export function createCompileDispatcher({ createWorker }) {
  let worker = null;
  let active = null;
  let pending = null;
  let disposed = false;
  function cancelRequest(request) {
    if (request && !request.cancelled) {
      request.cancelled = true;
      request.resolve({ kind: 'cancelled' });
    }
  }
  function dispatch() {
    if (active || !pending || disposed) return;
    if (!worker) {
      const nextWorker = createWorker();
      worker = nextWorker;
      nextWorker.onmessage = (event) => {
        if (worker !== nextWorker || !active) return;
        const request = active;
        active = null;
        if (!request.cancelled) request.resolve({ kind: 'compiled', result: event.data });
        dispatch();
      };
      nextWorker.onerror = (event) => {
        if (worker !== nextWorker) return;
        worker = null;
        nextWorker.terminate();
        for (const request of [active, pending])
          if (request && !request.cancelled) request.reject(new Error(event.message || 'compiler-worker error'));
        active = pending = null;
      };
    }
    active = pending;
    pending = null;
    try { worker.postMessage({ source: active.source, assets: active.assets }); }
    catch (error) { worker.onerror(error); }
  }
  return {
    request({ runId, source, assets }) {
      if (disposed) return Promise.resolve({ kind: 'cancelled' });
      cancelRequest(active);
      cancelRequest(pending);
      return new Promise((resolve, reject) => {
        pending = { runId, source, assets, resolve, reject, cancelled: false };
        try { dispatch(); }
        catch (error) { pending = null; reject(error); }
      });
    },
    cancel(runId) {
      if (active?.runId === runId) cancelRequest(active);
      if (pending?.runId === runId) { cancelRequest(pending); pending = null; }
    },
    dispose() {
      disposed = true;
      cancelRequest(active);
      cancelRequest(pending);
      active = pending = null;
      const previous = worker;
      worker = null;
      previous?.terminate();
    },
  };
}
