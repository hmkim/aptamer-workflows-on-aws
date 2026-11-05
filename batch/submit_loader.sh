#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd aws
load_stack_outputs
RUN_ID=${RUN_ID:-manifest}
validate_run_id "$RUN_ID"
name="$JOB_NAME_PREFIX-loader-$RUN_ID"
loader_environment=(RUN_ID="$RUN_ID" SCENARIO=loader JOB_SCRIPT=load_data.sh)
if [[ -n "${MANIFEST_S3_URI:-}" || -n "${MANIFEST_SHA256:-}" ]]; then
  : "${MANIFEST_S3_URI:?Set MANIFEST_S3_URI from upload_manifest.sh.}"
  : "${MANIFEST_SHA256:?Set MANIFEST_SHA256 from upload_manifest.sh.}"
  [[ "$MANIFEST_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || die "MANIFEST_SHA256 must be 64 hexadecimal characters"
  loader_environment+=(MANIFEST_S3_URI="$MANIFEST_S3_URI" MANIFEST_SHA256="${MANIFEST_SHA256,,}")
fi
job_id=$(submit_job "$name" "$JOBDEF_DATA_LOADER" \
  "$(container_overrides "${VCPU:-2}" "${MEMORY_MIB:-3500}" "${loader_environment[@]}")")
record_submission loader "$name" "$job_id"
log "loader target: s3://$DATA_BUCKET/$DATA_PREFIX/"
printf '%s\n' "$job_id"
