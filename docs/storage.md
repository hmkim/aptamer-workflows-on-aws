# Storage and cleanup guide

The workflow uses three kinds of storage: Amazon S3 for durable objects, local POSIX storage for active file operations, and service-managed task storage in AWS HealthOmics.

## Storage roles

| Location | Use | In plain terms |
|---|---|---|
| Private S3 input prefix | Immutable FASTQ inputs and samplesheets | Durable object storage shared by execution environments |
| Private S3 work prefix | Nextflow task cache and Batch intermediates | Restartable working data that can grow quickly |
| Private S3 output prefix | Ranked tables, folds, checksums, and selected reports | Results that should outlive a compute host |
| Local POSIX task storage | Temporary files, sorting, trimming, and tool working directories | A normal Linux disk that supports rename, links, locks, and in-place updates |
| Read-only Mountpoint path | Compatible input reads only | A file-like view of S3 objects, not a complete Linux file system |
| HealthOmics task storage | HealthOmics process work | Storage managed as part of a workflow run |

An **S3 prefix** is the folder-like beginning of an object key. It is not a real directory, but it is useful for separating runs and limiting IAM permissions.

## Recommended object layout

Use immutable inputs and a unique run identifier:

```text
s3://<PRIVATE_INPUT_BUCKET>/<DATASET_ID>/fastq/
s3://<PRIVATE_INPUT_BUCKET>/<DATASET_ID>/samplesheet.tsv
s3://<PRIVATE_WORK_BUCKET>/nextflow/work/<RUN_ID>/
s3://<PRIVATE_WORK_BUCKET>/batch/intermediate/<RUN_ID>/
s3://<PRIVATE_OUTPUT_BUCKET>/results/<RUN_ID>/
```

Do not reuse an output prefix across runs. Do not let one job write another run's prefix. Record the input-object version or checksum, container image digest, parameters, and workflow revision with the result.

## Native S3 staging

With the Nextflow `batch` profile, an input declared as a Nextflow `path` is staged into task storage. The task sees a local file and can use normal POSIX operations. Nextflow uploads task work and published outputs to S3.

This is the safest default for tools whose file behavior is unknown. It requires local capacity for each staged input and transfers the object for each task that needs it.

The Nextflow work directory must include a prefix below the bucket:

```bash
export NXF_WORK='s3://<PRIVATE_WORK_BUCKET>/<NEXTFLOW_WORK_PREFIX>/'
nextflow run nextflow/main.nf \
  -profile batch \
  -work-dir "$NXF_WORK" \
  --samplesheet nextflow/samplesheet.tsv \
  --input_dir 's3://<PRIVATE_INPUT_BUCKET>/<INPUT_PREFIX>/' \
  --outdir 's3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/' \
  --aws_region '<AWS_REGION>' \
  --batch_queue '<BATCH_JOB_QUEUE_NAME>' \
  --batch_job_role '<BATCH_JOB_ROLE_ARN>' \
  --container '<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>' \
  --front_primer '<FRONT_PRIMER_DNA>' \
  --back_primer '<BACK_PRIMER_DNA>'
```

## Mountpoint for Amazon S3

Mountpoint translates Linux file operations into S3 API requests. It is optimized for high-throughput access to objects, especially large sequential reads.

Mountpoint is **not fully POSIX-compliant and may fail according to the tool or workload file-access pattern**. For general-purpose S3 buckets, important differences include unsupported symbolic links and file locking, limited updates to existing files, and no general rename operation. See [Mountpoint file-system behavior](https://github.com/awslabs/mountpoint-s3/blob/main/doc/SEMANTICS.md) and the [Amazon S3 Mountpoint guide](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mountpoint.html).

Use this rule:

> Mount inputs read-only. Put temporary files and outputs on local POSIX storage. Never use Mountpoint as the Nextflow work directory.

A host-side read-only mount looks like this after Mountpoint is installed and the instance role has read access:

```bash
export INPUT_BUCKET='<PRIVATE_INPUT_BUCKET>'
export INPUT_PREFIX='<INPUT_PREFIX>'
export MOUNT_PATH='/mnt/s3-input'

sudo install -d -m 0755 "$MOUNT_PATH"
sudo mount-s3 \
  "$INPUT_BUCKET" \
  "$MOUNT_PATH" \
  --prefix "$INPUT_PREFIX/" \
  --read-only \
  --allow-other
mountpoint "$MOUNT_PATH"
```

On AWS Batch, create this mount in the compute-host launch template and bind-mount it read-only into the container. Do not mount from inside an unprivileged task container. Limit the compute instance role to `s3:ListBucket`, `s3:GetBucketLocation`, `s3:GetObject`, and only the intended bucket and prefix.

### Compatibility by stage

| Stage | Mounted operation | Required local operation | Expected approach |
|---|---|---|---|
| QC | Read compressed FASTQ | Write statistics in task storage | Test, then allow read-only input |
| Trim | Read compressed FASTQ | Write trimmed FASTQ and logs | Keep all writes local |
| Count | No mounted input after trim | Sort, temporary files, and count output | Set `TMPDIR` to local task storage |
| Enrichment | Read staged count tables | Write ranked tables | Use task-local or native S3 staging |
| Fold | Read staged ranked table | Write fold output in local working directory | Do not use mounted current directory |
| Nextflow engine | Mounted path passed as a string | Task scripts, links, cache, and metadata | Keep work in native S3 staging or local POSIX storage |

Run a real compatibility test with the exact tool and version. A successful `ls` or `head` test does not prove that a tool's complete access pattern is supported.

### Mountpoint and Nextflow resume

The `batch_mountpoint` profile passes mounted paths as string values. Nextflow hashes the string, not the object contents. If an object changes at the same path, `-resume` can reuse stale work.

Use S3 versioning plus immutable object keys, include a content identifier in the path, or launch without `-resume` whenever mounted content may have changed.

## S3 security baseline

- Enable all four S3 Block Public Access settings.
- Use bucket-owner-enforced object ownership so ACLs are disabled.
- Deny requests that do not use TLS.
- Encrypt objects and restrict key use to the required roles.
- Give input identities read-only permission.
- Give task roles write permission only to the required work or output scope. The included Batch task role covers the stack's complete `runs/` prefix; use separate stacks or per-run roles when IAM must isolate runs from each other.
- Keep versioning and lifecycle rules aligned with recovery and retention requirements.
- Abort incomplete multipart uploads after an approved interval.
- Do not record confidential object keys or results in public logs.

## Cleanup

Cleanup commands are intentionally split into inspection, dry run, and execution. Replace every placeholder, confirm the AWS account and Region, preserve required results, and obtain explicit operator approval before an execution step.

### Local run directory

Inspect one local run under a fixed base directory:

```bash
export LOCAL_RUN_BASE="$HOME/aptamer-runs"
export RUN_ID='<RUN_ID>'
export LOCAL_RUN_DIRECTORY="$LOCAL_RUN_BASE/$RUN_ID"
export LOCAL_RUN_BASE_CANONICAL=$(realpath --canonicalize-missing -- "$LOCAL_RUN_BASE")
export LOCAL_RUN_DIRECTORY_CANONICAL=$(realpath --canonicalize-missing -- "$LOCAL_RUN_DIRECTORY")
case "$LOCAL_RUN_DIRECTORY_CANONICAL" in
  "$LOCAL_RUN_BASE_CANONICAL"/*) ;;
  *) printf 'Refusing path outside LOCAL_RUN_BASE\n' >&2; exit 1 ;;
esac
test "$LOCAL_RUN_DIRECTORY_CANONICAL" != "$LOCAL_RUN_BASE_CANONICAL"
test -d "$LOCAL_RUN_DIRECTORY_CANONICAL"
find "$LOCAL_RUN_DIRECTORY_CANONICAL" -mindepth 1 -maxdepth 2 -print
```

Local `rm` has no reliable dry-run mode. After separately reviewing the listing and receiving explicit approval, repeat the same canonical-path guards and remove only that strict descendant:

```bash
export LOCAL_RUN_BASE="$HOME/aptamer-runs"
export RUN_ID='<RUN_ID>'
export LOCAL_RUN_DIRECTORY="$LOCAL_RUN_BASE/$RUN_ID"
export LOCAL_RUN_BASE_CANONICAL=$(realpath --canonicalize-missing -- "$LOCAL_RUN_BASE")
export LOCAL_RUN_DIRECTORY_CANONICAL=$(realpath --canonicalize-missing -- "$LOCAL_RUN_DIRECTORY")
case "$LOCAL_RUN_DIRECTORY_CANONICAL" in
  "$LOCAL_RUN_BASE_CANONICAL"/*) ;;
  *) printf 'Refusing path outside LOCAL_RUN_BASE\n' >&2; exit 1 ;;
esac
test "$LOCAL_RUN_DIRECTORY_CANONICAL" != "$LOCAL_RUN_BASE_CANONICAL"
test -d "$LOCAL_RUN_DIRECTORY_CANONICAL"
rm -rf -- "$LOCAL_RUN_DIRECTORY_CANONICAL"
```

### S3 run prefix

Inspect the prefix:

```bash
export AWS_REGION='<AWS_REGION>'
export RUN_OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/<RUN_ID>/'
aws s3 ls "$RUN_OUTPUT_URI" --region "$AWS_REGION" --recursive --human-readable --summarize
```

Preview every removal without deleting objects:

```bash
export AWS_REGION='<AWS_REGION>'
export RUN_OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/<RUN_ID>/'
aws s3 rm "$RUN_OUTPUT_URI" --region "$AWS_REGION" --recursive --dryrun
```

After checking the preview and receiving explicit approval, run the same scoped command without `--dryrun`:

```bash
export AWS_REGION='<AWS_REGION>'
export RUN_OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/<RUN_ID>/'
aws s3 rm "$RUN_OUTPUT_URI" --region "$AWS_REGION" --recursive --only-show-errors
```

In a versioned bucket, this usually creates delete markers rather than erasing prior versions. Review retention and legal requirements before deleting versions.

### Batch jobs

List active jobs before deciding whether to stop them:

```bash
export AWS_REGION='<AWS_REGION>'
export BATCH_JOB_QUEUE='<BATCH_JOB_QUEUE_NAME>'
aws batch list-jobs --region "$AWS_REGION" --job-queue "$BATCH_JOB_QUEUE" --job-status RUNNING
aws batch list-jobs --region "$AWS_REGION" --job-queue "$BATCH_JOB_QUEUE" --job-status RUNNABLE
```

Stopping a job can leave incomplete output. Use `cancel-job` for jobs that have not started and `terminate-job` for running jobs only after explicit approval and after recording the exact job ID.

### HealthOmics and CloudFormation

Inspect runs and stack resources before cleanup:

```bash
export AWS_REGION='<AWS_REGION>'
export STACK_NAME='<STACK_NAME>'
aws omics list-runs --region "$AWS_REGION" --max-results 25
aws cloudformation describe-stack-resources --region "$AWS_REGION" --stack-name "$STACK_NAME"
```

The included template retains its bucket, KMS key, and ECR repository when the stack is deleted. CloudFormation stack deletion has no dry-run mode. Treat stack deletion and retained-resource deletion as separate approved actions. Inventory S3 object versions and ECR images before deciding whether retained resources can be removed.

## Further reading

- [Nextflow AWS Batch executor](https://docs.seqera.io/nextflow/aws#aws-batch)
- [AWS Batch job dependencies](https://docs.aws.amazon.com/batch/latest/userguide/job_dependencies.html)
- [AWS HealthOmics private workflows](https://docs.aws.amazon.com/omics/latest/dev/private-workflows.html)
