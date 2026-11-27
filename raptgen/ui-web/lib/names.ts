/**
 * Names derived from the stack name, shared by the CDK app and the edge build.
 * Keep in sync with scripts/names.sh.
 *
 *   stack name   -c stackName=<name> or UI_WEB_STACK=<name>; default RaptGenUiWeb
 *   Region       always us-east-1 (Lambda@Edge and its config secret must live there)
 *   name prefix  "raptgen-ui-web" for the default stack, else the stack name in lower case
 *   secrets      /<prefix>/edge-auth, /<prefix>/users/<username>
 */
import { createHash } from 'node:crypto';

export const DEFAULT_STACK_NAME = 'RaptGenUiWeb';
export const UI_WEB_REGION = 'us-east-1';

export function checkStackName(name: string): string {
  if (!/^[A-Za-z][A-Za-z0-9-]{0,39}$/.test(name)) {
    throw new Error('stackName: 1-40 letters, digits, hyphens, starting with a letter');
  }
  return name;
}

export function namePrefix(stackName: string): string {
  return stackName === DEFAULT_STACK_NAME ? 'raptgen-ui-web' : checkStackName(stackName).toLowerCase();
}

export const edgeSecretId = (stackName: string): string => `/${namePrefix(stackName)}/edge-auth`;

/** Default Cognito domain prefix: unique per account and stack, stable across deploys. */
export function defaultCognitoDomainPrefix(stackName: string, account: string): string {
  if (stackName === DEFAULT_STACK_NAME) {
    return `raptgen-ui-${createHash('sha256').update(account).digest('hex').slice(0, 10)}`;
  }
  const hash = createHash('sha256').update(`${account}/${stackName}`).digest('hex').slice(0, 10);
  return `${namePrefix(stackName).slice(0, 40).replace(/-+$/, '')}-${hash}`;
}
