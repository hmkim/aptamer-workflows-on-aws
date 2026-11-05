#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# < 4 || $# > 7 )); then
  echo "usage: $0 INPUT_DIR OUTPUT_DIR FRONT_PRIMER BACK_PRIMER [TOP_CANDIDATES] [INPUT_GLOB] [ROUND_REGEX]" >&2
  exit 2
fi

input_dir=$(realpath -- "$1")
mkdir -p "$2"
output_dir=$(realpath -- "$2")
front_primer=$3
back_primer=$4
top_candidates=${5:-100}
input_glob=${6:-'R*_*.fastq.gz'}
round_regex=${7:-'^R([0-9]+)_'}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

[[ "$top_candidates" =~ ^[1-9][0-9]*$ ]] \
  || { echo "TOP_CANDIDATES must be a positive integer." >&2; exit 2; }
[[ "$input_glob" != */* ]] \
  || { echo "INPUT_GLOB must not contain a path separator." >&2; exit 2; }

mapfile -d '' -t inputs < <(
  find "$input_dir" -maxdepth 1 -type f -name "$input_glob" -print0 | sort -zV
)
((${#inputs[@]} > 0)) \
  || { echo "no files matching $input_glob in $input_dir" >&2; exit 1; }

mkdir -p "$output_dir"/{qc,trimmed,counts,enrich,fold,logs,tmp}
"$script_dir/s1_qc.sh" "$input_dir" "$output_dir/qc/stats.tsv" "$input_glob"

declare -A seen_rounds=()
for input in "${inputs[@]}"; do
  sample=$(basename -- "$input")
  if [[ ! "$sample" =~ $round_regex ]]; then
    echo "cannot extract a round number from $sample with ROUND_REGEX=$round_regex" >&2
    exit 1
  fi
  round_number=${BASH_REMATCH[1]}
  [[ "$round_number" =~ ^[0-9]+$ ]] \
    || { echo "ROUND_REGEX capture must be numeric: $round_number" >&2; exit 1; }
  round_name="R${round_number}"
  [[ -z "${seen_rounds[$round_number]:-}" ]] \
    || { echo "more than one input matched round $round_number" >&2; exit 1; }
  seen_rounds[$round_number]=1

  "$script_dir/s2_trim.sh" \
    "$input" \
    "$output_dir/trimmed/${round_name}.fastq.gz" \
    "$front_primer" \
    "$back_primer" \
    > "$output_dir/logs/${round_name}.cutadapt.log" 2>&1
  TMPDIR="$output_dir/tmp/${round_name}" \
    "$script_dir/s3_count.sh" \
    "$output_dir/trimmed/${round_name}.fastq.gz" \
    "$output_dir/counts/${round_name}.tsv"
done

"$script_dir/enrich.py" \
  --counts-dir "$output_dir/counts" \
  --output-dir "$output_dir/enrich" \
  --counts-pattern 'R*.tsv' \
  --round-regex '^R([0-9]+)$' \
  --top-candidates "$top_candidates"
"$script_dir/s5_fold.sh" \
  "$output_dir/enrich/top_candidates.tsv" \
  "$output_dir/fold/top_candidates.fold"

(
  cd "$output_dir"
  find qc trimmed counts enrich fold -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum > checksums.sha256
)
printf 'pipeline complete: %s\n' "$output_dir"
