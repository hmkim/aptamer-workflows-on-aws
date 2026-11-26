[English](README.md) | [한국어](README.ko.md)

# HealthOmics VPC networking (not yet validated)

> **Not yet validated.** Everything in this directory follows the AWS HealthOmics developer guide but has not been run end to end in this repository. The default and validated path is `RESTRICTED` networking in [`../README.md`](../README.md).

| File | Purpose |
|---|---|
| `vpc.yaml` | Run security group (HTTPS egress only, no ingress), `AWS::Omics::Configuration` for VPC-mode runs, opt-in PrivateLink interface endpoints |
| `omics-vpc-configuration.sh` | CLI alternative to the CloudFormation configuration: `create` (waits for `ACTIVE`, up to 15 minutes), `status`, `wait`, `delete` |

## `vpc.yaml` parameters

| Parameter | Default | Meaning |
|---|---|---|
| `VpcId` | required | `VpcId` output of the network stack |
| `PrivateSubnetIds` | required | `PrivateSubnetIds` output of the network stack: private, NAT route, one per AZ |
| `VpcCidr` | required | `VpcCidr` output of the network stack; scopes the endpoint security group |
| `CreateConfiguration` | `true` | Create the HealthOmics configuration in CloudFormation; `false` to use the script |
| `ConfigurationName` | stack name | Configuration name passed to `start-run --configuration-name` |
| `CreateInterfaceEndpoints` | `false` | Create the interface endpoints selected below |
| `EndpointWorkflows` | `true` | `com.amazonaws.<region>.workflows-omics` (workflow and run APIs) |
| `EndpointStorage` | `false` | `storage-omics` (sequence store data plane) |
| `EndpointControlStorage` | `false` | `control-storage-omics` (sequence and reference store control plane) |
| `EndpointAnalytics` | `false` | `analytics-omics` (variant and annotation stores) |
| `EndpointTags` | `false` | `tags-omics` (tagging) |

`scripts/setup-healthomics.sh --vpc --interface-endpoints [--endpoint-services <list>]` sets these (default `workflows-omics` only) and first checks that each service is offered in the Region. Not every Region offers all five. Check with:

```bash
aws ec2 describe-vpc-endpoint-services --region <REGION> \
  --query 'ServiceNames[?contains(@, `omics`)]' --output text
```

On 2026-11-26 this listed all five in us-east-1, us-west-2 and eu-west-1, and only `workflows-omics`, `analytics-omics` and `tags-omics` in ap-northeast-2. The template change was checked with `cfn-lint` and CloudFormation template validation only; it was not deployed.
| `ProjectTag` | `aptamer-workflows` | `Project` tag value |

Outputs: `RunSecurityGroupId`, `SubnetIds`, `ConfigurationName`, `ConfigurationArn`, `InterfaceEndpointsEnabled`, `ValidationStatus`.

## Facts this design relies on

From [VPC networking](https://docs.aws.amazon.com/omics/latest/dev/workflows-vpc-networking.html), [internet access](https://docs.aws.amazon.com/omics/latest/dev/workflows-vpc-internet.html), and [interface endpoints](https://docs.aws.amazon.com/omics/latest/dev/vpc-interface-endpoints.html):

- `RESTRICTED` (default) allows only same-Region S3 and ECR. `VPC` mode sends run traffic through HealthOmics-managed network interfaces in your subnets.
- A configuration takes 1-16 subnets (at most one per Availability Zone, in AZs where HealthOmics operates) and 1-5 security groups from one VPC. It is immutable; 10 per account by default.
- The first configuration creates the `AWSServiceRoleForHealthOmics` service-linked role. The deployer needs `iam:CreateServiceLinkedRole` for `omics.amazonaws.com`.
- Public subnets give a run no internet access. Use private subnets with a NAT route, as `../../batch/network.yaml` creates.
- Interface endpoints let clients inside the VPC call HealthOmics APIs privately. VPC-mode runs do not need them. Each endpoint has an hourly charge per AZ.

## Run in VPC mode

```bash
AWS_REGION='<AWS_REGION>' ... ../orchestrate.sh run --networking-mode VPC --configuration-name '<CONFIGURATION_NAME>'
```

Use the same environment variables as a `RESTRICTED` run. Delete the configuration (or the `vpc.yaml` stack) before deleting the network; HealthOmics network interfaces can delay subnet and security group deletion.
