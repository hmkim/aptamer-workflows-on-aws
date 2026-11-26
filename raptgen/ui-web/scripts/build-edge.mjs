// Bundle the Lambda@Edge auth function into edge/dist/index.js.
import { build } from 'esbuild';
import { mkdirSync, rmSync } from 'node:fs';

export const SECRET_ID = '/raptgen-ui-web/edge-auth';

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
console.log('edge bundle written to edge/dist/index.js');
