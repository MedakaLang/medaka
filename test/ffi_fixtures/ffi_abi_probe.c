/* ffi_abi_probe.c — the C half of the #2074 FFI lowering gate.
 *
 * ⚠️ A NEW FILE KIND under test/: plain C, compiled and linked into a `medaka
 * build` output by test/diff_compiler_llvm_ffi.sh.  Nothing else in the tree
 * reads it.  It is deliberately written the way a REAL C library would be — plain
 * C types, no Medaka header, no knowledge of the tagged value representation —
 * because that is the whole property under test: `compiler/FFI-ABI.md` §2 says
 * the compiler untags/unboxes on the way out and re-tags/copies on the way in, so
 * a C function that knew anything about Medaka's representation would be testing
 * the wrong contract.
 *
 * 🚨 THE FUNCTION NAMES ARE camelCase ON PURPOSE.  #2074's contract is that a
 * declared extern's name is the C symbol VERBATIM — `call @ffiAddInts`, not
 * `@mdk_ffiAddInts` and not a snake_case transliteration.  Renaming these to
 * idiomatic C spelling would break the link, which is precisely the assertion.
 *
 * Every function's Medaka counterpart is declared in ffi_abi_probe.mdk; the
 * expected values are hand-computed in that file's header, not captured. */

#include <string.h>

/* §2.1 immediates — plain int64_t both directions, no tag anywhere. */
long long ffiAddInts(long long a, long long b) { return a + b; }

/* Bool: Medaka's True/False arrive as 1/0 and go back as 1/0. */
long long ffiNegate(long long b) { return b ? 0 : 1; }

/* Char: a codepoint, plain. */
long long ffiCharNext(long long cp) { return cp + 1; }

/* §2.2 Float — an unboxed C double both directions; the caller never sees, and
 * this function could never dereference, a Medaka `{header, double}` cell. */
double ffiScale(double x, double y) { return x * y; }

/* §2.3 String, Medaka → C: a borrowed NUL-terminated const char*.  Counts BYTES,
 * so a multi-byte UTF-8 input distinguishes a byte count from a codepoint count. */
long long ffiByteLen(const char *s) { return (long long)strlen(s); }

/* §2.3 String, C → Medaka: the returned buffer is C-OWNED and must be COPIED by
 * the compiler, never adopted.  Static on purpose: if the copy were skipped, the
 * next call would visibly clobber the previously returned Medaka String. */
static char ffiEchoBuf[64];
const char *ffiEcho(const char *s) {
  size_t n = strlen(s);
  if (n > sizeof(ffiEchoBuf) - 2) n = sizeof(ffiEchoBuf) - 2;
  memcpy(ffiEchoBuf, s, n);
  ffiEchoBuf[n] = '!';
  ffiEchoBuf[n + 1] = '\0';
  return ffiEchoBuf;
}

/* §2.4 Array Int, Medaka → C: a flat, UNTAGGED int64_t buffer.  If the compiler
 * handed over the live cell instead, every element would read back as 2*v+1 and
 * the sum would be wrong rather than merely different — which is exactly the
 * point of asserting the value, not the exit code.  The length is an ordinary
 * author-written parameter: §2.4 specifies a bare pointer, so the C signature
 * carries its own length channel. */
long long ffiSumInts(const long long *xs, long long n) {
  long long acc = 0;
  for (long long i = 0; i < n; i++) acc += xs[i];
  return acc;
}

/* §2.6 Unit RETURN — a C `void` function, the commonest foreign shape.  Called
 * for effect only; it accumulates into a counter the next function reads back, so
 * "the call actually happened" is observable in the program's output. */
static long long ffiNotes;
void ffiNote(const char *s) { ffiNotes += (long long)strlen(s); }

/* §2.6 Unit PARAMETER — marshals to nothing, so this takes NO C argument at all
 * despite its Medaka signature being `Unit -> Int`. */
long long ffiNotesLen(void) { return ffiNotes; }

/* Mixed spine: three different marshallings in one signature, returning a
 * fourth. */
double ffiMix(long long i, double f, const char *s) {
  return (double)i + f + (double)strlen(s);
}
