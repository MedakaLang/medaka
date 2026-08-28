#!/bin/sh
# diff_compiler_llvm_ffi.sh — VALUE GATE for the #2074 FFI lowering.
#
# Proves that a user-declared `extern` becomes a real C-ABI call whose values
# cross correctly in BOTH directions, per compiler/FFI-ABI.md §2 — not merely
# that such a program builds and exits 0.
#
# WHY A VALUE GATE AND NOT AN EXIT-CODE ONE.  Every interesting way to get the
# marshalling wrong still links and still exits 0:
#   * handing C the LIVE Medaka array cell instead of the §2.4 copy -> the C side
#     reads 2*v+1 per element and sums 24 instead of 10;
#   * handing C the String CELL POINTER instead of its payload at +24 -> strlen
#     reads the header bytes;
#   * forgetting the §2.1 untag -> every Int arrives doubled-plus-one;
#   * handing C the boxed `{header, double}` pointer instead of the §2.2 unboxed
#     double -> a garbage float.
# So this gate asserts the exact printed bytes against a hand-computed expectation
# that lives in the fixture's own header (test/ffi_fixtures/ffi_abi_probe.mdk),
# derived from the C source — NOT captured from a run.  There is no golden file
# to bless here on purpose: a captured golden would record whatever the emitter
# did, which is the one thing this gate must not assume.
#
# CELL 2 is the builtin-name exemption (#2074 / slice 1's `ffiIsBuiltinExternName`):
# a program that locally redeclares a `stdlib/runtime.mdk` extern name must STILL
# run the builtin's codegen, never a foreign call to an unbound symbol.  It is
# checked here rather than only in the typecheck fixtures because the exemption is
# ultimately an EMITTER ordering fact (`isAnyExtern` before the FFI arm), and it is
# the arm this gate's own change could regress.
#
# LINKING.  Cells 1 and 2 predate library linkage: they merge the fixture's C half
# into the runtime object and link it through the existing MEDAKA_RT_OBJ fast path
# — a REAL `medaka build` link, not a hand-rolled clang line, so they exercise the
# driver they are meant to.  They are KEPT as-is rather than rewritten, because
# they isolate the LOWERING from the linkage: if cell 3 (below) goes red they say
# whether the marshalling or only the link line broke.
#
# CELLS 3 AND 4 are the linkage slice (#2075): cell 3 reaches cell 1's exact nine
# values through a genuine static library named ONLY by the project's
# `[foreign-libraries]` manifest section (no MEDAKA_RT_OBJ anywhere), and cell 4
# pins that a declared-but-absent library is a Medaka diagnostic naming the
# library, its manifest key, and the manifest file — not clang's `ld: library not
# found` wall.
#
# CELLS 7, 8 AND 9 are the INBOUND-SCALAR honesty slice (#2128).  Cells 1 and 3
# only ever see a C half that stays inside Medaka's `Bool`/`Char` subsets, which
# is the easy half of §2.1 and the half a real C library does not promise.  These
# three assert what happens when it does not: an out-of-range C bool must read
# the SAME under `if` and under `match` (it used not to — see cell 7), and an
# out-of-range C codepoint must fail LOUDLY rather than print replacement
# garbage at exit 0 (cell 9).  Their in-range companions are the regression
# floor, not padding: a normalisation that mangled 0/1 or trapped on a valid
# codepoint would satisfy the headline half alone.
#
# CELL 10 is the §2.4 COPY-BACK slice (#2164).  Cells 1 and 3 pass an array to a C
# function that only READS it, which is the half that worked; cell 10 passes one
# to a C function that WRITES it, which silently did nothing before #2164 — the C
# side filled §2.4'''s throwaway copy and the Medaka array came back unchanged, at
# exit 0.  Its read-only lines are the regression floor for the copy-back being
# unconditional: it now also runs after every array call C never wrote to.
#
# Usage:  sh test/diff_compiler_llvm_ffi.sh
# Exit:   0 every cell produces its expected output;
#         1 a build failed or the output differs;
#         2 the native medaka/emitter is missing, no C compiler, no `ld -r`, or
#           libgc is absent (opt-in skip, same discipline as the other LLVM gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
CC="${CC:-clang}"
FIXDIR="$ROOT/test/ffi_fixtures"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }
command -v ld >/dev/null 2>&1 || { echo "no ld on PATH — skipping"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir $FIXDIR"; exit 1; }

# libgc probe (mirror the other native gates' opt-in skip).
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then :
else echo "libgc (bdw-gc) not found — skipping (install bdw-gc)"; exit 2; fi

export MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

fail=0
checked=0

# ── the linkable runtime+fixture object ─────────────────────────────────────
if ! "$MEDAKA" build --emit-rt-obj "$W/rt.o" >"$W/rt.log" 2>&1 || [ ! -f "$W/rt.o" ]; then
  echo "FAIL: could not --emit-rt-obj"; cat "$W/rt.log"; exit 1
fi
if ! "$CC" -O2 -c "$FIXDIR/ffi_abi_probe.c" -o "$W/probe.o" >"$W/cc.log" 2>&1; then
  echo "FAIL: could not compile $FIXDIR/ffi_abi_probe.c"; cat "$W/cc.log"; exit 1
fi
# `ld -r` (partial link) exists on both GNU ld and Apple ld — see AGENTS.md
# [B-DUAL-PLATFORM].  If a future toolchain lacks it, SKIP rather than fail: this
# gate's subject is the emitter, not the platform linker.
if ! ld -r "$W/rt.o" "$W/probe.o" -o "$W/combined.o" >"$W/ld.log" 2>&1; then
  echo "ld -r unavailable or failed on this toolchain — skipping"; cat "$W/ld.log"; exit 2
fi

# ── cell 1: every crossable shape, values asserted ──────────────────────────
# Hand-computed from test/ffi_fixtures/ffi_abi_probe.c; see that fixture's header
# for the derivation of each line.
EXPECT_PROBE='42
False
b
6.0
6
round-trip!
10
7
5.5'

if ! MEDAKA_RT_OBJ="$W/combined.o" "$MEDAKA" build "$FIXDIR/ffi_abi_probe.mdk" \
     -o "$W/probe.bin" >"$W/build.log" 2>&1; then
  echo "FAIL: ffi_abi_probe.mdk did not build"; cat "$W/build.log"; fail=$((fail+1))
else
  checked=$((checked+1))
  got="$("$W/probe.bin" 2>&1)"
  if [ "$got" = "$EXPECT_PROBE" ]; then
    echo "ok   ffi_abi_probe          9/9 crossable-shape values correct"
  else
    fail=$((fail+1))
    echo "FAIL ffi_abi_probe          output differs"
    printf 'expected:\n%s\ngot:\n%s\n' "$EXPECT_PROBE" "$got"
  fi
fi

# ── cell 2: the builtin-name exemption ──────────────────────────────────────
# `bitAnd` IS a stdlib/runtime.mdk extern.  Redeclaring it locally must keep the
# BUILTIN's codegen: 255 & 240 = 240.  A regression here looks like a link error
# for an unbound `@bitAnd`, or a wrong number — both loud, neither silent.
# ⚠️ `main` needs `<FFI>` even though the call is lowered as the BUILTIN: slice 1's
# `userExternSchemes` stamps `<FFI>` on EVERY user-declared extern row, and
# `ffiIsBuiltinExternName` exempts only the crossable-set GUARD, not the stamp.
# That asymmetry is a slice-1 observation, not something this cell asserts — the
# assertion is the printed value.
cat > "$W/builtin_name.mdk" <<'CELL2'
extern bitAnd : Int -> Int -> <> Int

main : <IO, FFI> Unit
main = println (bitAnd 255 240)
CELL2

if ! MEDAKA_RT_OBJ="$W/combined.o" "$MEDAKA" build "$W/builtin_name.mdk" \
     -o "$W/builtin.bin" >"$W/build2.log" 2>&1; then
  echo "FAIL: builtin-name redeclaration did not build"; cat "$W/build2.log"; fail=$((fail+1))
else
  checked=$((checked+1))
  got2="$("$W/builtin.bin" 2>&1)"
  if [ "$got2" = "240" ]; then
    echo "ok   builtin_name_exemption  redeclared 'bitAnd' still ran the builtin (240)"
  else
    fail=$((fail+1))
    printf 'FAIL builtin_name_exemption  expected 240, got: %s\n' "$got2"
  fi
fi

# ── cell 3: REAL LIBRARY LINKAGE via medaka.toml [foreign-libraries] ─────────
# The headline end-to-end property of the linkage slice (#2075): the same nine
# crossable-shape values as cell 1, but reached WITHOUT the MEDAKA_RT_OBJ
# partial-link workaround the header describes.  Here the C half is a genuine
# static library and the ONLY thing that puts it on the link line is the
# project's own manifest:
#
#     [foreign-libraries]
#     ffiprobe = "vendor"
#
# The search directory is deliberately RELATIVE, so this also pins that
# readForeignLibs resolves it against the PROJECT ROOT (the dir holding
# medaka.toml) and not the cwd or the medaka install root.  Identical expected
# output to cell 1 on purpose: the values prove the marshalling, the absence of
# MEDAKA_RT_OBJ proves the linkage.
P="$W/proj"
mkdir -p "$P/vendor"
cp "$FIXDIR/ffi_abi_probe.mdk" "$P/main.mdk"
printf '[package]\nname = "ffi_link_probe"\n\n[foreign-libraries]\nffiprobe = "vendor"\n' > "$P/medaka.toml"
if ! "$CC" -O2 -c "$FIXDIR/ffi_abi_probe.c" -o "$W/probe_lib.o" >"$W/cc3.log" 2>&1 \
   || ! ar rcs "$P/vendor/libffiprobe.a" "$W/probe_lib.o" >>"$W/cc3.log" 2>&1; then
  echo "could not build libffiprobe.a on this toolchain — skipping cell 3"; cat "$W/cc3.log"
elif ! "$MEDAKA" build "$P/main.mdk" -o "$W/link.bin" >"$W/build3.log" 2>&1; then
  echo "FAIL: declared-library project did not build/link"; cat "$W/build3.log"; fail=$((fail+1))
else
  checked=$((checked+1))
  got3="$("$W/link.bin" 2>&1)"
  if [ "$got3" = "$EXPECT_PROBE" ]; then
    echo "ok   ffi_manifest_linkage   9/9 values via [foreign-libraries] -L/-l (no MEDAKA_RT_OBJ)"
  else
    fail=$((fail+1))
    echo "FAIL ffi_manifest_linkage   output differs"
    printf 'expected:\n%s\ngot:\n%s\n' "$EXPECT_PROBE" "$got3"
  fi
fi

# ── cell 4: a DECLARED-BUT-ABSENT library is a Medaka diagnostic ─────────────
# #2075's other half.  A library that cannot be found must NOT reach the user as
# clang's `ld: library not found for -lfoo` wall: the driver probes each declared
# library first and reports one message naming the LIBRARY, the manifest KEY, and
# the medaka.toml it came from.  Asserted on all three, because a message that
# named only the library would leave the reader hunting for where it was declared.
# ⚠️ exit code read by REDIRECT, never through a pipe — AGENTS.md [D-BUILD-PIPE].
B="$W/badproj"
mkdir -p "$B"
cp "$FIXDIR/ffi_abi_probe.mdk" "$B/main.mdk"
printf '[package]\nname = "ffi_absent_lib"\n\n[foreign-libraries]\nnonexistent_ffi_test_lib_xyz = ""\n' > "$B/medaka.toml"
"$MEDAKA" build "$B/main.mdk" -o "$W/bad.bin" >"$W/build4.log" 2>&1
rc4=$?
checked=$((checked+1))
if [ "$rc4" -eq 0 ]; then
  echo "FAIL ffi_absent_library     build succeeded despite an undeclarable library"; fail=$((fail+1))
elif grep -q "B-FFI-LIB-NOT-FOUND" "$W/build4.log" \
  && grep -q "nonexistent_ffi_test_lib_xyz" "$W/build4.log" \
  && grep -q "\[foreign-libraries\]" "$W/build4.log" \
  && grep -q "medaka.toml" "$W/build4.log" \
  && ! grep -q "library not found for" "$W/build4.log"; then
  echo "ok   ffi_absent_library      named the library, the key, and the manifest (not clang's wall)"
else
  echo "FAIL ffi_absent_library     wrong diagnostic:"; cat "$W/build4.log"; fail=$((fail+1))
fi

# ── cell 5: ONE C SYMBOL, ONE SIGNATURE (review round S0-1) ─────────────────
# The FFI index is BARE-NAME KEYED across the WHOLE PROGRAM (`ffiExternRows` ->
# `EmitInputData.ffiExternIndex`, minted with `omFromPairs (reverseL …)` =
# first-match-wins), and the declared name IS the C symbol -- so two modules that
# each declare `cDouble` with DIFFERENT signatures name ONE C function and only
# one of the two rows reaches codegen.  Before the refusal, `useY 4.0` against an
# `Int -> Int` row printed 139888567046080 at exit 0, and the `Float -> Float`
# variant of the same collision segfaulted (exit 139).  Both passed `medaka check`.
#
# 🚨 THE CONTROL IS LOAD-BEARING, NOT DECORATION.  Two modules declaring the same
# name with the SAME signature is LEGITIMATE SHARING and must keep building -- a
# guard that banned every duplicate name would satisfy the reject half alone.
# The control asserts the VALUE (2*21=42, 2*5=10) rather than exit 0, because a
# collision guard that broke marshalling would still exit 0.
#
# No C symbol is needed for the reject half: the refusal happens at Core IR
# lowering, before any link.  The control half does need one, so it goes through
# the same MEDAKA_RT_OBJ combined object cells 1 and 2 use.
# ⚠️ exit code read by REDIRECT, never through a pipe -- AGENTS.md [D-BUILD-PIPE].
D="$W/dupproj"
mkdir -p "$D"
printf '[package]\nname = "ffi_dup_extern"\n' > "$D/medaka.toml"
cat > "$D/libx.mdk" <<'DUPX'
export
extern cDouble : Int -> <FFI> Int
export
useX : Int -> <FFI> Int
useX x = cDouble x
DUPX
cat > "$D/liby.mdk" <<'DUPY'
export
extern cDouble : Float -> <FFI> Int
export
useY : Float -> <FFI> Int
useY x = cDouble x
DUPY
cat > "$D/main.mdk" <<'DUPM'
import libx.{useX}
import liby.{useY}

main : <IO, FFI> Unit
main =
  let _ = println (useX 21)
  println (useY 4.0)
DUPM
MEDAKA_RT_OBJ="$W/combined.o" "$MEDAKA" build "$D/main.mdk" -o "$W/dup.bin" >"$W/build5.log" 2>&1
rc5=$?
checked=$((checked+1))
if [ "$rc5" -eq 0 ]; then
  echo "FAIL ffi_extern_collision   built despite two contradictory declarations of one C symbol"; fail=$((fail+1))
elif grep -q "foreign declaration collision" "$W/build5.log" \
  && grep -qxF "colliding symbol: cDouble" "$W/build5.log" \
  && grep -qxF "declaration 1: Int -> Int" "$W/build5.log" \
  && grep -qxF "declaration 2: Float -> Int" "$W/build5.log"; then
  echo "ok   ffi_extern_collision    refused, naming the symbol and both signatures"
else
  echo "FAIL ffi_extern_collision   wrong diagnostic:"; cat "$W/build5.log"; fail=$((fail+1))
fi

# ── cell 6: the CONTROL for cell 5 — identical signatures still share ────────
S="$W/shareproj"
mkdir -p "$S"
printf '[package]\nname = "ffi_share_extern"\n' > "$S/medaka.toml"
cat > "$S/libp.mdk" <<'SHP'
export
extern ffiCharNext : Int -> <FFI> Int
export
useP : Int -> <FFI> Int
useP x = ffiCharNext x
SHP
cat > "$S/libq.mdk" <<'SHQ'
export
extern ffiCharNext : Int -> <FFI> Int
export
useQ : Int -> <FFI> Int
useQ x = ffiCharNext x
SHQ
cat > "$S/main.mdk" <<'SHM'
import libp.{useP}
import libq.{useQ}

main : <IO, FFI> Unit
main =
  let _ = println (useP 21)
  println (useQ 5)
SHM
if ! MEDAKA_RT_OBJ="$W/combined.o" "$MEDAKA" build "$S/main.mdk" -o "$W/share.bin" >"$W/build6.log" 2>&1; then
  echo "FAIL: identical cross-module redeclaration did not build"; cat "$W/build6.log"; fail=$((fail+1))
else
  checked=$((checked+1))
  got6="$("$W/share.bin" 2>&1)"
  if [ "$got6" = "22
6" ]; then
    echo "ok   ffi_extern_shared       identical signatures in two modules still share one symbol (22/6)"
  else
    fail=$((fail+1))
    printf 'FAIL ffi_extern_shared      expected 22 then 6, got: %s\n' "$got6"
  fi
fi

# ── cell 7: INBOUND Bool — `if` and `match` must agree (#2128) ──────────────
# The S1 this cell exists for: FFI-ABI.md §2.1's inbound rule used to be a bare
# re-tag of whatever `long long` C returned, so `cTruthy`'s 42 became the
# immediate word 85 — neither True (3) nor False (1).  `if` untags and tests
# `!= 0` (emitIf), so it took the TRUE branch; `match` compares the word against
# 3/1 exactly (emitRefutMatch), so it fell off the end into
# E-NONEXHAUSTIVE-MATCH.  Same program, same runtime value, two answers, and the
# `if` half at exit 0.
#
# 🚨 THE IN-RANGE LINES ARE THE REGRESSION FLOOR, NOT PADDING.  A "fix" that
# normalised by MASKING the low bit, or that mapped every nonzero to False,
# would satisfy the agreement half alone.  0 must still be False and 1 must
# still be True, which is what `cFalsy`/`cOne` assert.
#
# Expected output is hand-computed from FFI-ABI.md §2.1's stated rule (C's own
# truthiness: 0 is false, every other bit pattern is true) applied to the C
# source, NOT captured: 42 -> True, 0 -> False, 1 -> True, and the `if` and
# `match` readings of each are the SAME word.
cat > "$W/ffi_bool_in.mdk" <<'CELL7'
extern cTruthy : Unit -> <FFI> Bool
extern cFalsy : Unit -> <FFI> Bool
extern cOne : Unit -> <FFI> Bool

viaMatch : Bool -> String
viaMatch b = match b
  True => "match:True"
  False => "match:False"

main : <IO, FFI> Unit
main =
  let _ = println (if cTruthy () then "if:True" else "if:False")
  let _ = println (viaMatch (cTruthy ()))
  let _ = println (cTruthy ())
  let _ = println (if cFalsy () then "if:True" else "if:False")
  let _ = println (viaMatch (cFalsy ()))
  let _ = println (if cOne () then "if:True" else "if:False")
  println (viaMatch (cOne ()))
CELL7

EXPECT_BOOL_IN='if:True
match:True
True
if:False
match:False
if:True
match:True'

if ! MEDAKA_RT_OBJ="$W/combined.o" "$MEDAKA" build "$W/ffi_bool_in.mdk" \
     -o "$W/bool_in.bin" >"$W/build7.log" 2>&1; then
  echo "FAIL: inbound-Bool program did not build"; cat "$W/build7.log"; fail=$((fail+1))
else
  checked=$((checked+1))
  got7="$("$W/bool_in.bin" 2>&1)"
  if [ "$got7" = "$EXPECT_BOOL_IN" ]; then
    echo "ok   ffi_inbound_bool       'if' and 'match' agree on an out-of-range C bool (42 -> True), 0/1 unchanged"
  else
    fail=$((fail+1))
    echo "FAIL ffi_inbound_bool       output differs"
    printf 'expected:\n%s\ngot:\n%s\n' "$EXPECT_BOOL_IN" "$got7"
  fi
fi

# ── cell 8: INBOUND Char in range — round-trips through if/match/println ─────
# The other half of #2128's regression floor.  65 IS a valid codepoint, so the
# §2.1 range check must be transparent here: 'A' through an equality test, a
# literal match arm, and Show alike.  A validation arm that trapped on a valid
# codepoint, or that clamped every value, would redden exactly this cell.
cat > "$W/ffi_char_in.mdk" <<'CELL8'
extern cCharA : Unit -> <FFI> Char

viaMatch : Char -> String
viaMatch c = match c
  'A' => "match:A"
  _ => "match:other"

main : <IO, FFI> Unit
main =
  let _ = println (if cCharA () == 'A' then "if:A" else "if:other")
  let _ = println (viaMatch (cCharA ()))
  println (cCharA ())
CELL8

EXPECT_CHAR_IN='if:A
match:A
A'

if ! MEDAKA_RT_OBJ="$W/combined.o" "$MEDAKA" build "$W/ffi_char_in.mdk" \
     -o "$W/char_in.bin" >"$W/build8.log" 2>&1; then
  echo "FAIL: inbound-Char program did not build"; cat "$W/build8.log"; fail=$((fail+1))
else
  checked=$((checked+1))
  got8="$("$W/char_in.bin" 2>&1)"
  if [ "$got8" = "$EXPECT_CHAR_IN" ]; then
    echo "ok   ffi_inbound_char       in-range codepoint 65 round-trips as 'A' through if/match/println"
  else
    fail=$((fail+1))
    echo "FAIL ffi_inbound_char       output differs"
    printf 'expected:\n%s\ngot:\n%s\n' "$EXPECT_CHAR_IN" "$got8"
  fi
fi

# ── cell 9: INBOUND Char out of range — LOUD, never replacement garbage ──────
# FFI-ABI.md §2.1's Char totality decision, pinned as behaviour: an out-of-range
# codepoint TRAPS.  There is no honest value to substitute — clamping or masking
# would invent a codepoint C never returned and print it at exit 0, which is the
# silent wrongness the whole slice exists to remove (AGENTS.md [W-QUIETER]).
# Before the fix, 1200000 was tagged as-is and `println` emitted replacement
# garbage at exit 0.
#
# TWO values, not one: 1200000 is above charMaxBound, and -1 reads as a HUGE
# unsigned — a signed `<=` bound check would let the negative sail straight
# through, so the negative arm is what pins the check as unsigned.  Asserted on
# BOTH a nonzero exit and the message text: a segfault would also exit nonzero.
# ⚠️ exit code read by REDIRECT, never through a pipe — AGENTS.md [D-BUILD-PIPE].
for cfn in cCharBig cCharNeg; do
  cat > "$W/ffi_char_oob_$cfn.mdk" <<CELL9
extern $cfn : Unit -> <FFI> Char

main : <IO, FFI> Unit
main = println ($cfn ())
CELL9
  if ! MEDAKA_RT_OBJ="$W/combined.o" "$MEDAKA" build "$W/ffi_char_oob_$cfn.mdk" \
       -o "$W/oob_$cfn.bin" >"$W/build9_$cfn.log" 2>&1; then
    echo "FAIL: out-of-range-Char program ($cfn) did not build"; cat "$W/build9_$cfn.log"; fail=$((fail+1))
    continue
  fi
  checked=$((checked+1))
  "$W/oob_$cfn.bin" >"$W/oob_$cfn.out" 2>"$W/oob_$cfn.err"
  rc9=$?
  if [ "$rc9" -eq 0 ]; then
    printf 'FAIL ffi_inbound_char_oob   %s: exited 0 with stdout: %s\n' "$cfn" "$(cat "$W/oob_$cfn.err" "$W/oob_$cfn.out")"
    fail=$((fail+1))
  elif grep -q "runtime error" "$W/oob_$cfn.err" \
    && grep -q "outside the Char range 0..1114111" "$W/oob_$cfn.err" \
    && grep -q "$cfn" "$W/oob_$cfn.err" \
    && [ ! -s "$W/oob_$cfn.out" ]; then
    printf 'ok   ffi_inbound_char_oob   %s: trapped loudly (exit %d), naming the call and the range\n' "$cfn" "$rc9"
  else
    printf 'FAIL ffi_inbound_char_oob   %s: exit %d, wrong failure:\n' "$cfn" "$rc9"; fail=$((fail+1))
    cat "$W/oob_$cfn.out" "$W/oob_$cfn.err"
  fi
done

# ── cell 10: §2.4 COPY-BACK — a C function that FILLS a caller's array (#2164) ─
# The S0 this cell exists for.  §2.4's outbound rule hands C a COPY of the array,
# never the live cell, and until #2164 nothing ever copied that buffer back — so a
# C function filling a caller-allocated `Array Int` filled a throwaway buffer and
# the Medaka array was SILENTLY unchanged, at exit 0, with no diagnostic.  Cell 1's
# `ffiSumInts` cannot catch it: that C half only READS the buffer, so it passes
# with the copy-back absent.
#
# 🚨 THE FIRST THREE LINES ARE THE REGRESSION FLOOR, NOT PADDING.  The copy-back
# is UNCONDITIONAL (a Medaka FFI signature has no "in" vs "out" parameter
# distinction), so it also runs after every READ-ONLY array call — and a copy-back
# that re-tagged wrongly, or read the count from the buffer instead of the live
# cell, would corrupt an array that C never touched.  Line 1 sums the untouched
# array, line 2 reads element 0 back IN MEDAKA, line 3 sums it AGAIN: a copy-back
# that mangled the cell would redden one of those three, and a "fix" that skipped
# the copy-back for arguments it guessed were read-only would redden line 4.
#
# Line 2 and line 4 go through `array.get`, i.e. PURE MEDAKA indexing of the live
# cell — not another FFI call.  That distinction is the assertion: `ffiSumInts`
# alone could be satisfied by a buffer that round-trips without the live cell ever
# changing, whereas `get 0 a` reads the tagged word the copy-back wrote.
#
# Expected output hand-computed from ffiFill99 in ffi_abi_probe.c (it writes the
# constant 99, chosen so the answer does not depend on what was in the array
# before), NOT captured: 1+2+3 = 6, element 0 = 1, 6 again, then 99 and 99*3 = 297.
cat > "$W/ffi_array_copyback.mdk" <<'CELL10'
import array.{get}

extern ffiFill99 : Array Int -> Int -> <FFI> Unit
extern ffiSumInts : Array Int -> Int -> <FFI> Int

show0 : Array Int -> String
show0 a = match get 0 a
  Some v => intToString v
  None => "none"

main : <IO, FFI> Unit
main =
  let a = [|1, 2, 3|]
  let _ = println (ffiSumInts a 3)
  let _ = println (show0 a)
  let _ = println (ffiSumInts a 3)
  let _ = ffiFill99 a 3
  let _ = println (show0 a)
  println (ffiSumInts a 3)
CELL10

EXPECT_COPYBACK='6
1
6
99
297'

if ! MEDAKA_RT_OBJ="$W/combined.o" "$MEDAKA" build "$W/ffi_array_copyback.mdk" \
     -o "$W/copyback.bin" >"$W/build10.log" 2>&1; then
  echo "FAIL: array copy-back program did not build"; cat "$W/build10.log"; fail=$((fail+1))
else
  checked=$((checked+1))
  got10="$("$W/copyback.bin" 2>&1)"
  if [ "$got10" = "$EXPECT_COPYBACK" ]; then
    echo "ok   ffi_array_copyback     C writes to the caller's array are visible in Medaka (99/297), read-only calls unchanged (6/1/6)"
  else
    fail=$((fail+1))
    echo "FAIL ffi_array_copyback     output differs"
    printf 'expected:\n%s\ngot:\n%s\n' "$EXPECT_COPYBACK" "$got10"
  fi
fi

# ZERO-COMPARISON guard (docs/ops/TESTING-DESIGN.md §2.3): a gate that compared
# nothing has proven nothing.
[ "$checked" -gt 0 ] || { echo "no cell ran — the gate proved nothing"; exit 2; }

printf '\n%d cell(s) checked, %d failing\n' "$checked" "$fail"

# Explicit exit, not a trailing test — an EXIT trap can override a fall-off-the-end
# status to 0 on some shells (macOS bash-3.2 /bin/sh), turning a real mismatch green.
if [ "$fail" -ne 0 ]; then
  printf 'FAILED: %d FFI lowering cell(s) wrong\n' "$fail" >&2
  exit 1
fi
exit 0
