#!/usr/bin/env bash
# Delete the stacks for one prefix in reverse order:
#   <prefix>-raptgen-ui-origin-access, <prefix>-raptgen-ui, <prefix>-raptgen-jobs,
#   <prefix>-healthomics-vpc, <prefix>-healthomics, <prefix>-batch, <prefix>-network
# The optional RaptGen-UI web gate (CDK app in raptgen/ui-web, us-east-1) is not deleted here:
# the script stops and tells you how to remove it while it still points at the UI host.
# Buckets, KMS keys, ECR repositories, and log groups are retained by the
# templates and are kept unless --delete-data is passed.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/cleanup.sh [--prefix <name>] [--region <region>] [--stacks <list>] [--yes] [--delete-data]

  --stacks       comma-separated subset of raptgen-ui-origin-access,raptgen-ui,raptgen-jobs,
                 healthomics-vpc,healthomics,batch,network (default: all)
  --yes          do not ask for confirmation
  --delete-data  also delete retained data: S3 buckets (every object version), ECR
                 repositories and images, log groups; schedule KMS key deletion (7 days)
EOF
}

ORDER=(raptgen-ui-origin-access raptgen-ui raptgen-jobs healthomics-vpc healthomics batch network)
selected='' assume_yes=0 delete_data=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX=${2:?}; shift 2 ;;
    --region) REGION=${2:?}; shift 2 ;;
    --stacks) selected=${2:?}; shift 2 ;;
    --yes) assume_yes=1; shift ;;
    --delete-data) delete_data=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done
check_common
selected=${selected:-$(IFS=,; printf '%s' "${ORDER[*]}")}
IFS=, read -r -a wanted <<<"$selected"
for w in "${wanted[@]}"; do
  [[ " ${ORDER[*]} " == *" $w "* ]] || die "unknown stack kind: $w"
done
is_wanted() { [[ ",$selected," == *",$1,"* ]]; }

# A stack can only go when nothing that uses it remains.
guard() { # <kind> <dependent kind>...
  local kind=$1 dep; shift
  is_wanted "$kind" || return 0
  for dep in "$@"; do
    if ! is_wanted "$dep" && stack_exists "$PREFIX-$dep"; then
      die "stack $PREFIX-$dep still uses $PREFIX-$kind; add $dep to --stacks or delete it first"
    fi
  done
}
guard network batch healthomics-vpc raptgen-ui raptgen-ui-origin-access
guard raptgen-ui raptgen-ui-origin-access
guard batch raptgen-jobs

# The optional web gate (raptgen/ui-web, a CDK stack in us-east-1) owns a CloudFront VPC origin whose
# network interfaces and the security group CloudFront-VPCOrigins-Service-SG live in this network.
# Remove the gate first; otherwise the UI host and the network cannot be deleted.
if is_wanted raptgen-ui || is_wanted network; then
  vpc=''
  stack_exists "$(network_stack)" && vpc=$(stack_output "$(network_stack)" VpcId)
  if [[ -n "$vpc" ]]; then
    cf_sg=$(aws --region "$REGION" ec2 describe-security-groups \
      --filters Name=group-name,Values=CloudFront-VPCOrigins-Service-SG "Name=vpc-id,Values=$vpc" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
    if [[ -n "$cf_sg" && "$cf_sg" != None ]]; then
      log "a CloudFront VPC origin still uses $(network_stack) (security group CloudFront-VPCOrigins-Service-SG)."
      hint 'Remove the RaptGen-UI web gate first (it is a CDK stack in us-east-1, not deleted by this script):' \
           '  cd raptgen/ui-web && UI_WEB_STACK=<gate stack name> npx cdk destroy' \
           'Then wait until CloudFront has removed the VPC origin (the security group disappears; this can take' \
           'several minutes) and run this script again. See docs/getting-started/90-cleanup.md.'
      die 'refusing to delete the UI host or the network while the web gate still exists'
    fi
  fi
fi

targets=()
for kind in "${ORDER[@]}"; do
  is_wanted "$kind" && stack_exists "$PREFIX-$kind" && targets+=("$PREFIX-$kind")
done
[[ ${#targets[@]} -gt 0 ]] || { log "no stacks to delete for prefix $PREFIX in $REGION"; exit 0; }

# Record retained resources before the stacks disappear.
buckets=() repos=() keys=() log_groups=()
if ((delete_data)); then
  for stack in "${targets[@]}"; do
    case "$stack" in
      "$PREFIX-batch")
        for k in DataBucketName WorkBucketName; do v=$(stack_output "$stack" "$k"); [[ -n "$v" ]] && buckets+=("$v"); done
        for k in RepositoryUri RaptgenCpuRepositoryUri RaptgenGpuRepositoryUri; do
          v=$(stack_output "$stack" "$k"); [[ -n "$v" ]] && repos+=("${v#*/}")
        done
        v=$(stack_output "$stack" KmsKeyArn); [[ -n "$v" ]] && keys+=("$v")
        v=$(stack_output "$stack" LogGroupName); [[ -n "$v" ]] && log_groups+=("$v")
        # CodeBuild creates this one itself on the first --build-image run.
        v=$(stack_output "$stack" ImageBuildProjectName); [[ -n "$v" ]] && log_groups+=("/aws/codebuild/$v")
        ;;
      "$PREFIX-healthomics")
        v=$(stack_output "$stack" BucketName); [[ -n "$v" ]] && buckets+=("$v")
        v=$(stack_output "$stack" RepositoryUri); [[ -n "$v" ]] && repos+=("${v#*/}")
        v=$(stack_output "$stack" KmsKeyArn); [[ -n "$v" ]] && keys+=("$v")
        ;;
    esac
  done
fi

printf 'Region: %s\nStacks to delete, in order:\n' "$REGION" >&2
printf '  %s\n' "${targets[@]}" >&2
if ((delete_data)); then
  printf 'Retained data to delete permanently:\n' >&2
  for b in ${buckets[@]+"${buckets[@]}"}; do printf '  s3 bucket   %s (all versions)\n' "$b" >&2; done
  for r in ${repos[@]+"${repos[@]}"}; do printf '  ecr repo    %s (all images)\n' "$r" >&2; done
  for l in ${log_groups[@]+"${log_groups[@]}"}; do printf '  log group   %s\n' "$l" >&2; done
  [[ ${#keys[@]} -gt 0 ]] && printf '  kms keys    %s (scheduled deletion in 7 days)\n' "${#keys[@]}" >&2
else
  printf 'Data buckets, ECR repositories, KMS keys, and log groups are kept (pass --delete-data to remove).\n' >&2
fi

if ((!assume_yes)); then
  [[ -t 0 ]] || die 'no terminal for confirmation; pass --yes to proceed'
  read -r -p "Type the prefix '$PREFIX' to confirm: " answer
  [[ "$answer" == "$PREFIX" ]] || die 'confirmation did not match; nothing deleted'
fi

for stack in "${targets[@]}"; do
  if [[ "$stack" == "$(healthomics_vpc_stack)" && "$(stack_parameter "$stack" CreateConfiguration)" == false ]]; then
    # The configuration was created by omics-vpc-configuration.sh, outside CloudFormation.
    config=$(stack_parameter "$stack" ConfigurationName)
    "$REPO_DIR/healthomics/vpc/omics-vpc-configuration.sh" delete --region "$REGION" --name "${config:-$stack}"
  fi
  log "deleting $stack"
  cfn delete-stack --stack-name "$stack"
  if ! cfn wait stack-delete-complete --stack-name "$stack"; then
    die "$stack did not delete cleanly; inspect its events. HealthOmics or Batch network interfaces can delay subnet and security group deletion; retry in a few minutes."
  fi
  log "$stack deleted"
done

empty_bucket() {
  local bucket=$1 batch
  require_cmd jq
  while :; do
    batch=$(aws --region "$REGION" s3api list-object-versions --bucket "$bucket" --max-items 500 --output json |
      jq -c '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key, VersionId})), Quiet: true}')
    [[ "$(jq '.Objects | length' <<<"$batch")" -gt 0 ]] || break
    aws --region "$REGION" s3api delete-objects --bucket "$bucket" --delete "$batch" >/dev/null
  done
}

if ((delete_data)); then
  for b in ${buckets[@]+"${buckets[@]}"}; do
    if aws --region "$REGION" s3api head-bucket --bucket "$b" 2>/dev/null; then
      log "emptying and deleting bucket $b"
      empty_bucket "$b"
      aws --region "$REGION" s3api delete-bucket --bucket "$b"
    fi
  done
  for r in ${repos[@]+"${repos[@]}"}; do
    aws --region "$REGION" ecr delete-repository --repository-name "$r" --force >/dev/null 2>&1 &&
      log "deleted ECR repository $r" || log "ECR repository $r not found"
  done
  for l in ${log_groups[@]+"${log_groups[@]}"}; do
    aws --region "$REGION" logs delete-log-group --log-group-name "$l" 2>/dev/null &&
      log "deleted log group $l" || log "log group $l not found"
  done
  for k in ${keys[@]+"${keys[@]}"}; do
    aws --region "$REGION" kms schedule-key-deletion --key-id "$k" --pending-window-in-days 7 >/dev/null &&
      log 'scheduled KMS key deletion in 7 days'
  done
fi

log "cleanup finished for prefix $PREFIX"
((delete_data)) || hint 'Retained buckets, keys, repositories, and log groups still exist and may incur charges.'
