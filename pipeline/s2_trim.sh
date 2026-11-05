#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 4 ]] || {
  echo "usage: $0 INPUT_FASTQ OUTPUT_FASTQ FRONT_PRIMER BACK_PRIMER" >&2
  exit 2
}

input=$1
output=$2
front_primer=$3
back_primer=$4
[[ -n "$front_primer" && -n "$back_primer" ]] \
  || { echo "primer sequences must not be empty" >&2; exit 2; }

mkdir -p "$(dirname -- "$output")"
cutadapt \
  --cores "${CUTADAPT_CORES:-0}" \
  --error-rate "${CUTADAPT_ERROR_RATE:-0.12}" \
  --overlap "${CUTADAPT_OVERLAP:-15}" \
  --discard-untrimmed \
  --minimum-length "${MINIMUM_LENGTH:-10}" \
  --maximum-length "${MAXIMUM_LENGTH:-80}" \
  --adapter "${front_primer}...${back_primer}" \
  --output "$output" \
  "$input"
