// medaka_host_test.mjs — one negative probe per host axis of playground/medaka_host.mjs,
// run through the hosts that consume it (test/wasm/run.js, playground/worker.js).
//
//   node playground/medaka_host_test.mjs      exit 0 all pass, 1 a probe failed, 2 setup
//
// It builds its wasm inputs with the tree's ./medaka (`build --target wasmgc/<profile>`)
// and the wasm emitter from `sh test/wasm/build_wasm_oracle.sh` (MEDAKA_WASM_EMITTER
// overrides test/bin/wasm_emit_modules_main).  MEDAKA_HOST_TEST_RUNJS,
// MEDAKA_HOST_TEST_WORKER and MEDAKA_HOST_TEST_COMPILE point the probes at another
// run.js, worker.js or compile.mjs, which is how a probe is shown red against an older
// host.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHost, runProgram, CapabilityError, HostKeyError, SLICES, KEY_EXTERN } from './medaka_host.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = dirname(here);
const medaka = join(root, 'medaka');
const emitter = process.env.MEDAKA_WASM_EMITTER || join(root, 'test', 'bin', 'wasm_emit_modules_main');
const runJs = process.env.MEDAKA_HOST_TEST_RUNJS || join(root, 'test', 'wasm', 'run.js');
const workerJs = process.env.MEDAKA_HOST_TEST_WORKER || join(here, 'worker.js');
const compileMjs = process.env.MEDAKA_HOST_TEST_COMPILE || join(here, 'compile.mjs');
for (const [what, p] of [['medaka binary', medaka], ['wasm emitter', emitter]])
  if (!existsSync(p)) {
    console.error(`SETUP: no ${what} at ${p} (make medaka; sh test/wasm/build_wasm_oracle.sh)`);
    process.exit(2);
  }

// 20000 lines on each stream: far past the 64 KiB a pipe holds.
const BIG_LINES = 20000;
const BIG_LOOP = String.raw`loop : Int -> <Stdout, Stderr> Unit
loop i =
  if i > ${BIG_LINES} then
    ()
  else
    let _ = putStrLn "stdout line \{i} of the run"
    let _ = ePutStrLn "stderr line \{i}"
    loop (i + 1)

`;
const bigText = (line) => Array.from({ length: BIG_LINES }, (_, i) => line(i + 1) + '\n').join('');

const PROGRAMS = {
  exit: 'main =\n  let _ = putStrLn "out-before-exit"\n  let _ = ePutStrLn "err-before-exit"\n  exit 3\n',
  write: 'main =\n  let w = writeFileBytes "probe.bin" (arrayFromList [104, 105, 10])\n'
    + '  let _ = match w\n    Ok _ => putStrLn "write ok"\n    Err e => putStrLn "write err: \\{e}"\n'
    + '  match readFile "probe.bin"\n    Ok s => putStr "read back: \\{s}"\n    Err e => putStrLn "read err: \\{e}"\n',
  read: 'main = match readFile "probe.bin"\n  Ok s => putStr "present: \\{s}"\n  Err e => putStrLn "missing: \\{e}"\n',
  env: 'main = match getEnv "HOME"\n  Some _ => putStrLn "home set"\n  None => putStrLn "home unset"\n',
  trap: 'main =\n  let _ = putStr "out-partial"\n  let _ = ePutStr "err-partial"\n'
    + '  let z = length [1] - 1\n  println (10 / z)\n',
  hello: 'main = putStrLn "hello"\n',
  vfs: String.raw`okErr : Result String a -> String
okErr r = match r
  Ok _ => "Ok"
  Err _ => "Err"

main =
  let _ = putStrLn "write a.txt: \{okErr (writeFileBytes "a.txt" (arrayFromList [120]))}"
  let _ = putStrLn "exists ./a.txt: \{debug (fileExists "./a.txt")}"
  let _ = match readFile "./a.txt"
    Ok s => putStrLn "read ./a.txt: \{s}"
    Err _ => putStrLn "read ./a.txt: Err"
  let _ = putStrLn "read .//a.txt: \{okErr (readFile ".//a.txt")}"
  let _ = putStrLn "write nodir_zz/a.txt: \{okErr (writeFileBytes "nodir_zz/a.txt" (arrayFromList [120]))}"
  let _ = putStrLn "exists nodir_zz/a.txt: \{debug (fileExists "nodir_zz/a.txt")}"
  let _ = putStrLn "exists .: \{debug (fileExists ".")}"
  putStrLn "read .: \{okErr (readFile ".")}"
`,
  bigexit: BIG_LOOP + 'main =\n  let _ = loop 1\n  exit 3\n',
  bigtrap: BIG_LOOP + 'main =\n  let _ = loop 1\n  let z = length [1] - 1\n  println (10 / z)\n',
};

const built = [];
const work = mkdtempSync(join(os.tmpdir(), 'medaka-host-test-'));
function build(name, profile) {
  const src = join(work, name + '.mdk');
  const out = join(work, `${name}.${profile.replace('/', '-')}.wasm`);
  built.push(out);
  writeFileSync(src, PROGRAMS[name]);
  const r = spawnSync(medaka, ['build', '--target', profile, src, '-o', out], {
    env: { ...process.env, MEDAKA_STRICT: '1', MEDAKA_WASM_EMITTER: emitter }, encoding: 'utf8',
  });
  if (r.status !== 0) {
    console.error(`SETUP: build of ${name} for ${profile} failed:\n${r.stdout}${r.stderr}`);
    process.exit(2);
  }
  return out;
}

// The worker module runs here with a stand-in `self`: each run posts into `posted`
// and ends at its 'done' or 'error' message.
let posted = [];
let ended = null;
globalThis.self = {
  postMessage(m) {
    posted.push(m);
    if ((m.type === 'done' || m.type === 'error') && ended) ended();
  },
};
await import(pathToFileURL(workerJs).href);
async function runInWorker(wasmPath) {
  posted = [];
  const done = new Promise((resolve) => { ended = resolve; });
  const bytes = readFileSync(wasmPath);
  self.onmessage({ data: { wasm: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength), isolated: false } });
  await done;
  ended = null;
  return posted;
}
const streamText = (msgs, type) => msgs.filter((m) => m.type === type).map((m) => m.text).join('');
const last = (msgs) => msgs[msgs.length - 1] || {};

let failed = 0;
function check(name, ok, detail) {
  console.log((ok ? 'PASS ' : 'FAIL ') + name);
  if (!ok) { failed++; console.log('     ' + detail); }
}

// (a) WH4 on `exit`: run.js delivers stderr as well as stdout before it exits (#376).
{
  const r = spawnSync(process.execPath, [runJs, build('exit', 'wasmgc/node')], { encoding: 'utf8' });
  check('(a) run.js: stderr survives mdk_exit',
    r.stdout === 'out-before-exit\n' && r.stderr === 'err-before-exit\n' && r.status === 3,
    JSON.stringify({ stdout: r.stdout, stderr: r.stderr, status: r.status }));
}

// (b) WH3 on the worker: a writeFileBytes program links, writes, and reads back (#375).
{
  const msgs = await runInWorker(build('write', 'wasmgc/browser-worker'));
  check('(b) worker: writeFileBytes writes then reads back through the vfs',
    last(msgs).type === 'done' && streamText(msgs, 'stdout') === 'write ok\nread back: hi\n',
    JSON.stringify(msgs));
}

// (c) A withheld slice is a CapabilityError naming the capability, never a LinkError.
{
  const msgs = await runInWorker(build('env', 'wasmgc/node'));
  const m = last(msgs);
  check('(c) worker (browser-worker): getEnv throws CapabilityError naming `env`',
    m.type === 'error' && m.message.includes('getEnv') && m.message.includes('`env` capability'),
    JSON.stringify(msgs));
  const host = createHost('wasmgc/wasi-p2');
  const r = await runProgram(readFileSync(build('hello', 'wasmgc/edge')), host);
  check('(c) wasi-p2: putStr throws CapabilityError naming `stdout`',
    r.kind === 'error' && r.error instanceof CapabilityError && r.error.capability === 'stdout'
      && host.sink.text('stdout') === '',
    JSON.stringify({ kind: r.kind, error: r.error && r.error.message, out: host.sink.text('stdout') }));
}

// (d) WH4 on a trap: buffered stdout is delivered before stderr.  The coded trap line
// ends in a newline, which must not let stderr overtake the partial stdout line.
{
  const msgs = await runInWorker(build('trap', 'wasmgc/browser-worker'));
  const streams = msgs.filter((m) => m.type === 'stdout' || m.type === 'stderr');
  check('(d) worker: a trap flushes stdout, then stderr',
    streams.length >= 2 && streams[0].type === 'stdout' && streams[0].text === 'out-partial'
      && streams[1].type === 'stderr' && streams[1].text.startsWith('err-partial')
      && streams[1].text.includes('E-DIV-ZERO') && last(msgs).type === 'error',
    JSON.stringify(msgs));
  const r = spawnSync('sh', ['-c', '"$0" "$1" "$2" 2>&1', process.execPath, runJs, build('trap', 'wasmgc/node')],
    { encoding: 'utf8' });
  check('(d) run.js: a trap writes stdout, then stderr',
    r.status === 1 && r.stdout.startsWith('out-partialerr-partial') && r.stdout.includes('E-DIV-ZERO'),
    JSON.stringify({ out: r.stdout, status: r.status }));
}

// (e) The worker's vfs belongs to one run: a file the previous run wrote is gone.
{
  await runInWorker(build('write', 'wasmgc/browser-worker'));
  const msgs = await runInWorker(build('read', 'wasmgc/browser-worker'));
  check('(e) worker: the vfs is empty at the start of the next run',
    last(msgs).type === 'done'
      && streamText(msgs, 'stdout') === "missing: ENOENT: no such file or directory, open 'probe.bin'\n",
    JSON.stringify(msgs));
}

// (f) A module importing an `env` key no slice lists is refused before instantiation,
// naming the key, on every host path.  The module is `(import "env" "mdk_fake_key" (func))`.
{
  const name = new TextEncoder().encode('mdk_fake_key');
  const imp = [1, 3, 0x65, 0x6e, 0x76, name.length, ...name, 0, 0];
  const bytes = new Uint8Array([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0, 1, 4, 1, 0x60, 0, 0, 2, imp.length, ...imp]);
  const fake = join(work, 'fake_key.wasm');
  writeFileSync(fake, bytes);
  const host = createHost('wasmgc/node');
  const r = await runProgram(bytes, host);
  check('(f) runProgram: an unknown env key is a HostKeyError naming it',
    r.kind === 'error' && r.error instanceof HostKeyError && r.error.message.includes('env.mdk_fake_key'),
    JSON.stringify({ kind: r.kind, error: r.error && r.error.message }));
  const rr = spawnSync(process.execPath, [runJs, fake], { encoding: 'utf8' });
  check('(f) run.js: the unknown key is named',
    rr.status === 1 && rr.stderr.includes('env.mdk_fake_key') && rr.stderr.includes('wasmgc/node'),
    JSON.stringify({ stderr: rr.stderr, status: rr.status }));
  const msgs = await runInWorker(fake);
  check('(f) worker: the unknown key is named',
    last(msgs).type === 'error' && last(msgs).message.includes('env.mdk_fake_key'),
    JSON.stringify(msgs));
}

// (g) The worker's vfs path model (WASM-SEMANTICS §3): `./a.txt` is `a.txt`, the root
// exists and is a directory, and a write into a directory never created is an Err.  The
// expected text is what the native build of the same program prints.
{
  const msgs = await runInWorker(build('vfs', 'wasmgc/browser-worker'));
  const native = 'write a.txt: Ok\nexists ./a.txt: True\nread ./a.txt: x\nread .//a.txt: Ok\n'
    + 'write nodir_zz/a.txt: Err\nexists nodir_zz/a.txt: False\nexists .: True\nread .: Err\n';
  check('(g) worker: path spellings alias, `.` is a directory, a write needs its directory',
    last(msgs).type === 'done' && streamText(msgs, 'stdout') === native,
    JSON.stringify(msgs));
}

// (h) WH4 through pipes: run.js delivers every byte of both streams on `exit` and on a
// trap, past what a pipe buffers, with the program's exit status (3), and 1 on a trap.
{
  const out = bigText((i) => `stdout line ${i} of the run`);
  const err = bigText((i) => `stderr line ${i}`);
  const piped = { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 };
  const r = spawnSync(process.execPath, [runJs, build('bigexit', 'wasmgc/node')], piped);
  check('(h) run.js: piped stdout and stderr survive mdk_exit whole',
    r.status === 3 && r.stdout === out && r.stderr === err,
    JSON.stringify({ stdout: r.stdout.length, want: out.length, stderr: r.stderr.length, wantErr: err.length, status: r.status }));
  const t = spawnSync(process.execPath, [runJs, build('bigtrap', 'wasmgc/node')], piped);
  check('(h) run.js: piped stdout and stderr survive a trap whole',
    t.status === 1 && t.stdout === out && t.stderr.startsWith(err) && t.stderr.includes('E-DIV-ZERO'),
    JSON.stringify({ stdout: t.stdout.length, want: out.length, stderr: t.stderr.length, status: t.status }));
}

// (i) compile.mjs names its host when the compiler module imports a key no slice lists.
{
  const { compile } = await import(pathToFileURL(compileMjs).href);
  const name = new TextEncoder().encode('mdk_fake_key');
  const imp = [1, 3, 0x65, 0x6e, 0x76, name.length, ...name, 0, 0];
  const bytes = new Uint8Array([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0, 1, 4, 1, 0x60, 0, 0, 2, imp.length, ...imp]);
  const r = await compile('main = ()\n', { wasm: bytes, stdlib: { runtime: '', core: '' } })
    .catch((e) => ({ threw: String(e && e.message) }));
  const text = JSON.stringify(r);
  check('(i) compile.mjs: the HostKeyError names the compiler host',
    text.includes('env.mdk_fake_key') && text.includes('no slice of the playground compiler host lists'),
    text.slice(0, 400));
}

// (j) KEY_EXTERN covers every key a withholdable slice owns alone: a missing row would
// degrade the CapabilityError message to the raw import key.
{
  const alwaysInstalled = new Set(Object.values(SLICES)
    .filter((s) => s.needs.length === 0 && !s.process).flatMap((s) => s.keys));
  const bad = [];
  for (const [name, s] of Object.entries(SLICES))
    for (const k of s.keys) {
      if (alwaysInstalled.has(k)) continue;
      const e = KEY_EXTERN[k];
      if (e === undefined) bad.push(`${name}: ${k} has no KEY_EXTERN row`);
      else if (!/ result$/.test(e) && !(s.externs || []).includes(e))
        bad.push(`${name}: ${k} -> ${e}, not among the slice's externs`);
    }
  check('(j) KEY_EXTERN agrees with SLICES externs', bad.length === 0, bad.join('; '));
}

// Report only: slices no module built above imports a key of.
{
  const imported = new Set();
  for (const f of built)
    for (const i of WebAssembly.Module.imports(new WebAssembly.Module(readFileSync(f))))
      if (i.module === 'env') imported.add(i.name);
  const unused = Object.entries(SLICES)
    .filter(([, s]) => !s.keys.some((k) => imported.has(k))).map(([n]) => n);
  console.log(`unused slices (no probe module imports a key): ${unused.join(', ') || 'none'}`);
}

rmSync(work, { recursive: true, force: true });
console.log(failed ? `${failed} probe(s) failed` : 'all probes pass');
process.exit(failed ? 1 : 0);
