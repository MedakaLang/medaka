#!/usr/bin/env node
// WasmGC runner — `node test/wasm/run.js <module.wasm>`: instantiate a module on the
// wasmgc/node host profile, run it, and write what it wrote.  `(start $__init)` runs
// the value-binding prologue during instantiation; the program itself runs when the
// host calls the `mdk_main` export.  The hand-written test/wasm/w1_add.wat predates
// that entry and runs in its start function, so a module without the export is only
// instantiated.
//
// The import object, the shims behind it and the flush discipline are
// playground/medaka_host.mjs (docs/spec/WASM-SEMANTICS.md WH3/WH4).  This file
// supplies only the Node side of the profile: the real filesystem, process.env,
// MDK_ARGS as argv, and process stdout/stderr.  Every byte the module writes is
// accumulated and written when the run ends, stdout before stderr.
//
// Exit codes: the program's `exit` code; 0 on completion; 1 on a trap, a failed
// instantiation or a module built by an older compiler; 2 on a usage error.  A run
// ends by setting `process.exitCode`, never `process.exit`: a write to a pipe past
// its buffer is still queued when the flush returns, and `process.exit` drops it.
const fs = require('fs');
const nodePath = require('path');
const { pathToFileURL } = require('url');
const path = process.argv[2];
if (!path) { console.error('usage: run.js <module.wasm>'); process.exit(2); }
const bytes = fs.readFileSync(path);
const hostUrl = pathToFileURL(nodePath.join(__dirname, '..', '..', 'playground', 'medaka_host.mjs')).href;

// The file source: Node fs.  A failure's message is the guest's Err text.
const vfs = {
  readFile: (p) => fs.readFileSync(p),   // -> Buffer; throws on missing/unreadable
  exists: (p) => fs.existsSync(p),
  writeFile: (p, buf) => fs.writeFileSync(p, buf),   // throws on unwritable path
  // confinement's primitives: realpath(3) itself, and whether lstat(2) succeeds
  realpath: (p) => fs.realpathSync.native(p),
  lexists: (p) => { try { fs.lstatSync(p); return true; } catch (e) { return false; } },
};
const args = (process.env.MDK_ARGS ? process.env.MDK_ARGS.split(' ') : []);
let wroteStderr = false;
const sink = {
  write(stream, b) {
    if (stream === 'stderr') wroteStderr = true;
    (stream === 'stdout' ? process.stdout : process.stderr).write(Buffer.from(b).toString('utf8'));
  },
};

import(hostUrl).then(async ({ createHost, runProgram, OldEntryShape }) => {
  const host = createHost('wasmgc/node', { vfs, args, getEnv: (n) => process.env[n], sink });
  const r = await runProgram(bytes, host);
  if (r.kind === 'exit') { process.exitCode = r.code; return; }
  if (r.kind === 'error') {
    const e = r.error;
    process.exitCode = 1;
    if (e instanceof OldEntryShape) { process.stderr.write('error: ' + e.message + '\n'); return; }
    // A Medaka runtime trap streams a coded `runtime error [E-CODE]: …` line to stderr
    // before its `unreachable`; that line, already written by the flush, is the report.
    // Without one, surface the engine's message.
    if (!wroteStderr)
      process.stderr.write((r.inProgram ? 'runtime error: ' : 'instantiate failed: ') + (e && e.message ? e.message : String(e)) + '\n');
  }
}).catch((e) => {
  process.stderr.write('run.js: ' + (e && e.stack ? e.stack : String(e)) + '\n');
  process.exitCode = 1;
});
