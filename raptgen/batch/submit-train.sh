#!/usr/bin/env bash
# Submit a RaptGen training job (train + encode, results to S3).
#
#   submit-train.sh --device cpu|gpu [--input s3://bucket/key.fastq|builtin:A_4R|builtin:sample]
#                   [--epochs N] [--min-count N] [--threshold N]
#                   [--stack-prefix aptamer-workflows] [--jobdef-prefix <stack-prefix>-raptgen]
#
# Without --input the bundled paper dataset A (data/real/A_4R.fastq) is used.
# Results: s3://<WorkBucketName>/runs/raptgen/<run-id>/ (model, loss CSV, embeddings, run.json).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

device="" input="builtin:A_4R" epochs=50 mincount=2 threshold=50
prefix="${STACK_PREFIX:-aptamer-workflows}" jdprefix=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device="${2:?}"; shift 2 ;;
    --input) input="${2:?}"; shift 2 ;;
    --epochs) epochs="${2:?}"; shift 2 ;;
    --min-count) mincount="${2:?}"; shift 2 ;;
    --threshold) threshold="${2:?}"; shift 2 ;;
    --stack-prefix) prefix="${2:?}"; shift 2 ;;
    --jobdef-prefix) jdprefix="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
jdprefix="${jdprefix:-${prefix}-raptgen}"   # job definitions <stack-prefix>-raptgen-* (jobs.yaml NamePrefix)
[[ "${device}" == cpu || "${device}" == gpu ]] || { echo "--device cpu|gpu is required" >&2; exit 2; }
[[ "${epochs}" =~ ^[0-9]+$ && "${mincount}" =~ ^[0-9]+$ && "${threshold}" =~ ^[0-9]+$ ]] || { echo "numbers expected for --epochs/--min-count/--threshold" >&2; exit 2; }
[[ "${input}" =~ ^(builtin:(A_4R|sample)|s3://[a-z0-9][a-z0-9.-]+/.+)$ ]] || { echo "--input must be s3://bucket/key, builtin:A_4R or builtin:sample" >&2; exit 2; }

queue="$(queue_for_device "${prefix}" "${device}")"
bucket="$(stack_output "${prefix}-batch" WorkBucketName)"
[[ -n "${bucket}" ]] || { echo "stack ${prefix}-batch has no WorkBucketName output" >&2; exit 1; }
run_id="train-${device}-$(date -u +%Y%m%d-%H%M%S)"
# The job role may write only below runs/ of the work bucket (batch/infrastructure.yaml).
output="s3://${bucket}/runs/raptgen/${run_id}/"
cuda=cpu; [[ "${device}" == gpu ]] && cuda=cuda

overrides="$(python3 - "${input}" "${epochs}" "${mincount}" "${threshold}" "${run_id}" "${output}" "${cuda}" <<'PY'
import json, sys
keys = ["RAPTGEN_INPUT", "RAPTGEN_EPOCHS", "RAPTGEN_MIN_COUNT", "RAPTGEN_THRESHOLD", "RAPTGEN_RUN_ID", "RAPTGEN_OUTPUT", "RAPTGEN_DEVICE"]
print(json.dumps({"environment": [{"name": k, "value": v} for k, v in zip(keys, sys.argv[1:])]}))
PY
)"
job_id="$(aws batch submit-job --job-name "${run_id}" --job-queue "${queue}" \
  --job-definition "${jdprefix}-train-${device}" --container-overrides "${overrides}" \
  --query jobId --output text)"
echo "submitted ${run_id}"
echo "  job id : ${job_id}"
echo "  queue  : ${queue}"
echo "  output : ${output}"
echo "check with: ${here}/status.sh ${job_id}"
