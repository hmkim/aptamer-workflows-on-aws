#!/usr/bin/env bash
# Generic one-off loader. Downloads manifest entries inside Batch, verifies MD5, and uploads inputs.
set -Eeuo pipefail
export SCENARIO=${SCENARIO:-loader}
export RUN_ID=${RUN_ID:-manifest}
source "$(dirname -- "${BASH_SOURCE[0]}")/job_common.sh"

MANIFEST=${MANIFEST:-/opt/aptamer/data/dra009383_manifest.tsv}
if [[ -n "${MANIFEST_S3_URI:-}" ]]; then
  : "${MANIFEST_SHA256:?Set MANIFEST_SHA256 for MANIFEST_S3_URI.}"
  [[ "$MANIFEST_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || { log "invalid MANIFEST_SHA256"; exit 1; }
  expected_manifest_uri="s3://${WORK_BUCKET}/manifests/${MANIFEST_SHA256,,}.tsv"
  [[ "$MANIFEST_S3_URI" == "$expected_manifest_uri" ]] || {
    log "MANIFEST_S3_URI must be the content-addressed key $expected_manifest_uri"
    exit 1
  }
  MANIFEST="$JOB_INPUT/input_manifest.tsv"
  s3_cp "$MANIFEST_S3_URI" "$MANIFEST"
  actual_manifest_sha256=$(sha256sum "$MANIFEST" | cut -d' ' -f1)
  [[ "$actual_manifest_sha256" == "${MANIFEST_SHA256,,}" ]] || {
    log "manifest checksum mismatch"
    exit 1
  }
fi
[[ -f "$MANIFEST" ]] || { log "manifest not found: $MANIFEST"; exit 1; }

download() {
  local url=$1 output=$2
  if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
      --proto '=https' --proto-redir '=https' --output "$output" "$url"
  else
    python3 - "$url" "$output" <<'PY'
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

url, output = sys.argv[1:]
if urllib.parse.urlparse(url).scheme != "https":
    raise SystemExit("manifest URL must use HTTPS")

class HttpsOnlyRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        if urllib.parse.urlparse(new_url).scheme != "https":
            raise urllib.error.HTTPError(new_url, code, "redirect target must use HTTPS", headers, file_pointer)
        return super().redirect_request(request, file_pointer, code, message, headers, new_url)

opener = urllib.request.build_opener(HttpsOnlyRedirectHandler())
for attempt in range(1, 6):
    try:
        with opener.open(url, timeout=120) as response:
            if urllib.parse.urlparse(response.geturl()).scheme != "https":
                raise RuntimeError("redirect target must use HTTPS")
            with open(output, "wb") as stream:
                shutil.copyfileobj(response, stream, 1 << 20)
        break
    except Exception:
        if attempt == 5:
            raise
        time.sleep(5 * attempt)
PY
  fi
}

while IFS=$'\t' read -r round accession label source_name url expected_md5; do
  [[ "$round" == round || -z "$round" ]] && continue
  [[ "$round" =~ ^[0-9]+$ ]] || { log "invalid round in manifest"; exit 1; }
  [[ "$accession" =~ ^[A-Za-z0-9._-]+$ ]] || { log "invalid accession in manifest"; exit 1; }
  [[ "$source_name" =~ ^[A-Za-z0-9._-]+$ ]] || { log "invalid source filename in manifest"; exit 1; }
  [[ "$url" == https://* ]] || { log "manifest URL must use HTTPS"; exit 1; }
  [[ "$expected_md5" =~ ^[a-fA-F0-9]{32}$ ]] || { log "invalid MD5 in manifest"; exit 1; }
  expected_md5=${expected_md5,,}
  name="R${round}_${accession}.fastq.gz"
  local_file="$JOB_INPUT/$name"
  if aws s3api head-object --bucket "$DATA_BUCKET" --key "$DATA_PREFIX/$name" >/dev/null 2>&1; then
    log "verifying existing input $name"
    s3_cp "$INPUT_S3/$name" "$local_file"
    actual_md5=$(md5sum "$local_file" | cut -d' ' -f1)
    [[ "$actual_md5" == "$expected_md5" ]] || {
      log "existing object checksum mismatch for $name; refusing to overwrite it"
      exit 1
    }
    rm -f "$local_file"
    continue
  fi
  log "download $name ($label)"
  timed "download_ms_$name" download "$url" "$local_file.part"
  mv "$local_file.part" "$local_file"
  actual_md5=$(md5sum "$local_file" | cut -d' ' -f1)
  [[ "$actual_md5" == "$expected_md5" ]] || { log "checksum mismatch for $name"; exit 1; }
  s3_cp "$local_file" "$INPUT_S3/$name"
  rm -f "$local_file"
  metric "uploaded_$name" 1 file
done < "$MANIFEST"
log "loader complete"
