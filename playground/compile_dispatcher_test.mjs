import assert from 'node:assert/strict';
import { createCompileDispatcher } from './compile_dispatcher.mjs';

export async function runCompileDispatcherTests(check) {
  const workers = [];
  const dispatcher = createCompileDispatcher({ createWorker() {
    const worker = { sent: [], terminated: false, postMessage(m) { this.sent.push(m); }, terminate() { this.terminated = true; } };
    workers.push(worker);
    return worker;
  } });
  try {
    const a = dispatcher.request({ runId: 1, source: 'A' });
    dispatcher.cancel(1);
    const b = dispatcher.request({ runId: 2, source: 'B' });
    assert.deepEqual(await a, { kind: 'cancelled' });
    assert.deepEqual(workers[0].sent.map(m => m.source), ['A']);
    workers[0].onmessage({ data: { wasm: 'late A' } });
    assert.deepEqual(workers[0].sent.map(m => m.source), ['A', 'B']);
    workers[0].onmessage({ data: { wasm: 'B' } });
    assert.deepEqual(await b, { kind: 'compiled', result: { wasm: 'B' } });
    check('compile A/Stop/B consumes late A before dispatching B', true);
    const c = dispatcher.request({ runId: 3, source: 'C' });
    const d = dispatcher.request({ runId: 4, source: 'D' });
    const e = dispatcher.request({ runId: 5, source: 'E' });
    assert.equal((await c).kind, 'cancelled');
    assert.equal((await d).kind, 'cancelled');
    workers[0].onmessage({ data: { wasm: 'C' } });
    assert.equal(workers[0].sent.at(-1).source, 'E');
    workers[0].onmessage({ data: { wasm: 'E' } });
    assert.equal((await e).result.wasm, 'E');
    check('compile dispatcher retains only latest pending request', true);
    const f = dispatcher.request({ runId: 6, source: 'F' });
    const g = dispatcher.request({ runId: 7, source: 'G' });
    const rejected = assert.rejects(g, /broken worker/);
    workers[0].onerror({ message: 'broken worker' });
    assert.equal((await f).kind, 'cancelled');
    await rejected;
    const h = dispatcher.request({ runId: 8, source: 'H' });
    workers[0].onmessage({ data: { wasm: 'old worker' } });
    assert.equal(workers.length, 2);
    dispatcher.dispose();
    assert.equal((await h).kind, 'cancelled');
    workers[1].onmessage({ data: { wasm: 'disposed worker' } });
    assert.equal(workers[1].terminated, true);
    check('compiler failure rejects pending and replacement/disposal reject late worker messages', true);
  } catch (error) { check('compile dispatcher', false, error.stack); }
  finally { dispatcher.dispose(); }
}
