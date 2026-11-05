#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 TRIMMED_FASTQ OUTPUT_TSV" >&2; exit 2; }
input=$1
output=$2
mkdir -p "$(dirname -- "$output")"
tmpdir=${TMPDIR:-"$(dirname -- "$output")/tmp"}
mkdir -p "$tmpdir"

sequence_file=$(mktemp "$tmpdir/sequences.XXXXXX")
counts_file=$(mktemp "$tmpdir/counts.XXXXXX")
trap 'rm -f "$sequence_file" "$counts_file"' EXIT

seqkit seq --seq-type dna --seq --line-width 0 "$input" \
  | tr '[:lower:]' '[:upper:]' > "$sequence_file"
LC_ALL=C sort --temporary-directory="$tmpdir" "$sequence_file" \
  | uniq -c > "$counts_file"
total=$(awk '{sum += $1} END {print sum + 0}' "$counts_file")
((total > 0)) || { echo "no trimmed reads in $input" >&2; exit 1; }

{
  printf 'sequence\tcount\trpm\n'
  awk -v total="$total" \
    '{printf "%s\t%d\t%.6f\n", $2, $1, ($1 * 1000000.0 / total)}' \
    "$counts_file" \
    | LC_ALL=C sort -t $'\t' -k2,2nr -k1,1
} > "$output"
