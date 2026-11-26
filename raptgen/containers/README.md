[English](README.md) | [한국어](README.ko.md)

# RaptGen container images

How to build, push and use them: [RaptGen on AWS Batch](../../docs/raptgen/batch.md).

| | `cpu/` | `gpu/` |
|---|---|---|
| ECR repository | `RaptgenCpuRepositoryUri` | `RaptgenGpuRepositoryUri` |
| Base | `python:3.12.16-slim-trixie` (digest pinned) | same |
| torch | `2.14.1+cpu` (sha256 pinned wheel) | `2.14.1+cu126` (sha256 pinned) + CUDA runtime wheels from `requirements-cuda.txt` |
| Python deps | `requirements.lock` + `requirements-s3.lock` (`--require-hashes`) | same, plus `requirements-cuda.txt` |
| GPU driver | none | host NVIDIA driver >= 560 (A10G `g5`, L4 `g6`, L40S `g6e`, H100 `p5`) |

Upstream RaptGen `c4986ca9fa439b9389916c05829da4ff9c30d6f3` (MIT, see `NOTICE`) is fetched at build
time, checked against `source-checksums.sha256`, patched (`patches/`, np.int alias, float64 probability
normalization, Bayesian optimization excluded) and checked against `patched-checksums.sha256`.
Both images run as UID 10001, expose no port, and have no daemon.

## Entry points

| Command | Purpose |
|---|---|
| `raptgen-job train` | stage input (S3 or built-in), run upstream `real.py` then `encode.py`, upload model, loss CSV, `embed_seq.csv`, `train.log`, `run.json` to `RAPTGEN_OUTPUT` |
| `raptgen-bench` | fixed-epoch timing of `real.py` on dataset A (`BENCH_DEVICES`, `BENCH_MINCOUNTS`, `BENCH_EPOCHS`, `BENCH_OUT`); one JSON line per run |
| `smoke-test` | network-free contract test on the upstream sample |
| `tool-version` | versions as JSON |

`raptgen-job` options (or `RAPTGEN_*` env vars): `--input s3://...|builtin:A_4R|builtin:sample`,
`--output s3://bucket/prefix/`, `--epochs`, `--threshold`, `--min-count`, `--device cpu|cuda`,
`--run-id`, `--local-out DIR` (copy results locally instead of S3).

## Build and test

```bash
raptgen/containers/build.sh cpu --no-push          # local build only
docker run --rm --network none --read-only --tmpfs /tmp --user 10001:10001 \
  -v "$PWD/smoke:/smoke-out" -e SMOKE_OUT=/smoke-out <image> /usr/local/bin/smoke-test
docker run --rm --gpus all -e BENCH_EPOCHS=5 <gpu-image> /usr/local/bin/raptgen-bench
raptgen/containers/build.sh cpu                    # build, push, print the digest URI
```

`build.sh` tags `<upstream-commit12>-<git-sha7>`, logs in to ECR and prints the digest. Use the digest
URI in `../batch/jobs.yaml`.

## Open items

- CUDA wheels are exact pins, not hash-locked. The resolved set is written to
  `/usr/share/doc/aptamer-raptgen/pip-freeze.txt` (GPU image); a hash lock can be generated from it.
- `python-dateutil` is 2.9.0.post0 (with `six`) instead of 4.0.0 because botocore requires `<3`.
- Blackwell GPUs (sm_120) need a CUDA 12.8+ torch build.
