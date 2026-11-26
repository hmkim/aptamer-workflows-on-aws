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
| `CreateInterfaceEndpoints` | `false` | `workflows-omics`, `storage-omics`, `control-storage-omics`, `analytics-omics`, `tags-omics` interface endpoint 생성 |
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
