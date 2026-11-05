# EC2 baseline helper

`run_baseline.sh` runs the shared Nextflow `local` profile on an existing EC2 instance. It uses local POSIX storage for Nextflow work and Docker task directories, then uploads final outputs to private S3. It does not create an instance, change security groups, start a listener, or publish a container port.

## Host requirements

- Nextflow 24.10 or 25.x
- Docker
- AWS CLI v2
- Enough local disk for staged inputs, task work, and outputs
- An instance role that can read the input S3 prefix, write the output S3 prefix, and pull the selected private ECR image

Use an instance role instead of long-lived AWS access keys. Limit the role to the exact bucket prefixes and ECR repository needed for the run.

## Run

```bash
AWS_REGION='<AWS_REGION>' \
INPUT_URI='s3://<INPUT_BUCKET>/<FASTQ_PREFIX>/' \
OUTPUT_URI='s3://<OUTPUT_BUCKET>/<BASELINE_OUTPUT_PREFIX>/' \
PIPELINE_IMAGE='<ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPOSITORY>@sha256:<IMAGE_DIGEST>' \
FRONT_PRIMER='<FRONT_PRIMER_DNA>' \
BACK_PRIMER='<BACK_PRIMER_DNA>' \
RUN_ID='<RUN_ID>' \
WORK_ROOT="$PWD/ec2-runs" \
./run_baseline.sh
```

`WORK_ROOT` is a normal local file system path. Do not set it to Mountpoint for Amazon S3 because Nextflow work needs POSIX behaviors that Mountpoint does not provide.

The helper accepts input files named `R<number>_<name>.fastq.gz`. It refuses to overwrite an existing run directory. Final results are uploaded to `OUTPUT_URI/RUN_ID/`, while work files remain local for inspection or `-resume` use.

## Validate locally

```bash
bash -n run_baseline.sh
```

## Glossary

- **EC2 instance role:** temporary AWS permissions delivered to the virtual machine without storing access keys in a file.
- **ECR:** private AWS container image storage.
- **POSIX storage:** a normal local file system with the file operations expected by Nextflow and command-line tools.
- **S3 prefix:** the leading folder-like part of object keys used to organize data and limit permissions.
