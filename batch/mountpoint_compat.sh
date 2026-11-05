#!/usr/bin/env bash
# Test pipeline read patterns against read-only Mountpoint and local POSIX scratch.
set -Eeuo pipefail
export SCENARIO=${SCENARIO:-compat}
source "$(dirname -- "${BASH_SOURCE[0]}")/job_common.sh"
: "${FRONT_PRIMER:?Set FRONT_PRIMER.}"
: "${BACK_PRIMER:?Set BACK_PRIMER.}"

MOUNT_PATH=${MOUNT_PATH:-/mnt/s3-data}
mount_input=${MOUNT_INPUT_DIR:-"$MOUNT_PATH/$DATA_PREFIX"}
[[ -d "$mount_input" ]] || { log "input mount is unavailable: $mount_input"; exit 1; }
REPORT="$JOB_OUTPUT/compat_report.tsv"
printf 'case\tcategory\ttool\tlocation\texpected\tresult\texit_code\tms\terror\n' > "$REPORT"

check() {
  local case_id=$1 category=$2 tool=$3 location=$4 expected=$5; shift 5
  local start end rc=0 error result verdict=as-expected error_file="$JOB_TMP/$case_id.err"
  start=$(now_ms)
  set +e; "$@" >/dev/null 2>"$error_file"; rc=$?; set -e
  end=$(now_ms)
  error=$(tr '\n\t' '  ' < "$error_file" | cut -c1-300)
  if ((rc == 0)); then result=pass; else result=fail; fi
  [[ "$result" == "$expected" ]] || verdict=UNEXPECTED
  printf '%s\t%s\t%s\t%s\t%s\t%s (%s)\t%s\t%s\t%s\n' \
    "$case_id" "$category" "$tool" "$location" "$expected" "$result" "$verdict" "$rc" "$((end-start))" "$error" >> "$REPORT"
  log "$case_id $tool expected=$expected result=$result ($verdict)"
}

mapfile -t inputs < <(find "$mount_input" -maxdepth 1 -name 'R*_*.fastq.gz' | sort -V)
((${#inputs[@]} > 0)) || { log "no FASTQ inputs were found"; exit 1; }
sample=${inputs[0]}
local_out="$JOB_OUTPUT/tool-checks"
mkdir -p "$local_out" "$JOB_TMP/sort"

mount_options=$(findmnt --noheadings --output OPTIONS --target "$MOUNT_PATH" 2>/dev/null || true)
if [[ -z "$mount_options" ]]; then
  mount_options=$(awk -v target="$MOUNT_PATH" '$5 == target {print $6; exit}' /proc/self/mountinfo)
fi
[[ ",$mount_options," == *,ro,* ]] || { log "input mount is not read-only according to mount metadata"; exit 1; }

check R1 read ls mountpoint pass ls -la "$mount_input"
check R2 read stat mountpoint pass stat "$sample"
check R3 read gzip-stream mountpoint pass bash -c 'gzip -cd "$1" | head -n 8 >/dev/null' _ "$sample"
check R4 read random-seek mountpoint pass dd if="$sample" bs=4096 skip=1 count=1 status=none
check R5 pipeline seqkit-stats mountpoint pass seqkit stats --tabular --basename "${inputs[@]}"
check R6 pipeline cutadapt-read mountpoint pass env CUTADAPT_CORES=2 \
  s2_trim.sh "$sample" "$local_out/trimmed.fastq.gz" "$FRONT_PRIMER" "$BACK_PRIMER"
check L1 pipeline count-local-temp local-posix pass env TMPDIR="$JOB_TMP/sort" \
  s3_count.sh "$local_out/trimmed.fastq.gz" "$local_out/counts.tsv"
check L2 pipeline fold-local-output local-posix pass bash -c \
  'cd "$1" && printf ">probe\nGGGAGCAGGAGAGAGGUCAGAUG\n" | RNAfold --noPS >/dev/null' _ "$local_out"

record_disk_usage
s3_cp "$REPORT" "$RUN_S3/compat_report.tsv"
if grep -q 'UNEXPECTED' "$REPORT"; then
  log "one or more compatibility checks had unexpected results"
  exit 1
fi
log "compatibility report uploaded"
