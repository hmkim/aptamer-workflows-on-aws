[English](20-batch.md) | [한국어](20-batch.ko.md)

# AWS Batch만 쓰기

**AWS Batch**는 컨테이너 job을 대신 실행해 줍니다. job을 **job queue**에 제출하면 Batch가 **compute environment**(관리형 인스턴스 풀)에서 EC2 인스턴스를 시작하고, job을 실행하고, 큐가 비면 0까지 줄입니다. **job definition**은 job의 저장된 템플릿으로, 이미지, CPU, 메모리, 역할, 명령을 담습니다.

이 가이드는 공유 네트워크와 Batch 스택 하나(`<prefix>-batch`)를 원하는 컴퓨팅 구성으로 배포합니다.

| 선택 | 플래그 | 용도 |
|---|---|---|
| CPU만 (기본값) | `--cpu` | 압타머 파이프라인(QC, trim, count, enrichment, fold)과 CPU에서 RaptGen |
| CPU + GPU | `--cpu --gpu` | 파이프라인과 GPU에서 RaptGen, 또는 CPU 대 GPU 벤치마크 |
| GPU만 | `--gpu` | GPU에서 RaptGen만. 압타머 파이프라인 job definition은 만들지 않습니다 |

세 가지 모두 같은 템플릿 `batch/infrastructure.yaml`에서 나옵니다. [사전 준비](00-prerequisites.ko.md)부터 시작하세요. GPU를 고른다면 G 계열 vCPU 할당량을 먼저 확인하세요.

## 1단계: 변수 설정

```bash
export AWS_REGION='<REGION>'
export PREFIX='aptamer-workflows'
export STACK_NAME="$PREFIX-batch"
```

`batch/`의 스크립트는 `AWS_REGION`과 `STACK_NAME`을 읽습니다.

## 2단계: 스택 배포

아래 세 명령 중 하나를 고르세요. `<prefix>-network`가 없으면 먼저 만듭니다([네트워크 가이드](10-network.ko.md) 참고).

### CPU만

```bash
scripts/setup-batch.sh --prefix "$PREFIX" --region "$AWS_REGION" --cpu
```

### CPU + GPU

```bash
scripts/setup-batch.sh --prefix "$PREFIX" --region "$AWS_REGION" --cpu --gpu
```

### GPU만

```bash
scripts/setup-batch.sh --prefix "$PREFIX" --region "$AWS_REGION" --gpu
```

보여야 하는 것:

- `compute: CPU=true GPU=false` (또는 고른 조합).
- CPU를 켠 경우: `computing SHA-256 of Mountpoint 1.25.0 (x86_64) from the official release`. CPU 호스트는 부팅할 때 Mountpoint for Amazon S3를 설치하고, 템플릿은 패키지를 체크섬으로 고정합니다. 프로덕션에서는 출력된 값을 릴리스 서명과 대조하거나 `--mountpoint-sha256 <hash>`를 직접 넘기세요.
- GPU를 켠 경우: `G/VT On-Demand vCPU quota: <n>`, 또는 할당량이 `GpuMaxvCpus`보다 낮다는 `WARNING`.
- `aptamer-workflows-batch: CREATE_COMPLETE`, 이어서 출력 표와 다음 단계 안내.

유용한 옵션(모두 선택): CPU용 `--max-vcpus`, `--instance-types`(기본 72, `c7i,c6i`), GPU용 `--gpu-max-vcpus`, `--gpu-instance-types`(기본 8, `g5.xlarge,g6.xlarge`). GPU 인스턴스는 NVIDIA 드라이버가 들어 있는 ECS GPU 최적화 Amazon Linux 2023 이미지(`ECS_AL2023_NVIDIA`)를 씁니다.

**보안 강화:** compute 보안 그룹은 이미지 pull과 D1 다운로드가 NAT gateway를 거치므로 outbound TCP 443을 `0.0.0.0/0`으로 허용합니다. 좁히려면 VPC endpoint(ECR, CloudWatch Logs, S3 gateway)를 추가하고 `batch/infrastructure.yaml`의 `ComputeSecurityGroup` egress를 그쪽으로 제한하세요.

## 3단계: 스택 확인

```bash
aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[?contains(OutputKey,`Queue`)].[OutputKey,OutputValue]' --output table
```

`JobQueueName`이 보이고, CPU를 켰다면 `CpuJobQueueName`, GPU를 켰다면 `GpuJobQueueName`도 보여야 합니다. 큐가 준비됐는지 확인합니다.

```bash
aws batch describe-job-queues --region "$AWS_REGION" --job-queues "$STACK_NAME-queue" \
  --query 'jobQueues[0].[state,status]' --output text
```

`ENABLED VALID`가 보여야 합니다. GPU는 `"$STACK_NAME-gpu-queue"`를 쓰세요.

**GPU만 구성했다면 압타머 파이프라인은 여기서 끝입니다.** [이 스택에서 RaptGen 실행](#이-스택에서-raptgen-실행)으로 넘어가세요. 4~7단계에는 CPU가 필요합니다.

## 4단계: 파이프라인 이미지 빌드 (CPU)

```bash
scripts/setup-batch.sh --prefix "$PREFIX" --region "$AWS_REGION" --build-image
```

`--cpu`나 `--gpu`를 주지 않으면 현재 컴퓨팅 설정을 그대로 둡니다. 스크립트는 이 저장소의 **커밋된** 파일을 묶고(`git archive HEAD`, 커밋하지 않은 수정은 포함되지 않음), 데이터 버킷에 올리고, AWS CodeBuild를 시작합니다. CodeBuild는 `Dockerfile`을 빌드해 스택에 기록된 태그(기본값 `git-<commit>`)로 private ECR 리포지토리에 push합니다.

`CodeBuild started for tag git-<commit>`가 보이고, 몇 분 뒤(검증 실행에서는 약 2분) `pipeline image build succeeded`가 보여야 합니다. 태그가 이미 있으면 `pipeline image tag ... already exists; skipping build`가 보입니다.

## 5단계: 공개 D1 데이터 불러오기 (CPU)

loader job이 공개 D1 파일 아홉 개를 내려받고, MD5를 확인하고, 데이터 버킷에 씁니다.

```bash
JOB_ID=$(batch/submit_loader.sh)
echo "$JOB_ID"
```

job을 기다립니다. 아래 도우미는 30초마다 상태를 출력하고 끝나면 멈춥니다.

```bash
wait_job() {
  local status
  while :; do
    status=$(aws batch describe-jobs --region "$AWS_REGION" --jobs "$1" --query 'jobs[0].status' --output text)
    printf '%s %s\n' "$(date -u +%H:%M:%S)" "$status"
    case "$status" in SUCCEEDED) return 0 ;; FAILED) return 1 ;; esac
    sleep 30
  done
}
wait_job "$JOB_ID"
```

`SUBMITTED`, `RUNNABLE`, `STARTING`, `RUNNING`, 마지막으로 `SUCCEEDED`가 보여야 합니다. 첫 job은 Batch가 인스턴스를 시작하는 동안 몇 분 기다립니다. 객체를 확인합니다.

```bash
DATA_BUCKET=$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`DataBucketName`].OutputValue' --output text)
aws s3 ls "s3://$DATA_BUCKET/input/" --region "$AWS_REGION"
```

`R<round>_DRR<number>.fastq.gz` 객체 아홉 개가 보여야 합니다. (`input`은 기본 `DataPrefix`입니다.)

## 6단계: 파이프라인 실행 (CPU)

공개된 D1 프라이머를 불러오고 실행 ID를 정합니다.

```bash
source data/dra009383.env.example
export RUN_ID="d1-$(date -u +%Y%m%d%H%M)"
JOB_ID=$(batch/submit_copyin.sh)
wait_job "$JOB_ID"
```

copy-in 패턴은 입력을 로컬 디스크로 복사하고, `pipeline/run_pipeline.sh`를 실행하고, 결과를 업로드합니다. 스크립트는 `result prefix: s3://<WorkBucketName>/runs/copyin/<RUN_ID>/result/`를 로그로 남깁니다.

같은 `RUN_ID`로 쓸 수 있는 다른 패턴([batch/README.ko.md](../../batch/README.ko.md) 참고):

```bash
ROUNDS=9 batch/submit_steps.sh          # S1-S3 array jobs per round, then S4 and S5
batch/submit_mountpoint.sh              # read-only S3 input through Mountpoint
batch/submit_compat.sh                  # Mountpoint compatibility report
```

## 7단계: 결과 모으기

```bash
batch/collect_results.sh
```

스크립트는 이 `RUN_ID`의 끝나지 않은 job을 기다린 다음 `batch/runs/<RUN_ID>/`(Git이 무시)에 씁니다. `job_status.tsv`, `job_timing.tsv`, `s3/` 아래에 내려받은 결과, 그리고 `result_compare.tsv`가 생깁니다. 마지막 파일에는 패턴별로 정렬한 `top_candidates.tsv`의 SHA-256이 있으며, 값이 같으면 표가 같다는 뜻입니다. [로컬 가이드](05-local.ko.md)의 기준 결과와 비교하려면 스크립트를 실행하기 전에 `REFERENCE_RESULT=outputs/bash-d1/enrich/top_candidates.tsv`를 설정하세요. 순위 표를 확인합니다.

```bash
column -ts $'\t' "batch/runs/$RUN_ID/s3/copyin/result/enrich/top_candidates.tsv" | sed -n '1,11p'
```

## 나중에 컴퓨팅 바꾸기

원하는 플래그로 `scripts/setup-batch.sh`를 다시 실행하세요. **플래그는 변경분이 아니라 최종 상태를 뜻합니다.** CPU + GPU 스택에 `--gpu`만 주면 CPU compute environment, 큐, 파이프라인 job definition이 삭제됩니다. `--cpu`와 `--gpu`를 모두 빼면 현재 설정이 유지됩니다. 스크립트와 템플릿은 둘 다 끄는 것을 거부합니다.

스크립트는 현재 상태와 결과 상태를 출력합니다(`compute now:   CPU=true GPU=true`, 다음에 `compute: CPU=false GPU=true`). 켜져 있는 compute를 끄게 되면 무엇이 지워지는지 `WARNING`으로 알려 주고 `yes`를 입력하라고 묻습니다. 터미널이 없으면(자동화) `--yes`를 주지 않는 한 멈춥니다.

```bash
scripts/setup-batch.sh --prefix "$PREFIX" --region "$AWS_REGION" --cpu --gpu   # add GPU to a CPU stack
```

실행 중인 job이 없을 때 하세요.

## 이 스택에서 RaptGen 실행

Batch 스택은 RaptGen용 private ECR 리포지토리 두 개도 만듭니다(출력 `RaptgenCpuRepositoryUri`, `RaptgenGpuRepositoryUri`). 이미지를 빌드하고, RaptGen job definition을 배포하고, 학습이나 CPU 대 GPU 벤치마크를 실행하는 방법은 [Batch에서 RaptGen 가이드](../raptgen/batch.ko.md)를 보세요. 배경 설명: [RaptGen 문서](../raptgen/README.ko.md).

## 참고: batch 폴더 구성

| 구성 요소 | 파일 | 역할 |
|---|---|---|
| 인프라 | `network.yaml`, `infrastructure.yaml` | AWS 리소스를 코드로 선언하는 AWS CloudFormation 템플릿입니다. private 네트워크, 암호화된 S3 버킷, private ECR 리포지토리, AWS CodeBuild 이미지 프로젝트, 최소 권한 IAM 역할, CPU와/또는 GPU compute environment와 큐, job definition 세 개를 만듭니다. |
| 운영 스크립트 | `submit_*.sh`, `upload_manifest.sh`, `collect_results.sh`, `validate.sh`, `lib/common.sh` | 워크스테이션에서 실행합니다. 스택 출력을 읽고, job을 제출하고, Git이 무시하는 `batch/runs/`에 job ID를 기록하고, 결과를 모읍니다. |
| job 스크립트 | `job_common.sh`, `run_copyin.sh`, `run_stage.sh`, `run_mountpoint.sh`, `mountpoint_compat.sh`, `load_data.sh` | 컨테이너 안에서 실행합니다. 이미지 빌드가 이 스크립트를 `/opt/aptamer/batch/`에 복사하므로 job이 실행 중에 실행 파일을 내려받지 않습니다. |

모든 job definition은 `/opt/aptamer/batch/${JOB_SCRIPT}`를 실행합니다. 각 submit 스크립트는 container override(job definition 기본값을 job 단위로 바꾸는 값)로 실행할 스크립트를 고릅니다. 파라미터와 출력은 [batch/README.ko.md](../../batch/README.ko.md)에 있습니다.

## 패턴을 직접 실행하기

아래 명령은 이미 있는 리소스에 `aws batch submit-job`을 직접 호출하는 예입니다. submit 스크립트가 하는 일을 설명하려는 것이며, 위 단계에는 필요 없습니다.

### 패턴 1: 복사해 들여오기, 실행, 복사해 내보내기

가장 단순한 이전 방식은 Bash 파이프라인을 그대로 둡니다. S3 입력 객체를 작업 로컬 스토리지로 복사하고, 파이프라인을 실행하고, 결과를 업로드합니다.

아래 명령은 이미 있는 큐와 job definition을 가정합니다. job definition의 이미지에는 이 저장소의 파이프라인 도구가 있어야 하고, job role은 입력 prefix를 읽고 출력 prefix에 쓸 수 있어야 합니다.

```bash
export AWS_REGION='<AWS_REGION>'
export BATCH_JOB_QUEUE='<BATCH_JOB_QUEUE_NAME>'
export BATCH_JOB_DEFINITION='<COPY_IN_JOB_DEFINITION_NAME_OR_ARN>'
export INPUT_URI='s3://<PRIVATE_INPUT_BUCKET>/<INPUT_PREFIX>/'
export OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/<UNIQUE_RUN_ID>/'
export FRONT_PRIMER='<FRONT_PRIMER_DNA>'
export BACK_PRIMER='<BACK_PRIMER_DNA>'

aws batch submit-job \
  --region "$AWS_REGION" \
  --job-name '<COPY_IN_JOB_NAME>' \
  --job-queue "$BATCH_JOB_QUEUE" \
  --job-definition "$BATCH_JOB_DEFINITION" \
  --container-overrides "$(jq -cn \
    --arg input "$INPUT_URI" \
    --arg output "$OUTPUT_URI" \
    --arg front "$FRONT_PRIMER" \
    --arg back "$BACK_PRIMER" \
    '{command:["bash","-lc","set -Eeuo pipefail; mkdir -p /tmp/aptamer/input /tmp/aptamer/output; aws s3 sync \"$INPUT_URI\" /tmp/aptamer/input --exclude \"*\" --include \"R*_*.fastq.gz\" --only-show-errors; run_pipeline.sh /tmp/aptamer/input /tmp/aptamer/output \"$FRONT_PRIMER\" \"$BACK_PRIMER\" 100 \"R*_*.fastq.gz\" \"^R([0-9]+)_\"; aws s3 sync /tmp/aptamer/output \"$OUTPUT_URI\" --only-show-errors"],environment:[{name:"INPUT_URI",value:$input},{name:"OUTPUT_URI",value:$output},{name:"FRONT_PRIMER",value:$front},{name:"BACK_PRIMER",value:$back}]}')" \
  --query 'jobId' \
  --output text
```

`jq`가 올바른 JSON을 만들어 주므로 셸 따옴표 처리가 container override를 망가뜨리지 않습니다. CPU, 메모리, 재시도, 타임아웃, non-root 사용자, 로깅, 최소 권한 job role은 이 명령이 아니라 job definition에서 정해야 합니다.

### 패턴 2: `dependsOn`으로 단계별 job 실행

**job dependency**는 앞선 job이 성공할 때까지 job을 대기시킵니다. **array job**은 한 번 제출로 번호가 붙은 자식 job을 만듭니다. `N_TO_N` dependency를 쓰면 한 array의 4번 자식은 앞 array의 4번 자식을 기다립니다. 그래서 SELEX 라운드마다 자식 하나를 두는 구조에 자연스럽게 맞습니다.

아래 명령이 dependency 그래프를 만듭니다. 각 job definition은 해당 단계를 구현하고, S1~S3에서는 `AWS_BATCH_JOB_ARRAY_INDEX`를 쓰고, 실행별 private S3 prefix로 중간 결과를 주고받아야 합니다.

`batch/run_stage.sh`에서 array index `n`은 라운드 `R<n>`을 고릅니다. 따라서 라운드 번호는 `R0`부터 빠짐없이 이어져야 합니다. 라운드가 빠지면 그 번호의 S1 자식이 입력 파일을 찾지 못해 실패합니다.

```bash
export AWS_REGION='<AWS_REGION>'
export BATCH_JOB_QUEUE='<BATCH_JOB_QUEUE_NAME>'
export S1_JOB_DEFINITION='<QC_ARRAY_JOB_DEFINITION_NAME_OR_ARN>'
export S2_JOB_DEFINITION='<TRIM_ARRAY_JOB_DEFINITION_NAME_OR_ARN>'
export S3_JOB_DEFINITION='<COUNT_ARRAY_JOB_DEFINITION_NAME_OR_ARN>'
export S4_JOB_DEFINITION='<ENRICH_JOB_DEFINITION_NAME_OR_ARN>'
export S5_JOB_DEFINITION='<FOLD_JOB_DEFINITION_NAME_OR_ARN>'
export RUN_NAME='<UNIQUE_RUN_NAME>'
export ROUND_COUNT='9'

S1_JOB_ID=$(aws batch submit-job --region "$AWS_REGION" --job-name "$RUN_NAME-s1-qc" --job-queue "$BATCH_JOB_QUEUE" --job-definition "$S1_JOB_DEFINITION" --array-properties "size=$ROUND_COUNT" --query 'jobId' --output text)
S2_JOB_ID=$(aws batch submit-job --region "$AWS_REGION" --job-name "$RUN_NAME-s2-trim" --job-queue "$BATCH_JOB_QUEUE" --job-definition "$S2_JOB_DEFINITION" --array-properties "size=$ROUND_COUNT" --depends-on "jobId=$S1_JOB_ID,type=N_TO_N" --query 'jobId' --output text)
S3_JOB_ID=$(aws batch submit-job --region "$AWS_REGION" --job-name "$RUN_NAME-s3-count" --job-queue "$BATCH_JOB_QUEUE" --job-definition "$S3_JOB_DEFINITION" --array-properties "size=$ROUND_COUNT" --depends-on "jobId=$S2_JOB_ID,type=N_TO_N" --query 'jobId' --output text)
S4_JOB_ID=$(aws batch submit-job --region "$AWS_REGION" --job-name "$RUN_NAME-s4-enrich" --job-queue "$BATCH_JOB_QUEUE" --job-definition "$S4_JOB_DEFINITION" --depends-on "jobId=$S3_JOB_ID" --query 'jobId' --output text)
S5_JOB_ID=$(aws batch submit-job --region "$AWS_REGION" --job-name "$RUN_NAME-s5-fold" --job-queue "$BATCH_JOB_QUEUE" --job-definition "$S5_JOB_DEFINITION" --depends-on "jobId=$S4_JOB_ID" --query 'jobId' --output text)

printf 'S1=%s\nS2=%s\nS3=%s\nS4=%s\nS5=%s\n' "$S1_JOB_ID" "$S2_JOB_ID" "$S3_JOB_ID" "$S4_JOB_ID" "$S5_JOB_ID"
```

앞 단계 dependency가 실패하면 뒤 단계는 성공적으로 실행되지 않습니다. [AWS Batch job dependency 문서](https://docs.aws.amazon.com/batch/latest/userguide/job_dependencies.html)를 보세요.

## 검증 기록

2026-11-26에 us-west-2에서 새 prefix로 검증했습니다: CPU만(D1 loader와 copy-in 패턴 1), CPU + GPU, GPU만, 다시 CPU + GPU 모두 통과. 자세한 내용과 소요 시간은 [검증 가이드](../validation.ko.md#검증-기록)에 있습니다. 패턴 2(`submit_steps.sh`), 패턴 3(Mountpoint), 호환성 보고서는 이번 검증에서 다시 실행하지 않았습니다.

## 다음 단계

- [이 Batch 큐에서 Nextflow 실행](25-nextflow.ko.md)
- [Batch에서 RaptGen](../raptgen/batch.ko.md)
- [HealthOmics 추가](40-both.ko.md#차례로-하나씩)
- [정리](90-cleanup.ko.md)
