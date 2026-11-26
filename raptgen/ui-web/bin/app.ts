import { App } from 'aws-cdk-lib';
import { readFileSync } from 'node:fs';
import { RaptGenUiWebStack } from '../lib/stack.js';
import { DEFAULT_STACK_NAME, UI_WEB_REGION, checkStackName, defaultCognitoDomainPrefix, edgeSecretId, namePrefix } from '../lib/names.js';

const app = new App();

const need = (key: string): string => {
  const v = app.node.tryGetContext(key);
  if (typeof v !== 'string' || v === '') {
    throw new Error(`missing CDK context "${key}": pass -c ${key}=... (see README.md)`);
  }
  return v;
};

// Origin = the private RaptGen-UI EC2 host (raptgen/ui/ec2.yaml outputs). It may live in any Region.
const originInstanceArn = need('originInstanceArn');
const originPrivateDns = need('originPrivateDns');
const originPort = Number(app.node.tryGetContext('originPort') ?? 18042);
if (!/^arn:aws[a-z-]*:ec2:[a-z0-9-]+:\d{12}:instance\/i-[0-9a-f]+$/.test(originInstanceArn)) {
  throw new Error('originInstanceArn must be an EC2 instance ARN');
}
if (!Number.isInteger(originPort) || originPort < 1 || originPort > 65535) throw new Error('bad originPort');

// The account comes from your AWS CLI configuration (CDK resolves it).
const account = process.env.CDK_DEFAULT_ACCOUNT;
if (!account) throw new Error('cannot resolve the AWS account: configure the AWS CLI and run through `cdk`');

// Stack name: -c stackName=... or UI_WEB_STACK=... (default RaptGenUiWeb). Use a new name for a second,
// independent gate. Secret names, the Cognito pool and the default domain prefix derive from it.
const ctxStack = app.node.tryGetContext('stackName') as string | undefined;
const envStack = process.env.UI_WEB_STACK || undefined;
if (ctxStack && envStack && ctxStack !== envStack) {
  throw new Error(`stackName context (${ctxStack}) and UI_WEB_STACK (${envStack}) differ`);
}
const stackName = checkStackName(ctxStack ?? envStack ?? DEFAULT_STACK_NAME);
const secretId = edgeSecretId(stackName);

// The edge bundle has the secret ID baked in; refuse to deploy a bundle built for another stack.
let built: { stackName?: string; secretId?: string } = {};
try { built = JSON.parse(readFileSync(new URL('../edge/dist/build-info.json', import.meta.url), 'utf8')); } catch { /* checked below */ }
if (built.secretId !== secretId) {
  throw new Error(`edge/dist was built for stack "${built.stackName ?? '?'}", not "${stackName}": ` +
    `run UI_WEB_STACK=${stackName} npm run build:edge (npm run deploy does this when UI_WEB_STACK is set)`);
}

// Cognito domain prefixes are unique per Region. Supply one, or a stable value derived from the account
// (and the stack name, for a non-default stack) is used.
const cognitoDomainPrefix: string =
  (app.node.tryGetContext('cognitoDomainPrefix') as string | undefined) ??
  defaultCognitoDomainPrefix(stackName, account);
if (!/^[a-z0-9][a-z0-9-]{2,62}$/.test(cognitoDomainPrefix) || /aws|amazon|cognito/.test(cognitoDomainPrefix)) {
  throw new Error('cognitoDomainPrefix: lowercase letters, digits, hyphens; must not contain aws, amazon or cognito');
}

// Cognito MFA (TOTP): -c cognitoMfa=REQUIRED|OPTIONAL, default OPTIONAL. Use REQUIRED for real users;
// Cognito accepts REQUIRED only when the user pool is created. See README.md.
const cognitoMfa = String(app.node.tryGetContext('cognitoMfa') ?? 'OPTIONAL').toUpperCase();
if (cognitoMfa !== 'OPTIONAL' && cognitoMfa !== 'REQUIRED') throw new Error('cognitoMfa must be OPTIONAL or REQUIRED');

new RaptGenUiWebStack(app, stackName, {
  // Lambda@Edge must live in us-east-1.
  env: { account, region: UI_WEB_REGION },
  description: 'RaptGen-UI: CloudFront + Cognito gate (full / read-only) -> VPC origin -> private EC2',
  originInstanceArn,
  originPrivateDns,
  originPort,
  cognitoDomainPrefix,
  secretId,
  namePrefix: namePrefix(stackName),
  cognitoMfa,
});
