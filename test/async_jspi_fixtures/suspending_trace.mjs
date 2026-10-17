// Preload for `node --import`: counts WebAssembly.Suspending constructions and
// the calls that go through them, and reports both on stderr at exit. A run
// that took the Atomics.wait form constructs none, so stdout alone cannot
// tell the two forms apart but this line can.
const Real = globalThis.WebAssembly?.Suspending;
if (Real) {
  let imports = 0;
  let calls = 0;
  WebAssembly.Suspending = new Proxy(Real, {
    construct(target, args) {
      imports += 1;
      const fn = args[0];
      const counted = function (...a) {
        calls += 1;
        return fn.apply(this, a);
      };
      return Reflect.construct(target, [counted]);
    },
  });
  process.on("exit", () => {
    process.stderr.write(`TRACE suspending-imports=${imports} suspending-calls=${calls}\n`);
  });
}
