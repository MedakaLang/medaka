import assert from 'node:assert/strict';
import { createAnimationBindings } from './animation_host.mjs';
import { LIMITS } from './animation_protocol.mjs';
import { sampleInput, sampleBatch } from './animation_protocol_test.mjs';

export function runAnimationHostTests(check) {
  let cases = 0;
  const test = (name, fn) => {
    cases++;
    try { fn(); check(`animation host: ${name}`, true); }
    catch (error) { check(`animation host: ${name}`, false, error.stack); }
  };
  const setup = () => {
    const host = createAnimationBindings();
    const call = (name, ...args) => host.bindings[`medaka_canvas_v1_${name}`](...args);
    return { host, call };
  };
  const start = (host, call) => { host.beginInvocation(sampleInput()); call('begin', true); call('background', 1, 0, 0.5, 0.75); };
  const rejects = (fn, message = /E-GRAPHICS-PROTOCOL/) => assert.throws(fn,
    (e) => e.name === 'GraphicsError' && message.test(e.message));

  test('known complete batch and immutable scalar reads', () => {
    const { host, call } = setup();
    const input = sampleInput();
    host.beginInvocation(input);
    input.viewport.revision = 99;
    input.pointer.x = 99;
    call('begin', true);
    for (const [name, expected] of Object.entries({ elapsed: 1, delta: 0.025, width: 640, height: 360,
      pointerX: 12, pointerY: -4, pointerInside: true, pointerDown: false })) assert.equal(call(name), expected);
    call('background', 1, 0, 0.5, 0.75);
    call('line', 1, 0, 0.5, 0.75, 2, -1, 2, 3, 4);
    call('circle', 1, 0, 0.5, 0.75, 0, 0, 0);
    call('polygonBegin', 1, 0, 0.5, 0.75);
    call('polygonPoint', 0, 0);
    call('polygonPoint', 1, 1);
    call('polygonEnd');
    assert.equal(call('end'), undefined);
    assert.deepEqual(host.finishInvocation(), sampleBatch());
  });
  test('console invocation produces no batch; next input is fresh', () => {
    const { host, call } = setup();
    host.beginInvocation(sampleInput());
    assert.equal(host.finishInvocation(), null);
    const input = sampleInput(); input.elapsed = 2;
    host.beginInvocation(input);
    call('begin', false);
    assert.equal(call('elapsed'), 2);
    call('background', 0, 0, 0, 0);
    call('end');
    assert.equal(host.finishInvocation().continuous, false);
  });
  test('outside invocation is a named initialization error', () => {
    const { host, call } = setup();
    rejects(() => call('begin', false), /E-GRAPHICS-INITIALIZATION/);
    rejects(() => host.finishInvocation());
  });
  for (const [name, run] of [
    ['getter before begin', (call) => call('elapsed')],
    ['shape before begin', (call) => call('circle', 0, 0, 0, 1, 0, 0, 1)],
    ['shape before background', (call) => { call('begin', false); call('circle', 0, 0, 0, 1, 0, 0, 1); }],
    ['end before background', (call) => { call('begin', false); call('end'); }],
    ['second background', (call) => { call('begin', false); call('background', 0, 0, 0, 1); call('background', 0, 0, 0, 1); }],
    ['second picture', (call) => { call('begin', true); call('background', 0, 0, 0, 1); call('end'); call('begin', true); }],
    ['getter after end', (call) => { call('begin', true); call('background', 0, 0, 0, 1); call('end'); call('width'); }],
    ['nested polygon', (call) => { call('begin', true); call('background', 0, 0, 0, 1); call('polygonBegin', 0, 0, 0, 1); call('polygonBegin', 0, 0, 0, 1); }],
    ['polygon point without polygon', (call) => { call('begin', true); call('background', 0, 0, 0, 1); call('polygonPoint', 0, 0); }],
    ['nonboolean begin', (call) => call('begin', 1)],
  ]) test(name, () => {
    const { host, call } = setup(); host.beginInvocation(sampleInput());
    rejects(() => run(call));
    rejects(() => host.finishInvocation());
  });
  for (const [name, run] of [
    ['nonfinite color', (call) => call('background', NaN, 0, 0, 1)],
    ['out-of-range color', (call) => call('background', 0, 0, 0, 2)],
    ['nonfinite coordinate', (call) => { call('background', 0, 0, 0, 1); call('line', 0, 0, 0, 1, 1, Infinity, 0, 0, 0); }],
    ['out-of-range coordinate', (call) => { call('background', 0, 0, 0, 1); call('circle', 0, 0, 0, 1, LIMITS.maxCoordinate + 1, 0, 1); }],
    ['nonpositive width', (call) => { call('background', 0, 0, 0, 1); call('line', 0, 0, 0, 1, 0, 0, 0, 0, 0); }],
    ['excessive width', (call) => { call('background', 0, 0, 0, 1); call('line', 0, 0, 0, 1, LIMITS.maxCoordinate + 1, 0, 0, 0, 0); }],
    ['negative radius', (call) => { call('background', 0, 0, 0, 1); call('circle', 0, 0, 0, 1, 0, 0, -1); }],
    ['excessive radius', (call) => { call('background', 0, 0, 0, 1); call('circle', 0, 0, 0, 1, 0, 0, LIMITS.maxCoordinate + 1); }],
  ]) test(name, () => {
    const { host, call } = setup(); host.beginInvocation(sampleInput()); call('begin', true);
    rejects(() => run(call)); rejects(() => host.finishInvocation());
  });
  for (const [name, run] of [
    ['unclosed picture', () => {}],
    ['unclosed polygon', (call) => call('polygonBegin', 0, 0, 0, 1)],
  ]) test(name, () => {
    const { host, call } = setup(); start(host, call); run(call);
    rejects(() => host.finishInvocation(), /incomplete picture/);
  });
  test('second invocation refuses overlap without replacing input', () => {
    const { host, call } = setup(); start(host, call);
    rejects(() => host.beginInvocation(sampleInput()), /already active/);
    rejects(() => host.finishInvocation());
  });
  test('discard after end publishes nothing and resets invocation', () => {
    const { host, call } = setup(); start(host, call); call('end'); host.discard();
    rejects(() => host.finishInvocation(), /no entry/);
    host.beginInvocation(sampleInput());
    assert.equal(host.finishInvocation(), null);
  });
  test('command budget enforced before append', () => {
    const { host, call } = setup(); start(host, call);
    for (let i = 0; i < LIMITS.maxShapes; i++) call('circle', 0, 0, 0, 1, 0, 0, 1);
    rejects(() => call('circle', 0, 0, 0, 1, 0, 0, 1), /shapes exceed/);
    rejects(() => host.finishInvocation());
  });
  test('point budget enforced during open polygon', () => {
    const { host, call } = setup(); start(host, call); call('polygonBegin', 0, 0, 0, 1);
    for (let i = 0; i < LIMITS.maxPoints; i++) call('polygonPoint', 0, 0);
    rejects(() => call('polygonPoint', 0, 0), /points exceed/);
    rejects(() => host.finishInvocation());
  });
  test('scalar call budget includes frame getters', () => {
    const { host, call } = setup(); start(host, call);
    for (let i = 2; i < LIMITS.maxCalls; i++) call('elapsed');
    rejects(() => call('elapsed'), /scalar calls exceed/);
    rejects(() => host.finishInvocation());
  });
  test('exact point budget, degenerate polygon, and repeated successful invocation', () => {
    const { host, call } = setup(); start(host, call); call('polygonBegin', 0, 0, 0, 1);
    for (let i = 0; i < LIMITS.maxPoints; i++) call('polygonPoint', 0, 0);
    call('polygonEnd'); call('end');
    assert.equal(host.finishInvocation().commands[0].points.length, LIMITS.maxPoints);
    start(host, call); call('polygonBegin', 0, 0, 0, 1); call('polygonEnd'); call('end');
    assert.deepEqual(host.finishInvocation().commands[0].points, []);
  });
  console.log(`animation host executed ${cases} cases`);
  return cases;
}
