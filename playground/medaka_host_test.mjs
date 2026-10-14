// medaka_host_test.mjs — one negative probe per host axis of playground/medaka_host.mjs,
// run through the hosts that consume it (test/wasm/run.js, playground/worker.js).
//
//   node playground/medaka_host_test.mjs      exit 0 all pass, 1 a probe failed, 2 setup
//
// It builds its wasm inputs with the tree's ./medaka (`build --target wasmgc/<profile>`)
// and the wasm emitter from `sh test/wasm/build_wasm_oracle.sh` (MEDAKA_WASM_EMITTER
// overrides test/bin/wasm_emit_modules_main).  MEDAKA_HOST_TEST_RUNJS and
// MEDAKA_HOST_TEST_WORKER point the probes at another run.js or worker.js, which is how
// a probe is shown red against an older host.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHost, runProgram, CapabilityError } from './medaka_host.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = dirname(here);
const medaka = join(root, 'medaka');
const emitter = process.env.MEDAKA_WASM_EMITTER || join(root, 'test', 'bin', 'wasm_emit_modules_main');
const runJs = process.env.MEDAKA_HOST_TEST_RUNJS || join(root, 'test', 'wasm', 'run.js');
const workerJs = process.env.MEDAKA_HOST_TEST_WORKER || join(here, 'worker.js');
for (const [what, p] of [['medaka binary', medaka], ['wasm emitter', emitter]])
  if (!existsSync(p)) {
    console.error(`SETUP: no ${what} at ${p} (make medaka; sh test/wasm/build_wasm_oracle.sh)`);
    process.exit(2);
  }

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
};

const work = mkdtempSync(join(os.tmpdir(), 'medaka-host-test-'));
function build(name, profile) {
  const src = join(work, name + '.mdk');
  const out = join(work, `${name}.${profile.replace('/', '-')}.wasm`);
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

rmSync(work, { recursive: true, force: true });
console.log(failed ? `${failed} probe(s) failed` : 'all probes pass');
process.exit(failed ? 1 : 0);
