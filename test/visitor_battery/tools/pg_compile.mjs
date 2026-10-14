#!/usr/bin/env node
// pg_compile.mjs — compile one program through the playground's compile.mjs seam
// with the SAME extra stdlib modules the live page ships (read from
// playground/dist/stdlib_modules.json, the list main.js fetches from, so the two
// cannot drift). Prints the WAT on success
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

const EXTRA = JSON.parse(fs.readFileSync(path.join(root, 'playground/dist/stdlib_modules.json'), 'utf8'));
if (!EXTRA.length) { console.error('playground/dist/stdlib_modules.json lists no module'); process.exit(2); }

const { loadCompiler, compile } = await import(path.join(root, 'playground/compile.mjs'));
const wasm = await loadCompiler(path.join(root, 'playground/dist/playground.wasm'));
const extra = {};
for (const id of EXTRA) extra[id] = fs.readFileSync(path.join(root, 'stdlib', id.replace(/\./g, '/') + '.mdk'), 'utf8');
const stdlib = {
  runtime: fs.readFileSync(path.join(root, 'stdlib/runtime.mdk'), 'utf8'),
  core: fs.readFileSync(path.join(root, 'stdlib/core.mdk'), 'utf8'),
  extra,
};
const r = await compile(fs.readFileSync(userPath, 'utf8'), { wasm, stdlib });
if (r.ok) { process.stdout.write(r.wat); process.exit(0); }
process.stdout.write(JSON.stringify(r.diagnostics, null, 2) + '\n');
process.exit(1);
