[English](40-both.md) | [한국어](40-both.ko.md)

# AWS Batch와 HealthOmics 함께 쓰기

Batch와 HealthOmics는 prefix 하나를 공유하는 서로 독립된 스택입니다. 한 번에 배포해도 되고, 순서에 상관없이 하나씩 배포해도 됩니다. 모든 스크립트는 멱등적(idempotent)입니다. 같은 옵션으로 다시 실행해도 아무것도 바뀌지 않습니다.

| 스택 | 만드는 것 | 네트워크 필요 |
|---|---|---|
| `<prefix>-network` | `setup-network.sh` 또는 자동 | — |
| `<prefix>-batch` | `setup-batch.sh` | 예 |
| `<prefix>-healthomics` | `setup-healthomics.sh` | 아니요 |
| `<prefix>-healthomics-vpc` | `setup-healthomics.sh --vpc` (아직 검증되지 않음) | 예 |

[사전 준비](00-prerequisites.ko.md)부터 시작하세요.

```bash
export AWS_REGION='<REGION>'
export PREFIX='aptamer-workflows'
```

## 한 번에 둘 다

```bash
scripts/setup-all.sh --prefix "$PREFIX" --region "$AWS_REGION"
```

`setup-network.sh`, `setup-batch.sh`(기본값 CPU만), `setup-healthomics.sh`(`RESTRICTED` 모드)를 차례로 실행합니다. 각 스택이 `CREATE_COMPLETE`가 되고 마지막에 `all stacks for prefix aptamer-workflows are deployed`가 보여야 합니다.

전달되는 옵션:

| 옵션 | 전달 대상 | 의미 |
|---|---|---|
| `--cpu`, `--gpu` | `setup-batch.sh` | 컴퓨팅 선택. [Batch 가이드](20-batch.ko.md#2단계-스택-배포) 참고 |
| `--build-image` | `setup-batch.sh` | CodeBuild로 CPU 파이프라인 이미지 빌드 |
| `--gpu-max-vcpus <n>`, `--gpu-instance-types <list>` | `setup-batch.sh` | GPU 용량 |
| `--mountpoint-version <v>`, `--mountpoint-sha256 <h>` | `setup-batch.sh` | Mountpoint 패키지 고정 |
| `--vpc`, `--interface-endpoints` | `setup-healthomics.sh` | HealthOmics VPC 모드 (아직 검증되지 않음) |

예: 파이프라인 이미지를 포함한 CPU + GPU Batch, 그리고 `RESTRICTED` 모드 HealthOmics:

```bash
scripts/setup-all.sh --prefix "$PREFIX" --region "$AWS_REGION" --cpu --gpu --build-image
```

그다음 각 가이드의 실행 단계를 이어 가세요. [Batch 5~7단계](20-batch.ko.md#5단계-공개-d1-데이터-불러오기-cpu), [HealthOmics 2~7단계](30-healthomics.ko.md#2단계-스택-배포)(스택은 이미 있으므로 2단계에서는 출력만 다시 읽습니다). HealthOmics 스택에는 자체 버킷과 ECR 리포지토리가 있으므로, HealthOmics 3단계처럼 워크플로 이미지를 그곳에 빌드해 push하세요.

## 차례로 하나씩

### Batch 먼저, 그다음 HealthOmics

1. [Batch 가이드](20-batch.ko.md)를 따르세요.
2. 나중에 **같은** `PREFIX`와 리전으로 [HealthOmics 가이드](30-healthomics.ko.md)를 따르세요. Batch 스택은 건드리지 않습니다.
3. `--vpc`를 쓰면 `setup-healthomics.sh`가 기존 `<prefix>-network`를 찾아 재사용합니다(`using existing network stack ...`).

### HealthOmics 먼저, 그다음 Batch

1. [HealthOmics 가이드](30-healthomics.ko.md)를 따르세요. `--vpc`가 없으면 아직 네트워크가 없고, 네트워크 요금도 나오지 않습니다.
2. 나중에 같은 `PREFIX`로 [Batch 가이드](20-batch.ko.md)를 따르세요. `setup-batch.sh`가 네트워크를 만들거나(`network stack ... not found; creating it`) VPC 모드가 만든 네트워크를 재사용합니다.

### 나중에 일부만 추가하거나 삭제하기

- Batch에 GPU 추가: `scripts/setup-batch.sh --prefix "$PREFIX" --region "$AWS_REGION" --cpu --gpu`.
- HealthOmics VPC 모드 추가: `scripts/setup-healthomics.sh --prefix "$PREFIX" --region "$AWS_REGION" --vpc`.
- 일부만 삭제: `scripts/cleanup.sh --stacks <list>`. [정리](90-cleanup.ko.md)를 보세요.

## 검증 기록

> TODO(validation): 3차 작업에서 `setup-all.sh`의 날짜, 리전, 결과를 여기와 [검증 가이드](../validation.ko.md#검증-기록)에 채웁니다.

## 다음 단계

- [Batch 스택에서 RaptGen](../raptgen/README.ko.md)
- [정리](90-cleanup.ko.md)
