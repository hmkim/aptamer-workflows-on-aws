# Security policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability, exposed credential, private sequence, or identifying information. Use the repository host's private vulnerability-reporting feature when it is enabled. Include a minimal reproduction, affected revision, impact, and suggested mitigation. Remove credentials, account IDs, resource identifiers, object keys, logs, and biological data from the report.

If private reporting is unavailable, contact the repository maintainer through a private channel listed on the repository profile. Do not test against infrastructure you do not own or lack authorization to assess.

## Supported versions

Security fixes are applied to the current main branch. This educational repository does not promise long-term support for older revisions.

## Data classification

Treat sequencing reads, candidate sequences, samplesheets, and derived results as sensitive unless their public status and redistribution terms are documented.

D1 refers to public RNA SELEX data generated with Ion Torrent sequencing. It is not customer DNA data and it is not Illumina data. The repository contains public metadata and checksums, not the downloaded reads or generated results.

Never commit:

- Private or customer sequencing data
- Personal or organization names tied to private work
- AWS account IDs, role ARNs, bucket names, workflow IDs, job IDs, or other real resource identifiers
- Access keys, session tokens, passwords, private keys, or signed URLs
- Execution logs, screenshots, or result tables from private runs
- Local absolute paths that disclose a user or machine name

## Deployment baseline

This repository is not an official AWS sample or template. Review every deployment for your environment.

### Identity and permissions

- Use temporary role credentials. Do not place long-lived access keys in files or environment setup committed to source control.
- Separate the provisioning role, EC2 instance role, Batch job role, Nextflow head role, and HealthOmics run role.
- Limit permissions to required API actions and exact resources.
- Give input prefixes read-only access. Grant output writes only to a unique run prefix.
- Avoid delete permission in runtime roles. Use a separate, controlled cleanup role when deletion is required.

### Storage

- Keep all four S3 Block Public Access controls enabled.
- Disable ACL-based ownership with bucket-owner-enforced object ownership.
- Deny non-TLS requests.
- Encrypt S3 objects and compute volumes.
- Restrict KMS key use to required roles and services. KMS is AWS Key Management Service, which controls encryption keys.
- Enable versioning and define reviewed lifecycle and recovery policies.
- Use private ECR repositories, immutable image tags, and image scanning.

### Network

- Run non-interactive compute without inbound security-group rules.
- Prefer private subnets and private AWS service connectivity where appropriate.
- Do not expose SSH, workflow dashboards, container ports, databases, or storage to the internet for this workflow.
- Use an approved managed access path such as AWS Systems Manager Session Manager when interactive host access is required.
- Keep HealthOmics in restricted networking mode unless the workflow has a reviewed need for VPC connectivity.

### Containers and software supply chain

- Pin intentional dependency versions and review updates.
- Build from a reviewed Dockerfile in a controlled build environment.
- Refer to deployed images by digest for reproducible comparisons.
- Run workload containers as a non-root user and without privileged mode.
- Do not download executables during a restricted workflow run. Package dependencies into the image before launch.

## Mountpoint safety

Mountpoint for Amazon S3 is not fully POSIX-compliant. Compatibility depends on the actual file-access pattern.

- Mount input data read-only.
- Keep temporary files, current working directories, and outputs on local POSIX storage.
- Never use Mountpoint as the Nextflow work directory.
- Do not perform destructive compatibility tests against valuable objects.
- Use immutable or versioned mounted object keys because Nextflow cannot detect content changes behind an unchanged string path.

## Cleanup safety

Cloud cleanup can destroy data or interrupt running work. Follow this order:

1. Confirm the AWS account, Region, resource, and prefix.
2. Check for active jobs and runs.
3. Preserve required outputs and provenance records.
4. List the exact target.
5. Use `--dryrun` where the AWS CLI operation supports it.
6. Obtain explicit operator approval.
7. Execute only the reviewed command.
8. Verify the result without broadening the target.

CloudFormation stack deletion has no dry-run mode. The included HealthOmics template retains its S3 bucket, KMS key, and ECR repository, so deleting the stack does not finish cleanup. Review retained resources separately.

## Scientific safety

This software ranks sequences and predicts RNA secondary structure. It does not establish binding, safety, efficacy, diagnostic performance, or clinical utility. Molecular dynamics simulation is excluded. Use qualified scientific review and appropriate experimental validation before making decisions from results.
