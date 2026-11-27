[English](90-cleanup.md) | [한국어](90-cleanup.ko.md)

# 정리

스택을 삭제하면 시간당 요금(NAT gateway, interface endpoint, 놀고 있는 RaptGen-UI 호스트)이 멈춥니다. 보존된 데이터 삭제는 별도의 의도적인 단계입니다. 필요한 결과는 먼저 모두 저장하세요. S3 prefix, 로컬 폴더, job을 실행 단위로 정리하려면 [스토리지 가이드](../storage.ko.md#정리)를 보세요.

```bash
export AWS_REGION='<REGION>'
export PREFIX='aptamer-workflows'
```

## 1단계: 실행 중인 작업 멈추기

```bash
for q in "$PREFIX-batch-queue" "$PREFIX-batch-gpu-queue"; do
  for s in RUNNABLE STARTING RUNNING; do
    aws batch list-jobs --region "$AWS_REGION" --job-queue "$q" --job-status "$s" \
      --query 'jobSummaryList[].[jobId,jobName,status]' --output text 2>/dev/null
  done
done
aws omics list-runs --region "$AWS_REGION" --status RUNNING --query 'items[].[id,name,status]' --output text
```

아무 줄도 보이지 않아야 합니다. job이나 실행이 남아 있으면 끝날 때까지 기다리거나, ID를 하나씩 확인한 뒤 멈추세요(`aws batch terminate-job`, `aws omics cancel-run`).

## 2단계: RaptGen-UI 웹 gate 먼저 삭제 (만든 경우)

선택 사항인 웹 접속(`raptgen/ui-web`)은 **us-east-1**에 있는 CDK 스택이고 prefix에 속하지 않으므로 `scripts/cleanup.sh`가 지우지 않습니다. 그 CloudFront VPC origin이 공유 네트워크 안에 network interface와 보안 그룹 `CloudFront-VPCOrigins-Service-SG`를 두므로, UI 호스트와 네트워크보다 먼저 지워야 합니다. 그 보안 그룹이 남아 있으면 `scripts/cleanup.sh`는 메시지를 내고 멈춥니다.

```bash
export UI_WEB_STACK='RaptGenUiWeb'          # 사용한 gate 스택 이름
aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$PREFIX-raptgen-ui-origin-access"
aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$PREFIX-raptgen-ui-origin-access"
aws cloudformation delete-stack --region us-east-1 --stack-name "$UI_WEB_STACK"
aws cloudformation wait stack-delete-complete --region us-east-1 --stack-name "$UI_WEB_STACK"
```

CloudFront가 distribution을 먼저 비활성화하고 지우므로 gate 스택 삭제에는 시간이 걸립니다. Lambda@Edge 함수에서 `DELETE_FAILED`로 끝나면 CloudFront가 아직 복제본을 갖고 있는 것입니다. 기다린 뒤(검증 실행에서는 약 25분 뒤 재시도로 성공, 더 걸릴 수도 있음) 마지막 두 명령을 다시 실행하세요. 스택은 Cognito user pool(삭제 보호 켜짐), CloudFront 로그 버킷, 사용자 시크릿을 남깁니다. [raptgen/ui-web/README.ko.md](../../raptgen/ui-web/README.ko.md)를 보세요. 필요한 것을 저장한 뒤에만 지우세요 (로그 버킷에는 versioning이 없습니다).

```bash
aws cloudformation list-stack-resources --region us-east-1 --stack-name "$UI_WEB_STACK" \
  --query 'StackResourceSummaries[?ResourceStatus==`DELETE_SKIPPED`].[ResourceType,PhysicalResourceId]' --output text
aws cognito-idp update-user-pool --region us-east-1 --user-pool-id '<UserPoolId>' --deletion-protection INACTIVE
aws cognito-idp delete-user-pool --region us-east-1 --user-pool-id '<UserPoolId>'
aws s3 rm "s3://<LogBucket>" --recursive --region us-east-1 && aws s3api delete-bucket --bucket '<LogBucket>' --region us-east-1
aws secretsmanager delete-secret --region us-east-1 --secret-id '<UserSecretPrefix><username>' --force-delete-without-recovery
```

`list-stack-resources`는 스택이 남아 있는 동안(예: `DELETE_FAILED`)만 됩니다. 마지막 삭제 전에 ID를 적어 두세요.

RaptGen-UI 호스트(`<prefix>-raptgen-ui`), RaptGen job definition(`<prefix>-raptgen-jobs`), origin-access 스택은 3단계의 `scripts/cleanup.sh`가 지웁니다. UI의 모델은 호스트 디스크에 있으므로 함께 지워집니다.

## 3단계: 주요 스택 삭제

prefix에 해당하는 모든 스택을 역순(`raptgen-ui-origin-access`, `raptgen-ui`, `raptgen-jobs`, `healthomics-vpc`, `healthomics`, `batch`, `network`)으로 삭제합니다. 없는 스택은 건너뜁니다.

```bash
scripts/cleanup.sh --prefix "$PREFIX" --region "$AWS_REGION"
```

스크립트는 삭제할 스택 목록을 보여 주고 prefix를 입력하라고 묻습니다. 스택마다 `deleting <stack>`과 `<stack> deleted`가 보이고, 마지막에 `cleanup finished for prefix aptamer-workflows`와 보존된 리소스가 아직 남아 있다는 안내가 보여야 합니다.

일부 스택만, 예를 들어 HealthOmics만 삭제하려면:

```bash
scripts/cleanup.sh --prefix "$PREFIX" --region "$AWS_REGION" --stacks healthomics-vpc,healthomics
```

남아 있는 다른 스택이 쓰고 있는 스택은 삭제를 거부합니다. Batch, HealthOmics VPC, RaptGen-UI 스택이 있으면 네트워크를, origin-access 스택이 있으면 UI 호스트를, RaptGen job definition 스택이 있으면 Batch 스택을, 네트워크에 CloudFront VPC origin(웹 gate)이 남아 있으면 UI 호스트와 네트워크를 지우지 않습니다. `--configuration-by-script`로 HealthOmics configuration을 만들었다면 스크립트가 스택보다 먼저 지웁니다. HealthOmics와 Batch의 네트워크 인터페이스 때문에 서브넷과 security group 삭제가 늦어질 수 있습니다. 삭제가 실패하면 몇 분 기다렸다가 같은 명령을 다시 실행하세요.

`--yes`로 확인 질문을 건너뛸 수 있지만, 목록을 한 번 검토한 뒤 자동화에서만 쓰세요.

## 4단계 (선택): 보존된 데이터 삭제

템플릿은 스택을 삭제해도 S3 버킷, ECR 리포지토리, KMS 키, Batch 로그 그룹을 남겨 실수로 데이터를 잃지 않게 합니다. 그래도 요금은 나옵니다. 이것까지 지우려면 스택이 사라지기 **전에** 아래처럼 실행하세요(스크립트가 스택 출력에서 이름을 읽습니다).

```bash
scripts/cleanup.sh --prefix "$PREFIX" --region "$AWS_REGION" --delete-data
```

스크립트는 영구 삭제할 버킷, 리포지토리, 로그 그룹을 모두 보여 주고, 삭제 예약할 KMS 키 개수(7일 대기 기간)도 보여 줍니다. 버킷은 모든 객체 버전을 먼저 비웁니다. 되돌릴 수 없습니다.

스택이 이미 삭제됐다면 S3, ECR, KMS, CloudWatch Logs 콘솔에서 이름으로 보존된 리소스를 찾아 검토한 뒤 직접 삭제하세요.

## 5단계: HealthOmics 워크플로 삭제

등록한 private workflow는 어느 스택에도 속하지 않습니다. 만든 것을 나열하고 삭제하세요.

```bash
aws omics list-workflows --region "$AWS_REGION" --type PRIVATE --query 'items[].[id,name,status]' --output text
aws omics delete-workflow --region "$AWS_REGION" --id '<WORKFLOW_ID>'
```

실행 기록도 남습니다(`RETENTION_MODE=RETAIN`). 직접 시작한 실행과, 더 필요 없다면 공유 로그 그룹 `/aws/omics/WorkflowLog`의 해당 로그 스트림을 지우세요.

```bash
aws omics list-runs --region "$AWS_REGION" --query 'items[].[id,name,status]' --output text
aws omics delete-run --region "$AWS_REGION" --id '<RUN_ID>'
aws logs describe-log-streams --region "$AWS_REGION" --log-group-name /aws/omics/WorkflowLog \
  --log-stream-name-prefix 'run/<RUN_ID>' --query 'logStreams[].logStreamName' --output text
```

그다음 로컬 상태 `healthomics/.state/`, `healthomics/dist/`, `batch/runs/`, 내려받은 `inputs/`(모두 Git이 무시)를 지우세요.

## 남은 것이 없는지 확인

```bash
aws cloudformation list-stacks --region "$AWS_REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?starts_with(StackName, '$PREFIX')].[StackName,StackStatus]" --output text
```

아무 줄도 보이지 않아야 합니다.
