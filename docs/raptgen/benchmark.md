[English](benchmark.md) | [한국어](benchmark.ko.md)

# RaptGen: CPU vs GPU benchmark

This page reports one measurement of RaptGen training speed on a GPU and on CPUs, what the numbers mean, and where they stop being reliable. To repeat the measurement yourself, see [RaptGen on AWS Batch](batch.md#step-4-run-the-cpu-vs-gpu-benchmark-optional).

## What was measured

- The upstream RaptGen training script `scripts/real.py`, **unchanged**, on the same data on CPU and on GPU.
- Data: the RaptGen paper dataset A (`data/real/A_4R.fastq`, 80,864 reads, public). It is also the RAPT1 sample used in [ui](ui.md).
- Settings: 5 fixed epochs, early stopping off, `--reg-epochs 1`, batch size 512 (the upstream default).
- Software: the images in [`raptgen/containers`](../../raptgen/containers/README.md): Python 3.12, PyTorch 2.14.1 with CUDA 12.6 wheels, same source and patches for CPU and GPU.
- Raw data: [`raptgen/results/benchmark/`](../../raptgen/results/README.md), one JSON line per event.

| Run | Where | Hardware |
|---|---|---|
| GPU and CPU | AWS Batch, `g5.xlarge` | NVIDIA A10G (24 GB), 4 vCPU AMD EPYC 7R32. PyTorch used 2 CPU threads. |
| CPU | EC2 `m7i.2xlarge`, run in a container with no network | 8 vCPU Intel Xeon 8488C. PyTorch used 4 CPU threads. |

## Results

Seconds per epoch. Smaller is faster.

| Hardware | Device | 3,043 unique sequences (min-count 2) | 38,513 unique sequences (min-count 1) |
|---|---|---|---|
| `g5.xlarge` | **GPU (A10G)** | **14.1** | **144.3** |
| `g5.xlarge` | CPU (2 threads) | 32.6 | 275.4 |
| `m7i.2xlarge` | CPU (4 threads) | 17.5 | 187.6 |

| Comparison | 3,043 sequences | 38,513 sequences |
|---|---|---|
| GPU vs the CPU of the same `g5.xlarge` | 2.3x faster | 1.9x faster |
| GPU vs `m7i.2xlarge` CPU | 1.2x faster | 1.3x faster |

The last test loss of the three runs on 38,513 sequences is close (40.72 on GPU, 40.82 on the g5 CPU, 40.91 on m7i). That shows the three runs did the same work. It is not a statement about sequence quality.

## Why the GPU gain is small

RaptGen's pHMM loss walks over sequence positions with a **nested Python loop**: for a 30-base random region it loops 31 times over positions and 31 times over motif states (upstream `raptgen/models.py`, lines 156-157), so each batch makes about 961 small GPU calls one after another.

```text
profile_hmm_loss
  for i in range(random_len + 1):        # 31 iterations for a 30 nt region
      for j in range(motif_len + 1):     # 31 iterations  -> about 961 small steps per batch
```

A GPU is fast when it does a few large calculations. Many small calls issued one at a time spend their time waiting. So for this code the GPU is only a little faster than a good CPU.

## What it means

| Observation | Meaning |
|---|---|
| One GPU is 1.2 to 1.3x faster than a good 8 vCPU CPU on this code | Do not expect a GPU to cut training time from days to hours. Measure with your own data first. |
| Instance prices differ | Check the EC2 pricing page for your Region. With a gain this small, a CPU instance can be the cheaper choice for this code. |
| Training runs are independent of each other (different seeds, inputs, or repeats with `--multi`) | **Running many jobs at once** shortens wall-clock time the most. AWS Batch does this naturally: submit several jobs and let the compute environment scale out. |

This is why this repo lets you choose CPU only, CPU and GPU, or GPU only for the same RaptGen jobs.

## Limits of this measurement

- 5 epochs, one data set, **one run per table cell**, no repeats. This is not a statistical benchmark.
- Training is not seeded upstream. Timings are for single runs.
- CPU thread counts differ by instance (2 on the g5, 4 on the m7i). PyTorch chose these defaults. Larger CPU instances (for example 16 to 32 vCPU) were not measured.
- One GPU type only (A10G). L4, L40S and H100 were not measured.
- Full training to convergence was not timed, only per-epoch time.
- The code was not optimized (`torch.compile`, larger batches, rewriting the loop). A faster loss implementation would change the picture.
- Results from a different Region, instance generation or PyTorch version can differ.

Next: [RaptGen-UI on a private EC2 host](ui.md) | [Index](README.md)
