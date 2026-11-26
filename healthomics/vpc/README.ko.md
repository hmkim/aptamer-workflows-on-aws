[English](README.md) | [한국어](README.ko.md)

# HealthOmics VPC 네트워킹 (아직 검증되지 않음)

> **아직 검증되지 않았습니다.** 이 디렉터리의 모든 내용은 AWS HealthOmics 개발자 가이드를 따랐지만 이 저장소에서 end-to-end로 실행해 본 적이 없습니다. 기본이자 검증된 경로는 [`../README.md`](../README.ko.md)의 `RESTRICTED` 네트워킹입니다.

| 파일 | 용도 |
|---|---|
| `vpc.yaml` | run 보안 그룹(HTTPS egress만, ingress 없음), VPC 모드 run용 `AWS::Omics::Configuration`, 선택형 PrivateLink interface endpoint |
| `omics-vpc-configuration.sh` | CloudFormation configuration의 CLI 대안: `create`(`ACTIVE`까지 최대 15분 대기), `status`, `wait`, `delete` |

## `vpc.yaml` 파라미터

| 파라미터 | 기본값 | 뜻 |
|---|---|---|
| `VpcId` | 필수 | network 스택의 `VpcId` output |
| `PrivateSubnetIds` | 필수 | network 스택의 `PrivateSubnetIds` output: private, NAT 경로 있음, AZ당 하나 |
| `VpcCidr` | 필수 | network 스택의 `VpcCidr` output. endpoint 보안 그룹 범위를 정함 |
| `CreateConfiguration` | `true` | HealthOmics configuration을 CloudFormation에서 만듦. 스크립트를 쓰려면 `false` |
| `ConfigurationName` | 스택 이름 | `start-run --configuration-name`에 넘기는 configuration 이름 |
| `CreateInterfaceEndpoints` | `false` | 아래에서 고른 interface endpoint 생성 |
| `EndpointWorkflows` | `true` | `com.amazonaws.<region>.workflows-omics` (workflow, run API) |
| `EndpointStorage` | `false` | `storage-omics` (sequence store data plane) |
| `EndpointControlStorage` | `false` | `control-storage-omics` (sequence/reference store control plane) |
| `EndpointAnalytics` | `false` | `analytics-omics` (variant, annotation store) |
| `EndpointTags` | `false` | `tags-omics` (태그) |

`scripts/setup-healthomics.sh --vpc --interface-endpoints [--endpoint-services <list>]`가 이 값을 정하고(기본 `workflows-omics`만), 먼저 각 서비스가 그 리전에 있는지 확인합니다. 모든 리전에 다섯 개가 다 있지는 않습니다. 확인 방법:

```bash
aws ec2 describe-vpc-endpoint-services --region <REGION> \
  --query 'ServiceNames[?contains(@, `omics`)]' --output text
```

2026-11-26 기준 us-east-1, us-west-2, eu-west-1에는 다섯 개가 모두 있었고, ap-northeast-2에는 `workflows-omics`, `analytics-omics`, `tags-omics`만 있었습니다. 템플릿 변경은 `cfn-lint`와 CloudFormation 템플릿 검증으로만 확인했고 배포하지 않았습니다.
| `ProjectTag` | `aptamer-workflows` | `Project` 태그 값 |

Output: `RunSecurityGroupId`, `SubnetIds`, `ConfigurationName`, `ConfigurationArn`, `InterfaceEndpointsEnabled`, `ValidationStatus`.

## 이 설계가 기대는 사실

[VPC networking](https://docs.aws.amazon.com/omics/latest/dev/workflows-vpc-networking.html), [internet access](https://docs.aws.amazon.com/omics/latest/dev/workflows-vpc-internet.html), [interface endpoints](https://docs.aws.amazon.com/omics/latest/dev/vpc-interface-endpoints.html)에서 가져온 내용입니다.

- `RESTRICTED`(기본값)는 같은 Region의 S3와 ECR만 허용합니다. `VPC` 모드는 run 트래픽을 내 subnet 안의 HealthOmics 관리 네트워크 인터페이스로 보냅니다.
- configuration 하나는 subnet 1~16개(AZ당 최대 하나, HealthOmics가 운영되는 AZ)와 같은 VPC의 보안 그룹 1~5개를 받습니다. 한 번 만들면 바꿀 수 없고, 계정당 기본 10개입니다.
- 첫 configuration이 `AWSServiceRoleForHealthOmics` service-linked role을 만듭니다. 배포하는 사람에게 `omics.amazonaws.com`에 대한 `iam:CreateServiceLinkedRole` 권한이 필요합니다.
- public subnet은 run에 인터넷을 주지 않습니다. `../../batch/network.yaml`이 만드는 것처럼 NAT 경로가 있는 private subnet을 쓰세요.
- interface endpoint는 VPC 안의 클라이언트가 HealthOmics API를 private하게 호출하게 해 줍니다. VPC 모드 run에는 필요하지 않습니다. endpoint마다 AZ별로 시간당 요금이 있습니다.

## VPC 모드로 실행

```bash
AWS_REGION='<AWS_REGION>' ... ../orchestrate.sh run --networking-mode VPC --configuration-name '<CONFIGURATION_NAME>'
```

`RESTRICTED` run과 같은 환경 변수를 쓰세요. network를 지우기 전에 configuration(또는 `vpc.yaml` 스택)을 먼저 지우세요. HealthOmics 네트워크 인터페이스가 subnet과 보안 그룹 삭제를 지연시킬 수 있습니다.
