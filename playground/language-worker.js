// language-worker.js — dedicated module Web Worker for the live language service
// (analyze → diagnostics for inline squiggles).  Kept SEPARATE from
// compiler-worker.js: that worker is busy during a Run (instantiate + wat2wasm
// assemble); this one stays warm for debounced analyze on every keystroke.
//
// It imports the same compile.mjs seam, through its `analyze` mode: the guest
// runs the IDENTICAL diagnostic-producing front end `compile` runs (same route,
// same main-shape guard, same underivedMainDiags) and then stops before wasm
// codegen.  This worker discards the WAT, and emitting it cost 596ms of a 769ms
// clean-program analyze (#2442).  Still ONE compiler entry — playground.wasm just
// dispatches on an extra argv mode.
//
// Protocol:
//   Receives { type:'init', assets:{ wasm:ArrayBuffer, runtime, core } }
//   Receives { type:'analyze', id:number, source:string }
//   Posts    { type:'diagnostics', id, files }   // files = check --json shape ([] = clean)
//          | { type:'error', id, message }
//
// Cancellation: the worker processes messages sequentially and cannot interrupt
// a running analyze, so the main thread coalesces (only the latest source is
// ever queued) and ignores responses whose id is stale.  compile.mjs keeps ONE
// compiler instance alive in this worker and re-enters its `mdk_main` export per
// analyze, so the compiler's prelude parse/desugar memos survive between
// keystrokes (a fresh instance per analyze re-derived them every time).
//
// NOTE (S3/S4): hover + completion do NOT run here.  They run on the MAIN THREAD
// (see main.js): a full single-file typecheck recurses thousands of frames deep
// (the lexer's layout pass) and overflows a Web Worker's small stack, whereas the
// main thread's larger stack fits it.  Keeping analyze here still isolates the
// per-keystroke work from the UI thread.

import { analyze } from './compile.mjs';

let wasmBytes = null;   // Uint8Array of playground.wasm
let stdlib = null;      // { runtime, core }

self.onmessage = async function (e) {
  const msg = e.data;

  if (msg.type === 'init') {
    wasmBytes = new Uint8Array(msg.assets.wasm);
    stdlib = { runtime: msg.assets.runtime, core: msg.assets.core, extra: msg.assets.extra };
    self.postMessage({ type: 'ready' });
    return;
  }

  if (msg.type === 'analyze') {
    const { id, source } = msg;
    if (!wasmBytes || !stdlib) {
      self.postMessage({ type: 'error', id, message: 'language worker not initialized' });
      return;
    }
    try {
      // `analyze` always returns a `diagnostics` envelope: on a clean program
      // it is {"files":[]} or the WARNINGS (e.g. W-NONEXHAUSTIVE, which never
      // blocks emit but still deserves a squiggle), on a broken one the errors.
      // Either way the posted shape is the same, so `ok` needs no branch here.
      const r = await analyze(source, { wasm: wasmBytes, stdlib });
      const files = (r.diagnostics && r.diagnostics.files) || [];
      self.postMessage({ type: 'diagnostics', id, files });
    } catch (err) {
      self.postMessage({ type: 'error', id, message: (err && err.message) || String(err) });
    }
    return;
  }
};
