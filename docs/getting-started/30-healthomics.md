[English](30-healthomics.md) | [한국어](30-healthomics.ko.md)

# AWS HealthOmics only

**AWS HealthOmics** is a managed service for bioinformatics workflows. You register a workflow definition (here, the Nextflow workflow in `nextflow/`) as a **private workflow**, then start **runs**; HealthOmics provisions compute and storage for each run and removes it afterwards. A **run role** is the IAM role that HealthOmics uses during a run to read inputs, write outputs, and pull the container image.

This guide deploys one stack, `<prefix>-healthomics` (`healthomics/infrastructure.yaml`): a private encrypted S3 bucket, a private ECR repository, a KMS key, and the run role. It does **not** create a VPC. Runs use the default `RESTRICTED` networking mode. An optional [VPC mode](#optional-vpc-networking-mode-not-yet-validated) section follows at the end.

Start with [prerequisites](00-prerequisites.md). You need Docker on your workstation to build the workflow image.

## Step 1: Set variables

```bash
export AWS_REGION='<REGION>'
export PREFIX='aptamer-workflows'
export HO_STACK="$PREFIX-healthomics"
```

## Step 2: Deploy the stack

```bash
scripts/setup-healthomics.sh --prefix "$PREFIX" --region "$AWS_REGION"
```

You should see `deploying aptamer-workflows-healthomics from healthomics/infrastructure.yaml`, then `CREATE_COMPLETE`, an outputs table (`BucketName`, `RepositoryUri`, `PipelineImage`, `RunRoleArn`, `InputPrefix`, `OutputPrefix`, `KmsKeyArn`), and next-step hints.

Options: `--image-tag <tag>` (default `git-<commit>`), `--input-prefix` (default `inputs`), `--output-prefix` (default `outputs`). The run role can read only the input prefix and write only the output prefix.

Read the outputs into variables:

```bash
ho_output() {
  aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$HO_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
export BUCKET_NAME=$(ho_output BucketName)
export REPOSITORY_URI=$(ho_output RepositoryUri)
export IMAGE_WITH_TAG=$(ho_output PipelineImage)
export RUN_ROLE_ARN=$(ho_output RunRoleArn)
```

## Step 3: Build and push the workflow image

`RESTRICTED` mode gives workflow tasks no internet access, so every tool must already be in the image. Build `Dockerfile` and push it to the private repository:

```bash
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${REPOSITORY_URI%%/*}"
docker build --platform linux/amd64 --tag "$IMAGE_WITH_TAG" .
docker push "$IMAGE_WITH_TAG"
```

You should see `Login Succeeded`, then the push progress ending with a `digest: sha256:...` line. The repository has immutable tags: pushing a different image under the same tag fails. Use a new `--image-tag` in step 2 for a new build.

Pin the run to the image digest, not the tag:

```bash
DIGEST=$(aws ecr describe-images --region "$AWS_REGION" --repository-name "${REPOSITORY_URI#*/}" \
  --image-ids "imageTag=${IMAGE_WITH_TAG##*:}" --query 'imageDetails[0].imageDigest' --output text)
export PIPELINE_IMAGE="$REPOSITORY_URI@$DIGEST"
echo "$PIPELINE_IMAGE"
```

You should see `<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<repository>@sha256:<64 hex characters>`.

## Step 4: Upload the public D1 data

This downloads D1 to `inputs/DRA009383/` (checking each MD5), refuses to continue unless the bucket blocks all public access, and copies the files to the input prefix:

```bash
bash data/upload_to_s3.sh "$AWS_REGION" "$BUCKET_NAME" inputs/DRA009383
```

You should see a listing that ends with `Total Objects: 9`.

HealthOmics needs a samplesheet with complete S3 URIs. Create it from the D1 samplesheet and upload it:

```bash
awk -v base="s3://$BUCKET_NAME/inputs/DRA009383/" 'BEGIN { FS = OFS = "\t" }
  NR == 1 { print; next } { print $1, base $2 }' \
  nextflow/samplesheet.dra009383.tsv > inputs/samplesheet.healthomics.tsv
aws s3 cp inputs/samplesheet.healthomics.tsv "s3://$BUCKET_NAME/inputs/samplesheet.tsv" \
  --region "$AWS_REGION" --only-show-errors
export SAMPLESHEET_URI="s3://$BUCKET_NAME/inputs/samplesheet.tsv"
head -3 inputs/samplesheet.healthomics.tsv
```

You should see the header `round	file` and lines such as `0	s3://<bucket>/inputs/DRA009383/R0_DRR201861.fastq.gz`.

## Step 5: Register the private workflow

```bash
WORKFLOW_NAME=aptamer-workflow healthomics/orchestrate.sh register
```

The script zips `nextflow/main.nf` and its config, calls `create-workflow`, waits until the workflow is `ACTIVE`, and prints `id`, `arn`, `status`, `engine`, and `storageType`. The workflow ID is saved in the ignored `healthomics/.state/` directory, so later commands find it.

## Step 6: Start a run

```bash
source data/dra009383.env.example
export RUN_NAME="d1-$(date -u +%Y%m%d%H%M)"
healthomics/orchestrate.sh run
```

You should see JSON with `id`, `arn`, `status` (`PENDING`), `name` and `outputUri`. Defaults: `--networking-mode RESTRICTED`, dynamic run storage, `RETENTION_MODE=RETAIN`, `LOG_LEVEL=ALL`, output below `s3://<BucketName>/outputs/<RUN_NAME>/`. See [healthomics/README.md](../../healthomics/README.md) for every variable.

## Step 7: Check the run

```bash
healthomics/orchestrate.sh status
```

Without an argument it reads the last run ID. You should see the run status move from `PENDING` and `STARTING` to `RUNNING` and then `COMPLETED`, followed by a table of tasks. In the console: AWS HealthOmics, Runs. When the run is complete, list the outputs:

```bash
aws s3 ls "s3://$BUCKET_NAME/outputs/$RUN_NAME/" --region "$AWS_REGION" --recursive
```

You should find `<run id>/pubdir/enrich/top_candidates.tsv` below the run's output folder (HealthOmics adds the run ID and `pubdir/`), next to `qc/`, `trimmed/`, `counts/`, `fold/` and `checksums.sha256`. In the validation run its sorted SHA-256 matched the Batch copy-in result for the same D1 data. Compare it with other runs using [the validation guide](../validation.md).

## Optional: VPC networking mode (not yet validated)

> **Not yet validated in this repository.** The steps below follow the official AWS documentation, but nobody has run them end to end here. Use `RESTRICTED` mode unless your workflow needs more network access. Results will be added after validation.

By default (`RESTRICTED`), a run can reach only Amazon S3 and Amazon ECR in the same Region. **VPC mode** sends run traffic through network interfaces that HealthOmics creates in your subnets, so a run can reach resources in your VPC and, through a NAT gateway, the internet. Facts from the AWS documentation ([VPC networking](https://docs.aws.amazon.com/omics/latest/dev/workflows-vpc-networking.html), [internet access](https://docs.aws.amazon.com/omics/latest/dev/workflows-vpc-internet.html), [interface endpoints](https://docs.aws.amazon.com/omics/latest/dev/vpc-interface-endpoints.html)):

- You enable VPC mode with a HealthOmics **configuration** (subnets and security groups), then start runs with `--networking-mode VPC --configuration-name <name>`.
- A configuration takes 1 to 16 subnets, **at most one per Availability Zone**, in AZs where HealthOmics operates, and 1 to 5 security groups, all from one VPC. It goes from `CREATING` to `ACTIVE` in up to 15 minutes. Configurations cannot be changed; the default limit is 10 per account per Region.
- The first configuration creates the service-linked role `AWSServiceRoleForHealthOmics`. Your identity needs `iam:CreateServiceLinkedRole` for `omics.amazonaws.com`.
- A public subnet does not give a run internet access. Use private subnets with a route to a NAT gateway, as the [shared network](10-network.md) provides.
- An S3 gateway endpoint is optional: in-Region S3 traffic goes through the HealthOmics service network by default.
- **Interface endpoints** (AWS PrivateLink) are a different feature: they let clients inside your VPC call the HealthOmics APIs privately. VPC-mode runs do not need them. Each endpoint is billed per hour per AZ. Not every HealthOmics API (workflows, storage, analytics) is offered in every Region; check the [endpoints list](https://docs.aws.amazon.com/general/latest/gr/healthomics-quotas.html) before enabling them.

Deploy the VPC pieces. This creates the shared network when it is missing (choose AZs first with [the network guide](10-network.md) if needed):

```bash
scripts/setup-healthomics.sh --prefix "$PREFIX" --region "$AWS_REGION" --vpc
```

Options: `--configuration-name <name>` (default `<prefix>-vpc`), `--interface-endpoints` (create PrivateLink endpoints; default `workflows-omics` only), `--endpoint-services <list>` (choose from `workflows-omics,storage-omics,control-storage-omics,analytics-omics,tags-omics`; the script checks Region availability first), `--configuration-by-script` (create the configuration with `healthomics/vpc/omics-vpc-configuration.sh` instead of CloudFormation).

You should see `HealthOmics VPC networking mode is NOT YET VALIDATED in this repository`, the stack `<prefix>-healthomics-vpc` reach `CREATE_COMPLETE`, and the configuration reach `ACTIVE`. The stack adds a run security group with HTTPS (TCP 443) egress only and no ingress. Check the configuration:

**Hardened use:** the run security group allows TCP 443 to `0.0.0.0/0`. If your runs need only AWS services, restrict its egress in `healthomics/vpc/vpc.yaml` to VPC endpoints or prefix lists.

```bash
healthomics/vpc/omics-vpc-configuration.sh status --region "$AWS_REGION" --name "$PREFIX-vpc"
```

Start a run in VPC mode with the same variables as step 6:

```bash
healthomics/orchestrate.sh run --networking-mode VPC --configuration-name "$PREFIX-vpc"
```

Details: [healthomics/vpc/README.md](../../healthomics/vpc/README.md).

## Validated on

`RESTRICTED` mode validated on 2026-11-26 in us-west-2 with a new prefix: steps 2 to 7 on D1 passed, and the result matched the Batch copy-in result. Details: [the validation guide](../validation.md#validated-on). VPC mode stays not yet validated.

## Next

- [Add AWS Batch](40-both.md#one-after-another)
- [Clean up](90-cleanup.md); HealthOmics workflows and the retained bucket need separate steps
