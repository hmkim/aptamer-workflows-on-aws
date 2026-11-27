[English](benchmark.md) | [한국어](benchmark.ko.md)

# RaptGen: CPU vs GPU 벤치마크

이 문서는 RaptGen 학습 속도를 GPU와 CPU에서 한 번 측정한 결과, 숫자의 의미, 그리고 어디까지 믿을 수 있는지를 설명합니다. 직접 다시 측정하려면 [AWS Batch에서 RaptGen 실행](batch.ko.md#4단계-cpu-vs-gpu-벤치마크-실행-선택)을 보세요.

## 무엇을 측정했나

- 원본 RaptGen 학습 스크립트 `scripts/real.py`를 **고치지 않고** 같은 데이터로 CPU와 GPU에서 실행했습니다.
- 데이터: RaptGen 논문 dataset A (`data/real/A_4R.fastq`, 80,864 reads, 공개). [ui](ui.ko.md)에서 쓰는 RAPT1 샘플과 같은 파일입니다.
- 조건: 5 epoch 고정, 조기 종료 끔, `--reg-epochs 1`, batch 512 (원본 기본값).
- 소프트웨어: [`raptgen/containers`](../../raptgen/containers/README.ko.md)의 이미지. Python 3.12, PyTorch 2.14.1 (CUDA 12.6 wheel). CPU 이미지와 GPU 이미지는 소스와 패치가 같습니다.
- 원본 데이터: [`raptgen/results/benchmark/`](../../raptgen/results/README.ko.md), 이벤트마다 JSON 한 줄.

| 실행 | 장소 | 하드웨어 |
|---|---|---|
| GPU와 CPU | AWS Batch, `g5.xlarge` | NVIDIA A10G (24 GB), 4 vCPU AMD EPYC 7R32. PyTorch가 CPU 스레드 2개 사용 |
| CPU | EC2 `m7i.2xlarge`, 네트워크 없는 컨테이너 | 8 vCPU Intel Xeon 8488C. PyTorch가 CPU 스레드 4개 사용 |

## 결과

epoch 1회당 초입니다. 작을수록 빠릅니다.

| 하드웨어 | 장치 | 고유 서열 3,043개 (min-count 2) | 고유 서열 38,513개 (min-count 1) |
|---|---|---|---|
| `g5.xlarge` | **GPU (A10G)** | **14.1** | **144.3** |
| `g5.xlarge` | CPU (스레드 2) | 32.6 | 275.4 |
| `m7i.2xlarge` | CPU (스레드 4) | 17.5 | 187.6 |

| 비교 | 3,043개 | 38,513개 |
|---|---|---|
| GPU vs 같은 `g5.xlarge`의 CPU | 2.3배 빠름 | 1.9배 빠름 |
| GPU vs `m7i.2xlarge` CPU | 1.2배 빠름 | 1.3배 빠름 |

38,513개 서열에서 세 실행의 마지막 test loss는 비슷합니다 (GPU 40.72, g5 CPU 40.82, m7i 40.91). 세 실행이 같은 계산을 했다는 뜻입니다. 서열 품질을 판단한 것은 아닙니다.

## GPU 이득이 작은 이유

RaptGen의 pHMM loss 계산은 서열 위치를 **중첩된 Python 반복문**으로 한 칸씩 돕니다. 무작위 구간이 30 nt이면 위치 31번, motif 상태 31번을 도는 구조입니다 (원본 `raptgen/models.py` 156-157행). 그래서 batch마다 작은 GPU 호출이 약 961번 순서대로 일어납니다.

```text
profile_hmm_loss
  for i in range(random_len + 1):        # 30 nt이면 31번
      for j in range(motif_len + 1):     # 31번  -> batch마다 작은 계산 약 961번
```

GPU는 큰 계산을 한 번에 할 때 빠릅니다. 작은 호출을 하나씩 순서대로 부르면 대기 시간이 쌓입니다. 그래서 이 코드에서는 GPU가 좋은 CPU보다 조금만 빠릅니다.

## 의미

| 관찰 | 뜻 |
|---|---|
| 이 코드에서 GPU 1장은 8 vCPU급 좋은 CPU보다 1.2~1.3배 빠름 | GPU를 붙이면 학습이 며칠에서 몇 시간으로 준다고 기대하면 안 됩니다. 먼저 내 데이터로 측정하세요. |
| 인스턴스 가격이 다름 | 해당 Region의 EC2 요금 페이지를 확인하세요. 이득이 이 정도로 작으면 이 코드에서는 CPU 인스턴스가 더 싼 선택일 수 있습니다. |
| 학습 실행끼리는 서로 독립 (seed, 입력, `--multi` 반복이 다름) | **여러 job을 동시에 돌리는 것**이 실제 소요 시간을 가장 크게 줄입니다. AWS Batch는 job을 여러 개 제출하면 compute environment가 알아서 늘어나므로 잘 맞습니다. |

그래서 이 저장소는 같은 RaptGen job을 CPU만, CPU와 GPU, GPU만으로 고를 수 있게 합니다.

## 이 측정의 한계

- 5 epoch, 데이터 1개, **표의 칸마다 1회 실행**, 반복 없음. 통계적 벤치마크가 아닙니다.
- 원본 학습은 seed를 고정하지 않습니다. 시간은 단일 실행 값입니다.
- CPU 스레드 수가 인스턴스마다 다릅니다 (g5 2개, m7i 4개). PyTorch가 정한 기본값입니다. 더 큰 CPU 인스턴스(예: 16~32 vCPU)는 측정하지 않았습니다.
- GPU는 A10G 한 종류만 측정했습니다. L4, L40S, H100은 측정하지 않았습니다.
- 수렴할 때까지의 전체 학습 시간은 재지 않았고 epoch당 시간만 쟀습니다.
- 코드 최적화(`torch.compile`, batch 키우기, 반복문 재작성)는 하지 않았습니다. 더 빠른 loss 구현이 있으면 결과가 달라질 수 있습니다.
- 다른 Region, 인스턴스 세대, PyTorch 버전에서는 결과가 다를 수 있습니다.

다음: [사설 EC2에서 RaptGen-UI 실행](ui.ko.md) | [목차](README.ko.md)
