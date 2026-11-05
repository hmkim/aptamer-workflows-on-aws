#!/usr/bin/env bash
# Wait for submitted jobs, mirror run outputs, and compare result tables by SHA-256.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd aws
: "${RUN_ID:?Set RUN_ID to a submitted run.}"
validate_run_id "$RUN_ID"
load_stack_outputs
run_dir="$RUNS_DIR/$RUN_ID"
submissions="$run_dir/submissions.tsv"
[[ -f "$submissions" ]] || die "no local submission record for RUN_ID=$RUN_ID"
WAIT=${WAIT:-true}
POLL_SECONDS=${POLL_SECONDS:-30}
mapfile -t job_ids < <(tail -n +2 "$submissions" | cut -f4)
((${#job_ids[@]} > 0)) || die "submission record contains no job IDs"

status_file="$run_dir/job_status.tsv"
while :; do
  {
    printf 'job_id\tjob_name\tstatus\tcreated_ms\tstarted_ms\tstopped_ms\tstatus_reason\tarray_size\n'
    aws batch describe-jobs --jobs "${job_ids[@]}" \
      --query 'jobs[].[jobId,jobName,status,createdAt,startedAt,stoppedAt,statusReason,arrayProperties.size]' \
      --output text
  } > "$status_file"
  pending=$(awk -F'\t' 'NR>1 && $3!="SUCCEEDED" && $3!="FAILED"' "$status_file" | wc -l)
  log "unfinished jobs: $pending"
  [[ "$WAIT" == true && "$pending" -gt 0 ]] || break
  sleep "$POLL_SECONDS"
done

awk -F'\t' 'BEGIN{print "job_name\tmetric\tvalue_ms"}
  NR>1 && $4!="None" && $5!="None" {printf "%s\tqueue_wait_ms\t%d\n", $2, $5-$4;
  if ($6!="None") printf "%s\trun_ms\t%d\n", $2, $6-$5}' "$status_file" > "$run_dir/job_timing.tsv"
mkdir -p "$run_dir/s3"
for scenario in copyin dependencies mountpoint compat loader; do
  prefix="runs/$scenario/$RUN_ID/"
  key_count=$(aws s3api list-objects-v2 \
    --bucket "$WORK_BUCKET" \
    --prefix "$prefix" \
    --max-keys 1 \
    --query KeyCount \
    --output text)
  if [[ "$key_count" =~ ^[1-9][0-9]*$ ]]; then
    aws s3 sync --only-show-errors "s3://$WORK_BUCKET/$prefix" "$run_dir/s3/$scenario/"
  else
    log "no objects found for $prefix"
  fi
done
find "$run_dir/s3" -name metrics.tsv -print0 | sort -z \
  | xargs -0 -r awk 'FNR==1 && NR!=1 {next} {print}' > "$run_dir/metrics.tsv"

comparison="$run_dir/result_compare.tsv"
printf 'scenario\tresult_path\tsorted_sha256\tmatches_reference\n' > "$comparison"
sorted_sha256() { LC_ALL=C sort "$1" | sha256sum | cut -d' ' -f1; }
reference_hash=""
if [[ -n "${REFERENCE_RESULT:-}" ]]; then
  [[ -f "$REFERENCE_RESULT" ]] || die "REFERENCE_RESULT does not exist"
  reference_hash=$(sorted_sha256 "$REFERENCE_RESULT")
  printf 'reference\t%s\t%s\t-\n' "$REFERENCE_RESULT" "$reference_hash" >> "$comparison"
fi
for scenario in copyin dependencies mountpoint; do
  result_file="$run_dir/s3/$scenario/result/enrich/top_candidates.tsv"
  if [[ -f "$result_file" ]]; then
    hash=$(sorted_sha256 "$result_file")
    match=n/a
    [[ -n "$reference_hash" ]] && { [[ "$hash" == "$reference_hash" ]] && match=yes || match=no; }
    printf '%s\t%s\t%s\t%s\n' "$scenario" "$result_file" "$hash" "$match" >> "$comparison"
  else
    printf '%s\t-\tmissing\t-\n' "$scenario" >> "$comparison"
  fi
done
cat "$comparison"
log "local collection directory: $run_dir"
