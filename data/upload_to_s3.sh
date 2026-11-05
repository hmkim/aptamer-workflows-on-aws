#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# < 2 || $# > 5 )); then
  echo "usage: $0 REGION BUCKET [PREFIX] [DOWNLOAD_DIR] [MANIFEST]" >&2
  exit 2
fi

region=$1
bucket=$2
prefix=${3:-datasets/DRA009383}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
download_dir=${4:-"$script_dir/../inputs/DRA009383"}
manifest=${5:-"$script_dir/dra009383_manifest.tsv"}

[[ "$bucket" != s3://* && "$bucket" != */* ]] \
  || { echo "BUCKET must be a bucket name, not a URI or path." >&2; exit 2; }
prefix=${prefix#/}
prefix=${prefix%/}
[[ -n "$prefix" ]] || { echo "PREFIX must not be empty." >&2; exit 2; }

read -r block_public_acls ignore_public_acls block_public_policy restrict_public_buckets < <(
  aws s3api get-public-access-block \
    --bucket "$bucket" \
    --region "$region" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
    --output text
)
if [[ "$block_public_acls $ignore_public_acls $block_public_policy $restrict_public_buckets" != "True True True True" ]]; then
  echo "refusing upload: all four bucket-level S3 Block Public Access settings must be enabled" >&2
  exit 1
fi

"$script_dir/fetch_dra009383.sh" "$manifest" "$download_dir"
aws s3 sync "$download_dir/" "s3://${bucket}/${prefix}/" \
  --region "$region" \
  --no-follow-symlinks \
  --only-show-errors
aws s3 ls "s3://${bucket}/${prefix}/" --region "$region" --summarize
