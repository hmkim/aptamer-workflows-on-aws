// Bundle the Lambda@Edge auth function into edge/dist/index.js.
import { build } from 'esbuild';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { DEFAULT_STACK_NAME, checkStackName, edgeSecretId } from '../lib/names.ts';

// The secret ID is baked into the bundle (Lambda@Edge has no environment variables), so the
// bundle is built for one stack: UI_WEB_STACK (default RaptGenUiWeb). bin/app.ts checks it.
const stackName = checkStackName(process.env.UI_WEB_STACK || DEFAULT_STACK_NAME);
export const SECRET_ID = edgeSecretId(stackName);

rmSync('edge/dist', { recursive: true, force: true });
mkdirSync('edge/dist', { recursive: true });
await build({
  entryPoints: ['edge/index.ts'],
  outfile: 'edge/dist/index.js',
  bundle: true,
  minify: true,
  platform: 'node',
  target: 'node22',
  format: 'cjs',
  external: ['@aws-sdk/*'],
  define: { __SECRET_ID__: JSON.stringify(SECRET_ID) },
  legalComments: 'none',
});
writeFileSync('edge/dist/build-info.json', JSON.stringify({ stackName, secretId: SECRET_ID }));
console.log(`edge bundle for stack ${stackName} (secret ${SECRET_ID}) written to edge/dist/index.js`);
