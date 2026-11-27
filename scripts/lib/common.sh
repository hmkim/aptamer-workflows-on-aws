#!/usr/bin/env bash
# Shared helpers for the scripts/setup-*.sh and scripts/cleanup.sh entry points.
# Source this file; it never prints credentials or account identifiers.
set -euo pipefail

SCRIPTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REPO_DIR=$(cd -- "$SCRIPTS_DIR/.." && pwd)
PREFIX=${PREFIX:-aptamer-workflows}
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
hint() { printf '  %s\n' "$@" >&2; }
require_cmd() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing command: $c"; done; }

# Validate the shared --prefix and --region values. Stack names become ECR
# repository names, so the prefix must be lowercase.
check_common() {
  [[ "$PREFIX" =~ ^[a-z][a-z0-9-]{0,39}$ ]] || die '--prefix must match ^[a-z][a-z0-9-]{0,39}$'
  [[ -n "$REGION" ]] || die 'set --region or AWS_REGION'
  [[ "$REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || die "invalid Region: $REGION"
  require_cmd aws
  export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION
}

network_stack() { printf '%s-network' "$PREFIX"; }
batch_stack() { printf '%s-batch' "$PREFIX"; }
healthomics_stack() { printf '%s-healthomics' "$PREFIX"; }
healthomics_vpc_stack() { printf '%s-healthomics-vpc' "$PREFIX"; }

cfn() { aws --region "$REGION" --no-cli-pager cloudformation "$@"; }

# Prints the stack status, or NONE when the stack does not exist.
stack_status() {
  local out
  if out=$(cfn describe-stacks --stack-name "$1" --query 'Stacks[0].StackStatus' --output text 2>&1); then
    printf '%s' "$out"
  elif [[ "$out" == *'does not exist'* ]]; then
    printf 'NONE'
  else
    die "describe-stacks $1 failed: $out"
  fi
}

stack_exists() {
  local status
  status=$(stack_status "$1")
  [[ "$status" != NONE && "$status" != DELETE_COMPLETE ]]
}

# Prints one stack output, or an empty string when it is absent.
stack_output() {
  local value
  value=$(cfn describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text)
  [[ "$value" == None ]] && value=''
  printf '%s' "$value"
}

require_output() {
  local value
  value=$(stack_output "$1" "$2")
  [[ -n "$value" ]] || die "stack $1 has no output $2"
  printf '%s' "$value"
}

# Prints a current stack parameter value, or an empty string.
stack_parameter() {
  local value
  value=$(cfn describe-stacks --stack-name "$1" \
    --query "Stacks[0].Parameters[?ParameterKey=='$2'].ParameterValue | [0]" --output text)
  [[ "$value" == None ]] && value=''
  printf '%s' "$value"
}

# deploy_stack <stack> <template> <capabilities|-> [Key=Value ...]
# Parameters not passed keep their current value on an existing stack.
deploy_stack() {
  local stack=$1 template=$2 capabilities=$3; shift 3
  local status
  status=$(stack_status "$stack")
  case "$status" in
    ROLLBACK_COMPLETE|ROLLBACK_FAILED|DELETE_FAILED)
      die "stack $stack is in $status; inspect its events, then run scripts/cleanup.sh before retrying" ;;
    *_IN_PROGRESS)
      die "stack $stack is busy ($status); wait for it to finish" ;;
  esac
  local args=(deploy --stack-name "$stack" --template-file "$template" --no-fail-on-empty-changeset
              --tags "Project=$PREFIX")
  [[ "$capabilities" != - ]] && args+=(--capabilities "$capabilities")
  [[ $# -gt 0 ]] && args+=(--parameter-overrides "$@")
  log "deploying $stack from ${template#"$REPO_DIR"/}"
  cfn "${args[@]}" >&2
  log "$stack: $(stack_status "$stack")"
}

print_outputs() {
  cfn describe-stacks --stack-name "$1" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table >&2
}

# Deploy the shared network stack when it does not exist yet.
ensure_network() {
  if stack_exists "$(network_stack)"; then
    log "using existing network stack $(network_stack)"
  else
    log "network stack $(network_stack) not found; creating it"
    "$SCRIPTS_DIR/setup-network.sh" --prefix "$PREFIX" --region "$REGION"
  fi
}

default_image_tag() {
  local sha
  if sha=$(git -C "$REPO_DIR" rev-parse --short=12 HEAD 2>/dev/null); then
    printf 'git-%s' "$sha"
  else
    printf 'build-%s' "$(date -u +%Y%m%dT%H%M%SZ)"
  fi
}
