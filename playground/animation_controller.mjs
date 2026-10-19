import { PROTOCOL_VERSION, validateFrameBatch, validateFrameInput } from './animation_protocol.mjs';

export function createAnimationController(deps) {
  const { createWorker, renderer, requestAnimationFrame: raf, cancelAnimationFrame: caf,
    setTimeout: later, clearTimeout: cancelTimer } = deps;
  const now = deps.now || (() => performance.now());
  let worker = null;
  let runId = 0;
  let frameId = 0;
  let outstanding = null;
  let timer = null;
  let scheduled = null;
  let pending = null;
  let initial = null;
  let firstPresented = false;
  let continuous = null;
  let done = false;
  let manualPause = false;
  let hidden = false;
  let viewport = { revision: 0, width: 640, height: 360, dpr: 1 };
  let pointer = { x: 0, y: 0, inside: false, down: false };
  let elapsed = 0;
  let baseline = null;
  let previousDispatch = null;
  let resumeDelta = true;
  const paused = () => manualPause || hidden || viewport.width <= 0 || viewport.height <= 0;
  function suspend() {
    if (baseline !== null) elapsed += Math.max(0, now() - baseline) / 1000;
    baseline = null;
    resumeDelta = true;
  }
  function status(state, extra = {}) { deps.status?.({ state, runId, continuous, ...extra }); }
  function unschedule() { if (scheduled !== null) caf(scheduled); scheduled = null; }
  function clearDeadline() { if (timer !== null) cancelTimer(timer); timer = null; }
  function terminate() {
    unschedule(); clearDeadline();
    const old = worker;
    worker = null;
    old?.terminate();
    outstanding = null;
  }
  function fail(message, shown = false) {
    terminate(); pending = null;
    status('failed', { message, shown });
  }
  function deadline(ms) {
    clearDeadline();
    timer = later(() => fail(ms === (deps.startupTimeout || 10000)
      ? `stopped after ${ms / 1000} s (the playground's time limit)`
      : 'animation frame exceeded its time limit'), ms);
  }
  function schedule() {
    if (!worker && !initial && !pending) return;
    if (hidden || viewport.width <= 0 || viewport.height <= 0 || scheduled !== null) return;
    if (paused() && !(pending && !firstPresented)) return;
    if (!pending && (outstanding || !firstPresented || !continuous || done)) return;
    scheduled = raf(opportunity);
  }
  function input(delta) {
    return validateFrameInput({ elapsed, delta,
      viewport: { revision: viewport.revision, width: viewport.width, height: viewport.height }, pointer });
  }
  function opportunity(now) {
    scheduled = null;
    if (deps.measureViewport) resize(deps.measureViewport());
    if (hidden || viewport.width <= 0 || viewport.height <= 0) return;
    if (!paused() && baseline !== null) elapsed += Math.max(0, now - baseline) / 1000;
    baseline = paused() ? null : now;
    if (pending && (!paused() || !firstPresented)) {
      const batch = pending;
      pending = null;
      if (!firstPresented || batch.viewport.revision === viewport.revision) {
        renderer.present(batch);
        if (!firstPresented) {
          initial = batch;
          firstPresented = true;
          elapsed = 0;
          baseline = paused() ? null : now;
          status(paused() ? 'paused' : continuous ? 'running' : 'done', { presented: true });
        }
      }
    }
    if (!paused() && continuous && !outstanding && firstPresented && !done && worker) {
      const delta = resumeDelta || previousDispatch === null ? 0 : Math.min(0.050, Math.max(0, elapsed - previousDispatch));
      resumeDelta = false;
      previousDispatch = elapsed;
      frameId++;
      outstanding = { frameId, viewport: { ...viewport } };
      deadline(deps.frameTimeout || 2000);
      worker.postMessage({ type: 'tick', version: PROTOCOL_VERSION, runId, frameId, input: input(delta) });
    }
  }
  function receive(event, source) {
    const message = event.data;
    if (worker !== source || message.runId !== runId) return;
    if (message.version !== PROTOCOL_VERSION) { fail('E-GRAPHICS-PROTOCOL: unsupported worker version'); return; }
    if (message.frameId !== undefined && message.frameId !== frameId) return;
    if (message.type === 'stdout' || message.type === 'stderr') { deps.output?.(message); return; }
    if (message.type === 'error') { fail(message.message, message.shown); return; }
    if (message.type === 'done') {
      if (continuous === true || (outstanding && continuous !== false)) {
        if (continuous === true) { fail('E-GRAPHICS-PROTOCOL: animation ended without a frame'); return; }
      }
      clearDeadline(); outstanding = null; done = true;
      worker = null; source.terminate();
      if (!pending) status('done');
      schedule();
      return;
    }
    if (message.type !== 'frame' || !outstanding || message.frameId !== outstanding.frameId) return;
    try {
      validateFrameBatch(message);
      const expected = outstanding.viewport;
      if (message.viewport.revision !== expected.revision || message.viewport.width !== expected.width
          || message.viewport.height !== expected.height) throw new Error('E-GRAPHICS-PROTOCOL: viewport mismatch');
      if (continuous === true && !message.continuous) throw new Error('E-GRAPHICS-PROTOCOL: animation changed to a static picture');
    } catch (error) { fail(error.message); return; }
    clearDeadline(); outstanding = null;
    if (continuous === null) {
      continuous = message.continuous;
      if (continuous && deps.reducedMotion?.()) manualPause = true;
    }
    pending = message;
    schedule();
  }
  function resize(next) {
    const changed = viewport.width !== next.width || viewport.height !== next.height || viewport.dpr !== next.dpr;
    if (!changed) return;
    if (next.width <= 0 || next.height <= 0) suspend();
    viewport = { ...next, revision: viewport.revision + 1 };
    if (viewport.width > 0 && viewport.height > 0) {
      renderer.resize(viewport);
      if (initial && !continuous) renderer.present(initial);
    } else { unschedule(); }
    schedule();
  }
  return {
    start({ runId: nextId, wasm, isolated = false, viewport: nextViewport }) {
      terminate(); runId = nextId; frameId = 0;
      pending = initial = null; firstPresented = false; continuous = null; done = false;
      manualPause = false; elapsed = 0; baseline = previousDispatch = null; resumeDelta = true;
      pointer = { x: 0, y: 0, inside: false, down: false };
      if (nextViewport) viewport = { ...nextViewport };
      if (viewport.width <= 0 || viewport.height <= 0) viewport = { ...viewport, width: 640, height: 360 };
      renderer.resize(viewport);
      const source = createWorker(); worker = source;
      source.onmessage = (event) => receive(event, source);
      source.onerror = (event) => { if (worker === source) fail(event.message || 'runner error'); };
      outstanding = { frameId: 0, viewport: { ...viewport } };
      status('loading'); deadline(deps.startupTimeout || 10000);
      source.postMessage({ type: 'start', version: PROTOCOL_VERSION, runId, wasm, isolated, input: input(0) }, [wasm]);
    },
    pause() { manualPause = true; suspend(); unschedule(); status('paused'); schedule(); },
    resume() { manualPause = false; baseline = null; resumeDelta = true; status(paused() ? 'paused' : 'running'); schedule(); },
    visibility(value) {
      if (value && !hidden) suspend();
      hidden = value; pointer.down = false; resumeDelta = true;
      unschedule(); if (worker) status(paused() ? 'paused' : 'running'); schedule();
    },
    stop() { terminate(); runId++; pending = initial = null; pointer.down = false; status('stopped'); },
    resize,
    pointer(next) { pointer = { ...pointer, ...next }; },
    dispose() { terminate(); pending = initial = null; renderer.dispose(); },
  };
}
