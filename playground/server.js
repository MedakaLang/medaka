#!/usr/bin/env node
// server.js — static dev server for the Medaka playground.
// Zero npm deps: Node stdlib only (http, fs, path).
//
// Serves the playground/ directory as static files.  No backend compilation —
// the Medaka compiler runs fully client-side as a WasmGC module (dist/playground.wasm).
// See playground/compiler-worker.js and playground/compile.mjs for the client-side flow.
//
// Before starting, build the dist assets (once, gitignored):
//   bash playground/build_playground_wasm.sh
//
// Env:
//   PORT        — listen port (default 8080)
//   SERVE_ROOT  — directory to serve (default: this one, the dev tree).
//                 Set it to playground/site to serve the DEPLOYED layout —
//                 index.html + guide/ + dist/ as build_site.sh assembles them,
//                 which is what actually reaches medaka-lang.dev. The e2e
//                 harness uses this (SITE=1 bash playground/e2e/run.sh); it is
//                 one server with one MIME map and one cache policy either way,
//                 so a second serving implementation cannot drift from this one.

'use strict';

const http = require('http');
const fs   = require('fs');
const path = require('path');

// ── Configuration ─────────────────────────────────────────────────────────��───
const PORT       = parseInt(process.env.PORT || '8080', 10);
// Resolved so the traversal guard below compares canonical paths, and so a
// relative SERVE_ROOT is read against the caller's cwd rather than silently
// against this file's directory.
const PLAYGROUND = process.env.SERVE_ROOT
  ? path.resolve(process.env.SERVE_ROOT)
  : __dirname;
if (!fs.existsSync(path.join(PLAYGROUND, 'index.html'))) {
  // Fail loud rather than serving 404s that read like a broken page: a missing
  // site/ almost always means build_site.sh has not been run.
  console.error('FAIL: no index.html in ' + PLAYGROUND);
  if (process.env.SERVE_ROOT) console.error('  build it first: bash playground/build_site.sh');
  process.exit(1);
}

// ── MIME map ──────────────────────────────────────────────────────────────────
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'text/javascript; charset=utf-8',
  '.mjs':  'text/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.mdk':  'text/plain; charset=utf-8',
  '.ico':  'image/x-icon',
};

// ── Static file handler ───────────────────────────────────────────────────────
function handleStatic(req, res) {
  // Strip query string first, then resolve a directory URL to its index.html —
  // what every static host (Cloudflare Pages included) does, and what the site
  // relies on for the bare `/guide/` route. Without this the dev server 404s a
  // directory that the real origin serves, so the e2e harness would grade a
  // route the deploy does not actually have.
  const cleanPath = req.url.split('?')[0].replace(/\/$/, '/index.html');
  // Resolve canonically: join first, then resolve to collapse any '..' segments.
  const filePath = path.resolve(path.join(PLAYGROUND, cleanPath));

  // Security: prevent path traversal outside playground/.
  if (!filePath.startsWith(PLAYGROUND + path.sep) && filePath !== PLAYGROUND) {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    res.end('Forbidden');
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('Not found: ' + cleanPath);
      return;
    }
    const ext = path.extname(filePath);
    res.writeHead(200, {
      'Content-Type': MIME[ext] || 'application/octet-stream',
      'Content-Length': data.length,
      // Dev server: never let the browser serve a stale asset (edits to
      // main.js/editor.js/compile.mjs must take effect on the next reload, and the
      // e2e harness must never run against a cached build).
      'Cache-Control': 'no-store, must-revalidate',
    });
    res.end(data);
  });
}

// ── HTTP server ───────────────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  if (req.method === 'GET' || req.method === 'HEAD') {
    handleStatic(req, res);
  } else {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    res.end('Method Not Allowed');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log('Medaka playground (static) at http://localhost:' + PORT);
  console.log('  Serving: ' + PLAYGROUND);
  console.log('  dist/playground.wasm must be pre-built: bash playground/build_playground_wasm.sh');
  if (process.env.SERVE_ROOT) console.log('  (SERVE_ROOT set — this is the deployed site layout, not the dev tree)');
});

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.error('Port ' + PORT + ' in use — set PORT=<other> to use a different port.');
  } else {
    console.error('Server error:', e);
  }
  process.exit(1);
});
