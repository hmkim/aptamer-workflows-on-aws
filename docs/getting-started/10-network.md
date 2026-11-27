[English](10-network.md) | [한국어](10-network.ko.md)

# Shared private network

AWS Batch, the RaptGen-UI EC2 host, and the optional HealthOmics VPC mode (not yet validated) all use one private network, created by `batch/network.yaml` as the stack `<prefix>-network`. You rarely run this step by hand: `scripts/setup-batch.sh` and `scripts/setup-healthomics.sh --vpc` create the network when it is missing. Run it yourself when you want to choose the Availability Zones.

HealthOmics without `--vpc` (the default `RESTRICTED` mode) does not use this network.

## What it creates

A **VPC** (virtual private cloud) is your own isolated network in AWS. A **subnet** is a range of addresses inside it, placed in one Availability Zone. A **NAT gateway** lets machines without public addresses open outbound connections to the internet, while nothing on the internet can connect in.

```text
VPC 10.64.0.0/16 (default)
├── NAT subnet 10.64.0.0/24 (AZ 1): NAT gateway with an Elastic IP; no automatic public IPs
├── Private subnet 1 10.64.10.0/24 (AZ 1) ──┐  default route 0.0.0.0/0 -> NAT gateway
└── Private subnet 2 10.64.20.0/24 (AZ 2) ──┘
```

- The two private subnets are in **two different AZs**. HealthOmics VPC mode accepts at most one subnet per AZ, so this layout fits it.
- Compute (Batch instances, the RaptGen-UI host, HealthOmics network interfaces) goes only into the private subnets. None of it gets a public IP address.
- There is one NAT gateway, in AZ 1. That keeps cost down; if AZ 1 has a problem, the private subnets lose outbound internet access.
- The Batch stack adds an S3 **gateway endpoint** to the private route tables, so S3 traffic from Batch stays on the AWS network and does not go through the NAT gateway.

Outputs: `VpcId`, `PrivateSubnetIds`, `PrivateRouteTableIds`, `VpcCidr`, `PrivateSubnetAvailabilityZones`.

## Step 1: Set variables

```bash
export AWS_REGION='<REGION>'
export PREFIX='aptamer-workflows'
```

`PREFIX` becomes the first part of every stack name. Use lowercase letters, digits, and hyphens. Use a new prefix to build a second, independent set of stacks.

## Step 2 (optional): Choose Availability Zones

Skip this step if you will not use HealthOmics VPC mode. Otherwise, list the Region's AZs and compare them with the HealthOmics [supported AZ list](https://docs.aws.amazon.com/omics/latest/dev/workflows-vpc-internet.html):

```bash
aws ec2 describe-availability-zones --region "$AWS_REGION" \
  --query 'AvailabilityZones[].ZoneName' --output text
```

Pick two different AZs that appear on both lists.

## Step 3: Deploy the network

Default AZs (the first two in the Region):

```bash
scripts/setup-network.sh --prefix "$PREFIX" --region "$AWS_REGION"
```

Chosen AZs:

```bash
scripts/setup-network.sh --prefix "$PREFIX" --region "$AWS_REGION" \
  --az1 '<AZ_NAME_1>' --az2 '<AZ_NAME_2>'
```

You should see `deploying aptamer-workflows-network from batch/network.yaml`, then `aptamer-workflows-network: CREATE_COMPLETE` (or `UPDATE_COMPLETE`), then a table of outputs and next-step hints. Running it again with the same values changes nothing.

## Step 4: Check the result

```bash
aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$PREFIX-network" \
  --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnetAvailabilityZones`].OutputValue' --output text
```

You should see two different AZ names separated by a comma.

## Cost note

The NAT gateway is billed per hour while the network stack exists, even when no job runs, plus per GB that passes through it. Delete the network when you are done (see [cleanup](90-cleanup.md)).

## Next

- [AWS Batch](20-batch.md)
- [AWS HealthOmics](30-healthomics.md) (VPC mode uses this network)
- [Both, at once or one after another](40-both.md)
