/**
 * Lambda@Edge viewer-request: Cognito login gate + role check for RaptGen-UI.
 *
 * Authentication: cognito-at-edge (hosted-UI code flow, PKCE + CSRF nonce on the callback).
 * Authorization:  the verified ID token's `cognito:groups` claim.
 *   raptgen-full      every method and path
 *   raptgen-readonly  GET/HEAD, plus the POST endpoints that only compute and never
 *                     write to the database (encode/decode/weblogo, job search)
 *   no group          denied
 *
 * Lambda@Edge has no environment variables: config comes from a Secrets Manager
 * secret in us-east-1. Every error fails CLOSED; the request is never forwarded.
 */
import { Authenticator } from 'cognito-at-edge';
import { CognitoJwtVerifier } from 'aws-jwt-verify';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import type { CloudFrontRequest, CloudFrontRequestEvent, CloudFrontRequestResult, CloudFrontResultResponse } from 'aws-lambda';

declare const __SECRET_ID__: string;

export const CALLBACK_PATH = 'oauth2/idpresponse';
export const FULL_GROUP = 'raptgen-full';
export const READONLY_GROUP = 'raptgen-readonly';

/** POST endpoints a read-only user may call: pure computation, no DB writes. */
export const READONLY_POST = new Set([
  '/api/session/encode',
  '/api/session/decode',
  '/api/session/decode/weblogo',
  '/api/session/decode/weblogo-map',
  '/api/train/jobs/search',
  '/api/gmm/jobs/search',
]);

/** Paths nobody needs through the public front door. */
const BLOCKED_PREFIXES = ['/_next/image']; // Next 13.1 image optimizer (known DoS issues); the app does not use it

interface EdgeConfig {
  region: string;
  userPoolId: string;
  clientId: string;
  domain: string;
  nonceSigningSecret: string;
}

type Loaded = { auth: Authenticator; cfg: EdgeConfig; verifier: { verify(t: string): Promise<Record<string, unknown>> } };

const sm = new SecretsManagerClient({ region: 'us-east-1' });
let loaded: Promise<Loaded> | undefined;

async function load(): Promise<Loaded> {
  const out = await sm.send(new GetSecretValueCommand({ SecretId: __SECRET_ID__ }));
  const c = JSON.parse(out.SecretString ?? '{}') as Partial<EdgeConfig>;
  if (!c.region || !c.userPoolId || !c.clientId || !c.domain || !c.nonceSigningSecret) {
    throw new Error('edge auth config incomplete');
  }
  const cfg = c as EdgeConfig;
  const auth = new Authenticator({
    region: cfg.region,
    userPoolId: cfg.userPoolId,
    userPoolAppId: cfg.clientId,
    userPoolDomain: cfg.domain,
    parseAuthPath: CALLBACK_PATH,
    cookieExpirationDays: 1,
    cookiePath: '/',
    httpOnly: true,
    sameSite: 'Lax',
    logLevel: 'warn',
    csrfProtection: { nonceSigningSecret: cfg.nonceSigningSecret },
  });
  const verifier = CognitoJwtVerifier.create({ userPoolId: cfg.userPoolId, tokenUse: 'id', clientId: cfg.clientId });
  return { auth, cfg, verifier: verifier as unknown as Loaded['verifier'] };
}

const NO_STORE = [{ key: 'Cache-Control', value: 'no-cache, no-store, max-age=0, must-revalidate' }];

function deny(status: string, text: string): CloudFrontResultResponse {
  return {
    status,
    headers: {
      'content-type': [{ key: 'Content-Type', value: 'text/plain; charset=utf-8' }],
      'cache-control': NO_STORE,
    },
    body: text,
  };
}

export function fixLocation(res: CloudFrontRequestResult, host: string): CloudFrontRequestResult {
  const r = res as CloudFrontResultResponse;
  const loc = r?.headers?.location?.[0]?.value;
  if (r?.status === '302' && loc && loc.startsWith(`https://${host}/https://`)) {
    r.headers!.location = [{ key: 'Location', value: `https://${host}/` }];
  }
  return res;
}

/** The ID token cookie cognito-at-edge sets: CognitoIdentityServiceProvider.<clientId>.<user>.idToken */
export function idTokenFromCookies(req: CloudFrontRequest, clientId: string): string | undefined {
  const prefix = `CognitoIdentityServiceProvider.${clientId}.`;
  for (const h of req.headers.cookie ?? []) {
    for (const part of h.value.split(';')) {
      const i = part.indexOf('=');
      if (i < 0) continue;
      const name = part.slice(0, i).trim();
      if (name.startsWith(prefix) && name.endsWith('.idToken')) return part.slice(i + 1).trim();
    }
  }
  return undefined;
}

export function isAllowed(groups: string[], method: string, uri: string): boolean {
  if (BLOCKED_PREFIXES.some((p) => uri.startsWith(p))) return false;
  if (groups.includes(FULL_GROUP)) return true;
  if (groups.includes(READONLY_GROUP)) {
    if (method === 'GET' || method === 'HEAD') return true;
    if (method === 'POST') return READONLY_POST.has(uri);
    return false;
  }
  return false;
}

function isResponse(r: CloudFrontRequestResult): r is CloudFrontResultResponse {
  return !!r && 'status' in r;
}

export const handler = async (event: CloudFrontRequestEvent): Promise<CloudFrontRequestResult> => {
  try {
    loaded ??= load();
    const { auth, cfg, verifier } = await loaded;
    const req = event.Records[0].cf.request;
    const host = req.headers.host[0].value;

    if (req.uri === `/${CALLBACK_PATH}`) {
      const res = (await auth.handleParseAuth(event)) as CloudFrontResultResponse;
      if (res.status !== '302') return deny('400', 'Sign-in failed. Please start again from the site address.');
      return fixLocation(res, host);
    }

    if (req.uri === '/logout') {
      const cognitoLogout =
        `https://${cfg.domain}/logout?client_id=${encodeURIComponent(cfg.clientId)}` +
        `&logout_uri=${encodeURIComponent(`https://${host}/`)}`;
      const res: CloudFrontResultResponse = req.headers.cookie
        ? ((await auth.handleSignOut(event)) as CloudFrontResultResponse)
        : { status: '302', headers: {} };
      res.status = '302';
      res.headers = { ...(res.headers ?? {}), location: [{ key: 'Location', value: cognitoLogout }], 'cache-control': NO_STORE };
      return res;
    }

    if (/(^|&)(code|state)=/.test(req.querystring)) req.querystring = '';
    const result = await auth.handle(event);
    if (isResponse(result)) return fixLocation(result, host); // not signed in -> login redirect

    // Signed in: check the role on the verified ID token.
    const token = idTokenFromCookies(req, cfg.clientId);
    if (!token) return deny('403', 'Forbidden.');
    let groups: string[] = [];
    try {
      const claims = await verifier.verify(token);
      const g = claims['cognito:groups'];
      groups = Array.isArray(g) ? g.map(String) : [];
    } catch {
      return deny('403', 'Forbidden.');
    }
    if (!isAllowed(groups, req.method, req.uri)) {
      return deny('403', groups.includes(READONLY_GROUP)
        ? 'Read-only account: this action is not allowed.'
        : 'Forbidden.');
    }
    // The origin does not use cookies; do not forward tokens to it.
    delete req.headers.cookie;
    return req;
  } catch (err) {
    loaded = undefined;
    console.error('edge auth failure', (err as Error).message);
    return deny('503', 'Temporarily unavailable.');
  }
};
