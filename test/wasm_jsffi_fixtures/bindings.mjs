// The JS functions the fixtures in this directory bind (`stub_host.mjs` loads them).
// `jsMissing` is deliberately absent.
export const jsUpper = (s) => s.toUpperCase();
export const jsAddInts = (a, b) => a + b;
export const jsIntMax = () => 2n ** 63n - 1n;
export const jsIntMin = () => -(2n ** 63n);
export const jsThrow = (s) => { throw new Error('boom: ' + s); };
export const jsLone = () => '\uD800';
export const jsPlus10 = (x) => x + 10n;
export const jsPlus20 = (x) => x + 20n;
export const jsPlus30 = (x) => x + 30n;
export const jsTick = () => Promise.resolve();
