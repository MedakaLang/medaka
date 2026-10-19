import assert from 'node:assert/strict';
import { PROTOCOL_VERSION, LIMITS, validateFrameInput, validateFrameBatch } from './animation_protocol.mjs';

export const sampleInput = () => ({ elapsed: 1, delta: 0.025,
  viewport: { revision: 2, width: 640, height: 360 },
  pointer: { x: 12, y: -4, inside: true, down: false } });
export const sampleColor = () => ({ red: 1, green: 0, blue: 0.5, alpha: 0.75 });
export const sampleBatch = () => ({ version: PROTOCOL_VERSION, continuous: true,
  viewport: sampleInput().viewport, background: sampleColor(), commands: [
    { type: 'line', color: sampleColor(), width: 2, from: { x: -1, y: 2 }, to: { x: 3, y: 4 } },
    { type: 'circle', color: sampleColor(), center: { x: 0, y: 0 }, radius: 0 },
    { type: 'polygon', color: sampleColor(), points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] },
  ] });

export function runAnimationProtocolTests(check) {
  let cases = 0;
  const test = (name, fn) => {
    cases++;
    try { fn(); check(`animation protocol: ${name}`, true); }
    catch (error) { check(`animation protocol: ${name}`, false, error.stack); }
  };
  const rejects = (fn, message) => assert.throws(fn, (e) => e.name === 'GraphicsError' && message.test(e.message));
  test('complete known batch and envelope', () => {
    const batch = { type: 'frame', runId: 3, frameId: 0, ...sampleBatch() };
    assert.equal(validateFrameBatch(batch), batch);
  });
  test('input snapshot and absent pointer', () => {
    const input = sampleInput();
    const snapshot = validateFrameInput(input);
    input.viewport.width = 1;
    input.pointer.x = 3;
    assert.deepEqual(snapshot, sampleInput());
    delete input.pointer;
    assert.deepEqual(validateFrameInput(input).pointer, { x: 0, y: 0, inside: false, down: false });
  });
  for (const [name, mutate] of [
    ['wrong version', (b) => { b.version++; }],
    ['bad runId', (b) => { b.runId = -1; }],
    ['bad frameId', (b) => { b.frameId = Number.MAX_SAFE_INTEGER + 1; }],
    ['unknown command', (b) => { b.commands[0].type = 'script'; }],
    ['function payload', (b) => { b.commands[0].callback = () => {}; }],
    ['missing background', (b) => { delete b.background; }],
    ['nonboolean continuous', (b) => { b.continuous = 1; }],
    ['nonfinite color', (b) => { b.background.red = NaN; }],
    ['out-of-range color', (b) => { b.commands[1].color.alpha = 2; }],
    ['nonfinite coordinate', (b) => { b.commands[0].from.x = Infinity; }],
    ['out-of-range coordinate', (b) => { b.commands[0].to.y = LIMITS.maxCoordinate + 1; }],
    ['nonpositive width', (b) => { b.commands[0].width = 0; }],
    ['excessive width', (b) => { b.commands[0].width = LIMITS.maxCoordinate + 1; }],
    ['negative radius', (b) => { b.commands[1].radius = -1; }],
    ['excessive radius', (b) => { b.commands[1].radius = LIMITS.maxCoordinate + 1; }],
    ['command budget', (b) => { b.commands = Array(LIMITS.maxShapes + 1).fill(b.commands[1]); }],
    ['point budget', (b) => { b.commands[2].points = Array(LIMITS.maxPoints).fill({ x: 0, y: 0 }); }],
  ]) test(name, () => { const batch = sampleBatch(); mutate(batch); rejects(() => validateFrameBatch(batch), /E-GRAPHICS/); });
  for (const [name, mutate] of [
    ['negative elapsed', (i) => { i.elapsed = -1; }],
    ['nonfinite elapsed', (i) => { i.elapsed = Infinity; }],
    ['delta outside clamp', (i) => { i.delta = 0.051; }],
    ['zero viewport', (i) => { i.viewport.width = 0; }],
    ['nonfinite viewport', (i) => { i.viewport.height = NaN; }],
    ['bad revision', (i) => { i.viewport.revision = 0.5; }],
    ['nonfinite pointer', (i) => { i.pointer.x = NaN; }],
    ['nonboolean pointer', (i) => { i.pointer.down = 1; }],
  ]) test(name, () => { const input = sampleInput(); mutate(input); rejects(() => validateFrameInput(input), /E-GRAPHICS/); });
  test('exact command and point limits accepted', () => {
    const batch = sampleBatch();
    batch.commands = Array.from({ length: LIMITS.maxShapes }, () => ({ type: 'polygon', color: sampleColor(),
      points: Array.from({ length: LIMITS.maxPoints / LIMITS.maxShapes }, () => ({ x: 0, y: 0 })) }));
    assert.equal(validateFrameBatch(batch), batch);
  });
  console.log(`animation protocol executed ${cases} cases`);
  return cases;
}
