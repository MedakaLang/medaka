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
//   opts = { vfs, args, getEnv, executablePath, stdin, sink, streaming, isolated, hostLabel, withheldHint }

// ── capability slices ────────────────────────────────────────────────────────
// Each slice lists the import keys it implements.  A key may sit in several slices
// when they share it (the path and result byte channels, WH5); it is real when any
// installed slice lists it.  `needs` is the effect labels a profile must grant for
// the slice to be installed; `process` marks the slices only a process host has
// (`args` and `exit` carry no effect label in stdlib/runtime.mdk).
const PATH_KEYS = ['mdk_path_reset', 'mdk_path_push'];
const GRANT_KEYS = ['mdk_grant_reset', 'mdk_grant_push'];
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
      'mdk_read_file', 'mdk_file_exists', 'mdk_canonicalize_path',
      'mdk_write_file_reset', 'mdk_write_file_push', 'mdk_write_file_commit',
      'mdk_write_file', 'mdk_append_file', 'mdk_rename', 'mdk_list_dir', 'mdk_stat_file', 'mdk_stat_field',
      'mdk_make_dir', 'mdk_remove_file', 'mdk_remove_dir', 'mdk_fsync', 'mdk_file_mode', 'mdk_write_file_mode',
      ...PATH_KEYS, ...RESULT_KEYS, ...GRANT_KEYS,
    ],
    externs: [
      'readFile', 'readFileBytes', 'fileExists', 'canonicalizePath', 'writeFile', 'writeFileBytes',
      'appendFile', 'writeFileMode', 'rename', 'listDir', 'statFile', 'fileMode', 'makeDir', 'removeFile', 'removeDir',
      'fsync',
    ],
  },
  // A declared file bound's frame (EFFECTS-SEMANTICS §7) is bookkeeping, not a
  // capability: a bounded body that performs no file operation runs anywhere.
  filebound: { needs: [], keys: ['mdk_file_bound_enter', 'mdk_file_bound_exit', ...GRANT_KEYS] },
  env: {
    needs: ['Env'],
    keys: ['mdk_get_env', 'mdk_executable_path', ...PATH_KEYS, ...RESULT_KEYS],
    externs: ['getEnv', 'executablePath'],
  },
  args: { needs: [], process: true, keys: ['mdk_args_count', 'mdk_arg_len', 'mdk_arg_byte'], externs: ['args'] },
  exit: { needs: [], process: true, keys: ['mdk_exit'], externs: ['exit'] },
  clock: {
    needs: ['Clock'],
    keys: ['mdk_wall_time_sec', 'mdk_monotonic_sec', 'mdk_sleep_ms'],
    externs: ['wallTimeSec', 'monotonicSec', 'sleepMs'],
  },
  entropy: { needs: ['Rand'], keys: ['mdk_os_entropy', ...RESULT_KEYS], externs: ['osEntropyBytes'] },
  stdin: {
    needs: ['Stdin'],
    keys: ['mdk_read_line', 'mdk_read_all', 'mdk_read_exactly', ...RESULT_KEYS],
    externs: ['readLine', 'readLineOpt', 'readAll', 'readExactly'],
  },
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
  slices: ['stdout', 'stderr', 'floatfmt', 'math', 'strtod', 'fs', 'filebound', 'env', 'args', 'exit', 'clock'],
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
// None now: every extern a granted slice serves has a wasm lowering.
export const WASM_GAP_EXTERNS = [];

// The extern a key serves, for a withheld slice's message.  medaka_host_test.mjs asserts
// every key of a withholdable slice has a row naming one of that slice's `externs`.
export const KEY_EXTERN = {
  mdk_write_byte: 'putStr', mdk_write_err_byte: 'ePutStr',
  mdk_read_file: 'readFile', mdk_file_exists: 'fileExists', mdk_canonicalize_path: 'canonicalizePath',
  mdk_write_file_reset: 'writeFileBytes', mdk_write_file_push: 'writeFileBytes',
  mdk_write_file_commit: 'writeFileBytes', mdk_write_file: 'writeFile', mdk_append_file: 'appendFile',
  mdk_rename: 'rename',
  mdk_list_dir: 'listDir', mdk_stat_file: 'statFile', mdk_stat_field: 'statFile', mdk_get_env: 'getEnv',
  mdk_make_dir: 'makeDir', mdk_remove_file: 'removeFile', mdk_remove_dir: 'removeDir', mdk_fsync: 'fsync', mdk_file_mode: 'fileMode',
  mdk_write_file_mode: 'writeFileMode',
  mdk_read_line: 'readLine', mdk_read_all: 'readAll', mdk_read_exactly: 'readExactly',
  mdk_os_entropy: 'osEntropyBytes', mdk_executable_path: 'executablePath',
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
// A module imports an `env` key no slice lists: the compiler emitted a key the host cannot
// even withhold, so the profile and the slice set have drifted.
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
// A byte string holds one char per byte (Node's `latin1`), so `===`, `startsWith` and
// `length` on two of them compare and count bytes, as strcmp, strncmp and strlen do.
const byteString = (bytes) => { let s = ''; for (const b of bytes) s += String.fromCharCode(b); return s; };
const byteStringBytes = (s) => Uint8Array.from(s, (c) => c.charCodeAt(0));

// ── vfs ──────────────────────────────────────────────────────────────────────
// The file source behind the `fs` slice: readFile(path) -> bytes (throws an Error
// whose message is the guest's Err text), exists(path) -> bool, writeFile(path, bytes),
// and for confinement realpath(path) -> the canonical path (throws when it has none)
// and lexists(path) -> whether an entry is present, a dangling symlink included.
// Those two take and return byte strings (one char per byte, Node's `latin1`), since
// confinement compares paths as bytes and a name need not be UTF-8; every other
// primitive takes the guest's path as text.
// Four more primitives serve the directory and metadata externs: stat(path) -> { size,
// isDir, isFile, mtime (seconds), mode (permission bits) } (follows links, throws when
// the path is absent), readdir(path) -> the entry names (throws on a missing path or a
// non-directory) and rename(src, dst).  writeFile(path, bytes, mode?) sets the file's
// permission bits to `mode` when one is given.
// An in-memory vfs, with the path model of docs/spec/WASM-SEMANTICS.md §3: the root
// is also the working directory, so `a` and `/a` name one entry and `.` and `/` name
// the root; the empty path names nothing (ENOENT, as open(2) answers); `.` and empty
// components are dropped, `..` steps up (never above the root), and every component
// a `/` follows must be an existing directory.  The root always exists; another directory exists
// when a constructor entry lies under it, since nothing a program calls creates one.
// A missing path, or a write into a missing directory, is an Err naming the path,
// never empty contents; the texts are Node's, as on test/wasm/run.js.
export class MemoryVfs {
  constructor(entries) {
    this.files = new Map();
    this.dirs = new Set(['']);
    // A file's permission bits and modification time (seconds), by key.  A file made
    // without a mode reads 0o644, as a file created under the usual umask does, and a
    // directory 0o755.
    this.modes = new Map();
    this.mtimes = new Map();
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
    if (p === '') return { error: 'ENOENT: no such file or directory' };
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
  // The canonical absolute form of an existing path, the root being `/`; it has no
  // symbolic links, so an entry is present exactly when it exists.  Both take a byte
  // string; every name here is guest text, so the bytes are well-formed UTF-8.
  realpath(b) {
    const p = dec(byteStringBytes(b));
    const { key, error } = this.resolve(p);
    if (error || !(this.dirs.has(key) || this.files.has(key)))
      throw new Error(`ENOENT: no such file or directory, realpath '${p}'`);
    return byteString(enc('/' + key));
  }
  lexists(b) { return this.exists(dec(byteStringBytes(b))); }
  writeFile(p, bytes, mode) {
    const { key, error } = this.resolve(p);
    if (error) throw new Error(`${error}, open '${p}'`);
    if (this.dirs.has(key)) throw new Error(`EISDIR: illegal operation on a directory, open '${p}'`);
    this.files.set(key, bytes);
    if (mode !== undefined) this.modes.set(key, mode & 0o7777);
    this.mtimes.set(key, Math.floor(Date.now() / 1000));
  }
  // appendFile: the bytes go to the end of the file, which is created (at the default
  // mode) when absent; an existing file keeps its mode.
  appendFile(p, bytes) {
    const { key, error } = this.resolve(p);
    if (error) throw new Error(`${error}, open '${p}'`);
    if (this.dirs.has(key)) throw new Error(`EISDIR: illegal operation on a directory, open '${p}'`);
    const old = this.files.get(key) || new Uint8Array(0);
    const out = new Uint8Array(old.length + bytes.length);
    out.set(old, 0);
    out.set(bytes, old.length);
    this.files.set(key, out);
    this.mtimes.set(key, Math.floor(Date.now() / 1000));
  }
  stat(p) {
    const { key, error } = this.resolve(p);
    const isDir = !error && this.dirs.has(key);
    if (error || !(isDir || this.files.has(key)))
      throw new Error(`ENOENT: no such file or directory, stat '${p}'`);
    if (isDir) return { size: 0, isDir: true, isFile: false, mtime: 0, mode: 0o755 };
    return {
      size: this.files.get(key).length, isDir: false, isFile: true,
      mtime: this.mtimes.get(key) || 0, mode: this.modes.has(key) ? this.modes.get(key) : 0o644,
    };
  }
  readdir(p) {
    const { key, error } = this.resolve(p);
    if (error) throw new Error(`${error}, scandir '${p}'`);
    if (!this.dirs.has(key)) {
      if (this.files.has(key)) throw new Error(`ENOTDIR: not a directory, scandir '${p}'`);
      throw new Error(`ENOENT: no such file or directory, scandir '${p}'`);
    }
    const prefix = key === '' ? '' : key + '/';
    const names = new Set();
    for (const k of [...this.files.keys(), ...this.dirs])
      if (k !== '' && k.startsWith(prefix) && k.length > prefix.length) names.add(k.slice(prefix.length).split('/')[0]);
    return [...names];
  }
  // rename(2) over files and directories: a file replaces a file, a directory moves
  // with everything under it and replaces only an empty directory.
  rename(a, b) {
    const src = this.resolve(a), dst = this.resolve(b);
    const fail = (e) => { throw new Error(`${e}, rename '${a}' -> '${b}'`); };
    if (src.error) fail(src.error);
    if (dst.error) fail(dst.error);
    const sk = src.key, dk = dst.key;
    const srcDir = this.dirs.has(sk);
    if (!srcDir && !this.files.has(sk)) fail('ENOENT: no such file or directory');
    if (sk === dk) return;
    if (srcDir && (dk === '' || dk.startsWith(sk + '/'))) fail('EINVAL: invalid argument');
    if (sk === '') fail('EBUSY: resource busy or locked');
    if (!srcDir && this.dirs.has(dk)) fail('EISDIR: illegal operation on a directory');
    if (srcDir && this.files.has(dk)) fail('ENOTDIR: not a directory');
    if (srcDir && this.dirs.has(dk) && this.readdir(dk).length > 0) fail('ENOTEMPTY: directory not empty');
    const move = (k) => dk + k.slice(sk.length);
    for (const [k, bytes] of [...this.files])
      if (k === sk || k.startsWith(sk + '/')) {
        this.files.delete(k); this.files.set(move(k), bytes);
        for (const m of [this.modes, this.mtimes])
          if (m.has(k)) { m.set(move(k), m.get(k)); m.delete(k); }
      }
    if (srcDir)
      for (const k of [...this.dirs])
        if (k === sk || k.startsWith(sk + '/')) { this.dirs.delete(k); this.dirs.add(move(k)); }
  }
  // unlink(2): removes a file; a directory is EISDIR, a missing path ENOENT.
  unlink(p) {
    const { key, error } = this.resolve(p);
    if (error) throw new Error(`${error}, unlink '${p}'`);
    if (this.dirs.has(key)) throw new Error(`EISDIR: illegal operation on a directory, unlink '${p}'`);
    if (!this.files.has(key)) throw new Error(`ENOENT: no such file or directory, unlink '${p}'`);
    this.files.delete(key);
    this.modes.delete(key);
    this.mtimes.delete(key);
  }
  // fsync(2) on a file or a directory: nothing to flush in memory, so only the path's
  // existence is answered.
  fsync(p) {
    const { key, error } = this.resolve(p);
    if (error) throw new Error(`${error}, fsync '${p}'`);
    if (!(this.dirs.has(key) || this.files.has(key))) throw new Error(`ENOENT: no such file or directory, fsync '${p}'`);
  }
  // mkdir(2) at mode 0o755: the parent must be a directory, and an existing entry of
  // either kind is EEXIST.
  mkdir(p) {
    const { key, error } = this.resolve(p);
    if (error) throw new Error(`${error}, mkdir '${p}'`);
    if (this.dirs.has(key) || this.files.has(key)) throw new Error(`EEXIST: file already exists, mkdir '${p}'`);
    this.dirs.add(key);
  }
  // rmdir(2): removes an empty directory; a file is ENOTDIR, the root EBUSY.
  rmdir(p) {
    const { key, error } = this.resolve(p);
    if (error) throw new Error(`${error}, rmdir '${p}'`);
    if (this.files.has(key)) throw new Error(`ENOTDIR: not a directory, rmdir '${p}'`);
    if (!this.dirs.has(key)) throw new Error(`ENOENT: no such file or directory, rmdir '${p}'`);
    if (key === '') throw new Error(`EBUSY: resource busy or locked, rmdir '${p}'`);
    if (this.readdir(key).length > 0) throw new Error(`ENOTEMPTY: directory not empty, rmdir '${p}'`);
    this.dirs.delete(key);
  }
}

// ── confinement (EFFECTS-SEMANTICS §7) ──────────────────────────────────────
// The port of runtime/medaka_rt.c's mdk_canon_path, mdk_element_admits,
// mdk_confine and mdk_confine_bounds, over a vfs's `realpath` (realpath(3): throws
// when a path does not resolve) and `lexists` (lstat(2) succeeds).  Every path here
// is a byte string, so two names that are not UTF-8 stay as distinct as their bytes,
// and lengths count bytes against Linux's PATH_MAX, as the C buffers do.
const PATH_MAX = 4096;

// The components of `p`, split on `/`, with empty and `.` components dropped.
const pathComponents = (p) => p.split('/').filter((c) => c !== '' && c !== '.');

// `/` or `.` followed by comps[0..k), joined by `/`; null past PATH_MAX.
function pathJoin(absolute, comps, k) {
  let out = absolute ? '/' : '.';
  for (let i = 0; i < k; i++) {
    if (out.length + 1 + comps[i].length >= PATH_MAX) return null;
    out += (absolute && out === '/' ? '' : '/') + comps[i];
  }
  return out;
}

// `dir` (canonical) followed by `/name`; null past PATH_MAX.
function pathAppend(dir, name) {
  const root = dir === '/';
  if (dir.length + (root ? 0 : 1) + name.length >= PATH_MAX) return null;
  return dir + (root ? '' : '/') + name;
}

function tryRealpath(vfs, p) {
  try { return vfs.realpath(p); } catch (e) { return null; }
}

// The canonical form of `p`, or null when it has none: the realpath of the longest
// prefix that resolves, followed by the remaining components, which may not include
// `..` and whose first must be absent (an entry present that does not resolve is a
// dangling or looping symlink).  In entry mode the last component is appended to
// its directory's canonical form unresolved.
export function canonPath(vfs, p, entry) {
  if (p === '' || p.length >= PATH_MAX) return null;
  const absolute = p[0] === '/';
  const comps = pathComponents(p);
  const n = comps.length;
  if (entry && n > 0 && comps[n - 1] !== '..') {
    const probe = pathJoin(absolute, comps, n - 1);
    const dir = probe === null ? null : canonPath(vfs, probe, false);
    return dir === null ? null : pathAppend(dir, comps[n - 1]);
  }
  let k = n;
  let out = null;
  for (; k >= 0; k--) {
    const probe = pathJoin(absolute, comps, k);
    if (probe === null) return null;
    out = tryRealpath(vfs, probe);
    if (out !== null) break;
  }
  if (k < 0) return null;
  if (k === n) return out;
  for (let i = k; i < n; i++) if (comps[i] === '..') return null;
  const first = pathAppend(out, comps[k]);
  if (first === null || vfs.lexists(first)) return null;
  for (let i = k; i < n; i++) {
    out = pathAppend(out, comps[i]);
    if (out === null) return null;
  }
  return out;
}

// Whether one grant element admits the canonical path `canon`: an exact element by
// canonical equality, a pattern `<dir>/<stem>*` by prefix of the canonical `<dir>`
// followed by `/<stem>` (and `<dir>` itself for an empty stem), `*` alone always.
function elementAdmits(vfs, elem, canon) {
  if (elem.length >= PATH_MAX) return false;
  if (elem.endsWith('*')) {
    const e = elem.slice(0, -1);
    if (e === '') return true;
    const slash = e.lastIndexOf('/');
    const dir = slash < 0 ? '.' : slash === 0 ? '/' : e.slice(0, slash);
    const stem = slash < 0 ? e : e.slice(slash + 1);
    const want = canonPath(vfs, dir, false);
    if (want === null) return false;
    if (stem === '' && canon === want) return true;
    const prefix = pathAppend(want, stem);
    return prefix !== null && canon.startsWith(prefix);
  }
  const c = canonPath(vfs, elem, false);
  return c !== null && c === canon;
}

// null when `grant` (`[]` = the whole domain) admits `path`, else the refusal text.
// `path` and the grant are the guest's text, which is UTF-8, so its byte strings are
// exactly the bytes native compares.
export function confine(vfs, path, grant, entry) {
  if (grant.length === 0) return null;
  const canon = canonPath(vfs, byteString(enc(path)), entry);
  if (canon !== null && grant.some((g) => elementAdmits(vfs, byteString(enc(g)), canon))) return null;
  return `${path} is outside the granted authority [${grant.map((g) => `"${g}"`).join(', ')}]`;
}

// Byte order of two encoded names.
const compareBytes = (a, b) => {
  for (let i = 0; i < a.length && i < b.length; i++) if (a[i] !== b[i]) return a[i] - b[i];
  return a.length - b.length;
};

// A missing grant (null) equals no grant, not even another missing one.
const sameGrant = (a, b) => a !== null && b !== null && a.length === b.length && a.every((g, i) => g === b[i]);

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
    withheldError: (slice, k) => new CapabilityError(slice,
      `${KEY_EXTERN[k] || k} is not available${where}: the \`${slice}\` capability is withheld on ${config.name}${withheldHint}`),
    vfs: opts.vfs || new MemoryVfs(),
    args: opts.args || [],
    getEnv: opts.getEnv || (() => undefined),
    // The path the guest's `executablePath` answers: the wasm module's own file, where
    // the host knows it (test/wasm/run.js); "" otherwise.
    executablePath: opts.executablePath ?? '',
    // A blocking read of standard input: the next bytes, or none (zero length) at end.
    stdin: opts.stdin || (() => new Uint8Array(0)),
    stdinBuf: new Uint8Array(0), stdinPos: 0, stdinEof: false,
    sink: opts.sink || bufferSink(),
    streaming: !!opts.streaming,
    isolated: opts.isolated,
    stdoutBuf: [], stderrBuf: [],
    pathBuf: [], resultBuf: new Uint8Array(0), writeBuf: [],
    floatFmtBuf: new Uint8Array(0), strToFloatOk: 0,
    argBytes: null, waitCell: null,
    // The grant the guest pushed for the next file operation (null: none pushed, or
    // already taken), the element it is pushing, the grant that ended with a -2 push
    // (a two-path operation's first), the stat the last mdk_stat_file took, and the
    // declared bounds entered: { write, grant, active }, innermost last.
    grant: null, grantElem: [], grantFirst: null, stat: null, bounds: [],
  };
  host.reset = () => {
    host.stdoutBuf = []; host.stderrBuf = [];
    host.pathBuf = []; host.resultBuf = new Uint8Array(0); host.writeBuf = [];
    host.stdinBuf = new Uint8Array(0); host.stdinPos = 0; host.stdinEof = false;
    host.floatFmtBuf = new Uint8Array(0); host.strToFloatOk = 0; host.argBytes = null;
    host.grant = null; host.grantElem = []; host.grantFirst = null; host.stat = null; host.bounds = [];
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
  // Append the source's next bytes to the buffer, dropping what was consumed; false
  // once the source answers with none.
  const stdinMore = () => {
    if (host.stdinEof) return false;
    const c = host.stdin();
    if (!c || c.length === 0) { host.stdinEof = true; return false; }
    const rest = host.stdinBuf.subarray(host.stdinPos);
    const nb = new Uint8Array(rest.length + c.length);
    nb.set(rest); nb.set(c, rest.length);
    host.stdinBuf = nb; host.stdinPos = 0;
    return true;
  };
  const takePath = () => { const s = dec(host.pathBuf); host.pathBuf = []; return s; };
  const fail = (e) => { host.resultBuf = enc(String((e && e.message) || e)); return 0; };
  // A grant is taken by the operation it was pushed for, so an operation that finds
  // none refuses rather than inherit a previous call's.
  const takeGrant = () => { const g = host.grant; host.grant = null; host.grantFirst = null; return g; };
  // A missing grant (null) refuses every path.
  const confineUnder = (grant, path, entry) => grant === null
    ? `${path} is outside the granted authority: no grant was given`
    : confine(host.vfs, path, grant, entry);
  // The refusal text for `path` under `grant`, or null: the grant, then each active
  // bound of the operation's mode, innermost first (mdk_confine_bounds).
  const refusalUnder = (grant, path, entry, write) => {
    let refused = confineUnder(grant, path, entry);
    for (let i = host.bounds.length - 1; refused === null && i >= 0; i--) {
      const b = host.bounds[i];
      if (b.active && b.write === write) refused = confineUnder(b.grant, path, entry);
    }
    return refused;
  };
  const refusal = (path, entry, write) => refusalUnder(takeGrant(), path, entry, write);
  const refuse = (msg) => { host.resultBuf = enc(msg); return 0; };
  // The write channel's bytes to the path on the path channel, in write mode.
  // `mode`, when given, is the permission bits the file is left at (writeFileMode).
  const commitWrite = (append, mode) => {
    const bytes = new Uint8Array(host.writeBuf);
    host.writeBuf = [];
    const p = takePath();
    const refused = refusal(p, false, 1);
    if (refused !== null) return refuse(refused);
    try {
      if (append) host.vfs.appendFile(p, bytes); else host.vfs.writeFile(p, bytes, mode);
      return 1;
    } catch (e) { return fail(e); }
  };
  // statFile and fileMode: confine the path as a read that follows its last component,
  // then take its stat for mdk_stat_field.
  const takeStat = () => {
    const p = takePath();
    const refused = refusal(p, false, 0);
    if (refused !== null) return refuse(refused);
    try { host.stat = host.vfs.stat(p); return 1; } catch (e) { return fail(e); }
  };
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
    // The grant channel: each element's bytes, each ended by -1; reset starts a grant.
    // A -2 ends the grant pushed so far and starts the next (rename's second).
    mdk_grant_reset: () => { host.grant = []; host.grantElem = []; host.grantFirst = null; },
    mdk_grant_push: (b) => {
      if (b === -2) { host.grantFirst = host.grant; host.grant = []; host.grantElem = []; }
      else if (b < 0) { host.grant.push(dec(host.grantElem)); host.grantElem = []; }
      else host.grantElem.push(b & 0xff);
    },
    // A declared bound (mdk_with_file_bound): `keep` 1 always records a frame, which
    // exit pops; `keep` 0 (a tail position) records one only when it restricts, and
    // the guest calls exit only when this returns 1.  The whole domain, or an equal
    // bound of the same mode already active, adds no restriction.  A bound entered
    // with no grant pushed records one that refuses every path of its mode.
    mdk_file_bound_enter: (write, keep) => {
      const grant = takeGrant();
      const active = grant === null || (grant.length > 0
        && !host.bounds.some((b) => b.active && b.write === write && sameGrant(b.grant, grant)));
      if (active || keep) host.bounds.push({ write, grant, active });
      return active ? 1 : 0;
    },
    mdk_file_bound_exit: () => { host.bounds.pop(); },
    mdk_read_file: () => {
      const p = takePath();
      const refused = refusal(p, false, 0);
      if (refused !== null) return refuse(refused);
      try { host.resultBuf = host.vfs.readFile(p); return 1; } catch (e) { return fail(e); }
    },
    // fileExists and canonicalizePath return no Result: a refusal is 2 / 0 with its
    // text on the result channel, and the guest panics with it.
    mdk_file_exists: () => {
      const p = takePath();
      const refused = refusal(p, false, 0);
      if (refused !== null) { refuse(refused); return 2; }
      return host.vfs.exists(p) ? 1 : 0;
    },
    // realpath(3), or the path unchanged when it has none (mdk_canonicalize_path).  A
    // resolved name that is not UTF-8 reaches the guest with each ill-formed subpart
    // as U+FFFD, as native's mdk_str_lossy gives it.
    mdk_canonicalize_path: () => {
      const p = takePath();
      const refused = refusal(p, false, 0);
      if (refused !== null) return refuse(refused);
      let out = p;
      try { out = dec(byteStringBytes(host.vfs.realpath(byteString(enc(p))))); } catch (e) { out = p; }
      host.resultBuf = enc(out);
      return 1;
    },
    // writeFileBytes: the path arrives on the path channel, the bytes stream into
    // writeBuf, commit writes them.  Ok -> 1; an error caches its message -> 0.
    mdk_write_file_reset: () => { host.writeBuf = []; },
    mdk_write_file_push: (b) => { host.writeBuf.push(b & 0xff); },
    mdk_write_file_commit: () => commitWrite(false),
    // writeFile: the contents stream into writeBuf as writeFileBytes' do.
    mdk_write_file: () => commitWrite(false),
    // appendFile: the same stream, appended to the file (created when absent).
    mdk_append_file: () => commitWrite(true),
    // writeFileMode: the same stream, the file left at the mode (path, mode, contents).
    mdk_write_file_mode: (m) => commitWrite(false, m & 0o7777),
    // rename: both paths arrive on the path channel, the source's bytes first, `srcLen`
    // of them; each is confined in entry mode under its own grant, source first.
    mdk_rename: (srcLen) => {
      const bytes = host.pathBuf; host.pathBuf = [];
      const src = dec(bytes.slice(0, srcLen)), dst = dec(bytes.slice(srcLen));
      const gs = host.grantFirst, gd = takeGrant();
      const refused = refusalUnder(gs, src, true, 1) ?? refusalUnder(gd, dst, true, 1);
      if (refused !== null) return refuse(refused);
      try { host.vfs.rename(src, dst); return 1; } catch (e) { return fail(e); }
    },
    // listDir: the entry names, sorted by their UTF-8 bytes, each followed by a NUL.
    mdk_list_dir: () => {
      const p = takePath();
      const refused = refusal(p, false, 0);
      if (refused !== null) return refuse(refused);
      let names;
      try { names = host.vfs.readdir(p).filter((n) => n !== '.' && n !== '..'); } catch (e) { return fail(e); }
      const parts = names.map(enc).sort(compareBytes);
      const out = new Uint8Array(parts.reduce((n, a) => n + a.length + 1, 0));
      let at = 0;
      for (const a of parts) { out.set(a, at); at += a.length + 1; }
      host.resultBuf = out;
      return 1;
    },
    // statFile: take the stat, then read its fields as f64s by index: size, isDir,
    // isFile, mtime in seconds, permission bits.
    // fileMode takes the same stat (its field 4 is the mode), so both share takeStat.
    mdk_stat_file: takeStat,
    mdk_file_mode: takeStat,
    mdk_stat_field: (i) => {
      const st = host.stat;
      return [st.size, st.isDir ? 1 : 0, st.isFile ? 1 : 0, st.mtime, st.mode][i];
    },
    // makeDir, removeFile and removeDir: the path is confined in entry mode, so a
    // symbolic link as the last component is the entry itself (makeDir finds it
    // present; the removals take it, not its target).
    mdk_make_dir: () => {
      const p = takePath();
      const refused = refusal(p, true, 1);
      if (refused !== null) return refuse(refused);
      try { host.vfs.mkdir(p); return 1; } catch (e) { return fail(e); }
    },
    mdk_remove_file: () => {
      const p = takePath();
      const refused = refusal(p, true, 1);
      if (refused !== null) return refuse(refused);
      try { host.vfs.unlink(p); return 1; } catch (e) { return fail(e); }
    },
    mdk_remove_dir: () => {
      const p = takePath();
      const refused = refusal(p, true, 1);
      if (refused !== null) return refuse(refused);
      try { host.vfs.rmdir(p); return 1; } catch (e) { return fail(e); }
    },
    // fsync: a regular file or a directory, confined as a write that follows its last
    // component.
    mdk_fsync: () => {
      const p = takePath();
      const refused = refusal(p, false, 1);
      if (refused !== null) return refuse(refused);
      try { host.vfs.fsync(p); return 1; } catch (e) { return fail(e); }
    },
    mdk_get_env: () => {
      const v = host.getEnv(takePath());
      if (v === undefined) { host.resultBuf = new Uint8Array(0); return 0; }
      host.resultBuf = enc(v); return 1;
    },
    // Standard input: one buffer behind all four readers, as the C `stdin` stream is.
    // End of input is sticky once the source has answered with no bytes.
    // readLine/readLineOpt: 1 with the line (newline stripped, any CR kept) on the
    // result channel; 0 at end of input with nothing read.
    mdk_read_line: () => {
      let from = host.stdinPos;
      for (;;) {
        const i = host.stdinBuf.indexOf(10, from);
        if (i >= 0) { host.resultBuf = host.stdinBuf.slice(host.stdinPos, i); host.stdinPos = i + 1; return 1; }
        const scanned = host.stdinBuf.length - host.stdinPos;
        if (!stdinMore()) {
          host.resultBuf = host.stdinBuf.slice(host.stdinPos);
          host.stdinPos = host.stdinBuf.length;
          return host.resultBuf.length > 0 ? 1 : 0;
        }
        from = scanned;
      }
    },
    mdk_read_all: () => {
      while (stdinMore()) { /* drain */ }
      host.resultBuf = host.stdinBuf.slice(host.stdinPos);
      host.stdinPos = host.stdinBuf.length;
    },
    // readExactly: 1 with the n bytes; 0 at end of input or on a short read, which
    // still consumes what was there.  A count of zero or less is an empty Some.
    mdk_read_exactly: (n) => {
      n = Number(n);
      if (n <= 0) { host.resultBuf = new Uint8Array(0); return 1; }
      while (host.stdinBuf.length - host.stdinPos < n && stdinMore()) { /* fill */ }
      const have = Math.min(n, host.stdinBuf.length - host.stdinPos);
      host.resultBuf = host.stdinBuf.slice(host.stdinPos, host.stdinPos + have);
      host.stdinPos += have;
      return have === n ? 1 : 0;
    },
    // osEntropyBytes: n bytes from the platform's CSPRNG, in chunks of at most 65,536
    // (the Web Crypto limit).  A negative or oversized count is refused with native's
    // panic text (runtime/medaka_rt.c mdk_os_entropy_bytes) and no bytes.
    mdk_os_entropy: (n) => {
      n = BigInt(n);
      if (n < 0n) { host.resultBuf = enc('osEntropyBytes: length must be non-negative'); return 0; }
      if (n > (2n ** 63n - 1n) / 8n - 1n) { host.resultBuf = enc('osEntropyBytes: requested length is too large'); return 0; }
      const out = new Uint8Array(Number(n));
      for (let off = 0; off < out.length; off += 65536)
        crypto.getRandomValues(out.subarray(off, Math.min(off + 65536, out.length)));
      host.resultBuf = out;
      return 1;
    },
    mdk_executable_path: () => { host.resultBuf = enc(host.executablePath); return 1; },
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
  host.installed = installed;
  for (const [slice, { keys }] of Object.entries(SLICES))
    for (const k of keys) {
      if (k in env) continue;
      if (installed.has(k)) { env[k] = real[k]; continue; }
      env[k] = () => { throw host.withheldError(slice, k); };
    }
  host.imports = { env };
  return host;
}

// Every `env` import key of `module` must be a key the host installs for real
// (`installedKeys`): a module imports only the keys its reached externs call, so an
// import the host withholds is a program the profile cannot run, refused before
// instantiation instead of left to a stub that throws mid-run.  `host.installed`
// is the set `installedKeys` gives the host's profile or configuration.
export function checkImportKeys(module, host) {
  const missing = [...new Set(WebAssembly.Module.imports(module)
    .filter((i) => i.module === 'env' && !host.installed.has(i.name))
    .map((i) => i.name))];
  // A key some slice owns is that slice withheld: the program needs a capability the
  // profile does not grant, so the refusal names it, as the stub would have at the call.
  for (const k of missing) {
    const slice = Object.keys(SLICES).find((s) => SLICES[s].keys.includes(k));
    if (slice) throw host.withheldError(slice, k);
  }
  if (missing.length > 0)
    throw new HostKeyError(
      `module imports ${missing.map((k) => 'env.' + k).join(', ')}, which no slice of ${host.profile} lists`,
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
