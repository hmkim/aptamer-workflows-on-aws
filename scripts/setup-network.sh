#!/usr/bin/env bash
# Deploy or update the shared private network stack <prefix>-network.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/setup-network.sh [--prefix <name>] [--region <region>] [--az1 <az> --az2 <az>]

  --prefix   stack name prefix, default aptamer-workflows (stack <prefix>-network)
  --region   AWS Region, default $AWS_REGION
  --az1/2    optional Availability Zone names for the two private subnets. Pick
             AZs where HealthOmics operates if you plan HealthOmics VPC mode.
EOF
}

az1='' az2=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX=${2:?}; shift 2 ;;
    --region) REGION=${2:?}; shift 2 ;;
    --az1) az1=${2:?}; shift 2 ;;
    --az2) az2=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done
check_common
[[ -z "$az1" && -z "$az2" || -n "$az1" && -n "$az2" ]] || die 'pass both --az1 and --az2, or neither'
[[ -z "$az1" || "$az1" != "$az2" ]] || die '--az1 and --az2 must differ'

params=("ProjectTag=$PREFIX")
[[ -n "$az1" ]] && params+=("AvailabilityZone1=$az1" "AvailabilityZone2=$az2")
deploy_stack "$(network_stack)" "$REPO_DIR/batch/network.yaml" - "${params[@]}"
print_outputs "$(network_stack)"

log 'next steps:'
hint "Batch:       scripts/setup-batch.sh --prefix $PREFIX --region $REGION [--cpu] [--gpu]" \
     "HealthOmics: scripts/setup-healthomics.sh --prefix $PREFIX --region $REGION [--vpc]"
