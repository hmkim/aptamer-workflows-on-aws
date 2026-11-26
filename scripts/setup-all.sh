#!/usr/bin/env bash
# Deploy everything at once: shared network, AWS Batch, and AWS HealthOmics.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/setup-all.sh [--prefix <name>] [--region <region>] [--cpu] [--gpu]
                            [--build-image] [--vpc] [--interface-endpoints]

  --cpu/--gpu, --build-image          passed to setup-batch.sh (default: CPU only)
  --mountpoint-version <v>, --mountpoint-sha256 <h>, --gpu-max-vcpus <n>, --gpu-instance-types <l>
                                      passed to setup-batch.sh
  --vpc, --interface-endpoints        passed to setup-healthomics.sh (VPC mode is not yet validated)
EOF
}

batch_args=() ho_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX=${2:?}; shift 2 ;;
    --region) REGION=${2:?}; shift 2 ;;
    --cpu|--gpu|--build-image) batch_args+=("$1"); shift ;;
    --mountpoint-version|--mountpoint-sha256|--gpu-max-vcpus|--gpu-instance-types)
      batch_args+=("$1" "${2:?}"); shift 2 ;;
    --vpc|--interface-endpoints) ho_args+=("$1"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done
check_common

"$SCRIPTS_DIR/setup-network.sh" --prefix "$PREFIX" --region "$REGION"
"$SCRIPTS_DIR/setup-batch.sh" --prefix "$PREFIX" --region "$REGION" ${batch_args[@]+"${batch_args[@]}"}
"$SCRIPTS_DIR/setup-healthomics.sh" --prefix "$PREFIX" --region "$REGION" ${ho_args[@]+"${ho_args[@]}"}

log "all stacks for prefix $PREFIX are deployed"
hint "Remove everything: scripts/cleanup.sh --prefix $PREFIX --region $REGION"
