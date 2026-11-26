[English](00-prerequisites.md) | [한국어](00-prerequisites.ko.md)

# 사전 준비

이 저장소의 어떤 경로든 시작하기 전에 아래 확인을 한 번 해 두세요. 단계마다 무엇이 보여야 하는지 적어 두었습니다.

## 워크스테이션 도구

Linux, 또는 WSL이나 클라우드 IDE 같은 Linux 셸을 쓰세요. 다음이 필요합니다.

| 도구 | 필요한 곳 | 확인 |
|---|---|---|
| Git | clone, 커밋으로 만드는 이미지 태그 | `git --version` |
| Bash 4 이상 | 모든 스크립트 (macOS 기본 Bash 3.2는 안 되므로 새 버전 설치) | `bash --version` |
| AWS CLI v2 | 모든 AWS 단계 | `aws --version`에 `aws-cli/2.`가 보임 |
| `jq`, `curl`, `unzip`, `sha256sum` | 설치 스크립트와 도우미 | `jq --version` |
| Python 3 | 오프라인 테스트 | `python3 --version` |
| Docker | 로컬 실행, HealthOmics 이미지, RaptGen 이미지 | `docker version` |
| AWS CLI용 Session Manager plugin | RaptGen-UI 포트 포워딩에만 필요 | `session-manager-plugin --version` |
| Node.js 22 이상 | 선택 사항인 RaptGen-UI 웹 접속에만 필요 | `node --version` |

저장소를 clone하고 오프라인 테스트를 실행하세요. AWS를 호출하지 않습니다.

```bash
git clone 'https://github.com/<GITHUB_ORGANIZATION>/aptamer-workflows-on-aws.git'
cd aptamer-workflows-on-aws
python3 -m unittest discover --start-directory tests --pattern 'test_*.py'
```

`OK`가 보여야 합니다. 선택 도구가 없으면 일부 테스트는 skipped로 표시될 수 있습니다.

## AWS 계정과 자격 증명

네트워크, IAM 역할, S3 버킷, 컴퓨팅을 만들 수 있는 AWS 계정을 쓰세요. 처음 실행할 때는 샌드박스나 개발 계정이 알맞습니다.

AWS IAM Identity Center(`aws sso login`)나 역할(role) 같은 임시 자격 증명을 쓰세요. 이 저장소 안 파일에 액세스 키를 넣지 마세요. 현재 자격 증명을 확인합니다.

```bash
aws sts get-caller-identity --query Arn --output text
```

역할 또는 사용자 ARN이 보여야 합니다. 이 값을 이슈나 커밋에 붙여 넣지 마세요.

설치 스크립트를 실행하는 자격 증명에는 `CAPABILITY_NAMED_IAM`으로 CloudFormation을 쓸 권한(템플릿이 IAM 역할을 만듭니다)과 VPC, EC2, S3, KMS, ECR, AWS Batch, CodeBuild, CloudWatch Logs, HealthOmics 리소스를 만들 권한이 필요합니다. HealthOmics VPC 모드에는 `omics.amazonaws.com`에 대한 `iam:CreateServiceLinkedRole`도 필요합니다.

## 리전

AWS 리전 하나를 정해 모든 곳에서 같은 값을 쓰세요.

```bash
export AWS_REGION='<REGION>'
aws ec2 describe-availability-zones --query 'AvailabilityZones[].ZoneName' --output text
```

가용 영역 이름이 두 개 이상 보여야 합니다. **가용 영역(Availability Zone, AZ)**은 리전 안에 있는 하나 이상의 분리된 데이터 센터입니다.

AWS HealthOmics를 쓸 계획이라면 [HealthOmics 엔드포인트 목록](https://docs.aws.amazon.com/general/latest/gr/healthomics-quotas.html)에서 그 리전이 HealthOmics를 제공하는지 확인하세요. HealthOmics VPC 모드를 쓸 계획이라면 그 리전에서 HealthOmics가 지원하는 AZ도 확인해 두세요([지원 AZ](https://docs.aws.amazon.com/omics/latest/dev/workflows-vpc-internet.html)).

## 할당량

**서비스 할당량(service quota)**은 리전별 계정 한도입니다. 예를 들어 동시에 실행할 수 있는 vCPU 수입니다. AWS Batch는 할당량을 넘어 인스턴스를 시작할 수 없고, 그러면 job이 `RUNNABLE` 상태에 머뭅니다.

CPU 컴퓨팅(기본 `MaxvCpus` 72, 인스턴스 계열 `c7i,c6i`)은 "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances" 할당량을 씁니다.

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.Value' --output text
```

GPU 컴퓨팅(기본 `GpuMaxvCpus` 8, `g5.xlarge,g6.xlarge`)은 "Running On-Demand G and VT instances" 할당량을 씁니다. **GPU 경로를 고르기 전에 꼭 확인하세요.** 새 계정은 이 값이 낮거나 0인 경우가 많습니다.

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA \
  --query 'Quota.Value' --output text
```

사용할 vCPU 수(기본값이면 8) 이상인 숫자가 보여야 합니다. 더 낮으면 Service Quotas 콘솔(EC2, "Running On-Demand G and VT instances")에서 증가를 요청하거나 더 작은 `--gpu-max-vcpus`를 넘기세요. `scripts/setup-batch.sh --gpu`도 이 확인을 다시 하고 경고를 출력합니다.

## 비용이 드는 부분

아래 항목은 존재하거나 실행되는 동안 요금이 나옵니다. 시작하기 전에 사용할 리전의 요금 페이지를 확인하고, 끝나면 [정리 가이드](90-cleanup.ko.md)를 따르세요.

| 항목 | 만드는 곳 | 과금 |
|---|---|---|
| NAT gateway (와 Elastic IP) | 네트워크 스택 | 존재하는 동안 시간당, 그리고 처리한 GB당 |
| AWS Batch 뒤의 EC2 인스턴스 | Batch 스택 | job이 실행되는 동안만. compute environment는 0까지 줄어듭니다 |
| GPU 인스턴스 (G 계열) | `--gpu`를 쓴 Batch 스택 | GPU job이 실행되는 동안만. 시간당 요금이 CPU보다 높습니다 |
| HealthOmics 실행과 실행 스토리지 | 사용자가 시작한 실행 | 실행별 컴퓨팅, 실행별 스토리지 |
| HealthOmics interface endpoint | `--interface-endpoints` | endpoint별, AZ별 시간당, 그리고 GB당 |
| S3, ECR, KMS 키, CloudWatch Logs | Batch와 HealthOmics 스택 | 저장량과 요청 수. 직접 지우지 않으면 스택 삭제 후에도 남습니다 |
| RaptGen-UI EC2 호스트 | RaptGen UI 스택 | 실행 중 시간당, 그리고 EBS 볼륨 |

요금 페이지: [Amazon VPC (NAT gateway, PrivateLink)](https://aws.amazon.com/vpc/pricing/), [Amazon EC2](https://aws.amazon.com/ec2/pricing/), [AWS HealthOmics](https://aws.amazon.com/healthomics/pricing/), [Amazon S3](https://aws.amazon.com/s3/pricing/).

## 다음 단계

[README의 경로 표](../../README.ko.md#경로-고르기)로 돌아가거나, [공유 네트워크](10-network.ko.md)로 이어 가세요.
