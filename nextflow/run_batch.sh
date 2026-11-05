#!/usr/bin/env bash
# Launch the workflow from a Nextflow head node. This script does not provision AWS resources.
set -Eeuo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: run_batch.sh batch|batch_mountpoint [additional Nextflow arguments]

Required environment:
  AWS_REGION, BATCH_QUEUE, BATCH_JOB_ROLE_ARN, PIPELINE_IMAGE
  NXF_WORK=s3://<bucket>/<prefix>
  OUTPUT_URI=s3://<bucket>/<prefix>
  SAMPLESHEET=<local-samplesheet-path>
  INPUT_URI=s3://<bucket>/<prefix>             (batch)
  INPUT_URI=/mnt/s3-input/<prefix>             (batch_mountpoint)
Optional:
  MOUNT_PATH=/mnt/s3-input, REPORT_DIR=<local-path>, RESUME=true
EOF
}

[[ $# -ge 1 ]] || { usage; exit 2; }
profile=$1
shift
[[ "$profile" == batch || "$profile" == batch_mountpoint ]] || { usage; exit 2; }

: "${AWS_REGION:?set AWS_REGION}"
: "${BATCH_QUEUE:?set BATCH_QUEUE}"
: "${BATCH_JOB_ROLE_ARN:?set BATCH_JOB_ROLE_ARN}"
: "${PIPELINE_IMAGE:?set PIPELINE_IMAGE}"
: "${NXF_WORK:?set NXF_WORK to an s3:// URI}"
: "${OUTPUT_URI:?set OUTPUT_URI to an s3:// URI}"
: "${INPUT_URI:?set INPUT_URI}"
: "${SAMPLESHEET:?set SAMPLESHEET to a local TSV file}"
[[ -f "$SAMPLESHEET" ]] || { echo 'SAMPLESHEET must identify a local file' >&2; exit 2; }
[[ "$NXF_WORK" == s3://* ]] || { echo 'NXF_WORK must use s3://' >&2; exit 2; }
[[ "$OUTPUT_URI" == s3://* ]] || { echo 'OUTPUT_URI must use s3://' >&2; exit 2; }
[[ "$PIPELINE_IMAGE" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\.cn)?/.+(:[A-Za-z0-9._-]+|@sha256:[a-fA-F0-9]{64})$ ]] \
  || { echo 'PIPELINE_IMAGE must be a tagged or digest-pinned private ECR image URI' >&2; exit 2; }

if [[ "$profile" == batch ]]; then
  [[ "$INPUT_URI" == s3://* ]] || { echo 'batch INPUT_URI must use s3://' >&2; exit 2; }
else
  [[ "$INPUT_URI" == /* ]] || { echo 'batch_mountpoint INPUT_URI must be absolute' >&2; exit 2; }
  if [[ "${RESUME:-false}" == true ]]; then
    cat >&2 <<'EOF'
WARNING: -resume cannot detect changed objects behind the same Mountpoint path.
Use immutable/versioned object keys, or leave RESUME=false when content may have changed.
EOF
  fi
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
resume_args=()
[[ "${RESUME:-false}" == true ]] && resume_args=(-resume)

exec nextflow run "$script_dir/main.nf" \
  -profile "$profile" \
  "${resume_args[@]}" \
  --samplesheet "$SAMPLESHEET" \
  --input_dir "$INPUT_URI" \
  --outdir "$OUTPUT_URI" \
  --work_uri "$NXF_WORK" \
  --aws_region "$AWS_REGION" \
  --batch_queue "$BATCH_QUEUE" \
  --batch_job_role "$BATCH_JOB_ROLE_ARN" \
  --container "$PIPELINE_IMAGE" \
  --mount_path "${MOUNT_PATH:-/mnt/s3-input}" \
  --report_dir "${REPORT_DIR:-pipeline_info/$profile}" \
  "$@"
