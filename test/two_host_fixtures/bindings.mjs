// The JS half of two_host.mdk; stub.c is the C half and must keep the same
// semantics, function by function.
const byteLen = (s) => BigInt(new TextEncoder().encode(s).length);

export const jsAdd = (a, b) => a + b;
export const jsScale = (x, y) => x * y;
export const jsFloatId = (x) => x;
export const jsNot = (b) => !b;
export const jsCharNext = (c) => String.fromCodePoint(c.codePointAt(0) + 1);
export const jsCharId = (c) => c;
export const jsEcho = (s) => s + '!';
export const jsByteLen = byteLen;
export const jsDouble = (xs, n) => {
  let sum = 0n;
  for (let i = 0; i < Number(n); i++) {
    sum += xs[i];
    xs[i] *= 2n;
  }
  return sum;
};
let notes = 0n;
export const jsNote = (s) => { notes += byteLen(s); };
export const jsNotesLen = () => notes;
export const jsMix = (i, f, s) => Number(i) + f + Number(byteLen(s));
