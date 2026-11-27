#!/usr/bin/env bash
# Deploy or update the HealthOmics stack <prefix>-healthomics (RESTRICTED networking).
# With --vpc, also deploy <prefix>-healthomics-vpc in the shared network
# (VPC networking mode: NOT YET VALIDATED). Without --vpc no network is created.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/setup-healthomics.sh [--vpc] [options]

  --prefix <name>             default aptamer-workflows (stack <prefix>-healthomics)
  --region <region>           default $AWS_REGION
  --image-tag <tag>           workflow image tag recorded in the PipelineImage output.
                              Default: current value, else git-<sha>
  --input-prefix <prefix>     S3 input prefix (template default inputs)
  --output-prefix <prefix>    S3 output prefix (template default outputs)
  --vpc                       also deploy the VPC-mode stack (not yet validated); creates
                              the shared network stack when it is missing
  --configuration-name <name> HealthOmics configuration name, default <prefix>-vpc
  --interface-endpoints       with --vpc: create HealthOmics PrivateLink interface endpoints
                              (default service: workflows-omics only)
  --endpoint-services <list>  with --interface-endpoints: comma-separated subset of
                              workflows-omics,storage-omics,control-storage-omics,analytics-omics,tags-omics.
                              Not every Region offers all five; the script checks before deploying.
  --configuration-by-script   with --vpc: skip AWS::Omics::Configuration and create the
                              configuration with healthomics/vpc/omics-vpc-configuration.sh
EOF
}

image_tag='' input_prefix='' output_prefix='' vpc=0 config_name='' endpoints=false by_script=0
endpoint_services=workflows-omics
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX=${2:?}; shift 2 ;;
    --region) REGION=${2:?}; shift 2 ;;
    --image-tag) image_tag=${2:?}; shift 2 ;;
    --input-prefix) input_prefix=${2:?}; shift 2 ;;
    --output-prefix) output_prefix=${2:?}; shift 2 ;;
    --vpc) vpc=1; shift ;;
    --configuration-name) config_name=${2:?}; shift 2 ;;
    --interface-endpoints) endpoints=true; shift ;;
    --endpoint-services) endpoint_services=${2:?}; shift 2 ;;
    --configuration-by-script) by_script=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done
check_common
[[ -z "$image_tag" || "$image_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'invalid --image-tag'
for p in "$input_prefix" "$output_prefix"; do
  [[ -z "$p" || "$p" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "invalid S3 prefix: $p"
done
config_name=${config_name:-$PREFIX-vpc}
declare -A endpoint_param=([workflows-omics]=EndpointWorkflows [storage-omics]=EndpointStorage
  [control-storage-omics]=EndpointControlStorage [analytics-omics]=EndpointAnalytics [tags-omics]=EndpointTags)
endpoint_params=()
for svc in "${!endpoint_param[@]}"; do
  [[ ",$endpoint_services," == *",$svc,"* ]] && v=true || v=false
  endpoint_params+=("${endpoint_param[$svc]}=$v")
done
IFS=, read -r -a _svcs <<<"$endpoint_services"
for svc in "${_svcs[@]}"; do
  [[ -n "${endpoint_param[$svc]:-}" ]] || die "unknown endpoint service: $svc"
done
[[ "$config_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'invalid --configuration-name'

stack=$(healthomics_stack)
if [[ -z "$image_tag" ]] && stack_exists "$stack"; then
  image_tag=$(stack_parameter "$stack" ImageTag)
fi
image_tag=${image_tag:-$(default_image_tag)}
params=("ImageTag=$image_tag")
[[ -n "$input_prefix" ]] && params+=("InputPrefix=$input_prefix")
[[ -n "$output_prefix" ]] && params+=("OutputPrefix=$output_prefix")
deploy_stack "$stack" "$REPO_DIR/healthomics/infrastructure.yaml" CAPABILITY_IAM "${params[@]}"
print_outputs "$stack"

if ((vpc)); then
  log 'HealthOmics VPC networking mode is NOT YET VALIDATED in this repository'
  ensure_network
  net=$(network_stack)
  vpc_id=$(require_output "$net" VpcId)
  subnets=$(require_output "$net" PrivateSubnetIds)
  vpc_cidr=$(stack_output "$net" VpcCidr)
  if [[ -z "$vpc_cidr" ]]; then
    vpc_cidr=$(aws --region "$REGION" ec2 describe-vpcs --vpc-ids "$vpc_id" --query 'Vpcs[0].CidrBlock' --output text)
  fi
  if [[ "$endpoints" == true ]]; then
    offered=$(aws --region "$REGION" ec2 describe-vpc-endpoint-services \
      --query 'ServiceNames[?contains(@, `omics`)]' --output text | tr '\t' ' ')
    for svc in "${_svcs[@]}"; do
      [[ " $offered " == *" com.amazonaws.$REGION.$svc "* ]] ||
        die "interface endpoint service $svc is not offered in $REGION (offered: ${offered:-none})"
    done
    log "interface endpoints: $endpoint_services"
  fi
  create_config=true
  ((by_script)) && create_config=false
  vstack=$(healthomics_vpc_stack)
  deploy_stack "$vstack" "$REPO_DIR/healthomics/vpc/vpc.yaml" - \
    "VpcId=$vpc_id" "PrivateSubnetIds=$subnets" "VpcCidr=$vpc_cidr" "ProjectTag=$PREFIX" \
    "CreateConfiguration=$create_config" "ConfigurationName=$config_name" \
    "CreateInterfaceEndpoints=$endpoints" "${endpoint_params[@]}"
  if ((by_script)); then
    "$REPO_DIR/healthomics/vpc/omics-vpc-configuration.sh" create \
      --region "$REGION" --name "$config_name" --from-stack "$vstack"
  else
    "$REPO_DIR/healthomics/vpc/omics-vpc-configuration.sh" wait --region "$REGION" --name "$config_name"
  fi
  print_outputs "$vstack"
fi

log 'next steps:'
hint "Outputs:   aws cloudformation describe-stacks --region $REGION --stack-name $stack --query 'Stacks[0].Outputs'" \
     "Push the workflow image to the RepositoryUri output with tag $image_tag" \
     "Register:  AWS_REGION=$REGION WORKFLOW_NAME=<WORKFLOW_NAME> healthomics/orchestrate.sh register" \
     "Run:       AWS_REGION=$REGION BUCKET_NAME=<BucketName> RUN_ROLE_ARN=<RunRoleArn> ... healthomics/orchestrate.sh run"
((vpc)) && hint "VPC mode:  add --networking-mode VPC --configuration-name $config_name to the run command (not yet validated)"
hint "Remove:    scripts/cleanup.sh --prefix $PREFIX --region $REGION --stacks healthomics-vpc,healthomics"
