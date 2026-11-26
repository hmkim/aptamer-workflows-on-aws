[English](25-nextflow.md) | [한국어](25-nextflow.ko.md)

# Nextflow on AWS Batch

Nextflow turns each process into a Batch job and tracks dependencies for you. **Nextflow DSL2** is the current Nextflow syntax for connecting processes into a workflow. A **profile** is a named set of runtime settings selected with `-profile`.

This guide needs a CPU Batch stack from [the Batch guide](20-batch.md) (steps 1 to 5: stack, pipeline image, and D1 data). The stack does not create a role for the Nextflow head process; see the end of the next section.

## Nextflow on AWS Batch

With the `batch` profile, Nextflow stages S3 input files into task storage and requires an S3 work prefix. A small head process must remain running to coordinate the workflow.

```bash
export AWS_REGION='<AWS_REGION>'
export BATCH_QUEUE='<BATCH_JOB_QUEUE_NAME>'
export BATCH_JOB_ROLE_ARN='<BATCH_JOB_ROLE_ARN>'
export PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>'
export NXF_WORK='s3://<PRIVATE_WORK_BUCKET>/<NEXTFLOW_WORK_PREFIX>/'
export OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/'
export INPUT_URI='s3://<PRIVATE_INPUT_BUCKET>/<INPUT_PREFIX>/'
export SAMPLESHEET="$PWD/nextflow/samplesheet.dra009383.tsv"
export FRONT_PRIMER='<FRONT_PRIMER_DNA>'
export BACK_PRIMER='<BACK_PRIMER_DNA>'

bash nextflow/run_batch.sh batch \
  --front_primer "$FRONT_PRIMER" \
  --back_primer "$BACK_PRIMER"
```

See [nextflow/README.md](../../nextflow/README.md) and the [Nextflow AWS Batch executor documentation](https://docs.seqera.io/nextflow/aws#aws-batch).

To run Nextflow on the queue created by `batch/infrastructure.yaml`, take values from that stack's outputs:

| Variable | Stack output or value |
|---|---|
| `BATCH_QUEUE` | `CpuJobQueueName` (same as `JobQueueName` when CPU is enabled) |
| `BATCH_JOB_ROLE_ARN` | `PipelineJobRoleArn` |
| `PIPELINE_IMAGE` | `RepositoryUri` plus the image tag or digest you built |
| `INPUT_URI` | `s3://<DataBucketName>/<DataPrefix>/` |
| `NXF_WORK` | A prefix under `s3://<WorkBucketName>/runs/` |

The pipeline job role can write only below `runs/` in the work bucket, so a Nextflow work directory elsewhere fails with access denied. The stack does not create a role for the Nextflow head process. Give the head process its own role that can submit and inspect Batch jobs, read and write the work prefix, and write `OUTPUT_URI`.

## Nextflow with read-only Mountpoint input

Mountpoint for Amazon S3 presents S3 objects through a Linux file path. It is **not a fully POSIX-compliant file system and may fail according to a tool's or workload's file-access pattern**. Use it read-only for compatible inputs. Keep temporary files and outputs on local POSIX storage, and **never use a Mountpoint path as the Nextflow work directory**.

```bash
export AWS_REGION='<AWS_REGION>'
export BATCH_QUEUE='<MOUNTPOINT_ENABLED_BATCH_QUEUE_NAME>'
export BATCH_JOB_ROLE_ARN='<BATCH_JOB_ROLE_ARN>'
export PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>'
export NXF_WORK='s3://<PRIVATE_WORK_BUCKET>/<NEXTFLOW_WORK_PREFIX>/'
export OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/'
export INPUT_URI='/mnt/s3-input/<INPUT_PREFIX>'
export MOUNT_PATH='/mnt/s3-input'
export SAMPLESHEET="$PWD/nextflow/samplesheet.dra009383.tsv"
export FRONT_PRIMER='<FRONT_PRIMER_DNA>'
export BACK_PRIMER='<BACK_PRIMER_DNA>'
export RESUME='false'

bash nextflow/run_batch.sh batch_mountpoint \
  --front_primer "$FRONT_PRIMER" \
  --back_primer "$BACK_PRIMER"
```

The compute hosts must mount the private input bucket at `MOUNT_PATH`, which defaults to `/mnt/s3-input`, and expose that host path read-only to task containers. The CPU hosts created by `batch/infrastructure.yaml` use a different layout: they mount only the `<DataPrefix>/` part of the data bucket at `/mnt/s3-data`, so input objects appear directly below `/mnt/s3-data`. On that queue, set `MOUNT_PATH='/mnt/s3-data'` and `INPUT_URI='/mnt/s3-data'`. GPU hosts do not mount S3.

Mounted paths are passed as strings rather than Nextflow `path` inputs. Nextflow therefore cannot detect an object whose contents changed without changing its mounted path. Use versioned or immutable keys, or run without `-resume` after an input change.

Read [the storage guide](../storage.md) and [Mountpoint file-system behavior](https://github.com/awslabs/mountpoint-s3/blob/main/doc/SEMANTICS.md).

## Next

- [Validation guide](../validation.md) to compare Nextflow and Batch results
- [Clean up](90-cleanup.md)
