[English](README.md) | [한국어](README.ko.md)

# AWS Batch에서 RaptGen 실행

단계별 가이드: [AWS Batch에서 RaptGen 실행](../../docs/raptgen/batch.ko.md). 측정된 속도: [benchmark](../../docs/raptgen/benchmark.ko.md).

`jobs.yaml`은 이미지 파라미터가 설정된 것만 골라 최대 4개의 job definition을 만듭니다: `raptgen-train-cpu`, `raptgen-train-gpu`, `raptgen-bench-cpu`, `raptgen-bench-gpu` (`NamePrefix`로 prefix 변경). CPU만, CPU + GPU, GPU만 모두 이 템플릿을 씁니다. 컨테이너는 UID 10001, 읽기 전용 루트 파일 시스템, 2 GiB tmpfs `/tmp`로 실행되며, GPU job definition은 GPU 1개를 요청합니다. 로그는 batch 스택의 로그 그룹으로 갑니다.

| 스크립트 | 하는 일 |
|---|---|
| `submit-train.sh --device cpu\|gpu [--input ...] [--epochs N] [--min-count N]` | 장치에 맞는 큐를 고르고(그 큐가 꺼져 있으면 명확히 실패), run id와 `s3://<WorkBucketName>/raptgen/<run-id>/`를 정해 제출 |
| `submit-bench.sh --device cpu\|gpu\|both [--epochs N]` | 모든 큐를 먼저 확인한 뒤 제출. GPU job은 CUDA를 측정하고 같은 인스턴스의 CPU를 이어서 측정 |
| `status.sh <job-id>` / `--list` | 상태, 사유, 결과 위치, 끝난 벤치마크 job은 JSON 결과 줄 |

기본값: `--stack-prefix aptamer-workflows` (환경 변수 `STACK_PREFIX`), `--jobdef-prefix raptgen`. 학습 기본값: 내장 dataset A, 50 epoch, min-count 2 (고유 서열 3,043개). min-count 1(고유 서열 38,513개)은 epoch당 약 10배 오래 걸립니다 (`../results/benchmark` 참고). GPU 메모리 기본값 14 GiB는 `g5.xlarge`에 맞습니다. 다른 인스턴스는 `GpuMemoryMiB`를 바꾸세요.
