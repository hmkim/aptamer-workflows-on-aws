[English](30-healthomics.md) | [한국어](30-healthomics.ko.md)

# AWS HealthOmics만 쓰기

**AWS HealthOmics**는 생물정보학 워크플로를 위한 관리형 서비스입니다. 워크플로 정의(여기서는 `nextflow/`의 Nextflow 워크플로)를 **private workflow**로 등록한 뒤 **run**을 시작하면, HealthOmics가 실행마다 컴퓨팅과 스토리지를 마련하고 끝나면 치웁니다. **run role**은 실행 중에 HealthOmics가 입력을 읽고, 출력을 쓰고, 컨테이너 이미지를 가져올 때 쓰는 IAM 역할입니다.

이 가이드는 스택 하나 `<prefix>-healthomics`(`healthomics/infrastructure.yaml`)를 배포합니다. private 암호화 S3 버킷, private ECR 리포지토리, KMS 키, run role이 만들어집니다. VPC는 **만들지 않습니다**. 실행은 기본 `RESTRICTED` 네트워킹 모드를 씁니다. 끝부분에 선택 사항인 [VPC 모드](#선택-vpc-네트워킹-모드-아직-검증되지-않음) 절이 있습니다.

[사전 준비](00-prerequisites.ko.md)부터 시작하세요. 워크플로 이미지를 빌드하려면 워크스테이션에 Docker가 필요합니다.

## 1단계: 변수 설정

```bash
export AWS_REGION='<REGION>'
export PREFIX='aptamer-workflows'
export HO_STACK="$PREFIX-healthomics"
```

## 2단계: 스택 배포

```bash
scripts/setup-healthomics.sh --prefix "$PREFIX" --region "$AWS_REGION"
```

`deploying aptamer-workflows-healthomics from healthomics/infrastructure.yaml`, 이어서 `CREATE_COMPLETE`, 출력 표(`BucketName`, `RepositoryUri`, `PipelineImage`, `RunRoleArn`, `InputPrefix`, `OutputPrefix`, `KmsKeyArn`), 다음 단계 안내가 보여야 합니다.

옵션: `--image-tag <tag>`(기본 `git-<commit>`), `--input-prefix`(기본 `inputs`), `--output-prefix`(기본 `outputs`). run role은 입력 prefix만 읽고 출력 prefix에만 쓸 수 있습니다.

출력 값을 변수에 담습니다.

```bash
ho_output() {
  aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$HO_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
export BUCKET_NAME=$(ho_output BucketName)
export REPOSITORY_URI=$(ho_output RepositoryUri)
export IMAGE_WITH_TAG=$(ho_output PipelineImage)
export RUN_ROLE_ARN=$(ho_output RunRoleArn)
```

## 3단계: 워크플로 이미지 빌드와 push

`RESTRICTED` 모드에서는 워크플로 작업이 인터넷에 접근할 수 없으므로 모든 도구가 이미지 안에 미리 들어 있어야 합니다. `Dockerfile`을 빌드해 private 리포지토리에 push합니다.

```bash
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${REPOSITORY_URI%%/*}"
docker build --platform linux/amd64 --tag "$IMAGE_WITH_TAG" .
docker push "$IMAGE_WITH_TAG"
```

`Login Succeeded`가 보이고, push 진행 상황이 `digest: sha256:...` 줄로 끝나야 합니다. 리포지토리 태그는 변경 불가(immutable)입니다. 같은 태그로 다른 이미지를 push하면 실패합니다. 새로 빌드할 때는 2단계에서 새 `--image-tag`를 쓰세요.

실행은 태그가 아니라 이미지 digest로 고정합니다.

```bash
DIGEST=$(aws ecr describe-images --region "$AWS_REGION" --repository-name "${REPOSITORY_URI#*/}" \
  --image-ids "imageTag=${IMAGE_WITH_TAG##*:}" --query 'imageDetails[0].imageDigest' --output text)
export PIPELINE_IMAGE="$REPOSITORY_URI@$DIGEST"
echo "$PIPELINE_IMAGE"
```

`<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<repository>@sha256:<64자리 16진수>`가 보여야 합니다.

## 4단계: 공개 D1 데이터 업로드

아래 명령은 D1을 `inputs/DRA009383/`에 내려받고(각 MD5 확인), 버킷이 모든 퍼블릭 접근을 막고 있지 않으면 진행을 거부하며, 파일을 입력 prefix로 복사합니다.

```bash
bash data/upload_to_s3.sh "$AWS_REGION" "$BUCKET_NAME" inputs/DRA009383
```

`Total Objects: 9`로 끝나는 목록이 보여야 합니다.

HealthOmics에는 전체 S3 URI가 들어간 samplesheet가 필요합니다. D1 samplesheet로 만들어 업로드합니다.

```bash
awk -v base="s3://$BUCKET_NAME/inputs/DRA009383/" 'BEGIN { FS = OFS = "\t" }
  NR == 1 { print; next } { print $1, base $2 }' \
  nextflow/samplesheet.dra009383.tsv > inputs/samplesheet.healthomics.tsv
aws s3 cp inputs/samplesheet.healthomics.tsv "s3://$BUCKET_NAME/inputs/samplesheet.tsv" \
  --region "$AWS_REGION" --only-show-errors
export SAMPLESHEET_URI="s3://$BUCKET_NAME/inputs/samplesheet.tsv"
head -3 inputs/samplesheet.healthomics.tsv
```

헤더 `round	file`과 `0	s3://<bucket>/inputs/DRA009383/R0_DRR201861.fastq.gz` 같은 줄이 보여야 합니다.

## 5단계: private workflow 등록

```bash
WORKFLOW_NAME=aptamer-workflow healthomics/orchestrate.sh register
```

스크립트는 `nextflow/main.nf`와 설정 파일을 zip으로 묶고, `create-workflow`를 호출하고, 워크플로가 `ACTIVE`가 될 때까지 기다린 뒤 `id`, `arn`, `status`, `engine`, `storageType`을 출력합니다. 워크플로 ID는 Git이 무시하는 `healthomics/.state/`에 저장되어 이후 명령이 찾아 씁니다.

## 6단계: 실행 시작

```bash
source data/dra009383.env.example
export RUN_NAME="d1-$(date -u +%Y%m%d%H%M)"
healthomics/orchestrate.sh run
```

`id`, `arn`, `status`(`PENDING`), `name`, `outputUri`가 담긴 JSON이 보여야 합니다. 기본값: `--networking-mode RESTRICTED`, 동적 실행 스토리지, `RETENTION_MODE=RETAIN`, `LOG_LEVEL=ALL`, 출력 위치 `s3://<BucketName>/outputs/<RUN_NAME>/`. 모든 변수는 [healthomics/README.ko.md](../../healthomics/README.ko.md)를 보세요.

## 7단계: 실행 확인

```bash
healthomics/orchestrate.sh status
```

인자가 없으면 마지막 실행 ID를 읽습니다. 실행 상태가 `PENDING`, `STARTING`에서 `RUNNING`을 거쳐 `COMPLETED`로 바뀌고, 이어서 작업(task) 표가 보여야 합니다. 콘솔에서는 AWS HealthOmics, Runs에서 볼 수 있습니다. 실행이 끝나면 출력을 나열합니다.

```bash
aws s3 ls "s3://$BUCKET_NAME/outputs/$RUN_NAME/" --region "$AWS_REGION" --recursive
```

실행 출력 폴더 아래에서 `<run id>/pubdir/enrich/top_candidates.tsv`를 찾을 수 있어야 합니다 (HealthOmics가 실행 ID와 `pubdir/`를 붙입니다). 옆에 `qc/`, `trimmed/`, `counts/`, `fold/`, `checksums.sha256`도 있습니다. 검증 실행에서는 정렬한 SHA-256이 같은 D1 데이터의 Batch copy-in 결과와 같았습니다. 다른 실행과 비교할 때는 [검증 가이드](../validation.ko.md)를 쓰세요.

## 선택: VPC 네트워킹 모드 (아직 검증되지 않음)

> **이 저장소에서 아직 검증되지 않았습니다.** 아래 단계는 AWS 공식 문서를 따르지만, 여기서 처음부터 끝까지 실행해 본 적은 없습니다. 워크플로에 더 넓은 네트워크 접근이 꼭 필요하지 않다면 `RESTRICTED` 모드를 쓰세요. 검증한 뒤 결과를 추가할 예정입니다.

기본값(`RESTRICTED`)에서 실행은 같은 리전의 Amazon S3와 Amazon ECR에만 접근할 수 있습니다. **VPC 모드**는 HealthOmics가 내 서브넷에 만드는 네트워크 인터페이스로 실행 트래픽을 보내므로, 실행이 VPC 안의 리소스에, 그리고 NAT gateway를 거쳐 인터넷에 접근할 수 있습니다. AWS 문서의 사실([VPC 네트워킹](https://docs.aws.amazon.com/omics/latest/dev/workflows-vpc-networking.html), [인터넷 접근](https://docs.aws.amazon.com/omics/latest/dev/workflows-vpc-internet.html), [interface endpoint](https://docs.aws.amazon.com/omics/latest/dev/vpc-interface-endpoints.html)):

- VPC 모드는 HealthOmics **configuration**(서브넷과 security group)으로 켜고, 실행을 `--networking-mode VPC --configuration-name <name>`으로 시작합니다.
- configuration에는 HealthOmics가 운영되는 AZ의 서브넷 1~16개(**AZ당 최대 하나**)와 security group 1~5개가 들어가며, 모두 같은 VPC에 있어야 합니다. `CREATING`에서 `ACTIVE`가 되기까지 최대 15분이 걸립니다. configuration은 바꿀 수 없고, 기본 한도는 계정과 리전당 10개입니다.
- 첫 configuration을 만들 때 service-linked role `AWSServiceRoleForHealthOmics`가 생성됩니다. 내 자격 증명에 `omics.amazonaws.com`에 대한 `iam:CreateServiceLinkedRole`이 필요합니다.
- 퍼블릭 서브넷에 두어도 실행이 인터넷에 접근하지 못합니다. [공유 네트워크](10-network.ko.md)처럼 NAT gateway 경로가 있는 private subnet을 쓰세요.
- S3 gateway endpoint는 선택 사항입니다. 같은 리전 S3 트래픽은 기본적으로 HealthOmics 서비스 네트워크를 거칩니다.
- **interface endpoint**(AWS PrivateLink)는 다른 기능입니다. VPC 안의 클라이언트가 HealthOmics API를 private하게 호출하게 해 줍니다. VPC 모드 실행에는 필요 없습니다. endpoint마다 AZ별 시간당 요금이 나옵니다. HealthOmics API(workflows, storage, analytics)가 모든 리전에 다 있지는 않으니, 켜기 전에 [엔드포인트 목록](https://docs.aws.amazon.com/general/latest/gr/healthomics-quotas.html)을 확인하세요.

VPC 구성 요소를 배포합니다. 공유 네트워크가 없으면 함께 만듭니다(필요하면 먼저 [네트워크 가이드](10-network.ko.md)로 AZ를 고르세요).

```bash
scripts/setup-healthomics.sh --prefix "$PREFIX" --region "$AWS_REGION" --vpc
```

옵션: `--configuration-name <name>`(기본 `<prefix>-vpc`), `--interface-endpoints`(PrivateLink endpoint 생성, 기본은 `workflows-omics`만), `--endpoint-services <list>`(`workflows-omics,storage-omics,control-storage-omics,analytics-omics,tags-omics` 중 선택, 스크립트가 먼저 리전 지원 여부를 확인), `--configuration-by-script`(CloudFormation 대신 `healthomics/vpc/omics-vpc-configuration.sh`로 configuration 생성).

`HealthOmics VPC networking mode is NOT YET VALIDATED in this repository`가 보이고, `<prefix>-healthomics-vpc` 스택이 `CREATE_COMPLETE`가 되고, configuration이 `ACTIVE`가 되어야 합니다. 이 스택은 HTTPS(TCP 443) egress만 있고 ingress는 없는 run security group을 추가합니다. configuration을 확인합니다.

```bash
healthomics/vpc/omics-vpc-configuration.sh status --region "$AWS_REGION" --name "$PREFIX-vpc"
```

6단계와 같은 변수로 VPC 모드 실행을 시작합니다.

```bash
healthomics/orchestrate.sh run --networking-mode VPC --configuration-name "$PREFIX-vpc"
```

자세한 내용: [healthomics/vpc/README.ko.md](../../healthomics/vpc/README.ko.md).

## 검증 기록

`RESTRICTED` 모드는 2026-11-26에 us-west-2에서 새 prefix로 검증했습니다. D1으로 2~7단계 통과, 결과가 Batch copy-in 결과와 같았습니다. 자세한 내용은 [검증 가이드](../validation.ko.md#검증-기록)에 있습니다. VPC 모드는 아직 검증되지 않았습니다.

## 다음 단계

- [AWS Batch 추가](40-both.ko.md#차례로-하나씩)
- [정리](90-cleanup.ko.md). HealthOmics 워크플로와 보존된 버킷은 따로 지워야 합니다
