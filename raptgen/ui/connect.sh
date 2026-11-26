#!/usr/bin/env bash
# Open an SSM port forward to RaptGen-UI, then browse http://localhost:18042
#
#   raptgen/ui/connect.sh --instance-id i-... [--local-port 18042] [--remote-host 127.0.0.1]
#
# --remote-host is the address the UI is published on at the instance: 127.0.0.1
# by default, the instance private IP when installed with --bind-private-ip.
# Needs the AWS CLI and the Session Manager plugin. Ctrl-C closes the tunnel.
set -euo pipefail
instance="" local_port=18042 remote_host=127.0.0.1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) instance="${2:?}"; shift 2 ;;
    --local-port) local_port="${2:?}"; shift 2 ;;
    --remote-host) remote_host="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "${instance}" =~ ^i-[0-9a-f]{8,17}$ ]] || { echo "--instance-id i-... is required" >&2; exit 2; }
[[ "${local_port}" =~ ^[0-9]{2,5}$ ]] || { echo "bad --local-port" >&2; exit 2; }
[[ "${remote_host}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "bad --remote-host" >&2; exit 2; }
command -v session-manager-plugin >/dev/null || { echo "Install the Session Manager plugin first." >&2; exit 1; }

echo "Forwarding localhost:${local_port} -> ${remote_host}:18042 on ${instance}. Open http://localhost:${local_port}"
exec aws ssm start-session --target "${instance}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=${remote_host},portNumber=18042,localPortNumber=${local_port}"
