[English](25-nextflow.md) | [한국어](25-nextflow.ko.md)

# AWS Batch에서 Nextflow 쓰기

Nextflow는 각 process를 Batch job으로 바꾸고 dependency를 대신 추적합니다. **Nextflow DSL2**는 process를 연결해 워크플로를 만드는 현재 Nextflow 문법입니다. **profile**은 `-profile`로 고르는, 이름이 붙은 실행 설정 묶음입니다.

이 가이드에는 [Batch 가이드](20-batch.ko.md)의 CPU Batch 스택(1~5단계: 스택, 파이프라인 이미지, D1 데이터)이 필요합니다. 스택은 Nextflow head 프로세스용 역할을 만들지 않습니다. 다음 절 끝부분을 보세요.

## AWS Batch에서 Nextflow 실행

`batch` profile을 쓰면 Nextflow가 S3 입력 파일을 작업 스토리지로 staging하며, S3 work prefix가 필요합니다. 워크플로를 조율하는 작은 head 프로세스가 계속 실행되어 있어야 합니다.

```bash
export AWS_REGION='<AWS_REGION>'
export BATCH_QUEUE='<BATCH_JOB_QUEUE_NAME>'
export BATCH_JOB_ROLE_ARN='<BATCH_JOB_ROLE_ARN>'
export PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>'
export NXF_WORK='s3://<PRIVATE_WORK_BUCKET>/<NEXTFLOW_WORK_PREFIX>/'
export OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/'
export INPUT_URI='s3://<PRIVATE_INPUT_BUCKET>/<INPUT_PREFIX>/'
export SAMPLESHEET="$PWD/nextflow/samplesheet.dra009383.tsv"
export FRONT_PRIMER='<FRONT_PRIMER_DNA>'
export BACK_PRIMER='<BACK_PRIMER_DNA>'

bash nextflow/run_batch.sh batch \
  --front_primer "$FRONT_PRIMER" \
  --back_primer "$BACK_PRIMER"
```

[nextflow/README.ko.md](../../nextflow/README.ko.md)와 [Nextflow AWS Batch executor 문서](https://docs.seqera.io/nextflow/aws#aws-batch)를 보세요.

`batch/infrastructure.yaml`이 만든 큐에서 Nextflow를 실행하려면 그 스택의 출력 값을 쓰세요.

| 변수 | 스택 출력 또는 값 |
|---|---|
| `BATCH_QUEUE` | `CpuJobQueueName` (CPU가 켜져 있으면 `JobQueueName`과 같음) |
| `BATCH_JOB_ROLE_ARN` | `PipelineJobRoleArn` |
| `PIPELINE_IMAGE` | `RepositoryUri`와 빌드한 이미지 태그 또는 digest |
| `INPUT_URI` | `s3://<DataBucketName>/<DataPrefix>/` |
| `NXF_WORK` | `s3://<WorkBucketName>/runs/` 아래의 prefix |

파이프라인 job role은 work 버킷의 `runs/` 아래에만 쓸 수 있으므로, Nextflow work 디렉터리를 다른 곳에 두면 access denied로 실패합니다. 스택은 Nextflow head 프로세스용 역할을 만들지 않습니다. Batch job을 제출하고 조회하고, work prefix를 읽고 쓰고, `OUTPUT_URI`에 쓸 수 있는 별도 역할을 head 프로세스에 주세요.

## 읽기 전용 Mountpoint 입력을 쓰는 Nextflow

Mountpoint for Amazon S3는 S3 객체를 Linux 파일 경로로 보여 줍니다. **완전한 POSIX 호환 파일 시스템이 아니며, 도구나 작업의 파일 접근 패턴에 따라 실패할 수 있습니다.** 호환되는 입력에만 읽기 전용으로 쓰세요. 임시 파일과 출력은 로컬 POSIX 스토리지에 두고, **Mountpoint 경로를 Nextflow work 디렉터리로 절대 쓰지 마세요.**

```bash
export AWS_REGION='<AWS_REGION>'
export BATCH_QUEUE='<MOUNTPOINT_ENABLED_BATCH_QUEUE_NAME>'
export BATCH_JOB_ROLE_ARN='<BATCH_JOB_ROLE_ARN>'
export PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>'
export NXF_WORK='s3://<PRIVATE_WORK_BUCKET>/<NEXTFLOW_WORK_PREFIX>/'
export OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/'
export INPUT_URI='/mnt/s3-input/<INPUT_PREFIX>'
export MOUNT_PATH='/mnt/s3-input'
export SAMPLESHEET="$PWD/nextflow/samplesheet.dra009383.tsv"
export FRONT_PRIMER='<FRONT_PRIMER_DNA>'
export BACK_PRIMER='<BACK_PRIMER_DNA>'
export RESUME='false'

bash nextflow/run_batch.sh batch_mountpoint \
  --front_primer "$FRONT_PRIMER" \
  --back_primer "$BACK_PRIMER"
```

컴퓨팅 호스트는 private 입력 버킷을 `MOUNT_PATH`(기본값 `/mnt/s3-input`)에 마운트하고, 그 호스트 경로를 작업 컨테이너에 읽기 전용으로 노출해야 합니다. `batch/infrastructure.yaml`이 만드는 CPU 호스트는 구성이 조금 다릅니다. 데이터 버킷의 `<DataPrefix>/` 부분만 `/mnt/s3-data`에 마운트하므로 입력 객체가 `/mnt/s3-data` 바로 아래에 보입니다. 이 큐에서는 `MOUNT_PATH='/mnt/s3-data'`, `INPUT_URI='/mnt/s3-data'`로 설정하세요. GPU 호스트는 S3를 마운트하지 않습니다.

마운트된 경로는 Nextflow `path` 입력이 아니라 문자열로 전달됩니다. 그래서 마운트 경로가 그대로인데 객체 내용이 바뀌면 Nextflow가 알아채지 못합니다. 버전이 있거나 바뀌지 않는 키를 쓰거나, 입력이 바뀐 뒤에는 `-resume` 없이 실행하세요.

[스토리지 가이드](../storage.ko.md)와 [Mountpoint 파일 시스템 동작](https://github.com/awslabs/mountpoint-s3/blob/main/doc/SEMANTICS.md)을 읽어 보세요.

## 다음 단계

- Nextflow와 Batch 결과를 비교하려면 [검증 가이드](../validation.ko.md)
- [정리](90-cleanup.ko.md)
