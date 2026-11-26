[English](README.md) | [한국어](README.ko.md)

# RaptGen-UI web access (CloudFront + Cognito, two roles)

Optional. Without it, use the private SSM port forward in [`../ui`](../ui/README.md). Step-by-step guide: [Web access](../../docs/raptgen/ui-web.md).

```
Browser -HTTPS-> CloudFront -> Lambda@Edge (Cognito login + role check, fail-closed)
                                  |
                                  v
        VPC origin (CloudFront ENI in a private subnet) -HTTP:18042-> UI EC2 (no public IP)
                                              RaptGen-UI frontend -> backend / worker / db / redis
```

## Security warning

- **RaptGen-UI has no per-user data.** Every `raptgen-full` user sees and can delete every model.
  Give the full role only to people who may do that. Use `raptgen-readonly` for everyone else.
- The site is reachable from the internet behind the Cognito login. Create users only after
  `scripts/verify-gate.sh` passes. Self sign-up is off; users are created by an admin.
- The CloudFront to EC2 hop is HTTP inside the VPC (VPC origin). The browser side is HTTPS.
- Use public or non-sensitive sequence data only.
- The UI must listen on the instance **private IP**, not on loopback, so CloudFront can reach it.
  Install the UI with `../ui/install.sh --bind-private-ip` (the compose patch reads `UI_BIND_ADDR`).
  Loopback-only installs (the default) are not reachable from CloudFront.

## Roles (enforced at the edge on the verified ID token)

| | `raptgen-full` | `raptgen-readonly` |
|---|---|---|
| Open pages, list models/jobs | yes | yes |
| Encode / decode / weblogo in Viewer | yes | yes |
| Upload, VAE/GMM training, publish | yes | 403 |
| Bayesian optimization | yes | 403 |
| Rename / delete | yes | 403 |
| No group | 403 | 403 |

`/_next/image` is blocked for everyone (Next 13.1 image optimizer, unused). Every error in the
edge function fails closed (503), the request is never forwarded.

## Deploy (order matters)

Prerequisites: Node.js 22+, AWS CDK bootstrapped in **us-east-1** (Lambda@Edge needs it),
the UI host from `../ui/ec2.yaml`, and its outputs `InstanceArn`, `PrivateDnsName`, `SecurityGroupId`.

```bash
cd raptgen/ui-web
npm install
npx tsx --test edge/authz.test.ts          # role-check unit tests

export UI_WEB_STACK=RaptGenUiWeb   # stack name (default); every script below reads it
# 1. deploy the gate (edge bundle + CloudFront + Cognito)
npm run deploy -- \
  -c originInstanceArn=<InstanceArn> \
  -c originPrivateDns=<PrivateDnsName> \
  [-c originPort=18042] [-c cognitoDomainPrefix=<unique-prefix>]

# 2. prove anonymous access is denied. Must pass before step 3.
scripts/verify-gate.sh

# 3. open the EC2 security group to the CloudFront VPC origin only
#    (CloudFrontVpcOriginSecurityGroupId = group "CloudFront-VPCOrigins-Service-SG" in the VPC of the UI host)
aws cloudformation deploy --region <UI-HOST-REGION> --stack-name <prefix>-raptgen-ui-origin-access \
  --template-file origin-access.yaml \
  --parameter-overrides UiSecurityGroupId=<SecurityGroupId> CloudFrontVpcOriginSecurityGroupId=<sg-id>

# 4. create users (random password stored in Secrets Manager, never printed)
scripts/add-user.sh <username> full|readonly
```

Parameters come from CDK context, `UI_WEB_STACK` and your AWS CLI configuration. No account, instance
or domain is hard-coded; the gate is always in `us-east-1` (Lambda@Edge). The stack name (`UI_WEB_STACK`
or `-c stackName=...`, default `RaptGenUiWeb`) sets the other names, see `lib/names.ts` and
`scripts/names.sh`: secrets under `/raptgen-ui-web/` for the default stack, else `/<stack name in lower
case>/`; the user pool and app client take the same name. The edge bundle has the secret name baked in,
so `bin/app.ts` refuses a bundle built for another stack. If `cognitoDomainPrefix` is not given, a
stable value derived from the account (and the stack name, if not the default) is used. Passwords are
in Secrets Manager `<UserSecretPrefix output><username>` (us-east-1). The site URL is the `SiteUrl` output.

## Test through the front door

```bash
npx playwright install chromium
SITE_URL=https://<SiteUrl> FULL_USER=... FULL_PW_FILE=... RO_USER=... RO_PW_FILE=... \
FASTQ=<RAPT1_4R.fastq> SHOT_DIR=./shots npm run e2e
```

## Close the door

1. Delete the `origin-access` stack (removes the only ingress rule).
2. Or disable the CloudFront distribution.
3. Remove a user: `aws cognito-idp admin-delete-user --region us-east-1 --user-pool-id <UserPoolId> --username <name>`.
4. `aws cloudformation delete-stack --region us-east-1 --stack-name "$UI_WEB_STACK"` removes the gate (a first
   attempt can fail on the Lambda@Edge function while CloudFront still holds replicas; retry later). The user
   pool, logging bucket and user secrets are retained; delete them by hand.

## Files

| File | Purpose |
|---|---|
| `bin/app.ts`, `lib/stack.ts` | CDK app: CloudFront, VPC origin, Cognito pool/groups, Lambda@Edge, log bucket |
| `edge/index.ts`, `edge/authz.test.ts` | login gate and role rules, with tests |
| `scripts/build-edge.mjs` | bundles the edge function into `edge/dist` (gitignored) |
| `scripts/verify-gate.sh` | anonymous-denial checks; exit 1 on any failure |
| `scripts/add-user.sh` | create a user in a role group |
| `scripts/e2e-roles.ts` | Playwright test of both roles |
| `origin-access.yaml` | the single security-group ingress rule |
