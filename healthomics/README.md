[English](README.md) | [한국어](README.ko.md)

# AWS HealthOmics orchestration

This directory packages and launches the same workflow in `../nextflow/` as an AWS HealthOmics private workflow. HealthOmics is an AWS managed service for running bioinformatics workflows.

Nothing runs automatically. `orchestrate.sh` provides `package`, `register`, `run`, and `status`; it has no delete operation.

## Security model

- `infrastructure.yaml` creates an S3 bucket with all four Block Public Access settings, enforced bucket ownership, versioning, TLS-only access, and KMS encryption.
- The container repository is private ECR with immutable tags and image scanning.
- The run role can read only the configured input prefix, write only the configured output prefix, use one encryption key, and pull from one repository.
- The run command always passes `--workflow-type PRIVATE` and defaults to `--networking-mode RESTRICTED`. `--networking-mode VPC --configuration-name <name>` is optional and **not yet validated**; see [`vpc/README.md`](vpc/README.md).
- Restricted networking prevents workflow tasks from reaching the public internet. Put every tool and dependency in the container image before launch.
- Runtime workflow and run identifiers are written only to the ignored `healthomics/.state/` directory with owner-only permissions.

The template retains the bucket, key, and repository if the stack is deleted. This protects data from accidental stack deletion, but it also means those resources require a separate, deliberate cleanup.

## Prerequisites

- AWS CLI v2 with HealthOmics support
- `jq`, `zip`, and `sha256sum`
- A tagged workflow container already pushed to the stack's private ECR repository
- A samplesheet uploaded to private S3. Each `file` value must be a complete S3 object URI.

Example samplesheet:

```text
round	file
0	s3://<PRIVATE_BUCKET>/<INPUT_PREFIX>/R0_sample.fastq.gz
1	s3://<PRIVATE_BUCKET>/<INPUT_PREFIX>/R1_sample.fastq.gz
```

## Validate locally

```bash
bash -n orchestrate.sh
python3 -m json.tool parameter-template.json >/dev/null
python3 -m json.tool run-parameters.example.json >/dev/null
aws cloudformation validate-template \
  --region '<AWS_REGION>' \
  --template-body 'file://infrastructure.yaml'
```

The final command calls AWS only to parse the template. It does not create resources.

## Deploy private resources

Review the template and choose the target AWS account and Region before running this write operation:

```bash
aws cloudformation deploy \
  --region '<AWS_REGION>' \
  --stack-name '<STACK_NAME>' \
  --template-file infrastructure.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    InputPrefix='<INPUT_PREFIX>' \
    OutputPrefix='<OUTPUT_PREFIX>' \
    ImageTag='<IMAGE_TAG>'
```

Read the generated values without committing them:

```bash
aws cloudformation describe-stacks \
  --region '<AWS_REGION>' \
  --stack-name '<STACK_NAME>' \
  --query 'Stacks[0].Outputs' \
  --output table
```

## Package and register

```bash
AWS_REGION='<AWS_REGION>' \
WORKFLOW_NAME='<WORKFLOW_NAME>' \
./orchestrate.sh package
```

```bash
AWS_REGION='<AWS_REGION>' \
WORKFLOW_NAME='<WORKFLOW_NAME>' \
STORAGE_TYPE='DYNAMIC' \
./orchestrate.sh register
```

The registration command stores the generated workflow ID under `.state/`. To avoid local state, set `WORKFLOW_ID` explicitly for later commands.

## Run

The following command assumes the samplesheet object and every referenced FASTQ object already exist in the private bucket:

```bash
AWS_REGION='<AWS_REGION>' \
WORKFLOW_ID='<WORKFLOW_ID>' \
BUCKET_NAME='<PRIVATE_BUCKET>' \
SAMPLESHEET_URI='s3://<PRIVATE_BUCKET>/<INPUT_PREFIX>/samplesheet.tsv' \
PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>' \
RUN_ROLE_ARN='<HEALTHOMICS_RUN_ROLE_ARN>' \
OUTPUT_PREFIX='<OUTPUT_PREFIX>' \
RUN_NAME='<RUN_NAME>' \
FRONT_PRIMER='<FRONT_PRIMER_DNA>' \
BACK_PRIMER='<BACK_PRIMER_DNA>' \
SCRATCH_STORAGE_MODE='SHARED' \
RETENTION_MODE='RETAIN' \
LOG_LEVEL='ALL' \
./orchestrate.sh run
```

The script verifies that the ECR image URI names the selected Region. Replace primer placeholders with DNA sequences containing only A, C, G, T, or N.

### Run options

| Option or variable | Default | Meaning |
|---|---|---|
| `--networking-mode` / `NETWORKING_MODE` | `RESTRICTED` | `RESTRICTED` or `VPC` (VPC is not yet validated) |
| `--configuration-name` / `CONFIGURATION_NAME` | none | HealthOmics configuration name; required for `VPC` |

## Stack outputs

`BucketName`, `RepositoryUri`, `PipelineImage`, `RunRoleArn`, `InputPrefix`, `OutputPrefix`, `KmsKeyArn`.

## Inspect a run

```bash
AWS_REGION='<AWS_REGION>' \
./orchestrate.sh status '<RUN_ID>'
```

This reads run and task status. It does not download logs or outputs.

## Glossary

- **ECR:** Amazon Elastic Container Registry, private storage for container images.
- **HealthOmics private workflow:** a workflow definition visible only through authorized AWS API access.
- **KMS:** AWS Key Management Service, which controls the encryption key used for S3 objects.
- **Restricted networking:** a run mode that blocks workflow tasks from public internet access.
- **Run role:** the IAM role assumed by HealthOmics to read inputs, write outputs, and pull the image.
- **S3 prefix:** the leading folder-like part of an S3 object key used to limit access.
