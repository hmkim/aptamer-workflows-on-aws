// Run: npx tsx --test edge/authz.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isAllowed, idTokenFromCookies, FULL_GROUP, READONLY_GROUP } from './index.js';

test('full group may do everything except blocked paths', () => {
  for (const m of ['GET', 'POST', 'PUT', 'PATCH', 'DELETE']) assert.equal(isAllowed([FULL_GROUP], m, '/api/train/jobs/submit'), true);
  assert.equal(isAllowed([FULL_GROUP], 'GET', '/_next/image?url=x'), false);
});

test('read-only group: GET yes, compute-only POST yes, writes no', () => {
  const ro = [READONLY_GROUP];
  assert.equal(isAllowed(ro, 'GET', '/viewer'), true);
  assert.equal(isAllowed(ro, 'GET', '/api/data/VAE-model-names'), true);
  assert.equal(isAllowed(ro, 'POST', '/api/session/encode'), true);
  assert.equal(isAllowed(ro, 'POST', '/api/session/decode/weblogo'), true);
  for (const p of ['/api/train/jobs/submit', '/api/gmm/jobs/submit', '/api/upload/upload-vae',
    '/api/train/jobs/publish', '/api/bayesopt/submit', '/api/bayesopt/run', '/api/session/encode/x']) {
    assert.equal(isAllowed(ro, 'POST', p), false, p);
  }
  assert.equal(isAllowed(ro, 'DELETE', '/api/data/items/abc'), false);
  assert.equal(isAllowed(ro, 'PATCH', '/api/train/jobs/items/abc'), false);
  assert.equal(isAllowed(ro, 'PUT', '/api/bayesopt/items/abc'), false);
});

test('no group or unknown group: denied', () => {
  assert.equal(isAllowed([], 'GET', '/'), false);
  assert.equal(isAllowed(['other'], 'GET', '/'), false);
});

test('id token cookie lookup is scoped to the client id', () => {
  const req = { headers: { cookie: [{ key: 'Cookie', value:
    'a=1; CognitoIdentityServiceProvider.other.u.idToken=bad; CognitoIdentityServiceProvider.cid.u.idToken=good; x=y' }] } };
  assert.equal(idTokenFromCookies(req as never, 'cid'), 'good');
  assert.equal(idTokenFromCookies({ headers: {} } as never, 'cid'), undefined);
});
