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
# LINKING.  User-object linkage is #2074's next slice; `medaka build` has no flag
# for extra objects yet.  So the fixture's C half is merged into the runtime object
# and linked through the existing MEDAKA_RT_OBJ fast path — a REAL `medaka build`
# link, not a hand-rolled clang line, so the gate exercises the driver it is meant
# to.  When the linkage slice lands, this should switch to whatever flag it adds.
#
# Usage:  sh test/diff_compiler_llvm_ffi.sh
# Exit:   0 both cells produce their expected output;
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
