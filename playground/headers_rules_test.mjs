// headers_rules_test.mjs — which paths receive COOP/COEP under playground/_headers.
// Usage: node playground/headers_rules_test.mjs
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
const require = createRequire(import.meta.url);
const { loadRules, headersFor } = require('./headers_rules.cjs');
const rules = loadRules(join(dirname(fileURLToPath(import.meta.url)), '_headers'));
const get = (p, n) => headersFor(rules, p).filter(([k]) => k === n).map(([, v]) => v);
let bad = 0;
const check = (name, ok) => { console.log((ok ? 'PASS ' : 'FAIL ') + name); if (!ok) bad++; };
for (const p of ['/', '/index.html'])
  check(`${p} gets COOP+COEP`, get(p, 'Cross-Origin-Opener-Policy').join() === 'same-origin'
    && get(p, 'Cross-Origin-Embedder-Policy').join() === 'require-corp');
for (const p of ['/worker.js', '/compiler-worker.js', '/language-worker.js'])
  check(`${p} gets COEP`, get(p, 'Cross-Origin-Embedder-Policy').join() === 'require-corp');
for (const p of ['/blog/pds', '/blog/index.html', '/guide/00-introduction.html', '/advanced/index.html', '/stdlib/index.html', '/dist/x.mdk'])
  check(`${p} gets neither`, get(p, 'Cross-Origin-Opener-Policy').length === 0
    && get(p, 'Cross-Origin-Embedder-Policy').length === 0);
check('/dist/x.mdk keeps Content-Type', get('/dist/x.mdk', 'Content-Type').join() === 'text/plain; charset=utf-8');
for (const p of ['/', '/index.html', '/worker.js', '/blog/pds', '/guide/00-introduction.html', '/dist/x.mdk'])
  console.log(p, '->', JSON.stringify(headersFor(rules, p)));
process.exit(bad ? 1 : 0);
