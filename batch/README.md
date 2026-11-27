[English](README.md) | [한국어](README.ko.md)

# AWS Batch implementation

This directory runs the aptamer workflow on AWS Batch with three execution patterns and a separate input loader. Nothing deploys or submits automatically.

| Pattern | Submit script | Data path |
|---|---|---|
| Copy-in | `submit_copyin.sh` | S3 input copied to local POSIX scratch before processing |
| Stage dependencies | `submit_steps.sh` | S1-S3 array jobs use `N_TO_N`; S4 and S5 depend on the completed prior stage |
| Mountpoint input | `submit_mountpoint.sh` | Read-only S3 input mount; local POSIX temporary files and outputs |
| Compatibility report | `submit_compat.sh` | Read and pipeline probes against Mountpoint after a metadata-only read-only check |
| Input loader | `submit_loader.sh` | Manifest-driven download, MD5 verification, encrypted S3 upload |

POSIX means the standard file behavior expected by Linux tools, including modifying, renaming, linking, and locking files. Mountpoint for Amazon S3 is not a fully POSIX-compliant file system. A tool can fail depending on its file-access pattern. This implementation therefore treats Mountpoint as input-only and read-only. Every temporary file and output uses local POSIX storage before upload to S3. Run the compatibility job before relying on a new tool or input format. Use the copy-in pattern when a tool needs POSIX behavior for its inputs.

## Infrastructure

`network.yaml` creates two private subnets and a NAT gateway. Batch compute must use these private subnets. The NAT subnet does not assign public IP addresses automatically, and the Batch security group has no inbound rules. There is no SSH rule or key pair.

`infrastructure.yaml` creates:

* a rotating KMS key;
* separate data and work buckets with S3 Block Public Access, bucket-owner-enforced object ownership, versioning, KMS encryption, and TLS-only bucket policies;
* a private ECR repository and CodeBuild image project;
* an S3 gateway endpoint;
* least-privilege compute, pipeline-job, loader-job, and image-build roles;
* an EC2 launch template with encrypted storage, required IMDSv2, and metadata hop limit 1;
* a managed EC2 Batch compute environment, queue, log group, and three job definitions.

### Compute and RaptGen parameters

| Parameter | Default | Meaning |
|---|---|---|
| `EnableCpu` | `true` | CPU compute environment and `<stack>-queue`, CodeBuild image project, and the three pipeline job definitions |
| `EnableGpu` | `false` | GPU compute environment (`ECS_AL2023_NVIDIA` AMI) and `<stack>-gpu-queue` |
| `MaxvCpus` / `InstanceTypes` | `72` / `c7i,c6i` | CPU compute environment only |
| `GpuMaxvCpus` / `GpuInstanceTypes` | `8` / `g5.xlarge,g6.xlarge` | GPU compute environment only; needs G-family On-Demand vCPU quota |
| `ImageTag`, `MountpointVersion`, `MountpointPackageSha256` | empty | Required when `EnableCpu=true`; ignored for GPU only |

A `Rules` block rejects `EnableCpu=false` with `EnableGpu=false`. Both compute environments use the same private subnets, security group, instance role, IMDSv2 settings, and encrypted root volume. Only CPU hosts mount the read-only S3 input.

| Output | Present when |
|---|---|
| `JobQueueName` | always: CPU queue if CPU is enabled, otherwise GPU queue |
| `CpuJobQueueName`, `PipelineJobDefinitionArn`, `MountpointJobDefinitionArn`, `DataLoaderJobDefinitionArn`, `ImageBuildProjectName` | `EnableCpu=true` |
| `GpuJobQueueName` | `EnableGpu=true` |
| `RaptgenCpuRepositoryUri`, `RaptgenGpuRepositoryUri`, `RepositoryUri`, `PipelineJobRoleArn`, `DataBucketName`, `WorkBucketName`, `LogGroupName`, `KmsKeyArn`, `ComputeSecurityGroupId`, `CpuEnabled`, `GpuEnabled` | always |

The ECR repositories, buckets, KMS key, and log group are retained when the stack is deleted. `network.yaml` outputs `VpcId`, `PrivateSubnetIds`, `PrivateRouteTableIds`, `VpcCidr`, and `PrivateSubnetAvailabilityZones`; optional `AvailabilityZone1`/`AvailabilityZone2` parameters pin the two private subnets to Availability Zones where HealthOmics operates.

The stack derives account, partition, Region, bucket, ECR, and resource names at deployment time. `ProjectTag`, `JobNamePrefix`, `DataPrefix`, and capacity settings are parameters. Operators provide stack names and Regions through environment variables rather than editing files.

## Deployment inputs

Deploy `network.yaml` first. Pass its `VpcId`, `PrivateSubnetIds`, and `PrivateRouteTableIds` outputs to `infrastructure.yaml`. The private subnets need outbound HTTPS through the NAT gateway because the loader downloads public data and hosts install Mountpoint during bootstrap.

Example placeholders below are intentionally not runnable until they are replaced:

```bash
aws cloudformation deploy \
  --region <AWS_REGION> \
  --stack-name <NETWORK_STACK_NAME> \
  --template-file batch/network.yaml \
  --parameter-overrides ProjectTag=<PROJECT_TAG>

aws cloudformation deploy \
  --region <AWS_REGION> \
  --stack-name <BATCH_STACK_NAME> \
  --template-file batch/infrastructure.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    VpcId=<VPC_ID> \
    PrivateSubnetIds=<PRIVATE_SUBNET_1>,<PRIVATE_SUBNET_2> \
    PrivateRouteTableIds=<PRIVATE_ROUTE_TABLE_1>,<PRIVATE_ROUTE_TABLE_2> \
    ProjectTag=<PROJECT_TAG> \
    JobNamePrefix=<JOB_NAME_PREFIX> \
    DataPrefix=<DATA_PREFIX> \
    ImageTag=<IMMUTABLE_IMAGE_TAG> \
    MountpointVersion=<MOUNTPOINT_VERSION> \
    MountpointPackageSha256=<MOUNTPOINT_RPM_SHA256>
```

The image project reads `build/context.zip` from the data bucket. The job scripts are baked into the immutable image; Batch never downloads executable scripts from a mutable S3 prefix.

Package the tracked repository files, upload the build context, start CodeBuild, and wait for the terminal status:

```bash
export AWS_REGION=<AWS_REGION>
export BATCH_STACK_NAME=<BATCH_STACK_NAME>
export BUILD_CONTEXT=/tmp/aptamer-workflow-context.zip
export DATA_BUCKET=$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$BATCH_STACK_NAME" --query 'Stacks[0].Outputs[?OutputKey==`DataBucketName`].OutputValue | [0]' --output text)
export BUILD_PROJECT=$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$BATCH_STACK_NAME" --query 'Stacks[0].Outputs[?OutputKey==`ImageBuildProjectName`].OutputValue | [0]' --output text)

git archive --format=zip --output "$BUILD_CONTEXT" HEAD
aws s3 cp "$BUILD_CONTEXT" "s3://$DATA_BUCKET/build/context.zip" --region "$AWS_REGION" --only-show-errors
export BUILD_ID=$(aws codebuild start-build --region "$AWS_REGION" --project-name "$BUILD_PROJECT" --query 'build.id' --output text)
while true; do
  BUILD_STATUS=$(aws codebuild batch-get-builds --region "$AWS_REGION" --ids "$BUILD_ID" --query 'builds[0].buildStatus' --output text)
  printf 'CodeBuild status: %s\n' "$BUILD_STATUS"
  case "$BUILD_STATUS" in
    SUCCEEDED) break ;;
    FAILED|FAULT|STOPPED|TIMED_OUT) exit 1 ;;
    *) sleep 15 ;;
  esac
done
```

## Upload and run

All operator scripts require `AWS_REGION` and `STACK_NAME`. Pipeline and compatibility submissions also require `FRONT_PRIMER` and `BACK_PRIMER`; `TOP_CANDIDATES` defaults to `100`. The manifest must be a tab-separated file with the header and columns `round`, `run_accession`, `library_name`, `file_name`, `url`, and `md5` (see `data/dra009383_manifest.tsv`). The loader validates the source filename but writes each object as `R<round>_<run_accession>.fastq.gz`, which is the pipeline input convention. Round numbers must be contiguous from zero for the stage-array pattern.

For the bundled public D1 manifest, the immutable container already includes the file, so submit the loader directly:

```bash
AWS_REGION=<AWS_REGION> STACK_NAME=<BATCH_STACK_NAME> batch/submit_loader.sh
```

For a custom manifest, upload it to a content-addressed key and pass the returned URI and SHA-256 to the loader:

```bash
mkdir -p batch/runs
AWS_REGION=<AWS_REGION> \
STACK_NAME=<BATCH_STACK_NAME> \
MANIFEST_PATH=<INPUT_MANIFEST_TSV> \
batch/upload_manifest.sh > batch/runs/manifest.env
source batch/runs/manifest.env
AWS_REGION=<AWS_REGION> \
STACK_NAME=<BATCH_STACK_NAME> \
MANIFEST_S3_URI="$MANIFEST_S3_URI" \
MANIFEST_SHA256="$MANIFEST_SHA256" \
batch/submit_loader.sh
```

```bash
AWS_REGION=<AWS_REGION> \
STACK_NAME=<BATCH_STACK_NAME> \
RUN_ID=<RUN_ID> \
FRONT_PRIMER=<FRONT_PRIMER_DNA> \
BACK_PRIMER=<BACK_PRIMER_DNA> \
TOP_CANDIDATES=100 \
batch/submit_copyin.sh

AWS_REGION=<AWS_REGION> \
STACK_NAME=<BATCH_STACK_NAME> \
RUN_ID=<RUN_ID> \
ROUNDS=<ROUND_COUNT> \
FRONT_PRIMER=<FRONT_PRIMER_DNA> \
BACK_PRIMER=<BACK_PRIMER_DNA> \
TOP_CANDIDATES=100 \
batch/submit_steps.sh

AWS_REGION=<AWS_REGION> \
STACK_NAME=<BATCH_STACK_NAME> \
RUN_ID=<RUN_ID> \
FRONT_PRIMER=<FRONT_PRIMER_DNA> \
BACK_PRIMER=<BACK_PRIMER_DNA> \
TOP_CANDIDATES=100 \
batch/submit_mountpoint.sh

AWS_REGION=<AWS_REGION> \
STACK_NAME=<BATCH_STACK_NAME> \
RUN_ID=<RUN_ID> \
FRONT_PRIMER=<FRONT_PRIMER_DNA> \
BACK_PRIMER=<BACK_PRIMER_DNA> \
batch/submit_compat.sh
AWS_REGION=<AWS_REGION> STACK_NAME=<BATCH_STACK_NAME> RUN_ID=<RUN_ID> batch/collect_results.sh
```

If a stage needs a manual rerun after changing code or parameters, submit a new `RUN_ID` through `submit_steps.sh`. This keeps the downstream outputs and checksum manifest coherent. The job definition's retry policy handles transient host failures within one run.

Submission records and collected results are written below `batch/runs/`, which the repository ignores. Do not commit manifests containing private URLs, credentials, or non-public data.

## Validation

Run `batch/validate.sh`. It performs Bash syntax checks, YAML parsing, CloudFormation linting when available, optional ShellCheck, JSON parsing, exposure checks, and scans for fixed account IDs, internal URLs, and local source paths. It makes no AWS calls.
