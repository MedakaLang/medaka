import assert from 'node:assert/strict';
import { createAnimationController } from './animation_controller.mjs';

function harness(reducedMotion = false) {
  let id = 0;
  let now = 0;
  const frames = new Map();
  const timers = new Map();
  const workers = [];
  const painted = [];
  const states = [];
  const output = [];
  const viewport = { revision: 0, width: 640, height: 360, dpr: 1 };
  const controller = createAnimationController({
    createWorker() {
      const worker = { sent: [], terminated: false, postMessage(m) { this.sent.push(m); }, terminate() { this.terminated = true; } };
      workers.push(worker); return worker;
    },
    renderer: { resize() {}, present(batch) { painted.push(batch); }, dispose() {} },
    requestAnimationFrame(fn) { const key = ++id; frames.set(key, fn); return key; },
    cancelAnimationFrame(key) { frames.delete(key); },
    setTimeout(fn, ms) { const key = ++id; timers.set(key, { fn, ms }); return key; },
    clearTimeout(key) { timers.delete(key); },
    now: () => now,
    reducedMotion: () => reducedMotion,
    startupTimeout: 100, frameTimeout: 20,
    status: state => states.push(state), output: m => output.push(m),
  });
  function start(runId = 1) { controller.start({ runId, wasm: new ArrayBuffer(0), viewport }); }
  function reply(overrides = {}, worker = workers.at(-1)) {
    const request = worker.sent.at(-1);
    worker.onmessage({ data: { type: 'frame', version: 1, runId: request.runId, frameId: request.frameId || 0,
      continuous: true, viewport: { ...request.input.viewport },
      background: { red: 0, green: 0, blue: 0, alpha: 1 }, commands: [], ...overrides } });
  }
  function step(time) {
    now = time;
    const queued = [...frames.values()]; frames.clear();
    for (const fn of queued) fn(time);
  }
  return { controller, workers, painted, states, output, timers, frames, viewport, start, reply, step };
}

export function runAnimationControllerTests(check) {
  function test(name, fn) {
    try { fn(); check(name, true); }
    catch (error) { check(name, false, error.stack); }
  }
  test('controller permits one in-flight tick, clamps delta, watchdog survives pause', () => {
    const h = harness(); h.start();
    assert.equal([...h.timers.values()][0].ms, 100);
    h.step(0); assert.equal(h.workers[0].sent.length, 1);
    h.reply(); h.step(1000);
    assert.equal(h.workers[0].sent.length, 2);
    assert.equal(h.workers[0].sent[1].input.elapsed, 0);
    assert.equal([...h.timers.values()][0].ms, 20);
    h.step(1500); assert.equal(h.workers[0].sent.length, 2);
    h.reply(); h.step(2000);
    assert.equal(h.workers[0].sent[2].input.delta, 0.05);
    h.controller.pause();
    assert.equal(h.timers.size, 1);
    [...h.timers.values()][0].fn();
    assert.equal(h.states.at(-1).state, 'failed');
    assert.equal(h.workers[0].terminated, true);
    assert.equal(h.painted.length, 2);
  });
  test('pause excludes hidden/manual time and resume resets delta', () => {
    const h = harness(); h.start(); h.reply(); h.step(100);
    h.controller.pause(); h.reply(); h.step(1100);
    assert.equal(h.painted.length, 1);
    h.controller.visibility(true); h.controller.visibility(false); h.step(1200);
    assert.equal(h.workers[0].sent.length, 2);
    h.controller.resume(); h.step(2000);
    assert.equal(h.workers[0].sent.at(-1).input.elapsed, 0);
    assert.equal(h.workers[0].sent.at(-1).input.delta, 0);
    assert.equal(h.painted.length, 2);
  });
  for (const [name, suspend, resume] of [
    ['manual pause', h => h.controller.pause(), h => h.controller.resume()],
    ['hidden tab', h => h.controller.visibility(true), h => h.controller.visibility(false)],
    ['zero layout', h => h.controller.resize({ width: 0, height: 0, dpr: 1 }),
      h => h.controller.resize({ width: 640, height: 360, dpr: 1 })],
  ]) {
    test(`${name} preserves active time with an outstanding frame and resets delta`, () => {
      const h = harness(); h.start(); h.reply(); h.step(0);
      h.step(120); suspend(h); h.reply(); h.step(200);
      resume(h); h.step(300);
      const next = h.workers[0].sent.at(-1).input;
      assert.equal(next.elapsed, 0.12);
      assert.equal(next.delta, 0);
    });
  }
  for (const continuous of [false, true]) {
    test(`first ${continuous ? 'continuous' : 'static'} image survives resize, zero layout and pause before presentation`, () => {
      const h = harness(); h.start(); h.controller.pause();
      h.controller.resize({ width: 0, height: 0, dpr: 1 });
      h.reply({ continuous });
      if (!continuous) h.workers[0].onmessage({ data: { type: 'done', version: 1, runId: 1, frameId: 0 } });
      h.step(100); assert.equal(h.painted.length, 0);
      h.controller.resize({ width: 800, height: 450, dpr: 2 });
      h.step(200); assert.equal(h.painted.length, 1);
      assert.equal(h.workers[0].sent.length, 1);
      h.controller.resume(); h.step(1000);
      if (continuous) {
        assert.equal(h.workers[0].sent.at(-1).input.elapsed, 0);
        assert.equal(h.workers[0].sent.at(-1).input.delta, 0);
        assert.equal(h.workers[0].sent.at(-1).input.viewport.width, 800);
      } else {
        h.controller.resize({ width: 1000, height: 562.5, dpr: 1 });
        assert.equal(h.painted.length, 2);
        assert.equal(h.workers[0].sent.length, 1);
      }
    });
  }
  test('later stale viewport is acknowledged without painting and next tick uses resize', () => {
    const h = harness(); h.start(); h.reply(); h.step(0);
    h.controller.resize({ width: 800, height: 450, dpr: 1 });
    h.reply(); h.step(20);
    assert.equal(h.painted.length, 1);
    assert.equal(h.workers[0].sent.at(-1).input.viewport.revision, 1);
  });
  test('reduced motion shows first frame while paused; hidden before first image waits', () => {
    const h = harness(true); h.start(); h.controller.visibility(true); h.reply(); h.step(0);
    assert.equal(h.painted.length, 0);
    h.controller.visibility(false); h.step(1000);
    assert.equal(h.painted.length, 1);
    assert.equal(h.workers[0].sent.length, 1);
    h.controller.resume(); h.step(2000);
    assert.equal(h.workers[0].sent.at(-1).input.elapsed, 0);
  });
  test('replacement and Stop reject every late frame, text, error, done and worker error', () => {
    const h = harness(); h.start(); const old = h.workers[0];
    h.start(2);
    const count = h.states.length;
    for (const type of ['frame', 'stdout', 'stderr', 'error', 'done'])
      old.onmessage({ data: { type, version: 1, runId: 1, frameId: 0, text: 'late', message: 'late' } });
    old.onerror({ message: 'late worker error' });
    assert.equal(h.states.length, count); assert.deepEqual(h.output, []);
    h.controller.stop(); const stopped = h.states.length;
    for (const type of ['frame', 'stdout', 'stderr', 'error', 'done'])
      h.workers[1].onmessage({ data: { type, version: 1, runId: 2, frameId: 0 } });
    assert.equal(h.states.length, stopped); assert.equal(h.frames.size, 0);
  });
  test('pointer snapshot is immutable and visibility clears down', () => {
    const h = harness(); h.start(); h.reply();
    h.controller.pointer({ x: 10, y: -20, inside: true, down: true }); h.step(0);
    const snapshot = h.workers[0].sent.at(-1).input.pointer;
    h.controller.pointer({ x: 100 });
    assert.equal(snapshot.x, 10);
    h.controller.visibility(true); h.reply(); h.controller.visibility(false); h.step(100);
    assert.equal(h.workers[0].sent.at(-1).input.pointer.down, false);
  });
  test('malformed reply fails without clearing last image and fresh Run recovers', () => {
    const h = harness(); h.start(); h.reply(); h.step(0);
    h.reply({ commands: [{ type: 'javascript' }] });
    assert.equal(h.states.at(-1).state, 'failed'); assert.equal(h.painted.length, 1);
    h.start(2); h.reply(); h.step(10);
    assert.equal(h.painted.length, 2);
  });
}
