#!/usr/bin/env bash
# Shared helpers for scripts running inside an AWS Batch job container.
set -Eeuo pipefail

: "${DATA_BUCKET:?Set DATA_BUCKET.}"
: "${WORK_BUCKET:?Set WORK_BUCKET.}"
: "${LOCAL_SCRATCH:?Set LOCAL_SCRATCH.}"
: "${SCENARIO:?Set SCENARIO.}"
DATA_PREFIX=${DATA_PREFIX:-input}
RUN_ID=${RUN_ID:-${AWS_BATCH_JOB_ID%%:*}}
RUN_PREFIX=${RUN_PREFIX:-"runs/$SCENARIO/$RUN_ID"}

JOB_ID_SAFE=$(printf '%s' "${AWS_BATCH_JOB_ID:-local-$$}" | tr ':' '-')
ARRAY_INDEX=${AWS_BATCH_JOB_ARRAY_INDEX:-}
JOB_ROOT="$LOCAL_SCRATCH/run-$JOB_ID_SAFE"
JOB_INPUT="$JOB_ROOT/input"
JOB_OUTPUT="$JOB_ROOT/output"
JOB_TMP="$JOB_ROOT/tmp"
mkdir -p "$JOB_INPUT" "$JOB_OUTPUT" "$JOB_TMP"
export TMPDIR="$JOB_TMP"

INPUT_S3="s3://$DATA_BUCKET/$DATA_PREFIX"
RUN_S3="s3://$WORK_BUCKET/$RUN_PREFIX"
RESULT_S3="$RUN_S3/result"
METRICS_FILE="$JOB_OUTPUT/metrics.tsv"
JOB_LOG="$JOB_ROOT/job.log"
exec > >(tee -a "$JOB_LOG") 2>&1

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
now_ms() { date +%s%3N; }
metric() {
  [[ -f "$METRICS_FILE" ]] || printf 'job_id\tscenario\tstage\tarray_index\tname\tvalue\tunit\n' > "$METRICS_FILE"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${AWS_BATCH_JOB_ID:-local}" "$SCENARIO" "${STAGE:-all}" "$ARRAY_INDEX" "$1" "$2" "${3:-}" >> "$METRICS_FILE"
}
timed() {
  local name=$1 start end; shift
  start=$(now_ms); "$@"; end=$(now_ms)
  metric "$name" "$((end - start))" ms
}
record_disk_usage() {
  metric local_input_bytes "$(du -sb "$JOB_INPUT" | cut -f1)" bytes
  metric local_output_bytes "$(du -sb "$JOB_OUTPUT" | cut -f1)" bytes
  metric local_total_bytes "$(du -sb "$JOB_ROOT" | cut -f1)" bytes
}
s3_cp() { aws s3 cp --only-show-errors "$@"; }
s3_sync() { aws s3 sync --only-show-errors "$@"; }
job_artifact_prefix() {
  local path="jobs/${STAGE:-all}"
  [[ -n "$ARRAY_INDEX" ]] && path="$path/idx-$ARRAY_INDEX"
  printf '%s/%s' "$RUN_S3" "$path"
}
finish() {
  local rc=$?
  set +e
  log "exit status $rc; uploading job artifacts"
  [[ -f "$METRICS_FILE" ]] && s3_cp "$METRICS_FILE" "$(job_artifact_prefix)/metrics.tsv"
  s3_cp "$JOB_LOG" "$(job_artifact_prefix)/job.log"
  rm -rf "$JOB_ROOT"
  exit "$rc"
}
trap finish EXIT

log "job start: scenario=$SCENARIO stage=${STAGE:-all} array_index=${ARRAY_INDEX:-none} run=$RUN_ID"
metric host_nproc "$(nproc)" vcpu
