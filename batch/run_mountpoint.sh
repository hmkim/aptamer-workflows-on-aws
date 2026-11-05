#!/usr/bin/env bash
# Read inputs through a read-only Mountpoint mount. All temporary files and outputs stay local.
set -Eeuo pipefail
export SCENARIO=${SCENARIO:-mountpoint}
source "$(dirname -- "${BASH_SOURCE[0]}")/job_common.sh"

MOUNT_PATH=${MOUNT_PATH:-/mnt/s3-data}
input_dir=${MOUNT_INPUT_DIR:-"$MOUNT_PATH/$DATA_PREFIX"}
[[ -d "$input_dir" ]] || { log "Mountpoint input directory is unavailable: $input_dir"; exit 1; }
mount_options=$(findmnt --noheadings --output OPTIONS --target "$MOUNT_PATH" 2>/dev/null || true)
if [[ -z "$mount_options" ]]; then
  mount_options=$(awk -v target="$MOUNT_PATH" '$5 == target {print $6; exit}' /proc/self/mountinfo)
fi
[[ ",$mount_options," == *,ro,* ]] || {
  log "ERROR: input mount is not read-only according to mount metadata"
  exit 1
}
log "verified read-only input mount from mount metadata"
metric input_files "$(find "$input_dir" -maxdepth 1 -name 'R*_*.fastq.gz' | wc -l)" files
metric copy_in_ms 0 ms

# Mountpoint is not fully POSIX-compliant. The pipeline may fail if a tool modifies,
# renames, links, or locks input files. Keep TMPDIR and every output on local POSIX storage.
: "${FRONT_PRIMER:?Set FRONT_PRIMER.}"
: "${BACK_PRIMER:?Set BACK_PRIMER.}"
TOP_CANDIDATES=${TOP_CANDIDATES:-100}
timed pipeline_ms run_pipeline.sh \
  "$input_dir" "$JOB_OUTPUT/result" "$FRONT_PRIMER" "$BACK_PRIMER" \
  "$TOP_CANDIDATES" 'R*_*.fastq.gz' '^R([0-9]+)_'
record_disk_usage
timed upload_ms s3_sync --exclude 'tmp/*' "$JOB_OUTPUT/result/" "$RESULT_S3/"
log "Mountpoint run complete"
