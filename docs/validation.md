[English](validation.md) | [한국어](validation.ko.md)

# Validation guide

Validation answers two different questions:

1. Did the software run reproducibly and produce the expected file structure?
2. Is the scientific configuration appropriate for the experiment?

Passing software checks does not answer the second question. A qualified scientist should review primer sequences, expected aptamer length, trimming tolerance, round labels, and the interpretation of enrichment.

## Scope of the included data

D1 is public RNA SELEX data generated with Ion Torrent sequencing. It is not customer DNA data and it is not Illumina data. D1 can exercise round-based QC, trimming, counting, RPM normalization, enrichment, and RNA folding. It cannot validate DNA-aptamer chemistry, Illumina-specific artifacts, paired-end handling, or a private experimental protocol.

Molecular dynamics simulation is excluded and has no validation claim here.

## 1. Static repository checks

Run these commands from the repository root:

```bash
python3 -m unittest discover --start-directory tests --pattern 'test_*.py' --verbose
bash -n pipeline/run_pipeline.sh pipeline/s1_qc.sh pipeline/s2_trim.sh pipeline/s3_count.sh pipeline/s5_fold.sh ec2/run_baseline.sh nextflow/run_batch.sh healthomics/orchestrate.sh data/fetch_dra009383.sh
python3 -m py_compile pipeline/enrich.py tests/test_enrich.py
python3 -m json.tool nextflow/nextflow_schema.json >/dev/null
python3 -m json.tool healthomics/parameter-template.json >/dev/null
python3 -m json.tool healthomics/run-parameters.example.json >/dev/null
```

If Nextflow is installed, also parse each profile:

```bash
nextflow run nextflow/main.nf --help
nextflow config nextflow/nextflow.config -profile local >/dev/null
nextflow config nextflow/nextflow.config -profile batch >/dev/null
nextflow config nextflow/nextflow.config -profile batch_mountpoint >/dev/null
nextflow config nextflow/nextflow.config -profile healthomics >/dev/null
```

Check the infrastructure templates and scripts. These make no AWS calls:

```bash
bash -n scripts/*.sh scripts/lib/common.sh healthomics/vpc/omics-vpc-configuration.sh
bash batch/validate.sh
```

`batch/validate.sh` checks Bash syntax and CloudFormation YAML in `batch/` and runs `cfn-lint` and ShellCheck when they are installed. It fails if a template has inbound network rules or public-address flags, or lacks the EC2 instance metadata hop limit, S3 Block Public Access, or read-only Mountpoint settings. It also fails on a fixed account ID or an internal URL anywhere in `batch/`. The unit tests also check that every document has a Korean twin, a language switch line, and working relative links.

If AWS CLI credentials are configured for the intended test account, ask CloudFormation to parse the HealthOmics template without creating resources:

```bash
aws cloudformation validate-template \
  --region '<AWS_REGION>' \
  --template-body 'file://healthomics/infrastructure.yaml' \
  >/dev/null
```

## 2. Public-data integrity

Download D1 through the repository helper:

```bash
bash data/fetch_dra009383.sh data/dra009383_manifest.tsv inputs/DRA009383
```

The helper requires HTTPS and checks each downloaded file against the MD5 value in the public manifest. MD5 is used here to detect download corruption because the archive publishes those values. It should not be treated as a modern cryptographic authenticity guarantee.

Confirm that nine files exist and that no partial download remains:

```bash
test "$(find inputs/DRA009383 -maxdepth 1 -type f -name 'R*_*.fastq.gz' | wc -l)" -eq 9
test "$(find inputs/DRA009383 -maxdepth 1 -type f -name '*.part' | wc -l)" -eq 0
```

## 3. Baseline run

Run the local Docker command in [the local run guide](getting-started/05-local.md) first. Treat its output as the reference only after reviewing the parameters.

Check the required files:

```bash
test -s outputs/bash-d1/qc/stats.tsv
test -s outputs/bash-d1/enrich/top_candidates.tsv
test -s outputs/bash-d1/enrich/unique_ratio.tsv
test -s outputs/bash-d1/fold/top_candidates.fold
test -s outputs/bash-d1/checksums.sha256
```

Verify every checksum from inside the output directory:

```bash
cd outputs/bash-d1
sha256sum --check checksums.sha256
cd ../..
```

Review, rather than merely count, the rows that remain after trimming. An empty or unexpectedly small output can indicate a wrong primer orientation, incorrect error tolerance, or unsuitable length limits.

## 4. Cross-platform comparison

Use the same values for all compared runs:

- Exact input object versions or checksums
- Container image digest, not only a mutable tag
- Front and back primers
- Trimming error rate, overlap, and length limits
- Pseudocount and top-candidate count
- Workflow revision

A **pseudocount** is a small added value that prevents division by zero when a sequence is absent from an earlier round. Changing it changes reported fold enrichment.

Download each result into a separate directory:

```bash
export AWS_REGION='<AWS_REGION>'
aws s3 sync 's3://<PRIVATE_OUTPUT_BUCKET>/<BASH_OUTPUT_PREFIX>/' validation/bash --region "$AWS_REGION" --only-show-errors
aws s3 sync 's3://<PRIVATE_OUTPUT_BUCKET>/<BATCH_OUTPUT_PREFIX>/' validation/batch --region "$AWS_REGION" --only-show-errors
aws s3 sync 's3://<PRIVATE_OUTPUT_BUCKET>/<NEXTFLOW_OUTPUT_PREFIX>/' validation/nextflow --region "$AWS_REGION" --only-show-errors
aws s3 sync 's3://<PRIVATE_OUTPUT_BUCKET>/<HEALTHOMICS_OUTPUT_PREFIX>/' validation/healthomics --region "$AWS_REGION" --only-show-errors
```

All execution modes name the ranking file `top_candidates.tsv`. Normalize line endings and compare the tables:

```bash
tr -d '\r' < validation/bash/enrich/top_candidates.tsv > validation/bash.top.tsv
tr -d '\r' < validation/batch/enrich/top_candidates.tsv > validation/batch.top.tsv
tr -d '\r' < validation/nextflow/enrich/top_candidates.tsv > validation/nextflow.top.tsv
tr -d '\r' < validation/healthomics/enrich/top_candidates.tsv > validation/healthomics.top.tsv

diff --unified validation/bash.top.tsv validation/batch.top.tsv
diff --unified validation/nextflow.top.tsv validation/healthomics.top.tsv
```

Do not assume the Bash and Nextflow table schemas are identical. Compare equivalent columns when implementations intentionally use different names or numeric formatting. A useful acceptance check compares sequence rank, count, RPM, previous-round enrichment, and first-round enrichment after parsing numeric fields with an agreed tolerance.

## 5. Structural and scientific checks

| Check | Why it matters | Evidence |
|---|---|---|
| One unique round label per input | Duplicate rounds can silently mix experiments. | Samplesheet and input listing |
| At least two rounds | Enrichment requires a comparison. | Workflow validation |
| Nonzero reads after trimming | Wrong primers can remove all useful reads. | Cutadapt report and count table |
| RPM sums close to one million per round | Confirms normalization arithmetic. | Parsed count tables |
| Deterministic tie ordering | Repeated runs should rank equal observations consistently. | Unit test and repeated comparison |
| Declining unique ratio only when supported by data | Selection may concentrate a library, but the trend is not guaranteed. | `unique_ratio.tsv` plus experimental context |
| Fold output count matches selected candidates | Detects dropped or malformed sequences. | Parsed ranking and fold files |

Do not define success as finding a desired motif or trend. Pre-register acceptance criteria before looking at results when the analysis supports a decision.

## 6. Mountpoint validation

Test the exact compute image and mount configuration. Keep the mount read-only.

```bash
export MOUNT_PATH='/mnt/s3-input'
export LOCAL_TEST_DIRECTORY="$HOME/aptamer-mountpoint-test"
mkdir -p "$LOCAL_TEST_DIRECTORY"
mountpoint "$MOUNT_PATH"
find "$MOUNT_PATH" -maxdepth 1 -type f -name '*.fastq.gz' -print
seqkit stats --tabular "$MOUNT_PATH/<ONE_FASTQ_FILE_NAME>" > "$LOCAL_TEST_DIRECTORY/stats.tsv"
test -s "$LOCAL_TEST_DIRECTORY/stats.tsv"
```

Then run each real stage with output, current working directory, and `TMPDIR` on local POSIX storage. A read test alone is insufficient. Do not test write failure against valuable objects, and do not use a production prefix for destructive compatibility experiments.

For Nextflow Mountpoint runs, change the mounted object key when content changes or run with `RESUME=false`. Verify that `NXF_WORK` is an `s3://` URI and not a mounted path.

## 7. Operational evidence

For each run, retain only the evidence allowed by your data policy:

- Run status and stage status
- Input checksums or version identifiers
- Image digest and workflow revision
- Parameters without secrets
- Output checksum manifest
- Failure reason with sensitive paths and identifiers removed before sharing

Do not commit cloud account IDs, resource identifiers, private object keys, execution logs, or research results to a public repository.

## Validated on

This table records end-to-end runs of the [getting-started guides](getting-started/00-prerequisites.md) on a fresh set of stacks. A path without a row is not validated.

Runs below used new stack prefixes, the guide commands as written (after the fixes noted in each guide), and the public D1 data. Durations are wall-clock times on that day and change with Region, capacity and network speed.

| Path | Guide | Date | Region | Result |
|---|---|---|---|---|
| Batch, CPU only | [20-batch](getting-started/20-batch.md#cpu-only) | 2026-11-26 | us-west-2 | Pass. `setup-network.sh` 2 min, `setup-batch.sh --cpu` 4 min, `--build-image` (CodeBuild) 2 min, D1 loader 7 min (incl. instance start), copy-in pattern 1: 3 min queue wait + 10 s run, `collect_results.sh` OK. |
| Batch, CPU + GPU | [20-batch](getting-started/20-batch.md#cpu--gpu) | 2026-11-26 | us-west-2 | Pass. CPU to CPU + GPU update 1 min; RaptGen train (3 epochs) on CPU and on GPU (`g5.xlarge`, A10G) and the 2-epoch benchmark on both queues succeeded; back from GPU only to CPU + GPU 1 min, then copy-in again OK. |
| Batch, GPU only | [20-batch](getting-started/20-batch.md#gpu-only) | 2026-11-26 | us-west-2 | Pass. Without `--yes` the script refused to turn CPU off; with `--yes` the update took 3 min while a GPU job kept running; `submit-train.sh --device cpu` then stopped with the "queue is disabled" message. |
| HealthOmics, `RESTRICTED` | [30-healthomics](getting-started/30-healthomics.md) | 2026-11-26 | us-west-2 | Pass. Stack 1 min, image build and push 1 min, D1 upload 4 min, register 15 s, run on D1 about 10 min to `COMPLETED`. Sorted `top_candidates.tsv` SHA-256 equal to the Batch copy-in result. |
| HealthOmics, VPC mode | [30-healthomics](getting-started/30-healthomics.md#optional-vpc-networking-mode-not-yet-validated) | not yet validated | — | — |
| RaptGen on Batch | [raptgen/batch](raptgen/batch.md) | 2026-11-26 | us-west-2 | Pass. CPU image build 2 min, GPU image 7 min; job definitions 1 min; train 3 epochs: CPU 133 s total, GPU 149 s total (train 48 s, encode 102 s); benchmark `--device both --epochs 2`: CPU 24 s/epoch, A10G 17 s/epoch at min-count 2. |
| RaptGen-UI on a private EC2 host | [raptgen/ui](raptgen/ui.md) | 2026-11-26 | us-west-2 | Pass via SSM Run Command: host stack 3 min, `install.sh` 12 min, UI answers on 127.0.0.1:18042, `e2e_api.py` `ALL: PASS` (10-epoch VAE 242 s, GMM 10 s). The SSM port forward (`connect.sh`) was not exercised (no Session Manager plugin on the test workstation). |
| RaptGen-UI web access | [raptgen/ui-web](raptgen/ui-web.md) | 2026-11-26 | us-east-1 (gate), us-west-2 (host) | Pass. Re-install with `--bind-private-ip` 1 min, gate deploy 12 min, `verify-gate.sh` 15/15 OK before opening the origin, `e2e-roles.ts` `E2E PASS` (full role trained 10 epochs in 227 s; read-only role got 403 on every write). First gate delete ended `DELETE_FAILED` on the Lambda@Edge version, as documented. |
| Both at once (`setup-all.sh`) | [40-both](getting-started/40-both.md#both-at-once) | 2026-11-26 | us-west-2 | Pass. `setup-all.sh --cpu` (CPU only Batch + HealthOmics `RESTRICTED`) 7.5 min; network, Batch and HealthOmics stacks `CREATE_COMPLETE` with outputs. |
| Cleanup | [90-cleanup](getting-started/90-cleanup.md) | 2026-11-26 | us-west-2, us-east-1 | Pass. `cleanup.sh --delete-data` removed the RaptGen-UI host, RaptGen job definitions, HealthOmics, Batch and network stacks with their buckets, ECR repositories and log group (6.5 min; 4 min for the `setup-all.sh` prefix). The web gate stack first ended `DELETE_FAILED` on the Lambda@Edge version and deleted on a retry about 25 minutes later; its retained user pool and log bucket were removed by hand. KMS keys stay in their 7-day pending-deletion window. |

## Acceptance checklist

- [ ] Static checks pass.
- [ ] Public downloads match their published checksums.
- [ ] Primer and length settings have scientific review.
- [ ] Every run uses the same immutable inputs and image digest.
- [ ] Required files are nonempty.
- [ ] Checksum manifests verify.
- [ ] Equivalent tables agree within the documented numeric tolerance.
- [ ] Mountpoint behavior is tested with every tool version and access pattern used.
- [ ] Security controls remain private and least-privilege.
- [ ] Cleanup targets were previewed and separately approved.
