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

/* ── #2128: inbound Bool/Char that a REAL C library is free to return ────────
 *
 * The functions above are all well-behaved: ffiNegate returns exactly 0 or 1,
 * ffiCharNext is only ever handed a valid codepoint.  That is the easy half.
 * These six are the honest half — a C library is under NO obligation to return
 * a value inside Medaka's `Bool`/`Char` subsets (FFI-ABI.md §2.1), and before
 * the inbound normalisation `cTruthy`'s 42 became an immediate word that was
 * neither True (3) nor False (1): `if` read it as true and `match` fell off the
 * end into E-NONEXHAUSTIVE-MATCH, in the same program.  They are NOT pathological
 * fixtures — `return 42` is what every C predicate written as `return flags &
 * MASK;` does. */

/* Bool, out of the 0/1 range but true by C's own rule. */
long long cTruthy(void) { return 42; }
/* Bool, in-range regression floor: these two must keep behaving exactly as before. */
long long cFalsy(void) { return 0; }
long long cOne(void) { return 1; }

/* Char, in range: 65 = 'A'. */
long long cCharA(void) { return 65; }
/* Char, above charMaxBound (1114111). */
long long cCharBig(void) { return 1200000; }
/* Char, negative — a distinct arm because it reads as a HUGE unsigned, so it
 * pins that the range check is unsigned rather than a signed `<=` that a
 * negative would sail through. */
long long cCharNeg(void) { return -1; }
/* Char, INSIDE the bounds but still not a Char: 0xD800 is the low end of the
 * UTF-16 surrogate window, which is excluded from the Unicode scalar values
 * (runtime/medaka_rt.c `mdk_char_from_code`, and the lexer, and `charFromCode`,
 * all agree).  The third arm, and the one a BOUNDS-only check cannot catch — it
 * is exactly what the check was before the ffi-boundary-honesty review round
 * (S0-1): `icmp ult i64 %r, 1114112` alone accepted this and `println` emitted
 * malformed UTF-8 at exit 0. */
long long cCharSurrogate(void) { return 0xD800; }

/* ── #2164: §2.4 COPY-BACK — a C function that FILLS a caller-allocated array ──
 *
 * The mirror of ffiSumInts.  That one only READS the buffer, so it passes even
 * with the copy-back missing; this one WRITES, which is the half that was
 * silently discarded before #2164 (the C side filled the throwaway §2.4 copy and
 * the Medaka array came back unchanged, at exit 0).
 *
 * Deliberately writes a CONSTANT rather than a function of the input, so the
 * expected sum is hand-computable without reference to what was in the array
 * before: 99 * 3 = 297, versus 1 + 2 + 3 = 6 for the untouched array. */
void ffiFill99(long long *xs, long long n) {
  for (long long i = 0; i < n; i++) xs[i] = 99;
}
