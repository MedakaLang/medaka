// lib/server.mjs — spawn/tear down the playground's own static dev server
// (playground/server.js) for the duration of the e2e run.
//
// `serveRoot` selects WHICH tree gets served, and that choice is the whole point
// of the site mode: served from playground/ the harness sees index.html + main.js
// sitting next to dist/, which is a layout no user ever visits. The deployed
// thing is playground/site/, assembled by build_site.sh — a different file set,
// with the rendered guide in it. This harness stayed green through a
// build_site.sh that shipped a broken site precisely because it never looked at
// site/. Passing a root here, rather than reimplementing a static server, keeps
// one MIME map and one cache policy for both modes.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const PLAYGROUND_ROOT = join(HERE, '..', '..'); // playground/e2e/lib -> playground/

export async function startServer(port, serveRoot = PLAYGROUND_ROOT) {
  const root = resolve(serveRoot);
  // Fail loud. A missing site/ must never degrade into "serve the dev tree
  // instead" — that would report PASS for a site that was never built.
  if (!existsSync(join(root, 'index.html'))) {
    throw new Error(
      `no index.html in ${root}\n` +
      (root === resolve(PLAYGROUND_ROOT)
        ? '  (the playground dev tree is incomplete?)'
        : '  build the site first: bash playground/build_site.sh'));
  }
  const child = spawn(process.execPath, [join(PLAYGROUND_ROOT, 'server.js')], {
    cwd: PLAYGROUND_ROOT,
    env: { ...process.env, PORT: String(port), SERVE_ROOT: root },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let out = '';
  child.stdout.on('data', (d) => { out += d.toString(); });
  child.stderr.on('data', (d) => { out += d.toString(); });

  // Poll until the server actually answers, rather than trusting stdout timing.
  const url = `http://127.0.0.1:${port}/`;
  const deadline = Date.now() + 10000;
  let ready = false;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(url);
      if (res.ok) { ready = true; break; }
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  if (!ready) {
    child.kill();
    throw new Error(`playground/server.js did not come up on ${url} (root ${root}). Output so far:\n${out}`);
  }
  return {
    url,
    root,
    stop: () => new Promise((resolve) => {
      child.once('exit', resolve);
      child.kill();
      // Fallback in case the child ignores SIGTERM.
      setTimeout(() => { try { child.kill('SIGKILL'); } catch {} }, 2000);
    }),
  };
}
