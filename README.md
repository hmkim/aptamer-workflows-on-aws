[English](README.md) | [한국어](README.ko.md)

# Aptamer workflows on AWS

This repository shows how one aptamer sequencing analysis can move from a Bash script on a single machine to AWS Batch, Nextflow, and AWS HealthOmics, and how to run RaptGen, a deep-learning model for aptamer sequences, on AWS Batch with CPU or GPU. The emphasis is on execution and storage patterns rather than on a new scientific method.

This is an independent educational project. It is **not an official AWS sample or template**, and it is not production-ready without review for your data, security requirements, quotas, and operating model.

## What is new

- **RaptGen and RaptGen-UI.** Container images, AWS Batch job definitions, a CPU vs GPU benchmark, and RaptGen-UI on a private EC2 host reached through AWS Systems Manager port forwarding. See [docs/raptgen](docs/raptgen/README.md).
- **GPU is optional.** One Batch template gives CPU only, CPU + GPU, or GPU only.
- **HealthOmics VPC mode, optional and not yet validated.** The default stays `RESTRICTED` networking.
- **Setup scripts** in `scripts/` for each path, and a cleanup script.
- **Korean guides.** Every document has a `.ko.md` twin.

## Choose your path

Every path starts with [prerequisites](docs/getting-started/00-prerequisites.md). Each guide is copy-paste, one step at a time, and says what you should see.

| I want to | Guide | Main command |
|---|---|---|
| Try the pipeline on my machine first | [Local run and EC2 baseline](docs/getting-started/05-local.md) | `docker run ...` |
| AWS Batch, CPU only | [Batch: CPU only](docs/getting-started/20-batch.md#cpu-only) | `scripts/setup-batch.sh --cpu` |
| AWS Batch, CPU + GPU | [Batch: CPU + GPU](docs/getting-started/20-batch.md#cpu--gpu) | `scripts/setup-batch.sh --cpu --gpu` |
| AWS Batch, GPU only (RaptGen) | [Batch: GPU only](docs/getting-started/20-batch.md#gpu-only) | `scripts/setup-batch.sh --gpu` |
| Nextflow on the Batch queue | [Nextflow on AWS Batch](docs/getting-started/25-nextflow.md) | `nextflow/run_batch.sh` |
| AWS HealthOmics only (`RESTRICTED`) | [HealthOmics](docs/getting-started/30-healthomics.md) | `scripts/setup-healthomics.sh` |
| HealthOmics VPC mode (not yet validated) | [HealthOmics: VPC mode](docs/getting-started/30-healthomics.md#optional-vpc-networking-mode-not-yet-validated) | `scripts/setup-healthomics.sh --vpc` |
| Batch and HealthOmics at once | [Both at once](docs/getting-started/40-both.md#both-at-once) | `scripts/setup-all.sh` |
| One now, the other later | [One after another](docs/getting-started/40-both.md#one-after-another) | the two scripts, same `--prefix` |
| RaptGen training and benchmark on Batch | [RaptGen on Batch](docs/raptgen/batch.md) | `raptgen/batch/submit-train.sh` |
| RaptGen-UI on a private EC2 host | [RaptGen-UI](docs/raptgen/ui.md) | `raptgen/ui/connect.sh` |
| Remove everything | [Cleanup](docs/getting-started/90-cleanup.md) | `scripts/cleanup.sh` |

The [shared network guide](docs/getting-started/10-network.md) explains the private VPC that Batch, the RaptGen-UI host, and HealthOmics VPC mode use. The setup scripts create it when needed.

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

RaptGen is a separate, optional module. It learns a low-dimensional map of the sequences in a SELEX dataset and can propose new candidate sequences. See [RaptGen concepts](docs/raptgen/concepts.md).

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
├── batch/               AWS Batch templates (network, CPU and/or GPU compute), submission and job scripts
├── data/                Public D1 manifest and checksum-verifying downloader
├── docs/
│   ├── getting-started/ Step-by-step guides for each path (English and Korean)
│   ├── raptgen/         RaptGen and RaptGen-UI guides, benchmark, screenshots
│   ├── architecture.md  Execution models and data flow
│   ├── storage.md       S3, local storage, staging, Mountpoint, and per-run cleanup
│   └── validation.md    Static, functional, and cross-run validation
├── ec2/                 Helper for a baseline run on an existing EC2 instance
├── healthomics/         Private HealthOmics workflow packaging and infrastructure; vpc/ for VPC mode
├── nextflow/            One DSL2 workflow with local, Batch, Mountpoint, and HealthOmics profiles
├── pipeline/            Bash and Python implementation of the scientific stages
├── raptgen/             RaptGen images, Batch jobs, RaptGen-UI host, optional web access, results
├── scripts/             setup-network, setup-batch, setup-healthomics, setup-all, cleanup
├── tests/               Unit, contract, template, script, and documentation tests
├── Dockerfile           Pipeline container image with the tools pinned in environment.yml
└── buildspec.yml        AWS CodeBuild steps that build the image and push it to private Amazon ECR
```

## Prerequisites

Moved to [docs/getting-started/00-prerequisites.md](docs/getting-started/00-prerequisites.md): tools, credentials, Region, quotas (including the GPU quota), and what costs money.

## Quick start: local Bash in Docker

Moved to [docs/getting-started/05-local.md](docs/getting-started/05-local.md#quick-start-local-bash-in-docker).

## Bash on an existing EC2 instance

Moved to [docs/getting-started/05-local.md](docs/getting-started/05-local.md#bash-on-an-existing-ec2-instance).

## AWS Batch implementation in `batch/`

Moved to [docs/getting-started/20-batch.md](docs/getting-started/20-batch.md#reference-what-is-in-batch). Technical reference: [batch/README.md](batch/README.md).

## AWS Batch pattern 1: copy in, run, copy out

Moved to [docs/getting-started/20-batch.md](docs/getting-started/20-batch.md#pattern-1-copy-in-run-copy-out).

## AWS Batch pattern 2: stage jobs with `dependsOn`

Moved to [docs/getting-started/20-batch.md](docs/getting-started/20-batch.md#pattern-2-stage-jobs-with-dependson).

## Nextflow on AWS Batch

Moved to [docs/getting-started/25-nextflow.md](docs/getting-started/25-nextflow.md#nextflow-on-aws-batch).

## Nextflow with read-only Mountpoint input

Moved to [docs/getting-started/25-nextflow.md](docs/getting-started/25-nextflow.md#nextflow-with-read-only-mountpoint-input).

## AWS HealthOmics

Moved to [docs/getting-started/30-healthomics.md](docs/getting-started/30-healthomics.md). Technical reference: [healthomics/README.md](healthomics/README.md) and, for VPC mode, [healthomics/vpc/README.md](healthomics/vpc/README.md).

## Validate before comparing platforms

Moved to [docs/validation.md](docs/validation.md), including the infrastructure checks in `batch/validate.sh`.

## Security defaults

- Keep S3 Block Public Access enabled and disable ACL-based ownership.
- Encrypt S3 objects and compute volumes. Use customer-managed KMS keys when your requirements call for control over key policy and rotation.
- Use private ECR repositories with immutable tags, record the resolved digest, and prefer digest-pinned images for runs.
- Put compute in private subnets. No public IP addresses, no inbound rules, and no SSH are needed to operate these workflows.
- Reach RaptGen-UI only through AWS Systems Manager port forwarding. The optional CloudFront and Amazon Cognito web access puts the UI on the internet behind a login: every user with the full role can delete every model. Read the warning in [the web access guide](docs/raptgen/ui-web.md) and verify the login gate before opening the origin.
- Use separate least-privilege roles for provisioning, the Nextflow head process, Batch jobs, EC2 hosts, and HealthOmics runs.
- Limit S3 permissions to the required input, work, and output scopes. The included Batch job role is stack-scoped across `runs/`, so use separate stacks or per-run roles if IAM-enforced run isolation is required. Input roles should not receive delete permission.
- Keep HealthOmics in `RESTRICTED` networking unless the workflow has a reviewed need for VPC connectivity.
- Treat FASTQ files and derived sequences as sensitive unless their public status and redistribution terms are confirmed.
- Do not place credentials, account IDs, resource identifiers, private data, or execution logs in commits or issue reports.

See [SECURITY.md](SECURITY.md) for reporting and deployment guidance.

## Cleanup

Moved to [docs/getting-started/90-cleanup.md](docs/getting-started/90-cleanup.md) for stacks and retained data, and [the storage guide](docs/storage.md#cleanup) for single runs. Cleanup is destructive: inspect the target, save required results, and get explicit approval first.

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
- AWS Batch and HealthOmics require AWS resources, quotas, permissions, and container images. GPU compute needs G-family vCPU quota.
- HealthOmics VPC mode is not yet validated in this repository.
- RaptGen training is not seeded upstream, so trained models are not bit-for-bit reproducible.
- The supplied infrastructure is a starting point for review, not a complete production environment.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE). RaptGen (MIT) and RaptGen-UI are separate upstream projects under their own licenses; see the `NOTICE` files in `raptgen/containers/` and the upstream repositories.
