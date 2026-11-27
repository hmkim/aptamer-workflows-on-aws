/**
 * End-to-end test through the public front door (CloudFront -> Cognito -> RaptGen-UI).
 *  1. full user:     sign in on the hosted UI, then VAE training on the public RAPT1 sample,
 *                    publish, GMM, Bayesian optimization, decode candidates, screenshots.
 *  2. read-only user: sign in, view + encode/decode allowed; train/upload/delete/BO denied (403).
 *  3. logout returns to the login.
 * Env: SITE_URL, FULL_USER, FULL_PW_FILE, RO_USER, RO_PW_FILE, FASTQ, SHOT_DIR, EPOCHS (default 10)
 * Passwords are read from files and never printed.
 */
import { chromium, type Page, type APIRequestContext } from 'playwright';
import { readFileSync, mkdirSync } from 'node:fs';

const site = process.env.SITE_URL!;
const shots = process.env.SHOT_DIR ?? '.';
const epochs = Number(process.env.EPOCHS ?? '10');
mkdirSync(shots, { recursive: true });
const t0 = Date.now();
const log = (step: string, v: unknown) =>
  console.log(`[${((Date.now() - t0) / 1000).toFixed(1).padStart(6)}s] ${step}: ${typeof v === 'string' ? v : JSON.stringify(v)}`);
let failures = 0;
const expect = (ok: boolean, what: string) => { log(ok ? 'PASS' : 'FAIL', what); if (!ok) failures++; };

async function signIn(page: Page, user: string, pwFile: string) {
  await page.goto(site);
  await page.waitForURL(/amazoncognito\.com/);
  await page.locator('input[name="username"]:visible').fill(user);
  await page.locator('input[name="password"]:visible').fill(readFileSync(pwFile, 'utf8').trim());
  await page.locator('input[name="signInSubmitButton"]:visible').click();
  await page.waitForURL((u) => u.host === new URL(site).host, { timeout: 30000 });
  await page.waitForLoadState('networkidle');
}

async function j(r: APIRequestContext, method: 'GET' | 'POST' | 'DELETE' | 'PATCH', path: string, data?: unknown) {
  const res = await r.fetch(site + path, { method, data, timeout: 120000 });
  const txt = await res.text();
  let body: any = txt;
  try { body = txt ? JSON.parse(txt) : null; } catch { /* text */ }
  return { status: res.status(), body };
}

async function poll(r: APIRequestContext, path: string, done: (b: any) => boolean, everyMs = 15000, limitMs = 3600000) {
  const start = Date.now();
  while (Date.now() - start < limitMs) {
    const { status, body } = await j(r, 'GET', path);
    if (status === 200 && done(body)) return body;
    await new Promise((s) => setTimeout(s, everyMs));
  }
  throw new Error(`timeout ${path}`);
}

const browser = await chromium.launch();

// ───────────── 1. full user ─────────────
{
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await signIn(page, process.env.FULL_USER!, process.env.FULL_PW_FILE!);
  log('full.signin', new URL(page.url()).host);
  await page.screenshot({ path: `${shots}/web-01-full-home.png` });
  const r = ctx.request;

  const models = await j(r, 'GET', '/api/data/VAE-model-names');
  expect(models.status === 200, `full: list models -> ${models.status}`);

  const reads = readFileSync(process.env.FASTQ!, 'utf8').split('\n').filter((_, i) => i % 4 === 1).map((s) => s.trim());
  const tl = await j(r, 'POST', '/api/upload/estimate-target-length', { sequences: reads });
  const target = tl.body.data.target_length;
  const ad = await j(r, 'POST', '/api/upload/estimate-adapters', { sequences: reads, target_length: target });
  const fwd: string = ad.body.data.forward_adapter, rev: string = ad.body.data.reverse_adapter;
  const rlen = target - fwd.length - rev.length, minCount = 2;
  const cnt = new Map<string, number>();
  for (const s of reads) if (s.startsWith(fwd) && s.endsWith(rev) && s.length === target) {
    const k = s.slice(fwd.length, s.length - rev.length); cnt.set(k, (cnt.get(k) ?? 0) + 1);
  }
  const uniq = [...cnt].filter(([, v]) => v >= minCount);
  log('full.preprocess', { reads: reads.length, target_length: target, fwd_len: fwd.length, rev_len: rev.length, random_region: rlen, unique: uniq.length });

  const name = `web-RAPT1-${epochs}ep-${new Date().toISOString().slice(0, 16).replace(/[-:T]/g, '')}`;
  const sub = await j(r, 'POST', '/api/train/jobs/submit', {
    type: 'RaptGen', name,
    params_preprocessing: { forward: fwd, reverse: rev, random_region_length: rlen, tolerance: 0, minimum_count: minCount },
    random_regions: uniq.map(([k]) => k), duplicates: uniq.map(([, v]) => v), reiteration: 1,
    params_training: { model_length: rlen, epochs, match_forcing_duration: Math.min(20, Math.floor(epochs / 2)),
      beta_duration: Math.min(50, Math.floor(epochs / 2)), early_stopping: epochs, seed_value: 42, match_cost: 4, device: 'CPU' },
  });
  expect(sub.status === 200, `full: submit VAE training -> ${sub.status}`);
  const puid = sub.body.uuid;
  await page.goto(`${site}/trainer`); await page.waitForLoadState('networkidle');
  await page.screenshot({ path: `${shots}/web-02-full-trainer-running.png` });
  const t1 = Date.now();
  const pj = await poll(r, `/api/train/jobs/items/${puid}`, (b) => !['pending', 'progress'].includes(b.status));
  expect(pj.status === 'success', `full: VAE training ${pj.status} in ${Math.round((Date.now() - t1) / 1000)}s`);

  const pub = await j(r, 'POST', '/api/train/jobs/publish', { uuid: puid, name });
  expect(pub.status === 200, `full: publish model -> ${pub.status}`);
  const m2 = await j(r, 'GET', '/api/data/VAE-model-names');
  const vae = m2.body.entries.find((e: any) => e.name === name).uuid;

  const g = await j(r, 'POST', '/api/gmm/jobs/submit', { target: vae, name: `${name}-gmm`,
    params: { minimum_n_components: 2, maximum_n_components: 6, step_size: 2, n_trials_per_component: 2 } });
  expect(g.status === 200, `full: submit GMM -> ${g.status}`);
  const gj = await poll(r, `/api/gmm/jobs/items/${g.body.uuid}`, (b) => !['pending', 'progress'].includes(b.status), 5000);
  expect(gj.status === 'success', `full: GMM ${gj.status}, optimal components ${gj.gmm?.optimal_n_components}`);
  const gp = await j(r, 'POST', '/api/gmm/jobs/publish', { uuid: g.body.uuid, n_components: gj.gmm.optimal_n_components, name: `${name}-gmm` });
  expect(gp.status === 200, `full: publish GMM -> ${gp.status}`);

  const s = await j(r, 'GET', `/api/session/start?vae_uuid=${vae}`);
  const sid = s.body.uuid;
  const xs = gj.gmm.means.map((m: number[]) => m[0]), ys = gj.gmm.means.map((m: number[]) => m[1]);
  const centers = await j(r, 'POST', '/api/session/decode', { session_uuid: sid, coords_x: xs, coords_y: ys });
  log('full.gmm_centers', centers.body.sequences);
  const bo = await j(r, 'POST', '/api/bayesopt/run', {
    coords_x: xs, coords_y: ys, values: [xs.map((_: number, i: number) => i + 1)], // placeholder values, not measurements
    optimization_args: { method_name: 'qEI', query_budget: 3 },
    distribution_args: { xlim_min: -3.5, xlim_max: 3.5, ylim_min: -3.5, ylim_max: 3.5 } });
  expect(bo.status === 200, `full: Bayesian optimization -> ${bo.status}`);
  const q = bo.body.query_data;
  const cand = await j(r, 'POST', '/api/session/decode', { session_uuid: sid, coords_x: q.coords_x, coords_y: q.coords_y });
  log('full.bo_candidates', cand.body.sequences);
  await j(r, 'GET', `/api/session/end?session_uuid=${sid}`);

  await page.goto(`${site}/trainer`); await page.waitForLoadState('networkidle');
  await page.screenshot({ path: `${shots}/web-03-full-trainer-done.png` });
  await page.goto(`${site}/viewer`); await page.waitForLoadState('networkidle');
  await page.getByText(name, { exact: true }).first().click().catch(() => {});
  await page.waitForTimeout(6000);
  await page.screenshot({ path: `${shots}/web-04-full-viewer-new-model.png`, fullPage: true });
  console.log(`MODEL_NAME=${name}`);
  await page.goto(`${site}/logout`);
  await page.goto(site);
  expect(/amazoncognito\.com/.test(page.url()), 'full: after logout the site asks for login again');
  await ctx.close();
}

// ───────────── 2. read-only user ─────────────
{
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await signIn(page, process.env.RO_USER!, process.env.RO_PW_FILE!);
  log('readonly.signin', new URL(page.url()).host);
  const r = ctx.request;
  const models = await j(r, 'GET', '/api/data/VAE-model-names');
  expect(models.status === 200, `readonly: list models -> ${models.status} (${models.body.entries?.length} models)`);
  const vae = models.body.entries[0].uuid;
  const s = await j(r, 'GET', `/api/session/start?vae_uuid=${vae}`);
  const enc = await j(r, 'POST', '/api/session/encode', { session_uuid: s.body.uuid, sequences: ['AUGACGGGGUCUGACGAAUUGACUCGGCACU'] });
  expect(enc.status === 200, `readonly: encode -> ${enc.status}`);
  const dec = await j(r, 'POST', '/api/session/decode', { session_uuid: s.body.uuid, coords_x: [0], coords_y: [0] });
  expect(dec.status === 200, `readonly: decode -> ${dec.status}`);
  await j(r, 'GET', `/api/session/end?session_uuid=${s.body.uuid}`);
  for (const [m, p, d] of [
    ['POST', '/api/train/jobs/submit', { type: 'RaptGen' }],
    ['POST', '/api/upload/upload-vae', {}],
    ['POST', '/api/gmm/jobs/submit', {}],
    ['POST', '/api/bayesopt/run', {}],
    ['DELETE', `/api/data/items/${vae}`, undefined],
    ['PATCH', `/api/data/items/${vae}`, { target: 'name', value: 'x' }],
  ] as const) {
    const res = await j(r, m as any, p, d);
    expect(res.status === 403, `readonly: ${m} ${p} -> ${res.status} (want 403)`);
  }
  const after = await j(r, 'GET', '/api/data/VAE-model-names');
  expect(after.body.entries.length === models.body.entries.length, 'readonly: model list unchanged');
  await page.goto(`${site}/viewer`); await page.waitForLoadState('networkidle'); await page.waitForTimeout(5000);
  await page.screenshot({ path: `${shots}/web-05-readonly-viewer.png`, fullPage: true });
  const denied = await page.request.fetch(`${site}/api/train/jobs/submit`, { method: 'POST', data: {} });
  log('readonly.denied_body', await denied.text());
  await ctx.close();
}

await browser.close();
console.log(failures === 0 ? 'E2E PASS' : `E2E FAIL (${failures})`);
process.exit(failures === 0 ? 0 : 1);
