[English](README.md) | [한국어](README.ko.md)

# AWS HealthOmics에서 RaptGen 실행 (다음 단계)

자리만 잡아 둔 문서입니다. 구현되거나 검증된 것은 아직 없습니다. 문서의 자리 표시: [HealthOmics에서 RaptGen 실행](../../docs/raptgen/healthomics.ko.md).

계획:

- RaptGen 학습과 encode를 HealthOmics private workflow로 실행합니다. `../containers`의 이미지를 사용합니다.
- HealthOmics run에서 쓸 수 있는 GPU 인스턴스 종류와 GPU 이미지가 그 인스턴스에 맞는지 확인합니다.
- `../results`의 Batch 결과와 일치하는지 확인합니다 (같은 입력, 같은 파라미터에서 실행 시간과 loss 곡선 비교). 학습은 seed가 고정되지 않으므로 결과는 bit 단위가 아니라 통계적으로 비교합니다.

이 폴더에는 워크플로 정의, 파라미터 템플릿, 비교 노트를 둡니다.
