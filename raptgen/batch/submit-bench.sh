#!/usr/bin/env bash
# Submit the RaptGen CPU-vs-GPU benchmark (fixed epochs on paper dataset A).
#
#   submit-bench.sh --device cpu|gpu|both [--epochs N] [--stack-prefix P] [--jobdef-prefix raptgen]
#
# The GPU job times CUDA and then CPU on the same instance. Results are JSON lines
# in the CloudWatch log stream of the job; status.sh prints them.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

device="" epochs=5
prefix="${STACK_PREFIX:-aptamer-workflows}" jdprefix=raptgen
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device="${2:?}"; shift 2 ;;
    --epochs) epochs="${2:?}"; shift 2 ;;
    --stack-prefix) prefix="${2:?}"; shift 2 ;;
    --jobdef-prefix) jdprefix="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "${device}" == cpu || "${device}" == gpu || "${device}" == both ]] || { echo "--device cpu|gpu|both is required" >&2; exit 2; }
[[ "${epochs}" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "--epochs must be 1..999" >&2; exit 2; }

devices=("${device}"); [[ "${device}" == both ]] && devices=(cpu gpu)
# Resolve every queue first so a disabled queue fails before anything is submitted.
declare -A queues
for d in "${devices[@]}"; do queues[$d]="$(queue_for_device "${prefix}" "${d}")"; done
for d in "${devices[@]}"; do
  job_name="bench-${d}-$(date -u +%Y%m%d-%H%M%S)"
  job_id="$(aws batch submit-job --job-name "${job_name}" --job-queue "${queues[$d]}" \
    --job-definition "${jdprefix}-bench-${d}" \
    --container-overrides "{\"environment\":[{\"name\":\"BENCH_EPOCHS\",\"value\":\"${epochs}\"}]}" \
    --query jobId --output text)"
  echo "submitted ${job_name}: job id ${job_id} (queue ${queues[$d]})"
  echo "  check with: ${here}/status.sh ${job_id}"
done
