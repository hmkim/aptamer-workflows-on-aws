[English](README.md) | [한국어](README.ko.md)

# RaptGen 컨테이너 이미지

빌드, push, 사용 방법: [AWS Batch에서 RaptGen 실행](../../docs/raptgen/batch.ko.md).

| | `cpu/` | `gpu/` |
|---|---|---|
| ECR 저장소 | `RaptgenCpuRepositoryUri` | `RaptgenGpuRepositoryUri` |
| Base | `python:3.12.16-slim-trixie` (digest 고정) | 동일 |
| torch | `2.14.1+cpu` (sha256 고정 wheel) | `2.14.1+cu126` (sha256 고정) + `requirements-cuda.txt`의 CUDA runtime wheel |
| Python 의존성 | `requirements.lock` + `requirements-s3.lock` (`--require-hashes`) | 동일, 추가로 `requirements-cuda.txt` |
| GPU driver | 없음 | 호스트 NVIDIA driver 560 이상 (A10G `g5`, L4 `g6`, L40S `g6e`, H100 `p5`) |

원본 RaptGen `c4986ca9fa439b9389916c05829da4ff9c30d6f3`(MIT, `NOTICE` 참고)은 빌드할 때 받아서 `source-checksums.sha256`로 확인하고, 패치(`patches/`: np.int alias, float64 확률 정규화, Bayesian optimization 제외)를 적용한 뒤 `patched-checksums.sha256`로 다시 확인합니다. 두 이미지 모두 UID 10001로 실행되고, 포트를 열지 않으며, daemon이 없습니다.

## 진입점

| 명령 | 용도 |
|---|---|
| `raptgen-job train` | 입력 준비(S3 또는 내장), 원본 `real.py` 실행 후 `encode.py` 실행, 모델, loss CSV, `embed_seq.csv`, `train.log`, `run.json`을 `RAPTGEN_OUTPUT`에 업로드 |
| `raptgen-bench` | dataset A로 `real.py`를 고정 epoch만큼 실행해 시간 측정 (`BENCH_DEVICES`, `BENCH_MINCOUNTS`, `BENCH_EPOCHS`, `BENCH_OUT`). 실행마다 JSON 한 줄 |
| `smoke-test` | 원본 샘플로 하는 네트워크 없는 계약 테스트 |
| `tool-version` | 버전을 JSON으로 출력 |

`raptgen-job` 옵션 (또는 `RAPTGEN_*` 환경 변수): `--input s3://...|builtin:A_4R|builtin:sample`, `--output s3://bucket/prefix/`, `--epochs`, `--threshold`, `--min-count`, `--device cpu|cuda`, `--run-id`, `--local-out DIR` (S3 대신 로컬로 결과 복사).

## 빌드와 테스트

```bash
raptgen/containers/build.sh cpu --no-push          # 로컬 빌드만
docker run --rm --network none --read-only --tmpfs /tmp --user 10001:10001 \
  -v "$PWD/smoke:/smoke-out" -e SMOKE_OUT=/smoke-out <image> /usr/local/bin/smoke-test
docker run --rm --gpus all -e BENCH_EPOCHS=5 <gpu-image> /usr/local/bin/raptgen-bench
raptgen/containers/build.sh cpu                    # 빌드, push, digest URI 출력
```

`build.sh`는 `<upstream-commit12>-<git-sha7>` 태그를 붙이고, ECR에 로그인하고, digest를 출력합니다. 그 digest URI를 `../batch/jobs.yaml`에 쓰세요.

## 남은 항목

- CUDA wheel은 정확한 버전 고정이지만 해시 고정은 아닙니다. 실제로 설치된 목록은 `/usr/share/doc/aptamer-raptgen/pip-freeze.txt`(GPU 이미지)에 기록되며, 이 목록에서 해시 lock을 만들 수 있습니다.
- `python-dateutil`은 botocore가 `<3`을 요구하므로 4.0.0이 아니라 2.9.0.post0(`six` 포함)입니다.
- Blackwell GPU(sm_120)는 CUDA 12.8 이상 torch 빌드가 필요합니다.
- 원본 패치에 내부 테스트 id("T05")를 언급하는 주석이 남아 있습니다. 바꾸면 패치된 파일의 checksum이 달라지므로 그대로 두었습니다.
