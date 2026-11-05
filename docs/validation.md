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

Run the local Docker command in the root README first. Treat its output as the reference only after reviewing the parameters.

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
