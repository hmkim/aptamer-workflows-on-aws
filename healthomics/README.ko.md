[English](README.md) | [한국어](README.ko.md)

# AWS HealthOmics 오케스트레이션

이 디렉터리는 `../nextflow/`의 같은 워크플로를 AWS HealthOmics private workflow로 패키징하고 실행합니다. HealthOmics는 생물정보학 워크플로를 실행하는 AWS 관리형 서비스입니다.

자동으로 실행되는 것은 없습니다. `orchestrate.sh`는 `package`, `register`, `run`, `status`를 제공하며 삭제 기능은 없습니다.

## 보안 모델

- `infrastructure.yaml`은 Block Public Access 4가지 설정을 모두 켠 S3 버킷을 만들고, 버킷 소유권 강제, 버전 관리, TLS 전용 접근, KMS 암호화를 적용합니다.
- 컨테이너 저장소는 immutable 태그와 이미지 스캔이 있는 private ECR입니다.
- run role은 설정한 입력 prefix만 읽고, 설정한 출력 prefix에만 쓰고, 암호화 키 하나를 쓰고, 저장소 하나에서만 pull할 수 있습니다.
- run 명령은 항상 `--workflow-type PRIVATE`을 넘기고 기본값은 `--networking-mode RESTRICTED`입니다. `--networking-mode VPC --configuration-name <name>`은 선택 사항이며 **아직 검증되지 않았습니다**. [`vpc/README.md`](vpc/README.ko.md)를 보세요.
- Restricted 네트워킹은 워크플로 task가 공용 인터넷에 접근하지 못하게 합니다. 모든 도구와 의존성을 시작 전에 컨테이너 이미지 안에 넣으세요.
- 런타임 workflow와 run 식별자는 git에서 무시되는 `healthomics/.state/` 디렉터리에만, 소유자만 읽을 수 있는 권한으로 기록됩니다.

스택을 지워도 버킷, 키, 저장소는 보존됩니다. 데이터를 실수로 지우는 것을 막아 주지만, 이 리소스들은 따로 의도적으로 정리해야 합니다.

## 사전 준비

- HealthOmics를 지원하는 AWS CLI v2
- `jq`, `zip`, `sha256sum`
- 스택의 private ECR 저장소에 이미 push된 태그가 있는 워크플로 컨테이너
- private S3에 올려 둔 samplesheet. 각 `file` 값은 완전한 S3 object URI여야 합니다.

samplesheet 예시:

```text
round	file
0	s3://<PRIVATE_BUCKET>/<INPUT_PREFIX>/R0_sample.fastq.gz
1	s3://<PRIVATE_BUCKET>/<INPUT_PREFIX>/R1_sample.fastq.gz
```

## 로컬 검증

```bash
bash -n orchestrate.sh
python3 -m json.tool parameter-template.json >/dev/null
python3 -m json.tool run-parameters.example.json >/dev/null
aws cloudformation validate-template \
  --region '<AWS_REGION>' \
  --template-body 'file://infrastructure.yaml'
```

마지막 명령은 템플릿을 파싱하려고 AWS를 호출할 뿐 리소스를 만들지 않습니다.

## private 리소스 배포

쓰기 작업이므로 실행 전에 템플릿을 검토하고 대상 AWS 계정과 Region을 고르세요.

```bash
aws cloudformation deploy \
  --region '<AWS_REGION>' \
  --stack-name '<STACK_NAME>' \
  --template-file infrastructure.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    InputPrefix='<INPUT_PREFIX>' \
    OutputPrefix='<OUTPUT_PREFIX>' \
    ImageTag='<IMAGE_TAG>'
```

생성된 값을 읽습니다. 커밋하지 마세요.

```bash
aws cloudformation describe-stacks \
  --region '<AWS_REGION>' \
  --stack-name '<STACK_NAME>' \
  --query 'Stacks[0].Outputs' \
  --output table
```

## 패키징과 등록

```bash
AWS_REGION='<AWS_REGION>' \
WORKFLOW_NAME='<WORKFLOW_NAME>' \
./orchestrate.sh package
```

```bash
AWS_REGION='<AWS_REGION>' \
WORKFLOW_NAME='<WORKFLOW_NAME>' \
STORAGE_TYPE='DYNAMIC' \
./orchestrate.sh register
```

등록 명령은 생성된 workflow ID를 `.state/` 아래에 저장합니다. 로컬 상태를 쓰지 않으려면 이후 명령에서 `WORKFLOW_ID`를 직접 지정하세요.

## 실행

다음 명령은 samplesheet object와 그것이 가리키는 모든 FASTQ object가 private 버킷에 이미 있다고 가정합니다.

```bash
AWS_REGION='<AWS_REGION>' \
WORKFLOW_ID='<WORKFLOW_ID>' \
BUCKET_NAME='<PRIVATE_BUCKET>' \
SAMPLESHEET_URI='s3://<PRIVATE_BUCKET>/<INPUT_PREFIX>/samplesheet.tsv' \
PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>' \
RUN_ROLE_ARN='<HEALTHOMICS_RUN_ROLE_ARN>' \
OUTPUT_PREFIX='<OUTPUT_PREFIX>' \
RUN_NAME='<RUN_NAME>' \
FRONT_PRIMER='<FRONT_PRIMER_DNA>' \
BACK_PRIMER='<BACK_PRIMER_DNA>' \
SCRATCH_STORAGE_MODE='SHARED' \
RETENTION_MODE='RETAIN' \
LOG_LEVEL='ALL' \
./orchestrate.sh run
```

스크립트는 ECR 이미지 URI가 선택한 Region의 것인지 확인합니다. primer 자리표시자는 A, C, G, T, N만 포함한 DNA 서열로 바꾸세요.

### run 옵션

| 옵션 또는 변수 | 기본값 | 뜻 |
|---|---|---|
| `--networking-mode` / `NETWORKING_MODE` | `RESTRICTED` | `RESTRICTED` 또는 `VPC` (VPC는 아직 검증되지 않음) |
| `--configuration-name` / `CONFIGURATION_NAME` | 없음 | HealthOmics configuration 이름. `VPC`에서 필수 |

## 스택 output

`BucketName`, `RepositoryUri`, `PipelineImage`, `RunRoleArn`, `InputPrefix`, `OutputPrefix`, `KmsKeyArn`.

## run 확인

```bash
AWS_REGION='<AWS_REGION>' \
./orchestrate.sh status '<RUN_ID>'
```

run과 task 상태를 읽을 뿐입니다. 로그나 출력은 내려받지 않습니다.

## 용어

- **ECR:** Amazon Elastic Container Registry, private 컨테이너 이미지 저장소.
- **HealthOmics private workflow:** 권한이 있는 AWS API 접근으로만 보이는 워크플로 정의.
- **KMS:** S3 object에 쓰이는 암호화 키를 관리하는 AWS Key Management Service.
- **Restricted networking:** 워크플로 task가 공용 인터넷에 접근하지 못하게 하는 run 모드.
- **Run role:** 입력을 읽고, 출력을 쓰고, 이미지를 pull하기 위해 HealthOmics가 assume하는 IAM role.
- **S3 prefix:** 접근을 제한하는 데 쓰는, S3 object key의 앞부분(폴더처럼 보이는 부분).
