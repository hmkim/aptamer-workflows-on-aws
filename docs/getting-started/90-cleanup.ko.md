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

## 2단계: RaptGen 스택 먼저 삭제 (만든 경우)

`scripts/cleanup.sh`는 RaptGen 스택을 모릅니다. RaptGen-UI 호스트가 공유 네트워크 안에 있으므로, 아래 순서대로 먼저 삭제하세요.

1. 선택 사항인 웹 접속(`raptgen/ui-web`): `<prefix>-raptgen-ui-origin-access` 스택을 삭제한 다음 `raptgen/ui-web`에서 `npx cdk destroy`를 실행하세요. 남는 리소스는 [raptgen/ui-web/README.ko.md](../../raptgen/ui-web/README.ko.md)를 보세요.
2. RaptGen-UI 호스트와 RaptGen job definition:

```bash
for s in "$PREFIX-raptgen-ui" "$PREFIX-raptgen-jobs"; do
  aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$s"
  aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$s"
done
```

배포할 때 정한 스택 이름을 쓰세요. 위 이름은 [raptgen/README.ko.md](../../raptgen/README.ko.md)에서 쓰는 이름입니다. 없는 스택을 삭제해도 오류가 아닙니다.

## 3단계: 주요 스택 삭제

prefix에 해당하는 모든 스택을 역순(`healthomics-vpc`, `healthomics`, `batch`, `network`)으로 삭제합니다.

```bash
scripts/cleanup.sh --prefix "$PREFIX" --region "$AWS_REGION"
```

스크립트는 삭제할 스택 목록을 보여 주고 prefix를 입력하라고 묻습니다. 스택마다 `deleting <stack>`과 `<stack> deleted`가 보이고, 마지막에 `cleanup finished for prefix aptamer-workflows`와 보존된 리소스가 아직 남아 있다는 안내가 보여야 합니다.

일부 스택만, 예를 들어 HealthOmics만 삭제하려면:

```bash
scripts/cleanup.sh --prefix "$PREFIX" --region "$AWS_REGION" --stacks healthomics-vpc,healthomics
```

Batch나 HealthOmics VPC 스택이 아직 네트워크를 쓰고 있으면 스크립트는 네트워크 삭제를 거부합니다. `--configuration-by-script`로 HealthOmics configuration을 만들었다면 스크립트가 스택보다 먼저 지웁니다. HealthOmics와 Batch의 네트워크 인터페이스 때문에 서브넷과 security group 삭제가 늦어질 수 있습니다. 삭제가 실패하면 몇 분 기다렸다가 같은 명령을 다시 실행하세요.

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

그다음 로컬 상태 `healthomics/.state/`와 `batch/runs/`(둘 다 Git이 무시)를 지우세요.

## 남은 것이 없는지 확인

```bash
aws cloudformation list-stacks --region "$AWS_REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?starts_with(StackName, '$PREFIX')].[StackName,StackStatus]" --output text
```

아무 줄도 보이지 않아야 합니다.
