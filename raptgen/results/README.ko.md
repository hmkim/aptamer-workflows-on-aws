[English](README.md) | [한국어](README.ko.md)

# 결과

숫자의 설명은 [CPU vs GPU 벤치마크](../../docs/raptgen/benchmark.ko.md)와 [RaptGen-UI 가이드](../../docs/raptgen/ui.ko.md)에 있습니다.

공개 샘플 데이터만 사용했습니다 (RaptGen 논문 dataset A `A_4R.fastq` 80,864 reads, RaptGen-UI에 포함된 RAPT1). job id, 계정 id, 이미지 digest는 기록하지 않았습니다.

## `benchmark/`

`raptgen-bench` 출력입니다. 실행마다 5 epoch 고정, 조기 종료 끔, `scripts/real.py`는 수정하지 않았습니다. 이벤트마다 JSON 한 줄입니다. 시간만 기록하며 loss 값은 과학적 주장을 담지 않습니다.

| 파일 | 호스트 | 장치 |
|---|---|---|
| `g5.xlarge-a10g-vs-cpu.jsonl` | AWS Batch `g5.xlarge` (A10G, 4 vCPU AMD EPYC 7R32), torch 2.14.1+cu126 | CUDA와 CPU, 같은 인스턴스 |
| `m7i.2xlarge-cpu.jsonl` | EC2 `m7i.2xlarge` (8 vCPU Xeon 8488C), torch 2.14.1+cu126 이미지, CPU만 | CPU |

| 고유 서열 수 (min-count) | A10G s/epoch | g5 CPU s/epoch | m7i.2xlarge CPU s/epoch |
|---|---|---|---|
| 3,043 (2) | 14.1 | 32.6 | 17.5 |
| 38,513 (1) | 144.3 | 275.4 | 187.6 |

이 작업에서 GPU는 같은 g5.xlarge의 4 vCPU CPU보다 약 2.3배, 8 vCPU m7i.2xlarge보다 약 1.3배 빠릅니다. 칸마다 1회 실행이며 통계적 벤치마크가 아닙니다.

## `ui/`

RaptGen-UI API end-to-end 테스트(`../ui/tests/e2e_api.py`)의 로그: `e2e-api-10ep-part1.log`(클라이언트가 중단된 실행), `e2e-api-resumed-10ep.log`(이어서 실행, GMM과 Bayesian optimization 포함, `ALL: PASS`로 끝남), `vae-worker-epoch-log.log`(worker epoch). job UUID는 `<uuid>`로 바꿨습니다. 화면 캡처는 `docs/raptgen/images/`에 있습니다.
