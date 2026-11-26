# Results

Public sample data only (RaptGen paper dataset A `A_4R.fastq`, 80,864 reads; RaptGen-UI bundled RAPT1).
No job ids, account ids or image digests are recorded.

## `benchmark/`

`raptgen-bench` output, 5 fixed epochs per run, early stopping off, `scripts/real.py` unchanged. One JSON line
per event. Timing only; loss values carry no science claim.

| File | Host | Device |
|---|---|---|
| `g5.xlarge-a10g-vs-cpu.jsonl` | AWS Batch `g5.xlarge` (A10G, 4 vCPU AMD EPYC 7R32), torch 2.14.1+cu126 | CUDA and CPU, same instance |
| `m7i.2xlarge-cpu.jsonl` | EC2 `m7i.2xlarge` (8 vCPU Xeon 8488C), torch 2.14.1+cu126 image, CPU only | CPU |

| unique sequences (min-count) | A10G s/epoch | g5 CPU s/epoch | m7i.2xlarge CPU s/epoch |
|---|---|---|---|
| 3,043 (2) | 14.1 | 32.6 | 17.5 |
| 38,513 (1) | 144.3 | 275.4 | 187.6 |

On this workload the GPU is about 2.3x faster than the 4 vCPU CPU of the same g5.xlarge and about 1.3x faster than
the 8 vCPU m7i.2xlarge. One run per cell; not a statistical benchmark.

## `ui/`

Logs of the RaptGen-UI API end-to-end test (`../ui/tests/e2e_api.py`): `e2e-api-10ep-part1.log` (interrupted
client), `e2e-api-resumed-10ep.log` (resumed, includes GMM and Bayesian optimization, ends `ALL: PASS`),
`vae-worker-epoch-log.log` (worker epochs). Job UUIDs are replaced by `<uuid>`. Screenshots are in `docs/raptgen/images/`.
