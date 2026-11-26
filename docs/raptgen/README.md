[English](README.md) | [한국어](README.ko.md)

# RaptGen guides

RaptGen generates new aptamer candidate sequences from SELEX sequencing data. RaptGen-UI is its web front end. These guides show how to run both on AWS, from a plain explanation of the ideas to copy-paste steps. The technical reference for the code is in [`raptgen/README.md`](../../raptgen/README.md).

| Guide | Read it to |
|---|---|
| [Concepts](concepts.md) | understand aptamers, SELEX, RaptGen and RaptGen-UI, with no background needed |
| [RaptGen on AWS Batch](batch.md) | build the images, deploy the job definitions, run training and the benchmark on CPU or GPU, read results in S3 |
| [CPU vs GPU benchmark](benchmark.md) | see the measured speed difference, why it is small, and what that means |
| [RaptGen-UI on a private EC2 host](ui.md) | run the web UI with no public IP, reach it through an SSM port forward, see test results and screenshots |
| [Web access (optional)](ui-web.md) | open the UI in a browser through CloudFront and Cognito, with a full and a read-only role (read the warning first) |
| [RaptGen on HealthOmics](healthomics.md) | placeholder for the next phase |

## Suggested order

1. Read [Concepts](concepts.md) (10 minutes).
2. Create the Batch stack with the compute you want (CPU, GPU or both): [Batch only](../getting-started/20-batch.md). Back in this folder, follow [RaptGen on AWS Batch](batch.md).
3. Optional: [RaptGen-UI](ui.md) on a private host, and then [web access](ui-web.md) if you really need a browser address.

For the whole repository and the other paths (Batch only, HealthOmics only, both, one after another), start at the [main README](../../README.md).

## Safety in short

- Everything is private by default: no public IPs, no inbound rules, SSM for access.
- RaptGen-UI has no login and no per-user data. Anyone who can reach it can delete every model.
- Use public or non-sensitive sequence data.
- Prices change. This documentation names the billed parts and leaves prices to the AWS pricing pages.

Images in `images/` are screenshots of RaptGen-UI (Hamada Lab, MIT).
