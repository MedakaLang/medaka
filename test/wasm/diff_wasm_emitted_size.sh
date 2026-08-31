#!/usr/bin/env bash
# diff_wasm_emitted_size.sh — Slice S5 gate (#2359 closure, epic #2036 G1/G2,
# #2377).  Asserts ABSOLUTE CEILINGS on what the WasmGC backend actually
# EMITS, on all three wasm corpora (modules / plain / typed):
#
#   (a) total assembled .wasm bytes, per corpus
#   (b) the emitted-vs-reachable function-count ratio, per corpus
#
# This is the FIRST absolute ceiling on anything the wasm backend emits, as
# opposed to a relative-reduction ratio a "count the box ops"-style metric
# could lie about (F8: static op density does not predict runtime).  It is
# also the sole thing that closes #2359 — per the sprint contract's §5
# issue-closure policy, #2359 closes only when THIS instrument re-derives the
# emitted-vs-reachable ratio, not when a slice report claims a prune landed.
#
# ── "reachable" is S1's notion, not a re-derived one ─────────────────────────
# `backend/wasm_reach.mdk`'s `wasmReachFilter` (landed S1) is the ONLY thing
# in this compiler that PRUNES the WasmGC MODULES emit path to what a
# program's dispatchable method names can actually reach — see that module's
# header for the exact rule.  Re-deriving reachability independently here
# (e.g. via a fresh `wasm-opt --remove-unused-module-elements` run) would
# grade something OTHER than what S1-S4 changed, and could go green while
# reporting a number that means nothing (the contract's named S1^S5
# shared-decision risk).  So the MODULES corpus's ratio is computed from the
# UNIT COUNT `wasmReachFilter` itself operates over (top-level bind groups +
# impl entries — see `programUnitCount` in
# `compiler/entries/wasm_emit_modules_main.mdk`), reported via a
# MEDAKA_STATS-gated hook on that entry (same convention as
# `llvm_emit.mdk`'s `emitProgramWithStats`/`support/timer.mdk`'s
# `statsEnabled`: OFF by default, so every other gate that diffs this entry's
# stdout stays byte-identical).
#
# The PLAIN (`wasm_emit_main`, W1-W4) and TYPED (`wasm_emit_typed_main`, W5)
# entries never call `wasmReachFilter` at all — that filter's documented
# SCOPE is "called ONLY from wasm_emit_modules_main.mdk" (each of those two
# entries builds its own minimal, already-small impl set, no real prelude, no
# DCE).  There is no "reachable" notion to re-derive there without inventing
# one S1 never computed — which the contract's constraint forbids — so their
# ratio is the mechanically true fact for an unfiltered path: emitted /
# emitted = 1.0 exactly.  Asserted (not skipped) as a fixed tautology print —
# it computes nothing today, and would only start being a real ceiling if one
# of these entries were ever wired to an actual reachability filter, which
# would require real code changes at that point (not just this line "starting
# to be real" on its own).
#
# ── toolchain ─────────────────────────────────────────────────────────────
# wasm-tools + node>=24 ONLY (no wasm-opt/binaryen — not in any gate's
# toolchain list).  Bytes = assembled `.wasm` file size.  Function count =
# `wasm-tools print` piped through the `^  (func ` anchor (F1's method — a
# naive `(func` grep inverts the answer by also matching `(func` type decls).
#
# Skips (exit 2) exactly like its `wasm/diff_wasm*` siblings when the
# toolchain or the prebuilt oracle binaries are missing.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

EMITBIN_MAIN="$ROOT/test/bin/wasm_emit_main"
EMITBIN_TYPED="$ROOT/test/bin/wasm_emit_typed_main"
EMITBIN_MODULES="$ROOT/test/bin/wasm_emit_modules_main"

FIXDIR_PLAIN="$ROOT/test/wasm/fixtures"
FIXDIR_TYPED="$ROOT/test/wasm/fixtures_typed"
FIXDIR_MODULES="$ROOT/test/wasm/fixtures_modules"

# ── absolute ceilings (S5 landing measurement, post S1-S4, sprint-branch head
#    6a93aae55 + this slice's stats-hook commit) — headroom ~15-20% over the
#    measured total so ordinary fixture churn doesn't false-positive, while a
#    reverted S1 filter (ratio -> ~1.0, byte/func count -> ~10x) still reds
#    hard.  Re-baseline via a follow-up commit if a legitimate corpus/feature
#    addition grows these for real reasons.
MODULES_BYTES_CEIL=2450000
MODULES_FUNCS_CEIL=3200
MODULES_RATIO_CEIL_X1000=150   # ratio * 1000, integer-only arithmetic (no bc/awk float compare)

PLAIN_BYTES_CEIL=415000
PLAIN_FUNCS_CEIL=2600

TYPED_BYTES_CEIL=20500
TYPED_FUNCS_CEIL=110

# ── exact per-corpus fixture-count floors (F2/S1-2 closure) ────────────────
# These corpus sizes are fixed and every prior sprint measurement (S1-S5's own
# reports) found 0 gap on all three. `checked == 0` alone only catches "compared
# NOTHING" — it stays green when SOME fixtures silently degrade to gap while
# every ceiling above still improves (fewer bytes/funcs/ratio look like a win
# when they're actually fixtures dropping out). A gap appearing at all here is
# itself the regression signal this gate exists to catch.
MODULES_OK_EXACT=43
PLAIN_OK_EXACT=157
TYPED_OK_EXACT=9

# ── F1's wasm-opt-derived function-count floor (F2/S2-4) ───────────────────
# 1,518 — a FIXED historical reference number from F1's research pass (the
# whole 43-fixture modules corpus, aggregate), not a fresh reachability
# computation (that would violate the S1^S5 shared-decision constraint — see
# the header note above). Used only as the denominator for a second,
# function-level ratio the contract's §7 exit criterion 2 literally asks for
# ("emitted-vs-reachable FUNCTION ratio") — the existing reach-ratio is a UNIT
# ratio (S1's own notion), not this.
F1_MODULES_FUNCS_FLOOR=1518
MODULES_F1_RATIO_CEIL_X1000=2200   # emitted-funcs/F1-floor * 1000, headroom over measured

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping S5 emitted-size gate"; exit 2; }
NODE=node
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 24 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
[ "$major" -ge 24 ] || { echo "S5 SKIP  Node >= 24 required (have $($NODE --version 2>/dev/null))"; exit 2; }
[ -x "$EMITBIN_MAIN" ]    || { echo "build the wasm emitter oracles first: sh test/wasm/build_wasm_oracle.sh (missing $EMITBIN_MAIN)"; exit 2; }
[ -x "$EMITBIN_TYPED" ]   || { echo "build the wasm emitter oracles first: sh test/wasm/build_wasm_oracle.sh (missing $EMITBIN_TYPED)"; exit 2; }
[ -x "$EMITBIN_MODULES" ] || { echo "build the wasm emitter oracles first: sh test/wasm/build_wasm_oracle.sh (missing $EMITBIN_MODULES)"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0

# ── PLAIN corpus (W1-W4, no reach filter — ratio is a tautology canary) ────
plain_bytes=0; plain_funcs=0; plain_ok=0; plain_gap=0
for f in "$FIXDIR_PLAIN"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  wat="$WORK/plain.$name.wat"; err="$WORK/plain.$name.err"; wasm="$WORK/plain.$name.wasm"
  if ! "$EMITBIN_MAIN" "$f" > "$wat" 2>"$err"; then plain_gap=$((plain_gap+1)); continue; fi
  if ! wasm-tools parse "$wat" -o "$wasm" 2>>"$err"; then plain_gap=$((plain_gap+1)); continue; fi
  if ! wasm-tools validate --features=all "$wasm" 2>>"$err"; then plain_gap=$((plain_gap+1)); continue; fi
  sz=$(wc -c < "$wasm")
  fc=$(wasm-tools print "$wasm" 2>/dev/null | grep -c '^  (func ')
  plain_bytes=$((plain_bytes+sz)); plain_funcs=$((plain_funcs+fc)); plain_ok=$((plain_ok+1))
done

# ── TYPED corpus (W5, no reach filter — ratio is a tautology canary) ───────
typed_bytes=0; typed_funcs=0; typed_ok=0; typed_gap=0
for f in "$FIXDIR_TYPED"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  wat="$WORK/typed.$name.wat"; err="$WORK/typed.$name.err"; wasm="$WORK/typed.$name.wasm"
  if ! "$EMITBIN_TYPED" "$RUNTIME" "$f" > "$wat" 2>"$err"; then typed_gap=$((typed_gap+1)); continue; fi
  if ! wasm-tools parse "$wat" -o "$wasm" 2>>"$err"; then typed_gap=$((typed_gap+1)); continue; fi
  if ! wasm-tools validate --features=all "$wasm" 2>>"$err"; then typed_gap=$((typed_gap+1)); continue; fi
  sz=$(wc -c < "$wasm")
  fc=$(wasm-tools print "$wasm" 2>/dev/null | grep -c '^  (func ')
  typed_bytes=$((typed_bytes+sz)); typed_funcs=$((typed_funcs+fc)); typed_ok=$((typed_ok+1))
done

# ── MODULES corpus (W9, S1's reach filter — the real ratio) ───────────────
mod_bytes=0; mod_funcs=0; mod_reach_total=0; mod_reach_kept=0; mod_ok=0; mod_gap=0
process_modules_one() {
  name="$1"; entry="$2"; root="$3"
  wat="$WORK/mod.$name.wat"; err="$WORK/mod.$name.err"; wasm="$WORK/mod.$name.wasm"
  if ! MEDAKA_STATS=1 "$EMITBIN_MODULES" "$RUNTIME" "$CORE" "$entry" "$root" > "$wat" 2>"$err"; then mod_gap=$((mod_gap+1)); return; fi
  if ! wasm-tools parse "$wat" -o "$wasm" 2>>"$err"; then mod_gap=$((mod_gap+1)); return; fi
  if ! wasm-tools validate --features=all "$wasm" 2>>"$err"; then mod_gap=$((mod_gap+1)); return; fi
  sz=$(wc -c < "$wasm")
  fc=$(wasm-tools print "$wasm" 2>/dev/null | grep -c '^  (func ')
  rt=$(grep 'wasm-reach-total-units' "$err" | awk -F'\t' '{print $2}')
  rk=$(grep 'wasm-reach-kept-units' "$err" | awk -F'\t' '{print $2}')
  mod_bytes=$((mod_bytes+sz)); mod_funcs=$((mod_funcs+fc))
  mod_reach_total=$((mod_reach_total+rt)); mod_reach_kept=$((mod_reach_kept+rk))
  mod_ok=$((mod_ok+1))
}
for f in "$FIXDIR_MODULES"/*.mdk; do
  [ -f "$f" ] || continue
  process_modules_one "$(basename "$f")" "$f" "$(dirname "$f")"
done
for dir in "$FIXDIR_MODULES"/*/; do
  [ -d "$dir" ] || continue
  entry="${dir%/}/entry.mdk"
  [ -f "$entry" ] || continue
  process_modules_one "$(basename "${dir%/}")" "$entry" "${dir%/}"
done

checked=$((plain_ok+typed_ok+mod_ok))
if [ "$checked" -eq 0 ]; then
  echo "FAIL  0 fixtures checked across all three corpora — this is NOT a pass"
  exit 1
fi

echo "S5 emitted-size — modules: $mod_ok ok / $mod_gap gap, plain: $plain_ok ok / $plain_gap gap, typed: $typed_ok ok / $typed_gap gap"

check_exact() {
  label="$1"; actual="$2"; expect="$3"
  if [ "$actual" -ne "$expect" ]; then
    echo "FAIL  $label = $actual, expected exactly $expect (a fixture silently degraded to gap)"
    fail=1
  else
    echo "ok    $label = $actual (expected exactly $expect)"
  fi
}
check_exact "modules ok-count" "$mod_ok"   "$MODULES_OK_EXACT"
check_exact "plain ok-count"   "$plain_ok" "$PLAIN_OK_EXACT"
check_exact "typed ok-count"   "$typed_ok" "$TYPED_OK_EXACT"

check_ceil() {
  label="$1"; actual="$2"; ceil="$3"
  if [ "$actual" -gt "$ceil" ]; then
    over=$((actual-ceil))
    echo "FAIL  $label = $actual exceeds ceiling $ceil (over by $over)"
    fail=1
  else
    echo "ok    $label = $actual (ceiling $ceil)"
  fi
}

check_ceil "modules bytes"        "$mod_bytes"  "$MODULES_BYTES_CEIL"
check_ceil "modules funcs"        "$mod_funcs"  "$MODULES_FUNCS_CEIL"
mod_ratio_x1000=$(( mod_reach_total > 0 ? (mod_reach_kept * 1000) / mod_reach_total : 1000 ))
check_ceil "modules unit-kept-ratio*1000 (kept=$mod_reach_kept/total=$mod_reach_total)" "$mod_ratio_x1000" "$MODULES_RATIO_CEIL_X1000"
# Function-level ratio the contract's §7 exit criterion 2 literally names
# ("emitted-vs-reachable FUNCTION ratio") — distinct from the unit-kept-ratio
# above (which moves only with how much of S1's INPUT the filter keeps, and
# barely varies since the prelude dominates the denominator). Compares actual
# emitted function count against F1's fixed, already-measured floor.
mod_f1_ratio_x1000=$(( (mod_funcs * 1000) / F1_MODULES_FUNCS_FLOOR ))
check_ceil "modules emitted/F1-floor-ratio*1000 (funcs=$mod_funcs/F1-floor=$F1_MODULES_FUNCS_FLOOR)" "$mod_f1_ratio_x1000" "$MODULES_F1_RATIO_CEIL_X1000"

check_ceil "plain bytes"          "$plain_bytes" "$PLAIN_BYTES_CEIL"
check_ceil "plain funcs"          "$plain_funcs" "$PLAIN_FUNCS_CEIL"
# no reach filter on this entry (wasm_reach.mdk SCOPE) — emitted/emitted = 1.0 always
echo "ok    plain reach-ratio = 1.000 (no reach filter wired; tautology canary)"

check_ceil "typed bytes"          "$typed_bytes" "$TYPED_BYTES_CEIL"
check_ceil "typed funcs"          "$typed_funcs" "$TYPED_FUNCS_CEIL"
echo "ok    typed reach-ratio = 1.000 (no reach filter wired; tautology canary)"

exit "$fail"
