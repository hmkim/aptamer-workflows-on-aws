#!/usr/bin/env bash
# Show a RaptGen Batch job: status, reason, where results are, and benchmark lines.
#
#   status.sh <job-id>                    one job
#   status.sh --list [--stack-prefix P]   latest jobs of every enabled queue
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

prefix="${STACK_PREFIX:-aptamer-workflows}" list=0 job=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) list=1; shift ;;
    --stack-prefix) prefix="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) job="$1"; shift ;;
  esac
done

if [[ "${list}" -eq 1 ]]; then
  for key in CpuJobQueueName GpuJobQueueName; do
    q="$(stack_output "${prefix}-batch" "${key}")" || exit 1
    [[ -n "${q}" ]] || { echo "${key}: disabled"; continue; }
    echo "== ${q}"
    for st in RUNNING RUNNABLE STARTING SUBMITTED PENDING SUCCEEDED FAILED; do
      aws batch list-jobs --job-queue "${q}" --job-status "${st}" \
        --query "jobSummaryList[:5].[jobId,jobName,status]" --output text
    done
  done
  exit 0
fi

[[ -n "${job}" ]] || { echo "usage: status.sh <job-id> | --list" >&2; exit 2; }
aws batch describe-jobs --jobs "${job}" \
  --query 'jobs[0].[jobName,status,statusReason,container.reason,container.exitCode,container.logStreamName]' --output text \
  | awk -F'\t' '{print "name   : "$1"\nstatus : "$2"\nreason : "$3" "$4"\nexit   : "$5"\nlog    : "$6}'
out="$(aws batch describe-jobs --jobs "${job}" \
  --query "jobs[0].container.environment[?name=='RAPTGEN_OUTPUT'].value | [0]" --output text)"
if [[ -n "${out}" && "${out}" != None ]]; then
  echo "results: ${out}"
  echo "  fetch: aws s3 cp ${out} ./results-${job} --recursive"
fi
status="$(aws batch describe-jobs --jobs "${job}" --query 'jobs[0].status' --output text)"
name="$(aws batch describe-jobs --jobs "${job}" --query 'jobs[0].jobName' --output text)"
if [[ "${status}" == SUCCEEDED && "${name}" == bench-* ]]; then
  stream="$(aws batch describe-jobs --jobs "${job}" --query 'jobs[0].container.logStreamName' --output text)"
  group="$(aws batch describe-jobs --jobs "${job}" --query 'jobs[0].container.logConfiguration.options."awslogs-group"' --output text)"
  if [[ "${group}" == None || -z "${group}" ]]; then group="$(stack_output "${prefix}-batch" LogGroupName)"; fi
  echo "benchmark lines:"
  aws logs get-log-events --log-group-name "${group}" --log-stream-name "${stream}" --start-from-head \
    --query 'events[].message' --output text | tr '\t' '\n' | grep '^{' || true
fi
