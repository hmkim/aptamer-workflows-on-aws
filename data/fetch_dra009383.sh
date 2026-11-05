#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
manifest=${1:-"$script_dir/dra009383_manifest.tsv"}
destination=${2:-"$script_dir/../inputs/DRA009383"}
mkdir -p "$destination"

partial=""
trap '[[ -z "$partial" ]] || rm -f "$partial"' EXIT

while IFS=$'\t' read -r round run_accession library_name file_name url expected_md5; do
  [[ "$round" == "round" ]] && continue
  [[ "$round" =~ ^[0-9]+$ ]] || { echo "invalid round in manifest: $round" >&2; exit 1; }
  [[ "$run_accession" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid run accession in manifest" >&2; exit 1; }
  [[ "$file_name" == "$(basename -- "$file_name")" && "$file_name" != .* ]] \
    || { echo "invalid file name in manifest: $file_name" >&2; exit 1; }
  [[ "$url" == https://* ]] || { echo "manifest URL must use HTTPS: $url" >&2; exit 1; }
  [[ "$expected_md5" =~ ^[0-9a-fA-F]{32}$ ]] \
    || { echo "invalid MD5 for $run_accession" >&2; exit 1; }

  output="$destination/$file_name"
  partial="$output.part"
  if [[ ! -f "$output" ]]; then
    curl --fail --location --retry 5 --retry-all-errors \
      --proto '=https' --proto-redir '=https' --output "$partial" "$url"
    mv "$partial" "$output"
  fi
  partial=""

  actual_md5=$(md5sum "$output" | cut -d' ' -f1)
  if [[ "$actual_md5" != "${expected_md5,,}" ]]; then
    echo "checksum mismatch: $output (expected ${expected_md5,,}, got $actual_md5)" >&2
    exit 1
  fi
  printf 'verified\tround-%s\t%s\t%s\t%s\n' "$round" "$run_accession" "$library_name" "$output"
done < "$manifest"
