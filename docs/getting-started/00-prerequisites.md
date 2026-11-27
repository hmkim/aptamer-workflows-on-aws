[English](00-prerequisites.md) | [한국어](00-prerequisites.ko.md)

# Prerequisites

Do these checks once before any path in this repository. Each step says what you should see.

## Tools on your workstation

Use Linux, or a Linux shell such as WSL or a cloud-based IDE. You need:

| Tool | Needed for | Check |
|---|---|---|
| Git | cloning, image tags derived from the commit | `git --version` |
| Bash 4 or later | every script (macOS ships Bash 3.2; install a newer one) | `bash --version` |
| AWS CLI v2 | every AWS step | `aws --version` shows `aws-cli/2.` |
| `jq`, `curl`, `unzip`, `sha256sum` | setup scripts and helpers | `jq --version` |
| Python 3 | offline tests | `python3 --version` |
| Docker | local runs, the HealthOmics image, RaptGen images | `docker version` |
| Session Manager plugin for the AWS CLI | RaptGen-UI port forwarding only | `session-manager-plugin --version` |
| Node.js 22 or later | the optional RaptGen-UI web access only | `node --version` |

Clone the repository and run the offline tests. They make no AWS calls:

```bash
git clone 'https://github.com/<GITHUB_ORGANIZATION>/aptamer-workflows-on-aws.git'
cd aptamer-workflows-on-aws
python3 -m unittest discover --start-directory tests --pattern 'test_*.py'
```

You should see `OK` (some tests may be reported as skipped when an optional tool is missing).

## AWS account and credentials

Use an AWS account where you may create networks, IAM roles, S3 buckets, and compute. A sandbox or development account is the right place for a first run.

Use temporary credentials, for example AWS IAM Identity Center (`aws sso login`) or a role. Do not put access keys in files inside this repository. Check who you are:

```bash
aws sts get-caller-identity --query Arn --output text
```

You should see a role or user ARN. Do not paste it into issues or commits.

The identity that runs the setup scripts needs permission to use CloudFormation with `CAPABILITY_NAMED_IAM` (the templates create IAM roles), and to create VPC, EC2, S3, KMS, ECR, AWS Batch, CodeBuild, CloudWatch Logs, and HealthOmics resources. HealthOmics VPC mode (not yet validated) also needs `iam:CreateServiceLinkedRole` for `omics.amazonaws.com`.

## Region

Pick one AWS Region and use it everywhere:

```bash
export AWS_REGION='<REGION>'
aws ec2 describe-availability-zones --query 'AvailabilityZones[].ZoneName' --output text
```

You should see at least two Availability Zone names. An **Availability Zone (AZ)** is one or more separate data centers inside a Region.

If you plan to use AWS HealthOmics, confirm that the Region offers it in the [HealthOmics endpoints list](https://docs.aws.amazon.com/general/latest/gr/healthomics-quotas.html). For HealthOmics VPC mode (not yet validated), also note which AZs HealthOmics supports in that Region ([supported AZs](https://docs.aws.amazon.com/omics/latest/dev/workflows-vpc-internet.html)).

## Quotas

A **service quota** is an account limit per Region, such as the number of vCPUs you may run at once. AWS Batch cannot start instances beyond your quota; jobs then stay in `RUNNABLE`.

CPU compute (default `MaxvCpus` 72, instance families `c7i,c6i`) uses the "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances" quota:

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.Value' --output text
```

GPU compute (default `GpuMaxvCpus` 8, `g5.xlarge,g6.xlarge`) uses the "Running On-Demand G and VT instances" quota. **Check it before you choose a GPU path.** New accounts often have a low or zero value:

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA \
  --query 'Quota.Value' --output text
```

You should see a number at least as large as the vCPUs you plan to use (8 for the default). If it is lower, request an increase in the Service Quotas console (EC2, "Running On-Demand G and VT instances") or pass a smaller `--gpu-max-vcpus`. `scripts/setup-batch.sh --gpu` repeats this check and warns.

## What costs money

These parts are billed while they exist or run. Check the pricing pages for your Region before you start, and use [the cleanup guide](90-cleanup.md) when you finish.

| Part | Created by | Billed |
|---|---|---|
| NAT gateway (and its Elastic IP) | network stack | per hour while it exists, plus per GB processed |
| EC2 instances behind AWS Batch | Batch stack | only while jobs run; the compute environments scale to zero |
| GPU instances (G family) | Batch stack with `--gpu` | only while GPU jobs run, at a higher hourly rate than CPU |
| HealthOmics runs and run storage | your runs | per run compute and per run storage |
| HealthOmics interface endpoints | `--interface-endpoints` | per hour per endpoint per AZ, plus per GB |
| S3, ECR, KMS keys, CloudWatch Logs | Batch and HealthOmics stacks | storage and requests; kept after stack deletion unless you delete them |
| RaptGen-UI EC2 host | RaptGen UI stack | per hour while running, plus its EBS volume |

Pricing pages: [Amazon VPC (NAT gateway, PrivateLink)](https://aws.amazon.com/vpc/pricing/), [Amazon EC2](https://aws.amazon.com/ec2/pricing/), [AWS HealthOmics](https://aws.amazon.com/healthomics/pricing/), [Amazon S3](https://aws.amazon.com/s3/pricing/).

## Next

Go back to [the path table in the README](../../README.md#choose-your-path), or continue with [the shared network](10-network.md).
