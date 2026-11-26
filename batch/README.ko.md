[English](README.md) | [한국어](README.ko.md)

# AWS Batch 구현

이 디렉터리는 별도의 입력 loader와 함께, 세 가지 실행 패턴으로 aptamer 워크플로를 AWS Batch에서 실행합니다. 자동으로 배포되거나 제출되는 것은 없습니다.

| 패턴 | 제출 스크립트 | 데이터 경로 |
|---|---|---|
| Copy-in | `submit_copyin.sh` | 처리 전에 S3 입력을 로컬 POSIX scratch로 복사 |
| 단계 의존성 | `submit_steps.sh` | S1-S3 array job은 `N_TO_N`을 쓰고, S4와 S5는 앞 단계가 끝나야 시작 |
| Mountpoint 입력 | `submit_mountpoint.sh` | 읽기 전용 S3 입력 마운트. 임시 파일과 출력은 로컬 POSIX |
| 호환성 리포트 | `submit_compat.sh` | 메타데이터만 읽는 읽기 전용 점검 뒤 Mountpoint에서 읽기와 파이프라인 probe 실행 |
| 입력 loader | `submit_loader.sh` | manifest 기반 다운로드, MD5 검증, 암호화된 S3 업로드 |

POSIX는 파일 수정, 이름 변경, 링크, 잠금 등 Linux 도구가 기대하는 표준 파일 동작을 뜻합니다. Mountpoint for Amazon S3는 POSIX를 완전히 지원하지 않습니다. 도구의 파일 접근 패턴에 따라 실패할 수 있습니다. 그래서 이 구현은 Mountpoint를 입력 전용, 읽기 전용으로만 씁니다. 모든 임시 파일과 출력은 S3에 업로드하기 전까지 로컬 POSIX 스토리지를 씁니다. 새 도구나 입력 형식에 의존하기 전에 호환성 job을 실행하세요. 도구가 입력에 POSIX 동작을 필요로 하면 copy-in 패턴을 쓰세요.

## 인프라

`network.yaml`은 private subnet 두 개와 NAT gateway를 만듭니다. Batch compute는 이 private subnet을 써야 합니다. NAT subnet은 public IP를 자동 할당하지 않고, Batch 보안 그룹에는 인바운드 규칙이 없습니다. SSH 규칙과 key pair도 없습니다.

`infrastructure.yaml`이 만드는 것:

* 자동 교체되는 KMS 키
* S3 Block Public Access, bucket-owner-enforced 소유권, 버전 관리, KMS 암호화, TLS 전용 버킷 정책을 갖춘 별도의 data 버킷과 work 버킷
* private ECR 저장소와 CodeBuild 이미지 프로젝트
* S3 gateway endpoint
* 최소 권한의 compute, pipeline-job, loader-job, image-build role
* 암호화된 스토리지, IMDSv2 필수, 메타데이터 hop limit 1의 EC2 launch template
* 관리형 EC2 Batch compute environment, 큐, 로그 그룹, job definition 세 개

### Compute와 RaptGen 파라미터

| 파라미터 | 기본값 | 뜻 |
|---|---|---|
| `EnableCpu` | `true` | CPU compute environment와 `<stack>-queue`, CodeBuild 이미지 프로젝트, pipeline job definition 세 개 |
| `EnableGpu` | `false` | GPU compute environment(`ECS_AL2023_NVIDIA` AMI)와 `<stack>-gpu-queue` |
| `MaxvCpus` / `InstanceTypes` | `72` / `c7i,c6i` | CPU compute environment 전용 |
| `GpuMaxvCpus` / `GpuInstanceTypes` | `8` / `g5.xlarge,g6.xlarge` | GPU compute environment 전용. G 계열 On-Demand vCPU 할당량이 필요 |
| `ImageTag`, `MountpointVersion`, `MountpointPackageSha256` | 비어 있음 | `EnableCpu=true`일 때 필수. GPU만 쓸 때는 무시 |

`Rules` 블록은 `EnableCpu=false`와 `EnableGpu=false`의 조합을 거부합니다. 두 compute environment는 같은 private subnet, 보안 그룹, 인스턴스 role, IMDSv2 설정, 암호화된 루트 볼륨을 씁니다. 읽기 전용 S3 입력은 CPU 호스트만 마운트합니다.

| Output | 존재 조건 |
|---|---|
| `JobQueueName` | 항상: CPU가 켜져 있으면 CPU 큐, 아니면 GPU 큐 |
| `CpuJobQueueName`, `PipelineJobDefinitionArn`, `MountpointJobDefinitionArn`, `DataLoaderJobDefinitionArn`, `ImageBuildProjectName` | `EnableCpu=true` |
| `GpuJobQueueName` | `EnableGpu=true` |
| `RaptgenCpuRepositoryUri`, `RaptgenGpuRepositoryUri`, `RepositoryUri`, `PipelineJobRoleArn`, `DataBucketName`, `WorkBucketName`, `LogGroupName`, `KmsKeyArn`, `ComputeSecurityGroupId`, `CpuEnabled`, `GpuEnabled` | 항상 |

스택을 지워도 ECR 저장소, 버킷, KMS 키, 로그 그룹은 보존됩니다. `network.yaml`은 `VpcId`, `PrivateSubnetIds`, `PrivateRouteTableIds`, `VpcCidr`, `PrivateSubnetAvailabilityZones`를 output으로 내보내며, 선택 파라미터 `AvailabilityZone1`/`AvailabilityZone2`로 private subnet 두 개를 HealthOmics가 운영되는 Availability Zone에 고정할 수 있습니다.

스택은 계정, partition, Region, 버킷, ECR, 리소스 이름을 배포 시점에 계산합니다. `ProjectTag`, `JobNamePrefix`, `DataPrefix`, 용량 설정은 파라미터입니다. 운영자는 파일을 수정하는 대신 환경 변수로 스택 이름과 Region을 줍니다.

## 배포 입력

먼저 `network.yaml`을 배포합니다. 그 output `VpcId`, `PrivateSubnetIds`, `PrivateRouteTableIds`를 `infrastructure.yaml`에 넘깁니다. loader가 공개 데이터를 받고 호스트가 부트스트랩 중에 Mountpoint를 설치하므로, private subnet에는 NAT gateway를 통한 outbound HTTPS가 필요합니다.

아래 자리표시자 예시는 값을 바꾸기 전에는 일부러 실행되지 않게 되어 있습니다.

```bash
aws cloudformation deploy \
  --region <AWS_REGION> \
  --stack-name <NETWORK_STACK_NAME> \
  --template-file batch/network.yaml \
  --parameter-overrides ProjectTag=<PROJECT_TAG>

aws cloudformation deploy \
  --region <AWS_REGION> \
  --stack-name <BATCH_STACK_NAME> \
  --template-file batch/infrastructure.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    VpcId=<VPC_ID> \
    PrivateSubnetIds=<PRIVATE_SUBNET_1>,<PRIVATE_SUBNET_2> \
    PrivateRouteTableIds=<PRIVATE_ROUTE_TABLE_1>,<PRIVATE_ROUTE_TABLE_2> \
    ProjectTag=<PROJECT_TAG> \
    JobNamePrefix=<JOB_NAME_PREFIX> \
    DataPrefix=<DATA_PREFIX> \
    ImageTag=<IMMUTABLE_IMAGE_TAG> \
    MountpointVersion=<MOUNTPOINT_VERSION> \
    MountpointPackageSha256=<MOUNTPOINT_RPM_SHA256>
```

이미지 프로젝트는 data 버킷의 `build/context.zip`을 읽습니다. job 스크립트는 불변 이미지에 포함되며, Batch는 변경 가능한 S3 prefix에서 실행 스크립트를 내려받지 않습니다.

추적되는 저장소 파일을 패키징하고, build context를 업로드하고, CodeBuild를 시작하고, 최종 상태를 기다립니다.

```bash
export AWS_REGION=<AWS_REGION>
export BATCH_STACK_NAME=<BATCH_STACK_NAME>
export BUILD_CONTEXT=/tmp/aptamer-workflow-context.zip
export DATA_BUCKET=$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$BATCH_STACK_NAME" --query 'Stacks[0].Outputs[?OutputKey==`DataBucketName`].OutputValue | [0]' --output text)
export BUILD_PROJECT=$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$BATCH_STACK_NAME" --query 'Stacks[0].Outputs[?OutputKey==`ImageBuildProjectName`].OutputValue | [0]' --output text)

git archive --format=zip --output "$BUILD_CONTEXT" HEAD
aws s3 cp "$BUILD_CONTEXT" "s3://$DATA_BUCKET/build/context.zip" --region "$AWS_REGION" --only-show-errors
export BUILD_ID=$(aws codebuild start-build --region "$AWS_REGION" --project-name "$BUILD_PROJECT" --query 'build.id' --output text)
while true; do
  BUILD_STATUS=$(aws codebuild batch-get-builds --region "$AWS_REGION" --ids "$BUILD_ID" --query 'builds[0].buildStatus' --output text)
  printf 'CodeBuild status: %s\n' "$BUILD_STATUS"
  case "$BUILD_STATUS" in
    SUCCEEDED) break ;;
    FAILED|FAULT|STOPPED|TIMED_OUT) exit 1 ;;
    *) sleep 15 ;;
  esac
done
```

## 업로드와 실행

모든 운영 스크립트에는 `AWS_REGION`과 `STACK_NAME`이 필요합니다. pipeline과 호환성 제출에는 `FRONT_PRIMER`와 `BACK_PRIMER`도 필요하며, `TOP_CANDIDATES`의 기본값은 `100`입니다. manifest는 헤더와 `round`, `run_accession`, `library_name`, `file_name`, `url`, `md5` 열을 갖춘 탭 구분 파일이어야 합니다(`data/dra009383_manifest.tsv` 참고). loader는 원본 파일 이름을 검증하지만, 각 object를 pipeline 입력 규칙인 `R<round>_<run_accession>.fastq.gz`로 씁니다. stage-array 패턴에서는 round 번호가 0부터 연속이어야 합니다.

공개 D1 manifest는 불변 컨테이너에 이미 들어 있으므로 loader를 바로 제출하면 됩니다.

```bash
AWS_REGION=<AWS_REGION> STACK_NAME=<BATCH_STACK_NAME> batch/submit_loader.sh
```

직접 만든 manifest는 내용 기반 key로 업로드한 뒤, 반환된 URI와 SHA-256을 loader에 넘기세요.

```bash
mkdir -p batch/runs
AWS_REGION=<AWS_REGION> \
STACK_NAME=<BATCH_STACK_NAME> \
MANIFEST_PATH=<INPUT_MANIFEST_TSV> \
batch/upload_manifest.sh > batch/runs/manifest.env
source batch/runs/manifest.env
AWS_REGION=<AWS_REGION> \
STACK_NAME=<BATCH_STACK_NAME> \
MANIFEST_S3_URI="$MANIFEST_S3_URI" \
MANIFEST_SHA256="$MANIFEST_SHA256" \
batch/submit_loader.sh
```

```bash
AWS_REGION=<AWS_REGION> \
STACK_NAME=<BATCH_STACK_NAME> \
RUN_ID=<RUN_ID> \
FRONT_PRIMER=<FRONT_PRIMER_DNA> \
BACK_PRIMER=<BACK_PRIMER_DNA> \
TOP_CANDIDATES=100 \
batch/submit_copyin.sh

AWS_REGION=<AWS_REGION> \
STACK_NAME=<BATCH_STACK_NAME> \
RUN_ID=<RUN_ID> \
ROUNDS=<ROUND_COUNT> \
FRONT_PRIMER=<FRONT_PRIMER_DNA> \
BACK_PRIMER=<BACK_PRIMER_DNA> \
TOP_CANDIDATES=100 \
batch/submit_steps.sh

AWS_REGION=<AWS_REGION> \
STACK_NAME=<BATCH_STACK_NAME> \
RUN_ID=<RUN_ID> \
FRONT_PRIMER=<FRONT_PRIMER_DNA> \
BACK_PRIMER=<BACK_PRIMER_DNA> \
TOP_CANDIDATES=100 \
batch/submit_mountpoint.sh

AWS_REGION=<AWS_REGION> \
STACK_NAME=<BATCH_STACK_NAME> \
RUN_ID=<RUN_ID> \
FRONT_PRIMER=<FRONT_PRIMER_DNA> \
BACK_PRIMER=<BACK_PRIMER_DNA> \
batch/submit_compat.sh
AWS_REGION=<AWS_REGION> STACK_NAME=<BATCH_STACK_NAME> RUN_ID=<RUN_ID> batch/collect_results.sh
```

코드나 파라미터를 바꾼 뒤 한 단계를 수동으로 다시 실행해야 하면 `submit_steps.sh`로 새 `RUN_ID`를 제출하세요. 그래야 하위 단계 출력과 checksum manifest의 일관성이 유지됩니다. job definition의 재시도 정책은 한 run 안에서 일시적인 호스트 오류를 처리합니다.

제출 기록과 수집된 결과는 저장소가 무시하는 `batch/runs/` 아래에 기록됩니다. 비공개 URL, 자격 증명, 비공개 데이터가 들어 있는 manifest는 커밋하지 마세요.

## 검증

`batch/validate.sh`를 실행하세요. Bash 문법 검사, YAML 파싱, 가능하면 CloudFormation lint, 선택적 ShellCheck, JSON 파싱, 노출 검사, 고정된 계정 ID, 내부 URL, 로컬 소스 경로 스캔을 수행합니다. AWS를 호출하지 않습니다.
