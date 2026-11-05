#!/usr/bin/env bash
# Submit S1-S3 as arrays with N_TO_N dependencies, then S4 and S5 as single dependent jobs.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd aws
load_stack_outputs
RUN_ID=${RUN_ID:-$(new_run_id)}
validate_run_id "$RUN_ID"
validate_pipeline_inputs
: "${ROUNDS:?Set ROUNDS to the number of contiguous rounds, starting at R0.}"
[[ "$ROUNDS" =~ ^[0-9]+$ && "$ROUNDS" -ge 2 ]] || die "ROUNDS must be an integer of at least 2"
vcpu=${STAGE_VCPU:-4}
memory=${STAGE_MEMORY_MIB:-7000}
stage_overrides() {
  container_overrides "$vcpu" "$memory" \
    RUN_ID="$RUN_ID" SCENARIO=dependencies JOB_SCRIPT=run_stage.sh JOB_ARGS="$1" \
    FRONT_PRIMER="$FRONT_PRIMER" BACK_PRIMER="$BACK_PRIMER" TOP_CANDIDATES="$TOP_CANDIDATES"
}

s1=$(submit_job "$JOB_NAME_PREFIX-s1-qc-$RUN_ID" "$JOBDEF_PIPELINE" "$(stage_overrides S1)" --array-properties "size=$ROUNDS")
record_submission dependencies S1-qc "$s1"
s2=$(submit_job "$JOB_NAME_PREFIX-s2-trim-$RUN_ID" "$JOBDEF_PIPELINE" "$(stage_overrides S2)" \
  --array-properties "size=$ROUNDS" --depends-on "jobId=$s1,type=N_TO_N")
record_submission dependencies S2-trim "$s2"
s3=$(submit_job "$JOB_NAME_PREFIX-s3-count-$RUN_ID" "$JOBDEF_PIPELINE" "$(stage_overrides S3)" \
  --array-properties "size=$ROUNDS" --depends-on "jobId=$s2,type=N_TO_N")
record_submission dependencies S3-count "$s3"
s4=$(submit_job "$JOB_NAME_PREFIX-s4-enrich-$RUN_ID" "$JOBDEF_PIPELINE" "$(stage_overrides S4)" --depends-on "jobId=$s3")
record_submission dependencies S4-enrich "$s4"
s5=$(submit_job "$JOB_NAME_PREFIX-s5-fold-$RUN_ID" "$JOBDEF_PIPELINE" "$(stage_overrides S5)" --depends-on "jobId=$s4")
record_submission dependencies S5-fold "$s5"
log "final job: $s5; result prefix: s3://$WORK_BUCKET/runs/dependencies/$RUN_ID/result/"
printf '%s\n' "$s1" "$s2" "$s3" "$s4" "$s5"
