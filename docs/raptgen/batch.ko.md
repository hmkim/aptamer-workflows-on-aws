[English](batch.md) | [한국어](batch.ko.md)

# AWS Batch에서 RaptGen 실행

이 가이드는 RaptGen 컨테이너 이미지를 빌드하고, Batch job definition을 등록하고, CPU 또는 GPU에서 학습 job과 벤치마크를 실행한 뒤, 결과가 S3 어디에 저장되는지 확인합니다.

**AWS Batch**는 EC2 인스턴스를 알아서 켜고 꺼 가며 컨테이너를 큐 방식의 job으로 실행해 주는 관리형 서비스입니다. **job definition**은 job 한 종류의 레시피(이미지, 메모리, 명령)입니다. **job queue**는 제출된 job을 compute environment에 자리가 날 때까지 보관합니다.

여기서 쓰는 파일의 기술 참조: [`raptgen/README.md`](../../raptgen/README.ko.md), [`raptgen/batch/README.md`](../../raptgen/batch/README.ko.md), [`raptgen/containers/README.md`](../../raptgen/containers/README.ko.md).

## 시작하기 전에

1. **원하는 compute가 있는 Batch 스택.** [Batch만 사용](../getting-started/20-batch.ko.md)을 따라 하세요. CPU, GPU, 또는 둘 다 켤 수 있습니다.

   | 원하는 것 | Batch 스택 설정 | 실행할 수 있는 RaptGen job |
   |---|---|---|
   | CPU만 | `scripts/setup-batch.sh --cpu` (기본값) | `--device cpu` |
   | CPU와 GPU | `scripts/setup-batch.sh --cpu --gpu` | `--device cpu`, `--device gpu` |
   | GPU만 | `scripts/setup-batch.sh --gpu` | `--device gpu` |

   스택 이름은 `<prefix>-batch`입니다 (기본 prefix는 `aptamer-workflows`). 이 스택이 이 가이드에서 쓰는 ECR 저장소 `raptgen-cpu`, `raptgen-gpu`, job role, 로그 그룹을 만듭니다.

2. **GPU 할당량 (GPU 경로만).** GPU 인스턴스(`g5`, `g6`)는 **Running On-Demand G and VT instances** vCPU 할당량을 사용하며, 새 계정에서는 이 값이 0인 경우가 많습니다. GPU compute environment를 켜기 전에 Service Quotas에서 확인하세요. 할당량이 모자라면 GPU job이 계속 `RUNNABLE`에 머뭅니다.

3. **내 컴퓨터에 필요한 것:** BuildKit이 있는 Docker, 대상 계정 자격 증명이 설정된 AWS CLI v2, `git`, `python3`. 이미지 빌드는 패키지와 RaptGen 원본 소스를 내려받으므로 인터넷이 필요합니다. 첫 빌드에는 수 GB의 디스크가 필요합니다.

4. **Region을 지정합니다.** 아래 모든 명령 전에 실행하세요 (`<REGION>`은 실제 값으로 바꿉니다).

   ```bash
   export AWS_REGION=<REGION> AWS_DEFAULT_REGION=<REGION>
   export STACK_PREFIX=aptamer-workflows     # Batch 스택에 쓴 prefix
   ```

   스크립트는 `${STACK_PREFIX}-batch` 스택의 output을 읽습니다.

5. **비용 안내.** job이 도는 동안의 Batch 인스턴스, GPU 인스턴스(별도 요금), 네트워크 스택 NAT gateway(시간당), CloudWatch Logs, S3와 ECR 저장 용량에 요금이 부과됩니다. 해당 Region의 AWS 요금 페이지를 확인하세요. 필요 없는 리소스는 [정리](../getting-started/90-cleanup.ko.md)로 지우세요.

## 1단계. 이미지 빌드와 push

저장소 루트에서 실행합니다. 켜 둔 종류에 맞게 빌드하세요.

```bash
raptgen/containers/build.sh cpu
raptgen/containers/build.sh gpu
```

스크립트가 하는 일: 로컬에서 이미지를 빌드하고, `<upstream-commit12>-<git-sha7>` 태그를 붙이고, 내 private ECR에 로그인해 push한 뒤 digest URI를 출력합니다.

실행이 끝나면 이렇게 보여야 합니다.

```text
image digest URI (use this in raptgen/batch/jobs.yaml parameters):
<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/raptgen-cpu@sha256:<64자리 16진수>
```

URI 두 개(또는 빌드한 하나)를 복사해 두세요. 2단계에서 씁니다. push 없이 빌드만 하려면 `--no-push`를 붙입니다.

스택에 `RaptgenGpuRepositoryUri` output이 없다는 메시지가 나오면 Batch 스택에서 GPU compute를 켜지 않은 것입니다. `scripts/setup-batch.sh --cpu --gpu`를 다시 실행하세요.

## 2단계. job definition 배포

Batch 스택에서 값을 읽습니다.

```bash
JOB_ROLE=$(aws cloudformation describe-stacks --stack-name "$STACK_PREFIX-batch" \
  --query "Stacks[0].Outputs[?OutputKey=='PipelineJobRoleArn'].OutputValue" --output text)
LOG_GROUP=$(aws cloudformation describe-stacks --stack-name "$STACK_PREFIX-batch" \
  --query "Stacks[0].Outputs[?OutputKey=='LogGroupName'].OutputValue" --output text)
echo "$JOB_ROLE" "$LOG_GROUP"
```

role ARN과 로그 그룹 이름이 출력되어야 합니다.

배포합니다. 빌드한 이미지 URI만 넘기세요. 넘기지 않은 쪽의 job definition은 만들어지지 않습니다.

```bash
aws cloudformation deploy --stack-name "$STACK_PREFIX-raptgen-jobs" \
  --template-file raptgen/batch/jobs.yaml \
  --parameter-overrides \
    CpuImageUri=<cpu-digest-uri> \
    GpuImageUri=<gpu-digest-uri> \
    JobRoleArn="$JOB_ROLE" LogGroupName="$LOG_GROUP"
```

`Successfully created/updated stack`이 보여야 합니다. Batch 콘솔의 **Job definitions**에 최대 4개가 보입니다.

| Job definition | 하는 일 | 필요한 값 |
|---|---|---|
| `raptgen-train-cpu` | CPU로 학습 + encode | `CpuImageUri` |
| `raptgen-train-gpu` | GPU 1개로 학습 + encode | `GpuImageUri` |
| `raptgen-bench-cpu` | CPU 시간 측정 벤치마크 | `CpuImageUri` |
| `raptgen-bench-gpu` | GPU 1개로 측정한 뒤 같은 인스턴스의 CPU로도 측정 | `GpuImageUri` |

모든 컨테이너는 non-root 사용자(UID 10001), 읽기 전용 루트 파일 시스템, 2 GiB tmpfs `/tmp`로 실행되고 들어오는 네트워크 포트가 없습니다. 로그는 Batch 스택의 로그 그룹으로 갑니다. 이미지는 태그가 아니라 digest로 고정됩니다.

## 3단계. 학습 job 실행

```bash
raptgen/batch/submit-train.sh --device cpu
# 또는
raptgen/batch/submit-train.sh --device gpu
```

`--input`을 주지 않으면 두 이미지에 들어 있는 RaptGen 논문 dataset A(`data/real/A_4R.fastq`, 80,864 reads, 공개 데이터)를 사용합니다. 기본값은 50 epoch, `--min-count 2`(고유 서열 3,043개)입니다. 내 reads를 쓰려면 job role이 읽을 수 있는 버킷(work bucket도 가능)에 FASTQ를 올리고 지정하세요.

```bash
raptgen/batch/submit-train.sh --device cpu --input s3://<WORK_BUCKET>/my-reads.fastq --epochs 100
```

| 옵션 | 뜻 |
|---|---|
| `--device cpu\|gpu` | 필수. 큐와 job definition을 정합니다. 해당 compute가 꺼져 있으면 명확한 메시지와 함께 실패합니다. |
| `--input` | `s3://bucket/key`, `builtin:A_4R`(기본값), `builtin:sample` |
| `--epochs N` | 학습 epoch 수, 기본 50 |
| `--min-count N` | 최소 N번 나온 서열만 사용, 기본 2. min-count 1은 서열이 더 많고(dataset A 기준 고유 38,513개) epoch당 약 10배 느립니다. |
| `--threshold N` | 원본 학습 스크립트에 전달, 기본 50 |
| `--stack-prefix`, `--jobdef-prefix` | 기본값 `aptamer-workflows`, `raptgen` |

이렇게 보여야 합니다.

```text
submitted train-cpu-<timestamp>
  job id : <JOB_ID>
  queue  : <queue name>
  output : s3://<WORK_BUCKET>/raptgen/train-cpu-<timestamp>/
check with: raptgen/batch/status.sh <JOB_ID>
```

## 4단계. CPU vs GPU 벤치마크 실행 (선택)

```bash
raptgen/batch/submit-bench.sh --device both      # 또는 cpu, gpu
```

벤치마크는 dataset A로 5 epoch(`--epochs`로 변경)를 고정 실행하고 실행마다 JSON 한 줄을 출력합니다. `--device both`는 두 compute environment가 모두 필요하며 CPU job 하나와 GPU job 하나를 제출합니다. GPU job은 CUDA를 먼저 측정하고 같은 GPU 인스턴스의 CPU로도 측정합니다. 결과 해석은 [benchmark](benchmark.ko.md)에 있습니다.

## 5단계. job 확인과 결과 읽기

```bash
raptgen/batch/status.sh <JOB_ID>
raptgen/batch/status.sh --list           # 켜 둔 모든 큐의 최근 job
```

상태는 `SUBMITTED` → `RUNNABLE` → `STARTING` → `RUNNING` → `SUCCEEDED`(또는 `FAILED`)로 바뀝니다. `RUNNABLE`은 Batch가 인스턴스를 기다리는 상태입니다. EC2가 켜지는 동안 첫 job은 몇 분 기다릴 수 있습니다. 오래 `RUNNABLE`이면 보통 할당량이나 용량 문제입니다. GPU라면 "시작하기 전에"의 G 인스턴스 할당량을 확인하세요.

`status.sh`는 결과가 저장될 S3 위치도 출력합니다. job이 `SUCCEEDED`가 되면 학습 job은 다음을 써 둡니다.

```bash
aws s3 ls s3://<WORK_BUCKET>/raptgen/train-cpu-<timestamp>/
```

| 파일 | 내용 |
|---|---|
| 모델 파일 | 학습된 RaptGen 모델 |
| loss CSV | epoch별 학습/테스트 loss |
| `embed_seq.csv` | 모든 서열의 encode된 좌표 |
| `train.log` | 학습 로그 |
| `run.json` | 이 실행의 입력, 파라미터, 장치, 버전, 시간 |

벤치마크 job은 JSON 줄을 job의 CloudWatch 로그 스트림에 씁니다. 끝난 벤치마크 job은 `status.sh`가 그 줄을 출력합니다.

한 실행의 결과를 모두 내려받으려면:

```bash
aws s3 cp --recursive s3://<WORK_BUCKET>/raptgen/train-cpu-<timestamp>/ ./raptgen-run/
```

## 알아 두면 좋은 점

- 원본 학습 코드는 seed를 고정하지 않으므로, 같은 입력으로 두 번 돌리면 비슷하지만 똑같지는 않은 모델이 나옵니다.
- Batch 이미지에는 Bayesian optimization이 없습니다. BO는 [RaptGen-UI](ui.ko.md)를 쓰세요.
- 학습 실행끼리는 서로 독립입니다. 입력, 파라미터, 반복을 바꿔 job을 여러 개 제출하면 병렬로 돕니다. [benchmark](benchmark.ko.md#의미)를 보세요.
- 공개 데이터 또는 민감하지 않은 데이터만 사용하세요. work bucket은 암호화되고 비공개이지만, 내 데이터 규정을 먼저 확인하세요.

## 아직 검증되지 않은 것

| 항목 | 상태 |
|---|---|
| 새 스택에서 이 가이드대로 실행 (CPU, GPU, 둘 다) | `TODO(validation)`: 검증 실행 후 결과를 추가합니다 |

다음: [CPU vs GPU 벤치마크](benchmark.ko.md) | [목차](README.ko.md)
