#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd aws
load_stack_outputs
RUN_ID=${RUN_ID:-$(new_run_id)}
validate_run_id "$RUN_ID"
validate_pipeline_inputs
name="$JOB_NAME_PREFIX-compat-$RUN_ID"
job_id=$(submit_job "$name" "$JOBDEF_MOUNTPOINT" \
  "$(container_overrides "${VCPU:-4}" "${MEMORY_MIB:-7000}" \
    RUN_ID="$RUN_ID" SCENARIO=compat JOB_SCRIPT=mountpoint_compat.sh \
    FRONT_PRIMER="$FRONT_PRIMER" BACK_PRIMER="$BACK_PRIMER" TOP_CANDIDATES="$TOP_CANDIDATES")")
record_submission compat "$name" "$job_id"
log "report prefix: s3://$WORK_BUCKET/runs/compat/$RUN_ID/"
printf '%s\n' "$job_id"
