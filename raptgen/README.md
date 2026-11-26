[English](README.md) | [한국어](README.ko.md)

# raptgen

[RaptGen](https://github.com/hmdlab/raptgen) (sequence VAE for SELEX data, MIT) and
[RaptGen-UI](https://github.com/hmdlab/RaptGen-UI) on AWS. Technical reference for this folder;
step-by-step guides live under [`docs/raptgen/`](../docs/raptgen/README.md) and `docs/getting-started/`.

| Folder | What |
|---|---|
| `containers/cpu`, `containers/gpu` | Hash-locked images (Python 3.12, PyTorch 2.14.1 CPU / CUDA 12.6), `raptgen-job`, `raptgen-bench`, smoke test. `containers/build.sh` builds and pushes to ECR. |
| `batch/` | `jobs.yaml` (AWS Batch job definitions) and `submit-train.sh`, `submit-bench.sh`, `status.sh`. |
| `ui/` | RaptGen-UI on a private EC2 host: `ec2.yaml`, `install.sh`, `connect.sh` (SSM port forward), patches, API end-to-end test. |
| `ui-web/` | Optional CloudFront + Cognito front door (CDK) with a full and a read-only role. |
| `results/` | Sanitized benchmark (`benchmark/*.jsonl`) and UI test logs (`ui/`). |
| `healthomics/` | Placeholder for the next phase. |

Pinned upstream: RaptGen `c4986ca9fa439b9389916c05829da4ff9c30d6f3`, RaptGen-UI
`13cad83859dc9eac39383a00882c17c82a4cdb37`.

## Expected stack outputs (from the network and batch stacks)

`<prefix>-batch` (default prefix `aptamer-workflows`): `CpuJobQueueName`, `GpuJobQueueName`
(either may be absent), `JobQueueName`, `PipelineJobRoleArn`, `WorkBucketName`, `DataBucketName`,
`LogGroupName`, `RaptgenCpuRepositoryUri`, `RaptgenGpuRepositoryUri`.
`<prefix>-network`: `VpcId`, `PrivateSubnetIds`.

## Commands

```bash
# 1. images (CPU, GPU or both; run from the repo root)
raptgen/containers/build.sh cpu            # prints  <repo-uri>@sha256:...
raptgen/containers/build.sh gpu

# 2. job definitions (leave an image empty to skip that device)
aws cloudformation deploy --stack-name aptamer-workflows-raptgen-jobs \
  --template-file raptgen/batch/jobs.yaml \
  --parameter-overrides CpuImageUri=<cpu-digest-uri> GpuImageUri=<gpu-digest-uri> \
    JobRoleArn=<PipelineJobRoleArn> LogGroupName=<LogGroupName>

# 3. train / benchmark
raptgen/batch/submit-train.sh --device cpu|gpu [--input s3://bucket/reads.fastq] [--epochs 50]
raptgen/batch/submit-bench.sh --device cpu|gpu|both
raptgen/batch/status.sh <job-id>

# 4. RaptGen-UI on a private EC2 host (SSM only)
aws cloudformation deploy --stack-name aptamer-workflows-raptgen-ui --capabilities CAPABILITY_IAM \
  --template-file raptgen/ui/ec2.yaml \
  --parameter-overrides VpcId=<VpcId> PrivateSubnetId=<one PrivateSubnetIds entry>
raptgen/ui/install.sh --instance-id <InstanceId>
raptgen/ui/connect.sh --instance-id <InstanceId>      # then http://localhost:18042

# 5. optional web access: see ui-web/README.md
```

## Notes

- Both images ship the upstream paper dataset A (`data/real/A_4R.fastq`, 80,864 reads) so the
  benchmark runs on CPU only setups. `raptgen-job` uses it when no `--input` is given.
- Training is not seeded upstream, so trained models are not bit-reproducible.
- Public sample data only. Bayesian optimization (GPyOpt) is excluded from the batch images; the UI
  has its own backend for it.
- Tests: `python3 -m pytest tests/test_raptgen_*.py`.
