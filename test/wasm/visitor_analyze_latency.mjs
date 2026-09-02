// visitor_analyze_latency.mjs — driver for diff_visitor_analyze_latency.sh (S4,
// #2442, epic #2036). Drives S1's `analyze()` export from playground/compile.mjs
// the SAME way playground/language-worker.js drives it (per the sprint contract's
// §3 shared decision) — no independent notion of "analyze" invented here.
//
// Same fixed clean program and min-of-N structure as S1's own latency probe
// (s1_latency.mjs) and F7 before it — a stable min across 9 reps is the
// comparison point, not a mean (mean is dominated by GC/scheduler noise on
// this shared box).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadCompiler, analyze } from '../../playground/compile.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..', '..');
const DIST = path.join(ROOT, 'playground', 'dist');

const wasm = await loadCompiler(path.join(DIST, 'playground.wasm'));
const stdlib = {
  runtime: fs.readFileSync(path.join(DIST, 'runtime.mdk'), 'utf8'),
  core: fs.readFileSync(path.join(DIST, 'core.mdk'), 'utf8'),
};

const clean = `add : Int -> Int -> Int
add a b = a + b

main = println (add 2 3)
`;

const REPS = 9;
const runs = [];
let ok = null;
for (let i = 0; i < REPS; i++) {
  const t0 = performance.now();
  const r = await analyze(clean, { wasm, stdlib });
  runs.push(performance.now() - t0);
  ok = r.ok;
}
runs.sort((a, b) => a - b);
const min = runs[0];
const med = runs[Math.floor(REPS / 2)];

console.log('analyze clean  ok=' + ok + '  min=' + min.toFixed(0) + 'ms  med=' + med.toFixed(0) + 'ms');

if (ok !== true) {
  console.log('FAIL  analyze() did not report ok=true for a clean program');
  process.exit(1);
}

// Ceiling comes from the CLI arg (the shell gate owns the numeric ceiling so
// a deliberate-break demonstration never has to edit this file).
const ceilMs = Number(process.argv[2]);
if (!Number.isFinite(ceilMs) || ceilMs <= 0) {
  console.log('usage: node visitor_analyze_latency.mjs <ceiling-ms>');
  process.exit(2);
}
if (min > ceilMs) {
  console.log('FAIL  min=' + min.toFixed(0) + 'ms exceeds ceiling ' + ceilMs + 'ms');
  process.exit(1);
}
console.log('ok    min=' + min.toFixed(0) + 'ms (ceiling ' + ceilMs + 'ms)');
process.exit(0);
