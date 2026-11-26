[English](10-network.md) | [한국어](10-network.ko.md)

# 공유 private 네트워크

AWS Batch, RaptGen-UI EC2 호스트, 선택 사항인 HealthOmics VPC 모드는 모두 private 네트워크 하나를 함께 씁니다. 이 네트워크는 `batch/network.yaml`이 `<prefix>-network` 스택으로 만듭니다. 이 단계를 직접 실행할 일은 많지 않습니다. 네트워크가 없으면 `scripts/setup-batch.sh`와 `scripts/setup-healthomics.sh --vpc`가 자동으로 만듭니다. 가용 영역을 직접 고르고 싶을 때만 직접 실행하세요.

`--vpc` 없이 쓰는 HealthOmics(기본 `RESTRICTED` 모드)는 이 네트워크를 쓰지 않습니다.

## 만들어지는 것

**VPC**(virtual private cloud)는 AWS 안의 나만의 격리된 네트워크입니다. **서브넷(subnet)**은 그 안의 주소 범위로, 가용 영역 하나에 놓입니다. **NAT gateway**는 퍼블릭 주소가 없는 머신이 인터넷으로 나가는 연결을 열 수 있게 해 주며, 인터넷에서는 안으로 들어올 수 없습니다.

```text
VPC 10.64.0.0/16 (default)
├── NAT subnet 10.64.0.0/24 (AZ 1): NAT gateway with an Elastic IP; no automatic public IPs
├── Private subnet 1 10.64.10.0/24 (AZ 1) ──┐  default route 0.0.0.0/0 -> NAT gateway
└── Private subnet 2 10.64.20.0/24 (AZ 2) ──┘
```

- 두 private subnet은 **서로 다른 AZ**에 있습니다. HealthOmics VPC 모드는 AZ당 서브넷을 최대 하나만 받으므로 이 구성이 맞습니다.
- 컴퓨팅(Batch 인스턴스, RaptGen-UI 호스트, HealthOmics 네트워크 인터페이스)은 private subnet에만 들어갑니다. 어느 것도 퍼블릭 IP 주소를 받지 않습니다.
- NAT gateway는 AZ 1에 하나만 있습니다. 비용을 줄이는 대신, AZ 1에 문제가 생기면 private subnet의 인터넷 아웃바운드가 끊깁니다.
- Batch 스택은 private route table에 S3 **gateway endpoint**를 추가합니다. 그래서 Batch의 S3 트래픽은 NAT gateway를 거치지 않고 AWS 네트워크 안에 머뭅니다.

출력: `VpcId`, `PrivateSubnetIds`, `PrivateRouteTableIds`, `VpcCidr`, `PrivateSubnetAvailabilityZones`.

## 1단계: 변수 설정

```bash
export AWS_REGION='<REGION>'
export PREFIX='aptamer-workflows'
```

`PREFIX`는 모든 스택 이름의 앞부분이 됩니다. 소문자, 숫자, 하이픈만 쓰세요. 서로 독립된 스택 세트를 하나 더 만들려면 새 prefix를 쓰세요.

## 2단계 (선택): 가용 영역 고르기

HealthOmics VPC 모드를 쓰지 않는다면 이 단계를 건너뛰세요. 쓴다면 리전의 AZ를 나열하고 HealthOmics [지원 AZ 목록](https://docs.aws.amazon.com/omics/latest/dev/workflows-vpc-internet.html)과 비교하세요.

```bash
aws ec2 describe-availability-zones --region "$AWS_REGION" \
  --query 'AvailabilityZones[].ZoneName' --output text
```

두 목록에 모두 있는 서로 다른 AZ 두 개를 고르세요.

## 3단계: 네트워크 배포

기본 AZ(리전의 처음 두 AZ):

```bash
scripts/setup-network.sh --prefix "$PREFIX" --region "$AWS_REGION"
```

직접 고른 AZ:

```bash
scripts/setup-network.sh --prefix "$PREFIX" --region "$AWS_REGION" \
  --az1 '<AZ_NAME_1>' --az2 '<AZ_NAME_2>'
```

`deploying aptamer-workflows-network from batch/network.yaml`, 이어서 `aptamer-workflows-network: CREATE_COMPLETE`(또는 `UPDATE_COMPLETE`), 출력 표, 다음 단계 안내가 보여야 합니다. 같은 값으로 다시 실행해도 아무것도 바뀌지 않습니다.

## 4단계: 결과 확인

```bash
aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$PREFIX-network" \
  --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnetAvailabilityZones`].OutputValue' --output text
```

쉼표로 구분된 서로 다른 AZ 이름 두 개가 보여야 합니다.

## 비용 참고

NAT gateway는 job이 없어도 네트워크 스택이 있는 동안 시간당 요금이 나오고, 통과한 GB당 요금도 나옵니다. 다 쓰면 네트워크를 삭제하세요([정리](90-cleanup.ko.md) 참고).

## 다음 단계

- [AWS Batch](20-batch.ko.md)
- [AWS HealthOmics](30-healthomics.ko.md) (VPC 모드가 이 네트워크를 씁니다)
- [둘 다, 한 번에 또는 차례로](40-both.ko.md)
