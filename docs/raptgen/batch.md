[English](batch.md) | [한국어](batch.ko.md)

# RaptGen on AWS Batch

This guide builds the RaptGen container images, registers the Batch job definitions, runs a training job and a benchmark on CPU or GPU, and shows you where the results land in S3.

**AWS Batch** is a managed service that runs containers as queued jobs on EC2 instances it starts and stops for you. A **job definition** is the recipe for one kind of job (image, memory, command). A **job queue** holds submitted jobs until a compute environment has room.

Technical reference for the files used here: [`raptgen/README.md`](../../raptgen/README.md), [`raptgen/batch/README.md`](../../raptgen/batch/README.md), [`raptgen/containers/README.md`](../../raptgen/containers/README.md).

## Before you start

1. **A Batch stack with the compute you want.** Follow [Batch only](../getting-started/20-batch.md). Enable CPU, GPU or both:

   | You want | Batch stack setting | RaptGen jobs you can run |
   |---|---|---|
   | CPU only | `scripts/setup-batch.sh --cpu` (default) | `--device cpu` |
   | CPU and GPU | `scripts/setup-batch.sh --cpu --gpu` | `--device cpu` and `--device gpu` |
   | GPU only | `scripts/setup-batch.sh --gpu` | `--device gpu` |

   The stack is called `<prefix>-batch` (default prefix `aptamer-workflows`). It creates the ECR repositories `<prefix>-batch-raptgen-cpu` and `<prefix>-batch-raptgen-gpu` (both always, whatever compute you enabled), the job role and the log group that this guide uses.

2. **GPU quota (GPU path only).** GPU instances (`g5`, `g6`) count against your **Running On-Demand G and VT instances** vCPU quota, which is 0 on many new accounts. Check it in Service Quotas before you enable the GPU compute environment. A GPU job stays `RUNNABLE` forever if the quota is too low.

3. **On your computer:** Docker with BuildKit, AWS CLI v2 with working credentials for the target account, `git`, and `python3`. The image build downloads packages and the upstream RaptGen source, so it needs internet access. The first build needs several GB of disk.

4. **Set the Region** for every command below (replace `<REGION>`):

   ```bash
   export AWS_REGION=<REGION> AWS_DEFAULT_REGION=<REGION>
   export STACK_PREFIX=aptamer-workflows     # the prefix you used for the Batch stack
   ```

   The scripts read the stack outputs from `${STACK_PREFIX}-batch`.

5. **Cost note.** You are billed for the Batch instances while jobs run, GPU instances at their own rate, the NAT gateway of the network stack by the hour, CloudWatch Logs, S3 and ECR storage. Check the AWS pricing pages for your Region. Delete what you do not need with [clean up](../getting-started/90-cleanup.md).

## Step 1. Build and push the images

Run from the repository root. Build the variant(s) you enabled.

```bash
raptgen/containers/build.sh cpu
raptgen/containers/build.sh gpu
```

What the script does: builds the image locally, tags it `<upstream-commit12>-<git-sha7>`, logs in to your private ECR registry, pushes, and prints the digest URI.

You should see, at the end of each run:

```text
image digest URI (use this in raptgen/batch/jobs.yaml parameters):
<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<prefix>-batch-raptgen-cpu@sha256:<64 hex characters>
```

Copy the two URIs (or only the one you built). They are used in step 2. To build without pushing, add `--no-push`.

Both repositories exist even when GPU compute is off, so you can build the GPU image first and enable GPU later. A GPU job needs the GPU queue: `submit-train.sh --device gpu` stops with `The gpu queue is disabled` until you run `scripts/setup-batch.sh --cpu --gpu` (or `--gpu`). In the validation run the CPU build took about 2 minutes and the GPU build (CUDA wheels) about 7 minutes on the validation workstation.

## Step 2. Deploy the job definitions

Read the values from the Batch stack:

```bash
JOB_ROLE=$(aws cloudformation describe-stacks --stack-name "$STACK_PREFIX-batch" \
  --query "Stacks[0].Outputs[?OutputKey=='PipelineJobRoleArn'].OutputValue" --output text)
LOG_GROUP=$(aws cloudformation describe-stacks --stack-name "$STACK_PREFIX-batch" \
  --query "Stacks[0].Outputs[?OutputKey=='LogGroupName'].OutputValue" --output text)
echo "$JOB_ROLE" "$LOG_GROUP"
```

You should see a role ARN and a log group name.

Deploy. Pass only the image URI you built; leave the other one out and its job definitions are not created:

```bash
aws cloudformation deploy --stack-name "$STACK_PREFIX-raptgen-jobs" \
  --template-file raptgen/batch/jobs.yaml \
  --parameter-overrides \
    NamePrefix="$STACK_PREFIX-raptgen" \
    CpuImageUri=<cpu-digest-uri> \
    GpuImageUri=<gpu-digest-uri> \
    JobRoleArn="$JOB_ROLE" LogGroupName="$LOG_GROUP"
```

You should see `Successfully created/updated stack`. In the Batch console, **Job definitions** now lists up to four entries:

| Job definition | Does | Needs |
|---|---|---|
| `<prefix>-raptgen-train-cpu` | train + encode on CPU | `CpuImageUri` |
| `<prefix>-raptgen-train-gpu` | train + encode on 1 GPU | `GpuImageUri` |
| `<prefix>-raptgen-bench-cpu` | timing benchmark on CPU | `CpuImageUri` |
| `<prefix>-raptgen-bench-gpu` | timing benchmark on 1 GPU, then on CPU of the same instance | `GpuImageUri` |

Every container runs as a non-root user (UID 10001) with a read-only root file system, a 2 GiB tmpfs `/tmp`, and no inbound network port. Logs go to the Batch stack log group. Image URIs are pinned by digest, not by tag.

## Step 3. Run a training job

```bash
raptgen/batch/submit-train.sh --device cpu
# or
raptgen/batch/submit-train.sh --device gpu
```

Without `--input`, the script uses the RaptGen paper dataset A that ships inside both images (`data/real/A_4R.fastq`, 80,864 reads, public). Defaults: 50 epochs, `--min-count 2` (3,043 unique sequences). To use your own reads, upload a FASTQ below `runs/` of the work bucket (the job role reads and writes only that prefix) and pass it:

```bash
raptgen/batch/submit-train.sh --device cpu --input s3://<WORK_BUCKET>/runs/inputs/my-reads.fastq --epochs 100
```

| Option | Meaning |
|---|---|
| `--device cpu\|gpu` | required. Chooses the queue and job definition. It fails with a clear message if that compute is not enabled. |
| `--input` | `s3://bucket/key`, `builtin:A_4R` (default) or `builtin:sample` |
| `--epochs N` | training epochs, default 50 |
| `--min-count N` | keep sequences seen at least N times, default 2. Min-count 1 keeps more sequences (38,513 unique for dataset A) and is about 10 times slower per epoch. |
| `--threshold N` | passed to the upstream training script, default 50 |
| `--stack-prefix`, `--jobdef-prefix` | defaults `aptamer-workflows` and `<stack-prefix>-raptgen` (the `NamePrefix` above) |

You should see:

```text
submitted train-cpu-<timestamp>
  job id : <JOB_ID>
  queue  : <queue name>
  output : s3://<WORK_BUCKET>/runs/raptgen/train-cpu-<timestamp>/
check with: raptgen/batch/status.sh <JOB_ID>
```

## Step 4. Run the CPU vs GPU benchmark (optional)

```bash
raptgen/batch/submit-bench.sh --device both      # or cpu, or gpu
```

The benchmark trains for a fixed 5 epochs (change with `--epochs`) on dataset A and prints one JSON line per run. `--device both` needs both compute environments and submits one CPU job and one GPU job. The GPU job times CUDA first and then the CPU of the same GPU instance. The results are explained in [benchmark](benchmark.md).

## Step 5. Watch the job and read the results

```bash
raptgen/batch/status.sh <JOB_ID>
raptgen/batch/status.sh --list           # latest jobs of every enabled queue
```

Status moves `SUBMITTED` → `RUNNABLE` → `STARTING` → `RUNNING` → `SUCCEEDED` (or `FAILED`). `RUNNABLE` means Batch is waiting for an instance. The first job of the day can wait a few minutes while EC2 starts. A job that stays `RUNNABLE` for long usually means a quota or capacity limit; for GPU, check the G-instance quota from "Before you start".

`status.sh` also prints the S3 location of the results. When the job has `SUCCEEDED`, a training job has written:

```bash
aws s3 ls s3://<WORK_BUCKET>/runs/raptgen/train-cpu-<timestamp>/
```

| File | Content |
|---|---|
| model file | the trained RaptGen model |
| loss CSV | training and test loss per epoch |
| `embed_seq.csv` | the encoded coordinates of every sequence |
| `train.log` | training log |
| `run.json` | input, parameters, device, versions and timing of this run |

Benchmark jobs write their JSON lines to the job's CloudWatch log stream. `status.sh` prints them for finished benchmark jobs.

Download everything for a run:

```bash
aws s3 cp --recursive s3://<WORK_BUCKET>/runs/raptgen/train-cpu-<timestamp>/ ./raptgen-run/
```

## Good to know

- Training is not seeded upstream, so two runs on the same input give similar but not identical models.
- The Batch images do not include Bayesian optimization. Use [RaptGen-UI](ui.md) for that.
- Training runs are independent of each other. Submit several jobs (different inputs, parameters or repeats) to run them in parallel; see [benchmark](benchmark.md#what-it-means).
- Use public or non-sensitive data. The work bucket is encrypted and private, but check your own data rules first.

## What is not validated yet

| Item | Status |
|---|---|
| Fresh-stack run of this guide (CPU, GPU, both) | Passed on 2026-11-26 in us-west-2: both images, job definitions, 3-epoch training on CPU and GPU, `submit-bench.sh --device both --epochs 2`, `status.sh`, outputs in S3. See [validation](../validation.md#validated-on). |

Next: [CPU vs GPU benchmark](benchmark.md) | [Index](README.md)
