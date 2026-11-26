#!/usr/bin/env bash
# Install RaptGen-UI on the private EC2 host through SSM Run Command.
#
#   raptgen/ui/install.sh --instance-id i-... [--bind-private-ip] [--apt-https]
#
#   --bind-private-ip  publish the UI on the instance private IP instead of
#                      127.0.0.1 (needed for raptgen/ui-web; read its README first)
#   --apt-https        also apply the HTTPS-only apt patch (only TCP 443 egress)
#
# Sends install-host.sh plus the patches (about 5 KB) as one command, waits for it
# and prints the output tail. The first build takes 15-30 minutes. Needs the
# aws CLI with working credentials and ssm:SendCommand on the instance.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

instance="" bind_private=0 apt_https=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) instance="${2:?}"; shift 2 ;;
    --bind-private-ip) bind_private=1; shift ;;
    --apt-https) apt_https=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "${instance}" =~ ^i-[0-9a-f]{8,17}$ ]] || { echo "--instance-id i-... is required" >&2; exit 2; }

bind_addr=127.0.0.1
if [[ "${bind_private}" -eq 1 ]]; then
  bind_addr="$(aws ec2 describe-instances --instance-ids "${instance}" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
  [[ "${bind_addr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "cannot read the private IP of ${instance}" >&2; exit 1; }
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/pkg"
cp "${here}/install-host.sh" "${work}/pkg/"
cp -r "${here}/patches" "${work}/pkg/patches"
tar -C "${work}/pkg" -czf "${work}/pkg.tgz" .
payload="$(base64 -w0 "${work}/pkg.tgz")"
[[ ${#payload} -gt 100 && ${#payload} -lt 40000 ]] || { echo "unexpected payload size ${#payload}" >&2; exit 1; }

python3 - "${payload}" "${bind_addr}" "${apt_https}" > "${work}/params.json" <<'PY'
import json, sys
payload, bind, apt = sys.argv[1:4]
cmd = [
    "set -euo pipefail",
    "d=$(mktemp -d)",
    f"echo '{payload}' | base64 -d | tar -xz -C \"$d\"",
    f"UI_BIND_ADDR={bind} APT_HTTPS={apt} bash \"$d/install-host.sh\"",
]
print(json.dumps({"commands": cmd, "executionTimeout": ["5400"]}))
PY

cid="$(aws ssm send-command --instance-ids "${instance}" --document-name AWS-RunShellScript \
  --comment "raptgen-ui install" --timeout-seconds 600 \
  --parameters "file://${work}/params.json" --query Command.CommandId --output text)"
echo "SSM command ${cid} sent; waiting (up to 90 minutes)"
status=InProgress
for _ in $(seq 1 540); do
  sleep 10
  status="$(aws ssm get-command-invocation --command-id "${cid}" --instance-id "${instance}" \
    --query Status --output text 2>/dev/null || echo Pending)"
  case "${status}" in Success|Failed|Cancelled|TimedOut) break ;; esac
done
aws ssm get-command-invocation --command-id "${cid}" --instance-id "${instance}" \
  --query '[StandardOutputContent,StandardErrorContent]' --output text | tail -n 30
echo "status: ${status}"
[[ "${status}" == Success ]] || exit 1
echo "Next: raptgen/ui/connect.sh --instance-id ${instance}   then open http://localhost:18042"
