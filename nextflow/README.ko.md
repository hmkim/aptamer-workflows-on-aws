[English](README.md) | [한국어](README.ko.md)

# Nextflow 워크플로

`main.nf`는 profile이 네 개인 Nextflow DSL2 워크플로 하나입니다. DSL2는 Nextflow의 현재 워크플로 문법입니다. 이 프로세스 그래프는 read 품질 검사, primer trimming, 서열 counting, enrichment 순위, RNA 2차 구조 folding, 출력 checksum을 수행합니다.

## 컨테이너 규약

컨테이너에는 `seqkit`, `cutadapt`, `RNAfold`, `enrich.py`가 있어야 합니다. 원격 profile은 private Amazon Elastic Container Registry(ECR) 이미지가 필요하며 `sha256` digest로 지정하는 것이 좋습니다. ECR은 AWS가 관리하는 private 컨테이너 저장소입니다.

## 입력

저장소에는 선택 사항인 D1 전용 예시 primer가 `../data/dra009383.env.example`에 있습니다. 출처와 재사용 한계는 `../DATA_NOTICE.md`를 확인하세요. 모든 실행은 여전히 시작할 때 primer를 명시적으로 받습니다.

samplesheet는 `round`와 `file` 열이 있는 탭 구분 텍스트입니다.

```text
round  file
0      R0_sample.fastq.gz
1      R1_sample.fastq.gz
```

상대 파일 이름은 `--input_dir`에 붙여 해석합니다. file 열에는 전체 로컬 경로나 `s3://` object URI를 넣을 수도 있습니다.

## Profile

| Profile | 입력 처리 | Nextflow work 디렉터리 |
|---|---|---|
| `local` | 로컬 파일을 링크로 준비 | 로컬 POSIX 파일 시스템 |
| `batch` | Nextflow가 S3 object를 task 스토리지로 복사 | S3 |
| `batch_mountpoint` | task가 `val` 문자열로 전달된 읽기 전용 Mountpoint 경로를 읽음 | S3 |
| `healthomics` | HealthOmics가 private S3 object를 준비 | HealthOmics 관리 task 스토리지 |

POSIX는 임의 위치 읽기, 이름 변경, 파일 잠금 등 명령줄 도구가 기대하는 일반적인 파일 동작을 뜻합니다. Mountpoint for Amazon S3는 POSIX를 완전히 지원하는 파일 시스템이 아닙니다. 이 워크플로는 Mountpoint를 순차적인 읽기 전용 FASTQ 입력에만 씁니다. 임시 파일, 중간 산출물, 출력은 모두 task 스토리지에 둡니다. 도구가 완전한 POSIX 동작을 필요로 하면 native S3 staging을 쓰세요.

### Mountpoint와 `-resume`

Nextflow는 `val` 입력을 문자열 값으로 해시합니다. 같은 마운트 경로 뒤에서 S3 object가 바뀌어도 알아채지 못합니다. 그래서 `batch_mountpoint` 모드에서 `-resume`은 오래된 캐시 task를 재사용할 수 있습니다. 변경되지 않는 (또는 버전이 붙은) object key를 쓰거나, 마운트된 object 내용이 바뀌었을 수 있으면 `-resume` 없이 실행하세요.

## 로컬 실행

필요한 컨테이너 이미지를 빌드한 뒤 저장소 루트에서 실행합니다.

```bash
nextflow run nextflow/main.nf -profile local \
  --reads 'inputs/DRA009383/R*_*.fastq.gz' \
  --front_primer '<FRONT_PRIMER_DNA>' \
  --back_primer '<BACK_PRIMER_DNA>' \
  --local_container 'aptamer-workflow:latest' \
  --outdir results
```

`<FRONT_PRIMER_DNA>`와 `<BACK_PRIMER_DNA>`는 A, C, G, T, N만 포함한 DNA 서열로 바꾸세요.

## AWS Batch 실행

launcher는 설정을 환경 변수와 명령 인수에서만 받습니다. 큐, role, 버킷, compute environment, 마운트를 만들지 않습니다.

Native S3 staging:

```bash
AWS_REGION='<AWS_REGION>' \
BATCH_QUEUE='<BATCH_JOB_QUEUE_NAME>' \
BATCH_JOB_ROLE_ARN='<BATCH_JOB_ROLE_ARN>' \
PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>' \
NXF_WORK='s3://<WORK_BUCKET>/<NEXTFLOW_WORK_PREFIX>' \
OUTPUT_URI='s3://<OUTPUT_BUCKET>/<RUN_OUTPUT_PREFIX>' \
INPUT_URI='s3://<INPUT_BUCKET>/<FASTQ_PREFIX>' \
SAMPLESHEET="$PWD/nextflow/samplesheet.dra009383.tsv" \
FRONT_PRIMER='<FRONT_PRIMER_DNA>' \
BACK_PRIMER='<BACK_PRIMER_DNA>' \
nextflow/run_batch.sh batch \
  --front_primer "$FRONT_PRIMER" \
  --back_primer "$BACK_PRIMER"
```

읽기 전용 Mountpoint 입력:

```bash
AWS_REGION='<AWS_REGION>' \
BATCH_QUEUE='<BATCH_JOB_QUEUE_NAME>' \
BATCH_JOB_ROLE_ARN='<BATCH_JOB_ROLE_ARN>' \
PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>' \
NXF_WORK='s3://<WORK_BUCKET>/<NEXTFLOW_WORK_PREFIX>' \
OUTPUT_URI='s3://<OUTPUT_BUCKET>/<RUN_OUTPUT_PREFIX>' \
INPUT_URI='/mnt/s3-input/<FASTQ_PREFIX>' \
MOUNT_PATH='/mnt/s3-input' \
SAMPLESHEET="$PWD/nextflow/samplesheet.dra009383.tsv" \
FRONT_PRIMER='<FRONT_PRIMER_DNA>' \
BACK_PRIMER='<BACK_PRIMER_DNA>' \
RESUME=false \
nextflow/run_batch.sh batch_mountpoint \
  --front_primer "$FRONT_PRIMER" \
  --back_primer "$BACK_PRIMER"
```

AWS Batch compute environment는 job이 시작되기 전에 Mountpoint 마운트를 만들고 `MOUNT_PATH`에 읽기 전용으로 노출해야 합니다. job role은 설정한 prefix에 필요한 S3 읽기/쓰기 권한만 가져야 합니다.

## HealthOmics

이 디렉터리를 패키징하고 `../healthomics/`의 도우미로 실행하세요. HealthOmics는 생물정보학 워크플로를 실행하는 AWS 관리형 서비스입니다. 도우미는 항상 restricted 네트워킹, private S3 스토리지, 같은 Region의 private ECR 이미지를 요청합니다.

## 로컬 검증

```bash
nextflow run nextflow/main.nf --help
nextflow config nextflow/main.nf -profile local
nextflow config nextflow/main.nf -profile batch
nextflow config nextflow/main.nf -profile batch_mountpoint
nextflow config nextflow/main.nf -profile healthomics
bash -n nextflow/run_batch.sh
python3 -m json.tool nextflow/nextflow_schema.json >/dev/null
```

## 용어

- **AWS Batch:** 관리형 job 스케줄링과 compute 프로비저닝.
- **DSL2:** 프로세스와 워크플로를 조합하는 Nextflow 문법.
- **ECR:** AWS의 private 컨테이너 이미지 저장소.
- **Mountpoint for Amazon S3:** 의도적으로 POSIX 기능을 제한한, S3 object의 파일 시스템 형태 뷰.
- **Native S3 staging:** 도구가 실행되기 전에 Nextflow가 각 S3 object를 task로 복사하는 방식.
- **Profile:** `-profile`로 고르는 이름 있는 Nextflow 설정.
- **Work 디렉터리:** task 스크립트, 준비된 입력, 중간 산출물을 보관하는 Nextflow 캐시.
