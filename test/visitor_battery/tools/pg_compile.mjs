#!/usr/bin/env node
// pg_compile.mjs — compile one program through the playground's compile.mjs seam
// with the SAME extra modules the live page ships (read from both generated
// manifests, so the browser and this probe cannot drift). Prints the WAT on success
// (exit 0) or the diagnostics JSON (exit 1), like playground/dev_compile_node.mjs,
// which this extends only by registering the extra modules.
//
// Usage: node test/visitor_battery/tools/pg_compile.mjs <program.mdk>
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const userPath = process.argv[2];
if (!userPath) { console.error('usage: pg_compile.mjs <program.mdk>'); process.exit(2); }

const manifest = (name) => JSON.parse(fs.readFileSync(path.join(root, 'playground/dist', name), 'utf8'));
const STDLIB = manifest('stdlib_modules.json');
const PLAYGROUND = manifest('playground_modules.json');
if (!STDLIB.length || !PLAYGROUND.length) { console.error('playground module manifests list no module'); process.exit(2); }

const { loadCompiler, compile } = await import(path.join(root, 'playground/compile.mjs'));
const wasm = await loadCompiler(path.join(root, 'playground/dist/playground.wasm'));
const extra = {};
for (const id of STDLIB) extra[id] = fs.readFileSync(path.join(root, 'stdlib', id.replace(/\./g, '/') + '.mdk'), 'utf8');
for (const id of PLAYGROUND) extra[id] = fs.readFileSync(path.join(root, 'playground', id + '.mdk'), 'utf8');
const stdlib = {
  runtime: fs.readFileSync(path.join(root, 'stdlib/runtime.mdk'), 'utf8'),
  core: fs.readFileSync(path.join(root, 'stdlib/core.mdk'), 'utf8'),
  extra,
};
const r = await compile(fs.readFileSync(userPath, 'utf8'), { wasm, stdlib });
if (r.ok) { process.stdout.write(r.wat); process.exit(0); }
process.stdout.write(JSON.stringify(r.diagnostics, null, 2) + '\n');
process.exit(1);
