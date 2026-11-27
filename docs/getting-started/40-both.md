[English](40-both.md) | [한국어](40-both.ko.md)

# AWS Batch and HealthOmics together

Batch and HealthOmics are independent stacks that share one prefix. You can deploy them at once, or one after the other in either order. All scripts are idempotent: running one again with the same options changes nothing.

| Stack | Created by | Needs the network |
|---|---|---|
| `<prefix>-network` | `setup-network.sh`, or automatically | — |
| `<prefix>-batch` | `setup-batch.sh` | yes |
| `<prefix>-healthomics` | `setup-healthomics.sh` | no |
| `<prefix>-healthomics-vpc` | `setup-healthomics.sh --vpc` (not yet validated) | yes |

Start with [prerequisites](00-prerequisites.md).

```bash
export AWS_REGION='<REGION>'
export PREFIX='aptamer-workflows'
```

## Both at once

```bash
scripts/setup-all.sh --prefix "$PREFIX" --region "$AWS_REGION"
```

This runs `setup-network.sh`, then `setup-batch.sh` (CPU only by default), then `setup-healthomics.sh` (`RESTRICTED` mode). You should see each stack reach `CREATE_COMPLETE` and finally `all stacks for prefix aptamer-workflows are deployed`.

Options passed through:

| Option | Goes to | Meaning |
|---|---|---|
| `--cpu`, `--gpu` | `setup-batch.sh` | compute choice; see [the Batch guide](20-batch.md#step-2-deploy-the-stack) |
| `--build-image` | `setup-batch.sh` | build the CPU pipeline image in CodeBuild |
| `--gpu-max-vcpus <n>`, `--gpu-instance-types <list>` | `setup-batch.sh` | GPU capacity |
| `--mountpoint-version <v>`, `--mountpoint-sha256 <h>` | `setup-batch.sh` | Mountpoint package pin |
| `--vpc`, `--interface-endpoints`, `--endpoint-services <list>` | `setup-healthomics.sh` | HealthOmics VPC mode (not yet validated) |
| `--yes` | `setup-batch.sh` | allow turning off compute that is on (see [Change compute later](20-batch.md#change-compute-later)) |

Example: CPU + GPU Batch with the pipeline image, and HealthOmics in `RESTRICTED` mode:

```bash
scripts/setup-all.sh --prefix "$PREFIX" --region "$AWS_REGION" --cpu --gpu --build-image
```

Then continue with the run steps of each guide: [Batch steps 5 to 7](20-batch.md#step-5-load-the-public-d1-data-cpu) and [HealthOmics steps 2 to 7](30-healthomics.md#step-2-deploy-the-stack) (step 2 only reads the outputs again; the stack already exists). The HealthOmics stack has its own bucket and ECR repository, so build and push the workflow image there as in HealthOmics step 3.

## One after another

### Batch first, then HealthOmics

1. Follow [the Batch guide](20-batch.md).
2. Later, follow [the HealthOmics guide](30-healthomics.md) with the **same** `PREFIX` and Region. The Batch stack is not touched.
3. With `--vpc`, `setup-healthomics.sh` finds the existing `<prefix>-network` and reuses it (`using existing network stack ...`).

### HealthOmics first, then Batch

1. Follow [the HealthOmics guide](30-healthomics.md). Without `--vpc` no network exists yet, and none is billed.
2. Later, follow [the Batch guide](20-batch.md) with the same `PREFIX`. `setup-batch.sh` creates the network (`network stack ... not found; creating it`) or reuses the one that VPC mode created.

### Add or remove one part later

- Add GPU to Batch: `scripts/setup-batch.sh --prefix "$PREFIX" --region "$AWS_REGION" --cpu --gpu`.
- Add HealthOmics VPC mode: `scripts/setup-healthomics.sh --prefix "$PREFIX" --region "$AWS_REGION" --vpc`.
- Remove only one part: `scripts/cleanup.sh --stacks <list>`; see [cleanup](90-cleanup.md).

## Validated on

Validated on 2026-11-26 in us-west-2: `setup-all.sh --cpu` created the network, CPU-only Batch and `RESTRICTED` HealthOmics stacks in about 7.5 minutes, and `scripts/cleanup.sh --delete-data` removed them. The one-after-another path (Batch first, then HealthOmics, same prefix) was also run. Details: [the validation guide](../validation.md#validated-on).

## Next

- [RaptGen on the Batch stack](../raptgen/README.md)
- [Clean up](90-cleanup.md)
