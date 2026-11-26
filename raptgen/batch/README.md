[English](README.md) | [한국어](README.ko.md)

# RaptGen on AWS Batch

Step-by-step guide: [RaptGen on AWS Batch](../../docs/raptgen/batch.md). Measured speeds: [benchmark](../../docs/raptgen/benchmark.md).

`jobs.yaml` creates up to four job definitions, each only if its image parameter is set:
`raptgen-train-cpu`, `raptgen-train-gpu`, `raptgen-bench-cpu`, `raptgen-bench-gpu`
(prefix via `NamePrefix`). CPU only, CPU + GPU and GPU only all use this template.
Containers run as UID 10001 with a read-only root filesystem and a 2 GiB tmpfs `/tmp`;
GPU definitions request 1 GPU. Logs go to the batch stack log group.

| Script | Does |
|---|---|
| `submit-train.sh --device cpu\|gpu [--input ...] [--epochs N] [--min-count N]` | picks the queue for the device (fails clearly when that queue is disabled), sets the run id and `s3://<WorkBucketName>/raptgen/<run-id>/`, submits |
| `submit-bench.sh --device cpu\|gpu\|both [--epochs N]` | resolves all queues first, then submits. The GPU job times CUDA, then CPU on the same instance |
| `status.sh <job-id>` / `--list` | status, reason, results location, and for finished benchmark jobs the JSON result lines |

Defaults: `--stack-prefix aptamer-workflows` (env `STACK_PREFIX`), `--jobdef-prefix raptgen`.
Training defaults: bundled dataset A, 50 epochs, min-count 2 (3,043 unique sequences). Min-count 1
(38,513 unique sequences) takes about 10 times longer per epoch (see `../results/benchmark`).
GPU memory default 14 GiB fits `g5.xlarge`; change `GpuMemoryMiB` for other instances.
