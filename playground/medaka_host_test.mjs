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
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHost, runProgram, confine, CapabilityError, HostKeyError, MemoryVfs, SLICES, KEY_EXTERN } from './medaka_host.mjs';

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
  entropy: 'main =\n  let a = osEntropyBytes 70000\n  let b = osEntropyBytes 0\n'
    + '  putStrLn "lengths \\{arrayLength a} \\{arrayLength b}"\n'
    + '  putStrLn "negative \\{arrayLength (osEntropyBytes (0 - 1))}"\n',
  exe: 'main = putStrLn "exe \\{executablePath ()}"\n',
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
  fsfam: String.raw`import list.{sort}

okErr : Result String a -> String
okErr r = match r
  Ok _ => "Ok"
  Err _ => "Err"

names : Result String (List String) -> String
names (Ok xs) = "Ok \{sort xs}"
names (Err _) = "Err"

shape : Result String (Int, Bool, Bool, Float) -> String
shape (Ok (size, isDir, isFile, _)) =
  "Ok \{if isFile then intToString size else "-"} \{isDir} \{isFile}"
shape (Err _) = "Err"

main =
  println "write a: \{okErr (writeFile "a.txt" "héllo")}"
  println "write b: \{okErr (writeFile "b.txt" "x")}"
  println "list: \{names (listDir ".")}"
  println "stat a: \{shape (statFile "a.txt")}"
  println "stat root: \{shape (statFile ".")}"
  println "stat missing: \{shape (statFile "zz.txt")}"
  println "rename: \{okErr (rename "a.txt" "c.txt")}"
  println "old name: \{debug (fileExists "a.txt")}"
  println "list: \{names (listDir ".")}"
  println "rename missing: \{okErr (rename "a.txt" "d.txt")}"
  println "write into nodir: \{okErr (writeFile "nodir_zz/a.txt" "x")}"
  println "list nodir: \{names (listDir "nodir_zz")}"
  println "list a file: \{names (listDir "b.txt")}"
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

// (k) Confinement (mdk_confine's port) over a real tree, through the host's import
// surface as a guest calls it: a symlink in the existing prefix, `..` after a
// symlink, a dangling symlink, the whole domain `[]`, a bound frame, and a grant left
// by a previous call, which the next call must not inherit.
{
  const t = realpathSync.native(mkdtempSync(join(os.tmpdir(), 'medaka-confine-')));
  mkdirSync(join(t, 'cfg'));
  mkdirSync(join(t, 'outdir'));
  writeFileSync(join(t, 'secret.txt'), 'top secret');
  writeFileSync(join(t, 'cfg', 'a.txt'), 'granted');
  symlinkSync('../outdir', join(t, 'cfg', 'link'));
  symlinkSync('../nowhere.txt', join(t, 'cfg', 'dangling'));
  const vfs = {
    readFile: (p) => readFileSync(p), exists: (p) => existsSync(p), writeFile: (p, b) => writeFileSync(p, b),
    realpath: (p) => realpathSync.native(p),
    lexists: (p) => { try { lstatSync(p); return true; } catch (e) { return false; } },
  };
  const cfg = [`${t}/cfg/*`];
  const out = (p) => `${p} is outside the granted authority ["${t}/cfg/*"]`;
  const cases = [
    ['inside', `${t}/cfg/a.txt`, cfg, null],
    ['a new file inside', `${t}/cfg/new.txt`, cfg, null],
    ['a symlink in the prefix', `${t}/cfg/link/x.txt`, cfg, out(`${t}/cfg/link/x.txt`)],
    ['`..` after a symlink', `${t}/cfg/link/../a.txt`, cfg, out(`${t}/cfg/link/../a.txt`)],
    ['a dangling symlink', `${t}/cfg/dangling`, cfg, out(`${t}/cfg/dangling`)],
    ['`..` out of the grant', `${t}/cfg/../secret.txt`, cfg, out(`${t}/cfg/../secret.txt`)],
    ['the whole domain', `${t}/secret.txt`, [], null],
  ];
  const bad = cases.filter(([, p, g, want]) => confine(vfs, p, g, false) !== want)
    .map(([name, p, g]) => `${name}: ${confine(vfs, p, g, false)}`);
  check('(k) confine: canonical paths, as medaka_rt.c mdk_confine', bad.length === 0, bad.join('; '));

  const host = createHost('wasmgc/node', { vfs });
  const env = host.imports.env;
  const bytes = (s) => new TextEncoder().encode(s);
  const grant = (g) => { env.mdk_grant_reset(); for (const e of g) { for (const b of bytes(e)) env.mdk_grant_push(b); env.mdk_grant_push(-1); } };
  const read = (p) => { env.mdk_path_reset(); for (const b of bytes(p)) env.mdk_path_push(b); return env.mdk_read_file(); };
  const text = () => new TextDecoder().decode(host.resultBuf);
  grant([]);
  const first = read(`${t}/secret.txt`);
  const stale = read(`${t}/secret.txt`);
  check('(k) host: a grant serves one call; the next call without one is refused',
    first === 1 && stale === 0 && text().includes('is outside the granted authority'),
    JSON.stringify({ first, stale, text: text() }));
  grant(cfg);
  const pushed = env.mdk_file_bound_enter(0, 1);
  grant([]);
  const underRead = read(`${t}/secret.txt`);
  grant(cfg);
  const reentered = env.mdk_file_bound_enter(0, 0);
  grant(cfg);
  const writeBound = env.mdk_file_bound_enter(1, 0);
  env.mdk_file_bound_exit();
  env.mdk_file_bound_exit();
  grant([]);
  const left = read(`${t}/secret.txt`);
  grant(cfg);
  env.mdk_file_bound_enter(0, 1);
  host.reset();
  grant([]);
  const afterReset = read(`${t}/secret.txt`);
  check('(k) host: a bound frame confines its mode, re-entry adds none, reset clears it',
    pushed === 1 && underRead === 0 && reentered === 0 && writeBound === 1 && left === 1 && afterReset === 1,
    JSON.stringify({ pushed, underRead, reentered, writeBound, left, afterReset }));
  rmSync(t, { recursive: true, force: true });
}

// (l) The directory and metadata externs over the worker's vfs, with the text the
// native build of the same program prints (a listing is sorted by the program, and a
// directory's size, which each host chooses, is not printed).
{
  const msgs = await runInWorker(build('fsfam', 'wasmgc/browser-worker'));
  const native = 'write a: Ok\nwrite b: Ok\nlist: Ok [a.txt, b.txt]\nstat a: Ok 6 False True\n'
    + 'stat root: Ok - True False\nstat missing: Err\nrename: Ok\nold name: False\n'
    + 'list: Ok [b.txt, c.txt]\nrename missing: Err\nwrite into nodir: Err\nlist nodir: Err\nlist a file: Err\n';
  check('(l) worker: writeFile, listDir, statFile and rename over the vfs',
    last(msgs).type === 'done' && streamText(msgs, 'stdout') === native,
    JSON.stringify(msgs));
}

// (m) The vfs mode model: a file made without a mode reads 0o644, a mode given at
// write sticks and survives the file being overwritten without one, and a rename
// carries it; a directory reads 0o755.  rename replaces a file and moves a directory
// with what is under it.
{
  const v = new MemoryVfs([['d/x.txt', new Uint8Array([1])]]);
  const bad = [];
  const eq = (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) bad.push(`${name}: ${JSON.stringify(got)} != ${JSON.stringify(want)}`); };
  eq('default file mode', v.stat('d/x.txt').mode, 0o644);
  eq('directory mode', v.stat('d').mode, 0o755);
  v.writeFile('new.txt', new Uint8Array([1, 2]), 0o600);
  eq('mode given', v.stat('new.txt').mode, 0o600);
  v.writeFile('new.txt', new Uint8Array([3]));
  eq('overwrite keeps the mode', v.stat('new.txt').mode, 0o600);
  eq('size', v.stat('new.txt').size, 1);
  v.rename('new.txt', 'd/moved.txt');
  eq('rename carries the mode', v.stat('d/moved.txt').mode, 0o600);
  eq('rename removes the source', v.exists('new.txt'), false);
  v.rename('d', 'e');
  eq('directory moves with its entries', v.readdir('e').sort(), ['moved.txt', 'x.txt']);
  eq('old directory gone', v.exists('d/x.txt'), false);
  eq('mode moved with the directory', v.stat('e/moved.txt').mode, 0o600);
  let err = '';
  try { v.rename('e', 'e/inside'); } catch (e) { err = e.message; }
  eq('a directory into itself', err.startsWith('EINVAL'), true);
  err = '';
  try { v.readdir('e/x.txt'); } catch (e) { err = e.message; }
  eq('readdir of a file', err.startsWith('ENOTDIR'), true);
  err = '';
  try { v.stat('nowhere'); } catch (e) { err = e.message; }
  eq('stat of a missing path', err.startsWith('ENOENT'), true);
  v.appendFile('e/moved.txt', new Uint8Array([9]));
  eq('append keeps the mode', v.stat('e/moved.txt').mode, 0o600);
  eq('append grows the file', v.stat('e/moved.txt').size, 2);
  v.appendFile('made.txt', new Uint8Array([4]));
  eq('append creates at the default mode', v.stat('made.txt').mode, 0o644);
  err = '';
  try { v.appendFile('nowhere/x', new Uint8Array([1])); } catch (e) { err = e.message; }
  eq('append into a missing directory', err.startsWith('ENOENT'), true);
  v.unlink('made.txt');
  v.mkdir('mk');
  eq('mkdir adds a directory', v.stat('mk').isDir, true);
  eq('mkdir mode', v.stat('mk').mode, 0o755);
  v.mkdir('mk/inner');
  eq('mkdir under a made directory', v.exists('mk/inner'), true);
  err = '';
  try { v.mkdir('mk'); } catch (e) { err = e.message; }
  eq('mkdir of an existing directory', err.startsWith('EEXIST'), true);
  err = '';
  try { v.mkdir('e/x.txt'); } catch (e) { err = e.message; }
  eq('mkdir over a file', err.startsWith('EEXIST'), true);
  err = '';
  try { v.mkdir('nowhere/sub'); } catch (e) { err = e.message; }
  eq('mkdir under a missing parent', err.startsWith('ENOENT'), true);
  err = '';
  try { v.mkdir('e/x.txt/sub'); } catch (e) { err = e.message; }
  eq('mkdir under a file', err.startsWith('ENOTDIR'), true);
  v.rmdir('mk/inner');
  v.rmdir('mk');
  eq('unlink removes a file', v.exists('made.txt'), false);
  err = '';
  try { v.unlink('e'); } catch (e) { err = e.message; }
  eq('unlink of a directory', err.startsWith('EISDIR'), true);
  err = '';
  try { v.rmdir('e'); } catch (e) { err = e.message; }
  eq('rmdir of a non-empty directory', err.startsWith('ENOTEMPTY'), true);
  err = '';
  try { v.rmdir('e/moved.txt'); } catch (e) { err = e.message; }
  eq('rmdir of a file', err.startsWith('ENOTDIR'), true);
  v.unlink('e/moved.txt');
  v.unlink('e/x.txt');
  v.rmdir('e');
  eq('rmdir removes an empty directory', v.exists('e'), false);
  err = '';
  try { v.rmdir('e'); } catch (e) { err = e.message; }
  eq('rmdir of a missing directory', err.startsWith('ENOENT'), true);
  v.writeFile('f.txt', new Uint8Array([1]));
  let flushed = true;
  try { v.fsync('f.txt'); v.fsync('.'); } catch (e) { flushed = false; }
  eq('fsync of a file and of the root', flushed, true);
  err = '';
  try { v.fsync('missing.txt'); } catch (e) { err = e.message; }
  eq('fsync of a missing path', err.startsWith('ENOENT'), true);
  eq('fileMode reads the stored mode', v.stat('f.txt').mode, 0o644);
  v.writeFile('f.txt', new Uint8Array([2]), 0o600);
  eq('writeFileMode over an existing file sets its mode', v.stat('f.txt').mode, 0o600);
  eq('writeFileMode writes the contents', v.stat('f.txt').size, 1);
  check('(m) MemoryVfs: stored modes (default 0o644), rename, readdir, stat, append, unlink, mkdir, rmdir, fsync, fileMode', bad.length === 0, bad.join('; '));
}

// (n) rename takes two grants on one channel (-2 ends the first) and confines the source
// under the first and the destination under the second, in entry mode, source first; a
// missing second grant refuses.
{
  const v = new MemoryVfs([['a/x.txt', new Uint8Array([1])], ['b/y.txt', new Uint8Array([2])]]);
  const host = createHost('wasmgc/node', { vfs: v });
  const env = host.imports.env;
  const bytes = (s) => new TextEncoder().encode(s);
  const pushGrant = (g) => { for (const e of g) { for (const b of bytes(e)) env.mdk_grant_push(b); env.mdk_grant_push(-1); } };
  const move = (src, dst, gs, gd) => {
    env.mdk_grant_reset(); pushGrant(gs);
    if (gd) { env.mdk_grant_push(-2); pushGrant(gd); }
    env.mdk_path_reset();
    for (const b of [...bytes(src), ...bytes(dst)]) env.mdk_path_push(b);
    const st = env.mdk_rename(bytes(src).length);
    return st === 1 ? 'Ok' : new TextDecoder().decode(host.resultBuf);
  };
  const out = (p, g) => `${p} is outside the granted authority [${g.map((x) => `"${x}"`).join(', ')}]`;
  const got = [
    move('a/x.txt', 'b/z.txt', ['a/*'], ['b/*']),
    move('b/z.txt', 'a/w.txt', ['a/*'], ['b/*']),
    move('b/z.txt', 'a/w.txt', ['b/*'], ['a/*']),
    move('a/w.txt', 'a/w2.txt', ['a/*'], ['b/*']),
    move('a/w.txt', 'b/q.txt', ['a/*'], null),
  ];
  const want = [
    'Ok',
    out('b/z.txt', ['a/*']),
    'Ok',
    out('a/w2.txt', ['b/*']),
    'a/w.txt is outside the granted authority: no grant was given',
  ];
  const bad = got.map((g, i) => (g === want[i] ? null : `${i}: ${g} != ${want[i]}`)).filter(Boolean);
  check('(n) host: rename confines each path under its own grant, source first', bad.length === 0, bad.join('; '));
}

// (o) osEntropyBytes and executablePath on wasmgc/node: the requested lengths, a negative
// count refused with native's text, and the path the host was given.
{
  const host = createHost('wasmgc/node', { executablePath: '/abs/x.wasm' });
  const r = await runProgram(readFileSync(build('entropy', 'wasmgc/node')), host);
  check('(o) host: osEntropyBytes gives the requested lengths, then refuses a negative count',
    r.kind === 'error' && host.sink.text('stdout') === 'lengths 70000 0\n'
      && host.sink.text('stderr').includes('osEntropyBytes: length must be non-negative'),
    JSON.stringify({ kind: r.kind, out: host.sink.text('stdout'), err: host.sink.text('stderr') }));
  const h2 = createHost('wasmgc/node', { executablePath: '/abs/x.wasm' });
  await runProgram(readFileSync(build('exe', 'wasmgc/node')), h2);
  check('(o) host: executablePath is the path the host was given',
    h2.sink.text('stdout') === 'exe /abs/x.wasm\n', JSON.stringify(h2.sink.text('stdout')));
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
