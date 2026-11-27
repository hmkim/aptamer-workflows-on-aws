#!/usr/bin/env bash
# Build a RaptGen image locally and push it to the ECR repository created by
# the Batch stack. Prints the image digest URI to use in raptgen/batch/jobs.yaml.
#
#   raptgen/containers/build.sh cpu|gpu [--stack-prefix aptamer-workflows] [--no-push]
#
# Needs: docker (with BuildKit), aws CLI v2 with working credentials, git (for the tag).
# The Region comes from your AWS CLI configuration. STACK_PREFIX sets the default prefix.
# Tag: <upstream-commit12>-<git-sha7> (git sha of this repo; "nogit" outside git).
set -euo pipefail

variant="${1:-}"
[[ "${variant}" == cpu || "${variant}" == gpu ]] || { echo "usage: $0 cpu|gpu [--stack-prefix P] [--no-push]" >&2; exit 2; }
shift
prefix="${STACK_PREFIX:-aptamer-workflows}"
push=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-prefix) prefix="${2:?}"; shift 2 ;;
    --no-push) push=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ctx="${here}/${variant}"
upstream="$(grep -m1 '^ARG RAPTGEN_COMMIT=' "${ctx}/Dockerfile" | cut -d= -f2)"
[[ ${#upstream} -eq 40 ]] || { echo "cannot read RAPTGEN_COMMIT from ${ctx}/Dockerfile" >&2; exit 1; }
gitsha="$(git -C "${here}" rev-parse --short=7 HEAD 2>/dev/null || echo nogit)"
tag="${upstream:0:12}-${gitsha}"
local_name="aptamer-raptgen-${variant}:${tag}"

echo "building ${local_name}"
DOCKER_BUILDKIT=1 docker build --build-arg "PROJECT_REVISION=${gitsha}" -t "${local_name}" "${ctx}"
if [[ "${push}" -eq 0 ]]; then echo "built ${local_name} (not pushed)"; exit 0; fi

key=RaptgenCpuRepositoryUri; [[ "${variant}" == gpu ]] && key=RaptgenGpuRepositoryUri
uri="$(aws cloudformation describe-stacks --stack-name "${prefix}-batch" \
  --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" --output text)"
if [[ -z "${uri}" || "${uri}" == None ]]; then
  echo "stack ${prefix}-batch has no output ${key}. Was ${variant} enabled (EnableCpu/EnableGpu)?" >&2
  exit 1
fi
registry="${uri%%/*}"
aws ecr get-login-password | docker login --username AWS --password-stdin "${registry}"
docker tag "${local_name}" "${uri}:${tag}"
docker push "${uri}:${tag}"
digest="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${uri}:${tag}" | grep -F "${uri}@" | head -1)"
[[ -n "${digest}" ]] || { echo "push finished but no digest found for ${uri}:${tag}" >&2; exit 1; }
echo
echo "image digest URI (use this in raptgen/batch/jobs.yaml parameters):"
echo "${digest}"
