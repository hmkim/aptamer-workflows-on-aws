# Aptamer workflows on AWS

This repository shows how one aptamer sequencing analysis can move from a Bash script on a single machine to AWS Batch, Nextflow, and AWS HealthOmics. The emphasis is on execution and storage patterns rather than on a new scientific method.

This is an independent educational project. It is **not an official AWS sample or template**, and it is not production-ready without review for your data, security requirements, quotas, and operating model.

## What the workflow does

An **aptamer** is a short DNA or RNA sequence selected because it binds to a target. **SELEX** (systematic evolution of ligands by exponential enrichment) repeats selection over several rounds so that useful sequences become more common.

```text
FASTQ reads from each SELEX round
              |
              v
     QC -> trim -> count and RPM -> enrichment -> fold
```

| Step | Tool | In plain terms | Main output |
|---|---|---|---|
| Quality control (QC) | SeqKit | Check how many sequencing reads arrived and whether their lengths look plausible. | `qc/stats.tsv` |
| Primer trimming | Cutadapt | Remove fixed laboratory primer sequences and retain the variable aptamer sequence. | `trimmed/` |
| Count and RPM | SeqKit and standard Unix tools | Count repeated sequences. RPM means reads per million and makes rounds with different read totals comparable. | `counts/` |
| Enrichment | Python | Rank sequences that became more common across selection rounds. | `enrich/top_candidates.tsv` |
| RNA folding | ViennaRNA RNAfold | Predict a two-dimensional base-pairing structure and its free energy. | `fold/` |

Molecular dynamics (MD) simulation is excluded. MD uses numerical physics, often on GPUs, to model three-dimensional molecular motion. The workflow stops after RNA secondary-structure prediction and does not claim binding affinity, biological activity, or clinical validity.

## Data used by the example

**D1 is public RNA SELEX data produced with Ion Torrent sequencing. It is not customer DNA data and it is not Illumina data.** The nine rounds are identified by the public [DRA009383 archive record](https://ddbj.nig.ac.jp/resource/sra-submission/DRA009383). Review the archive record, linked publication, and applicable data-use terms before downloading or publishing an analysis.

The repository stores only a manifest of public metadata and checksums. It does not store sequencing reads or derived research results. See [DATA_NOTICE.md](DATA_NOTICE.md).

The execution patterns also apply to other round-based FASTQ inputs, but different sequencing platforms, DNA aptamers, paired-end reads, primer layouts, and library lengths require scientific validation and may require code changes.

## Choose an execution pattern

| Pattern | Best starting point | Storage behavior | What you operate |
|---|---|---|---|
| Bash on a workstation or EC2 | Small studies and a transparent baseline | Inputs, temporary files, and outputs use a local POSIX file system. POSIX means ordinary Linux file behavior such as rename, locking, and in-place updates. | One machine |
| AWS Batch copy-in | Move an existing script into managed jobs with few changes | A job copies S3 inputs to local task storage, runs Bash, and uploads outputs. | Job definition, queue, and compute environment |
| AWS Batch with `dependsOn` | Expose stage boundaries and parallelize rounds | Each stage exchanges intermediates through private S3 prefixes. | Job graph and intermediate objects |
| Nextflow on AWS Batch | Let a workflow engine create and track task jobs | Nextflow stages S3 objects into task storage and keeps its work directory in S3. | Nextflow head process plus Batch |
| Nextflow with Mountpoint | Avoid a full input copy for compatible read-heavy steps | Tasks read mounted S3 objects, while temporary files and outputs remain on local POSIX storage. | Mountpoint-enabled Batch hosts plus Nextflow |
| AWS HealthOmics | Use a managed bioinformatics workflow service | HealthOmics stages private S3 inputs and manages task execution storage. | Private workflow, run role, image, and S3 data |

Read [the architecture guide](docs/architecture.md) and [the storage guide](docs/storage.md) before choosing a pattern.

## Repository map

```text
.
├── data/                Public D1 manifest and checksum-verifying downloader
├── ec2/                 Helper for a baseline run on an existing EC2 instance
├── healthomics/         Private HealthOmics workflow packaging and infrastructure
├── nextflow/            One DSL2 workflow with local, Batch, Mountpoint, and HealthOmics profiles
├── pipeline/            Bash and Python implementation of the scientific stages
├── tests/               Deterministic enrichment unit tests
├── docs/architecture.md Execution models and data flow
├── docs/storage.md      S3, local storage, staging, and Mountpoint guidance
└── docs/validation.md   Static, functional, and cross-run validation
```

**Nextflow DSL2** is the current Nextflow syntax for connecting processes into a workflow. A **profile** is a named set of runtime settings selected with `-profile`.

## Prerequisites

Use a Linux environment with:

- Git, Bash, `curl`, `jq`, `md5sum`, and Python 3.12 for local preparation and tests.
- Docker for the containerized local workflow.
- AWS CLI v2 for AWS operations.
- Nextflow 24.10 or 25.x for Nextflow runs.
- An AWS account and a selected AWS Region for AWS examples.

AWS examples assume that you have already created private resources with least-privilege IAM roles. **IAM** (AWS Identity and Access Management) controls which identity can perform which action on which resource. Prefer temporary role credentials over long-lived access keys.

Set placeholders to your own values. Angle-bracket values such as `<AWS_REGION>` are intentionally not real identifiers.

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

A successful command proves that files were processed as configured. It does not prove that the primer choices or scientific conclusions are correct.

## Bash on an existing EC2 instance

Amazon EC2 provides virtual machines. The helper in `ec2/run_baseline.sh` uses an existing private instance, local POSIX work storage, a private Amazon ECR image, and private S3 inputs and outputs. **Amazon ECR** is private container image storage. The helper does not create an instance, open a network port, or change a security group.

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

## AWS Batch pattern 1: copy in, run, copy out

AWS Batch schedules container jobs and can add or remove compute capacity. The simplest migration keeps the Bash pipeline unchanged: copy input objects from S3 into task-local storage, run the pipeline, then upload the result.

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

## AWS Batch pattern 2: stage jobs with `dependsOn`

A **job dependency** keeps a job pending until an earlier job succeeds. An **array job** creates indexed child jobs from one submission. With an `N_TO_N` dependency, child index 4 in one array waits for child index 4 in the previous array. This maps naturally to one child per SELEX round.

The following commands create the dependency graph. Each referenced job definition must implement the named stage, use `AWS_BATCH_JOB_ARRAY_INDEX` for S1 through S3, and exchange intermediates through a private run-specific S3 prefix.

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

## Nextflow on AWS Batch

Nextflow turns each process into a Batch job and tracks dependencies for you. With the `batch` profile, Nextflow stages S3 input files into task storage and requires an S3 work prefix. A small head process must remain running to coordinate the workflow.

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

See [nextflow/README.md](nextflow/README.md) and the [Nextflow AWS Batch executor documentation](https://docs.seqera.io/nextflow/aws#aws-batch).

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

The compute hosts must mount the private input bucket at `/mnt/s3-input` and expose that host path read-only to task containers. Mounted paths are passed as strings rather than Nextflow `path` inputs. Nextflow therefore cannot detect an object whose contents changed without changing its mounted path. Use versioned or immutable keys, or run without `-resume` after an input change.

Read [the storage guide](docs/storage.md) and [Mountpoint file-system behavior](https://github.com/awslabs/mountpoint-s3/blob/main/doc/SEMANTICS.md).

## AWS HealthOmics

AWS HealthOmics is a managed service for bioinformatics workflows. This repository packages the same Nextflow workflow as a private workflow and launches it with restricted networking, private S3 data, and a private same-Region ECR image.

Start with [healthomics/README.md](healthomics/README.md). Its helper supports package, register, run, and status operations but intentionally has no delete operation. The infrastructure template retains the bucket, encryption key, and repository when the stack is deleted, so cleanup is separate and deliberate.

See the [AWS HealthOmics private-workflow documentation](https://docs.aws.amazon.com/omics/latest/dev/private-workflows.html).

## Validate before comparing platforms

Run the repository checks first:

```bash
python3 -m unittest discover --start-directory tests --pattern 'test_*.py' --verbose
bash -n pipeline/run_pipeline.sh pipeline/s1_qc.sh pipeline/s2_trim.sh pipeline/s3_count.sh pipeline/s5_fold.sh ec2/run_baseline.sh nextflow/run_batch.sh healthomics/orchestrate.sh
python3 -m json.tool nextflow/nextflow_schema.json >/dev/null
python3 -m json.tool healthomics/parameter-template.json >/dev/null
python3 -m json.tool healthomics/run-parameters.example.json >/dev/null
```

Then compare outputs from the same immutable inputs, image digest, primers, and parameters. Checksums provide byte-level comparison; parsed tables provide a more useful scientific comparison when harmless file ordering differs. See [the validation guide](docs/validation.md).

## Security defaults

- Keep S3 Block Public Access enabled and disable ACL-based ownership.
- Encrypt S3 objects and compute volumes. Use customer-managed KMS keys when your requirements call for control over key policy and rotation.
- Use private ECR repositories with immutable tags, record the resolved digest, and prefer digest-pinned images for runs.
- Put compute in private subnets when possible. Do not add inbound rules or SSH merely to operate a batch workflow.
- Use separate least-privilege roles for provisioning, the Nextflow head process, Batch jobs, EC2 hosts, and HealthOmics runs.
- Limit S3 permissions to the required input, work, and output scopes. The included Batch job role is stack-scoped across `runs/`, so use separate stacks or per-run roles if IAM-enforced run isolation is required. Input roles should not receive delete permission.
- Treat FASTQ files and derived sequences as sensitive unless their public status and redistribution terms are confirmed.
- Do not place credentials, account IDs, resource identifiers, private data, or execution logs in commits or issue reports.

See [SECURITY.md](SECURITY.md) for reporting and deployment guidance.

## Cleanup

Cleanup is destructive even when a workflow is educational. First inspect the target, use service dry-run features where available, save required results elsewhere, and get explicit operator approval before removing cloud data or resources.

Use the dry-run-first commands in [the storage and cleanup guide](docs/storage.md#cleanup). Never copy a placeholder cleanup command without replacing and checking every value.

## Known limitations

- D1 is public RNA/Ion Torrent data, so it does not validate DNA/Illumina-specific behavior.
- The workflow assumes single-end FASTQ files and one input file per round.
- Primer layout, error tolerance, and length filters are study-specific.
- RPM normalizes library size but does not remove every experimental or amplification bias.
- Enrichment ranks observed sequences; it does not demonstrate binding.
- RNAfold predicts a secondary structure. It does not replace experimental structure or affinity measurements.
- MD simulation is outside this repository.
- Mountpoint compatibility depends on actual file operations. Test every tool version and access pattern before relying on it.
- Nextflow Mountpoint inputs passed as strings weaken cache-change detection.
- AWS Batch and HealthOmics require pre-created AWS resources, quotas, permissions, and container images.
- The supplied HealthOmics infrastructure is a starting point for review, not a complete production environment.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE).
