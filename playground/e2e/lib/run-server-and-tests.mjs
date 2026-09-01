// lib/run-server-and-tests.mjs — orchestrates: start static server -> run
// the Playwright test spec as a child process -> always tear the server down.
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { startServer } from './server.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
// SERVE_ROOT (4th arg) is the tree to serve; defaults to PLAYGROUND_ROOT, the
// dev tree. run.sh passes playground/site under SITE=1.
const [, , PLAYGROUND_ROOT, PORT_ARG, SCREENSHOT_DIR, SERVE_ROOT] = process.argv;
const PORT = parseInt(PORT_ARG, 10);

let server;
try {
  server = await startServer(PORT, SERVE_ROOT || PLAYGROUND_ROOT);
  console.log(`Static server up at ${server.url} (serving ${server.root})`);

  const testFile = join(HERE, '..', 'tests', 'playground.spec.mjs');
  const status = await new Promise((resolve) => {
    // The spec's CLI contract stays `<base-url> <screenshots-dir>` so the same
    // spec still verifies a LIVE origin (README: `node tests/playground.spec.mjs
    // https://medaka-lang.dev /tmp/shots`). Whether the guide MUST be there is an
    // env flag, not an argument, for the same reason: it is a property of the
    // origin under test, and a live origin has no local root to hand over.
    const child = spawn(process.execPath, [testFile, server.url, SCREENSHOT_DIR], {
      cwd: PLAYGROUND_ROOT,
      stdio: 'inherit',
    });
    child.on('exit', (code) => resolve(code ?? 1));
  });
  process.exitCode = status;
} finally {
  if (server) {
    console.log('Tearing down static server...');
    await server.stop();
  }
}
