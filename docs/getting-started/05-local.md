[English](05-local.md) | [한국어](05-local.ko.md)

# Local run and EC2 baseline

Run the workflow on one machine first. The result becomes the reference that you compare with AWS Batch, Nextflow, and HealthOmics runs. No AWS resources are needed for the local Docker run.

## Quick start: local Bash in Docker

Clone the repository and enter it:

```bash
git clone 'https://github.com/<GITHUB_ORGANIZATION>/aptamer-workflows-on-aws.git'
cd aptamer-workflows-on-aws
```

Download D1 from the public archive and verify every file against the manifest checksum:

```bash
bash data/fetch_dra009383.sh data/dra009383_manifest.tsv inputs/DRA009383
```

You should see nine `R<round>_DRR<number>.fastq.gz` files under `inputs/DRA009383/`.

Build the image and prepare an output directory:

```bash
docker build --tag aptamer-workflow:local .
mkdir -p outputs/bash-d1
```

Load the published D1 primer configuration. Review the linked study before using these values for any other dataset:

```bash
source data/dra009383.env.example
```

Run the complete Bash pipeline. The input mount is read-only and the output mount is writable:

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --volume "$PWD/inputs/DRA009383:/work/inputs:ro" \
  --volume "$PWD/outputs/bash-d1:/work/outputs" \
  aptamer-workflow:local \
  run_pipeline.sh \
  /work/inputs \
  /work/outputs \
  "$FRONT_PRIMER" \
  "$BACK_PRIMER" \
  100 \
  'R*_*.fastq.gz' \
  '^R([0-9]+)_'
```

Inspect the ranked candidates and verify the generated checksums:

```bash
column -ts $'\t' outputs/bash-d1/enrich/top_candidates.tsv | sed -n '1,11p'
cd outputs/bash-d1
sha256sum --check checksums.sha256
cd ../..
```

You should see a header row and up to ten ranked sequences, then `OK` for every checksum line.

A successful command proves that files were processed as configured. It does not prove that the primer choices or scientific conclusions are correct.

## Bash on an existing EC2 instance

Amazon EC2 provides virtual machines. The helper in `ec2/run_baseline.sh` uses an existing private instance, local POSIX work storage, a private Amazon ECR image, and private S3 inputs and outputs. **Amazon ECR** is private container image storage. The helper does not create an instance, open a network port, or change a security group. See [ec2/README.md](../../ec2/README.md).

The EC2 helper expects S3 object names in the form `R<number>_<name>.fastq.gz`. Convert the downloaded D1 names while uploading them:

```bash
export AWS_REGION='<AWS_REGION>'
export INPUT_BUCKET='<PRIVATE_INPUT_BUCKET>'
export INPUT_PREFIX='<INPUT_PREFIX>'

for SOURCE_PATH in inputs/DRA009383/R*_*.fastq.gz; do
  SOURCE_NAME=$(basename "$SOURCE_PATH")
  aws s3 cp \
    "$SOURCE_PATH" \
    "s3://$INPUT_BUCKET/$INPUT_PREFIX/$SOURCE_NAME" \
    --region "$AWS_REGION" \
    --only-show-errors
done
```

On the EC2 instance, from the repository root, run:

```bash
export AWS_REGION='<AWS_REGION>'
export INPUT_URI='s3://<PRIVATE_INPUT_BUCKET>/<INPUT_PREFIX>/'
export OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/'
export PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>'
export FRONT_PRIMER='<FRONT_PRIMER_DNA>'
export BACK_PRIMER='<BACK_PRIMER_DNA>'
export RUN_ID='<UNIQUE_RUN_ID>'
export WORK_ROOT="$HOME/aptamer-runs"

bash ec2/run_baseline.sh
```

Use private subnets, no inbound security-group rules, encrypted storage, and AWS Systems Manager Session Manager instead of SSH when that service fits your operating model. Grant the instance role only the required S3 prefixes and ECR repository.

## Next

- [Prerequisites](00-prerequisites.md) before any AWS path
- [Validation guide](../validation.md) to compare this baseline with other runs
