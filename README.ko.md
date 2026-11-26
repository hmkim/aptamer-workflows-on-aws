[English](README.md) | [한국어](README.ko.md)

# AWS에서 실행하는 압타머 워크플로

이 저장소는 압타머 시퀀싱 분석 하나를 단일 머신의 Bash 스크립트에서 AWS Batch, Nextflow, AWS HealthOmics로 옮기는 방법을 보여 줍니다. 또한 압타머 서열용 딥러닝 모델인 RaptGen을 AWS Batch에서 CPU 또는 GPU로 실행하는 방법도 다룹니다. 새로운 과학적 방법보다는 실행 방식과 스토리지 패턴에 초점을 둡니다.

이 프로젝트는 독립적인 교육용 프로젝트입니다. **AWS 공식 샘플이나 템플릿이 아니며**, 데이터, 보안 요구 사항, 할당량(quota), 운영 방식에 맞게 검토하지 않으면 프로덕션에 바로 쓸 수 없습니다.

## 새로 추가된 내용

- **RaptGen과 RaptGen-UI.** 컨테이너 이미지, AWS Batch job definition, CPU 대 GPU 벤치마크, 그리고 AWS Systems Manager 포트 포워딩으로만 접속하는 private EC2 호스트의 RaptGen-UI. [docs/raptgen](docs/raptgen/README.ko.md)을 보세요.
- **GPU는 선택 사항입니다.** Batch 템플릿 하나로 CPU만, CPU + GPU, GPU만 구성할 수 있습니다.
- **HealthOmics VPC 모드(선택, 아직 검증되지 않음).** 기본값은 그대로 `RESTRICTED` 네트워킹입니다.
- 경로별 **설치 스크립트**와 정리 스크립트가 `scripts/`에 있습니다.
- **한국어 가이드.** 모든 문서에 `.ko.md` 짝 문서가 있습니다.

## 경로 고르기

모든 경로는 [사전 준비](docs/getting-started/00-prerequisites.ko.md)에서 시작합니다. 각 가이드는 한 단계씩 복사해 붙여 넣을 수 있고, 단계마다 무엇이 보여야 하는지 알려 줍니다.

| 하고 싶은 것 | 가이드 | 주요 명령 |
|---|---|---|
| 먼저 내 컴퓨터에서 파이프라인 실행 | [로컬 실행과 EC2 기준 실행](docs/getting-started/05-local.ko.md) | `docker run ...` |
| AWS Batch, CPU만 | [Batch: CPU만](docs/getting-started/20-batch.ko.md#cpu만) | `scripts/setup-batch.sh --cpu` |
| AWS Batch, CPU + GPU | [Batch: CPU + GPU](docs/getting-started/20-batch.ko.md#cpu--gpu) | `scripts/setup-batch.sh --cpu --gpu` |
| AWS Batch, GPU만 (RaptGen) | [Batch: GPU만](docs/getting-started/20-batch.ko.md#gpu만) | `scripts/setup-batch.sh --gpu` |
| Batch 큐에서 Nextflow 실행 | [AWS Batch에서 Nextflow](docs/getting-started/25-nextflow.ko.md) | `nextflow/run_batch.sh` |
| AWS HealthOmics만 (`RESTRICTED`) | [HealthOmics](docs/getting-started/30-healthomics.ko.md) | `scripts/setup-healthomics.sh` |
| HealthOmics VPC 모드 (아직 검증되지 않음) | [HealthOmics: VPC 모드](docs/getting-started/30-healthomics.ko.md#선택-vpc-네트워킹-모드-아직-검증되지-않음) | `scripts/setup-healthomics.sh --vpc` |
| Batch와 HealthOmics를 한 번에 | [한 번에 둘 다](docs/getting-started/40-both.ko.md#한-번에-둘-다) | `scripts/setup-all.sh` |
| 하나는 지금, 다른 하나는 나중에 | [차례로 하나씩](docs/getting-started/40-both.ko.md#차례로-하나씩) | 두 스크립트, 같은 `--prefix` |
| Batch에서 RaptGen 학습과 벤치마크 | [Batch에서 RaptGen](docs/raptgen/batch.ko.md) | `raptgen/batch/submit-train.sh` |
| private EC2 호스트의 RaptGen-UI | [RaptGen-UI](docs/raptgen/ui.ko.md) | `raptgen/ui/connect.sh` |
| 전부 삭제 | [정리](docs/getting-started/90-cleanup.ko.md) | `scripts/cleanup.sh` |

[공유 네트워크 가이드](docs/getting-started/10-network.ko.md)는 Batch, RaptGen-UI 호스트, HealthOmics VPC 모드가 함께 쓰는 private VPC를 설명합니다. 필요하면 설치 스크립트가 자동으로 만듭니다.

## 워크플로가 하는 일

**압타머(aptamer)**는 특정 표적에 결합하도록 선별된 짧은 DNA 또는 RNA 서열입니다. **SELEX**(systematic evolution of ligands by exponential enrichment)는 선별을 여러 라운드 반복해 유용한 서열이 점점 많아지게 하는 실험 방법입니다.

```text
FASTQ reads from each SELEX round
              |
              v
     QC -> trim -> count and RPM -> enrichment -> fold
```

| 단계 | 도구 | 쉽게 말하면 | 주요 출력 |
|---|---|---|---|
| 품질 관리(QC) | SeqKit | 시퀀싱 read가 몇 개 들어왔는지, 길이가 그럴듯한지 확인합니다. | `qc/stats.tsv` |
| 프라이머 트리밍 | Cutadapt | 실험에서 붙인 고정 프라이머 서열을 잘라 내고 가변 압타머 서열만 남깁니다. | `trimmed/` |
| 카운트와 RPM | SeqKit과 표준 Unix 도구 | 반복되는 서열을 셉니다. RPM(reads per million)은 전체 read 수가 다른 라운드끼리 비교할 수 있게 해 줍니다. | `counts/` |
| 농축(enrichment) | Python | 선별 라운드를 거치며 많아진 서열에 순위를 매깁니다. | `enrich/top_candidates.tsv` |
| RNA 폴딩 | ViennaRNA RNAfold | 2차원 염기쌍 구조와 자유 에너지를 예측합니다. | `fold/` |

분자 동역학(MD) 시뮬레이션은 포함하지 않습니다. MD는 수치 물리 계산(주로 GPU 사용)으로 3차원 분자 움직임을 모델링합니다. 이 워크플로는 RNA 2차 구조 예측에서 끝나며, 결합 친화도, 생물학적 활성, 임상적 타당성을 주장하지 않습니다.

RaptGen은 별도의 선택 모듈입니다. SELEX 데이터셋에 있는 서열의 저차원 지도를 학습하고 새로운 후보 서열을 제안할 수 있습니다. [RaptGen 개념](docs/raptgen/concepts.ko.md)을 보세요.

## 예제에서 쓰는 데이터

**D1은 Ion Torrent로 시퀀싱한 공개 RNA SELEX 데이터입니다. 고객 DNA 데이터가 아니며 Illumina 데이터도 아닙니다.** 아홉 개 라운드는 공개 [DRA009383 아카이브 레코드](https://ddbj.nig.ac.jp/resource/sra-submission/DRA009383)로 식별됩니다. 데이터를 내려받거나 분석 결과를 공개하기 전에 아카이브 레코드, 연결된 논문, 데이터 이용 조건을 확인하세요.

저장소에는 공개 메타데이터와 체크섬 목록(manifest)만 들어 있습니다. 시퀀싱 read나 연구 결과는 저장하지 않습니다. [DATA_NOTICE.ko.md](DATA_NOTICE.ko.md)를 보세요.

이 실행 패턴은 라운드별 FASTQ 입력에도 적용할 수 있지만, 시퀀싱 플랫폼, DNA 압타머, paired-end read, 프라이머 배치, 라이브러리 길이가 다르면 과학적 검증이 필요하고 코드 수정이 필요할 수 있습니다.

## 실행 패턴 고르기

| 패턴 | 적합한 출발점 | 스토리지 동작 | 운영할 대상 |
|---|---|---|---|
| 워크스테이션 또는 EC2의 Bash | 작은 연구, 투명한 기준 결과 | 입력, 임시 파일, 출력이 로컬 POSIX 파일 시스템을 씁니다. POSIX는 이름 바꾸기, 잠금, 제자리 수정 같은 일반적인 Linux 파일 동작을 말합니다. | 머신 한 대 |
| AWS Batch copy-in | 기존 스크립트를 거의 그대로 관리형 job으로 옮기기 | job이 S3 입력을 로컬 작업 스토리지로 복사하고, Bash를 실행하고, 출력을 업로드합니다. | job definition, 큐, compute environment |
| `dependsOn`을 쓰는 AWS Batch | 단계 경계를 드러내고 라운드를 병렬화 | 각 단계가 private S3 prefix로 중간 결과를 주고받습니다. | job 그래프와 중간 객체 |
| AWS Batch에서 Nextflow | 워크플로 엔진이 작업 job을 만들고 추적 | Nextflow가 S3 객체를 작업 스토리지로 staging하고 work 디렉터리를 S3에 둡니다. | Nextflow head 프로세스와 Batch |
| Mountpoint를 쓰는 Nextflow | 호환되는 읽기 위주 단계에서 입력 전체 복사 피하기 | 작업은 마운트된 S3 객체를 읽고, 임시 파일과 출력은 로컬 POSIX 스토리지에 둡니다. | Mountpoint가 설정된 Batch 호스트와 Nextflow |
| AWS HealthOmics | 관리형 생물정보학 워크플로 서비스 사용 | HealthOmics가 private S3 입력을 staging하고 작업 실행 스토리지를 관리합니다. | private workflow, run role, 이미지, S3 데이터 |

패턴을 고르기 전에 [아키텍처 가이드](docs/architecture.ko.md)와 [스토리지 가이드](docs/storage.ko.md)를 읽어 보세요.

## 저장소 구조

```text
.
├── batch/               AWS Batch templates (network, CPU and/or GPU compute), submission and job scripts
├── data/                Public D1 manifest and checksum-verifying downloader
├── docs/
│   ├── getting-started/ Step-by-step guides for each path (English and Korean)
│   ├── raptgen/         RaptGen and RaptGen-UI guides, benchmark, screenshots
│   ├── architecture.md  Execution models and data flow
│   ├── storage.md       S3, local storage, staging, Mountpoint, and per-run cleanup
│   └── validation.md    Static, functional, and cross-run validation
├── ec2/                 Helper for a baseline run on an existing EC2 instance
├── healthomics/         Private HealthOmics workflow packaging and infrastructure; vpc/ for VPC mode
├── nextflow/            One DSL2 workflow with local, Batch, Mountpoint, and HealthOmics profiles
├── pipeline/            Bash and Python implementation of the scientific stages
├── raptgen/             RaptGen images, Batch jobs, RaptGen-UI host, optional web access, results
├── scripts/             setup-network, setup-batch, setup-healthomics, setup-all, cleanup
├── tests/               Unit, contract, template, script, and documentation tests
├── Dockerfile           Pipeline container image with the tools pinned in environment.yml
└── buildspec.yml        AWS CodeBuild steps that build the image and push it to private Amazon ECR
```

## 사전 준비

[docs/getting-started/00-prerequisites.ko.md](docs/getting-started/00-prerequisites.ko.md)로 옮겼습니다. 도구, 자격 증명, 리전, 할당량(GPU 할당량 포함), 비용이 드는 부분을 다룹니다.

## 빠른 시작: Docker에서 로컬 Bash 실행

[docs/getting-started/05-local.ko.md](docs/getting-started/05-local.ko.md#빠른-시작-docker에서-로컬-bash-실행)로 옮겼습니다.

## 기존 EC2 인스턴스에서 Bash 실행

[docs/getting-started/05-local.ko.md](docs/getting-started/05-local.ko.md#기존-ec2-인스턴스에서-bash-실행)로 옮겼습니다.

## `batch/`의 AWS Batch 구현

[docs/getting-started/20-batch.ko.md](docs/getting-started/20-batch.ko.md#참고-batch-폴더-구성)로 옮겼습니다. 기술 참고 자료: [batch/README.ko.md](batch/README.ko.md).

## AWS Batch 패턴 1: 복사해 들여오기, 실행, 복사해 내보내기

[docs/getting-started/20-batch.ko.md](docs/getting-started/20-batch.ko.md#패턴-1-복사해-들여오기-실행-복사해-내보내기)로 옮겼습니다.

## AWS Batch 패턴 2: `dependsOn`으로 단계별 job 실행

[docs/getting-started/20-batch.ko.md](docs/getting-started/20-batch.ko.md#패턴-2-dependson으로-단계별-job-실행)로 옮겼습니다.

## AWS Batch에서 Nextflow 실행

[docs/getting-started/25-nextflow.ko.md](docs/getting-started/25-nextflow.ko.md#aws-batch에서-nextflow-실행)로 옮겼습니다.

## 읽기 전용 Mountpoint 입력을 쓰는 Nextflow

[docs/getting-started/25-nextflow.ko.md](docs/getting-started/25-nextflow.ko.md#읽기-전용-mountpoint-입력을-쓰는-nextflow)로 옮겼습니다.

## AWS HealthOmics

[docs/getting-started/30-healthomics.ko.md](docs/getting-started/30-healthomics.ko.md)로 옮겼습니다. 기술 참고 자료: [healthomics/README.ko.md](healthomics/README.ko.md), VPC 모드는 [healthomics/vpc/README.ko.md](healthomics/vpc/README.ko.md).

## 플랫폼을 비교하기 전에 검증하기

`batch/validate.sh`의 인프라 검사를 포함해 [docs/validation.ko.md](docs/validation.ko.md)로 옮겼습니다.

## 보안 기본값

- S3 Block Public Access를 켜 두고 ACL 기반 소유권을 끄세요.
- S3 객체와 컴퓨팅 볼륨을 암호화하세요. 키 정책과 교체를 직접 통제해야 하면 고객 관리형 KMS 키를 쓰세요.
- 변경 불가(immutable) 태그를 쓰는 private ECR 리포지토리를 사용하고, 해석된 digest를 기록하고, 실행에는 digest로 고정한 이미지를 쓰세요.
- 컴퓨팅은 private subnet에 두세요. 이 워크플로를 운영하는 데 퍼블릭 IP 주소, 인바운드 규칙, SSH는 필요 없습니다.
- RaptGen-UI는 AWS Systems Manager 포트 포워딩으로만 접속하세요. 선택 사항인 CloudFront + Amazon Cognito 웹 접속은 로그인 뒤에 UI를 인터넷에 노출합니다. full 역할 사용자는 누구나 모든 모델을 삭제할 수 있습니다. [웹 접속 가이드](docs/raptgen/ui-web.ko.md)의 경고를 읽고, origin을 열기 전에 로그인 관문을 검증하세요.
- 프로비저닝, Nextflow head 프로세스, Batch job, EC2 호스트, HealthOmics 실행에 각각 최소 권한 역할을 따로 쓰세요.
- S3 권한은 필요한 입력, 작업, 출력 범위로 제한하세요. 포함된 Batch job role은 스택 단위로 `runs/` 전체에 접근하므로, IAM으로 실행끼리 격리해야 한다면 스택을 나누거나 실행별 역할을 쓰세요. 입력용 역할에는 삭제 권한을 주지 마세요.
- 검토된 VPC 연결 필요성이 없다면 HealthOmics는 `RESTRICTED` 네트워킹으로 두세요.
- 공개 여부와 재배포 조건이 확인되지 않은 FASTQ 파일과 파생 서열은 민감 데이터로 취급하세요.
- 자격 증명, 계정 ID, 리소스 식별자, 비공개 데이터, 실행 로그를 커밋이나 이슈에 넣지 마세요.

신고 및 배포 지침은 [SECURITY.ko.md](SECURITY.ko.md)를 보세요.

## 정리

스택과 보존된 데이터는 [docs/getting-started/90-cleanup.ko.md](docs/getting-started/90-cleanup.ko.md), 개별 실행은 [스토리지 가이드](docs/storage.ko.md#정리)로 옮겼습니다. 정리는 되돌릴 수 없습니다. 대상을 확인하고, 필요한 결과를 저장하고, 먼저 명시적인 승인을 받으세요.

## 알려진 제한 사항

- D1은 공개 RNA/Ion Torrent 데이터이므로 DNA/Illumina 고유 동작을 검증하지 않습니다.
- 워크플로는 single-end FASTQ 파일과 라운드당 입력 파일 하나를 가정합니다.
- 프라이머 배치, 오류 허용치, 길이 필터는 연구마다 다릅니다.
- RPM은 라이브러리 크기를 정규화하지만 모든 실험 편향이나 증폭 편향을 없애지는 않습니다.
- 농축 분석은 관측된 서열에 순위를 매길 뿐, 결합을 증명하지 않습니다.
- RNAfold는 2차 구조를 예측합니다. 실험적 구조 측정이나 친화도 측정을 대신하지 않습니다.
- MD 시뮬레이션은 이 저장소 범위 밖입니다.
- Mountpoint 호환성은 실제 파일 연산에 따라 달라집니다. 사용하기 전에 도구 버전과 접근 패턴마다 테스트하세요.
- 문자열로 전달된 Nextflow Mountpoint 입력은 캐시 변경 감지를 약하게 만듭니다.
- AWS Batch와 HealthOmics에는 AWS 리소스, 할당량, 권한, 컨테이너 이미지가 필요합니다. GPU 컴퓨팅에는 G 계열 vCPU 할당량이 필요합니다.
- HealthOmics VPC 모드는 이 저장소에서 아직 검증되지 않았습니다.
- RaptGen 학습은 업스트림에서 seed를 고정하지 않으므로 학습된 모델이 비트 단위로 재현되지 않습니다.
- 제공된 인프라는 검토를 위한 출발점이며, 완전한 프로덕션 환경이 아닙니다.

## 라이선스

Apache License 2.0으로 배포합니다. [LICENSE](LICENSE)를 보세요. RaptGen(MIT)과 RaptGen-UI는 각자의 라이선스를 따르는 별도의 업스트림 프로젝트입니다. `raptgen/containers/`의 `NOTICE` 파일과 업스트림 리포지토리를 확인하세요.
