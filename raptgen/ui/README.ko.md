[English](README.md) | [한국어](README.ko.md)

# 사설 EC2 호스트의 RaptGen-UI

단계별 가이드: [사설 EC2에서 RaptGen-UI 실행](../../docs/raptgen/ui.ko.md).

RaptGen-UI(Next.js frontend, FastAPI backend, Celery worker, PostgreSQL, Redis. 원본 `compose.yml`로 시작)는 사설 EC2 호스트 한 대에서 실행됩니다. 호스트에는 public IP, 인바운드 규칙, SSH 키가 없습니다. SSM 포트 포워딩으로 접속합니다.

| 파일 | 용도 |
|---|---|
| `ec2.yaml` | 호스트: AL2023, 기본 `m7i.2xlarge`, 암호화된 gp3 200 GiB, IMDSv2 필수(hop limit 1), SSM role, TCP 443 outbound만 허용. `CAPABILITY_IAM`이 필요합니다. |
| `install.sh` | `install-host.sh`와 패치를 SSM Run Command로 보내고 끝날 때까지 기다림 (첫 빌드 15~30분) |
| `install-host.sh` | 호스트에서 실행: cloud-init 완료 대기, Docker Compose plugin(v2.40.3)과 Docker Buildx plugin(v0.39.1), sha256 확인, 고정된 commit의 RaptGen-UI, 패치, `docker compose up -d --build` |
| `connect.sh` | `localhost:18042`로 가는 `aws ssm start-session` 포트 포워딩 |
| `tests/e2e_api.py` | API end-to-end 테스트 (Viewer, VAE 학습, GMM, Bayesian optimization) |
| `patches/` | RaptGen-UI `13cad83`에 대한 unified diff |

## 패치

| 패치 | 이유 |
|---|---|
| `0001-frontend-bookworm-base.patch` | `node:20.2-slim`(Debian bullseye)은 보안 저장소가 없어져 실패합니다. `node:20-bookworm-slim`을 씁니다. |
| `0002-relative-api-base.patch` | 원본은 브라우저에서 `http://localhost:18042/api`를 호출하는데 호스트 자신에서만 동작합니다. `/api`를 씁니다. |
| `0003-publish-on-bind-address.patch` | frontend를 모든 인터페이스가 아니라 `${UI_BIND_ADDR:-127.0.0.1}:18042`로 공개합니다. CloudFront 옵션에서는 인스턴스 private IP로 설정합니다. |
| `optional/0001-https-only-apt.patch` | HTTPS apt와 호스트 CA bundle. TCP 443만 허용하는 네트워크용. `ec2.yaml` 호스트가 그렇기 때문에 `install.sh`가 기본으로 적용합니다 (`--apt-http`로 건너뜀). |

## 사용

```bash
raptgen/ui/install.sh --instance-id <InstanceId>              # loopback만 (기본값)
raptgen/ui/install.sh --instance-id <InstanceId> --bind-private-ip   # ui-web용
raptgen/ui/connect.sh --instance-id <InstanceId>              # private IP로 bind했다면 --remote-host <PrivateIp> 추가
# http://localhost:18042 열기
python3 raptgen/ui/tests/e2e_api.py --base-url http://localhost:18042 --fastq <로컬 RAPT1_4R.fastq> --epochs 10
```

테스트는 모델 `e2e-RAPT1-<N>ep`, `e2e-gmm`을 만듭니다. UI에는 인증과 사용자별 데이터 구분이 없으므로 포트를 열 수 있는 누구나 모든 모델을 지울 수 있습니다. loopback에 두거나 `ui-web` 뒤에 두세요. backend와 worker는 CPU로 실행됩니다 (이 구성의 UI 이미지에는 GPU 경로가 없습니다).
