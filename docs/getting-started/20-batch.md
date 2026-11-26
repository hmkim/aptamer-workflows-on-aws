[English](20-batch.md) | [한국어](20-batch.ko.md)

# AWS Batch only

**AWS Batch** runs container jobs for you: you submit a job to a **job queue**, and Batch starts EC2 instances in a **compute environment** (a managed pool of instances), runs the job, and scales back to zero when the queue is empty. A **job definition** is the saved template for a job: image, CPU, memory, role, and command.

This guide deploys the shared network and one Batch stack, `<prefix>-batch`, with the compute you choose:

| Choice | Flag | Use it for |
|---|---|---|
| CPU only (default) | `--cpu` | the aptamer pipeline (QC, trim, count, enrichment, fold) and RaptGen on CPU |
| CPU + GPU | `--cpu --gpu` | the pipeline plus RaptGen on GPU, or CPU vs GPU benchmarks |
| GPU only | `--gpu` | RaptGen on GPU only; the aptamer pipeline job definitions are not created |

All three come from the same template, `batch/infrastructure.yaml`. Start with [prerequisites](00-prerequisites.md). For the GPU choices, check the G-family vCPU quota first.

## Step 1: Set variables

```bash
export AWS_REGION='<REGION>'
export PREFIX='aptamer-workflows'
export STACK_NAME="$PREFIX-batch"
```

The batch scripts in `batch/` read `AWS_REGION` and `STACK_NAME`.

## Step 2: Deploy the stack

Pick one of the three commands. Each creates `<prefix>-network` first when it does not exist (see [the network guide](10-network.md)).

### CPU only

```bash
scripts/setup-batch.sh --prefix "$PREFIX" --region "$AWS_REGION" --cpu
```

### CPU + GPU

```bash
scripts/setup-batch.sh --prefix "$PREFIX" --region "$AWS_REGION" --cpu --gpu
```

### GPU only

```bash
scripts/setup-batch.sh --prefix "$PREFIX" --region "$AWS_REGION" --gpu
```

What you should see:

- `compute: CPU=true GPU=false` (or the combination you chose).
- With CPU: `computing SHA-256 of Mountpoint 1.25.0 (x86_64) from the official release`. The CPU hosts install Mountpoint for Amazon S3 at boot, and the template pins the package by checksum. For production use, verify the printed value against the release signature, or pass `--mountpoint-sha256 <hash>` yourself.
- With GPU: `G/VT On-Demand vCPU quota: <n>`, or a `WARNING` that the quota is below `GpuMaxvCpus`.
- `aptamer-workflows-batch: CREATE_COMPLETE`, then an outputs table and next-step hints.

Useful options (all optional): `--max-vcpus` and `--instance-types` for CPU (defaults 72 and `c7i,c6i`); `--gpu-max-vcpus` and `--gpu-instance-types` for GPU (defaults 8 and `g5.xlarge,g6.xlarge`). GPU instances use the ECS GPU-optimized Amazon Linux 2023 image (`ECS_AL2023_NVIDIA`), which includes the NVIDIA driver.

## Step 3: Check the stack

```bash
aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[?contains(OutputKey,`Queue`)].[OutputKey,OutputValue]' --output table
```

You should see `JobQueueName`, plus `CpuJobQueueName` when CPU is on and `GpuJobQueueName` when GPU is on. Check that a queue is ready:

```bash
aws batch describe-job-queues --region "$AWS_REGION" --job-queues "$STACK_NAME-queue" \
  --query 'jobQueues[0].[state,status]' --output text
```

You should see `ENABLED VALID`. For GPU, use `"$STACK_NAME-gpu-queue"`.

**GPU only stops here for the aptamer pipeline.** Continue with [RaptGen on Batch](#run-raptgen-on-this-stack). Steps 4 to 7 need CPU.

## Step 4: Build the pipeline image (CPU)

```bash
scripts/setup-batch.sh --prefix "$PREFIX" --region "$AWS_REGION" --build-image
```

Without `--cpu` or `--gpu`, the script keeps the current compute setting. It packages the **committed** files of this repository (`git archive HEAD`; uncommitted edits are not included), uploads the archive to the data bucket, and starts AWS CodeBuild, which builds `Dockerfile` and pushes it to the private ECR repository with the tag recorded in the stack (`git-<commit>` by default).

You should see `CodeBuild started for tag git-<commit>`, then `pipeline image build succeeded` after several minutes. If the tag already exists, you see `pipeline image tag ... already exists; skipping build`.

## Step 5: Load the public D1 data (CPU)

The loader job downloads the nine public D1 files, checks their MD5 values, and writes them to the data bucket:

```bash
JOB_ID=$(batch/submit_loader.sh)
echo "$JOB_ID"
```

Wait for the job. This helper prints the status every 30 seconds and stops at the end:

```bash
wait_job() {
  local status
  while :; do
    status=$(aws batch describe-jobs --region "$AWS_REGION" --jobs "$1" --query 'jobs[0].status' --output text)
    printf '%s %s\n' "$(date -u +%H:%M:%S)" "$status"
    case "$status" in SUCCEEDED) return 0 ;; FAILED) return 1 ;; esac
    sleep 30
  done
}
wait_job "$JOB_ID"
```

You should see `SUBMITTED`, `RUNNABLE`, `STARTING`, `RUNNING`, then `SUCCEEDED`. The first job waits a few minutes while Batch starts an instance. Check the objects:

```bash
DATA_BUCKET=$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`DataBucketName`].OutputValue' --output text)
aws s3 ls "s3://$DATA_BUCKET/input/" --region "$AWS_REGION"
```

You should see nine `R<round>_DRR<number>.fastq.gz` objects. (`input` is the default `DataPrefix`.)

## Step 6: Run the pipeline (CPU)

Load the published D1 primers and choose a run ID:

```bash
source data/dra009383.env.example
export RUN_ID="d1-$(date -u +%Y%m%d%H%M)"
JOB_ID=$(batch/submit_copyin.sh)
wait_job "$JOB_ID"
```

The copy-in pattern copies the inputs to local disk, runs `pipeline/run_pipeline.sh`, and uploads the result. The script logs `result prefix: s3://<WorkBucketName>/runs/copyin/<RUN_ID>/result/`.

Other patterns with the same `RUN_ID` (see [batch/README.md](../../batch/README.md)):

```bash
ROUNDS=9 batch/submit_steps.sh          # S1-S3 array jobs per round, then S4 and S5
batch/submit_mountpoint.sh              # read-only S3 input through Mountpoint
batch/submit_compat.sh                  # Mountpoint compatibility report
```

## Step 7: Collect results

```bash
batch/collect_results.sh
```

The script waits for unfinished jobs of this `RUN_ID`, then writes to `batch/runs/<RUN_ID>/` (ignored by Git): `job_status.tsv`, `job_timing.tsv`, the downloaded results under `s3/`, and `result_compare.tsv`. That last file lists a SHA-256 of each pattern's sorted `top_candidates.tsv`; equal values mean equal tables. To compare with the local baseline from [the local guide](05-local.md), set `REFERENCE_RESULT=outputs/bash-d1/enrich/top_candidates.tsv` before running the script. Check the ranked table:

```bash
column -ts $'\t' "batch/runs/$RUN_ID/s3/copyin/result/enrich/top_candidates.tsv" | sed -n '1,11p'
```

## Change compute later

Run `scripts/setup-batch.sh` again with the flags you want. **The flags describe the final state, not a change**: on a CPU + GPU stack, `--gpu` alone removes the CPU compute environment, queue, and pipeline job definitions. Without `--cpu` or `--gpu`, the current setting is kept. The template refuses to turn both off.

```bash
scripts/setup-batch.sh --prefix "$PREFIX" --region "$AWS_REGION" --cpu --gpu   # add GPU to a CPU stack
```

Do this when no jobs are running.

## Run RaptGen on this stack

The Batch stack also creates two private ECR repositories for RaptGen (outputs `RaptgenCpuRepositoryUri`, `RaptgenGpuRepositoryUri`). Build the images, deploy the RaptGen job definitions, and run training or the CPU vs GPU benchmark with [the RaptGen on Batch guide](../raptgen/batch.md). Background: [RaptGen docs](../raptgen/README.md).

## Reference: what is in `batch/`

| Component | Files | Role |
|---|---|---|
| Infrastructure | `network.yaml`, `infrastructure.yaml` | AWS CloudFormation templates, which declare AWS resources as code. They create a private network, encrypted S3 buckets, private ECR repositories, an AWS CodeBuild image project, least-privilege IAM roles, CPU and/or GPU compute environments and queues, and three job definitions. |
| Operator scripts | `submit_*.sh`, `upload_manifest.sh`, `collect_results.sh`, `validate.sh`, `lib/common.sh` | Run from your workstation. They read stack outputs, submit jobs, record job IDs under the ignored `batch/runs/` directory, and collect results. |
| Job scripts | `job_common.sh`, `run_copyin.sh`, `run_stage.sh`, `run_mountpoint.sh`, `mountpoint_compat.sh`, `load_data.sh` | Run inside the container. The image build copies them into `/opt/aptamer/batch/`, so jobs never download executable scripts at run time. |

Every job definition runs `/opt/aptamer/batch/${JOB_SCRIPT}`. Each submit script chooses the script through a container override, which is a per-job value that replaces the job definition default. Parameters and outputs are listed in [batch/README.md](../../batch/README.md).

## Run the patterns by hand

The commands below show plain `aws batch submit-job` calls against resources that already exist. They explain what the submit scripts do; you do not need them for the steps above.

### Pattern 1: copy in, run, copy out

The simplest migration keeps the Bash pipeline unchanged: copy input objects from S3 into task-local storage, run the pipeline, then upload the result.

The following command assumes an existing queue and a job definition whose image contains this repository's pipeline tools and whose job role can read the input prefix and write the output prefix:

```bash
export AWS_REGION='<AWS_REGION>'
export BATCH_JOB_QUEUE='<BATCH_JOB_QUEUE_NAME>'
export BATCH_JOB_DEFINITION='<COPY_IN_JOB_DEFINITION_NAME_OR_ARN>'
export INPUT_URI='s3://<PRIVATE_INPUT_BUCKET>/<INPUT_PREFIX>/'
export OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/<UNIQUE_RUN_ID>/'
export FRONT_PRIMER='<FRONT_PRIMER_DNA>'
export BACK_PRIMER='<BACK_PRIMER_DNA>'

aws batch submit-job \
  --region "$AWS_REGION" \
  --job-name '<COPY_IN_JOB_NAME>' \
  --job-queue "$BATCH_JOB_QUEUE" \
  --job-definition "$BATCH_JOB_DEFINITION" \
  --container-overrides "$(jq -cn \
    --arg input "$INPUT_URI" \
    --arg output "$OUTPUT_URI" \
    --arg front "$FRONT_PRIMER" \
    --arg back "$BACK_PRIMER" \
    '{command:["bash","-lc","set -Eeuo pipefail; mkdir -p /tmp/aptamer/input /tmp/aptamer/output; aws s3 sync \"$INPUT_URI\" /tmp/aptamer/input --exclude \"*\" --include \"R*_*.fastq.gz\" --only-show-errors; run_pipeline.sh /tmp/aptamer/input /tmp/aptamer/output \"$FRONT_PRIMER\" \"$BACK_PRIMER\" 100 \"R*_*.fastq.gz\" \"^R([0-9]+)_\"; aws s3 sync /tmp/aptamer/output \"$OUTPUT_URI\" --only-show-errors"],environment:[{name:"INPUT_URI",value:$input},{name:"OUTPUT_URI",value:$output},{name:"FRONT_PRIMER",value:$front},{name:"BACK_PRIMER",value:$back}]}')" \
  --query 'jobId' \
  --output text
```

`jq` builds valid JSON so that shell quoting does not corrupt the container override. The job definition, rather than this command, should set CPU, memory, retry, timeout, non-root user, logging, and the least-privilege job role.

### Pattern 2: stage jobs with `dependsOn`

A **job dependency** keeps a job pending until an earlier job succeeds. An **array job** creates indexed child jobs from one submission. With an `N_TO_N` dependency, child index 4 in one array waits for child index 4 in the previous array. This maps naturally to one child per SELEX round.

The following commands create the dependency graph. Each referenced job definition must implement the named stage, use `AWS_BATCH_JOB_ARRAY_INDEX` for S1 through S3, and exchange intermediates through a private run-specific S3 prefix.

In `batch/run_stage.sh`, array index `n` selects round `R<n>`. Rounds must therefore be numbered contiguously from `R0`. If a round is missing, the S1 child with that index fails because it finds no input file.

```bash
export AWS_REGION='<AWS_REGION>'
export BATCH_JOB_QUEUE='<BATCH_JOB_QUEUE_NAME>'
export S1_JOB_DEFINITION='<QC_ARRAY_JOB_DEFINITION_NAME_OR_ARN>'
export S2_JOB_DEFINITION='<TRIM_ARRAY_JOB_DEFINITION_NAME_OR_ARN>'
export S3_JOB_DEFINITION='<COUNT_ARRAY_JOB_DEFINITION_NAME_OR_ARN>'
export S4_JOB_DEFINITION='<ENRICH_JOB_DEFINITION_NAME_OR_ARN>'
export S5_JOB_DEFINITION='<FOLD_JOB_DEFINITION_NAME_OR_ARN>'
export RUN_NAME='<UNIQUE_RUN_NAME>'
export ROUND_COUNT='9'

S1_JOB_ID=$(aws batch submit-job --region "$AWS_REGION" --job-name "$RUN_NAME-s1-qc" --job-queue "$BATCH_JOB_QUEUE" --job-definition "$S1_JOB_DEFINITION" --array-properties "size=$ROUND_COUNT" --query 'jobId' --output text)
S2_JOB_ID=$(aws batch submit-job --region "$AWS_REGION" --job-name "$RUN_NAME-s2-trim" --job-queue "$BATCH_JOB_QUEUE" --job-definition "$S2_JOB_DEFINITION" --array-properties "size=$ROUND_COUNT" --depends-on "jobId=$S1_JOB_ID,type=N_TO_N" --query 'jobId' --output text)
S3_JOB_ID=$(aws batch submit-job --region "$AWS_REGION" --job-name "$RUN_NAME-s3-count" --job-queue "$BATCH_JOB_QUEUE" --job-definition "$S3_JOB_DEFINITION" --array-properties "size=$ROUND_COUNT" --depends-on "jobId=$S2_JOB_ID,type=N_TO_N" --query 'jobId' --output text)
S4_JOB_ID=$(aws batch submit-job --region "$AWS_REGION" --job-name "$RUN_NAME-s4-enrich" --job-queue "$BATCH_JOB_QUEUE" --job-definition "$S4_JOB_DEFINITION" --depends-on "jobId=$S3_JOB_ID" --query 'jobId' --output text)
S5_JOB_ID=$(aws batch submit-job --region "$AWS_REGION" --job-name "$RUN_NAME-s5-fold" --job-queue "$BATCH_JOB_QUEUE" --job-definition "$S5_JOB_DEFINITION" --depends-on "jobId=$S4_JOB_ID" --query 'jobId' --output text)

printf 'S1=%s\nS2=%s\nS3=%s\nS4=%s\nS5=%s\n' "$S1_JOB_ID" "$S2_JOB_ID" "$S3_JOB_ID" "$S4_JOB_ID" "$S5_JOB_ID"
```

If an upstream dependency fails, downstream work does not run successfully. See the [AWS Batch job-dependency documentation](https://docs.aws.amazon.com/batch/latest/userguide/job_dependencies.html).

## Validated on

> TODO(validation): wave 3 fills in the date, Region, and result for CPU only, CPU + GPU, and GPU only here and in [the validation guide](../validation.md#validated-on). Until then, treat this path as not yet validated end to end.

## Next

- [Nextflow on this Batch queue](25-nextflow.md)
- [RaptGen on Batch](../raptgen/batch.md)
- [Add HealthOmics](40-both.md#one-after-another)
- [Clean up](90-cleanup.md)
