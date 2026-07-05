#!/usr/bin/env node
// lang_query_test.mjs — Stage S3/S4 verification: drive the stateless hover +
// completion wasm queries through playground/compile.mjs (the same seam the
// browser language worker uses) against playground/dist/playground.wasm.  NO
// server, NO native binary.
//
//   node lang_query_test.mjs <playground.wasm> <runtime.mdk> <core.mdk>
import fs from 'node:fs';
import { loadCompiler, hover, complete } from './compile.mjs';

const [wasmPath, runtimePath, corePath] = process.argv.slice(2);
if (!wasmPath || !runtimePath || !corePath) {
  console.error('usage: lang_query_test.mjs <playground.wasm> <runtime.mdk> <core.mdk>');
  process.exit(2);
}
const wasm = await loadCompiler(wasmPath);
const stdlib = {
  runtime: fs.readFileSync(runtimePath, 'utf8'),
  core: fs.readFileSync(corePath, 'utf8'),
};

// 0-based lines:
//   0: double : Int -> Int
//   1: double x = x + x
//   2:
//   3: main = println (double 21)
const SRC = 'double : Int -> Int\ndouble x = x + x\n\nmain = println (double 21)\n';

let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { pass++; console.log('  PASS  ' + name); }
  else { fail++; console.log('  FAIL  ' + name + (detail ? ' — ' + detail : '')); }
}

// ── Hover ──────────────────────────────────────────────────────────────────
console.log('=== hover ===');
const hDouble = await hover(SRC, 1, 0, { wasm, stdlib });   // `double` at its def
const hVal = hDouble && hDouble.contents && hDouble.contents.value;
check('hover on `double` returns a type', !!hVal && hVal.includes('double : Int -> Int'), JSON.stringify(hDouble));

const hPrintln = await hover(SRC, 3, 8, { wasm, stdlib });  // `println` in main
const pVal = hPrintln && hPrintln.contents && hPrintln.contents.value;
check('hover on `println` returns a type', !!pVal && pVal.includes('println :'), JSON.stringify(hPrintln));

const hOff = await hover(SRC, 2, 0, { wasm, stdlib });      // blank line → null
check('hover off an identifier is null', hOff === null, JSON.stringify(hOff));

// ── Completion ───────────────────────────────────────────────────────────────
console.log('=== completion ===');
const cDou = await complete(SRC, 1, 3, { wasm, stdlib });   // prefix `dou`
check('completion returns a non-empty list for prefix `dou`', Array.isArray(cDou) && cDou.length > 0, JSON.stringify(cDou));
check('completion includes `double` with a detail type',
  Array.isArray(cDou) && cDou.some((i) => i.label === 'double' && /Int/.test(i.detail || '')),
  JSON.stringify(cDou));

const cPr = await complete('main = pr\n', 0, 9, { wasm, stdlib });   // prefix `pr`
check('prefix `pr` completes to println/print/…',
  Array.isArray(cPr) && cPr.some((i) => i.label === 'println'),
  JSON.stringify(cPr && cPr.slice(0, 8)));

console.log('\n=== ' + pass + ' pass / ' + fail + ' fail ===');
process.exit(fail ? 1 : 0);
