// worker.js runs a persistent WasmGC session on the browser-worker host profile.
// Receives start/tick envelopes; posts stdout/stderr/frame/done/error with runId.
//
// Served with Cross-Origin-Embedder-Policy (playground/_headers), as is the host module
// it imports.  The import object, its shims and the flush discipline are
// playground/medaka_host.mjs; this file supplies a per-run in-memory
// vfs, the throttled posting below, and the wording of a failed run.
import { createHost, createProgramSession, MemoryVfs, CapabilityError, OldEntryShape, HostKeyError } from './medaka_host.mjs';
import { createAnimationBindings } from './animation_host.mjs';
import { PROTOCOL_VERSION, validateFrameInput } from './animation_protocol.mjs';

// A wasm stack overflow during the run (mdk_main or a value init) is the guest's recursion depth,
// worded like the interpreter's E-STACK-OVERFLOW.
const STACK_OVERFLOW_MSG =
  'stack overflow: recursion too deep for the browser; the native compiler has a larger stack';

// The guest runs synchronously except while a JSPI sleep suspends it, so a timer
// cannot fire inside a print loop. Per-line posts from one would flood the main
// thread's queue and starve its kill timer. Each POST_EVERY_MS window therefore
// allows BURST_POSTS immediate posts, so a quiet program never holds a line back
// (a kill during a later hang still shows all of it); past that, lines coalesce
// until the window rolls over. `force` drains what is left at exit.
const POST_EVERY_MS = 50;
const BURST_POSTS = 200;
const pending = [];   // [{ type, text }] in print order, adjacent same-type runs merged
let windowStart = -Infinity;
let windowPosts = 0;
let current = null;

function post(message, context = current) {
  self.postMessage({ ...message, version: PROTOCOL_VERSION,
    runId: context?.runId, frameId: context?.frameId });
}

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
  for (const m of pending) post(m);
  pending.length = 0;
}

self.onmessage = async function(e) {
  const message = e.data;
  const legacy = message.type === undefined;
  if (!legacy && (message.version !== PROTOCOL_VERSION || !Number.isSafeInteger(message.runId)
      || message.runId < 0)) return;
  if (message.type === 'tick') {
    const context = current;
    if (!context || message.runId !== context.runId) return;
    if (context.active || !context.continuous || message.frameId !== context.frameId + 1) {
      post({ type: 'error', message: 'E-GRAPHICS-PROTOCOL: unexpected tick' }, context);
      context.session?.dispose();
      return;
    }
    context.frameId = message.frameId;
    await invoke(context, message.input);
    return;
  }
  if (!legacy && message.type !== 'start') return;
  current?.session?.dispose();
  const { wasm, isolated } = message;
  const context = { runId: message.runId, frameId: 0, active: true,
    continuous: false, session: null, animation: createAnimationBindings(), stderrAll: [] };
  current = context;
  pending.length = 0;
  windowStart = -Infinity;
  windowPosts = 0;

  // Incremental UTF-8 decoders: stream:true carries a multi-byte codepoint across
  // the boundary between two deliveries.
  const stdoutDecoder = new TextDecoder('utf-8', { fatal: false });
  const stderrDecoder = new TextDecoder('utf-8', { fatal: false });
  // Every stderr byte of the run.  On a runtime trap the guest streams a coded
  // `runtime error [E-CODE]: …` line here before the `unreachable`; the error report
  // surfaces THAT instead of a generic message.
  const stderrAll = context.stderrAll;
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
    bindings: context.animation.bindings,
    isolated: !!isolated,
    hostLabel: 'the online playground',
    withheldHint: ' (use `medaka build` locally for process and environment access)',
  });
  context.flushDecoder = () => {
    queueText('stdout', stdoutDecoder.decode(new Uint8Array(0), { stream: false }));
    queueText('stderr', stderrDecoder.decode(new Uint8Array(0), { stream: false }));
    postPending(true);
  };

  try {
    context.session = await createProgramSession(wasm, host, {
      oldEntryMessage: 'this program was built by an older compiler: its start function runs main itself; reload the page',
    });
    context.active = false;
    await invoke(context, message.input || { elapsed: 0, delta: 0,
      viewport: { revision: 0, width: 640, height: 360 } });
  } catch (error) { reportError(context, { kind: 'error', error, inProgram: false }); }
};

async function invoke(context, input) {
  context.active = true;
  try {
    context.animation.beginInvocation(validateFrameInput(input));
    const result = await context.session.invokeMain();
    if (result.kind !== 'done') {
      context.animation.discard();
      reportError(context, result);
      return;
    }
    const batch = context.animation.finishInvocation();
    if (context.continuous && (!batch || !batch.continuous))
      throw new Error('E-GRAPHICS-PROTOCOL: animation entry did not return a continuous picture');
    if (batch) {
      context.continuous = batch.continuous;
      post({ ...batch, type: 'frame' }, context);
    }
    if (!batch || !batch.continuous) {
      context.flushDecoder();
      post({ type: 'done' }, context);
      context.session.dispose();
    }
  } catch (error) {
    context.animation.discard();
    reportError(context, { kind: 'error', error, inProgram: true });
  } finally { context.active = false; }
}

function reportError(context, r) {
  context.flushDecoder?.();
  context.session?.dispose();
  if (r.kind === 'exit') {
    // `exit` is withheld on this profile, so its slice never unwinds a run here.
    post({ type: 'error', message: 'program exited with code ' + r.code, shown: false }, context);
    return;
  }
  const err = r.error;
  const coded = new TextDecoder('utf-8', { fatal: false })
    .decode(new Uint8Array(context.stderrAll)).trim();
  const engineMsg = err.message || String(err);
  const isPanic = /unreachable|trap|RuntimeError/i.test(engineMsg);
  // A coded trap already reached the console through the stderr stream above, so
  // the error message is withheld (shown: true) instead of printing it twice.
  // V8 and JavaScriptCore: "Maximum call stack size exceeded"; Firefox: "too
  // much recursion".
  const overflow = /call stack|stack overflow|too much recursion/i.test(engineMsg);
  const named = err.name === 'GraphicsError' || err instanceof CapabilityError || err instanceof OldEntryShape
    || err instanceof HostKeyError;
  const message = named ? engineMsg
    : overflow ? STACK_OVERFLOW_MSG
    : coded ? coded
    : isPanic ? 'program panicked'
    : (r.inProgram ? 'runtime error: ' : 'instantiate failed: ') + engineMsg;
  post({ type: 'error', message, shown: !!coded && !overflow && !named }, context);
}
