#!/usr/bin/env node
// roundtrip_test.mjs — Stage-2 verification harness.  Runs the 4 contract cases
// through playground/compile.mjs against playground/dist/playground.wasm, and for
// the two clean cases assembles + RUNS the emitted WAT (wasm-tools + the runner
// host ABI) to assert the program's runtime output.
//
//   node roundtrip_test.mjs <playground.wasm> <runtime.mdk> <core.mdk>
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { loadCompiler, compile } from './compile.mjs';
import { createHost, runProgram } from './medaka_host.mjs';

const [wasmPath, runtimePath, corePath] = process.argv.slice(2);
const wasm = await loadCompiler(wasmPath);
const stdlib = {
  runtime: fs.readFileSync(runtimePath, 'utf8'),
  core: fs.readFileSync(corePath, 'utf8'),
};

// Assemble + run an emitted user WAT on the playground's runner profile
// (playground/medaka_host.mjs, wasmgc/browser-worker), returning its stdout.
async function runWat(wat) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mdk-wat-'));
  const watFile = path.join(tmp, 'p.wat');
  const wasmFile = path.join(tmp, 'p.wasm');
  fs.writeFileSync(watFile, wat);
  execFileSync('wasm-tools', ['parse', watFile, '-o', wasmFile]);
  const host = createHost('wasmgc/browser-worker');
  const r = await runProgram(fs.readFileSync(wasmFile), host);
  if (r.kind === 'error') throw r.error;
  return host.sink.text('stdout');
}

const cases = [
  { name: 'clean: arithmetic', src: 'main = println (1 + 2)\n', expect: { ok: true, run: '3' } },
  { name: 'clean: prelude (sum/map)', src: 'main = println (sum (map (x => x * 2) [1, 2, 3]))\n', expect: { ok: true, run: '12' } },
  { name: 'type-broken', src: 'main = println (1 + "hello")\n', expect: { ok: false } },
  { name: 'parse-broken', src: 'main = println (1 +\n', expect: { ok: false } },
];

let pass = 0, fail = 0;
for (const c of cases) {
  process.stdout.write('\n=== ' + c.name + ' ===\n');
  const r = await compile(c.src, { wasm, stdlib });
  process.stdout.write('  ok=' + r.ok + '\n');
  if (c.expect.ok && r.ok) {
    const watLen = r.wat.length;
    process.stdout.write('  WAT bytes=' + watLen + '\n');
    let runOut;
    try { runOut = (await runWat(r.wat)).trim(); }
    catch (e) { runOut = '<run failed: ' + (e.message || e) + '>'; }
    process.stdout.write('  run output=' + JSON.stringify(runOut) + ' (expect ' + JSON.stringify(c.expect.run) + ')\n');
    if (runOut === c.expect.run) { pass++; } else { fail++; process.stdout.write('  FAIL\n'); }
  } else if (!c.expect.ok && !r.ok) {
    process.stdout.write('  diagnostics=' + JSON.stringify(r.diagnostics) + '\n');
    pass++;
  } else {
    fail++;
    process.stdout.write('  FAIL (ok mismatch); payload=' + JSON.stringify(r) + '\n');
  }
}
process.stdout.write('\n=== ' + pass + ' pass / ' + fail + ' fail ===\n');
process.exit(fail ? 1 : 0);
