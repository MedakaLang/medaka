// Preload for `node --import`: counts WebAssembly.Suspending constructions, the
// calls that go through them, and Atomics.wait calls, and reports all three on
// stderr at exit. Stdout alone cannot tell the Suspending form of a sleep from
// the Atomics.wait form; this line can.
const Real = globalThis.WebAssembly?.Suspending;
let imports = 0;
let calls = 0;
let waits = 0;
if (Real) {
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
}
const realWait = Atomics.wait;
Atomics.wait = function (...a) {
  waits += 1;
  return realWait.apply(this, a);
};
process.on("exit", () => {
  process.stderr.write(
    `TRACE suspending-imports=${imports} suspending-calls=${calls} atomics-waits=${waits}\n`,
  );
});
