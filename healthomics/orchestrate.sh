#!/usr/bin/env bash
# Package, register, run, or inspect the private HealthOmics workflow.
# This script makes no resources public and has no delete operation.
# Runs default to RESTRICTED networking. VPC networking (--networking-mode VPC)
# is NOT YET VALIDATED; see vpc/README.md.
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
state_dir="$script_dir/.state"
dist_dir="$script_dir/dist"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
require_env() { [[ -n "${!1:-}" ]] || die "set $1"; }
aws_cli() { aws --region "$AWS_REGION" --no-cli-pager "$@"; }
init_state() { mkdir -p "$state_dir" "$dist_dir"; chmod 700 "$state_dir"; }
state_set() { init_state; printf '%s\n' "$2" > "$state_dir/$1"; chmod 600 "$state_dir/$1"; }
state_get() { [[ -f "$state_dir/$1" ]] && cat "$state_dir/$1" || true; }

usage() {
  cat >&2 <<'EOF'
Usage: orchestrate.sh package|register|run|status [run-id]
       orchestrate.sh run [--networking-mode RESTRICTED|VPC] [--configuration-name <name>]

Common environment:
  AWS_REGION=<region>
  WORKFLOW_NAME=<name>                     default: aptamer-workflow

register:
  STORAGE_TYPE=DYNAMIC|STATIC              default: DYNAMIC
  STORAGE_CAPACITY=<GiB>                   required only for STATIC

run:
  WORKFLOW_ID=<id>                         optional after register
  BUCKET_NAME=<private-s3-bucket>
  SAMPLESHEET_URI=s3://<bucket>/<key>      sheet must contain complete S3 object URIs
  PIPELINE_IMAGE=<private-same-region-ecr-image>:<tag>
  RUN_ROLE_ARN=<healthomics-run-role-arn>
  OUTPUT_PREFIX=<prefix>                   default: outputs
  RUN_NAME=<name>                          default: generated UTC name
  FRONT_PRIMER=<DNA sequence>
  BACK_PRIMER=<DNA sequence>
  SCRATCH_STORAGE_MODE=SHARED|LOCAL        default: SHARED
  RETENTION_MODE=RETAIN|REMOVE             default: RETAIN
  LOG_LEVEL=ALL|ERROR|FATAL|OFF             default: ALL
  NETWORKING_MODE=RESTRICTED|VPC           default: RESTRICTED (or --networking-mode)
  CONFIGURATION_NAME=<name>                required for VPC (or --configuration-name);
                                           VPC mode is not yet validated
EOF
}

package_workflow() {
  require_command zip
  require_command sha256sum
  local output=${1:-"$dist_dir/aptamer-workflow.zip"}
  mkdir -p "$(dirname -- "$output")"
  local staging
  staging=$(mktemp -d)
  cp -p "$project_dir/nextflow/main.nf" \
     "$project_dir/nextflow/nextflow.config" \
     "$project_dir/nextflow/nextflow_schema.json" \
     "$project_dir/nextflow/samplesheet.tsv" \
     "$staging/"
  rm -f "$output"
  (cd "$staging" && zip -q -X -D "$output" main.nf nextflow.config nextflow_schema.json samplesheet.tsv)
  rm -rf "$staging"
  (cd "$(dirname -- "$output")" && sha256sum "$(basename -- "$output")" > "$(basename -- "$output").sha256")
  printf '%s\n' "$output"
}

register_workflow() {
  require_env AWS_REGION
  require_command aws
  require_command jq
  local workflow_name=${WORKFLOW_NAME:-aptamer-workflow}
  [[ "$workflow_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'invalid WORKFLOW_NAME'
  local archive storage_type response workflow_id status
  archive=$(package_workflow)
  storage_type=${STORAGE_TYPE:-DYNAMIC}
  [[ "$storage_type" == DYNAMIC || "$storage_type" == STATIC ]] || die 'STORAGE_TYPE must be DYNAMIC or STATIC'
  local storage_args=(--storage-type "$storage_type")
  if [[ "$storage_type" == STATIC ]]; then
    require_env STORAGE_CAPACITY
    storage_args+=(--storage-capacity "$STORAGE_CAPACITY")
  fi
  response=$(aws_cli omics create-workflow \
    --name "$workflow_name" \
    --description 'Aptamer sequencing workflow' \
    --engine NEXTFLOW \
    --main main.nf \
    --definition-zip "fileb://${archive}" \
    --parameter-template "file://${script_dir}/parameter-template.json" \
    "${storage_args[@]}" \
    --output json)
  workflow_id=$(jq -r '.id' <<<"$response")
  [[ "$workflow_id" =~ ^[0-9]+$ ]] || die 'create-workflow returned no numeric workflow id'
  state_set workflow-id "$workflow_id"
  for _ in $(seq 1 60); do
    status=$(aws_cli omics get-workflow --id "$workflow_id" --query status --output text)
    case "$status" in
      ACTIVE) break ;;
      FAILED|DELETED) die "workflow entered $status" ;;
      *) sleep 10 ;;
    esac
  done
  [[ "$status" == ACTIVE ]] || die "workflow did not become ACTIVE; current status: $status"
  aws_cli omics get-workflow --id "$workflow_id" \
    --query '{id:id,arn:arn,status:status,engine:engine,storageType:storageType}' --output json
}

start_run() {
  local networking_mode=${NETWORKING_MODE:-RESTRICTED}
  local configuration_name=${CONFIGURATION_NAME:-}
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --networking-mode) networking_mode=${2:-}; shift 2 || die '--networking-mode needs a value' ;;
      --configuration-name) configuration_name=${2:-}; shift 2 || die '--configuration-name needs a value' ;;
      *) die "unknown run option: $1" ;;
    esac
  done
  local network_args=(--networking-mode "$networking_mode")
  case "$networking_mode" in
    RESTRICTED)
      [[ -z "$configuration_name" ]] || die '--configuration-name applies only to --networking-mode VPC'
      ;;
    VPC)
      [[ "$configuration_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
        || die 'VPC networking needs --configuration-name (or CONFIGURATION_NAME)'
      network_args+=(--configuration-name "$configuration_name")
      log 'VPC networking mode is not yet validated in this repository'
      ;;
    *) die 'networking mode must be RESTRICTED or VPC' ;;
  esac
  require_env AWS_REGION
  require_env BUCKET_NAME
  require_env SAMPLESHEET_URI
  require_env PIPELINE_IMAGE
  require_env RUN_ROLE_ARN
  require_env FRONT_PRIMER
  require_env BACK_PRIMER
  require_command aws
  require_command jq
  [[ "$SAMPLESHEET_URI" == s3://* ]] || die 'SAMPLESHEET_URI must be an s3:// object URI'
  [[ "$PIPELINE_IMAGE" =~ ^[0-9]{12}\.dkr\.ecr\.${AWS_REGION}\.amazonaws\.com(\.cn)?/.+(:[A-Za-z0-9._-]+|@sha256:[a-fA-F0-9]{64})$ ]] \
    || die 'PIPELINE_IMAGE must be a tagged or digest-pinned private ECR image in AWS_REGION'
  [[ "$FRONT_PRIMER" =~ ^[ACGTNacgtn]+$ ]] || die 'FRONT_PRIMER must contain only DNA bases'
  [[ "$BACK_PRIMER" =~ ^[ACGTNacgtn]+$ ]] || die 'BACK_PRIMER must contain only DNA bases'

  local workflow_id run_name output_uri params_file response run_id
  workflow_id=${WORKFLOW_ID:-$(state_get workflow-id)}
  [[ -n "$workflow_id" ]] || die 'set WORKFLOW_ID or run register first'
  [[ "$(aws_cli omics get-workflow --id "$workflow_id" --query status --output text)" == ACTIVE ]] \
    || die 'workflow is not ACTIVE'
  run_name=${RUN_NAME:-"aptamer-$(date -u +%Y%m%dT%H%M%SZ)"}
  [[ "$run_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'invalid RUN_NAME'
  output_uri="s3://${BUCKET_NAME}/${OUTPUT_PREFIX:-outputs}/${run_name}/"
  init_state
  params_file="$state_dir/run-parameters.${run_name}.json"
  jq -n \
    --arg samplesheet "$SAMPLESHEET_URI" \
    --arg container "$PIPELINE_IMAGE" \
    --arg front "$FRONT_PRIMER" \
    --arg back "$BACK_PRIMER" \
    '{samplesheet:$samplesheet,input_dir:".",container:$container,outdir:"/mnt/workflow/pubdir",front_primer:$front,back_primer:$back}' \
    > "$params_file"
  chmod 600 "$params_file"

  local storage_args=(--storage-type "${STORAGE_TYPE:-DYNAMIC}")
  if [[ "${STORAGE_TYPE:-DYNAMIC}" == STATIC ]]; then
    require_env STORAGE_CAPACITY
    storage_args+=(--storage-capacity "$STORAGE_CAPACITY")
  fi
  response=$(aws_cli omics start-run \
    --workflow-id "$workflow_id" \
    --workflow-type PRIVATE \
    --name "$run_name" \
    --role-arn "$RUN_ROLE_ARN" \
    --output-uri "$output_uri" \
    --parameters "file://${params_file}" \
    --engine-settings '{"profile":"healthomics"}' \
    "${network_args[@]}" \
    --scratch-storage-mode "${SCRATCH_STORAGE_MODE:-SHARED}" \
    --retention-mode "${RETENTION_MODE:-RETAIN}" \
    --log-level "${LOG_LEVEL:-ALL}" \
    "${storage_args[@]}" \
    --output json)
  run_id=$(jq -r '.id' <<<"$response")
  [[ -n "$run_id" && "$run_id" != null ]] || die 'start-run returned no run id'
  state_set last-run-id "$run_id"
  jq '{id,arn,status,name}' <<<"$response"
}

show_status() {
  require_env AWS_REGION
  require_command aws
  require_command jq
  local run_id=${1:-$(state_get last-run-id)}
  [[ -n "$run_id" ]] || die 'pass a run id or start a run first'
  aws_cli omics get-run --id "$run_id" \
    --query '{id:id,name:name,status:status,statusMessage:statusMessage,workflowId:workflowId,creationTime:creationTime,startTime:startTime,stopTime:stopTime,outputUri:outputUri,failureReason:failureReason}' \
    --output json
  aws_cli omics list-run-tasks --id "$run_id" --max-results 100 \
    --query 'items[].{name:name,status:status,cpus:cpus,memory:memory,instanceType:instanceType,startTime:startTime,stopTime:stopTime}' \
    --output table
}

[[ $# -ge 1 ]] || { usage; exit 2; }
command_name=$1
shift
case "$command_name" in
  package) package_workflow "${1:-}" ;;
  register) register_workflow ;;
  run) start_run "$@" ;;
  status) show_status "${1:-}" ;;
  *) usage; exit 2 ;;
esac
