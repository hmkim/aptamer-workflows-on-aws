[English](90-cleanup.md) | [한국어](90-cleanup.ko.md)

# Cleanup

Deleting stacks stops the hourly charges (NAT gateway, interface endpoints, an idle RaptGen-UI host). Deleting retained data is a separate, deliberate step. Save every result you need first. For per-run cleanup of S3 prefixes, local folders, and jobs, see [the storage guide](../storage.md#cleanup).

```bash
export AWS_REGION='<REGION>'
export PREFIX='aptamer-workflows'
```

## Step 1: Stop running work

```bash
for q in "$PREFIX-batch-queue" "$PREFIX-batch-gpu-queue"; do
  for s in RUNNABLE STARTING RUNNING; do
    aws batch list-jobs --region "$AWS_REGION" --job-queue "$q" --job-status "$s" \
      --query 'jobSummaryList[].[jobId,jobName,status]' --output text 2>/dev/null
  done
done
aws omics list-runs --region "$AWS_REGION" --status RUNNING --query 'items[].[id,name,status]' --output text
```

You should see no lines. If jobs or runs remain, wait for them, or stop them after checking each ID (`aws batch terminate-job`, `aws omics cancel-run`).

## Step 2: Remove the RaptGen-UI web gate first (if you created it)

The optional web access (`raptgen/ui-web`) is a CDK stack in **us-east-1**, not part of the prefix, so `scripts/cleanup.sh` does not delete it. Its CloudFront VPC origin keeps network interfaces and the security group `CloudFront-VPCOrigins-Service-SG` in the shared network, so remove it before the UI host and the network. `scripts/cleanup.sh` stops with a message while that security group still exists.

```bash
export UI_WEB_STACK='RaptGenUiWeb'          # the gate stack name you used
aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$PREFIX-raptgen-ui-origin-access"
aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$PREFIX-raptgen-ui-origin-access"
aws cloudformation delete-stack --region us-east-1 --stack-name "$UI_WEB_STACK"
aws cloudformation wait stack-delete-complete --region us-east-1 --stack-name "$UI_WEB_STACK"
```

The gate stack deletion takes a while because CloudFront disables and deletes the distribution first. If it ends in `DELETE_FAILED` on the Lambda@Edge function, CloudFront still holds replicas of it; wait (in the validation run a retry about 25 minutes later worked; it can take longer) and run the last two commands again. The stack retains the Cognito user pool (deletion protection on), the CloudFront log bucket and the users' secrets; see [raptgen/ui-web/README.md](../../raptgen/ui-web/README.md#close-the-door). Remove them only after you have saved what you need (the log bucket has no versioning):

```bash
aws cloudformation list-stack-resources --region us-east-1 --stack-name "$UI_WEB_STACK" \
  --query 'StackResourceSummaries[?ResourceStatus==`DELETE_SKIPPED`].[ResourceType,PhysicalResourceId]' --output text
aws cognito-idp update-user-pool --region us-east-1 --user-pool-id '<UserPoolId>' --deletion-protection INACTIVE
aws cognito-idp delete-user-pool --region us-east-1 --user-pool-id '<UserPoolId>'
aws s3 rm "s3://<LogBucket>" --recursive --region us-east-1 && aws s3api delete-bucket --bucket '<LogBucket>' --region us-east-1
aws secretsmanager delete-secret --region us-east-1 --secret-id '<UserSecretPrefix><username>' --force-delete-without-recovery
```

The `list-stack-resources` call works while the stack still exists (for example in `DELETE_FAILED`); note the IDs before the final delete.

The RaptGen-UI host (`<prefix>-raptgen-ui`), the RaptGen job definitions (`<prefix>-raptgen-jobs`) and the origin-access stack are deleted by `scripts/cleanup.sh` in step 3. Models in the UI live on the host disk and are deleted with it.

## Step 3: Delete the main stacks

Everything for the prefix, in reverse order (`raptgen-ui-origin-access`, `raptgen-ui`, `raptgen-jobs`, `healthomics-vpc`, `healthomics`, `batch`, `network`; stacks that do not exist are skipped):

```bash
scripts/cleanup.sh --prefix "$PREFIX" --region "$AWS_REGION"
```

The script lists the stacks it will delete and asks you to type the prefix. You should see `deleting <stack>` and `<stack> deleted` for each, then `cleanup finished for prefix aptamer-workflows` and a reminder that retained resources still exist.

Only some stacks, for example HealthOmics only:

```bash
scripts/cleanup.sh --prefix "$PREFIX" --region "$AWS_REGION" --stacks healthomics-vpc,healthomics
```

The script refuses to delete a stack that another remaining stack still uses: the network while the Batch, HealthOmics VPC or RaptGen-UI stacks exist, the UI host while its origin-access stack exists, the Batch stack while the RaptGen job definitions exist, and the UI host or the network while a CloudFront VPC origin (web gate) is still in the network. If you created the HealthOmics configuration with `--configuration-by-script`, the script deletes it before the stack. HealthOmics and Batch network interfaces can delay subnet and security group deletion; if a delete fails, wait a few minutes and run the command again.

Use `--yes` to skip the prompt in automation only after you have reviewed the list once.

## Step 4 (optional): Delete retained data

The templates keep S3 buckets, ECR repositories, KMS keys, and the Batch log groups (jobs and the CodeBuild image build) when a stack is deleted, so data is not lost by accident. They still cost money. To delete them as well, run the cleanup **before** the stacks are gone (the script reads the names from the stack outputs):

```bash
scripts/cleanup.sh --prefix "$PREFIX" --region "$AWS_REGION" --delete-data
```

The script prints every bucket, repository, and log group it will delete permanently, plus the number of KMS keys it will schedule for deletion (7-day waiting period). Buckets are emptied of every object version first. This cannot be undone.

If the stacks are already deleted, find the retained resources by name in the S3, ECR, KMS, and CloudWatch Logs consoles, review them, and delete them by hand.

## Step 5: Remove HealthOmics workflows

Registered private workflows are not part of any stack. List and delete the ones you created:

```bash
aws omics list-workflows --region "$AWS_REGION" --type PRIVATE --query 'items[].[id,name,status]' --output text
aws omics delete-workflow --region "$AWS_REGION" --id '<WORKFLOW_ID>'
```

Runs are kept too (`RETENTION_MODE=RETAIN`). Delete the runs you started, and their log streams in the shared log group `/aws/omics/WorkflowLog` if you no longer need them:

```bash
aws omics list-runs --region "$AWS_REGION" --query 'items[].[id,name,status]' --output text
aws omics delete-run --region "$AWS_REGION" --id '<RUN_ID>'
aws logs describe-log-streams --region "$AWS_REGION" --log-group-name /aws/omics/WorkflowLog \
  --log-stream-name-prefix 'run/<RUN_ID>' --query 'logStreams[].logStreamName' --output text
```

Then remove the local state: `healthomics/.state/`, `healthomics/dist/`, `batch/runs/` and the downloaded `inputs/` (all ignored by Git).

## Check that nothing is left

```bash
aws cloudformation list-stacks --region "$AWS_REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?starts_with(StackName, '$PREFIX')].[StackName,StackStatus]" --output text
```

You should see no lines.
