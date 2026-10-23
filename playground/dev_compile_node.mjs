#!/usr/bin/env node
// dev_compile_node.mjs — drive the WasmGC-compiled COMBINED Medaka compiler
// (playground.wasm = compiler/entries/playground_main.mdk self-compiled to wasm)
// entirely in Node, via the SHARED playground/compile.mjs seam (the same module the
// browser Stage-3 worker will import) and an IN-MEMORY vfs.  NO native binary, NO
// server.  This dogfoods compile.mjs: it does no host-ABI/vfs work itself.
//
// Usage:
//   node dev_compile_node.mjs [--interface <core.mdki> --fingerprint <file>] \
//        <playground.wasm> <runtime.mdk> <core.mdk> <user.mdk> [extra.mdk ...]
// --interface/--fingerprint (given together) hand the guest the shipped prelude
// interface and the compiler fingerprint, as dist/core.mdki and
// dist/compiler_fingerprint.txt do in the browser; without them core is checked.
// Each extra.mdk is registered as stdlib module <basename>, as the browser
// registers the modules it ships.
//
// Output:
//   clean program  → the emitted WAT on stdout (exit 0);
//   broken program → the check --json diagnostics on stdout (exit 1).
import fs from 'node:fs';
import path from 'node:path';
import { loadCompiler, compile } from './compile.mjs';

const usage = 'usage: dev_compile_node.mjs [--interface <core.mdki> --fingerprint <file>] <playground.wasm> <runtime.mdk> <core.mdk> <user.mdk> [extra.mdk ...]';
let argv = process.argv.slice(2);
const flags = {};
for (const name of ['interface', 'fingerprint']) {
  const i = argv.indexOf('--' + name);
  if (i >= 0) {
    if (i + 1 >= argv.length) { console.error(usage); process.exit(2); }
    flags[name] = argv[i + 1];
    argv = [...argv.slice(0, i), ...argv.slice(i + 2)];
  }
}
if (argv.length < 4 || (flags.interface === undefined) !== (flags.fingerprint === undefined)) {
  console.error(usage);
  process.exit(2);
}
const [wasmPath, runtimePath, corePath, userPath, ...extraPaths] = argv;

const wasm = await loadCompiler(wasmPath);
const stdlib = {
  runtime: fs.readFileSync(runtimePath, 'utf8'),
  core: fs.readFileSync(corePath, 'utf8'),
};
if (flags.interface !== undefined) {
  stdlib.coreInterface = fs.readFileSync(flags.interface, 'utf8');
  stdlib.compilerFingerprint = fs.readFileSync(flags.fingerprint, 'utf8');
}
if (extraPaths.length) {
  stdlib.extra = {};
  for (const p of extraPaths) stdlib.extra[path.basename(p, '.mdk')] = fs.readFileSync(p, 'utf8');
}
const source = fs.readFileSync(userPath, 'utf8');

const r = await compile(source, { wasm, stdlib });
if (r.ok) {
  process.stdout.write(r.wat);
  process.exit(0);
} else {
  process.stdout.write(JSON.stringify(r.diagnostics, null, 2) + '\n');
  process.exit(1);
}
