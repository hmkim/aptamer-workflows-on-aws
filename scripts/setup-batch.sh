#!/usr/bin/env bash
# Deploy or update the AWS Batch stack <prefix>-batch: CPU only, GPU only, or both.
# Creates the shared network stack first when it is missing.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

DEFAULT_MOUNTPOINT_VERSION=1.25.0
cleanup_paths=()
cleanup() { [[ ${#cleanup_paths[@]} -eq 0 ]] || rm -rf -- "${cleanup_paths[@]}"; }
trap cleanup EXIT

usage() {
  cat >&2 <<'EOF'
Usage: scripts/setup-batch.sh [--cpu] [--gpu] [options]

  --cpu / --gpu               compute to enable; pass one or both. Without either:
                              CPU only for a new stack, current setting for an existing one.
  --prefix <name>             default aptamer-workflows (stack <prefix>-batch)
  --region <region>           default $AWS_REGION
  --max-vcpus <n>             CPU compute environment maximum vCPUs
  --instance-types <list>     CPU instance types, comma-separated
  --gpu-max-vcpus <n>         GPU compute environment maximum vCPUs (template default 8)
  --gpu-instance-types <list> GPU instance types (template default g5.xlarge,g6.xlarge)
  --image-tag <tag>           pipeline image tag (CPU). Default: current value, else git-<sha>
  --mountpoint-version <ver>  Mountpoint for Amazon S3 version (CPU). Default: current value, else 1.25.0
  --mountpoint-sha256 <hash>  SHA-256 of the x86_64 Mountpoint RPM. Default: current value, else
                              computed from the official download (verify it against the release signature)
  --build-image               package this repository, upload it, and build the pipeline image in CodeBuild (CPU)
  --yes                       do not ask before turning OFF a compute type that is currently ON

The --cpu / --gpu flags describe the FINAL state, not a change: on a CPU + GPU stack,
--gpu alone removes the CPU compute environment, queue and pipeline job definitions.
EOF
}

want_cpu='' want_gpu='' build_image=0 assume_yes=0
image_tag='' mp_version='' mp_sha='' max_vcpus='' instance_types='' gpu_max_vcpus='' gpu_types=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu) want_cpu=true; shift ;;
    --gpu) want_gpu=true; shift ;;
    --prefix) PREFIX=${2:?}; shift 2 ;;
    --region) REGION=${2:?}; shift 2 ;;
    --max-vcpus) max_vcpus=${2:?}; shift 2 ;;
    --instance-types) instance_types=${2:?}; shift 2 ;;
    --gpu-max-vcpus) gpu_max_vcpus=${2:?}; shift 2 ;;
    --gpu-instance-types) gpu_types=${2:?}; shift 2 ;;
    --image-tag) image_tag=${2:?}; shift 2 ;;
    --mountpoint-version) mp_version=${2:?}; shift 2 ;;
    --mountpoint-sha256) mp_sha=${2:?}; shift 2 ;;
    --build-image) build_image=1; shift ;;
    --yes|-y) assume_yes=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done
check_common
for n in "$max_vcpus" "$gpu_max_vcpus"; do [[ -z "$n" || "$n" =~ ^[1-9][0-9]*$ ]] || die "vCPU values must be positive integers"; done
for t in "$instance_types" "$gpu_types"; do [[ -z "$t" || "$t" =~ ^[a-z0-9.,-]+$ ]] || die "invalid instance type list: $t"; done
[[ -z "$image_tag" || "$image_tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die 'invalid --image-tag'
[[ -z "$mp_version" || "$mp_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'invalid --mountpoint-version'
[[ -z "$mp_sha" || "$mp_sha" =~ ^[A-Fa-f0-9]{64}$ ]] || die 'invalid --mountpoint-sha256'

stack=$(batch_stack)
ensure_network
net=$(network_stack)
vpc_id=$(require_output "$net" VpcId)
subnets=$(require_output "$net" PrivateSubnetIds)
route_tables=$(require_output "$net" PrivateRouteTableIds)

exists=0
stack_exists "$stack" && exists=1

# Resolve which compute types are enabled after this deployment.
if [[ -n "$want_cpu$want_gpu" ]]; then
  enable_cpu=${want_cpu:-false}; enable_gpu=${want_gpu:-false}
elif ((exists)); then
  enable_cpu=$(stack_parameter "$stack" EnableCpu); enable_gpu=$(stack_parameter "$stack" EnableGpu)
  enable_cpu=${enable_cpu:-true}; enable_gpu=${enable_gpu:-false}
else
  enable_cpu=true; enable_gpu=false
fi
cur_cpu='' cur_gpu=''
if ((exists)); then
  cur_cpu=$(stack_parameter "$stack" EnableCpu); cur_gpu=$(stack_parameter "$stack" EnableGpu)
  cur_cpu=${cur_cpu:-true}; cur_gpu=${cur_gpu:-false}
  log "compute now:   CPU=$cur_cpu GPU=$cur_gpu"
fi
log "compute: CPU=$enable_cpu GPU=$enable_gpu"
[[ "$enable_cpu" == true || "$enable_gpu" == true ]] || die 'at least one of CPU and GPU must stay on'
turning_off=()
[[ "$cur_cpu" == true && "$enable_cpu" == false ]] && turning_off+=(CPU)
[[ "$cur_gpu" == true && "$enable_gpu" == false ]] && turning_off+=(GPU)
if ((${#turning_off[@]})); then
  log "WARNING: this run turns OFF ${turning_off[*]} on $stack (flags describe the final state)."
  [[ " ${turning_off[*]} " == *' CPU '* ]] && \
    hint 'CPU off removes the CPU compute environment, the CPU queue and the pipeline job definitions.'
  [[ " ${turning_off[*]} " == *' GPU '* ]] && hint 'GPU off removes the GPU compute environment and the GPU queue.'
  hint 'To keep both, pass --cpu --gpu. Make sure no jobs are running on the queue you remove.'
  if ((!assume_yes)); then
    if [[ -t 0 ]]; then
      read -r -p "Type yes to continue: " answer
      [[ "$answer" == yes ]] || die 'cancelled; nothing was changed'
    else
      die 'refusing to turn off compute without confirmation: re-run with --yes'
    fi
  fi
fi

params=("VpcId=$vpc_id" "PrivateSubnetIds=$subnets" "PrivateRouteTableIds=$route_tables"
        "ProjectTag=$PREFIX" "EnableCpu=$enable_cpu" "EnableGpu=$enable_gpu")
[[ -n "$max_vcpus" ]] && params+=("MaxvCpus=$max_vcpus")
[[ -n "$instance_types" ]] && params+=("InstanceTypes=$instance_types")
[[ -n "$gpu_max_vcpus" ]] && params+=("GpuMaxvCpus=$gpu_max_vcpus")
[[ -n "$gpu_types" ]] && params+=("GpuInstanceTypes=$gpu_types")

current() { ((exists)) && stack_parameter "$stack" "$1" || true; }

if [[ "$enable_cpu" == true ]]; then
  [[ -n "$image_tag" ]] || image_tag=$(current ImageTag)
  [[ -n "$image_tag" ]] || image_tag=$(default_image_tag)
  [[ -n "$mp_version" ]] || mp_version=$(current MountpointVersion)
  if [[ -z "$mp_version" ]]; then
    mp_version=$DEFAULT_MOUNTPOINT_VERSION
  elif [[ -z "$mp_sha" && "$mp_version" == "$(current MountpointVersion)" ]]; then
    mp_sha=$(current MountpointPackageSha256)
  fi
  if [[ -z "$mp_sha" ]]; then
    require_cmd curl sha256sum
    tmp_rpm=$(mktemp)
    cleanup_paths+=("$tmp_rpm")
    log "computing SHA-256 of Mountpoint $mp_version (x86_64) from the official release"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      "https://s3.amazonaws.com/mountpoint-s3-release/$mp_version/x86_64/mount-s3-$mp_version-x86_64.rpm" -o "$tmp_rpm"
    [[ -s "$tmp_rpm" ]] || die 'downloaded Mountpoint RPM is empty'
    mp_sha=$(sha256sum "$tmp_rpm" | cut -d' ' -f1)
    log "MountpointPackageSha256=$mp_sha (verify against the .asc signature for production use)"
  fi
  params+=("ImageTag=$image_tag" "MountpointVersion=$mp_version" "MountpointPackageSha256=$mp_sha")
fi

if [[ "$enable_gpu" == true ]]; then
  # Running On-Demand G and VT instances (vCPU). Read-only check; warn only.
  quota=$(aws --region "$REGION" service-quotas get-service-quota --service-code ec2 \
    --quota-code L-DB2E81BA --query 'Quota.Value' --output text 2>/dev/null || true)
  need=${gpu_max_vcpus:-8}
  if [[ "$quota" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    if (( ${quota%.*} < need )); then
      log "WARNING: G/VT On-Demand vCPU quota is ${quota%.*}, below GpuMaxvCpus=$need; GPU jobs may stay RUNNABLE"
      hint 'Request an increase in Service Quotas: EC2 > Running On-Demand G and VT instances'
    else
      log "G/VT On-Demand vCPU quota: ${quota%.*}"
    fi
  else
    log 'could not read the G/VT vCPU quota; check it in Service Quotas'
  fi
fi

deploy_stack "$stack" "$REPO_DIR/batch/infrastructure.yaml" CAPABILITY_NAMED_IAM "${params[@]}"

if ((build_image)); then
  [[ "$enable_cpu" == true ]] || die '--build-image builds the CPU pipeline image; enable --cpu'
  require_cmd git unzip
  repo_uri=$(require_output "$stack" RepositoryUri)
  repo_name=${repo_uri#*/}
  tag=$(stack_parameter "$stack" ImageTag)
  if aws --region "$REGION" ecr describe-images --repository-name "$repo_name" \
       --image-ids "imageTag=$tag" >/dev/null 2>&1; then
    log "pipeline image tag $tag already exists; skipping build"
  else
    data_bucket=$(require_output "$stack" DataBucketName)
    project=$(require_output "$stack" ImageBuildProjectName)
    work=$(mktemp -d)
    cleanup_paths+=("$work")
    archive="$work/context.zip"
    git -C "$REPO_DIR" archive --format=zip --output "$archive" HEAD
    [[ -s "$archive" ]] && unzip -tq "$archive" >/dev/null || die 'build context archive is empty or unreadable'
    local_size=$(wc -c < "$archive" | tr -d ' ')
    aws --region "$REGION" s3 cp "$archive" "s3://$data_bucket/build/context.zip" --only-show-errors
    remote_size=$(aws --region "$REGION" s3api head-object --bucket "$data_bucket" --key build/context.zip \
      --query ContentLength --output text)
    [[ "$remote_size" == "$local_size" ]] || die "uploaded context size $remote_size != local $local_size"
    build_id=$(aws --region "$REGION" codebuild start-build --project-name "$project" --query build.id --output text)
    log "CodeBuild started for tag $tag"
    while :; do
      status=$(aws --region "$REGION" codebuild batch-get-builds --ids "$build_id" \
        --query 'builds[0].buildStatus' --output text)
      case "$status" in
        SUCCEEDED) log 'pipeline image build succeeded'; break ;;
        FAILED|FAULT|STOPPED|TIMED_OUT) die "pipeline image build ended with $status" ;;
        *) sleep 20 ;;
      esac
    done
  fi
fi

print_outputs "$stack"
log 'next steps:'
if [[ "$enable_cpu" == true ]]; then
  ((build_image)) || hint "Build the pipeline image: scripts/setup-batch.sh --prefix $PREFIX --region $REGION --build-image"
  hint "Load data:  AWS_REGION=$REGION STACK_NAME=$stack batch/submit_loader.sh" \
       "Run:        AWS_REGION=$REGION STACK_NAME=$stack RUN_ID=<RUN_ID> FRONT_PRIMER=<DNA> BACK_PRIMER=<DNA> batch/submit_copyin.sh"
fi
hint 'RaptGen images: push to the RaptgenCpuRepositoryUri / RaptgenGpuRepositoryUri outputs (see raptgen/).'
[[ "$enable_gpu" == true ]] && hint "GPU jobs: submit to the GpuJobQueueName output with a GPU resource requirement."
hint "Remove:     scripts/cleanup.sh --prefix $PREFIX --region $REGION --stacks batch"
