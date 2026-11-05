#!/usr/bin/env bash
# Copy input objects to local POSIX storage, run the pipeline, then upload results.
set -Eeuo pipefail
export SCENARIO=${SCENARIO:-copyin}
source "$(dirname -- "${BASH_SOURCE[0]}")/job_common.sh"

timed copy_in_ms s3_sync --exclude '*' --include 'R*_*.fastq.gz' "$INPUT_S3/" "$JOB_INPUT/"
metric input_files "$(find "$JOB_INPUT" -maxdepth 1 -name 'R*_*.fastq.gz' | wc -l)" files
: "${FRONT_PRIMER:?Set FRONT_PRIMER.}"
: "${BACK_PRIMER:?Set BACK_PRIMER.}"
TOP_CANDIDATES=${TOP_CANDIDATES:-100}
timed pipeline_ms run_pipeline.sh \
  "$JOB_INPUT" "$JOB_OUTPUT/result" "$FRONT_PRIMER" "$BACK_PRIMER" \
  "$TOP_CANDIDATES" 'R*_*.fastq.gz' '^R([0-9]+)_'
record_disk_usage
timed upload_ms s3_sync --exclude 'tmp/*' "$JOB_OUTPUT/result/" "$RESULT_S3/"
log "copy-in run complete"
