#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 RANKED_CANDIDATES_TSV OUTPUT_FILE" >&2; exit 2; }
input=$1
output=$2
mkdir -p "$(dirname -- "$output")"

awk -F '\t' 'NR > 1 {print ">rank_" $1 "\n" $2}' "$input" \
  | tr 'T' 'U' \
  | RNAfold --noPS > "$output"
