#!/usr/bin/env bash
# Upload an operator-selected manifest to an immutable, content-addressed S3 key.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd aws sha256sum
load_stack_outputs
: "${MANIFEST_PATH:?Set MANIFEST_PATH to a six-column TSV: round, accession, label, filename, URL, MD5.}"
[[ -f "$MANIFEST_PATH" ]] || die "MANIFEST_PATH does not identify a file"

manifest_sha256=$(sha256sum "$MANIFEST_PATH" | cut -d' ' -f1)
manifest_uri="s3://${WORK_BUCKET}/manifests/${manifest_sha256}.tsv"
if aws s3api head-object \
  --bucket "$WORK_BUCKET" \
  --key "manifests/${manifest_sha256}.tsv" \
  --query 'Metadata.sha256' \
  --output text 2>/dev/null | grep -Fxq "$manifest_sha256"; then
  log "verified content-addressed manifest already exists"
else
  aws s3 cp \
    --only-show-errors \
    --metadata "sha256=$manifest_sha256" \
    "$MANIFEST_PATH" \
    "$manifest_uri"
fi
printf 'MANIFEST_S3_URI=%q\nMANIFEST_SHA256=%q\n' "$manifest_uri" "$manifest_sha256"
