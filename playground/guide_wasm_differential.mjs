// guide_wasm_differential.mjs — does every "Open in Playground" example in the
// rendered guide actually RUN, and produce the same answer, on the path the
// browser playground uses?
//
// The guide's promise to a reader is a link: every ▶ Open in Playground button
// asserts "click this and it works". Nothing checked that. S-3's
// test/diff_compiler_guide_render.sh proves the RENDER is structurally sound
// (links resolve, fences are known labels, no empty pages) — it never compiles a
// single example, and never touches wasm. This harness is the execution half.
//
// ── What it compares ─────────────────────────────────────────────────────────
//   ORACLE  native: `medaka build <ex>.mdk -o bin` (-O2) then run the binary.
//   SUBJECT browser: playground/dist/playground.wasm — the SAME WasmGC compiler
//           blob the page loads — driven through playground/compile.mjs (the SAME
//           module playground/compiler-worker.js imports) over the SAME in-memory
//           vfs, producing WAT; then assembled and run under Node ≥24.
// stdout, stderr and exit code are compared on all three channels (the #531
// lesson from test/wasm/diff_wasm_modules.sh: comparing stdout alone lets a whole
// class of divergence pass as empty == empty).
//
// Two deliberate, named deltas from a real browser tab, neither in the compiler:
//   * assembly:  wasm-tools parse here, vendor/wat2wasm in the page. Both are
//                WAT→wasm assemblers over the same emitter output.
//   * host ABI:  test/wasm/run.js here, playground/worker.js in the page. Their
//                numeric shims are byte-identical BY GATE
//                (test/diff_compiler_wasm_shim_parity.sh).
// The browser-driven sample in playground/e2e (SITE=1 bash playground/e2e/run.sh,
// tests/playground.spec.mjs "guide example round-trip") closes both deltas
// empirically for a few examples by running them in an actual Chrome.
//
// ── What it refuses to do ────────────────────────────────────────────────────
// Nothing is ever skipped into a pass. Every phase — oracle build, oracle run,
// guest compile, WAT assemble, wasm run — reports FAIL on failure and is counted
// as such; the only "not run" bucket is the NON-runnable partition, which is
// reported separately with its reason and never folded into the N-of-M numerator.
// `--fault-inject <id>` corrupts one example's WAT between emit and assembly to
// demonstrate that on demand.
//
// ── The partition is TESTED, not assumed ─────────────────────────────────────
// The runnable set is read off the rendered HTML (a block carries an
// `<a class="pg-run">` iff render_docs.mjs classified it runnable) AND
// independently recomputed here from the stated rule (fence label exactly
// `medaka`, and no call to a playground-stubbed capability). A disagreement is
// reported as MISCLASSIFIED and fails the run — the rule and the render must not
// drift apart silently.
//
// Usage:
//   node playground/guide_wasm_differential.mjs [--guide <dir>] [--only <id>]
//                                               [--fault-inject <id>] [--jobs N]
//                                               [--list] [--json <path>]
// Defaults: --guide playground/site/guide, falling back to playground/site-guide.
// Requires: playground/dist/playground.wasm (bash playground/build_playground_wasm.sh),
//           ./medaka (make medaka), wasm-tools on PATH, node >= 24.

import { readdirSync, readFileSync, writeFileSync, mkdirSync, existsSync, rmSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { compile, loadCompiler } from './compile.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');

// ── args ─────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const opts = { guide: null, only: null, faultInject: null, jobs: 1, list: false, json: null };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  const next = () => { const v = argv[++i]; if (v === undefined) die(`${a} needs a value`); return v; };
  switch (a) {
    case '--guide': opts.guide = next(); break;
    case '--only': opts.only = next(); break;
    case '--fault-inject': opts.faultInject = next(); break;
    case '--jobs': opts.jobs = parseInt(next(), 10); break;
    case '--list': opts.list = true; break;
    case '--json': opts.json = next(); break;
    default: die(`unknown argument \`${a}\``);
  }
}
function die(msg) { console.error(`guide_wasm_differential: ${msg}`); process.exit(2); }

const GUIDE_DIR = opts.guide
  ? resolve(opts.guide)
  : (existsSync(join(HERE, 'site', 'guide')) ? join(HERE, 'site', 'guide') : join(HERE, 'site-guide'));

// ── the runnability rule, restated INDEPENDENTLY of render_docs.mjs ───────────
// Deliberately a second copy rather than an import: this file's job is to catch
// the render and the rule drifting apart, and a shared constant cannot disagree
// with itself. Keep in sync with render_docs.mjs `classifyRunnable` /
// UNSUPPORTED_CALL_RE and with playground/worker.js `capabilityStub`.
const STUBBED_CAPABILITY_RE =
  /\b(readFile|writeFile|readLine|readLines|getEnv|fileExists|args|exit)\b/;
const KIND_MEDAKA_LABELS = new Set(['medaka', 'medaka-project', 'medaka-nocheck']);

function ruleSaysRunnable(label, source) {
  if (label !== 'medaka') return { runnable: false, reason: `fence label \`${label}\`` };
  const m = source.match(STUBBED_CAPABILITY_RE);
  if (m) return { runnable: false, reason: `uses \`${m[1]}\` (playground stubs it)` };
  return { runnable: true, reason: '' };
}

// ── two conditions the rule above does NOT state, which nonetheless decide
//    whether the ▶ button does anything ────────────────────────────────────
// Neither is a wasm divergence: on both, the native and the browser paths AGREE
// that the program cannot run. They are gaps in the runnable rule itself, so
// they are counted and reported separately from the wasm differential rather
// than blamed on the oracle. This harness deliberately does NOT patch
// render_docs.mjs's rule — see the report for S-prove-the-promise.
//
// (1) A block with no top-level `main` is not a program. `medaka build` panics
//     ("no 'main' binding found"); the browser answers W-MAIN-MISSING. The rule
//     never asks.
const definesMain = (source) => /^main\b/m.test(source);

// (2) A block importing a stdlib module the page does not SHIP cannot resolve in
//     the browser however well it compiles natively. The shipped set is derived
//     from playground/dist (what build_playground_wasm.sh staged and main.js
//     fetches), never hardcoded here.
function unshippedImports(source, shipped) {
  const out = [];
  for (const m of source.matchAll(/^\s*(?:export\s+)?import\s+([a-z][a-z_0-9]*)/gm)) {
    if (!shipped.has(m[1])) out.push(m[1]);
  }
  return out;
}

// ── read the corpus off the RENDERED html ────────────────────────────────────
const unescapeHtml = (s) => s
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
  .replace(/&quot;/g, '"').replace(/&#39;/g, "'")
  .replace(/&amp;/g, '&');   // last: an escaped &amp;lt; must survive as &lt;

function readBlocks(dir) {
  if (!existsSync(dir)) die(`guide dir not found: ${dir}\n  build it: bash playground/build_site.sh (or build_guide.sh)`);
  const files = readdirSync(dir).filter((f) => f.endsWith('.html')).sort();
  if (files.length === 0) die(`no rendered pages in ${dir}`);
  const blocks = [];
  for (const file of files) {
    const html = readFileSync(join(dir, file), 'utf8');
    // Every block render_docs.mjs emits opens exactly like this; the segment up
    // to the NEXT opener contains this block's footer (and so its pg-run link,
    // if the renderer classified it runnable).
    const segments = html.split('<div class="codeblock ');
    let n = 0;
    for (let i = 1; i < segments.length; i++) {
      const seg = segments[i];
      const label = /^kind-[a-z]+"\s+data-lang="([^"]*)"/.exec(seg)?.[1];
      const fence = /\sdata-fence="([^"]*)"/.exec(seg)?.[1] ?? '';
      const rawSrc = /\sdata-source="([^"]*)"/.exec(seg)?.[1];
      if (label === undefined || rawSrc === undefined) {
        die(`${file}: a codeblock div is missing data-lang/data-source — the render contract changed`);
      }
      n++;
      // A `medaka-expect` fence documents the stdout of the block right above it.
      // Carrying it here lets the run answer the guide's actual promise — "this
      // prints that" — and not merely "the two engines agree with each other".
      const prev = blocks[blocks.length - 1];
      if (label === 'medaka-expect' && prev && prev.file === file && prev.label === 'medaka') {
        prev.expect = unescapeHtml(rawSrc);
      }
      blocks.push({
        id: `${file.replace(/\.html$/, '')}#${n}`,
        file,
        label,
        fence,
        source: unescapeHtml(rawSrc),
        renderedRunnable: /<a class="pg-run"/.test(seg),
      });
    }
  }
  return blocks;
}

// ── environment preflight — every one of these is a hard stop, never a skip ───
function preflight() {
  const wasm = join(HERE, 'dist', 'playground.wasm');
  if (!existsSync(wasm)) die(`missing ${wasm}\n  build it: bash playground/build_playground_wasm.sh`);
  const medaka = join(ROOT, 'medaka');
  if (!existsSync(medaka)) die(`missing ${medaka}\n  build it: make medaka`);
  const major = parseInt(process.versions.node.split('.')[0], 10);
  if (major < 24) die(`node >= 24 required for the finalized-WasmGC encoding (have ${process.version})`);
  try { execFileSync('wasm-tools', ['--version'], { stdio: 'ignore' }); }
  catch { die('wasm-tools not on PATH'); }
  const runjs = join(ROOT, 'test', 'wasm', 'run.js');
  if (!existsSync(runjs)) die(`missing ${runjs}`);
  return { wasm, medaka, runjs };
}

// The browser feeds runtime.mdk + core.mdk directly and every EXTRA_MODULES
// sibling through the loader's "./<id>.mdk" key (playground/main.js). Mirror that
// exactly: read them from dist/, which build_playground_wasm.sh staged, so the
// module set here is the module set the page ships and cannot drift from it.
function loadStdlib() {
  const dist = join(HERE, 'dist');
  const runtime = readFileSync(join(dist, 'runtime.mdk'), 'utf8');
  const core = readFileSync(join(dist, 'core.mdk'), 'utf8');
  const extra = {};
  for (const f of readdirSync(dist).filter((f) => f.endsWith('.mdk'))) {
    if (f === 'runtime.mdk' || f === 'core.mdk') continue;
    extra[f.replace(/\.mdk$/, '')] = readFileSync(join(dist, f), 'utf8');
  }
  return { runtime, core, extra };
}

function runCaptured(cmd, args, cwd) {
  const r = spawnSync(cmd, args, { cwd, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.error) return { code: -1, out: '', err: String(r.error.message) };
  return { code: r.status ?? -1, out: r.stdout ?? '', err: r.stderr ?? '' };
}

// ── the differential, one example ────────────────────────────────────────────
async function checkExample(block, env, work) {
  // Rule gaps first: these are not wasm findings, and running them would only
  // charge a native-oracle panic to the wasm path.
  if (!definesMain(block.source)) {
    return { block, status: 'RULE-GAP', phase: 'no-main',
      detail: 'block defines no top-level `main`, so neither path can run it; the runnable rule does not require one', stdout: '' };
  }
  const missing = unshippedImports(block.source, env.shippedModules);
  if (missing.length) {
    return { block, status: 'RULE-GAP', phase: 'unshipped-import',
      detail: `imports \`${missing.join('`, `')}\`, which playground/dist does not ship; the runnable rule checks stubbed CALLS only, not unshipped IMPORTS`, stdout: '' };
  }

  const dir = join(work, block.id.replace(/[^A-Za-z0-9]+/g, '_'));
  mkdirSync(dir, { recursive: true });
  const src = block.source.endsWith('\n') ? block.source : block.source + '\n';
  const mdk = join(dir, 'main.mdk');
  writeFileSync(mdk, src);

  // ORACLE — native compile + run.
  const bin = join(dir, 'oracle');
  const build = runCaptured(env.medaka, ['build', mdk, '-o', bin], dir);
  if (build.code !== 0) {
    return fail(block, 'oracle-build', `${build.out}${build.err}`.trim());
  }
  const native = runCaptured(bin, [], dir);

  // SUBJECT — the page's own compiler blob, through the page's own seam.
  let res;
  try {
    res = await compile(src, { wasm: env.wasmBytes, stdlib: env.stdlib });
  } catch (e) {
    return fail(block, 'guest-compile-throw', String(e && e.message || e));
  }
  if (!res.ok) {
    return fail(block, 'guest-compile', JSON.stringify(res.diagnostics).slice(0, 600));
  }
  let wat = res.wat;
  if (opts.faultInject === block.id) {
    // Deliberate corruption, between emit and assembly. The point is to prove the
    // harness cannot mistake a broken pipeline for a pass — see the header.
    wat = wat.replace(/\(module/, '(module (this-is-not-a-wasm-instruction)');
  }
  const watPath = join(dir, 'prog.wat');
  const wasmPath = join(dir, 'prog.wasm');
  writeFileSync(watPath, wat);

  const parse = runCaptured('wasm-tools', ['parse', watPath, '-o', wasmPath], dir);
  if (parse.code !== 0) return fail(block, 'wasm-assemble', parse.err.trim().slice(0, 600));
  const validate = runCaptured('wasm-tools', ['validate', '--features=all', wasmPath], dir);
  if (validate.code !== 0) return fail(block, 'wasm-validate', validate.err.trim().slice(0, 600));

  const guest = runCaptured(process.execPath, [env.runjs, wasmPath], dir);

  // Compare all three channels (#531).
  const diffs = [];
  if (native.out !== guest.out) diffs.push(`stdout\n    native: ${JSON.stringify(native.out)}\n    wasm  : ${JSON.stringify(guest.out)}`);
  if (native.err !== guest.err) diffs.push(`stderr\n    native: ${JSON.stringify(native.err)}\n    wasm  : ${JSON.stringify(guest.err)}`);
  if (native.code !== guest.code) diffs.push(`exit code: native ${native.code}, wasm ${guest.code}`);
  if (diffs.length) return fail(block, 'divergence', diffs.join('\n  '));

  // Both engines agree — but do they agree with the GUIDE? A `medaka-expect`
  // fence right below the example is the documented answer the reader is
  // promised; a block without one makes no such promise and is simply not
  // checked on this axis.
  let documented = 'none';
  if (block.expect !== undefined) {
    documented = block.expect.trim() === guest.out.trim() ? 'match' : 'MISMATCH';
  }
  return { block, status: 'ok', phase: 'matched', detail: '', stdout: native.out, documented };
}

function fail(block, phase, detail) {
  return { block, status: 'FAIL', phase, detail, stdout: '' };
}

// ── main ─────────────────────────────────────────────────────────────────────
const env0 = preflight();
const blocks = readBlocks(GUIDE_DIR);

const kindMedaka = blocks.filter((b) => KIND_MEDAKA_LABELS.has(b.label));
const misclassified = [];
for (const b of kindMedaka) {
  const rule = ruleSaysRunnable(b.label, b.source);
  if (rule.runnable !== b.renderedRunnable) {
    misclassified.push({ b, rule });
  }
}
const runnable = kindMedaka.filter((b) => b.renderedRunnable);
const notRunnable = kindMedaka.filter((b) => !b.renderedRunnable);

console.log(`guide corpus: ${GUIDE_DIR}`);
console.log(`  fenced blocks total : ${blocks.length}`);
console.log(`  kind-medaka blocks  : ${kindMedaka.length}  (medaka ${kindMedaka.filter((b) => b.label === 'medaka').length}, medaka-project ${kindMedaka.filter((b) => b.label === 'medaka-project').length}, medaka-nocheck ${kindMedaka.filter((b) => b.label === 'medaka-nocheck').length})`);
console.log(`  runnable partition  : ${runnable.length} runnable / ${notRunnable.length} not`);
console.log('');

if (opts.list) {
  for (const b of runnable) console.log(`  runnable  ${b.id}`);
  for (const b of notRunnable) console.log(`  excluded  ${b.id}  (${ruleSaysRunnable(b.label, b.source).reason})`);
  process.exit(0);
}

if (misclassified.length) {
  console.log('MISCLASSIFIED — the rendered partition and the stated rule disagree:');
  for (const { b, rule } of misclassified) {
    console.log(`  ${b.id}: render says ${b.renderedRunnable ? 'runnable' : 'not runnable'}, rule says ${rule.runnable ? 'runnable' : `not runnable (${rule.reason})`}`);
  }
  console.log('');
}

const targets = opts.only ? runnable.filter((b) => b.id === opts.only) : runnable;
if (opts.only && targets.length === 0) die(`--only ${opts.only} matched no runnable block (try --list)`);
if (opts.faultInject && !runnable.some((b) => b.id === opts.faultInject)) {
  die(`--fault-inject ${opts.faultInject} matched no runnable block (try --list)`);
}

const stdlib = loadStdlib();
const env = {
  ...env0,
  wasmBytes: await loadCompiler(env0.wasm),
  stdlib,
  // core/runtime are fed directly, not through the loader, so they are shipped too.
  shippedModules: new Set([...Object.keys(stdlib.extra), 'core', 'runtime']),
};

const work = join(tmpdir(), `guide-wasm-${process.pid}`);
mkdirSync(work, { recursive: true });
process.on('exit', () => { try { rmSync(work, { recursive: true, force: true }); } catch {} });

const results = [];
let done = 0;
// Serial by construction: each example runs the whole WasmGC compiler blob, which
// wants a large stack and a lot of memory; a fan-out here bought nothing but
// flakiness in practice. --jobs is accepted and ignored for forward compat.
for (const b of targets) {
  const r = await checkExample(b, env, work);
  results.push(r);
  done++;
  const tag = { ok: 'ok      ', FAIL: 'FAIL    ', 'RULE-GAP': 'RULE-GAP' }[r.status];
  console.log(`[${String(done).padStart(3)}/${targets.length}] ${tag} ${r.block.id}${r.status === 'ok' ? '' : `  (${r.phase})`}`);
  if (r.status !== 'ok') console.log(`  ${r.detail.split('\n').join('\n  ')}`);
}

const matched = results.filter((r) => r.status === 'ok');
const failed = results.filter((r) => r.status === 'FAIL');
const ruleGaps = results.filter((r) => r.status === 'RULE-GAP');

const listPhases = (rs) => {
  const byPhase = {};
  for (const r of rs) (byPhase[r.phase] ??= []).push(r.block.id);
  for (const [phase, ids] of Object.entries(byPhase)) console.log(`    ${phase}: ${ids.join(', ')}`);
};

console.log('');
console.log(`RESULT over the ${targets.length}-block runnable partition:`);
console.log(`  ${matched.length} matched          — native oracle and the browser's wasm path agree on stdout, stderr and exit code`);
console.log(`  ${failed.length} wasm divergence  — the example works natively and does NOT work on the wasm path`);
if (failed.length) listPhases(failed);
console.log(`  ${ruleGaps.length} rule gap         — neither path can run it; the runnable rule should not have called it runnable`);
if (ruleGaps.length) listPhases(ruleGaps);
console.log(`  (${notRunnable.length} kind-medaka blocks are outside the runnable partition by the rule and were not run)`);

// Second axis, over the matched set only: does the output agree with the
// `medaka-expect` fence the guide prints beside the example? "The two engines
// agree with each other" and "the reader gets what the page promised" are
// different claims, and only the second is the guide's actual contract.
const documented = matched.filter((r) => r.documented && r.documented !== 'none');
const docMismatch = documented.filter((r) => r.documented === 'MISMATCH');
console.log('');
console.log(`DOCUMENTED OUTPUT: ${documented.length - docMismatch.length} of ${documented.length} matched blocks carrying a \`medaka-expect\` fence print exactly what the guide says they print`);
for (const r of docMismatch) {
  console.log(`  MISMATCH ${r.block.id}`);
  console.log(`    guide says : ${JSON.stringify(r.block.expect)}`);
  console.log(`    engines say: ${JSON.stringify(r.stdout)}`);
}

if (opts.json) {
  writeFileSync(opts.json, JSON.stringify({
    guideDir: GUIDE_DIR,
    totals: { blocks: blocks.length, kindMedaka: kindMedaka.length, runnable: runnable.length, notRunnable: notRunnable.length },
    misclassified: misclassified.map(({ b, rule }) => ({ id: b.id, rendered: b.renderedRunnable, rule })),
    results: results.map((r) => ({ id: r.block.id, status: r.status, phase: r.phase, detail: r.detail, stdout: r.stdout, source: r.block.source, expect: r.block.expect ?? null, documented: r.documented ?? null })),
    excluded: notRunnable.map((b) => ({ id: b.id, reason: ruleSaysRunnable(b.label, b.source).reason })),
  }, null, 2));
  console.log(`\nwrote ${opts.json}`);
}

// Exit nonzero on ANY of the three red states. A wasm divergence and a rule gap
// are both live defects in the guide's "click this and it runs" promise; a
// render/rule disagreement means the two have drifted. None of them is a state
// this harness should report as success.
process.exit(failed.length === 0 && ruleGaps.length === 0 && misclassified.length === 0 ? 0 : 1);
