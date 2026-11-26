# RaptGen-UI on a private EC2 host

RaptGen-UI (Next.js frontend, FastAPI backend, Celery worker, PostgreSQL, Redis, started by upstream
`compose.yml`) runs on one private EC2 host. The host has no public IP, no inbound rule and no SSH key.
You reach it through an SSM port forward.

| File | Purpose |
|---|---|
| `ec2.yaml` | host: AL2023, `m7i.2xlarge` default, encrypted gp3 200 GiB, IMDSv2 required (hop limit 1), SSM role, egress TCP 443 only. Needs `CAPABILITY_IAM`. |
| `install.sh` | sends `install-host.sh` plus the patches through SSM Run Command and waits (15-30 min first build) |
| `install-host.sh` | on the host: Docker Compose plugin (v2.40.3, sha256 checked), RaptGen-UI at the pinned commit, patches, `docker compose up -d --build` |
| `connect.sh` | `aws ssm start-session` port forward to `localhost:18042` |
| `tests/e2e_api.py` | API end-to-end test (Viewer, VAE training, GMM, Bayesian optimization) |
| `patches/` | unified diffs against RaptGen-UI `13cad83` |

## Patches

| Patch | Why |
|---|---|
| `0001-frontend-bookworm-base.patch` | `node:20.2-slim` (Debian bullseye) fails: its security repository is gone. Use `node:20-bookworm-slim`. |
| `0002-relative-api-base.patch` | upstream calls `http://localhost:18042/api` from the browser, which only works on the host itself. Use `/api`. |
| `0003-publish-on-bind-address.patch` | publish the frontend on `${UI_BIND_ADDR:-127.0.0.1}:18042` instead of all interfaces. Set the instance private IP for the CloudFront option. |
| `optional/0001-https-only-apt.patch` | HTTPS apt plus the host CA bundle, only for networks that allow TCP 443 alone (`install.sh --apt-https`). |

## Use

```bash
raptgen/ui/install.sh --instance-id <InstanceId>              # loopback only (default)
raptgen/ui/install.sh --instance-id <InstanceId> --bind-private-ip   # for ui-web
raptgen/ui/connect.sh --instance-id <InstanceId>              # add --remote-host <PrivateIp> if bound to it
# open http://localhost:18042
python3 raptgen/ui/tests/e2e_api.py --base-url http://localhost:18042 --fastq <local RAPT1_4R.fastq> --epochs 10
```

The test creates models `e2e-RAPT1-<N>ep` and `e2e-gmm`. The UI has no authentication and no per-user
data: anyone who can open the port can delete every model. Keep it on loopback or behind `ui-web`.
Backend and worker run on CPU (the UI image has no GPU path in this setup).
