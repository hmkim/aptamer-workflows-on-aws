#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd aws
load_stack_outputs
RUN_ID=${RUN_ID:-$(new_run_id)}
validate_run_id "$RUN_ID"
validate_pipeline_inputs
name="$JOB_NAME_PREFIX-mountpoint-$RUN_ID"
job_id=$(submit_job "$name" "$JOBDEF_MOUNTPOINT" \
  "$(container_overrides "${VCPU:-8}" "${MEMORY_MIB:-14000}" \
    RUN_ID="$RUN_ID" SCENARIO=mountpoint JOB_SCRIPT=run_mountpoint.sh \
    FRONT_PRIMER="$FRONT_PRIMER" BACK_PRIMER="$BACK_PRIMER" TOP_CANDIDATES="$TOP_CANDIDATES")")
record_submission mountpoint "$name" "$job_id"
log "result prefix: s3://$WORK_BUCKET/runs/mountpoint/$RUN_ID/result/"
printf '%s\n' "$job_id"
