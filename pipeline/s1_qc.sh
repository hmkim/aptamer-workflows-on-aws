#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# < 2 || $# > 3 )); then
  echo "usage: $0 INPUT_FILE_OR_DIR OUTPUT_TSV [INPUT_GLOB]" >&2
  exit 2
fi

input=$1
output=$2
input_glob=${3:-'R*_*.fastq.gz'}
[[ "$input_glob" != */* ]] || { echo "INPUT_GLOB must not contain a path separator." >&2; exit 2; }

mkdir -p "$(dirname -- "$output")"
if [[ -f "$input" ]]; then
  reads=("$input")
elif [[ -d "$input" ]]; then
  mapfile -d '' -t reads < <(
    find "$input" -maxdepth 1 -type f -name "$input_glob" -print0 | sort -zV
  )
else
  echo "input not found: $input" >&2
  exit 1
fi

((${#reads[@]} > 0)) || { echo "no files matching $input_glob in $input" >&2; exit 1; }
seqkit stats --tabular --basename "${reads[@]}" > "$output"
