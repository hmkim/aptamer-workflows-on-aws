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
| `CreateInterfaceEndpoints` | `false` | Create `workflows-omics`, `storage-omics`, `control-storage-omics`, `analytics-omics`, `tags-omics` interface endpoints |
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
