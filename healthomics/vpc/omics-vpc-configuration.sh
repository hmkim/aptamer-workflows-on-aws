#!/usr/bin/env bash
# NOT YET VALIDATED. Create, inspect, or delete an AWS HealthOmics run
# configuration for VPC networking mode with the AWS CLI.
#
# vpc.yaml creates the same configuration through CloudFormation
# (AWS::Omics::Configuration). Use this script only when you deploy vpc.yaml
# with CreateConfiguration=false, or need a configuration outside CloudFormation.
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: omics-vpc-configuration.sh create|status|wait|delete [options]

Options:
  --region <region>               default: $AWS_REGION
  --name <configuration-name>     required
  --from-stack <stack-name>       read RunSecurityGroupId and SubnetIds from a vpc.yaml stack
  --security-group-ids <sg,...>   1-5 security groups (instead of --from-stack)
  --subnet-ids <subnet,...>       1-16 private subnets, at most one per AZ (instead of --from-stack)
  --timeout-seconds <n>           wait limit for ACTIVE or deletion, default 900 (15 minutes)

create waits until the configuration is ACTIVE. delete waits until it is gone.
EOF
}

[[ $# -ge 1 ]] || { usage; exit 2; }
action=$1; shift
region=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
name='' from_stack='' sg_ids='' subnet_ids='' timeout=900
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) region=${2:?}; shift 2 ;;
    --name) name=${2:?}; shift 2 ;;
    --from-stack) from_stack=${2:?}; shift 2 ;;
    --security-group-ids) sg_ids=${2:?}; shift 2 ;;
    --subnet-ids) subnet_ids=${2:?}; shift 2 ;;
    --timeout-seconds) timeout=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done
[[ -n "$region" ]] || die 'set --region or AWS_REGION'
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'set --name to a valid configuration name'
[[ "$timeout" =~ ^[0-9]+$ ]] || die '--timeout-seconds must be an integer'
command -v aws >/dev/null 2>&1 || die 'missing command: aws'

aws_cli() { aws --region "$region" --no-cli-pager "$@"; }

stack_output() {
  aws_cli cloudformation describe-stacks --stack-name "$from_stack" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" --output text
}

config_status() {
  local out
  if out=$(aws_cli omics get-configuration --name "$name" --query status --output text 2>&1); then
    printf '%s' "$out"
  elif [[ "$out" == *ResourceNotFound* || "$out" == *NotFound* ]]; then
    printf 'NOT_FOUND'
  else
    die "get-configuration failed: $out"
  fi
}

wait_for() {
  local want=$1 waited=0 status
  while :; do
    status=$(config_status)
    log "configuration $name: $status"
    [[ "$status" == "$want" ]] && return 0
    case "$status" in FAILED|DELETED) [[ "$want" == NOT_FOUND ]] && return 0; die "configuration entered $status" ;; esac
    ((waited >= timeout)) && die "timed out after ${timeout}s waiting for $want"
    sleep 15; waited=$((waited + 15))
  done
}

json_list() {
  local IFS=, item out='' first=1
  for item in $1; do
    [[ "$item" =~ ^$2-[0-9a-f]+$ ]] || die "invalid id: $item"
    ((first)) || out+=','
    out+="\"$item\""; first=0
  done
  printf '[%s]' "$out"
}

case "$action" in
  create)
    if [[ -n "$from_stack" ]]; then
      sg_ids=$(stack_output RunSecurityGroupId)
      subnet_ids=$(stack_output SubnetIds)
    fi
    [[ -n "$sg_ids" && -n "$subnet_ids" ]] || die 'set --from-stack, or both --security-group-ids and --subnet-ids'
    if [[ "$(config_status)" != NOT_FOUND ]]; then
      log "configuration $name already exists (configurations are immutable)"
    else
      run_config=$(printf '{"vpcConfig":{"securityGroupIds":%s,"subnetIds":%s}}' \
        "$(json_list "$sg_ids" sg)" "$(json_list "$subnet_ids" subnet)")
      aws_cli omics create-configuration --name "$name" \
        --description 'VPC-mode run configuration for aptamer workflows (not yet validated)' \
        --run-configurations "$run_config" --query '{name:name,status:status}' --output json
    fi
    wait_for ACTIVE
    printf 'Next: orchestrate.sh run --networking-mode VPC --configuration-name %s\n' "$name" >&2
    ;;
  status)
    aws_cli omics get-configuration --name "$name" \
      --query '{name:name,status:status,vpcConfig:runConfigurations.vpcConfig}' --output json
    ;;
  wait) wait_for ACTIVE ;;
  delete)
    if [[ "$(config_status)" == NOT_FOUND ]]; then
      log "configuration $name does not exist"
      exit 0
    fi
    aws_cli omics delete-configuration --name "$name"
    wait_for NOT_FOUND
    ;;
  *) usage; exit 2 ;;
esac
