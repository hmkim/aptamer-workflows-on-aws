# Nextflow workflow

`main.nf` is one Nextflow DSL2 workflow with four profiles. DSL2 is Nextflow's current workflow syntax. The process graph performs read quality control, primer trimming, sequence counting, enrichment ranking, RNA secondary-structure folding, and output checksums.

## Container contract

The container must provide `seqkit`, `cutadapt`, `RNAfold`, and `enrich.py`. Remote profiles require a private Amazon Elastic Container Registry (ECR) image, preferably addressed by its `sha256` digest. ECR is AWS-managed private container storage.

## Inputs

The repository includes optional D1-specific example primers in `../data/dra009383.env.example`; review their source and reuse limits in `../DATA_NOTICE.md`. Every run still receives primers explicitly at launch.

The samplesheet is tab-separated text with `round` and `file` columns:

```text
round  file
0      R0_sample.fastq.gz
1      R1_sample.fastq.gz
```

Relative file names are joined to `--input_dir`. A file column may instead contain a complete local path or `s3://` object URI.

## Profiles

| Profile | Input handling | Nextflow work directory |
|---|---|---|
| `local` | Local files are staged with links | Local POSIX file system |
| `batch` | Nextflow copies S3 objects into task storage | S3 |
| `batch_mountpoint` | Tasks read a read-only Mountpoint path passed as a `val` string | S3 |
| `healthomics` | HealthOmics stages private S3 objects | HealthOmics-managed task storage |

POSIX means the normal file behavior expected by command-line tools, including random reads, renames, and file locking. Mountpoint for Amazon S3 is not a fully POSIX-compatible file system. This workflow uses Mountpoint only for sequential, read-only FASTQ input. All temporary files, intermediates, and outputs stay in task storage. Use native S3 staging when a tool needs full POSIX behavior.

### Mountpoint and `-resume`

Nextflow hashes a `val` input from its string value. It cannot see that an S3 object changed behind the same mounted path. Therefore, `-resume` can reuse stale cached tasks in `batch_mountpoint` mode. Use immutable or versioned object keys, or run without `-resume` whenever mounted object content may have changed.

## Local run

Run from the repository root after building the required container image:

```bash
nextflow run nextflow/main.nf -profile local \
  --reads 'inputs/DRA009383/R*_*.fastq.gz' \
  --front_primer '<FRONT_PRIMER_DNA>' \
  --back_primer '<BACK_PRIMER_DNA>' \
  --local_container 'aptamer-workflow:latest' \
  --outdir results
```

Replace `<FRONT_PRIMER_DNA>` and `<BACK_PRIMER_DNA>` with DNA sequences containing only A, C, G, T, or N.

## AWS Batch runs

The launcher takes configuration only from environment variables and command arguments. It does not create queues, roles, buckets, compute environments, or mounts.

Native S3 staging:

```bash
AWS_REGION='<AWS_REGION>' \
BATCH_QUEUE='<BATCH_JOB_QUEUE_NAME>' \
BATCH_JOB_ROLE_ARN='<BATCH_JOB_ROLE_ARN>' \
PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>' \
NXF_WORK='s3://<WORK_BUCKET>/<NEXTFLOW_WORK_PREFIX>' \
OUTPUT_URI='s3://<OUTPUT_BUCKET>/<RUN_OUTPUT_PREFIX>' \
INPUT_URI='s3://<INPUT_BUCKET>/<FASTQ_PREFIX>' \
SAMPLESHEET="$PWD/nextflow/samplesheet.dra009383.tsv" \
FRONT_PRIMER='<FRONT_PRIMER_DNA>' \
BACK_PRIMER='<BACK_PRIMER_DNA>' \
nextflow/run_batch.sh batch \
  --front_primer "$FRONT_PRIMER" \
  --back_primer "$BACK_PRIMER"
```

Read-only Mountpoint input:

```bash
AWS_REGION='<AWS_REGION>' \
BATCH_QUEUE='<BATCH_JOB_QUEUE_NAME>' \
BATCH_JOB_ROLE_ARN='<BATCH_JOB_ROLE_ARN>' \
PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>' \
NXF_WORK='s3://<WORK_BUCKET>/<NEXTFLOW_WORK_PREFIX>' \
OUTPUT_URI='s3://<OUTPUT_BUCKET>/<RUN_OUTPUT_PREFIX>' \
INPUT_URI='/mnt/s3-input/<FASTQ_PREFIX>' \
MOUNT_PATH='/mnt/s3-input' \
SAMPLESHEET="$PWD/nextflow/samplesheet.dra009383.tsv" \
FRONT_PRIMER='<FRONT_PRIMER_DNA>' \
BACK_PRIMER='<BACK_PRIMER_DNA>' \
RESUME=false \
nextflow/run_batch.sh batch_mountpoint \
  --front_primer "$FRONT_PRIMER" \
  --back_primer "$BACK_PRIMER"
```

The AWS Batch compute environment must create the Mountpoint mount before jobs start and expose it read-only at `MOUNT_PATH`. The job role should have only the S3 read and write permissions required for the configured prefixes.

## HealthOmics

Package this directory and launch it with the helpers in `../healthomics/`. HealthOmics is an AWS managed service that runs bioinformatics workflows. The helper always requests restricted networking, private S3 storage, and a private same-region ECR image.

## Local validation

```bash
nextflow run nextflow/main.nf --help
nextflow config nextflow/main.nf -profile local
nextflow config nextflow/main.nf -profile batch
nextflow config nextflow/main.nf -profile batch_mountpoint
nextflow config nextflow/main.nf -profile healthomics
bash -n nextflow/run_batch.sh
python3 -m json.tool nextflow/nextflow_schema.json >/dev/null
```

## Glossary

- **AWS Batch:** managed job scheduling and compute provisioning.
- **DSL2:** Nextflow syntax for composing processes and workflows.
- **ECR:** private container image storage on AWS.
- **Mountpoint for Amazon S3:** a file-system view of S3 objects with a deliberately limited POSIX feature set.
- **Native S3 staging:** Nextflow copies each S3 object into a task before the tool runs.
- **Profile:** a named Nextflow configuration selected with `-profile`.
- **Work directory:** Nextflow's cache of task scripts, staged inputs, and intermediate outputs.
