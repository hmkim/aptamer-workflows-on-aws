[English](healthomics.md) | [한국어](healthomics.ko.md)

# RaptGen on AWS HealthOmics (next phase)

**Placeholder. Nothing here is implemented or validated yet.** This page only reserves the place in the documentation for the next phase. For what works today, see [RaptGen on AWS Batch](batch.md).

## Plan

- Run RaptGen train and encode as an AWS HealthOmics private workflow, reusing the container images from [`raptgen/containers`](../../raptgen/containers/README.md).
- Find out which GPU instance types HealthOmics runs offer, and whether the GPU image fits them.
- Compare against the Batch results (same input, same parameters; compare run time and loss curves). RaptGen training is not seeded, so compare results statistically, not bit for bit.

## Where the work will live

[`raptgen/healthomics/`](../../raptgen/healthomics/README.md) holds the workflow definition, parameter templates and the comparison notes once they exist. For the HealthOmics setup of this repo (RESTRICTED networking by default, optional VPC mode that is not yet validated), see [`healthomics/README.md`](../../healthomics/README.md).

Back to [Index](README.md)
