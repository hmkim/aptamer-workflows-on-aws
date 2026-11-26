import { App } from 'aws-cdk-lib';
import { createHash } from 'node:crypto';
import { RaptGenUiWebStack } from '../lib/stack.js';

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

// Cognito domain prefixes are unique per Region. Supply one, or a stable suffix derived from the account is used.
const cognitoDomainPrefix: string =
  (app.node.tryGetContext('cognitoDomainPrefix') as string | undefined) ??
  `raptgen-ui-${createHash('sha256').update(account).digest('hex').slice(0, 10)}`;
if (!/^[a-z0-9][a-z0-9-]{2,62}$/.test(cognitoDomainPrefix) || /aws|amazon|cognito/.test(cognitoDomainPrefix)) {
  throw new Error('cognitoDomainPrefix: lowercase letters, digits, hyphens; must not contain aws, amazon or cognito');
}

new RaptGenUiWebStack(app, 'RaptGenUiWeb', {
  // Lambda@Edge must live in us-east-1.
  env: { account, region: 'us-east-1' },
  description: 'RaptGen-UI: CloudFront + Cognito gate (full / read-only) -> VPC origin -> private EC2',
  originInstanceArn,
  originPrivateDns,
  originPort,
  cognitoDomainPrefix,
});
