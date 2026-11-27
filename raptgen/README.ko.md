[English](README.md) | [한국어](README.ko.md)

# raptgen

AWS에서 [RaptGen](https://github.com/hmdlab/raptgen)(SELEX 데이터용 서열 VAE, MIT)과 [RaptGen-UI](https://github.com/hmdlab/RaptGen-UI)를 실행합니다. 이 폴더의 기술 참조 문서입니다. 단계별 가이드는 [`docs/raptgen/`](../docs/raptgen/README.ko.md)와 `docs/getting-started/`에 있습니다.

| 폴더 | 내용 |
|---|---|
| `containers/cpu`, `containers/gpu` | 해시를 고정한 이미지 (Python 3.12, PyTorch 2.14.1 CPU / CUDA 12.6), `raptgen-job`, `raptgen-bench`, smoke test. `containers/build.sh`가 빌드하고 ECR에 push합니다. |
| `batch/` | `jobs.yaml`(AWS Batch job definition)과 `submit-train.sh`, `submit-bench.sh`, `status.sh`. |
| `ui/` | 사설 EC2 호스트의 RaptGen-UI: `ec2.yaml`, `install.sh`, `connect.sh`(SSM 포트 포워딩), 패치, API end-to-end 테스트. |
| `ui-web/` | 선택 사항인 CloudFront + Cognito 접속 (CDK). full과 readonly 역할. |
| `results/` | 정리된 벤치마크(`benchmark/*.jsonl`)와 UI 테스트 로그(`ui/`). |
| `healthomics/` | 다음 단계를 위한 자리. |

고정된 원본 버전: RaptGen `c4986ca9fa439b9389916c05829da4ff9c30d6f3`, RaptGen-UI `13cad83859dc9eac39383a00882c17c82a4cdb37`.

## 예상되는 스택 output (network와 batch 스택)

`<prefix>-batch` (기본 prefix `aptamer-workflows`): `CpuJobQueueName`, `GpuJobQueueName` (둘 중 하나는 없을 수 있음), `JobQueueName`, `PipelineJobRoleArn`, `WorkBucketName`, `DataBucketName`, `LogGroupName`, `RaptgenCpuRepositoryUri`, `RaptgenGpuRepositoryUri`.
`<prefix>-network`: `VpcId`, `PrivateSubnetIds`.

## 명령

```bash
# 1. 이미지 (CPU, GPU 또는 둘 다. 저장소 루트에서 실행)
raptgen/containers/build.sh cpu            # <repo-uri>@sha256:... 를 출력
raptgen/containers/build.sh gpu

# 2. job definition (이미지를 비워 두면 그 장치는 건너뜀)
aws cloudformation deploy --stack-name aptamer-workflows-raptgen-jobs \
  --template-file raptgen/batch/jobs.yaml \
  --parameter-overrides NamePrefix=aptamer-workflows-raptgen \
    CpuImageUri=<cpu-digest-uri> GpuImageUri=<gpu-digest-uri> \
    JobRoleArn=<PipelineJobRoleArn> LogGroupName=<LogGroupName>

# 3. 학습 / 벤치마크
raptgen/batch/submit-train.sh --device cpu|gpu [--input s3://bucket/reads.fastq] [--epochs 50]
raptgen/batch/submit-bench.sh --device cpu|gpu|both
raptgen/batch/status.sh <job-id>

# 4. 사설 EC2 호스트의 RaptGen-UI (SSM만 사용)
aws cloudformation deploy --stack-name aptamer-workflows-raptgen-ui --capabilities CAPABILITY_IAM \
  --template-file raptgen/ui/ec2.yaml \
  --parameter-overrides VpcId=<VpcId> PrivateSubnetId=<PrivateSubnetIds 중 하나>
raptgen/ui/install.sh --instance-id <InstanceId>
raptgen/ui/connect.sh --instance-id <InstanceId>      # 그다음 http://localhost:18042

# 5. 선택: 웹 접속은 ui-web/README.ko.md 참고
```

## 참고

- 두 이미지 모두 원본 논문 dataset A(`data/real/A_4R.fastq`, 80,864 reads)를 포함하므로 CPU만 있는 환경에서도 벤치마크를 실행할 수 있습니다. `--input`이 없으면 `raptgen-job`이 이 데이터를 씁니다.
- 원본 학습은 seed를 고정하지 않으므로 학습된 모델은 bit 단위로 재현되지 않습니다.
- 공개 샘플 데이터만 사용합니다. Bayesian optimization(GPyOpt)은 Batch 이미지에서 제외했습니다. UI는 자체 backend로 BO를 합니다.
- 테스트: `python3 -m unittest discover -s tests -p 'test_raptgen_*.py'` (저장소 루트에서 실행).
