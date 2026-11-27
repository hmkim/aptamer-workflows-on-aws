[English](concepts.md) | [한국어](concepts.ko.md)

# RaptGen and RaptGen-UI: concepts

This page explains what RaptGen and RaptGen-UI are, in plain terms. You need no machine-learning background. For the AWS steps, go to [RaptGen on AWS Batch](batch.md) or [RaptGen-UI on a private EC2 host](ui.md).

## At a glance

| Question | Answer |
|---|---|
| What is RaptGen? | A model that learns from SELEX sequencing data and **generates new aptamer candidate sequences**. |
| What is RaptGen-UI? | A web application that runs the RaptGen workflow from a browser, without the command line. |
| Who made them? | Both come from the Hamada Lab at Waseda University ([hmdlab](https://github.com/hmdlab)). |
| License | Both are MIT licensed. |
| Is a GPU required? | No. Both run on CPU. A GPU helps less than you might expect; see [CPU vs GPU benchmark](benchmark.md). |
| Input and output | Input is sequencing reads (FASTQ/FASTA). Output is **sequences only**. No 3D structure and no binding strength. |

```text
 SELEX experiment -> NGS sequencing -> trim / count -> RaptGen -> candidate sequences -> structure / docking / MD -> lab validation
                                                          ^
                                                RaptGen-UI lets you run
                                                this step from a browser
```

## Background: aptamer and SELEX

**Aptamer.** An aptamer is a short piece of DNA or RNA, usually a few dozen bases long. It binds a target molecule (a protein, a small molecule) tightly, much like an antibody does.

**SELEX.** SELEX is a lab method that repeats "keep the sequences that bind well" many times:

```text
trillions of random sequences -> expose to the target -> keep what binds -> amplify by PCR -> repeat (round 1, 2, 3 ...)
```

Each round enriches the sequences that bind well. Reading every round with next-generation sequencing (NGS) gives tens of thousands to millions of sequences. This is **HT-SELEX** (high-throughput SELEX). A typical read looks like this:

```text
[fixed front primer] [random region] [fixed back primer]
 TAATACGACTCACTATAGGG...  (about 30 random bases)  ...CCTATGCGTGCTAGTGTGA
```

**Limit of count-based analysis.** The usual analysis ranks sequences by how often they appear or how much they grow from round to round. That can only pick sequences that were actually read. A better sequence that was never sequenced stays invisible. RaptGen was built to reduce that limit.

## What RaptGen does

RaptGen turns each sequence into a **point on a 2D map** and can create a new sequence from any point on that map. It was published as: Iwano N. et al., *Nature Computational Science* 2022 ([article](https://www.nature.com/articles/s43588-022-00249-6)).

| Everyday picture | In RaptGen |
|---|---|
| A city map | The latent space (a 2D coordinate system) |
| One house | One sequence |
| A neighborhood | A group of sequences sharing a motif (a common pattern) |
| Building a new house on empty land | Generating a sequence that was not in the training data |

### The four steps

| Step | Name | What happens | Result |
|---|---|---|---|
| 1 | VAE training | The model learns how to place sequences on the map | A trained model |
| 2 | Encode | Sequence to coordinates | An (x, y) per sequence |
| 3 | GMM clustering | Points on the map are grouped into clusters | Cluster centers act as representative sequences |
| 4 | Decode / BO | Coordinates to sequence. Bayesian optimization uses lab measurements to choose the next coordinates | New candidate sequences |

### Terms

- **VAE** (variational autoencoder): a model that squeezes data into a few numbers and expands it back.
- **pHMM** (profile hidden Markov model): a probability model of sequence patterns. RaptGen uses it in the "expand back" half of the VAE so that it captures motifs well.
- **GMM** (Gaussian mixture model): a way to split points into a few oval-shaped groups.
- **BO** (Bayesian optimization): a way to decide, from the measurements so far, which candidate to measure next.

### What the paper showed

- On simulated data, sequences separated cleanly by motif on the map.
- On two real SELEX data sets, RaptGen generated sequences that were **not in the sequencing data** and some of them bound the target.
- It also produced shorter (truncated) aptamers.
- It showed a loop that feeds lab measurements into BO to find better sequences.

### What to know in practice

| Item | Detail |
|---|---|
| Original code | [hmdlab/raptgen](https://github.com/hmdlab/raptgen), last commit 2022-12-17. This repo pins `c4986ca9fa439b9389916c05829da4ff9c30d6f3`. |
| Original environment | Ubuntu 18.04, Python 3.7, PyTorch 1.5, CUDA 10.2. It no longer builds as is. This repo ships hash-locked images (Python 3.12, PyTorch 2.14.1); see [`raptgen/containers`](../../raptgen/containers/README.md). |
| How you use it | Command-line scripts (`real.py` to train, `encode.py`, `decode.py`). |
| DNA or RNA | Both can be given as input (A/C/G/T/U). |
| Output | Sequences only. |
| Bayesian optimization | Excluded from the Batch images (the old GPyOpt dependency). RaptGen-UI has its own BO. |

## What RaptGen-UI does

RaptGen-UI runs the whole RaptGen flow from a browser. It was published as: Nakano R. et al., *Bioinformatics Advances* 2025 ([doi:10.1093/bioadv/vbaf120](https://doi.org/10.1093/bioadv/vbaf120)). Source: [hmdlab/RaptGen-UI](https://github.com/hmdlab/RaptGen-UI), pinned here at `13cad83859dc9eac39383a00882c17c82a4cdb37`.

| Screen | What you do | RaptGen step |
|---|---|---|
| VAE Trainer | Upload FASTQ/FASTA, let it estimate primers, run training and watch progress | 1 |
| GMM Trainer | Try several cluster counts and pick the best one (BIC) | 3 |
| Viewer | Look at the map, encode sequences, pick points and decode them, sequence logo, secondary structure, download clusters | 2, 4 |
| Bayesian Optimization | Enter measurements (for example binding values), get the next candidates, save the session | 4 |

```text
 browser -> frontend (Next.js, port 18042) -/api-> backend (FastAPI)
                                                       |
                                       +---------------+---------------+
                                       v               v               v
                                  PostgreSQL     Redis -> worker (Celery, runs training)
                                  (models)       (job queue)
```

Five containers start with one `docker compose up`. Training runs in the worker; the screen only shows progress.

### RaptGen compared with RaptGen-UI

| | RaptGen (original) | RaptGen-UI |
|---|---|---|
| Form | Python command-line scripts | Web screens and an API |
| Users | People who run code | Lab scientists can use it too |
| Install | Build a Python environment yourself | Docker Compose |
| Training code | Original | A copy of the RaptGen model inside the backend (see [ui](ui.md#which-raptgen-version-the-ui-contains)) |
| Results | Files | PostgreSQL database |
| Bayesian optimization | Script (GPyOpt, old) | Screen, with BoTorch (qEI) |
| Managing many jobs | By hand | Job list, stop, resume, delete |
| Automation / pipelines | Easy (commands) | Possible through the API; no official automation tool |
| Last update | 2022-12 | 2026-01-31 (`13cad83`) |
| Login | Not applicable | **None.** It is designed for your own computer. |

Because RaptGen-UI has no login, this repo only exposes it through a private EC2 host and an SSM port forward. See [ui](ui.md), and [ui-web](ui-web.md) for the optional web front door.

## Limits

- The results here show that the **software runs**. They say nothing about the scientific quality of generated sequences. Judge that with your own data and experiments.
- RaptGen-UI describes itself around RNA aptamers. DNA input is accepted, but some features such as secondary-structure display may assume RNA.
- Whether RaptGen-UI's training code and the RaptGen Batch images give the same results has not been compared.

## Sources

| Source | Content |
|---|---|
| [hmdlab/raptgen](https://github.com/hmdlab/raptgen) | RaptGen code (MIT) |
| [hmdlab/RaptGen-UI](https://github.com/hmdlab/RaptGen-UI) | RaptGen-UI code (MIT) |
| Iwano N. et al., *Nat Comput Sci* 2022 ([article](https://www.nature.com/articles/s43588-022-00249-6)) | RaptGen paper |
| Nakano R. et al., *Bioinformatics Advances* 5(1) vbaf120, 2025 ([doi](https://doi.org/10.1093/bioadv/vbaf120)) | RaptGen-UI paper |

Next: [RaptGen on AWS Batch](batch.md) | [Index](README.md)
