// compile.mjs — reusable, environment-agnostic seam between the WasmGC-compiled
// Medaka compiler (playground.wasm = the COMBINED diagnostics+emit entry,
// compiler/entries/playground_main.mdk) and its callers (the Node dev driver now,
// the browser Web Worker in Stage 3).
//
// Served with Cross-Origin-Embedder-Policy (playground/_headers): WebKit refuses a
// module worker's import without it.  The edge keeps the headers it cached for an
// unchanged body, so a header-rule change for this file only takes effect when its
// bytes change too.
//
// It instantiates playground.wasm through playground/medaka_host.mjs (the one host,
// as its COMPILER_HOST configuration) over an IN-MEMORY vfs (stdlib runtime.mdk/core.mdk + the user source), runs the
// guest — on ONE instance kept alive across calls, re-entered through the
// module's `mdk_main` export (see "persistent guest session" below) — and
// demuxes the guest's stdout by its first-line marker:
//
//   __MEDAKA_WAT__\n<wat>                          -> { ok: true,  wat }
//   __MEDAKA_WAT_DIAGS__\n<json>\n<wat>            -> { ok: true,  wat, diagnostics }  (clean, but WARNINGS)
//   __MEDAKA_DIAGNOSTICS__\n<json>                 -> { ok: false, diagnostics }   (check --json shape)
//   __MEDAKA_ANALYZE__\n<json>                    -> { ok: true,  diagnostics }   (analyze() only)
//
// `diagnostics` is the parsed {"files":[{file,diagnostics:[...]}]} object, drop-in
// for playground/main.js's renderDiagnostics (it reads `.files`/`.errors`).
//
// API:
//   const wasm = await loadCompiler(wasmBytesOrPath);   // Node: path or bytes; browser: bytes
//   const r = await compile(source, { wasm, stdlib });   // diagnostics + WAT
//   const a = await analyze(source, { wasm, stdlib });   // diagnostics ONLY, no codegen
//     stdlib = { runtime: <runtime.mdk text>, core: <core.mdk text> }
//     r = { ok:true, wat:string, diagnostics?:{files:[...]} } | { ok:false, diagnostics:{files:[...]} }
//     (diagnostics is present on an ok:true result only when there were WARNINGS —
//     e.g. W-NONEXHAUSTIVE. Warnings never block emit, matching native `medaka check`.)
//
// Neither this module nor medaka_host.mjs needs a `node:` module, so the browser
// workers import it unchanged (pass wasm bytes + stdlib text).

// Guest arg paths (also the vfs keys).  The guest requests these literal strings.
// The user entry + its sibling imports go through the loader, which resolves a
// module id to "<root>/<id>.mdk"; with root '.' that yields "./main.mdk", so we
// register the user file (and any extra stdlib siblings) under the "./"-prefixed
// keys the loader will request.  runtime.mdk/core.mdk are read directly via their
// arg paths (NOT through the loader), so they keep their bare names.
const RUNTIME_PATH = 'runtime.mdk';
const CORE_PATH = 'core.mdk';
const USER_ROOT = '.';
const USER_PATH = './main.mdk';
const USER_MODID = 'main';

// ── host ABI: playground/medaka_host.mjs ─────────────────────────────────────
import { createHost, COMPILER_HOST, MemoryVfs, bufferSink, ExitSignal, checkImportKeys } from './medaka_host.mjs';

const enc = (s) => new TextEncoder().encode(s);

// Compile the wasm bytes to a WebAssembly.Module ONCE and reuse it across every
// guest run.  Passing raw BYTES to instantiate recompiles with V8's baseline
// (Liftoff) tier on every call.  Reusing one Module lets V8 tier it up to
// TurboFan, whose smaller frames let a deep recursion go about 2.6x deeper
// before a Web Worker's small stack overflows (measured for #3688).  Keyed on
// the caller's stable wasm object reference (the
// language worker holds one Uint8Array for its lifetime).
// A single global slot: the playground only ever runs ONE wasm (playground.wasm),
// so cache the first compiled Module and reuse it for every call — even when the
// caller hands us a fresh Uint8Array/ArrayBuffer each time (the run compiler
// worker clones the bytes per message).  Reusing one Module is what lets V8 keep
// tiering it up (Liftoff→TurboFan) across calls.
let _compiledModule = null;
let _compiledLen = 0;
function compiledModuleFor(wasmModuleOrBytes) {
  if (wasmModuleOrBytes instanceof WebAssembly.Module) return Promise.resolve(wasmModuleOrBytes);
  const len = wasmModuleOrBytes.byteLength;
  if (_compiledModule && _compiledLen === len) return _compiledModule;
  _compiledLen = len;
  _compiledModule = WebAssembly.compile(wasmModuleOrBytes);
  _session = null;   // a new module means a new instance (see runGuest)
  return _compiledModule;
}

// Build the guest's in-memory vfs: the two stdlib sources under their bare arg
// paths (read directly, not through the loader) plus the user entry and any extra
// stdlib siblings under the loader's "./<id>.mdk" keys.  One definition, shared by
// every mode (compile / analyze / hover / complete) so they cannot drift.
function buildVfs(source, stdlib) {
  const vfsMap = new Map();
  const runtimeBytes = enc(stdlib.runtime);
  vfsMap.set(RUNTIME_PATH, runtimeBytes);
  // `import runtime` resolves through the loader, as natively; `core` is the
  // implicit prelude and is never loaded as a module.
  vfsMap.set(USER_ROOT + '/' + RUNTIME_PATH, runtimeBytes);
  vfsMap.set(CORE_PATH, enc(stdlib.core));
  vfsMap.set(USER_PATH, enc(source));
  // A prelude-only program resolves no sibling imports.  Extra stdlib modules
  // (list/map/...) a program imports go in opts.stdlib.extra as { '<id>': text }
  // (e.g. { 'list': '...' }), registered under the loader's key for the id:
  // "./<id>.mdk", a dotted id's segments as directories ("./crypto/sha256.mdk").
  if (stdlib.extra) for (const [id, text] of Object.entries(stdlib.extra)) {
    vfsMap.set(USER_ROOT + '/' + id.replace(/\./g, '/') + '.mdk', enc(text));
  }
  return vfsMap;
}

// The extra modules buildVfs registered, named to the guest so an unbound
// name's "did you forget to import" hint can name only modules that are here.
function shippedModulesArg(stdlib) {
  const ids = stdlib.extra ? Object.keys(stdlib.extra) : [];
  return ids.length ? ['--stdlib-modules=' + ids.join(',')] : [];
}

// ── persistent guest session ─────────────────────────────────────────────────
// The guest module's `(start $__init)` runs only the eager top-level
// initializers; `main` is the `mdk_main` export (compiler/backend/
// wasm_emit.mdk, emitRefInit), called once per run on the SAME instance.
// Re-entering keeps every top-level `Ref` the compiler uses as a process-wide
// memo alive across calls — above all the content-keyed prelude parse/desugar
// caches (frontend/parse_cache.mdk, frontend/desugar_cache.mdk).  A fresh
// instance per analyze re-parsed and re-desugared runtime.mdk + core.mdk on
// every keystroke: natively that is the difference between a 211ms first
// analyze and an ~85ms second one in the same process (#2036 playground arm).
//
// The host side of each call (argv, the vfs, the stdout/stderr accumulators) is
// swapped per call through one mutable `host` record that the import closures
// read at call time, so the imports bound at instantiate time stay valid.
//
// Safety: the session is dropped (and the next call re-instantiates) on ANY
// exception out of the guest other than a clean `mdk_exit` — a trap or a stack
// overflow can leave guest globals half-updated (a lazy value global stuck in
// its FORCING state, for instance), and a fresh instance is the only state we
// can vouch for.  `resetGuestSession()` drops it on demand (tests).
let _session = null;   // { instance, host } for the one cached module

function makeHost() {
  const mh = createHost(COMPILER_HOST, { getEnv: () => undefined });
  const host = { mh, imports: mh.imports, exited: false, resolve: null };
  host.reset = (vfsMap, argv, resolve) => {
    mh.vfs = new MemoryVfs(vfsMap); mh.args = argv; mh.sink = bufferSink(); mh.reset();
    host.resolve = resolve; host.exited = false;
  };
  host.finish = (code) => {
    if (host.exited) return;
    host.exited = true;
    mh.flush();
    const resolve = host.resolve;
    host.resolve = null;
    resolve({ out: mh.sink.text('stdout'), err: mh.sink.text('stderr'), exit: code | 0 });
  };
  return host;
}

// Drop the cached guest instance; the next call instantiates afresh.
export function resetGuestSession() { _session = null; }

// Run the compiler guest once over an in-memory vfs.  `vfsMap` = Map<path, Uint8Array>.
// `argv` = string[].  Returns { out, err, exit } (out/err as strings).
// First call: instantiate, then call `mdk_main`.  Later calls: re-enter the
// SAME instance through `mdk_main` (see above).
function runGuest(wasmModuleOrBytes, vfsMap, argv) {
  return new Promise((resolve, reject) => {
    if (_session) {
      const { instance, host } = _session;
      host.reset(vfsMap, argv, resolve);
      try {
        instance.exports.mdk_main();
        host.finish(0);
      } catch (e) {
        if (e instanceof ExitSignal || host.exited) { host.finish(e instanceof ExitSignal ? e.code : 0); return; }
        _session = null;
        reject(withGuestStderr(e, host));
      }
      return;
    }
    const host = makeHost();
    host.reset(vfsMap, argv, resolve);
    compiledModuleFor(wasmModuleOrBytes)
      .then((module) => {
        // A compiler module with mdk_main but no mdk_entry_split marker runs main in
        // its start function, so calling mdk_main would run it twice.
        const names = WebAssembly.Module.exports(module).map((e) => e.name);
        if (names.includes('mdk_main') && !names.includes('mdk_entry_split'))
          throw new Error('playground.wasm was built by an older compiler: its start function runs main itself; rebuild it / reload the page');
        checkImportKeys(module, host.mh);
        return WebAssembly.instantiate(module, host.imports);
      })
      .then((instance) => {
        _session = { instance, host };
        instance.exports.mdk_main();
        host.finish(0);
      })
      .catch((e) => {
        if (e instanceof ExitSignal || host.exited) { host.finish(e instanceof ExitSignal ? e.code : 0); return; }
        _session = null;
        reject(withGuestStderr(e, host));
      });
  });
}

// A guest that traps has usually already written WHY to stderr — the emitter's
// coded refusals (`runtime error [E-…]: …`, e.g. the WasmGC FFI wall) print
// their message and then hit `unreachable`.  The trap's own message is just
// "unreachable", so carry the guest's stderr on the rejection and let
// trapDiagnostic() surface it; without this the browser reported a bare
// "compiler trap: unreachable" for a refusal the CLI states by name.
function withGuestStderr(e, host) {
  try {
    host.mh.flush();
    if (e && typeof e === 'object') e.guestStderr = host.mh.sink.text('stderr');
  } catch (_) { /* leave e as-is */ }
  return e;
}

// Externs the wasm backend does not lower (their wasm row in
// compiler/backend/extern_catalog.mdk is NotProvided).  A program reaching one gets a
// message naming it, in place of the compiler trap the toolchain would otherwise
// surface.  The externs the browser host serves (medaka_host.mjs SLICES) are absent.
const NATIVE_ONLY_EXTERNS = new Set([
  'readLine', 'readLineOpt', 'readAll', 'readExactly',
  'executablePath', 'runCommand',
  'netResolve', 'netTcpConnect', 'netTcpListen', 'netListenPort', 'netTcpAccept',
  'netSend', 'netSendFrom', 'netRecv', 'netShutdown', 'netClose', 'netCloseListener',
  'netSetTimeout', 'netSetNonblock', 'netTryAccept', 'netTryRecv', 'netTrySend',
]);

function nativeOnlyMessage(text) {
  const ext = /runtime extern '([A-Za-z0-9_]+)' is not available on the wasm backend/.exec(text);
  if (ext && NATIVE_ONLY_EXTERNS.has(ext[1]))
    return ext[1] + ' is not available in the browser playground';
  return null;
}

function trapDiagnostic(e) {
  const err = e && e.guestStderr ? String(e.guestStderr).trim() : '';
  const named = nativeOnlyMessage(err);
  if (named) return synthErr(named);
  const msg = 'compiler trap: ' + (e && e.message || e);
  return synthErr(err ? msg + '\n' + err : msg);
}

// True for a stack-overflow thrown out of the guest.  On the FIRST run V8
// executes the module with its baseline (Liftoff) tier, whose larger frames
// overflow sooner; a retry re-runs against the tiered-up (TurboFan) module,
// which reaches about 2.6x deeper.  A retry cannot rescue unbounded recursion,
// which overflows the same way on every attempt.  See runGuestRetry.
// The wording is per engine: V8 and JavaScriptCore say "Maximum call stack size
// exceeded", Firefox says "too much recursion".
function isStackOverflow(e) {
  const m = (e && (e.message || String(e))) || '';
  return /call stack|stack (?:size|overflow)|too much recursion/i.test(m);
}

// Run the guest, transparently retrying a first-call stack overflow (see above).
// The compiled Module is cached (compiledModuleFor), so each retry runs against a
// progressively more-optimized tier until it fits.
async function runGuestRetry(wasm, vfsMap, argv, attempts = 5) {
  let last;
  for (let i = 0; i < attempts; i++) {
    try {
      return await runGuest(wasm, vfsMap, argv);
    } catch (e) {
      last = e;
      if (!isStackOverflow(e)) throw e;
    }
  }
  throw last;
}

// loadCompiler: normalize the wasm to bytes.  In Node, accepts a path or bytes;
// in the browser pass bytes (or a Response via arrayBuffer first).
export async function loadCompiler(src) {
  if (typeof src === 'string') {
    // Node path. Dynamic import keeps this module browser-safe.
    const fs = await import('node:fs');
    return new Uint8Array(fs.readFileSync(src));
  }
  if (src instanceof ArrayBuffer) return new Uint8Array(src);
  return src; // assume Uint8Array
}

// compile: the seam Stage 3 imports.
//   source : user .mdk text
//   opts.wasm   : Uint8Array of playground.wasm (from loadCompiler)
//   opts.stdlib : { runtime: <runtime.mdk text>, core: <core.mdk text> }
// Returns { ok:true, wat } or { ok:false, diagnostics } (parsed check --json object).
// On an unexpected guest trap (should not happen for the supported program shapes),
// returns { ok:false, diagnostics: <synthetic single-file error> }.
export async function compile(source, opts = {}) {
  const { wasm, stdlib } = opts;
  if (!wasm) throw new Error('compile: opts.wasm (playground.wasm bytes) required');
  if (!stdlib || stdlib.runtime == null || stdlib.core == null)
    throw new Error('compile: opts.stdlib { runtime, core } required');

  const vfsMap = buildVfs(source, stdlib);

  // argv = <mode> <runtime.mdk> <core.mdk> <entry.mdk> <root>.  Mode 'compile'
  // = today's analyze→emit behavior.  The loader resolves the entry's module id
  // "main" against root "." → "./main.mdk" (a registered key).
  const argv = ['compile', RUNTIME_PATH, CORE_PATH, USER_PATH, USER_ROOT, ...shippedModulesArg(stdlib)];

  let res;
  try {
    res = await runGuestRetry(wasm, vfsMap, argv);
  } catch (e) {
    return { ok: false, diagnostics: trapDiagnostic(e) };
  }

  const out = res.out;
  const nl = out.indexOf('\n');
  const marker = nl >= 0 ? out.slice(0, nl) : out;
  const payload = nl >= 0 ? out.slice(nl + 1) : '';

  if (marker === '__MEDAKA_WAT__') {
    return { ok: true, wat: payload };
  }
  if (marker === '__MEDAKA_WAT_DIAGS__') {
    // payload = <warnings JSON line>\n<WAT text>. WAT never starts with a bare
    // JSON '{', so splitting on the FIRST newline of the payload is safe (and the
    // WAT body itself starts with ";; Medaka WasmGC…", never "__MEDAKA_").
    const pnl = payload.indexOf('\n');
    const diagLine = pnl >= 0 ? payload.slice(0, pnl) : payload;
    const wat = pnl >= 0 ? payload.slice(pnl + 1) : '';
    try {
      return { ok: true, wat, diagnostics: JSON.parse(diagLine.trim()) };
    } catch (e) {
      // Malformed warnings JSON shouldn't lose the (otherwise-valid) WAT — still
      // run the program, just without warnings surfaced.
      return { ok: true, wat };
    }
  }
  if (marker === '__MEDAKA_DIAGNOSTICS__') {
    try {
      return { ok: false, diagnostics: JSON.parse(payload.trim()) };
    } catch (e) {
      return { ok: false, diagnostics: synthErr('bad diagnostics JSON: ' + payload.slice(0, 200)) };
    }
  }
  // No recognized marker — surface stderr/stdout as a synthetic diagnostic so the
  // caller never silently swallows a failure.
  return { ok: false, diagnostics: synthErr('unexpected compiler output: ' + (res.err || out).slice(0, 400)) };
}

// analyze: the diagnostics-only sibling of compile().  Same guest, same front
// end, same diagnostics — the guest stops where compile() would start wasm
// codegen (no lowerProgramEmit / wasmReachFilter / emitProgram), because the
// editor's live-squiggle path throws the WAT away: 596ms of a 769ms clean compile
// was emit nobody read (#2442).  Diagnostic CONTENT is byte-identical to what
// compile() reports for the same program; only the marker differs.
//   analyze(source, { wasm, stdlib })
//     -> { ok:true,  diagnostics:{files:[...]} }   clean (files may carry WARNINGS)
//      | { ok:false, diagnostics:{files:[...]} }   had ERROR diagnostics
// `diagnostics` is ALWAYS present (a clean program yields {"files":[]}), so a
// caller never has to distinguish "clean" from "no output".
export async function analyze(source, opts = {}) {
  const { wasm, stdlib } = opts;
  if (!wasm) throw new Error('analyze: opts.wasm (playground.wasm bytes) required');
  if (!stdlib || stdlib.runtime == null || stdlib.core == null)
    throw new Error('analyze: opts.stdlib { runtime, core } required');

  const vfsMap = buildVfs(source, stdlib);
  const argv = ['analyze', RUNTIME_PATH, CORE_PATH, USER_PATH, USER_ROOT, ...shippedModulesArg(stdlib)];

  let res;
  try {
    res = await runGuestRetry(wasm, vfsMap, argv);
  } catch (e) {
    return { ok: false, diagnostics: trapDiagnostic(e) };
  }

  const out = res.out;
  const nl = out.indexOf('\n');
  const marker = nl >= 0 ? out.slice(0, nl) : out;
  const payload = nl >= 0 ? out.slice(nl + 1) : '';

  if (marker === '__MEDAKA_ANALYZE__' || marker === '__MEDAKA_DIAGNOSTICS__') {
    try {
      return { ok: marker === '__MEDAKA_ANALYZE__', diagnostics: JSON.parse(payload.trim()) };
    } catch (e) {
      return { ok: false, diagnostics: synthErr('bad diagnostics JSON: ' + payload.slice(0, 200)) };
    }
  }
  return { ok: false, diagnostics: synthErr('unexpected compiler output: ' + (res.err || out).slice(0, 400)) };
}

// ── stateless language queries (hover / completion) ──────────────────────────
// Both wrap the SAME playground.wasm through a cursor-carrying mode arg
// (compiler/entries/playground_main.mdk dispatches on argv[0]).  The guest runs a
// fresh parse+typecheck of the single-file buffer, calls the LSP's already-pure
// hoverFor/completionFor, and prints one marker line + one JSON line.  We demux
// the marker and return the parsed LSP result Json (or null).
//
//   hover(source, line, col, {wasm, stdlib})    -> LSP Hover object | null
//   complete(source, line, col, {wasm, stdlib}) -> LSP CompletionItem[] | null
// line/col are 0-based (LSP position convention), matching CM6 line-1 / col.
async function queryAt(mode, marker, source, line, col, opts) {
  const { wasm, stdlib } = opts;
  if (!wasm) throw new Error(mode + ': opts.wasm (playground.wasm bytes) required');
  if (!stdlib || stdlib.runtime == null || stdlib.core == null)
    throw new Error(mode + ': opts.stdlib { runtime, core } required');

  const vfsMap = buildVfs(source, stdlib);

  // argv = <mode> <runtime.mdk> <core.mdk> <entry.mdk> <line> <col>.
  const argv = [mode, RUNTIME_PATH, CORE_PATH, USER_PATH, String(line | 0), String(col | 0)];

  let res;
  try {
    res = await runGuestRetry(wasm, vfsMap, argv);
  } catch {
    return null;
  }
  const out = res.out;
  const nl = out.indexOf('\n');
  const gotMarker = nl >= 0 ? out.slice(0, nl) : out;
  const payload = nl >= 0 ? out.slice(nl + 1) : '';
  if (gotMarker !== marker) return null;
  try {
    return JSON.parse(payload.trim());
  } catch {
    return null;
  }
}

// hover: returns the LSP Hover { contents:{ kind:'markdown', value } } or null.
export async function hover(source, line, col, opts = {}) {
  return queryAt('hover', '__MEDAKA_HOVER__', source, line, col, opts);
}

// complete: returns an array of LSP CompletionItem { label, kind, detail }, or null.
export async function complete(source, line, col, opts = {}) {
  const r = await queryAt('complete', '__MEDAKA_COMPLETE__', source, line, col, opts);
  return Array.isArray(r) ? r : null;
}

function synthErr(message) {
  return { files: [{
    file: USER_PATH,
    diagnostics: [{
      message,
      range: { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } },
      severity: 1,
      source: 'medaka',
    }],
  }] };
}
