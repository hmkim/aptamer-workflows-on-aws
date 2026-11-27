[English](healthomics.md) | [한국어](healthomics.ko.md)

# AWS HealthOmics에서 RaptGen 실행 (다음 단계)

**자리만 잡아 둔 문서입니다. 구현되거나 검증된 것은 아직 없습니다.** 이 페이지는 다음 단계를 위해 문서의 자리를 확보할 뿐입니다. 지금 동작하는 것은 [AWS Batch에서 RaptGen 실행](batch.ko.md)을 보세요.

## 계획

- RaptGen 학습과 encode를 AWS HealthOmics private workflow로 실행합니다. [`raptgen/containers`](../../raptgen/containers/README.ko.md)의 컨테이너 이미지를 재사용합니다.
- HealthOmics run에서 쓸 수 있는 GPU 인스턴스 종류와 GPU 이미지가 그 인스턴스에 맞는지 알아봅니다.
- Batch 결과와 비교합니다 (같은 입력, 같은 파라미터에서 실행 시간과 loss 곡선을 비교). RaptGen 학습은 seed가 고정되지 않으므로 결과는 bit 단위가 아니라 통계적으로 비교합니다.

## 작업이 놓일 곳

워크플로 정의, 파라미터 템플릿, 비교 노트는 만들어지면 [`raptgen/healthomics/`](../../raptgen/healthomics/README.ko.md)에 둡니다. 이 저장소의 HealthOmics 구성(기본 RESTRICTED 네트워킹, 아직 검증되지 않은 선택 VPC 모드)은 [`healthomics/README.md`](../../healthomics/README.ko.md)를 보세요.

돌아가기: [목차](README.ko.md)
