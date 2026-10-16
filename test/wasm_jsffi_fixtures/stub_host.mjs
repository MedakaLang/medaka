// A test-local host for `js` bindings: `node stub_host.mjs <module.wasm> <bindings.mjs>`.
//
// It runs a module the way test/wasm/run.js does (createHost('wasmgc/node'),
// runProgram, the same exit and stderr reporting) and adds the `jsffi` import
// object itself, built from the module's own `jsffi` imports and the named
// exports of the bindings module.  Each wrapper implements
// docs/spec/WASM-SEMANTICS.md section 3.1 over createHost's path and result
// channels; the real host slice in playground/medaka_host.mjs is held to the
// same section.
import fs from 'node:fs';
import nodePath from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const here = nodePath.dirname(fileURLToPath(import.meta.url));
const hostUrl = pathToFileURL(nodePath.join(here, '..', '..', 'playground', 'medaka_host.mjs')).href;
const { createHost, runProgram, CapabilityError } = await import(hostUrl);

class JsBindingError extends Error {
  constructor(binding, message) {
    super(message);
    this.name = 'JsBindingError';
    this.binding = binding;
  }
}

// `<jsName>:<P1>,...,<Pn>-><R>`
function parseField(field) {
  const colon = field.indexOf(':');
  const sig = field.slice(colon + 1);
  const arrow = sig.lastIndexOf('->');
  const params = sig.slice(0, arrow);
  return {
    name: field.slice(0, colon),
    params: params === '' ? [] : params.split(','),
    result: sig.slice(arrow + 2),
  };
}

function describe(v) {
  if (typeof v === 'bigint') return `the BigInt ${v}`;
  if (typeof v === 'string') return v.isWellFormed() ? 'a string' : 'a string with a lone surrogate';
  if (typeof v === 'number') return `the Number ${v}`;
  return v === null ? 'null' : `a value of type ${typeof v}`;
}

const NARROW = { U8: [0, 255], U16: [0, 65535], U32: [0, 4294967295], I32: [-2147483648, 2147483647] };

// The arguments one call carries: scalars from the wasm parameters, `String`
// and `Array` contents from the path channel, in parameter order.
function decodeArgs(params, wire, bytes) {
  const args = [];
  const arrays = [];
  let at = 0;
  let wi = 0;
  for (const p of params) {
    if (p === 'Unit') continue;
    const w = wire[wi++];
    if (p === 'String') {
      args.push(new TextDecoder().decode(bytes.subarray(at, at + w)));
      at += w;
    } else if (p === 'Array') {
      const a = new BigInt64Array(w);
      const dv = new DataView(bytes.buffer, bytes.byteOffset + at, w * 8);
      for (let i = 0; i < w; i++) a[i] = dv.getBigInt64(i * 8, true);
      at += w * 8;
      args.push(a);
      arrays.push(a);
    } else if (p === 'U64') args.push(BigInt.asUintN(64, w));
    else if (p === 'Bool') args.push(w !== 0);
    else if (p === 'Char') args.push(String.fromCodePoint(w));
    else if (p === 'U32') args.push(w >>> 0);
    else args.push(w);
  }
  return { args, arrays };
}

// The result's wasm value (undefined for `String` and `Unit`), and the bytes
// it puts on the result channel after the copy-back words.
function encodeResult(name, result, v) {
  const bad = () => new JsBindingError(name, `js binding \`${name}\` returned ${describe(v)}, not ${result}`);
  const isInt = (lo, hi) => typeof v === 'bigint' && v >= lo && v <= hi;
  switch (result) {
    case 'Unit': return { wire: undefined, bytes: [] };
    case 'String':
      if (typeof v !== 'string' || !v.isWellFormed()) throw bad();
      return { wire: undefined, bytes: [new TextEncoder().encode(v)] };
    case 'Int': case 'I64':
      if (!isInt(-(2n ** 63n), 2n ** 63n - 1n)) throw bad();
      return { wire: v, bytes: [] };
    case 'U64':
      if (!isInt(0n, 2n ** 64n - 1n)) throw bad();
      return { wire: BigInt.asIntN(64, v), bytes: [] };
    case 'Float':
      if (typeof v !== 'number') throw bad();
      return { wire: v, bytes: [] };
    case 'Bool':
      if (typeof v !== 'boolean') throw bad();
      return { wire: v ? 1 : 0, bytes: [] };
    case 'Char':
      if (typeof v !== 'string' || [...v].length !== 1) throw bad();
      return { wire: v.codePointAt(0), bytes: [] };
    default: {
      const [lo, hi] = NARROW[result];
      if (typeof v !== 'number' || !Number.isInteger(v) || v < lo || v > hi) throw bad();
      return { wire: v, bytes: [] };
    }
  }
}

function concatBytes(chunks) {
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let at = 0;
  for (const c of chunks) { out.set(c, at); at += c.length; }
  return out;
}

function jsffiImports(module, host, bindings) {
  const out = {};
  for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.module !== 'jsffi') continue;
    const { name, params, result } = parseField(imp.name);
    const fn = bindings[name];
    if (typeof fn !== 'function') {
      out[imp.name] = () => {
        throw new CapabilityError('FFI', `js binding \`${name}\` is not supplied by this host`);
      };
      continue;
    }
    out[imp.name] = (...wire) => {
      const { args, arrays } = decodeArgs(params, wire, Uint8Array.from(host.pathBuf));
      host.pathBuf = [];
      let v;
      try {
        v = fn(...args);
      } catch (e) {
        throw new JsBindingError(name, `js binding \`${name}\` threw: ${e && e.message !== undefined ? e.message : String(e)}`);
      }
      const r = encodeResult(name, result, v);
      const back = arrays.map((a) => {
        const b = new Uint8Array(a.length * 8);
        const dv = new DataView(b.buffer);
        for (let i = 0; i < a.length; i++) dv.setBigInt64(i * 8, a[i], true);
        return b;
      });
      host.resultBuf = concatBytes([...back, ...r.bytes]);
      return r.wire;
    };
  }
  return out;
}

const [wasmPath, bindingsPath] = process.argv.slice(2);
const bindings = await import(pathToFileURL(nodePath.resolve(bindingsPath)).href);
const module = await WebAssembly.compile(fs.readFileSync(wasmPath));
let wroteStderr = false;
const sink = {
  write(stream, b) {
    if (stream === 'stderr') wroteStderr = true;
    (stream === 'stdout' ? process.stdout : process.stderr).write(Buffer.from(b).toString('utf8'));
  },
};
const host = createHost('wasmgc/node', { sink });
host.imports.jsffi = jsffiImports(module, host, bindings);
const r = await runProgram(module, host);
if (r.kind === 'exit') process.exitCode = r.code;
else if (r.kind === 'error') {
  process.exitCode = 1;
  if (!wroteStderr)
    process.stderr.write((r.inProgram ? 'runtime error: ' : 'instantiate failed: ') + (r.error && r.error.message ? r.error.message : String(r.error)) + '\n');
}
