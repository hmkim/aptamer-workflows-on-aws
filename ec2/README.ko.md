[English](README.md) | [한국어](README.ko.md)

# EC2 baseline 도우미

`run_baseline.sh`는 이미 있는 EC2 인스턴스에서 공용 Nextflow `local` profile을 실행합니다. Nextflow work와 Docker task 디렉터리는 로컬 POSIX 스토리지를 쓰고, 최종 결과만 private S3로 업로드합니다. 인스턴스를 만들거나, 보안 그룹을 바꾸거나, listener를 시작하거나, 컨테이너 포트를 공개하지 않습니다.

## 호스트 요구 사항

- Nextflow 24.10 또는 25.x
- Docker
- AWS CLI v2
- 입력 파일, task work, 출력에 충분한 로컬 디스크
- 입력 S3 prefix 읽기, 출력 S3 prefix 쓰기, 선택한 private ECR 이미지 pull이 가능한 인스턴스 role

장기 AWS access key 대신 인스턴스 role을 사용하세요. role은 실행에 필요한 정확한 버킷 prefix와 ECR 저장소로만 제한하세요.

## 실행

```bash
AWS_REGION='<AWS_REGION>' \
INPUT_URI='s3://<INPUT_BUCKET>/<FASTQ_PREFIX>/' \
OUTPUT_URI='s3://<OUTPUT_BUCKET>/<BASELINE_OUTPUT_PREFIX>/' \
PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>' \
FRONT_PRIMER='<FRONT_PRIMER_DNA>' \
BACK_PRIMER='<BACK_PRIMER_DNA>' \
RUN_ID='<RUN_ID>' \
WORK_ROOT="$PWD/ec2-runs" \
./run_baseline.sh
```

`WORK_ROOT`는 일반 로컬 파일 시스템 경로입니다. Nextflow work에는 Mountpoint for Amazon S3가 제공하지 않는 POSIX 동작이 필요하므로 Mountpoint로 지정하지 마세요.

도우미는 `R<number>_<name>.fastq.gz` 형식의 입력 파일을 받습니다. 이미 있는 run 디렉터리를 덮어쓰지 않습니다. 최종 결과는 `OUTPUT_URI/RUN_ID/`에 업로드되고, work 파일은 확인이나 `-resume`을 위해 로컬에 남습니다.

## 로컬 검증

```bash
bash -n run_baseline.sh
```

## 용어

- **EC2 instance role:** access key를 파일에 저장하지 않고 가상 머신에 전달되는 임시 AWS 권한입니다.
- **ECR:** private AWS 컨테이너 이미지 저장소입니다.
- **POSIX storage:** Nextflow와 명령줄 도구가 기대하는 파일 동작을 갖춘 일반 로컬 파일 시스템입니다.
- **S3 prefix:** 데이터를 정리하고 권한을 제한하는 데 쓰는, object key의 앞부분(폴더처럼 보이는 부분)입니다.
