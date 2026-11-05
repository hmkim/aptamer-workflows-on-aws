#!/usr/bin/env bash
# Shared helpers for operator-side upload, submission, and collection scripts.
set -Eeuo pipefail

: "${AWS_REGION:?Set AWS_REGION to the deployment Region.}"
: "${STACK_NAME:?Set STACK_NAME to the CloudFormation stack name.}"
export AWS_DEFAULT_REGION="$AWS_REGION"

BATCH_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROJECT_DIR=$(cd -- "$BATCH_DIR/.." && pwd)
RUNS_DIR=${RUNS_DIR:-"$BATCH_DIR/runs"}

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
require_cmd() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing command: $c"; done; }
new_run_id() { date -u +%Y%m%dT%H%M%SZ; }
validate_run_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
    die "RUN_ID must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
}
validate_pipeline_inputs() {
  : "${FRONT_PRIMER:?Set FRONT_PRIMER to the study-specific DNA sequence.}"
  : "${BACK_PRIMER:?Set BACK_PRIMER to the study-specific DNA sequence.}"
  TOP_CANDIDATES=${TOP_CANDIDATES:-100}
  [[ "$FRONT_PRIMER" =~ ^[ACGTNacgtn]+$ ]] || die "FRONT_PRIMER must contain only A, C, G, T, or N"
  [[ "$BACK_PRIMER" =~ ^[ACGTNacgtn]+$ ]] || die "BACK_PRIMER must contain only A, C, G, T, or N"
  [[ "$TOP_CANDIDATES" =~ ^[1-9][0-9]*$ ]] || die "TOP_CANDIDATES must be a positive integer"
}

stack_output() {
  local value
  value=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" --output text 2>/dev/null) || true
  [[ -n "$value" && "$value" != None ]] || die "stack output $1 was not found"
  printf '%s' "$value"
}

load_stack_outputs() {
  DATA_BUCKET=$(stack_output DataBucketName)
  DATA_PREFIX=$(stack_output DataPrefix)
  WORK_BUCKET=$(stack_output WorkBucketName)
  JOB_QUEUE=$(stack_output JobQueueName)
  JOBDEF_PIPELINE=$(stack_output PipelineJobDefinitionArn)
  JOBDEF_MOUNTPOINT=$(stack_output MountpointJobDefinitionArn)
  JOBDEF_DATA_LOADER=$(stack_output DataLoaderJobDefinitionArn)
  LOG_GROUP=$(stack_output LogGroupName)
  JOB_NAME_PREFIX=$(stack_output JobNamePrefix)
  PROJECT_TAG=$(stack_output ProjectTag)
}

env_json() {
  local first=1 kv key val out='['
  for kv in "$@"; do
    key=${kv%%=*}; val=${kv#*=}
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "invalid environment variable name: $key"
    [[ "$val" =~ ^[A-Za-z0-9._/:=-]*$ ]] || die "unsafe characters in value for $key"
    ((first)) || out+=','
    out+="{\"name\":\"$key\",\"value\":\"$val\"}"
    first=0
  done
  printf '%s]' "$out"
}

container_overrides() {
  local vcpu=$1 memory=$2; shift 2
  [[ "$vcpu" =~ ^[0-9]+$ && "$memory" =~ ^[0-9]+$ ]] || die "vCPU and memory must be integers"
  printf '{"resourceRequirements":[{"type":"VCPU","value":"%s"},{"type":"MEMORY","value":"%s"}],"environment":%s}' \
    "$vcpu" "$memory" "$(env_json "$@")"
}

submit_job() {
  local name=$1 job_definition=$2 overrides=$3; shift 3
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$ ]] || die "invalid job name: $name"
  local job_id
  job_id=$(aws batch submit-job \
    --job-name "$name" \
    --job-queue "$JOB_QUEUE" \
    --job-definition "$job_definition" \
    --container-overrides "$overrides" \
    --propagate-tags \
    --tags "Project=$PROJECT_TAG,RunId=$RUN_ID" \
    "$@" \
    --query jobId --output text)
  [[ -n "$job_id" && "$job_id" != None ]] || die "submit-job returned no job ID"
  log "submitted $name -> $job_id"
  printf '%s' "$job_id"
}

record_submission() {
  mkdir -p "$RUNS_DIR/$RUN_ID"
  local file="$RUNS_DIR/$RUN_ID/submissions.tsv"
  [[ -f "$file" ]] || printf 'submitted_utc\tscenario\tlabel\tjob_id\n' > "$file"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$file"
}
