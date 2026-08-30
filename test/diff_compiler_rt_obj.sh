#!/bin/sh
# diff_compiler_rt_obj.sh — PROOF GATE for the MEDAKA_RT_OBJ build fast path.
#
# `medaka build` can link the C runtime three ways: compile runtime/medaka_rt.c
# INLINE (now only when the object cache is off — see MEDAKA_NO_OBJ_CACHE below);
# link an object named explicitly by MEDAKA_RT_OBJ, precompiled once via
# `medaka build --emit-rt-obj <path>` (how the heavy gates — diff_compiler_engines,
# build_construct_coverage, build_oracles — skip ~0.76s of redundant clang per
# build); or, since #133, link an AUTO-CACHED object that build_cmd.mdk manages
# itself, which is what an ordinary user build does by default.  All three must
# produce the same binary, and this gate pins ALL THREE against the inline arm.
#
# ⚠️ THE CACHED ARM IS NOT REDUNDANT WITH THE EXPLICIT ONE.  This header used to
# say the cached object "is compiled by the same `cachedRtObj` code path with the
# same flags" as --emit-rt-obj, and therefore needed no arm of its own.  That is
# not what the source says: `populateRtObj` (the cache-miss compile) and
# `emitRtObj` (the --emit-rt-obj compile) are TWO INDEPENDENTLY WRITTEN clang
# argument lists in build_cmd.mdk that happen to agree today.  They are the same
# flags, not the same literal — so an edit to one and not the other diverges the
# DEFAULT user build from everything this gate proves, with nothing to catch it.
# Hence a third arm: the cache path is the path ordinary users take, so it is the
# one arm whose divergence would ship.
#
# That is only sound if the link paths — inline `medaka_rt.c` vs prebuilt
# `medaka_rt.o` — produce the SAME binary. A one-time manual check (36/36 fixtures)
# proved they do; THIS GATE makes the proof permanent, so a future change to
# build_cmd.mdk / medaka_rt.c / the emitter that made the paths diverge is
# caught here instead of silently miscompiling every fast-path build.
#
# For a sample of fixtures, at BOTH opt levels the suite uses (-O0 for oracles, -O2
# for the default/engines path), it builds each fixture THREE times — inline, with
# MEDAKA_RT_OBJ, and via the auto cache (MEDAKA_CACHE_DIR pointed at a scratch dir,
# MEDAKA_RT_OBJ and MEDAKA_NO_OBJ_CACHE both explicitly cleared so an ambient value
# from a parent harness cannot turn this arm back into one of the other two) — and
# asserts all three are byte-identical (whole file,
# not just .text: on this toolchain the prebuilt-object link reproduces the exact
# bytes of the inline compile, so we hold to the strictest possible check; if a
# future toolchain perturbs only non-.text metadata, relax to a .text compare and
# say why here).  The cached arm additionally asserts that the scratch cache dir
# actually filled with rt-<hash>.o objects, so a cache that silently fails open to
# the inline compile cannot pass this arm vacuously.
#
# Usage:  sh test/diff_compiler_rt_obj.sh
# Exit:   0 if every (fixture, opt) pair is byte-identical inline-vs-prebuilt and
#           inline-vs-cached, and the cache directory was populated;
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

# A small, cheap, representative sample: an ordinary ADT program, both refutable-
# guard shapes (they exercise a nontrivial slice of the runtime), and a couple of
# construct fixtures. Kept small on purpose — this gate is a correctness tripwire,
# not a coverage sweep, and each entry is TWO builds × TWO opt levels.
SAMPLE="
$ROOT/test/llvm_fixtures/guard_match_ctor.mdk
$ROOT/test/llvm_fixtures/guard_refut_clause.mdk
$ROOT/test/llvm_fixtures/guard_refut_clause_chain.mdk
$ROOT/test/construct_fixtures/tuple_neq.mdk
$ROOT/test/construct_fixtures/type_alias.mdk
"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

checked=0
identical=0
cache_checked=0
cache_identical=0
fail=0

for OPT in -O0 -O2; do
  rtobj="$W/medaka_rt$OPT.o"
  if ! MEDAKA_CLANG_OPT="$OPT" "$MEDAKA" build --emit-rt-obj "$rtobj" >/dev/null 2>&1 || [ ! -f "$rtobj" ]; then
    echo "FAIL: could not --emit-rt-obj at $OPT"; fail=$((fail+1)); continue
  fi
  # THIRD-ARM cache dir: per opt level, inside the gate's own scratch tree, so we
  # never read or write the invoking user's real ~/.cache/medaka and the "did the
  # cache populate?" assertion below counts only objects THIS run produced.
  cachedir="$W/objcache$OPT"
  echo "cache arm $OPT: MEDAKA_CACHE_DIR=$cachedir"
  for src in $SAMPLE; do
    [ -f "$src" ] || { echo "FAIL: missing sample fixture $src"; fail=$((fail+1)); continue; }
    label="$(basename "$src" .mdk)"
    inline="$W/$label$OPT.inline"
    prebuilt="$W/$label$OPT.prebuilt"
    # MEDAKA_NO_OBJ_CACHE=1 IS LOAD-BEARING, NOT BELT-AND-BRACES. Since the
    # automatic runtime-object cache landed (#133, build_cmd.mdk `cachedRtObj`),
    # a build with MEDAKA_RT_OBJ unset no longer compiles medaka_rt.c inline —
    # it silently links a CACHED object. Without this the "inline" arm below is
    # a second prebuilt-object arm, the gate compares an object against an
    # object, and it passes VACUOUSLY while proving nothing about the inline
    # path it exists to protect. This is the one place in the suite that still
    # exercises the inline compile, so it must opt out of the cache explicitly.
    if ! MEDAKA_NO_OBJ_CACHE=1 MEDAKA_CLANG_OPT="$OPT" "$MEDAKA" build --allow-internal "$src" -o "$inline" >/dev/null 2>&1; then
      echo "FAIL: inline build failed ($label $OPT)"; fail=$((fail+1)); continue
    fi
    if ! MEDAKA_RT_OBJ="$rtobj" MEDAKA_CLANG_OPT="$OPT" "$MEDAKA" build --allow-internal "$src" -o "$prebuilt" >/dev/null 2>&1; then
      echo "FAIL: prebuilt build failed ($label $OPT)"; fail=$((fail+1)); continue
    fi
    checked=$((checked+1))
    if cmp -s "$inline" "$prebuilt"; then
      identical=$((identical+1))
      printf 'ok   %-28s %s  byte-identical\n' "$label" "$OPT"
    else
      fail=$((fail+1))
      printf 'FAIL %-28s %s  inline vs prebuilt DIFFER\n' "$label" "$OPT"
    fi
    # THIRD ARM — the DEFAULT user path: the auto object cache (build_cmd.mdk
    # `cachedRtObj`/`populateRtObj`). MEDAKA_RT_OBJ and MEDAKA_NO_OBJ_CACHE are
    # set to the EMPTY STRING rather than left alone: build_cmd.mdk treats "" as
    # unset for both (`envOr … "" /= ""`), and an ambient value inherited from a
    # parent harness (build_oracles.sh exports MEDAKA_RT_OBJ) would otherwise
    # silently turn this arm into a duplicate of the prebuilt arm above.
    cached="$W/$label$OPT.cached"
    if ! MEDAKA_RT_OBJ= MEDAKA_NO_OBJ_CACHE= MEDAKA_CACHE_DIR="$cachedir" \
         MEDAKA_CLANG_OPT="$OPT" "$MEDAKA" build --allow-internal "$src" -o "$cached" >/dev/null 2>&1; then
      echo "FAIL: cached build failed ($label $OPT)"; fail=$((fail+1)); continue
    fi
    cache_checked=$((cache_checked+1))
    if cmp -s "$inline" "$cached"; then
      cache_identical=$((cache_identical+1))
      printf 'ok   %-28s %s  byte-identical (cache arm)\n' "$label" "$OPT"
    else
      fail=$((fail+1))
      printf 'FAIL %-28s %s  inline vs CACHED DIFFER\n' "$label" "$OPT"
    fi
  done
  # ANTI-VACUITY for the cache arm. The cache is fail-open by design: an
  # unwritable dir, a missing sha256sum, a failed mv all return "" and the build
  # quietly compiles medaka_rt.c inline — producing a byte-identical binary and a
  # PASSING comparison that proved nothing about populateRtObj's flag list. The
  # only evidence the cache path actually ran is an object in the cache dir.
  n_objs=$(ls "$cachedir"/rt-*.o 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n_objs" -lt 1 ]; then
    echo "FAIL: cache arm $OPT produced no rt-<hash>.o in $cachedir — the cache failed open, so the comparison above is vacuous"
    fail=$((fail+1))
  else
    printf 'ok   cache arm %s populated %s object(s) in %s\n' "$OPT" "$n_objs" "$cachedir"
  fi
done

# ZERO-COMPARISON guard (docs/ops/TESTING-DESIGN.md §2.3): a gate that compared
# nothing has proven nothing.
[ "$checked" -gt 0 ] || { echo "the sample built nothing — the gate proved nothing"; exit 2; }
[ "$cache_checked" -gt 0 ] || { echo "the cache arm built nothing — the gate proved nothing about the default path"; exit 2; }

printf '\n%d/%d fixture-builds byte-identical inline-vs-prebuilt (%d checked)\n' \
  "$identical" "$checked" "$checked"
printf '%d/%d fixture-builds byte-identical inline-vs-cached (%d checked)\n' \
  "$cache_identical" "$cache_checked" "$cache_checked"

# EXIT STATUS — gated EXPLICITLY on $fail. Every failure path above (a failed
# --emit-rt-obj, a missing fixture, a failed inline/prebuilt/cached build, an
# unpopulated cache dir, and a byte
# MISMATCH on either comparison) increments $fail, and a byte-identity proof gate that observed a
# mismatch MUST exit nonzero — otherwise it is exactly the "detected a divergence
# and reported success" bug this whole optimization is guarding against. An
# explicit `exit` (not a trailing `[ "$fail" -eq 0 ]`) is deliberate: the trailing-
# test idiom leaves the final status to the shell's fall-off-the-end behavior,
# which an EXIT trap (`rm -rf "$W"` above) can override to 0 on some shells
# (notably macOS's bash-3.2 /bin/sh) — a silent green over a real mismatch. An
# explicit `exit N` is preserved through the trap on every shell.
if [ "$fail" -ne 0 ]; then
  printf 'FAILED: %d fixture-build(s) diverged inline-vs-prebuilt or inline-vs-cached (or failed to build, or left the cache empty)\n' "$fail" >&2
  exit 1
fi
exit 0
