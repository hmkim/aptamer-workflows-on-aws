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

## Step 2: Remove the RaptGen stacks first (if you created them)

`scripts/cleanup.sh` does not know about the RaptGen stacks. Delete them first, in this order, because the RaptGen-UI host lives in the shared network:

1. Optional web access (`raptgen/ui-web`): delete the `<prefix>-raptgen-ui-origin-access` stack, then run `npx cdk destroy` in `raptgen/ui-web`. See [raptgen/ui-web/README.md](../../raptgen/ui-web/README.md#close-the-door) for the resources it retains.
2. The RaptGen-UI host and the RaptGen job definitions:

```bash
for s in "$PREFIX-raptgen-ui" "$PREFIX-raptgen-jobs"; do
  aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$s"
  aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$s"
done
```

Use the stack names you chose when you deployed them; these are the names used in [raptgen/README.md](../../raptgen/README.md). Deleting a stack that does not exist is not an error.

## Step 3: Delete the main stacks

Everything for the prefix, in reverse order (`healthomics-vpc`, `healthomics`, `batch`, `network`):

```bash
scripts/cleanup.sh --prefix "$PREFIX" --region "$AWS_REGION"
```

The script lists the stacks it will delete and asks you to type the prefix. You should see `deleting <stack>` and `<stack> deleted` for each, then `cleanup finished for prefix aptamer-workflows` and a reminder that retained resources still exist.

Only some stacks, for example HealthOmics only:

```bash
scripts/cleanup.sh --prefix "$PREFIX" --region "$AWS_REGION" --stacks healthomics-vpc,healthomics
```

The script refuses to delete the network while the Batch or HealthOmics VPC stack still uses it. If you created the HealthOmics configuration with `--configuration-by-script`, the script deletes it before the stack. HealthOmics and Batch network interfaces can delay subnet and security group deletion; if a delete fails, wait a few minutes and run the command again.

Use `--yes` to skip the prompt in automation only after you have reviewed the list once.

## Step 4 (optional): Delete retained data

The templates keep S3 buckets, ECR repositories, KMS keys, and the Batch log group when a stack is deleted, so data is not lost by accident. They still cost money. To delete them as well, run the cleanup **before** the stacks are gone (the script reads the names from the stack outputs):

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

Then remove the local state: `healthomics/.state/` and `batch/runs/` (both ignored by Git).

## Check that nothing is left

```bash
aws cloudformation list-stacks --region "$AWS_REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?starts_with(StackName, '$PREFIX')].[StackName,StackStatus]" --output text
```

You should see no lines.
