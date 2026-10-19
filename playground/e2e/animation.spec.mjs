import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { ANIMATION_EXAMPLES } from '../animation_examples.mjs';

const [, , baseUrl, screenshotDir] = process.argv;
if (!baseUrl || !screenshotDir) throw new Error('usage: node animation.spec.mjs <base-url> <screenshots-dir>');
const scene = `import animation.{animateWith, Frame}
import graphics.{Picture, picture, rgba, circle, point}

scene : Frame -> Picture
scene frame =
  let red = if frame.pointer.down then 1.0 else 0.0
  picture (rgba red 0.0 0.0 1.0)
    [circle (rgba 0.0 1.0 0.0 1.0) (point (frame.elapsed * 80.0) 0.0) 20.0]

main = animateWith scene
`;
const runaway = `loop : Int -> Int
loop n = loop (n + 1)
main = println (loop 0)
`;
const failing = `main = panic "animation recovery probe"
`;
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function source(page, text) {
  await page.evaluate(text => {
    const view = window.__mdkView;
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
  }, text);
}
async function run(page, text = scene) {
  await source(page, text);
  await page.click('#run-btn');
}
async function still(page) { return page.locator('#animation-canvas').screenshot(); }
async function waitCanvas(page) {
  await page.waitForSelector('#canvas-pane:not([hidden])', { timeout: 60000 });
  await page.waitForFunction(() => !document.getElementById('run-btn').disabled);
}
async function open(browser, options = {}) {
  const page = await browser.newPage(options);
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.cm-editor .cm-content');
  return page;
}

async function exampleFrames(page, id) {
  return page.evaluate(async id => {
    const [{ ANIMATION_EXAMPLES }, { compile }, assembler, { createHost, createProgramSession },
      { createAnimationBindings }, { createCanvasRenderer }] = await Promise.all([
      import('./animation_examples.mjs'), import('./compile.mjs'),
      import('./vendor/wat2wasm/wat2wasm.js'), import('./medaka_host.mjs'),
      import('./animation_host.mjs'), import('./canvas_renderer.mjs'),
    ]);
    if (!window.__exampleAssets) {
      const text = path => fetch(path).then(r => { if (!r.ok) throw new Error(path); return r.text(); });
      const ids = await fetch('dist/stdlib_modules.json').then(r => r.json());
      const texts = await Promise.all(ids.map(id => text(`dist/${id}.mdk`)));
      window.__exampleAssets = { wasm: new Uint8Array(await fetch('dist/playground.wasm').then(r => r.arrayBuffer())),
        stdlib: { runtime: await text('dist/runtime.mdk'), core: await text('dist/core.mdk'),
          extra: Object.fromEntries(ids.map((id, i) => [id, texts[i]])) } };
      await assembler.default({ module_or_path: new Uint8Array(await fetch('vendor/wat2wasm/wat2wasm_bg.wasm').then(r => r.arrayBuffer())) });
    }
    const compileStart = performance.now();
    const result = await compile(ANIMATION_EXAMPLES[id], window.__exampleAssets);
    if (!result.ok || result.diagnostics?.files?.some(f => f.diagnostics?.length))
      throw new Error(`${id}: ${JSON.stringify(result.diagnostics)}`);
    const bytes = assembler.wat2wasm(result.wat);
    if (!WebAssembly.validate(bytes)) throw new Error(`${id}: invalid WASM`);
    const module = await WebAssembly.compile(bytes);
    const compileMs = performance.now() - compileStart;
    const viewport = { revision: 1, width: 640, height: 360 };
    const input = (elapsed, delta = 0, pointer = {}) => ({ elapsed, delta, viewport,
      pointer: { x: 0, y: 0, inside: false, down: false, ...pointer } });
    const create = async () => {
      const binding = createAnimationBindings();
      const host = createHost('wasmgc/browser-worker', { bindings: binding.bindings });
      const session = await createProgramSession(module, host);
      return { session, async frame(snapshot) {
        binding.beginInvocation(snapshot);
        const outcome = await session.invokeMain();
        if (outcome.kind !== 'done') { binding.discard(); throw new Error(`${id}: ${outcome.error?.message || outcome.kind}`); }
        return binding.finishInvocation();
      } };
    };
    const runner = await create();
    const frames = [];
    frames.push(await runner.frame(input(0)));
    frames.push(await runner.frame(input(1, 0.05)));
    frames.push(await runner.frame(input(1, 0.05, { x: 100, y: 60, inside: true, down: true })));
    runner.session.dispose();
    const fresh = await create();
    const reset = await fresh.frame(input(0));
    fresh.session.dispose();
    const collisionFrames = [];
    if (id === 'balls') {
      const collisions = await create();
      for (let i = 0; i <= 40; i++) collisionFrames.push(await collisions.frame({
        ...input(i * 0.05, i === 0 ? 0 : 0.05), viewport: { revision: 2, width: 220, height: 140 },
      }));
      collisions.session.dispose();
    }
    const measure = await create();
    const canvas = document.createElement('canvas');
    const renderer = createCanvasRenderer(canvas);
    renderer.resize(viewport);
    const channel = new MessageChannel();
    const totals = { guestMs: 0, transportMs: 0, replayMs: 0, frames: 60, compileMs };
    for (let i = 0; i < totals.frames; i++) {
      const beforeGuest = performance.now();
      const batch = await measure.frame(input(i / 60, i === 0 ? 0 : 1 / 60));
      const beforeTransport = performance.now();
      const copied = await new Promise(resolve => {
        channel.port2.onmessage = event => resolve(event.data);
        channel.port1.postMessage(batch);
      });
      const beforeReplay = performance.now();
      renderer.present(copied);
      const afterReplay = performance.now();
      totals.guestMs += beforeTransport - beforeGuest;
      totals.transportMs += beforeReplay - beforeTransport;
      totals.replayMs += afterReplay - beforeReplay;
    }
    channel.port1.close(); channel.port2.close(); measure.session.dispose(); renderer.dispose();
    return { frames, reset, collisionFrames, totals, userAgent: navigator.userAgent };
  }, id);
}

function close(actual, expected, label) {
  assert.ok(Math.abs(actual - expected) <= 1e-7, `${label}: expected ${expected}, received ${actual}`);
}
function pointClose(actual, expected, label) {
  close(actual.x, expected[0], `${label}.x`); close(actual.y, expected[1], `${label}.y`);
}

async function geometryProof(page) {
  for (const id of Object.keys(ANIMATION_EXAMPLES)) {
    const { frames, reset, collisionFrames, totals, userAgent } = await exampleFrames(page, id);
    assert.deepEqual(reset, frames[0], `${id}: fresh session restores the initial picture`);
    assert.notDeepEqual(frames[1].commands, frames[0].commands, `${id}: fixed frame inputs must change output`);
    if (id === 'cube') {
      const vertices = [[-1,-1,-1], [1,-1,-1], [1,1,-1], [-1,1,-1],
        [-1,-1,1], [1,-1,1], [1,1,1], [-1,1,1]];
      const edges = [[0,1],[1,2],[2,3],[3,0],[4,5],[5,6],[6,7],[7,4],[0,4],[1,5],[2,6],[3,7]];
      for (const [fi, theta] of [0, 0.7, 1.7].entries()) {
        // Apply independent rotation matrices in homogeneous camera coordinates.
        const matrix = [[Math.cos(theta), 0, Math.sin(theta)],
          [Math.sin(0.5) * Math.sin(theta), Math.cos(0.5), -Math.sin(0.5) * Math.cos(theta)],
          [-Math.cos(0.5) * Math.sin(theta), Math.sin(0.5), Math.cos(0.5) * Math.cos(theta)]];
        const projected = vertices.map(v => {
          const [x, y, z] = matrix.map(row => row.reduce((sum, a, i) => sum + a * v[i], 0));
          assert.ok(5 + z > 3, 'all cube vertices stay beyond the near plane');
          return [360 * x / (5 + z), 360 * y / (5 + z)];
        });
        assert.equal(frames[fi].commands.length, 12);
        edges.forEach(([a,b], i) => {
          pointClose(frames[fi].commands[i].from, projected[a], `cube ${fi} edge ${i} from`);
          pointClose(frames[fi].commands[i].to, projected[b], `cube ${fi} edge ${i} to`);
        });
      }
      assert.notDeepEqual(frames[2].commands, frames[1].commands, 'cube pointer changes rotation at the same elapsed time');
    } else if (id === 'lissajous') {
      for (const [fi, time] of [0, 1].entries()) {
        assert.equal(frames[fi].commands.length, 97);
        for (let i = 0; i < 96; i++) {
          for (const [end, sample] of [['from', i], ['to', i + 1]]) {
            const phase = sample * Math.PI / 48;
            pointClose(frames[fi].commands[i][end], [243.2 * Math.sin(3 * phase + time),
              136.8 * Math.sin(2 * phase)], `curve ${fi} segment ${i} ${end}`);
          }
        }
      }
      pointClose(frames[0].commands[96].center, [0, 0], 'initial curve marker');
    } else {
      const centers = batch => batch.commands.map(command => [command.center.x, command.center.y]);
      assert.deepEqual(centers(frames[0]), [[-90, 45], [65, -30], [0, 0]]);
      assert.deepEqual(centers(frames[1]), [[-84.5, 48.75], [60.75, -24], [3.25, -4.75]]);
      // Semi-implicit acceleration adds a * dt^2 to position.
      const previous = centers(frames[1]);
      const velocities = [[110,75],[-85,120],[65,-95]];
      centers(frames[2]).forEach((position, i) => position.forEach((value, axis) =>
        close(value, previous[i][axis] + velocities[i][axis] * 0.05
          + ([100,60][axis] - previous[i][axis]) * 0.005, `pointer ball ${i} axis ${axis}`)));
      close(collisionFrames[3].commands[0].center.y, 56, 'top wall clamps the first ball');
      close(collisionFrames[4].commands[0].center.y, 52.25, 'top wall reverses vertical velocity');
      close(collisionFrames[13].commands[2].center.y, -59, 'bottom wall clamps the third ball');
      close(collisionFrames[14].commands[2].center.y, -54.25, 'bottom wall reverses vertical velocity');
      close(collisionFrames[34].commands[0].center.x, 96, 'right wall clamps the first ball');
      close(collisionFrames[35].commands[0].center.x, 90.5, 'right wall reverses horizontal velocity');
      close(collisionFrames[37].commands[1].center.x, -90, 'left wall clamps the second ball');
      close(collisionFrames[38].commands[1].center.x, -85.75, 'left wall reverses horizontal velocity');
      for (const batch of collisionFrames) for (const command of batch.commands) {
        assert.ok(Math.abs(command.center.x) + command.radius <= 110);
        assert.ok(Math.abs(command.center.y) + command.radius <= 70);
      }
    }
    console.log(`PASS ${id}: real browser compile, assembly/validation, fixed frames, independent numeric oracle and model reset`);
    console.log(`PERF ${id} ${JSON.stringify({ ...totals, userAgent,
      guestScope: 'guest calculation plus scalar FFI construction/validation',
      transportScope: 'MessageChannel structured clone and event delivery', replayScope: 'Canvas2D replay' })}`);
  }
}

const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await open(browser);
  await geometryProof(page);
  await run(page); await waitCanvas(page);
  const first = await still(page); await pause(350);
  assert.notDeepEqual(await still(page), first, 'animation must change real canvas pixels');
  await page.click('#pause-btn'); await pause(100);
  const frozen = await still(page); await pause(150);
  assert.deepEqual(await still(page), frozen, 'Pause must hold the picture');
  await page.click('#pause-btn'); await pause(200);
  assert.notDeepEqual(await still(page), frozen, 'Resume must update the picture');
  console.log('PASS animation pixels change and Pause/Resume hold/restart rendering');

  await page.setViewportSize({ width: 800, height: 700 });
  await pause(100);
  assert.ok(await page.evaluate(() => {
    const canvas = document.getElementById('animation-canvas');
    const rect = canvas.getBoundingClientRect();
    return canvas.width > 0 && canvas.width <= 2048 && Math.abs(rect.width / rect.height - 16 / 9) < 0.01;
  }));
  const bounds = await page.locator('#animation-canvas').boundingBox();
  await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
  await page.mouse.down(); await pause(100);
  assert.equal(await page.evaluate(() => document.getElementById('animation-canvas').getContext('2d').getImageData(1, 1, 1, 1).data[0]), 255);
  await page.locator('#animation-canvas').dispatchEvent('pointercancel', { isPrimary: true, pointerId: 1 });
  await pause(100);
  assert.equal(await page.evaluate(() => document.getElementById('animation-canvas').getContext('2d').getImageData(1, 1, 1, 1).data[0]), 0);
  await page.mouse.up();
  console.log('PASS resize preserves logical aspect ratio and pointer cancellation clears down');

  await page.click('#pause-btn'); await pause(50);
  await page.evaluate(() => {
    window.__testHidden = true;
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => window.__testHidden });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  const hidden = await still(page); await pause(100);
  await page.evaluate(() => { window.__testHidden = false; document.dispatchEvent(new Event('visibilitychange')); });
  await pause(100); assert.deepEqual(await still(page), hidden);
  assert.equal(await page.locator('#pause-btn').textContent(), 'Resume');
  console.log('PASS returning from a hidden tab preserves manual pause');
  await page.click('#stop-btn');
  assert.equal(await page.locator('#status').textContent(), 'stopped');
  const stopped = await still(page); await pause(100); assert.deepEqual(await still(page), stopped);
  await run(page); await waitCanvas(page);
  await page.click('#run-btn'); await waitCanvas(page);
  await page.click('#stop-btn');
  console.log('PASS Stop preserves the image and repeated Run replaces the runner');

  await run(page, failing);
  await page.waitForFunction(() => document.getElementById('status').textContent === 'runtime error', null, { timeout: 60000 });
  await run(page); await waitCanvas(page); await page.click('#stop-btn');
  console.log('PASS runtime errors permit a fresh animation Run');
  await run(page, runaway);
  await page.waitForFunction(() => document.getElementById('console').textContent.includes('time limit'), null, { timeout: 60000 });
  assert.equal(await page.evaluate(() => !document.getElementById('run-btn').disabled), true);
  await run(page); await waitCanvas(page); await page.click('#stop-btn');
  console.log('PASS runaway termination and subsequent Run recovery');

  const reduced = await open(browser, { reducedMotion: 'reduce' });
  await run(reduced); await waitCanvas(reduced);
  assert.equal(await reduced.locator('#pause-btn').textContent(), 'Resume');
  const reducedStill = await still(reduced); await pause(100); assert.deepEqual(await still(reduced), reducedStill);
  await reduced.click('#pause-btn'); await pause(200); assert.notDeepEqual(await still(reduced), reducedStill);
  await reduced.click('#stop-btn');
  console.log('PASS reduced motion starts with a still image and explicit Resume');

  const held = await browser.newPage();
  await held.addInitScript(() => {
    const NativeWorker = window.Worker;
    window.__holdAnimation = true;
    window.Worker = class extends NativeWorker {
      constructor(url, options) {
        super(url, options);
        if (String(url) !== 'worker.js') return;
        Object.defineProperty(this, 'onmessage', { set: handler => {
          this.addEventListener('message', event => {
            if (window.__holdAnimation && event.data.type === 'frame') window.__releaseFrame = () => handler(event);
            else handler(event);
          });
        } });
      }
    };
  });
  await held.goto(baseUrl); await held.waitForSelector('.cm-editor .cm-content');
  await run(held);
  await held.waitForFunction(() => typeof window.__releaseFrame === 'function', null, { timeout: 60000 });
  await held.click('#pause-btn');
  await held.evaluate(() => { window.__holdAnimation = false; window.__releaseFrame(); });
  await waitCanvas(held);
  assert.equal(await held.locator('#pause-btn').textContent(), 'Resume');
  const initial = await still(held); await pause(100); assert.deepEqual(await still(held), initial);
  await held.click('#pause-btn'); await pause(200); assert.notDeepEqual(await still(held), initial);
  await held.click('#stop-btn');
  console.log('PASS pause before first presentation shows the initial image before advancing');
  console.log('ANIMATION CHECKS PASSED');
} finally { await browser.close(); }
