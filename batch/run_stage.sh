#!/usr/bin/env bash
# Run S1-S5 as separate jobs. S1-S3 are N_TO_N array stages; S4-S5 are single jobs.
set -Eeuo pipefail
export SCENARIO=${SCENARIO:-dependencies}
STAGE=${1:-${STAGE:-}}
[[ "$STAGE" =~ ^S[1-5]$ ]] || { echo "usage: $0 S1|S2|S3|S4|S5" >&2; exit 2; }
export STAGE
source "$(dirname -- "${BASH_SOURCE[0]}")/job_common.sh"

result="$JOB_OUTPUT/result"
mkdir -p "$result"
require_round() {
  [[ -n "$ARRAY_INDEX" ]] || { log "$STAGE requires an array-job index"; exit 2; }
  ROUND="R$ARRAY_INDEX"
}
fetch_round_input() {
  timed copy_in_ms s3_sync --exclude '*' --include "${ROUND}_*.fastq.gz" "$INPUT_S3/" "$JOB_INPUT/"
  mapfile -t found < <(find "$JOB_INPUT" -maxdepth 1 -name "${ROUND}_*.fastq.gz")
  [[ ${#found[@]} -eq 1 ]] || { log "expected one input for $ROUND; found ${#found[@]}"; exit 1; }
  ROUND_INPUT=${found[0]}
}
merge_stats() {
  mapfile -t parts < <(find "$result/qc" -maxdepth 1 -name 'R*.stats.tsv' | sort -V)
  ((${#parts[@]} > 0)) || { log "no per-round statistics were found"; exit 1; }
  { head -n 1 "${parts[0]}"; for part in "${parts[@]}"; do tail -n +2 "$part"; done; } > "$result/qc/stats.tsv"
}

case "$STAGE" in
  S1)
    require_round; fetch_round_input; mkdir -p "$result/qc"
    timed stage_ms s1_qc.sh "$JOB_INPUT" "$result/qc/$ROUND.stats.tsv" 'R*_*.fastq.gz'
    timed upload_ms s3_cp "$result/qc/$ROUND.stats.tsv" "$RESULT_S3/qc/$ROUND.stats.tsv"
    ;;
  S2)
    require_round; fetch_round_input; mkdir -p "$result/trimmed" "$result/logs"
    : "${FRONT_PRIMER:?Set FRONT_PRIMER.}"
    : "${BACK_PRIMER:?Set BACK_PRIMER.}"
    timed stage_ms bash -c 's2_trim.sh "$1" "$2" "$3" "$4" > "$5" 2>&1' _ \
      "$ROUND_INPUT" "$result/trimmed/$ROUND.fastq.gz" "$FRONT_PRIMER" "$BACK_PRIMER" \
      "$result/logs/$ROUND.cutadapt.log"
    timed upload_ms s3_sync "$result/" "$RESULT_S3/"
    ;;
  S3)
    require_round; mkdir -p "$result/counts" "$JOB_TMP/$ROUND"
    timed copy_in_ms s3_cp "$RESULT_S3/trimmed/$ROUND.fastq.gz" "$JOB_INPUT/$ROUND.fastq.gz"
    TMPDIR="$JOB_TMP/$ROUND" timed stage_ms s3_count.sh "$JOB_INPUT/$ROUND.fastq.gz" "$result/counts/$ROUND.tsv"
    timed upload_ms s3_cp "$result/counts/$ROUND.tsv" "$RESULT_S3/counts/$ROUND.tsv"
    ;;
  S4)
    mkdir -p "$result/qc" "$result/enrich"
    timed copy_in_ms s3_sync "$RESULT_S3/counts/" "$result/counts/"
    timed copy_in_qc_ms s3_sync --exclude '*' --include 'R*.stats.tsv' "$RESULT_S3/qc/" "$result/qc/"
    merge_stats
    TOP_CANDIDATES=${TOP_CANDIDATES:-100}
    timed stage_ms enrich.py \
      --counts-dir "$result/counts" \
      --output-dir "$result/enrich" \
      --counts-pattern 'R*.tsv' \
      --round-regex '^R([0-9]+)$' \
      --top-candidates "$TOP_CANDIDATES"
    timed upload_ms bash -c 'aws s3 cp --only-show-errors "$1" "$2" && aws s3 sync --only-show-errors "$3/" "$4/"' _ \
      "$result/qc/stats.tsv" "$RESULT_S3/qc/stats.tsv" "$result/enrich" "$RESULT_S3/enrich"
    ;;
  S5)
    mkdir -p "$result/fold" "$result/enrich"
    timed copy_in_ms s3_cp "$RESULT_S3/enrich/top_candidates.tsv" "$result/enrich/top_candidates.tsv"
    timed stage_ms s5_fold.sh "$result/enrich/top_candidates.tsv" "$result/fold/top_candidates.fold"
    timed upload_ms s3_cp "$result/fold/top_candidates.fold" "$RESULT_S3/fold/top_candidates.fold"
    timed checksum_sync_ms s3_sync --exclude 'tmp/*' --exclude 'checksums.sha256' "$RESULT_S3/" "$result/"
    (cd "$result" && { printf 'qc/stats.tsv\0'; find counts enrich fold trimmed -type f -print0; } \
      | sort -z | xargs -0 sha256sum > checksums.sha256)
    s3_cp "$result/checksums.sha256" "$RESULT_S3/checksums.sha256"
    ;;
esac
record_disk_usage
log "stage $STAGE complete"
