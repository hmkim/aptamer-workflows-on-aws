#!/usr/bin/env bash
# On-host installer for RaptGen-UI (Amazon Linux 2023). Run as root, normally
# through install.sh (SSM). Idempotent: re-running updates patches and restarts.
#
# Env:
#   UI_BIND_ADDR  address the UI port is published on (default 127.0.0.1).
#                 Set to the instance private IP for the CloudFront option.
#   APT_HTTPS     1 = also apply patches/optional/0001-https-only-apt.patch
#                 (for networks where only TCP 443 is open). Default 0.
#   PATCH_DIR     directory holding the *.patch files (default: next to this script)
set -euo pipefail

UI_REPO=https://github.com/hmdlab/RaptGen-UI.git
UI_COMMIT=13cad83859dc9eac39383a00882c17c82a4cdb37
COMPOSE_VERSION=v2.40.3
COMPOSE_SHA256=dba9d98e1ba5bfe11d88c99b9bd32fc4a0624a30fafe68eea34d61a3e42fd372
# docker compose build needs buildx 0.17+; the Amazon Linux 2023 docker package does not ship it.
BUILDX_VERSION=v0.39.1
BUILDX_SHA256=903090816da68f8bc1a2ff5346dd163a5adacfce4548d003c75df42cd47a9bf4
INSTALL_DIR=/opt/raptgen-ui
PORT=18042

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${PATCH_DIR:-${here}/patches}"
UI_BIND_ADDR="${UI_BIND_ADDR-127.0.0.1}"   # unset -> loopback; set but empty is rejected below
APT_HTTPS="${APT_HTTPS:-0}"
# Never publish on every interface: the UI has no login of its own.
case "${UI_BIND_ADDR}" in
  ""|0.0.0.0|::|"[::]"|0) echo "UI_BIND_ADDR must be one specific address (loopback or the private IP), not '${UI_BIND_ADDR}'" >&2; exit 2 ;;
esac
[[ "${UI_BIND_ADDR}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "UI_BIND_ADDR must be an IPv4 address" >&2; exit 2; }
[[ "$(id -u)" -eq 0 ]] || { echo "run as root" >&2; exit 1; }

echo "== waiting for first-boot setup (cloud-init) to finish"
# The instance user data installs docker/git/jq with dnf; a second dnf at the same time fails.
if command -v cloud-init >/dev/null; then cloud-init status --wait >/dev/null || true; fi

echo "== packages"
command -v docker >/dev/null || dnf -y install docker
command -v git >/dev/null || dnf -y install git
systemctl enable --now docker

echo "== docker compose plugin ${COMPOSE_VERSION}"
plugin=/usr/local/lib/docker/cli-plugins/docker-compose
if ! docker compose version 2>/dev/null | grep -q "${COMPOSE_VERSION#v}"; then
  mkdir -p "$(dirname "${plugin}")"
  tmp="$(mktemp)"
  curl -fsSL -o "${tmp}" "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64"
  echo "${COMPOSE_SHA256}  ${tmp}" | sha256sum -c -
  install -m 0755 "${tmp}" "${plugin}"
  rm -f "${tmp}"
fi
docker compose version

echo "== docker buildx plugin ${BUILDX_VERSION}"
bxplugin=/usr/local/lib/docker/cli-plugins/docker-buildx
if ! docker buildx version 2>/dev/null | grep -q "${BUILDX_VERSION}"; then
  mkdir -p "$(dirname "${bxplugin}")"
  tmp="$(mktemp)"
  curl -fsSL -o "${tmp}" "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64"
  echo "${BUILDX_SHA256}  ${tmp}" | sha256sum -c -
  install -m 0755 "${tmp}" "${bxplugin}"
  rm -f "${tmp}"
fi
docker buildx version

echo "== RaptGen-UI ${UI_COMMIT}"
mkdir -p "${INSTALL_DIR}"
src="${INSTALL_DIR}/RaptGen-UI"
if [[ -d "${src}/.git" ]]; then
  git -C "${src}" checkout -q -f "${UI_COMMIT}" 2>/dev/null || git -C "${src}" fetch -q origin "${UI_COMMIT}"
  git -C "${src}" checkout -q -f "${UI_COMMIT}"
  git -C "${src}" reset -q --hard "${UI_COMMIT}"
  git -C "${src}" clean -fdq
else
  git init -q "${src}"
  git -C "${src}" remote add origin "${UI_REPO}"
  git -C "${src}" fetch -q --depth 1 origin "${UI_COMMIT}"
  git -C "${src}" checkout -q --detach FETCH_HEAD
fi
test "$(git -C "${src}" rev-parse HEAD)" = "${UI_COMMIT}"

echo "== patches"
patches=("${PATCH_DIR}"/0*.patch)
if [[ "${APT_HTTPS}" == 1 ]]; then
  patches+=("${PATCH_DIR}/optional/0001-https-only-apt.patch")
  cp /etc/pki/tls/certs/ca-bundle.crt "${src}/frontend/host-ca.pem"
  cp /etc/pki/tls/certs/ca-bundle.crt "${src}/backend/host-ca.pem"
fi
for p in "${patches[@]}"; do
  git -C "${src}" apply --check "${p}"
  git -C "${src}" apply "${p}"
  echo "applied $(basename "${p}")"
done

echo "== docker compose up (first build takes 15-30 minutes)"
cd "${src}"
UI_BIND_ADDR="${UI_BIND_ADDR}" docker compose up -d --build

echo "== waiting for the UI on ${UI_BIND_ADDR}:${PORT}"
for _ in $(seq 1 180); do
  if curl -fs -o /dev/null "http://${UI_BIND_ADDR}:${PORT}/api/train/device/process"; then
    echo "RaptGen-UI is up on ${UI_BIND_ADDR}:${PORT}"
    exit 0
  fi
  sleep 10
done
echo "UI did not answer within 30 minutes; see: docker compose -f ${src}/compose.yml logs" >&2
exit 1
