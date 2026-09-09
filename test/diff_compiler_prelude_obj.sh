#!/bin/sh
# diff_compiler_prelude_obj.sh — PROOF GATE for both SPLIT-PRELUDE build paths: the
# MEDAKA_PRELUDE_OBJ object (issue #118) and the cached ThinLTO bitcode (issue #2730).
#
# `medaka build` normally hands clang the WHOLE module: on a nine-line fixture that
# is 11,841 lines of IR, 88% of which (270 of 281 defines) is the prelude — and
# clang -O2 re-optimises all of it on every single build.  The CI fast path
# precompiles the prelude ONCE (`medaka build --emit-prelude-obj <path>`) and links
# the object via MEDAKA_PRELUDE_OBJ, so a per-program build only compiles the
# program's own code plus its `@mdk_disp_*` dispatchers.
#
# Since #2730 the same split happens by DEFAULT with the shared half as ThinLTO
# bitcode rather than an object, which keeps the cross-module inlining the object
# gives up.  Both are the same soundness bet: one shared half, built once from
# stdlib/core.mdk alone, serving a program it has never seen.
#
# That is only sound if all three link paths — the whole module inline, the split
# prelude.o + program half, and the split prelude.bc + program half — produce a
# program that BEHAVES THE SAME.  This gate makes that proof permanent, with the
# WHOLE-MODULE build as the reference arm both split arms are compared against.
#
# WHY OUTPUT-IDENTITY, NOT BYTE-IDENTITY (unlike its sibling diff_compiler_rt_obj.sh):
# the rt-obj fast path compiles the SAME C to the SAME object, so the binaries are
# byte-identical and we hold it to that.  Here the two paths genuinely differ — one
# module vs two, with cross-module inlining lost across the object boundary — so the
# binaries CANNOT be byte-equal and the honest invariant is the one that matters:
# the program computes the same thing.  Both stdout AND exit status are compared.
#
# THE SPECIFIC MISCOMPILE THIS IS WATCHING FOR.  `prelude.o` is built ONCE, from
# stdlib/core.mdk alone, and must serve every program.  Two things in the emitter
# would silently break that if they regressed:
#   * a per-program `@mdk_disp_*` dispatcher leaking INTO prelude.o — it would then
#     dispatch on the prelude's impl set and miss the program's own impls;
#   * a prelude body baking in an impl decision (the sole-impl direct call, WS-1b) —
#     sound for the prelude alone, WRONG the moment a program adds a second impl.
# So the sample below is impl-HEAVY on purpose: fixtures that define their own
# `impl`s of prelude interfaces, and exercise them through prelude generics
# (`==` on a list of a user type, `sort`, `Debug`, deriving), are exactly the
# programs a stale prelude.o would get wrong.
#
# Usage:  sh test/diff_compiler_prelude_obj.sh
# Exit:   0 if every (fixture, opt, split-arm) triple matches the whole-module reference;
#         1 on any divergence or build failure;
#         2 if the native medaka/emitter is missing, no C compiler, or libgc is
#           absent (opt-in skip, same discipline as the other LLVM gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
CC="${CC:-clang}"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

# libgc probe (mirror the other native gates' opt-in skip).
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then :
else echo "libgc (bdw-gc) not found — skipping (install bdw-gc)"; exit 2; fi

export MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER"

# Impl-heavy on purpose (see the header): each of these defines impls of prelude
# interfaces and routes them through prelude generics, which is the only shape a
# stale/over-baked prelude.o can get wrong.  Kept small — this is a correctness
# tripwire, not a coverage sweep, and each entry is THREE builds × TWO opt levels.
#
# `interface_impl` earns its place twice over: its interface has exactly ONE impl,
# which is the WS-1b sole-impl direct-call shape — the one that must NOT be baked
# into prelude.o, and whose shortcut therefore moved inside the dispatcher body.
# `default_impl_override` covers `@mdk_default_*` (the other name-derived symbol
# family both halves can demand); `superclass`/`nested_requires_dict` cover dicts
# with `requires` element witnesses; the `deriving_*` pair covers generated impls.
SAMPLE="
$ROOT/test/construct_fixtures/interface_impl.mdk
$ROOT/test/construct_fixtures/superclass.mdk
$ROOT/test/construct_fixtures/nested_requires_dict.mdk
$ROOT/test/construct_fixtures/default_impl_override.mdk
$ROOT/test/construct_fixtures/deriving_eq.mdk
$ROOT/test/construct_fixtures/deriving_debug.mdk
$ROOT/test/construct_fixtures/operator_eq_user_impl.mdk
$ROOT/test/construct_fixtures/maximum_minimum_adt.mdk
$ROOT/test/construct_fixtures/multi_param_iface.mdk
$ROOT/test/construct_fixtures/tuple_neq.mdk
$ROOT/test/llvm_fixtures/guard_refut_clause_chain.mdk
$ROOT/test/wasm/fixtures/adt_enum_nullary.mdk
"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

checked=0
same=0
fail=0

for OPT in -O0 -O2; do
  pobj="$W/prelude$OPT.o"
  if ! MEDAKA_CLANG_OPT="$OPT" "$MEDAKA" build --emit-prelude-obj "$pobj" >/dev/null 2>&1 || [ ! -f "$pobj" ]; then
    echo "FAIL: could not --emit-prelude-obj at $OPT"; fail=$((fail+1)); continue
  fi
  for src in $SAMPLE; do
    [ -f "$src" ] || { echo "FAIL: missing sample fixture $src"; fail=$((fail+1)); continue; }
    label="$(basename "$src" .mdk)"
    inline="$W/$label$OPT.inline"
    prebuilt="$W/$label$OPT.prebuilt"
    bitcode="$W/$label$OPT.bitcode"
    # MEDAKA_PARALLEL_CODEGEN=0 pins the reference arm to the WHOLE-MODULE link.
    # Since #2730 an ordinary `medaka build` may split the prelude off as cached
    # ThinLTO bitcode by DEFAULT, and a reference arm that also split would leave
    # this gate comparing two split builds with each other — it would still pass
    # while proving nothing about the thing it exists to prove, which is that a
    # prelude built ONCE, from stdlib/core.mdk alone, serves a program it has
    # never seen.  The reference must be the unsplit build.
    if ! MEDAKA_PARALLEL_CODEGEN=0 MEDAKA_CLANG_OPT="$OPT" "$MEDAKA" build --allow-internal "$src" -o "$inline" >/dev/null 2>&1; then
      echo "FAIL: inline build failed ($label $OPT)"; fail=$((fail+1)); continue
    fi
    "$inline" > "$W/$label$OPT.inline.out" 2>&1; rc_i=$?
    # Two split arms, both against that same unsplit reference: the OBJECT
    # (MEDAKA_PRELUDE_OBJ, issue #118) and the cached ThinLTO BITCODE (#2730,
    # the default path).  They fail in the same ways for the same reasons — a
    # per-program dispatcher leaking into the shared half, or a prelude body
    # baking in an impl decision — so both are held to the same fixtures.
    if ! MEDAKA_PRELUDE_OBJ="$pobj" MEDAKA_CLANG_OPT="$OPT" "$MEDAKA" build --allow-internal "$src" -o "$prebuilt" >/dev/null 2>&1; then
      echo "FAIL: prebuilt build failed ($label $OPT)"; fail=$((fail+1)); continue
    fi
    if ! MEDAKA_CLANG_OPT="$OPT" "$MEDAKA" build --allow-internal "$src" -o "$bitcode" >/dev/null 2>&1; then
      echo "FAIL: bitcode build failed ($label $OPT)"; fail=$((fail+1)); continue
    fi
    "$prebuilt" > "$W/$label$OPT.prebuilt.out" 2>&1; rc_p=$?
    "$bitcode"  > "$W/$label$OPT.bitcode.out"  2>&1; rc_b=$?
    for arm in prebuilt bitcode; do
      case "$arm" in
        prebuilt) rc_a=$rc_p ;;
        *)        rc_a=$rc_b ;;
      esac
      checked=$((checked+1))
      if [ "$rc_i" -eq "$rc_a" ] && cmp -s "$W/$label$OPT.inline.out" "$W/$label$OPT.$arm.out"; then
        same=$((same+1))
        printf 'ok   %-28s %s %-8s same output (exit %d)\n' "$label" "$OPT" "$arm" "$rc_i"
      else
        fail=$((fail+1))
        printf 'FAIL %-28s %s %-8s inline(exit %d) vs %s(exit %d) DIVERGED\n' \
          "$label" "$OPT" "$arm" "$rc_i" "$arm" "$rc_a"
        diff "$W/$label$OPT.inline.out" "$W/$label$OPT.$arm.out" | head -10
      fi
    done
  done
done

printf '\n%d/%d split-half builds behave identically against the whole-module reference (%d checked)\n' \
  "$same" "$checked" "$checked"

# EXIT STATUS — gated EXPLICITLY on $fail, for the reason spelled out at the foot of
# test/diff_compiler_rt_obj.sh: a trailing-test idiom leaves the final status to the
# shell's fall-off-the-end behavior, which the EXIT trap above can override to 0 on
# some shells (notably macOS's bash-3.2 /bin/sh) — a silent green over a real
# divergence, which is precisely the bug class this gate exists to catch.
#
# ⚠️ $fail is checked BEFORE the zero-comparison guard, and that ORDER IS LOAD-BEARING.
# Found by breaking this gate on purpose: injecting a per-program dispatcher into
# prelude.o makes every prebuilt link fail with a duplicate symbol, so NOTHING ever
# reaches the comparison — `checked` stays 0 while `fail` climbs to 24.  With the
# guard first, the gate exited 2 (= SKIP, the opt-in "no toolchain here" code) on 24
# real failures: a regression reported as "not run".  A gate that observed failures
# must FAIL, whether or not it also managed to compare anything.
if [ "$fail" -ne 0 ]; then
  printf 'FAILED: %d split-half build(s) diverged from the whole-module reference (or failed to build)\n' "$fail" >&2
  exit 1
fi

# ZERO-COMPARISON guard (docs/ops/TESTING-DESIGN.md §2.3): a gate that compared
# nothing has proven nothing.  Only reachable with fail == 0, i.e. an empty SAMPLE.
[ "$checked" -gt 0 ] || { echo "the sample built nothing — the gate proved nothing"; exit 2; }
exit 0
