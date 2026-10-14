// worker.js — module Web Worker that runs a user's WasmGC program on the
// wasmgc/browser-worker host profile and posts back stdout/stderr.
// Receives: { wasm: ArrayBuffer, isolated: boolean }
// Posts:    { type: 'stdout'|'stderr'|'done'|'error', text?: string, message?: string }
//
// Served with Cross-Origin-Embedder-Policy (playground/_headers), as is the host module
// it imports.  The import object, its shims and the flush discipline are
// playground/medaka_host.mjs; this file supplies the page side: a per-run in-memory
// vfs, the throttled posting below, and the wording of a failed run.
import { createHost, runProgram, MemoryVfs, CapabilityError, OldEntryShape, HostKeyError } from './medaka_host.mjs';

// A wasm stack overflow during the run (mdk_main or a value init) is the guest's recursion depth,
// worded like the interpreter's E-STACK-OVERFLOW.
const STACK_OVERFLOW_MSG =
  'stack overflow: recursion too deep for the browser; the native compiler has a larger stack';

// The guest runs synchronously, so a timer can never fire inside it. Per-line
// posts from a print loop would flood the main thread's queue and starve its kill
// timer. Each POST_EVERY_MS window therefore allows BURST_POSTS immediate posts, so a
// quiet program never holds a line back (a kill during a later hang still shows all
// of it); past that, lines coalesce until the window rolls over. `force` drains what
// is left at exit.
const POST_EVERY_MS = 50;
const BURST_POSTS = 200;
const pending = [];   // [{ type, text }] in print order, adjacent same-type runs merged
let windowStart = -Infinity;
let windowPosts = 0;

function queueText(type, text) {
  if (!text) return;
  const last = pending[pending.length - 1];
  if (last && last.type === type) last.text += text;
  else pending.push({ type, text });
}

function postPending(force) {
  const now = performance.now();
  if (now - windowStart >= POST_EVERY_MS) { windowStart = now; windowPosts = 0; }
  if (!force && windowPosts >= BURST_POSTS) return;
  windowPosts++;
  for (const m of pending) self.postMessage(m);
  pending.length = 0;
}

self.onmessage = async function(e) {
  const { wasm, isolated } = e.data;

  // Incremental UTF-8 decoders: stream:true carries a multi-byte codepoint across
  // the boundary between two deliveries.
  const stdoutDecoder = new TextDecoder('utf-8', { fatal: false });
  const stderrDecoder = new TextDecoder('utf-8', { fatal: false });
  // Every stderr byte of the run.  On a runtime trap the guest streams a coded
  // `runtime error [E-CODE]: …` line here before the `unreachable`; the error report
  // surfaces THAT instead of a generic message.
  const stderrAll = [];
  const sink = {
    write(stream, bytes) {
      if (stream === 'stderr') for (const b of bytes) stderrAll.push(b);
      const decoder = stream === 'stdout' ? stdoutDecoder : stderrDecoder;
      queueText(stream, decoder.decode(new Uint8Array(bytes), { stream: true }));
      postPending(false);
    },
    sync() { postPending(true); },
  };
  // The vfs is this run's own: empty when the run starts, dropped when it ends.
  const host = createHost('wasmgc/browser-worker', {
    vfs: new MemoryVfs(),
    sink,
    streaming: true,
    isolated: !!isolated,
    hostLabel: 'the online playground',
    withheldHint: ' (use `medaka build` locally for process and environment access)',
  });

  const r = await runProgram(wasm, host, {
    oldEntryMessage: 'this program was built by an older compiler: its start function runs main itself; reload the page',
  });
  if (r.kind === 'done') {
    // Final decode with stream:false emits any incomplete multi-byte sequence.
    queueText('stdout', stdoutDecoder.decode(new Uint8Array(0), { stream: false }));
    postPending(true);
    self.postMessage({ type: 'done' });
    return;
  }
  if (r.kind === 'exit') {
    // `exit` is withheld on this profile, so its slice never unwinds a run here.
    self.postMessage({ type: 'error', message: 'program exited with code ' + r.code, shown: false });
    return;
  }
  const err = r.error;
  const coded = new TextDecoder('utf-8', { fatal: false })
    .decode(new Uint8Array(stderrAll)).trim();
  const engineMsg = err.message || String(err);
  const isPanic = /unreachable|trap|RuntimeError/i.test(engineMsg);
  // A coded trap already reached the console through the stderr stream above, so
  // the error message is withheld (shown: true) instead of printing it twice.
  // V8 and JavaScriptCore: "Maximum call stack size exceeded"; Firefox: "too
  // much recursion".
  const overflow = /call stack|stack overflow|too much recursion/i.test(engineMsg);
  const named = err instanceof CapabilityError || err instanceof OldEntryShape
    || err instanceof HostKeyError;
  const message = named ? engineMsg
    : overflow ? STACK_OVERFLOW_MSG
    : coded ? coded
    : isPanic ? 'program panicked'
    : (r.inProgram ? 'runtime error: ' : 'instantiate failed: ') + engineMsg;
  self.postMessage({ type: 'error', message, shown: !!coded && !overflow && !named });
};
