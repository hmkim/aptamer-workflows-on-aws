#!/usr/bin/env bash
# Run the Nextflow local profile on an EC2 host using local POSIX work storage.
# The script provisions nothing and publishes no network port.
set -Eeuo pipefail

require_env() { [[ -n "${!1:-}" ]] || { echo "set $1" >&2; exit 2; }; }
for name in AWS_REGION INPUT_URI OUTPUT_URI PIPELINE_IMAGE FRONT_PRIMER BACK_PRIMER; do
  require_env "$name"
done
for command_name in aws docker nextflow; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "missing command: $command_name" >&2; exit 2; }
done

[[ "$INPUT_URI" == s3://* ]] || { echo 'INPUT_URI must use s3://' >&2; exit 2; }
[[ "$OUTPUT_URI" == s3://* ]] || { echo 'OUTPUT_URI must use s3://' >&2; exit 2; }
[[ "$PIPELINE_IMAGE" =~ ^[0-9]{12}\.dkr\.ecr\.${AWS_REGION}\.amazonaws\.com(\.cn)?/.+(:[A-Za-z0-9._-]+|@sha256:[a-fA-F0-9]{64})$ ]] \
  || { echo 'PIPELINE_IMAGE must be a tagged or digest-pinned private ECR image in AWS_REGION' >&2; exit 2; }
[[ "$FRONT_PRIMER" =~ ^[ACGTNacgtn]+$ ]] || { echo 'invalid FRONT_PRIMER' >&2; exit 2; }
[[ "$BACK_PRIMER" =~ ^[ACGTNacgtn]+$ ]] || { echo 'invalid BACK_PRIMER' >&2; exit 2; }

run_id=${RUN_ID:-"baseline-$(date -u +%Y%m%dT%H%M%SZ)"}
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo 'invalid RUN_ID' >&2; exit 2; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
work_root=${WORK_ROOT:-"$PWD/ec2-runs"}
run_root="$work_root/$run_id"
[[ ! -e "$run_root" ]] || { echo "run directory exists: $run_root" >&2; exit 1; }
mkdir -p "$run_root/input" "$run_root/output" "$run_root/work" "$run_root/pipeline_info"

aws --region "$AWS_REGION" --no-cli-pager s3 sync \
  "$INPUT_URI" "$run_root/input" \
  --exclude '*' --include 'R*_*.fastq.gz' --only-show-errors
find "$run_root/input" -maxdepth 1 -type f -name 'R*_*.fastq.gz' -print -quit | grep -q . \
  || { echo 'no FASTQ inputs matched R*_*.fastq.gz' >&2; exit 1; }

registry=${PIPELINE_IMAGE%%/*}
trap 'docker logout "$registry" >/dev/null 2>&1 || true' EXIT
aws --region "$AWS_REGION" --no-cli-pager ecr get-login-password \
  | docker login --username AWS --password-stdin "$registry" >/dev/null
docker pull "$PIPELINE_IMAGE" >/dev/null

start_epoch=$(date +%s)
nextflow run "$project_dir/nextflow/main.nf" \
  -profile local \
  --reads "$run_root/input/R*_*.fastq.gz" \
  --front_primer "$FRONT_PRIMER" \
  --back_primer "$BACK_PRIMER" \
  --container "$PIPELINE_IMAGE" \
  --work_uri "$run_root/work" \
  --outdir "$run_root/output" \
  --report_dir "$run_root/pipeline_info"
stop_epoch=$(date +%s)
printf 'metric\tvalue\nrun_seconds\t%d\n' "$((stop_epoch - start_epoch))" > "$run_root/output/baseline_metrics.tsv"

aws --region "$AWS_REGION" --no-cli-pager s3 sync \
  "$run_root/output" "${OUTPUT_URI%/}/$run_id/" --only-show-errors
printf 'Baseline complete: %s/%s/\n' "${OUTPUT_URI%/}" "$run_id"
