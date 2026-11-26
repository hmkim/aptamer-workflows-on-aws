[English](validation.md) | [한국어](validation.ko.md)

# 검증 가이드

검증은 서로 다른 두 질문에 답합니다.

1. 소프트웨어가 재현 가능하게 실행되고 예상한 파일 구조를 만들었는가?
2. 과학적 설정이 실험에 알맞은가?

소프트웨어 검사를 통과해도 두 번째 질문에는 답하지 못합니다. 프라이머 서열, 예상 압타머 길이, 트리밍 허용치, 라운드 라벨, 농축 해석은 자격 있는 과학자가 검토해야 합니다.

## 포함된 데이터의 범위

D1은 Ion Torrent로 시퀀싱한 공개 RNA SELEX 데이터입니다. 고객 DNA 데이터가 아니며 Illumina 데이터도 아닙니다. D1로 라운드 단위 QC, 트리밍, 카운트, RPM 정규화, 농축, RNA 폴딩을 시험할 수 있습니다. DNA 압타머 화학, Illumina 고유 오류, paired-end 처리, 비공개 실험 프로토콜은 검증할 수 없습니다.

분자 동역학 시뮬레이션은 제외되며 여기서 어떤 검증도 주장하지 않습니다.

## 1. 저장소 정적 검사

저장소 루트에서 다음 명령을 실행하세요.

```bash
python3 -m unittest discover --start-directory tests --pattern 'test_*.py' --verbose
bash -n pipeline/run_pipeline.sh pipeline/s1_qc.sh pipeline/s2_trim.sh pipeline/s3_count.sh pipeline/s5_fold.sh ec2/run_baseline.sh nextflow/run_batch.sh healthomics/orchestrate.sh data/fetch_dra009383.sh
python3 -m py_compile pipeline/enrich.py tests/test_enrich.py
python3 -m json.tool nextflow/nextflow_schema.json >/dev/null
python3 -m json.tool healthomics/parameter-template.json >/dev/null
python3 -m json.tool healthomics/run-parameters.example.json >/dev/null
```

Nextflow가 설치되어 있으면 profile마다 파싱도 해 보세요.

```bash
nextflow run nextflow/main.nf --help
nextflow config nextflow/nextflow.config -profile local >/dev/null
nextflow config nextflow/nextflow.config -profile batch >/dev/null
nextflow config nextflow/nextflow.config -profile batch_mountpoint >/dev/null
nextflow config nextflow/nextflow.config -profile healthomics >/dev/null
```

인프라 템플릿과 스크립트를 검사합니다. AWS를 호출하지 않습니다.

```bash
bash -n scripts/*.sh scripts/lib/common.sh healthomics/vpc/omics-vpc-configuration.sh
bash batch/validate.sh
```

`batch/validate.sh`는 `batch/`의 Bash 문법과 CloudFormation YAML을 검사하고, 설치되어 있으면 `cfn-lint`와 ShellCheck를 실행합니다. 템플릿에 인바운드 네트워크 규칙이나 퍼블릭 주소 플래그가 있거나, EC2 인스턴스 메타데이터 hop limit, S3 Block Public Access, 읽기 전용 Mountpoint 설정이 빠져 있으면 실패합니다. `batch/` 어디든 고정된 계정 ID나 내부 URL이 있어도 실패합니다. 단위 테스트는 모든 문서에 한국어 짝 문서, 언어 전환 줄, 동작하는 상대 링크가 있는지도 확인합니다.

대상 테스트 계정의 AWS CLI 자격 증명이 설정되어 있으면, 리소스를 만들지 않고 CloudFormation에게 HealthOmics 템플릿을 파싱하게 할 수 있습니다.

```bash
aws cloudformation validate-template \
  --region '<AWS_REGION>' \
  --template-body 'file://healthomics/infrastructure.yaml' \
  >/dev/null
```

## 2. 공개 데이터 무결성

저장소 도우미로 D1을 내려받습니다.

```bash
bash data/fetch_dra009383.sh data/dra009383_manifest.tsv inputs/DRA009383
```

도우미는 HTTPS를 요구하고, 내려받은 파일마다 공개 manifest의 MD5 값과 대조합니다. 여기서 MD5는 아카이브가 그 값을 공개하기 때문에 다운로드 손상을 찾는 데 씁니다. 현대적인 암호학적 진위 보증으로 보면 안 됩니다.

파일 아홉 개가 있고 덜 받은 파일이 남지 않았는지 확인합니다.

```bash
test "$(find inputs/DRA009383 -maxdepth 1 -type f -name 'R*_*.fastq.gz' | wc -l)" -eq 9
test "$(find inputs/DRA009383 -maxdepth 1 -type f -name '*.part' | wc -l)" -eq 0
```

## 3. 기준 실행

먼저 [로컬 실행 가이드](getting-started/05-local.ko.md)의 Docker 명령을 실행하세요. 파라미터를 검토한 뒤에만 그 출력을 기준으로 삼으세요.

필수 파일을 확인합니다.

```bash
test -s outputs/bash-d1/qc/stats.tsv
test -s outputs/bash-d1/enrich/top_candidates.tsv
test -s outputs/bash-d1/enrich/unique_ratio.tsv
test -s outputs/bash-d1/fold/top_candidates.fold
test -s outputs/bash-d1/checksums.sha256
```

출력 디렉터리 안에서 모든 체크섬을 검증합니다.

```bash
cd outputs/bash-d1
sha256sum --check checksums.sha256
cd ../..
```

트리밍 후 남은 행은 개수만 세지 말고 내용을 검토하세요. 출력이 비었거나 예상보다 작으면 프라이머 방향, 오류 허용치, 길이 제한이 잘못됐을 수 있습니다.

## 4. 플랫폼 간 비교

비교하는 모든 실행에 같은 값을 쓰세요.

- 정확한 입력 객체 버전 또는 체크섬
- 바뀔 수 있는 태그가 아닌 컨테이너 이미지 digest
- 앞쪽과 뒤쪽 프라이머
- 트리밍 오류율, overlap, 길이 제한
- pseudocount와 상위 후보 개수
- 워크플로 리비전

**pseudocount**는 앞 라운드에 없던 서열 때문에 0으로 나누는 일을 막으려고 더하는 작은 값입니다. 이 값을 바꾸면 보고되는 fold enrichment가 바뀝니다.

결과마다 별도 디렉터리로 내려받습니다.

```bash
export AWS_REGION='<AWS_REGION>'
aws s3 sync 's3://<PRIVATE_OUTPUT_BUCKET>/<BASH_OUTPUT_PREFIX>/' validation/bash --region "$AWS_REGION" --only-show-errors
aws s3 sync 's3://<PRIVATE_OUTPUT_BUCKET>/<BATCH_OUTPUT_PREFIX>/' validation/batch --region "$AWS_REGION" --only-show-errors
aws s3 sync 's3://<PRIVATE_OUTPUT_BUCKET>/<NEXTFLOW_OUTPUT_PREFIX>/' validation/nextflow --region "$AWS_REGION" --only-show-errors
aws s3 sync 's3://<PRIVATE_OUTPUT_BUCKET>/<HEALTHOMICS_OUTPUT_PREFIX>/' validation/healthomics --region "$AWS_REGION" --only-show-errors
```

모든 실행 방식은 순위 파일 이름을 `top_candidates.tsv`로 씁니다. 줄 끝을 맞추고 표를 비교합니다.

```bash
tr -d '\r' < validation/bash/enrich/top_candidates.tsv > validation/bash.top.tsv
tr -d '\r' < validation/batch/enrich/top_candidates.tsv > validation/batch.top.tsv
tr -d '\r' < validation/nextflow/enrich/top_candidates.tsv > validation/nextflow.top.tsv
tr -d '\r' < validation/healthomics/enrich/top_candidates.tsv > validation/healthomics.top.tsv

diff --unified validation/bash.top.tsv validation/batch.top.tsv
diff --unified validation/nextflow.top.tsv validation/healthomics.top.tsv
```

Bash와 Nextflow의 표 스키마가 같다고 가정하지 마세요. 구현이 일부러 다른 이름이나 숫자 형식을 쓴다면 같은 의미의 열끼리 비교하세요. 숫자 필드를 파싱한 뒤 합의한 허용 오차로 서열 순위, 카운트, RPM, 이전 라운드 대비 농축, 첫 라운드 대비 농축을 비교하면 쓸모 있는 합격 기준이 됩니다.

## 5. 구조 검사와 과학적 검사

| 검사 | 중요한 이유 | 증거 |
|---|---|---|
| 입력마다 라운드 라벨 하나 | 라운드가 중복되면 실험이 조용히 섞일 수 있습니다. | samplesheet와 입력 목록 |
| 라운드 두 개 이상 | 농축에는 비교가 필요합니다. | 워크플로 검증 |
| 트리밍 후 read가 0보다 많음 | 프라이머가 틀리면 유용한 read가 모두 사라질 수 있습니다. | Cutadapt 보고서와 카운트 표 |
| 라운드마다 RPM 합이 백만에 가까움 | 정규화 계산을 확인합니다. | 파싱한 카운트 표 |
| 동점 순서가 결정적임 | 반복 실행에서 같은 관측값의 순위가 일관되어야 합니다. | 단위 테스트와 반복 비교 |
| 데이터가 뒷받침할 때만 unique ratio 감소 | 선별로 라이브러리가 집중될 수 있지만 그 추세가 보장되지는 않습니다. | `unique_ratio.tsv`와 실험 맥락 |
| 폴딩 출력 개수가 선택한 후보 수와 같음 | 빠지거나 깨진 서열을 찾습니다. | 파싱한 순위 파일과 폴딩 파일 |

원하는 motif나 추세를 찾는 것을 성공 기준으로 삼지 마세요. 분석이 의사 결정을 뒷받침한다면 결과를 보기 전에 합격 기준을 먼저 정해 두세요.

## 6. Mountpoint 검증

정확한 컴퓨팅 이미지와 마운트 설정으로 테스트하세요. 마운트는 읽기 전용으로 두세요.

```bash
export MOUNT_PATH='/mnt/s3-input'
export LOCAL_TEST_DIRECTORY="$HOME/aptamer-mountpoint-test"
mkdir -p "$LOCAL_TEST_DIRECTORY"
mountpoint "$MOUNT_PATH"
find "$MOUNT_PATH" -maxdepth 1 -type f -name '*.fastq.gz' -print
seqkit stats --tabular "$MOUNT_PATH/<ONE_FASTQ_FILE_NAME>" > "$LOCAL_TEST_DIRECTORY/stats.tsv"
test -s "$LOCAL_TEST_DIRECTORY/stats.tsv"
```

그다음 출력, 현재 작업 디렉터리, `TMPDIR`를 로컬 POSIX 스토리지에 두고 실제 단계를 하나씩 실행하세요. 읽기 테스트만으로는 부족합니다. 중요한 객체로 쓰기 실패를 시험하지 말고, 파괴적인 호환성 실험에 프로덕션 prefix를 쓰지 마세요.

Nextflow Mountpoint 실행에서는 내용이 바뀌면 마운트된 객체 키를 바꾸거나 `RESUME=false`로 실행하세요. `NXF_WORK`가 마운트 경로가 아니라 `s3://` URI인지 확인하세요.

## 7. 운영 증거

실행마다 데이터 정책이 허용하는 증거만 보관하세요.

- 실행 상태와 단계 상태
- 입력 체크섬 또는 버전 식별자
- 이미지 digest와 워크플로 리비전
- 비밀 값을 뺀 파라미터
- 출력 체크섬 manifest
- 공유 전에 민감한 경로와 식별자를 지운 실패 사유

클라우드 계정 ID, 리소스 식별자, 비공개 객체 키, 실행 로그, 연구 결과를 공개 저장소에 커밋하지 마세요.

## 검증 기록

이 표는 새로 만든 스택 세트에서 [시작 가이드](getting-started/00-prerequisites.ko.md)를 처음부터 끝까지 따라 한 기록입니다. 행이 없는 경로는 검증되지 않은 것입니다.

> TODO(validation): 3차 작업에서 placeholder 행을 새 실행의 날짜, 리전, 스크립트 옵션, 결과로 바꿉니다.

| 경로 | 가이드 | 날짜 | 리전 | 결과 |
|---|---|---|---|---|
| Batch, CPU만 | [20-batch](getting-started/20-batch.ko.md#cpu만) | TODO(validation) | TODO(validation) | TODO(validation) |
| Batch, CPU + GPU | [20-batch](getting-started/20-batch.ko.md#cpu--gpu) | TODO(validation) | TODO(validation) | TODO(validation) |
| Batch, GPU만 | [20-batch](getting-started/20-batch.ko.md#gpu만) | TODO(validation) | TODO(validation) | TODO(validation) |
| HealthOmics, `RESTRICTED` | [30-healthomics](getting-started/30-healthomics.ko.md) | TODO(validation) | TODO(validation) | TODO(validation) |
| HealthOmics, VPC 모드 | [30-healthomics](getting-started/30-healthomics.ko.md#선택-vpc-네트워킹-모드-아직-검증되지-않음) | 아직 검증되지 않음 | — | — |
| 한 번에 둘 다 (`setup-all.sh`) | [40-both](getting-started/40-both.ko.md#한-번에-둘-다) | TODO(validation) | TODO(validation) | TODO(validation) |
| 정리 | [90-cleanup](getting-started/90-cleanup.ko.md) | TODO(validation) | TODO(validation) | TODO(validation) |

## 합격 체크리스트

- [ ] 정적 검사를 통과한다.
- [ ] 공개 다운로드가 공개된 체크섬과 일치한다.
- [ ] 프라이머와 길이 설정을 과학적으로 검토했다.
- [ ] 모든 실행이 같은 불변 입력과 이미지 digest를 쓴다.
- [ ] 필수 파일이 비어 있지 않다.
- [ ] 체크섬 manifest가 검증된다.
- [ ] 같은 의미의 표가 문서화된 숫자 허용 오차 안에서 일치한다.
- [ ] 사용한 모든 도구 버전과 접근 패턴으로 Mountpoint 동작을 테스트했다.
- [ ] 보안 통제가 private이고 최소 권한으로 유지된다.
- [ ] 정리 대상을 미리 보고 따로 승인받았다.
