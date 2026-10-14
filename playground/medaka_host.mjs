// medaka_host.mjs — the one host for an emitted WasmGC module: it builds the `env`
// import object from capability slices, and runs a program with one flush discipline.
//
// Served with Cross-Origin-Embedder-Policy (playground/_headers): a module worker
// imports it, and WebKit refuses a module worker's import without that header.  The
// edge keeps the headers it cached for an unchanged body, so a header-rule change for
// this file only takes effect when its bytes change too.
//
// Consumers: test/wasm/run.js (every wasm gate, profile wasmgc/node),
// playground/worker.js (the user's program, wasmgc/browser-worker),
// playground/compile.mjs (the compiler itself, COMPILER_HOST), and the runner stubs in
// playground/roundtrip_test.mjs and playground/client_flow_test.mjs.  The import
// surface is docs/spec/WASM-SEMANTICS.md §3; WH3 and WH4 hold here, once.
//
// API:
//   createHost(profile, opts) -> host       host.imports is the import object
//   makeImports(profile, opts) -> imports   createHost(profile, opts).imports
//   runProgram(wasm, host, opts) -> { kind: 'done' } | { kind: 'exit', code }
//                                 | { kind: 'error', error, inProgram }
//   profile = a name in PROFILES, or a host configuration such as COMPILER_HOST.
//   opts = { vfs, args, getEnv, sink, streaming, isolated, hostLabel, withheldHint }

// ── capability slices ────────────────────────────────────────────────────────
// Each slice lists the import keys it implements.  A key may sit in several slices
// when they share it (the path and result byte channels, WH5); it is real when any
// installed slice lists it.  `needs` is the effect labels a profile must grant for
// the slice to be installed; `process` marks the slices only a process host has
// (`args` and `exit` carry no effect label in stdlib/runtime.mdk).  `entropy` and
// `stdin` have no keys: the emitter declares no import for either yet
// (compiler/backend/extern_catalog.mdk: osEntropyBytes is native-only, the stdin
// family is unported).
const PATH_KEYS = ['mdk_path_reset', 'mdk_path_push'];
const RESULT_KEYS = ['mdk_result_len', 'mdk_result_byte'];
const MATH_KEYS = [
  'mdk_cbrt', 'mdk_exp', 'mdk_log', 'mdk_log2', 'mdk_log10',
  'mdk_sin', 'mdk_cos', 'mdk_tan', 'mdk_asin', 'mdk_acos', 'mdk_atan',
  'mdk_sinh', 'mdk_cosh', 'mdk_tanh', 'mdk_pow', 'mdk_atan2', 'mdk_hypot',
];
// `externs` names the stdlib/runtime.mdk externs a slice that a profile can withhold
// serves, keyless slices included: the names a program calls to reach it.
export const SLICES = {
  stdout: { needs: ['Stdout'], keys: ['mdk_write_byte'], externs: ['putStr'] },
  stderr: { needs: ['Stderr'], keys: ['mdk_write_err_byte'], externs: ['ePutStr'] },
  floatfmt: { needs: [], keys: ['mdk_float_fmt', 'mdk_float_fmt_byte'] },
  math: { needs: [], keys: MATH_KEYS },
  strtod: { needs: [], keys: ['mdk_str_to_float', 'mdk_str_to_float_ok', ...PATH_KEYS] },
  fs: {
    needs: ['FileRead', 'FileWrite'],
    keys: [
      'mdk_read_file', 'mdk_file_exists',
      'mdk_write_file_reset', 'mdk_write_file_push', 'mdk_write_file_commit',
      ...PATH_KEYS, ...RESULT_KEYS,
    ],
    externs: ['readFile', 'readFileBytes', 'fileExists', 'writeFile', 'writeFileBytes'],
  },
  env: { needs: ['Env'], keys: ['mdk_get_env', ...PATH_KEYS, ...RESULT_KEYS], externs: ['getEnv'] },
  args: { needs: [], process: true, keys: ['mdk_args_count', 'mdk_arg_len', 'mdk_arg_byte'], externs: ['args'] },
  exit: { needs: [], process: true, keys: ['mdk_exit'], externs: ['exit'] },
  clock: {
    needs: ['Clock'],
    keys: ['mdk_wall_time_sec', 'mdk_monotonic_sec', 'mdk_sleep_ms'],
    externs: ['wallTimeSec', 'monotonicSec', 'sleepMs'],
  },
  entropy: { needs: ['Rand'], keys: [], externs: ['osEntropyBytes'] },
  stdin: { needs: ['Stdin'], keys: [], externs: ['readLine', 'readLineOpt', 'readAll', 'readExactly'] },
};

// The wasmgc rows of compiler/types/target_profile.mdk `profileRows`: the labels
// each profile grants.  A profile's slices are the ones whose `needs` it grants.
export const PROFILES = {
  'wasmgc/node': {
    grants: ['Stdout', 'Stderr', 'Stdin', 'Clock', 'Env', 'Rand', 'FileRead', 'FileWrite'],
    process: true,
  },
  'wasmgc/browser-worker': {
    grants: ['Stdout', 'Stderr', 'Clock', 'Rand', 'FileRead', 'FileWrite'],
    process: false,
  },
  'wasmgc/edge': { grants: ['Stdout', 'Stderr', 'Clock', 'Rand'], process: false },
  'wasmgc/wasi-p2': { grants: [], process: false },
};

// The compiler running in the browser (playground/compile.mjs) is a host
// configuration, not a target profile: `fs` over the source vfs, `args` as the call's
// argv, and an `env` that answers None.
export const COMPILER_HOST = {
  name: 'the playground compiler host',
  slices: ['stdout', 'stderr', 'floatfmt', 'math', 'strtod', 'fs', 'env', 'args', 'exit', 'clock'],
};

export function profileSlices(profile) {
  const p = PROFILES[profile];
  if (!p) throw new Error(`unknown host profile \`${profile}\` (known: ${Object.keys(PROFILES).join(', ')})`);
  return Object.keys(SLICES).filter((s) =>
    SLICES[s].needs.every((l) => p.grants.includes(l)) && (!SLICES[s].process || p.process));
}

// The import keys a profile (or host configuration) installs for real.
export function installedKeys(profile) {
  const slices = typeof profile === 'string' ? profileSlices(profile) : profile.slices;
  return [...new Set(slices.flatMap((s) => SLICES[s].keys))];
}

// The externs of the slices a profile withholds: a program calling one cannot run
// there as documented.  The playground's runnability rule (render_docs.mjs and,
// restated independently, guide_wasm_differential.mjs) reads this for
// `wasmgc/browser-worker`.
export function withheldExterns(profile) {
  const installed = new Set(profileSlices(profile));
  return Object.keys(SLICES)
    .filter((s) => !installed.has(s))
    .flatMap((s) => SLICES[s].externs || []);
}

// Externs of a slice a profile can install that no wasm build lowers (their wasm row in
// compiler/backend/extern_catalog.mdk is NotProvided): a call to one does not compile
// for any wasmgc profile, so the runnability rule reads them beside withheldExterns.
export const WASM_GAP_EXTERNS = ['writeFile', 'osEntropyBytes'];

// The extern a key serves, for a withheld slice's message.  medaka_host_test.mjs asserts
// every key of a withholdable slice has a row naming one of that slice's `externs`.
export const KEY_EXTERN = {
  mdk_write_byte: 'putStr', mdk_write_err_byte: 'ePutStr',
  mdk_read_file: 'readFile', mdk_file_exists: 'fileExists',
  mdk_write_file_reset: 'writeFileBytes', mdk_write_file_push: 'writeFileBytes',
  mdk_write_file_commit: 'writeFileBytes', mdk_get_env: 'getEnv',
  mdk_args_count: 'args', mdk_arg_len: 'args', mdk_arg_byte: 'args', mdk_exit: 'exit',
  mdk_wall_time_sec: 'wallTimeSec', mdk_monotonic_sec: 'monotonicSec', mdk_sleep_ms: 'sleepMs',
  mdk_result_len: 'readFile/getEnv result', mdk_result_byte: 'readFile/getEnv result',
};

// ── errors ───────────────────────────────────────────────────────────────────
// A call into a withheld slice.  `capability` is the slice name.
export class CapabilityError extends Error {
  constructor(capability, message) {
    super(message);
    this.name = 'CapabilityError';
    this.capability = capability;
  }
}
// A module that exports `mdk_main` without the `mdk_entry_split` marker was emitted
// with `main` inside its start function: instantiating it runs the program, and
// calling `mdk_main` would run it again.  It is refused before instantiation.
export class OldEntryShape extends Error {}
// A module imports an `env` key that no slice of the host's profile lists: the compiler
// emitted a key the host cannot even withhold, so the profile and the slice set have drifted.
export class HostKeyError extends Error {
  constructor(message, keys) {
    super(message);
    this.name = 'HostKeyError';
    this.keys = keys;
  }
}
// Thrown by `mdk_exit` to unwind the guest; the host that called `mdk_main` ends the run.
export class ExitSignal extends Error {
  constructor(code) { super('exit ' + code); this.code = code; }
}

// ── float formatting (WH2: ≡ medaka_rt.c mdk_float_lexeme) ───────────────────
// SHORTEST-ROUND-TRIP since issue #57. `toExponential()` (no arg) is JS's shortest
// half-even scientific form — it matches C's `%.*e` shortest-precision loop EXACTLY,
// including the 17-digit half-way tie (C printf and JS toExponential(16) diverge there
// — half-even vs half-up — but the no-arg shortest form agrees with C). We take only
// its digits + decimal exponent, then re-derive the layout with the SAME fixed
// threshold as C (scientific iff exp<-4 || exp>=12), lowercase 'e', 2-digit signed
// exponent, and the `.0` append rule.
export function fmt12g(d) {
  if (Number.isNaN(d)) return 'nan';
  if (d === Infinity) return 'inf';
  if (d === -Infinity) return '-inf';
  if (d === 0) return (1 / d === -Infinity) ? '-0.0' : '0.0';
  const neg = d < 0, ad = Math.abs(d);
  const m = ad.toExponential().match(/^(\d)(?:\.(\d+))?e([+-]\d+)$/);
  let digits = m[1] + (m[2] || '');     // shortest significant digits
  const exp = parseInt(m[3], 10);
  digits = digits.replace(/0+$/, '');   // trim (defensive)
  if (digits === '') digits = '0';
  const nd = digits.length;
  let out;
  if (exp < -4 || exp >= 12) {
    const mant = (nd === 1) ? digits : (digits[0] + '.' + digits.slice(1));
    const ea = Math.abs(exp).toString().padStart(2, '0');
    out = mant + 'e' + (exp < 0 ? '-' : '+') + ea;
  } else {
    const pointPos = exp + 1;
    if (pointPos <= 0) out = '0.' + '0'.repeat(-pointPos) + digits;
    else if (pointPos >= nd) out = digits + '0'.repeat(pointPos - nd);
    else out = digits.slice(0, pointPos) + '.' + digits.slice(pointPos);
  }
  if (neg) out = '-' + out;
  if (!/[.eEni]/.test(out)) out = out + '.0';   // the `.0` append rule
  return out;
}

// ── string -> float (WH2: ≡ medaka_rt.c mdk_string_to_float) ─────────────────
// The C runtime is the oracle for stringToFloat (WH2): medaka_rt.c
// mdk_string_to_float is `strtod` + an endptr FULL-CONSUMPTION check + an empty-string
// reject. JS Number() is NOT strtod: Number("") === 0, Number("1.5 ") trims,
// Number("nan"/"inf") is NaN, and Number rejects C99 hex floats ("0x1p3" -> NaN).
// strtod skips LEADING whitespace only, accepts inf/infinity and nan/nan(chars)
// case-insensitively, and accepts hex floats. Because native requires full
// consumption, longest-match is unnecessary — the whole post-whitespace string must
// match the grammar, or the endptr check would reject it anyway.
// Returns { ok, value }; ok === 0 means None. The native C oracle's frontier cases are
// test/llvm_fixtures/str_to_float_frontier.mdk.
export function mdkStrToFloat(s) {
  if (s.length === 0) return { ok: 0, value: 0 };   // medaka_rt.c: bl == 0 -> None
  const b = s.replace(/^[ \t\n\v\f\r]+/, '');       // strtod skips leading isspace
  let m;
  if ((m = /^([+-]?)(?:inf|infinity)$/i.exec(b)))
    return { ok: 1, value: m[1] === '-' ? -Infinity : Infinity };
  if ((m = /^([+-]?)nan(?:\([0-9A-Za-z_]*\))?$/i.exec(b)))
    // strtod propagates the SIGN onto the NaN, and the sign bit is OBSERVABLE
    // through floatToBytes64 (native "-nan" -> byte0 0xff, not 0x7f). JS unary
    // minus is an IEEE negate, so it sets the bit; the f64 crosses the import
    // boundary uncanonicalised.
    return { ok: 1, value: m[1] === '-' ? -NaN : NaN };
  if ((m = /^([+-]?)0[xX](?:([0-9A-Fa-f]+)(?:\.([0-9A-Fa-f]*))?|\.([0-9A-Fa-f]+))(?:[pP]([+-]?[0-9]+))?$/.exec(b))) {
    const ip = m[2] !== undefined ? m[2] : '';
    const fp = m[2] !== undefined ? (m[3] || '') : m[4];
    const v = mdkHexFloat(ip, fp, m[5] ? parseInt(m[5], 10) : 0);
    return { ok: 1, value: m[1] === '-' ? -v : v };
  }
  if (/^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/.test(b))
    return { ok: 1, value: Number(b) };             // decimal: Number() is correctly rounded
  return { ok: 0, value: 0 };
}
// C99 hex float -> double, correctly rounded like strtod. The value is M * 2^e for an
// exact BigInt M, so rendering it as an EXACT decimal string (2^-k = 5^k / 10^k) and
// handing that to Number() gets round-to-nearest-even for free.
function mdkHexFloat(ip, fp, pexp) {
  const M = BigInt('0x' + (ip + fp || '0'));
  if (M === 0n) return 0;
  const e = pexp - 4 * fp.length, bits = M.toString(2).length;
  if (bits + e > 1100) return Infinity;             // clamp keeps the BigInt bounded
  if (bits + e < -1100) return 0;
  if (e >= 0) return Number((M << BigInt(e)).toString());
  const k = -e, num = (M * 5n ** BigInt(k)).toString().padStart(k + 1, '0');
  return Number(num.slice(0, num.length - k) + '.' + num.slice(num.length - k));
}

const enc = (s) => new TextEncoder().encode(s);
const dec = (a) => new TextDecoder('utf-8').decode(a instanceof Uint8Array ? a : new Uint8Array(a));

// ── vfs ──────────────────────────────────────────────────────────────────────
// The file source behind the `fs` slice: readFile(path) -> bytes (throws an Error
// whose message is the guest's Err text), exists(path) -> bool, writeFile(path, bytes).
// An in-memory vfs, with the path model of docs/spec/WASM-SEMANTICS.md §3: paths are
// relative to its root (`.`, `/` and `` all name it), `.` and empty components are
// dropped, `..` steps up (never above the root), and every component a `/` follows
// must be an existing directory.  The root always exists; another directory exists
// when a constructor entry lies under it, since nothing a program calls creates one.
// A missing path, or a write into a missing directory, is an Err naming the path,
// never empty contents; the texts are Node's, as on test/wasm/run.js.
export class MemoryVfs {
  constructor(entries) {
    this.files = new Map();
    this.dirs = new Set(['']);
    for (const [p, bytes] of entries || []) {
      const parts = MemoryVfs.split(p);
      for (let i = 1; i < parts.length; i++) this.dirs.add(parts.slice(0, i).join('/'));
      this.files.set(parts.join('/'), bytes);
    }
  }
  // The components of a path with `.` and empty ones dropped and `..` applied lexically.
  static split(p) {
    const out = [];
    for (const s of p.split('/'))
      if (s === '..') out.pop();
      else if (s !== '' && s !== '.') out.push(s);
    return out;
  }
  // The key of `p`, or the errno of the first component a `/` follows that is not a
  // directory.
  resolve(p) {
    const parts = p.split('/');
    const out = [];
    for (let i = 0; i < parts.length; i++) {
      const s = parts[i];
      if (s === '' || s === '.') continue;
      if (s === '..') { out.pop(); continue; }
      out.push(s);
      if (i < parts.length - 1) {
        const k = out.join('/');
        if (!this.dirs.has(k))
          return { error: this.files.has(k) ? 'ENOTDIR: not a directory' : 'ENOENT: no such file or directory' };
      }
    }
    return { key: out.join('/') };
  }
  readFile(p) {
    const { key, error } = this.resolve(p);
    if (error) throw new Error(`${error}, open '${p}'`);
    if (this.dirs.has(key)) throw new Error('EISDIR: illegal operation on a directory, read');
    if (!this.files.has(key)) throw new Error(`ENOENT: no such file or directory, open '${p}'`);
    return this.files.get(key);
  }
  exists(p) {
    const { key, error } = this.resolve(p);
    return !error && (this.dirs.has(key) || this.files.has(key));
  }
  writeFile(p, bytes) {
    const { key, error } = this.resolve(p);
    if (error) throw new Error(`${error}, open '${p}'`);
    if (this.dirs.has(key)) throw new Error(`EISDIR: illegal operation on a directory, open '${p}'`);
    this.files.set(key, bytes);
  }
}

// A sink that keeps every delivered byte; `text(stream)` decodes what it holds.
export function bufferSink() {
  const sink = {
    out: [], err: [],
    write(stream, bytes) { const to = stream === 'stdout' ? sink.out : sink.err; for (const b of bytes) to.push(b); },
    text(stream) { return dec(stream === 'stdout' ? sink.out : sink.err); },
  };
  return sink;
}

// ── the host ─────────────────────────────────────────────────────────────────
// The import closures read the host's fields at call time, so a caller may swap
// `vfs`, `args`, `getEnv` and `sink` between runs of one instance (compile.mjs keeps
// one instance across calls); `reset()` clears the per-run channel state.
//
// Output: the guest's bytes are buffered per stream and handed to `sink.write(stream,
// bytes)` by `flush()`, stdout before stderr, then `sink.sync()` if the sink has one.
// That is the WH4 discipline, and `deliverAll` is its only implementation: runProgram
// flushes on completion, exit, trap, CapabilityError and OldEntryShape alike.  A
// `streaming` host also delivers both streams, in the same order, at each newline
// either stream writes, and flushes before a sleep, so a page shows output while the
// guest runs and a partial stdout line is not overtaken by a later stderr line.
export function createHost(profile, opts = {}) {
  const config = typeof profile === 'string'
    ? { name: profile, slices: profileSlices(profile) }
    : profile;
  const where = opts.hostLabel ? ` in ${opts.hostLabel}` : '';
  const withheldHint = opts.withheldHint || '';
  const host = {
    profile: config.name,
    vfs: opts.vfs || new MemoryVfs(),
    args: opts.args || [],
    getEnv: opts.getEnv || (() => undefined),
    sink: opts.sink || bufferSink(),
    streaming: !!opts.streaming,
    isolated: opts.isolated,
    stdoutBuf: [], stderrBuf: [],
    pathBuf: [], resultBuf: new Uint8Array(0), writeBuf: [],
    floatFmtBuf: new Uint8Array(0), strToFloatOk: 0,
    argBytes: null, waitCell: null,
  };
  host.reset = () => {
    host.stdoutBuf = []; host.stderrBuf = [];
    host.pathBuf = []; host.resultBuf = new Uint8Array(0); host.writeBuf = [];
    host.floatFmtBuf = new Uint8Array(0); host.strToFloatOk = 0; host.argBytes = null;
  };
  host.deliver = (stream) => {
    const buf = stream === 'stdout' ? host.stdoutBuf : host.stderrBuf;
    if (buf.length === 0) return;
    if (stream === 'stdout') host.stdoutBuf = []; else host.stderrBuf = [];
    host.sink.write(stream, buf);
  };
  host.deliverAll = () => {
    host.deliver('stdout');
    host.deliver('stderr');
  };
  host.flush = () => {
    host.deliverAll();
    if (host.sink.sync) host.sink.sync();
  };
  const takePath = () => { const s = dec(host.pathBuf); host.pathBuf = []; return s; };
  const fail = (e) => { host.resultBuf = enc(String((e && e.message) || e)); return 0; };
  const argBytes = (i) => {
    if (!host.argBytes) host.argBytes = host.args.map(enc);
    return host.argBytes[i];
  };
  const real = {
    mdk_write_byte: (b) => {
      host.stdoutBuf.push(b & 0xff);
      if (host.streaming && (b & 0xff) === 10) host.deliverAll();
    },
    mdk_write_err_byte: (b) => {
      host.stderrBuf.push(b & 0xff);
      if (host.streaming && (b & 0xff) === 10) host.deliverAll();
    },
    // floatToString: format the double, cache its bytes, return the byte length; the
    // module then reads each byte via mdk_float_fmt_byte to rebuild a $str.
    mdk_float_fmt: (d) => { host.floatFmtBuf = enc(fmt12g(d)); return host.floatFmtBuf.length; },
    mdk_float_fmt_byte: (i) => host.floatFmtBuf[i] & 0xff,
    // libm math: the transcendentals (+ pow/atan2/hypot) have no WasmGC opcode,
    // so they route to JS Math.*; the IEEE-exact ops lower to wasm opcodes.
    mdk_cbrt: Math.cbrt, mdk_exp: Math.exp, mdk_log: Math.log,
    mdk_log2: Math.log2, mdk_log10: Math.log10,
    mdk_sin: Math.sin, mdk_cos: Math.cos, mdk_tan: Math.tan,
    mdk_asin: Math.asin, mdk_acos: Math.acos, mdk_atan: Math.atan,
    mdk_sinh: Math.sinh, mdk_cosh: Math.cosh, mdk_tanh: Math.tanh,
    mdk_pow: Math.pow, mdk_atan2: Math.atan2, mdk_hypot: Math.hypot,
    // stringToFloat: the guest pushes the text through the path channel, then
    // calls mdk_str_to_float (parse AND latch the ok flag), then mdk_str_to_float_ok.
    // Two channels because Some(nan) is a legal strtod result, so NaN cannot double as
    // the failure signal.
    mdk_str_to_float: () => { const r = mdkStrToFloat(takePath()); host.strToFloatOk = r.ok; return r.value; },
    mdk_str_to_float_ok: () => host.strToFloatOk,
    // The byte channels (WH5): the guest pushes a path or name one byte at a time; the
    // host caches a result's bytes and exposes (length, byte-at-i).
    mdk_path_reset: () => { host.pathBuf = []; },
    mdk_path_push: (b) => { host.pathBuf.push(b & 0xff); },
    mdk_result_len: () => host.resultBuf.length,
    mdk_result_byte: (i) => host.resultBuf[i] & 0xff,
    mdk_read_file: () => {
      try { host.resultBuf = host.vfs.readFile(takePath()); return 1; } catch (e) { return fail(e); }
    },
    mdk_file_exists: () => (host.vfs.exists(takePath()) ? 1 : 0),
    // writeFileBytes: the path arrives on the path channel, the bytes stream into
    // writeBuf, commit writes them.  Ok -> 1; an error caches its message -> 0.
    mdk_write_file_reset: () => { host.writeBuf = []; },
    mdk_write_file_push: (b) => { host.writeBuf.push(b & 0xff); },
    mdk_write_file_commit: () => {
      const bytes = new Uint8Array(host.writeBuf);
      host.writeBuf = [];
      try { host.vfs.writeFile(takePath(), bytes); return 1; } catch (e) { return fail(e); }
    },
    mdk_get_env: () => {
      const v = host.getEnv(takePath());
      if (v === undefined) { host.resultBuf = new Uint8Array(0); return 0; }
      host.resultBuf = enc(v); return 1;
    },
    mdk_args_count: () => host.args.length,
    mdk_arg_len: (i) => argBytes(i).length,
    mdk_arg_byte: (i, j) => argBytes(i)[j] & 0xff,
    mdk_exit: (code) => { throw new ExitSignal(code | 0); },
    // Clock (design WA-1): reads in seconds, sleep in milliseconds.  A non-positive
    // sleep returns at once, as medaka_rt.c's mdk_sleep_ms does.  The wait cell is made
    // on first sleep so a page without SharedArrayBuffer still loads; there a sleep is
    // a named error, since returning at once would be a silently wrong program.
    mdk_wall_time_sec: () => Date.now() / 1000,
    mdk_monotonic_sec: () => performance.now() / 1000,
    mdk_sleep_ms: (ms) => {
      ms = Number(ms);
      if (ms <= 0) return;
      if (host.isolated === false || typeof SharedArrayBuffer === 'undefined')
        throw new CapabilityError('clock',
          '`sleep` needs cross-origin isolation, which this deployment does not provide');
      host.waitCell = host.waitCell || new Int32Array(new SharedArrayBuffer(4));
      // Output held back would otherwise sit behind the wait, and a kill mid-sleep
      // would lose it.
      if (host.streaming) host.flush();
      Atomics.wait(host.waitCell, 0, 0, ms);
    },
  };
  // Every key of every slice is a callable: real when an installed slice lists it,
  // otherwise one that throws the CapabilityError naming the withheld slice (WH3: never
  // a LinkError on a module the compiler legally emitted).
  const env = {};
  const installed = new Set(installedKeys(config));
  for (const [slice, { keys }] of Object.entries(SLICES))
    for (const k of keys) {
      if (k in env) continue;
      if (installed.has(k)) { env[k] = real[k]; continue; }
      const what = KEY_EXTERN[k] || k;
      env[k] = () => {
        throw new CapabilityError(slice,
          `${what} is not available${where}: the \`${slice}\` capability is withheld on ${config.name}${withheldHint}`);
      };
    }
  host.imports = { env };
  return host;
}

// Every `env` import key of `module` must be a key some slice lists: the host holds a
// callable for each of those (real, or the CapabilityError one).  A key in no slice
// would otherwise surface as a LinkError, or worse, a silently absent adapter.
export function checkImportKeys(module, host) {
  const known = new Set(Object.values(SLICES).flatMap((s) => s.keys));
  const missing = [...new Set(WebAssembly.Module.imports(module)
    .filter((i) => i.module === 'env' && !known.has(i.name))
    .map((i) => i.name))];
  if (missing.length > 0)
    throw new HostKeyError(
      `module imports ${missing.map((k) => 'env.' + k).join(', ')}, which no slice of ${host.profile} provides`,
      missing);
}

export function makeImports(profile, opts) { return createHost(profile, opts).imports; }

// Compile (unless given a Module), refuse an old entry shape, instantiate, call
// `mdk_main`, and flush on every way out.  `inProgram` says whether `mdk_main` had
// started: a failure after that is the program's, not the instantiation's.
export async function runProgram(wasm, host, opts = {}) {
  let inProgram = false;
  try {
    const module = wasm instanceof WebAssembly.Module ? wasm : await WebAssembly.compile(wasm);
    const names = WebAssembly.Module.exports(module).map((e) => e.name);
    if (names.includes('mdk_main') && !names.includes('mdk_entry_split'))
      throw new OldEntryShape(opts.oldEntryMessage
        || 'this module was built by an older compiler: its start function runs main itself; rebuild it');
    checkImportKeys(module, host);
    const instance = await WebAssembly.instantiate(module, host.imports);
    inProgram = true;
    if (typeof instance.exports.mdk_main === 'function') instance.exports.mdk_main();
    host.flush();
    return { kind: 'done' };
  } catch (e) {
    host.flush();
    if (e instanceof ExitSignal) return { kind: 'exit', code: e.code };
    return { kind: 'error', error: e, inProgram };
  }
}
