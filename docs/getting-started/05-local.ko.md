[English](05-local.md) | [한국어](05-local.ko.md)

# 로컬 실행과 EC2 기준 실행

먼저 머신 한 대에서 워크플로를 실행하세요. 그 결과가 AWS Batch, Nextflow, HealthOmics 실행과 비교할 기준이 됩니다. 로컬 Docker 실행에는 AWS 리소스가 필요 없습니다.

## 빠른 시작: Docker에서 로컬 Bash 실행

저장소를 clone하고 들어갑니다.

```bash
git clone 'https://github.com/<GITHUB_ORGANIZATION>/aptamer-workflows-on-aws.git'
cd aptamer-workflows-on-aws
```

공개 아카이브에서 D1을 내려받고 모든 파일을 manifest 체크섬으로 검증합니다.

```bash
bash data/fetch_dra009383.sh data/dra009383_manifest.tsv inputs/DRA009383
```

`inputs/DRA009383/` 아래에 `R<round>_DRR<number>.fastq.gz` 파일 아홉 개가 보여야 합니다.

이미지를 빌드하고 출력 디렉터리를 준비합니다.

```bash
docker build --tag aptamer-workflow:local .
mkdir -p outputs/bash-d1
```

공개된 D1 프라이머 설정을 불러옵니다. 다른 데이터셋에 이 값을 쓰기 전에 연결된 논문을 확인하세요.

```bash
source data/dra009383.env.example
```

Bash 파이프라인 전체를 실행합니다. 입력 마운트는 읽기 전용이고 출력 마운트는 쓰기 가능합니다.

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --volume "$PWD/inputs/DRA009383:/work/inputs:ro" \
  --volume "$PWD/outputs/bash-d1:/work/outputs" \
  aptamer-workflow:local \
  run_pipeline.sh \
  /work/inputs \
  /work/outputs \
  "$FRONT_PRIMER" \
  "$BACK_PRIMER" \
  100 \
  'R*_*.fastq.gz' \
  '^R([0-9]+)_'
```

순위가 매겨진 후보를 보고, 생성된 체크섬을 검증합니다.

```bash
column -ts $'\t' outputs/bash-d1/enrich/top_candidates.tsv | sed -n '1,11p'
cd outputs/bash-d1
sha256sum --check checksums.sha256
cd ../..
```

헤더 행과 최대 열 개의 순위 서열, 그리고 체크섬 줄마다 `OK`가 보여야 합니다.

명령이 성공했다는 것은 파일이 설정대로 처리되었다는 뜻일 뿐, 프라이머 선택이나 과학적 결론이 맞다는 뜻은 아닙니다.

## 기존 EC2 인스턴스에서 Bash 실행

Amazon EC2는 가상 머신을 제공합니다. `ec2/run_baseline.sh` 도우미는 기존 private 인스턴스, 로컬 POSIX 작업 스토리지, private Amazon ECR 이미지, private S3 입력과 출력을 씁니다. **Amazon ECR**은 private 컨테이너 이미지 저장소입니다. 이 도우미는 인스턴스를 만들거나, 네트워크 포트를 열거나, security group을 바꾸지 않습니다. [ec2/README.ko.md](../../ec2/README.ko.md)를 보세요.

EC2 도우미는 S3 객체 이름이 `R<number>_<name>.fastq.gz` 형식이길 기대합니다. 내려받은 D1 이름 그대로 업로드합니다.

```bash
export AWS_REGION='<AWS_REGION>'
export INPUT_BUCKET='<PRIVATE_INPUT_BUCKET>'
export INPUT_PREFIX='<INPUT_PREFIX>'

for SOURCE_PATH in inputs/DRA009383/R*_*.fastq.gz; do
  SOURCE_NAME=$(basename "$SOURCE_PATH")
  aws s3 cp \
    "$SOURCE_PATH" \
    "s3://$INPUT_BUCKET/$INPUT_PREFIX/$SOURCE_NAME" \
    --region "$AWS_REGION" \
    --only-show-errors
done
```

EC2 인스턴스에서 저장소 루트로 가서 실행합니다.

```bash
export AWS_REGION='<AWS_REGION>'
export INPUT_URI='s3://<PRIVATE_INPUT_BUCKET>/<INPUT_PREFIX>/'
export OUTPUT_URI='s3://<PRIVATE_OUTPUT_BUCKET>/<OUTPUT_PREFIX>/'
export PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>'
export FRONT_PRIMER='<FRONT_PRIMER_DNA>'
export BACK_PRIMER='<BACK_PRIMER_DNA>'
export RUN_ID='<UNIQUE_RUN_ID>'
export WORK_ROOT="$HOME/aptamer-runs"

bash ec2/run_baseline.sh
```

private subnet, 인바운드 규칙 없는 security group, 암호화된 스토리지를 쓰고, 운영 방식에 맞는다면 SSH 대신 AWS Systems Manager Session Manager를 쓰세요. 인스턴스 역할에는 필요한 S3 prefix와 ECR 리포지토리 권한만 주세요.

## 다음 단계

- AWS 경로를 시작하기 전에 [사전 준비](00-prerequisites.ko.md)
- 이 기준 결과를 다른 실행과 비교하려면 [검증 가이드](../validation.ko.md)
