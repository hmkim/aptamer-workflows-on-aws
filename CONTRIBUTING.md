[English](CONTRIBUTING.md) | [한국어](CONTRIBUTING.ko.md)

# Contributing

Contributions should keep this repository useful as a public, independent educational project. It is not an official AWS sample or template.

## Before proposing a change

1. Open an issue describing the problem, intended behavior, and affected execution pattern.
2. Separate scientific changes from infrastructure changes when possible.
3. Explain every new bioinformatics or cloud term in plain language at first use.
4. Do not include private data, customer or person names, account IDs, resource identifiers, credentials, costs, execution logs, or local absolute paths.
5. Do not add molecular dynamics simulation without first agreeing on a separate scope and validation model.

## Development setup

Clone your fork and enter the repository:

```bash
git clone 'https://github.com/<GITHUB_USER>/aptamer-workflows-on-aws.git'
cd aptamer-workflows-on-aws
git remote add upstream 'https://github.com/<UPSTREAM_ORGANIZATION>/aptamer-workflows-on-aws.git'
```

Create a topic branch:

```bash
git fetch upstream
git switch --create '<TOPIC_BRANCH_NAME>' upstream/main
```

Build the local container:

```bash
docker build --tag aptamer-workflow:development .
```

## Required checks

Run the offline checks from the repository root:

```bash
python3 -m unittest discover --start-directory tests --pattern 'test_*.py' --verbose
bash -n pipeline/run_pipeline.sh pipeline/s1_qc.sh pipeline/s2_trim.sh pipeline/s3_count.sh pipeline/s5_fold.sh ec2/run_baseline.sh nextflow/run_batch.sh healthomics/orchestrate.sh data/fetch_dra009383.sh
python3 -m py_compile pipeline/enrich.py tests/test_enrich.py
python3 -m json.tool nextflow/nextflow_schema.json >/dev/null
python3 -m json.tool healthomics/parameter-template.json >/dev/null
python3 -m json.tool healthomics/run-parameters.example.json >/dev/null
```

When Nextflow is available, parse every profile:

```bash
nextflow run nextflow/main.nf --help
nextflow config nextflow/nextflow.config -profile local >/dev/null
nextflow config nextflow/nextflow.config -profile batch >/dev/null
nextflow config nextflow/nextflow.config -profile batch_mountpoint >/dev/null
nextflow config nextflow/nextflow.config -profile healthomics >/dev/null
```

Run cloud tests only in an authorized non-production environment. Review every planned write before execution and clean up only after a separate dry run and explicit approval.

## Scientific changes

A scientific change must state:

- The hypothesis or defect being addressed
- Supported molecule type and sequencing layout
- Input assumptions
- Parameter defaults and their source
- Expected outputs
- Positive, negative, and edge-case tests
- Limits on interpretation

Do not claim that enrichment proves binding or that a predicted fold proves a three-dimensional structure. D1 is public RNA/Ion Torrent data and must not be described as DNA/Illumina or customer data.

## Storage changes

Any Mountpoint change must preserve these rules:

- Mount inputs read-only.
- Keep temporary files and outputs on local POSIX storage.
- Never use Mountpoint as the Nextflow work directory.
- Test the exact tool version and file-access pattern.
- Document the `-resume` cache limitation for mounted string paths.

## Security changes

Keep resources private by default. Use least-privilege IAM roles, private S3 buckets, private ECR images, encryption, immutable run prefixes, and no inbound network access for non-interactive jobs. Follow [SECURITY.md](SECURITY.md).

## Documentation and links

Use complete commands with explicit `<PLACEHOLDER_NAMES>`. Do not use omitted arguments or three-dot abbreviations. Test relative links and verify external links before submitting. When you change an English document `X.md`, update its Korean twin `X.ko.md` with the same headings, commands, and links.

## Pull request checklist

- [ ] The change has one clear purpose.
- [ ] Tests cover new behavior.
- [ ] Offline validation passes.
- [ ] Documentation explains new terms in plain language.
- [ ] Commands are complete and placeholders are explicit.
- [ ] Public-data and scientific limitations remain accurate.
- [ ] The change contains no private or identifying information.
- [ ] No resource is made public and no authentication or safety control is weakened.
- [ ] Cleanup instructions begin with inspection or dry run.
