#!/usr/bin/env node
// Compile a user program through the playground's compile.mjs seam with the SAME
// extra stdlib modules the live page ships (EXTRA_MODULES in playground/main.js).
import fs from 'node:fs';
import path from 'node:path';
const [root, userPath] = process.argv.slice(2);
const { loadCompiler, compile } = await import(path.join(root, 'playground/compile.mjs'));
const EXTRA = ['args','array','async','base64','bytebuilder','byteparser','bytes','hash_map','hash_set','hex','i32','i64','json','list','map','nonempty','path','set','string','toml','u16','u32','u64','u8','validation','vector'];
const wasm = await loadCompiler(path.join(root, 'playground/dist/playground.wasm'));
const extra = {};
for (const m of EXTRA) extra[m] = fs.readFileSync(path.join(root, 'stdlib', m + '.mdk'), 'utf8');
const stdlib = {
  runtime: fs.readFileSync(path.join(root, 'stdlib/runtime.mdk'), 'utf8'),
  core: fs.readFileSync(path.join(root, 'stdlib/core.mdk'), 'utf8'),
  extra,
};
const source = fs.readFileSync(userPath, 'utf8');
const r = await compile(source, { wasm, stdlib });
if (r.ok) { process.stdout.write(r.wat); process.exit(0); }
process.stdout.write(JSON.stringify(r.diagnostics, null, 2) + '\n');
process.exit(1);
