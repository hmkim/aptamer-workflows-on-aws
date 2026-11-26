[English](README.md) | [한국어](README.ko.md)

# RaptGen 가이드

RaptGen은 SELEX 시퀀싱 데이터에서 새 aptamer 후보 서열을 만들어 주는 모델이고, RaptGen-UI는 그 웹 화면입니다. 이 가이드는 둘을 AWS에서 실행하는 방법을, 개념 설명부터 복사해서 붙여 넣는 단계까지 보여 줍니다. 코드의 기술 참조는 [`raptgen/README.md`](../../raptgen/README.ko.md)에 있습니다.

| 가이드 | 이럴 때 읽으세요 |
|---|---|
| [개념](concepts.ko.md) | aptamer, SELEX, RaptGen, RaptGen-UI를 배경지식 없이 이해하고 싶을 때 |
| [AWS Batch에서 RaptGen 실행](batch.ko.md) | 이미지를 빌드하고, job definition을 배포하고, CPU 또는 GPU로 학습과 벤치마크를 실행하고, S3에서 결과를 읽고 싶을 때 |
| [CPU vs GPU 벤치마크](benchmark.ko.md) | 측정된 속도 차이, 차이가 작은 이유, 그 의미를 보고 싶을 때 |
| [사설 EC2에서 RaptGen-UI 실행](ui.ko.md) | public IP 없이 웹 UI를 띄우고 SSM 포트 포워딩으로 접속하고, 테스트 결과와 화면을 보고 싶을 때 |
| [웹 접속 (선택)](ui-web.ko.md) | CloudFront와 Cognito로 브라우저 접속을 열고 싶을 때 (full과 readonly 역할, 먼저 경고를 읽으세요) |
| [HealthOmics에서 RaptGen 실행](healthomics.ko.md) | 다음 단계를 위한 자리 |

## 권장 순서

1. [개념](concepts.ko.md)을 읽습니다 (10분).
2. 원하는 compute(CPU, GPU, 둘 다)로 Batch 스택을 만듭니다: [Batch만 사용](../getting-started/20-batch.ko.md). 그다음 이 폴더로 돌아와 [AWS Batch에서 RaptGen 실행](batch.ko.md)을 따라 합니다.
3. 선택: 사설 호스트의 [RaptGen-UI](ui.ko.md). 브라우저 주소가 꼭 필요할 때만 [웹 접속](ui-web.ko.md)을 씁니다.

저장소 전체와 다른 경로(Batch만, HealthOmics만, 동시에, 차례로)는 [메인 README](../../README.ko.md)에서 시작하세요.

## 안전 요약

- 모든 것이 기본적으로 비공개입니다: public IP 없음, 인바운드 규칙 없음, 접속은 SSM.
- RaptGen-UI에는 로그인과 사용자별 데이터 구분이 없습니다. 닿을 수 있는 누구나 모든 모델을 삭제할 수 있습니다.
- 공개 데이터 또는 민감하지 않은 서열 데이터만 사용하세요.
- 가격은 바뀝니다. 이 문서는 요금이 부과되는 항목만 알려 주고 가격은 AWS 요금 페이지에 맡깁니다.

`images/`의 이미지는 RaptGen-UI(Hamada Lab, MIT) 화면 캡처입니다.
