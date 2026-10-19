import assert from 'node:assert/strict';
import { createCanvasRenderer } from './canvas_renderer.mjs';

export function runCanvasRendererTests(check) {
  try {
    const calls = [];
    const context = new Proxy({}, { get: (_, key) => (...args) => calls.push([key, ...args]),
      set: (_, key, value) => { calls.push([key, value]); return true; } });
    const canvas = { getContext: () => context };
    const renderer = createCanvasRenderer(canvas);
    renderer.resize({ width: 640, height: 360, dpr: 3 });
    assert.equal(canvas.width, 1280);
    assert.equal(canvas.height, 720);
    const color = { red: 1, green: 0, blue: 0, alpha: 1 };
    const batch = { version: 1, continuous: true, viewport: { revision: 0, width: 640, height: 360 },
      background: { ...color, alpha: 0 }, commands: [
        { type: 'line', color, width: 2, from: { x: 1, y: 2 }, to: { x: 3, y: 4 } },
        { type: 'circle', color, center: { x: 0, y: 0 }, radius: 0 },
        { type: 'polygon', color, points: [] },
      ] };
    renderer.present(batch);
    assert.deepEqual(calls[0], ['setTransform', 1, 0, 0, 1, 0, 0]);
    assert.deepEqual(calls[1], ['clearRect', 0, 0, 1280, 720]);
    assert.ok(calls.some(c => JSON.stringify(c) === JSON.stringify(['setTransform', 2, 0, 0, -2, 640, 360])));
    assert.ok(calls.some(c => c[0] === 'stroke'));
    assert.equal(calls.some(c => c[0] === 'fill'), false);
    const before = calls.length;
    assert.throws(() => renderer.present({ ...batch, commands: [{ type: 'javascript' }] }), /unknown command/);
    assert.equal(calls.length, before);
    renderer.resize({ width: 4000, height: 2000, dpr: 2 });
    assert.equal(canvas.width, 2048);
    assert.equal(canvas.height, 1024);
    check('canvas clears transparent frames, centers y-up coordinates, caps DPR/backing size and validates before painting', true);
  } catch (error) { check('canvas renderer', false, error.stack); }
}
