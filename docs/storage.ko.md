[English](storage.md) | [한국어](storage.ko.md)

# 스토리지와 정리 가이드

워크플로는 세 종류의 스토리지를 씁니다. 오래 보관할 객체용 Amazon S3, 실제 파일 작업용 로컬 POSIX 스토리지, 그리고 AWS HealthOmics가 관리하는 작업 스토리지입니다.

## 스토리지 역할

| 위치 | 용도 | 쉽게 말하면 |
|---|---|---|
| private S3 입력 prefix | 바뀌지 않는 FASTQ 입력과 samplesheet | 여러 실행 환경이 함께 쓰는 내구성 있는 객체 스토리지 |
| private S3 work prefix | Nextflow 작업 캐시와 Batch 중간 결과 | 다시 시작할 때 쓰는 작업 데이터. 빠르게 커질 수 있음 |
| private S3 출력 prefix | 순위 표, 폴딩 결과, 체크섬, 선택한 보고서 | 컴퓨팅 호스트보다 오래 남아야 하는 결과 |
| 로컬 POSIX 작업 스토리지 | 임시 파일, 정렬, 트리밍, 도구 작업 디렉터리 | 이름 바꾸기, 링크, 잠금, 제자리 수정을 지원하는 일반 Linux 디스크 |
| 읽기 전용 Mountpoint 경로 | 호환되는 입력 읽기 전용 | S3 객체를 파일처럼 보여 주는 것. 완전한 Linux 파일 시스템이 아님 |
| HealthOmics 작업 스토리지 | HealthOmics process 작업 | 워크플로 실행의 일부로 관리되는 스토리지 |

**S3 prefix**는 객체 키의 앞부분으로, 폴더처럼 보입니다. 실제 디렉터리는 아니지만 실행을 나누고 IAM 권한을 제한하는 데 유용합니다.

## 권장 객체 구조

바뀌지 않는 입력과 고유한 실행 식별자를 쓰세요.

```text
s3://<PRIVATE_INPUT_BUCKET>/<DATASET_ID>/fastq/
s3://<PRIVATE_INPUT_BUCKET>/<DATASET_ID>/samplesheet.tsv
s3://<PRIVATE_WORK_BUCKET>/nextflow/work/<RUN_ID>/
s3://<PRIVATE_WORK_BUCKET>/batch/intermediate/<RUN_ID>/
s3://<PRIVATE_OUTPUT_BUCKET>/results/<RUN_ID>/
```

출력 prefix를 실행끼리 재사용하지 마세요. 한 job이 다른 실행의 prefix에 쓰지 못하게 하세요. 결과와 함께 입력 객체 버전이나 체크섬, 컨테이너 이미지 digest, 파라미터, 워크플로 리비전을 기록하세요.

## 기본 S3 staging

Nextflow `batch` profile에서는 Nextflow `path`로 선언한 입력이 작업 스토리지로 staging됩니다. 작업은 로컬 파일을 보게 되고 일반 POSIX 연산을 쓸 수 있습니다. Nextflow는 작업 결과와 게시된 출력을 S3로 업로드합니다.

파일 동작을 모르는 도구에는 이것이 가장 안전한 기본값입니다. staging되는 입력마다 로컬 용량이 필요하고, 그 객체가 필요한 작업마다 전송이 일어납니다.

Nextflow work 디렉터리에는 버킷 아래 prefix가 있어야 합니다.

```bash
export NXF_WORK='s3://<PRIVATE_WORK_BUCKET>/<NEXTFLOW_WORK_PREFIX>/'
nextflow run nextflow/main.nf \
  -profile batch \
  -work-dir "$NXF_WORK" \
  --samplesheet nextflow/samplesheet.tsv \
  --input_dir 's3://<PRIVATE_INPUT_BUCKET>/<INPUT_PREFIX>/' \
  --outdir 's3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/' \
  --aws_region '<AWS_REGION>' \
  --batch_queue '<BATCH_JOB_QUEUE_NAME>' \
  --batch_job_role '<BATCH_JOB_ROLE_ARN>' \
  --container '<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>' \
  --front_primer '<FRONT_PRIMER_DNA>' \
  --back_primer '<BACK_PRIMER_DNA>'
```

## Mountpoint for Amazon S3

Mountpoint는 Linux 파일 연산을 S3 API 요청으로 바꿉니다. 객체를 높은 처리량으로 읽는 경우, 특히 큰 파일을 순차적으로 읽는 경우에 최적화되어 있습니다.

Mountpoint는 **완전한 POSIX 호환이 아니며, 도구나 작업의 파일 접근 패턴에 따라 실패할 수 있습니다.** 범용 S3 버킷에서 중요한 차이점은 심볼릭 링크와 파일 잠금 미지원, 기존 파일 수정 제한, 일반적인 이름 바꾸기 미지원입니다. [Mountpoint 파일 시스템 동작](https://github.com/awslabs/mountpoint-s3/blob/main/doc/SEMANTICS.md)과 [Amazon S3 Mountpoint 가이드](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mountpoint.html)를 보세요.

다음 규칙을 따르세요.

> 입력은 읽기 전용으로 마운트하세요. 임시 파일과 출력은 로컬 POSIX 스토리지에 두세요. Mountpoint를 Nextflow work 디렉터리로 절대 쓰지 마세요.

Mountpoint를 설치하고 인스턴스 역할에 읽기 권한이 있으면, 호스트에서 읽기 전용 마운트는 다음과 같습니다.

```bash
export INPUT_BUCKET='<PRIVATE_INPUT_BUCKET>'
export INPUT_PREFIX='<INPUT_PREFIX>'
export MOUNT_PATH='/mnt/s3-input'

sudo install -d -m 0755 "$MOUNT_PATH"
sudo mount-s3 \
  "$INPUT_BUCKET" \
  "$MOUNT_PATH" \
  --prefix "$INPUT_PREFIX/" \
  --read-only \
  --allow-other
mountpoint "$MOUNT_PATH"
```

AWS Batch에서는 컴퓨팅 호스트 launch template에서 이 마운트를 만들고, 컨테이너에 읽기 전용으로 bind mount하세요. 권한 없는 작업 컨테이너 안에서 마운트하지 마세요. 컴퓨팅 인스턴스 역할은 `s3:ListBucket`, `s3:GetBucketLocation`, `s3:GetObject`와 대상 버킷과 prefix로만 제한하세요.

### 단계별 호환성

| 단계 | 마운트 경로에서 하는 연산 | 로컬에서 해야 하는 연산 | 권장 방식 |
|---|---|---|---|
| QC | 압축 FASTQ 읽기 | 작업 스토리지에 통계 쓰기 | 테스트 후 읽기 전용 입력 허용 |
| Trim | 압축 FASTQ 읽기 | 트리밍된 FASTQ와 로그 쓰기 | 모든 쓰기는 로컬에 |
| Count | trim 이후에는 마운트 입력 없음 | 정렬, 임시 파일, 카운트 출력 | `TMPDIR`를 로컬 작업 스토리지로 설정 |
| Enrichment | staging된 카운트 표 읽기 | 순위 표 쓰기 | 작업 로컬 또는 기본 S3 staging 사용 |
| Fold | staging된 순위 표 읽기 | 로컬 작업 디렉터리에 폴딩 출력 쓰기 | 마운트된 현재 디렉터리 쓰지 않기 |
| Nextflow 엔진 | 마운트 경로를 문자열로 전달 | 작업 스크립트, 링크, 캐시, 메타데이터 | work는 기본 S3 staging이나 로컬 POSIX 스토리지에 |

정확한 도구와 버전으로 실제 호환성 테스트를 하세요. `ls`나 `head` 테스트가 성공해도 도구의 전체 접근 패턴이 지원된다는 증거는 아닙니다.

### Mountpoint와 Nextflow resume

`batch_mountpoint` profile은 마운트된 경로를 문자열 값으로 전달합니다. Nextflow는 객체 내용이 아니라 문자열을 해시합니다. 같은 경로의 객체가 바뀌면 `-resume`이 오래된 작업 결과를 재사용할 수 있습니다.

S3 버전 관리와 바뀌지 않는 객체 키를 쓰거나, 경로에 내용 식별자를 넣거나, 마운트된 내용이 바뀌었을 수 있으면 `-resume` 없이 실행하세요.

## S3 보안 기준

- 네 가지 S3 Block Public Access 설정을 모두 켜세요.
- bucket-owner-enforced 객체 소유권을 써서 ACL을 끄세요.
- TLS를 쓰지 않는 요청을 거부하세요.
- 객체를 암호화하고 키 사용을 필요한 역할로 제한하세요.
- 입력용 자격 증명에는 읽기 전용 권한만 주세요.
- 작업 역할에는 필요한 work 또는 출력 범위에만 쓰기 권한을 주세요. 포함된 Batch task role은 스택의 `runs/` prefix 전체에 걸치므로, IAM으로 실행끼리 격리해야 하면 스택을 나누거나 실행별 역할을 쓰세요.
- 버전 관리와 수명 주기 규칙을 복구와 보존 요구 사항에 맞추세요.
- 완료되지 않은 multipart upload는 승인된 기간이 지나면 중단하세요.
- 기밀 객체 키나 결과를 공개 로그에 남기지 마세요.

## 정리

이 절은 실행 하나씩을 다룹니다. 스택 전체와 보존된 버킷을 지우려면 [정리 가이드](getting-started/90-cleanup.ko.md)를 보세요.

정리 명령은 일부러 확인, dry run, 실행으로 나눠 두었습니다. 모든 placeholder를 바꾸고, AWS 계정과 리전을 확인하고, 필요한 결과를 보존하고, 실행 단계 전에 운영자의 명시적인 승인을 받으세요.

### 로컬 실행 디렉터리

고정된 기준 디렉터리 아래의 로컬 실행 하나를 확인합니다.

```bash
export LOCAL_RUN_BASE="$HOME/aptamer-runs"
export RUN_ID='<RUN_ID>'
export LOCAL_RUN_DIRECTORY="$LOCAL_RUN_BASE/$RUN_ID"
export LOCAL_RUN_BASE_CANONICAL=$(realpath --canonicalize-missing -- "$LOCAL_RUN_BASE")
export LOCAL_RUN_DIRECTORY_CANONICAL=$(realpath --canonicalize-missing -- "$LOCAL_RUN_DIRECTORY")
case "$LOCAL_RUN_DIRECTORY_CANONICAL" in
  "$LOCAL_RUN_BASE_CANONICAL"/*) ;;
  *) printf 'Refusing path outside LOCAL_RUN_BASE\n' >&2; exit 1 ;;
esac
test "$LOCAL_RUN_DIRECTORY_CANONICAL" != "$LOCAL_RUN_BASE_CANONICAL"
test -d "$LOCAL_RUN_DIRECTORY_CANONICAL"
find "$LOCAL_RUN_DIRECTORY_CANONICAL" -mindepth 1 -maxdepth 2 -print
```

로컬 `rm`에는 믿을 만한 dry run 모드가 없습니다. 목록을 따로 검토하고 명시적인 승인을 받은 뒤, 같은 정규 경로 검사를 반복하고 그 하위 디렉터리만 삭제하세요.

```bash
export LOCAL_RUN_BASE="$HOME/aptamer-runs"
export RUN_ID='<RUN_ID>'
export LOCAL_RUN_DIRECTORY="$LOCAL_RUN_BASE/$RUN_ID"
export LOCAL_RUN_BASE_CANONICAL=$(realpath --canonicalize-missing -- "$LOCAL_RUN_BASE")
export LOCAL_RUN_DIRECTORY_CANONICAL=$(realpath --canonicalize-missing -- "$LOCAL_RUN_DIRECTORY")
case "$LOCAL_RUN_DIRECTORY_CANONICAL" in
  "$LOCAL_RUN_BASE_CANONICAL"/*) ;;
  *) printf 'Refusing path outside LOCAL_RUN_BASE\n' >&2; exit 1 ;;
esac
test "$LOCAL_RUN_DIRECTORY_CANONICAL" != "$LOCAL_RUN_BASE_CANONICAL"
test -d "$LOCAL_RUN_DIRECTORY_CANONICAL"
rm -rf -- "$LOCAL_RUN_DIRECTORY_CANONICAL"
```

### S3 실행 prefix

prefix를 확인합니다.

```bash
export AWS_REGION='<AWS_REGION>'
export RUN_OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/<RUN_ID>/'
aws s3 ls "$RUN_OUTPUT_URI" --region "$AWS_REGION" --recursive --human-readable --summarize
```

객체를 지우지 않고 삭제될 대상을 모두 미리 봅니다.

```bash
export AWS_REGION='<AWS_REGION>'
export RUN_OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/<RUN_ID>/'
aws s3 rm "$RUN_OUTPUT_URI" --region "$AWS_REGION" --recursive --dryrun
```

미리 보기를 확인하고 명시적인 승인을 받은 뒤, 같은 범위의 명령을 `--dryrun` 없이 실행합니다.

```bash
export AWS_REGION='<AWS_REGION>'
export RUN_OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/<RUN_ID>/'
aws s3 rm "$RUN_OUTPUT_URI" --region "$AWS_REGION" --recursive --only-show-errors
```

버전 관리가 켜진 버킷에서는 보통 이전 버전을 지우지 않고 delete marker를 만듭니다. 버전을 지우기 전에 보존 요구 사항과 법적 요구 사항을 검토하세요.

### Batch job

멈출지 정하기 전에 활성 job을 나열합니다.

```bash
export AWS_REGION='<AWS_REGION>'
export BATCH_JOB_QUEUE='<BATCH_JOB_QUEUE_NAME>'
aws batch list-jobs --region "$AWS_REGION" --job-queue "$BATCH_JOB_QUEUE" --job-status RUNNING
aws batch list-jobs --region "$AWS_REGION" --job-queue "$BATCH_JOB_QUEUE" --job-status RUNNABLE
```

job을 멈추면 출력이 불완전하게 남을 수 있습니다. 시작하지 않은 job에는 `cancel-job`, 실행 중인 job에는 `terminate-job`을 쓰되, 명시적인 승인을 받고 정확한 job ID를 기록한 뒤에만 쓰세요.

### HealthOmics와 CloudFormation

정리하기 전에 실행과 스택 리소스를 확인합니다.

```bash
export AWS_REGION='<AWS_REGION>'
export STACK_NAME='<STACK_NAME>'
aws omics list-runs --region "$AWS_REGION" --max-results 25
aws cloudformation describe-stack-resources --region "$AWS_REGION" --stack-name "$STACK_NAME"
```

포함된 템플릿은 스택을 삭제해도 버킷, KMS 키, ECR 리포지토리를 남깁니다. CloudFormation 스택 삭제에는 dry run 모드가 없습니다. 스택 삭제와 보존된 리소스 삭제는 각각 따로 승인받는 작업으로 다루세요. 보존된 리소스를 지워도 되는지 정하기 전에 S3 객체 버전과 ECR 이미지를 확인하세요.

## 더 읽을거리

- [Nextflow AWS Batch executor](https://docs.seqera.io/nextflow/aws#aws-batch)
- [AWS Batch job dependency](https://docs.aws.amazon.com/batch/latest/userguide/job_dependencies.html)
- [AWS HealthOmics private workflow](https://docs.aws.amazon.com/omics/latest/dev/private-workflows.html)
