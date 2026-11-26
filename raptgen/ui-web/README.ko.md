[English](README.md) | [한국어](README.ko.md)

# RaptGen-UI 웹 접속 (CloudFront + Cognito, 두 가지 역할)

선택 사항입니다. 사용하지 않으면 [`../ui`](../ui/README.ko.md)의 사설 SSM 포트 포워딩을 쓰세요. 단계별 가이드: [웹 접속](../../docs/raptgen/ui-web.ko.md).

```
브라우저 -HTTPS-> CloudFront -> Lambda@Edge (Cognito 로그인 + 역할 확인, fail-closed)
                                   |
                                   v
         VPC origin (private subnet의 CloudFront ENI) -HTTP:18042-> UI EC2 (public IP 없음)
                                               RaptGen-UI frontend -> backend / worker / db / redis
```

## 보안 경고

- **RaptGen-UI에는 사용자별 데이터 구분이 없습니다.** `raptgen-full` 사용자는 모두 모든 모델을 보고 삭제할 수 있습니다. full 역할은 그래도 되는 사람에게만 주고, 나머지는 `raptgen-readonly`를 쓰세요.
- 사이트는 Cognito 로그인 뒤에서 인터넷에 접근할 수 있게 됩니다. `scripts/verify-gate.sh`가 통과한 뒤에만 사용자를 만드세요. 직접 가입은 꺼져 있고, 사용자는 관리자가 만듭니다.
- CloudFront에서 EC2까지는 VPC 안의 HTTP입니다 (VPC origin). 브라우저 쪽은 HTTPS입니다.
- 공개 데이터 또는 민감하지 않은 서열 데이터만 사용하세요.
- UI는 loopback이 아니라 인스턴스 **private IP**에서 listen해야 CloudFront가 닿을 수 있습니다. `../ui/install.sh --bind-private-ip`로 설치하세요 (compose 패치가 `UI_BIND_ADDR`를 읽습니다). 기본값인 loopback 설치에는 CloudFront가 닿지 못합니다.

## 역할 (검증된 ID 토큰을 기준으로 edge에서 강제)

| | `raptgen-full` | `raptgen-readonly` |
|---|---|---|
| 페이지 열기, 모델/job 목록 | 가능 | 가능 |
| Viewer의 encode / decode / weblogo | 가능 | 가능 |
| 업로드, VAE/GMM 학습, 모델 등록 | 가능 | 403 |
| Bayesian optimization | 가능 | 403 |
| 이름 변경 / 삭제 | 가능 | 403 |
| 그룹 없음 | 403 | 403 |

`/_next/image`는 모두에게 막혀 있습니다 (Next 13.1 이미지 최적화, 사용하지 않음). edge 함수의 모든 오류는 fail-closed(503)로 처리되며 요청은 전달되지 않습니다.

## 배포 (순서가 중요)

사전 준비: Node.js 22 이상, **us-east-1**에 bootstrap된 AWS CDK (Lambda@Edge에 필요), `../ui/ec2.yaml`로 만든 UI 호스트와 그 output `InstanceArn`, `PrivateDnsName`, `SecurityGroupId`.

```bash
cd raptgen/ui-web
npm install
npx tsx --test edge/authz.test.ts          # 역할 규칙 단위 테스트

export UI_WEB_STACK=RaptGenUiWeb   # 스택 이름 (기본값). 아래 스크립트가 모두 읽습니다
# 1. gate 배포 (edge bundle + CloudFront + Cognito)
npm run deploy -- \
  -c originInstanceArn=<InstanceArn> \
  -c originPrivateDns=<PrivateDnsName> \
  [-c originPort=18042] [-c cognitoDomainPrefix=<unique-prefix>]

# 2. 익명 접근이 거부되는지 확인. 3단계 전에 반드시 통과해야 합니다.
scripts/verify-gate.sh

# 3. EC2 보안 그룹을 CloudFront VPC origin에만 열기
#    (CloudFrontVpcOriginSecurityGroupId = UI 호스트 VPC의 "CloudFront-VPCOrigins-Service-SG" 그룹)
aws cloudformation deploy --region <UI-HOST-REGION> --stack-name <prefix>-raptgen-ui-origin-access \
  --template-file origin-access.yaml \
  --parameter-overrides UiSecurityGroupId=<SecurityGroupId> CloudFrontVpcOriginSecurityGroupId=<sg-id>

# 4. 사용자 만들기 (임의 비밀번호는 Secrets Manager에 저장, 출력하지 않음)
scripts/add-user.sh <username> full|readonly
```

파라미터는 CDK context, `UI_WEB_STACK`, AWS CLI 설정에서 옵니다. 계정, 인스턴스, 도메인은 코드에 박혀 있지 않고, gate는 항상 `us-east-1`에 있습니다 (Lambda@Edge). 스택 이름(`UI_WEB_STACK` 또는 `-c stackName=...`, 기본값 `RaptGenUiWeb`)이 다른 이름을 정합니다 (`lib/names.ts`, `scripts/names.sh`). 기본 스택의 시크릿은 `/raptgen-ui-web/` 아래, 다른 이름이면 `/<소문자 스택 이름>/` 아래에 있고, user pool과 app client도 같은 이름을 씁니다. edge bundle에는 시크릿 이름이 들어가므로 `bin/app.ts`는 다른 스택용으로 빌드된 bundle을 거부합니다. `cognitoDomainPrefix`를 주지 않으면 계정(기본 이름이 아니면 스택 이름도)에서 계산한 안정적인 값이 쓰입니다. 비밀번호는 Secrets Manager `<UserSecretPrefix output><username>`(us-east-1)에 있습니다. 사이트 주소는 스택 output `SiteUrl`입니다.

## 정문으로 테스트

```bash
npx playwright install chromium
SITE_URL=https://<SiteUrl> FULL_USER=... FULL_PW_FILE=... RO_USER=... RO_PW_FILE=... \
FASTQ=<RAPT1_4R.fastq> SHOT_DIR=./shots npm run e2e
```

## 접속 닫기

1. `origin-access` 스택을 지웁니다 (유일한 인바운드 규칙이 사라집니다).
2. 또는 CloudFront distribution을 비활성화합니다.
3. 사용자 삭제: `aws cognito-idp admin-delete-user --region us-east-1 --user-pool-id <UserPoolId> --username <name>`.
4. `aws cloudformation delete-stack --region us-east-1 --stack-name "$UI_WEB_STACK"`로 gate를 지웁니다 (CloudFront가 Lambda@Edge 복제본을 아직 갖고 있으면 첫 시도는 실패할 수 있으니 나중에 다시 실행). user pool, 로그 버킷, 사용자 시크릿은 보존되므로 직접 지우세요.

## 파일

| 파일 | 용도 |
|---|---|
| `bin/app.ts`, `lib/stack.ts` | CDK 앱: CloudFront, VPC origin, Cognito pool/group, Lambda@Edge, 로그 버킷 |
| `edge/index.ts`, `edge/authz.test.ts` | 로그인 gate와 역할 규칙, 테스트 포함 |
| `scripts/build-edge.mjs` | edge 함수를 `edge/dist`로 bundle (gitignore됨) |
| `scripts/verify-gate.sh` | 익명 접근 거부 확인. 하나라도 실패하면 exit 1 |
| `scripts/add-user.sh` | 역할 그룹에 사용자 만들기 |
| `scripts/e2e-roles.ts` | 두 역할의 Playwright 테스트 |
| `origin-access.yaml` | 보안 그룹 인바운드 규칙 하나 |
