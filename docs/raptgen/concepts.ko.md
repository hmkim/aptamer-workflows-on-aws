[English](concepts.md) | [한국어](concepts.ko.md)

# RaptGen과 RaptGen-UI: 개념

이 문서는 RaptGen과 RaptGen-UI가 무엇인지 쉬운 말로 설명합니다. 머신러닝 배경지식은 필요 없습니다. AWS 실행 방법은 [AWS Batch에서 RaptGen 실행](batch.ko.md) 또는 [사설 EC2에서 RaptGen-UI 실행](ui.ko.md)을 보세요.

## 한눈에 보기

| 질문 | 답 |
|---|---|
| RaptGen은 무엇인가요? | SELEX 시퀀싱 데이터를 학습해 **새 aptamer 후보 서열을 만들어 주는 모델**입니다. |
| RaptGen-UI는 무엇인가요? | 명령어 없이 브라우저에서 RaptGen 작업을 하게 해 주는 웹 애플리케이션입니다. |
| 누가 만들었나요? | 둘 다 와세다대 Hamada Lab ([hmdlab](https://github.com/hmdlab))에서 만들었습니다. |
| 라이선스 | 둘 다 MIT입니다. |
| GPU가 필요한가요? | 아니요. 둘 다 CPU로 돌아갑니다. GPU 이득은 기대보다 작습니다. [CPU vs GPU 벤치마크](benchmark.ko.md)를 보세요. |
| 입력과 출력 | 입력은 시퀀싱 read(FASTQ/FASTA), 출력은 **서열뿐**입니다. 3차원 구조나 결합력 값은 나오지 않습니다. |

```text
 SELEX 실험 -> NGS 시퀀싱 -> 서열 정리(trim/count) -> RaptGen -> 후보 서열 -> 구조 / 도킹 / MD -> 실험 검증
                                                        ^
                                              RaptGen-UI는 이 단계를
                                              브라우저로 쓰게 해 줍니다
```

## 배경: aptamer와 SELEX

**aptamer.** aptamer는 보통 수십 개 염기로 된 짧은 DNA 또는 RNA 조각입니다. 항체처럼 목표 물질(단백질, 작은 분자)에 단단히 붙습니다.

**SELEX.** SELEX는 "잘 붙는 서열만 남기기"를 여러 번 반복하는 실험입니다.

```text
무작위 서열 수조 개 -> 목표 물질에 노출 -> 붙은 것만 남기기 -> PCR로 증폭 -> 반복 (Round 1, 2, 3 ...)
```

라운드를 거칠수록 잘 붙는 서열이 많아집니다. 각 라운드를 NGS(차세대 시퀀싱)로 읽으면 수만에서 수백만 개 서열이 나옵니다. 이것이 **HT-SELEX**(high-throughput SELEX)입니다. read 하나는 보통 이렇게 생겼습니다.

```text
[앞 고정 구간 (primer)] [무작위 구간] [뒤 고정 구간 (primer)]
 TAATACGACTCACTATAGGG...  (무작위 염기 약 30개)  ...CCTATGCGTGCTAGTGTGA
```

**횟수 기반 분석의 한계.** 보통은 "많이 나온 서열", "라운드마다 늘어난 서열"로 순위를 매깁니다. 이 방법은 시퀀싱에서 실제로 읽힌 서열만 고를 수 있습니다. 읽히지 않은 더 좋은 서열은 찾을 수 없습니다. RaptGen은 이 한계를 줄이려고 만들어졌습니다.

## RaptGen이 하는 일

RaptGen은 각 서열을 **2차원 지도 위의 점**으로 바꾸고, 지도 위 어느 점에서든 새 서열을 만들어 낼 수 있습니다. 논문: Iwano N. et al., *Nature Computational Science* 2022 ([논문](https://www.nature.com/articles/s43588-022-00249-6)).

| 비유 | RaptGen에서는 |
|---|---|
| 도시 지도 | latent space (잠재 공간, 2차원 좌표) |
| 집 한 채 | 서열 하나 |
| 비슷한 동네 | 공통 패턴(motif)을 가진 서열 묶음 |
| 빈 땅에 새 집 짓기 | 학습 데이터에 없던 새 서열 생성 |

### 동작 4단계

| 단계 | 이름 | 하는 일 | 결과 |
|---|---|---|---|
| 1 | VAE 학습 | 서열을 지도에 놓는 법을 배웁니다 | 학습된 모델 |
| 2 | Encode | 서열을 좌표로 바꿉니다 | 서열마다 (x, y) |
| 3 | GMM 군집 | 지도 위 점들을 덩어리로 묶습니다 | 군집 중심이 대표 서열 |
| 4 | Decode / BO | 좌표를 서열로 바꿉니다. BO는 실험값으로 다음 좌표를 고릅니다 | 새 후보 서열 |

### 용어

- **VAE** (variational autoencoder): 데이터를 몇 개의 숫자로 줄였다가 다시 늘리는 모델입니다.
- **pHMM** (profile hidden Markov model): 서열 패턴을 표현하는 확률 모델입니다. RaptGen은 VAE의 "다시 늘리는" 부분에 pHMM을 써서 motif를 잘 잡습니다.
- **GMM** (Gaussian mixture model): 점들을 몇 개의 타원 덩어리로 나누는 방법입니다.
- **BO** (Bayesian optimization): 지금까지의 실험값을 보고 다음에 어느 후보를 잴지 고르는 방법입니다.

### 논문이 보여 준 것

- 시뮬레이션 데이터에서 motif별로 지도 위에 깔끔하게 나뉘었습니다.
- 실제 SELEX 데이터 두 세트에서 **시퀀싱 데이터에 없던 서열**을 만들었고, 그중 일부가 목표 물질에 실제로 붙었습니다.
- 더 짧은(truncated) aptamer도 만들었습니다.
- 실험값을 BO에 넣어 더 좋은 서열을 찾는 흐름을 보였습니다.

### 실무에서 알아야 할 점

| 항목 | 내용 |
|---|---|
| 원본 코드 | [hmdlab/raptgen](https://github.com/hmdlab/raptgen), 마지막 commit 2022-12-17. 이 저장소는 `c4986ca9fa439b9389916c05829da4ff9c30d6f3`로 고정합니다. |
| 원본 환경 | Ubuntu 18.04, Python 3.7, PyTorch 1.5, CUDA 10.2. 지금은 그대로 빌드되지 않습니다. 이 저장소는 해시를 고정한 이미지(Python 3.12, PyTorch 2.14.1)를 제공합니다. [`raptgen/containers`](../../raptgen/containers/README.ko.md)를 보세요. |
| 사용 방식 | 명령어 스크립트 (`real.py` 학습, `encode.py`, `decode.py`) |
| DNA/RNA | 둘 다 입력할 수 있습니다 (A/C/G/T/U). |
| 출력 | 서열만 나옵니다. |
| Bayesian optimization | Batch 이미지에서는 제외했습니다 (오래된 GPyOpt 의존성). RaptGen-UI는 자체 BO를 갖고 있습니다. |

## RaptGen-UI가 하는 일

RaptGen-UI는 RaptGen 전체 과정을 브라우저에서 하게 해 줍니다. 논문: Nakano R. et al., *Bioinformatics Advances* 2025 ([doi:10.1093/bioadv/vbaf120](https://doi.org/10.1093/bioadv/vbaf120)). 소스: [hmdlab/RaptGen-UI](https://github.com/hmdlab/RaptGen-UI), 이 저장소에서는 `13cad83859dc9eac39383a00882c17c82a4cdb37`로 고정합니다.

| 화면 | 하는 일 | RaptGen 단계 |
|---|---|---|
| VAE Trainer | FASTQ/FASTA 올리기, primer 자동 추정, 학습 실행과 진행 보기 | 1 |
| GMM Trainer | 군집 수를 바꿔 가며 최적 군집 찾기 (BIC 기준) | 3 |
| Viewer | 지도 보기, 서열 encode, 좌표 골라 decode, 서열 로고, 2차 구조, 군집 다운로드 | 2, 4 |
| Bayesian Optimization | 실험값(예: 결합력)을 넣고 다음 후보 받기, 세션 저장 | 4 |

```text
 브라우저 -> frontend (Next.js, 포트 18042) -/api-> backend (FastAPI)
                                                        |
                                        +---------------+---------------+
                                        v               v               v
                                   PostgreSQL     Redis -> worker (Celery, 학습 실행)
                                   (모델)         (작업 줄)
```

`docker compose up` 한 번으로 컨테이너 5개가 뜹니다. 학습은 worker가 실행하고 화면은 진행만 보여 줍니다.

### RaptGen과 RaptGen-UI 비교

| | RaptGen (원본) | RaptGen-UI |
|---|---|---|
| 형태 | Python 명령어 스크립트 | 웹 화면과 API |
| 사용자 | 코드를 실행하는 사람 | wet-lab 연구자도 사용 가능 |
| 설치 | Python 환경을 직접 구성 | Docker Compose |
| 학습 코드 | 원본 | backend 안에 RaptGen 모델의 복사본을 포함 ([ui](ui.ko.md#ui-안의-raptgen-버전) 참고) |
| 결과 저장 | 파일 | PostgreSQL DB |
| Bayesian optimization | 스크립트 (GPyOpt, 오래됨) | 화면 + BoTorch (qEI) |
| 여러 작업 관리 | 직접 | 작업 목록, 정지, 재개, 삭제 |
| 자동화 / 파이프라인 연결 | 쉬움 (명령어) | API로 가능하지만 공식 자동화 도구는 없음 |
| 마지막 업데이트 | 2022-12 | 2026-01-31 (`13cad83`) |
| 로그인 | 해당 없음 | **없음.** 자기 PC 전용으로 설계됨 |

RaptGen-UI에는 로그인이 없으므로 이 저장소는 사설 EC2 호스트와 SSM 포트 포워딩으로만 접속하게 합니다. [ui](ui.ko.md)를 보세요. 선택 사항인 웹 접속은 [ui-web](ui-web.ko.md)에 있습니다.

## 한계

- 이 문서의 결과는 **소프트웨어가 동작한다는 것**만 보여 줍니다. 생성된 서열의 과학적 품질은 알려 주지 않습니다. 직접 가진 데이터와 실험으로 판단하세요.
- RaptGen-UI 문서는 RNA aptamer를 중심으로 쓰여 있습니다. DNA 데이터도 입력은 되지만, 2차 구조 표시 같은 일부 기능은 RNA 기준일 수 있습니다.
- RaptGen-UI의 학습 코드와 RaptGen Batch 이미지가 같은 결과를 내는지는 비교하지 않았습니다.

## 출처

| 출처 | 내용 |
|---|---|
| [hmdlab/raptgen](https://github.com/hmdlab/raptgen) | RaptGen 코드 (MIT) |
| [hmdlab/RaptGen-UI](https://github.com/hmdlab/RaptGen-UI) | RaptGen-UI 코드 (MIT) |
| Iwano N. et al., *Nat Comput Sci* 2022 ([논문](https://www.nature.com/articles/s43588-022-00249-6)) | RaptGen 논문 |
| Nakano R. et al., *Bioinformatics Advances* 5(1) vbaf120, 2025 ([doi](https://doi.org/10.1093/bioadv/vbaf120)) | RaptGen-UI 논문 |

다음: [AWS Batch에서 RaptGen 실행](batch.ko.md) | [목차](README.ko.md)
