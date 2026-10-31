#!/usr/bin/env bash
# tmc_census.sh — per-function TMC census across BOTH backends (TMC parity arc).
#
# Emits a pinned corpus through the LLVM and WasmGC emitters and extracts, per
# backend, the set of SOURCE functions that received a TMC (tail-modulo-cons)
# destination-passing transform.  The parity gate (diff_compiler_tmc_parity_test.mdk)
# wraps this helper and FAILS on any DIFF row; run standalone to inspect.
# Comparison is exact on the PROBE arm and subset-tolerant (wasm ⊆ llvm) on the
# SHIPPING arm — see the summary section at the bottom for why.
#
# Extraction is marker-first: both emitters emit a deterministic census marker
# per TMC decision (`; tmc: <fn> <mode>` in .ll / `;; tmc: <fn> <mode>` in .wat).
# When no marker is present in an artifact (older binaries), falls back to IR
# shape (LLVM: defines containing `br label %trmcloop`; wasm: funcs containing
# `$tmcloop`, plus `<root>__disploop` group functions).  Modes:
#   trmc  — self-recursive/impl destination-passing loop (Stage 1 / B-dispatch)
#   group:<root> — member of a dispatch-graph (b') TMC group rooted at <root>
#
# Corpus (must stay emit-able by BOTH backends):
#   • test/stack_fixtures/*.mdk          (prelude-free deep builders)
#   • test/wasm/fixtures/w_trmc_*.mdk    (wasm TMC fixtures, incl. dispatch shape)
#   • test/wasm/fixtures/w_deep_append.mdk (dict-carrying builder + `++`)
#   • compiler/entries/check_main.mdk    (the compiler front-end module graph —
#     the real-world corpus: lexer/layout/parser/typecheck families + prelude impls)
#
# Each fixture is emitted through TWO arms:
#   • the PROBE arm (llvm_emit_main / wasm_emit_main): parse→desugar→lower→emit,
#     NO typecheck, NO prelude — a cheap detection-drift signal, but blind to the
#     dict-param population (no typecheck ⇒ no dictPass ⇒ no `$dict` params);
#   • the SHIPPING arm (medaka_emitter / wasm_emit_modules_main with
#     stdlib/runtime.mdk + stdlib/core.mdk — the exact pair `medaka build` shells
#     out to): the path users take.  Written as <name>.ship.{llvm,wasm}.tmc.
#     An unannotated polymorphic builder carries a `$dict` param ONLY here, which
#     is how TMC once silently declined on every such builder while this census
#     stayed green (archive/design/WASM-TMC-GAP-DESIGN.md).
#
# COVERAGE PINS: a fixture may declare `-- EXPECT-TMC: fn1 fn2 …` in its header.
# Every pinned fn must appear (any mode) in BOTH backends' SHIPPING sets, else
# the census fails with a PINFAIL row.  Parity between two sets that both
# dropped a function is vacuous; the pins are the coverage claim.
#
# Usage: sh test/tmc_census.sh [outdir]
#   Writes <item>.{llvm,wasm}.tmc sorted set files + SUMMARY into outdir
#   (default: a mktemp dir, path printed).  Exit 0 unless an EMIT or PIN fails.
#
# FAN-OUT: corpus items run concurrently over xargs -P (TMC_CENSUS_JOBS, default
# min(4, NCPU/2), at least 1).  Each item runs its LLVM arm and its WASM arm in
# parallel; the graph item (check_main, the largest) is dispatched first.  Each
# worker leaves item.<n>.{out,pins,rc} in outdir and the main run replays them in
# corpus order, so stdout, PINFAILS, SUMMARY and the exit status are order-stable.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITTER="$ROOT/medaka_emitter"
LLVM_ONE="$ROOT/test/bin/llvm_emit_main"
WASM_ONE="$ROOT/test/bin/wasm_emit_main"
WASM_MODS="$ROOT/test/bin/wasm_emit_modules_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
GRAPH_ENTRY="$ROOT/compiler/entries/check_main.mdk"

for b in "$EMITTER" "$LLVM_ONE" "$WASM_ONE" "$WASM_MODS"; do
  # These four binaries come from THREE different builders, so the hint lists all three —
  # but the build_oracles one names the TARGETED form (#527): bare build_oracles.sh spawns
  # the xargs -P pool AGENTS.md documents as having killed several agents.
  [ -x "$b" ] || { echo "missing $b — try: make medaka | FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$b") | sh test/wasm/build_wasm_oracle.sh"; exit 2; }
done

# --worker OUTDIR N re-enters this script under xargs; it runs item N only.
WORKER_MODE=0
if [ "${1:-}" = "--worker" ]; then
  WORKER_MODE=1
  OUT="$2"
else
  OUT="${1:-$(mktemp -d /tmp/tmc_census.XXXXXX)}"
  mkdir -p "$OUT"
fi

# extract_ll FILE — one "<fn> <mode>" line per TMC'd source function, sorted.
extract_ll() {
  if grep -q '^; tmc: ' "$1"; then
    sed -n 's/^; tmc: //p' "$1"
  else
    awk '/^define /{fn=$0; sub(/.*@/,"",fn); sub(/\(.*/,"",fn); cur=fn}
         /br label %trmcloop/{print cur " trmc"}
         /gdispexit[0-9]*:/{print cur " group-root"}' "$1"
  fi | sed 's/^mdk_//' | sort -u
}

# extract_wat FILE — same contract for a WAT artifact.
extract_wat() {
  if grep -q '^ *;; tmc: ' "$1"; then
    sed -n 's/^ *;; tmc: //p' "$1"
  else
    { awk '/\(func \$/{fn=$0; sub(/.*\(func \$/,"",fn); sub(/[ )].*/,"",fn); cur=fn}
           /\$l[.]tmcloop[.]0/{print cur " trmc"}' "$1"
      grep -o '(func \$[A-Za-z0-9_]*__disploop' "$1" \
        | sed 's/(func \$//; s/__disploop//; s/$/ group-root/'; }
  fi | sed 's/^mdk_//' | sort -u
}

# extract_pair NAME — both artifacts already emitted to $OUT/NAME.{ll,wat}.
extract_pair() {
  extract_ll "$OUT/$1.ll" > "$OUT/$1.llvm.tmc"
  extract_wat "$OUT/$1.wat" > "$OUT/$1.wasm.tmc"
}

# emit_to BACKEND NAME CMD... — runs one emitter. Writes NAME.{ll,wat} and NAME.err and
# records the exit status in NAME.<backend>.rc. Never prints: the replay decides what the
# serial census would have reported.
emit_to() {
  be="$1"; nm="$2"; shift 2
  ext=ll; [ "$be" = wasm ] && ext=wat
  "$@" > "$OUT/$nm.$ext" 2>"$OUT/$nm.$ext.err"
  echo "$?" > "$OUT/$nm.$be.rc"
}

# run_arm BACKEND KIND NAME FIXTURE — one backend's emits for one corpus item, in the
# serial census's order. KIND F = fixture (probe, then shipping); G = the graph item.
run_arm() {
  be="$1"; kind="$2"; name="$3"; fx="$4"
  if [ "$kind" = G ]; then
    if [ "$be" = llvm ]; then
      emit_to llvm "$name" "$EMITTER" "$RUNTIME" "$CORE" "$GRAPH_ENTRY" "$ROOT/compiler" "$ROOT/stdlib"
    else
      emit_to wasm "$name" "$WASM_MODS" "$RUNTIME" "$CORE" "$GRAPH_ENTRY" "$ROOT/compiler" "$ROOT/stdlib"
    fi
  elif [ "$be" = llvm ]; then
    emit_to llvm "$name" "$LLVM_ONE" "$fx"
    emit_to llvm "$name.ship" "$EMITTER" "$RUNTIME" "$CORE" "$fx"
  else
    emit_to wasm "$name" "$WASM_ONE" "$fx"
    emit_to wasm "$name.ship" "$WASM_MODS" "$RUNTIME" "$CORE" "$fx"
  fi
}

# check_pins FIXTURE NAME PINFILE — enforce the fixture's `-- EXPECT-TMC:` pins against
# the SHIPPING sets.  A pinned fn must appear (any mode; module-prefixed names
# match on the `__<fn>` suffix) in BOTH backends' NAME.ship.*.tmc.  Returns 1 on any miss.
check_pins() {
  pin_fx="$1"; pin_nm="$2"; pin_file="$3"; pin_rc=0
  pins="$(sed -n 's/^-- EXPECT-TMC: *//p' "$pin_fx")"
  [ -n "$pins" ] || return 0
  for fn in $pins; do
    for be in llvm wasm; do
      if ! grep -Eq "(^|__)$fn " "$OUT/$pin_nm.ship.$be.tmc" 2>/dev/null; then
        echo "PINFAIL $pin_nm: '$fn' missing from the $be SHIPPING TMC set" >> "$pin_file"
        pin_rc=1
      fi
    done
  done
  return $pin_rc
}

# worker N — one corpus item. Both arms run concurrently; the replay below mirrors the
# serial census exactly: a probe-pair failure suppresses the wasm message when llvm
# already failed, and extraction and pins run only when both emits of a pair succeeded.
worker() {
  n="$1"
  line="$(sed -n "${n}p" "$OUT/items")"
  kind="${line%%|*}"; rest="${line#*|}"
  name="${rest%%|*}"; fx="${rest#*|}"
  run_arm llvm "$kind" "$name" "$fx" &
  la=$!
  run_arm wasm "$kind" "$name" "$fx" &
  wa=$!
  wait "$la"
  wait "$wa"

  rc=0
  {
    if [ "$kind" = G ]; then pairs="$name"; else pairs="$name $name.ship"; fi
    for nm in $pairs; do
      lr="$(cat "$OUT/$nm.llvm.rc" 2>/dev/null)"
      wr="$(cat "$OUT/$nm.wasm.rc" 2>/dev/null)"
      if [ "${lr:-1}" != 0 ]; then
        echo "EMIT-FAIL llvm $nm"; head -5 "$OUT/$nm.ll.err"; rc=1
      elif [ "${wr:-1}" != 0 ]; then
        echo "EMIT-FAIL wasm $nm"; head -5 "$OUT/$nm.wat.err"; rc=1
      else
        extract_pair "$nm"
        if [ "$kind" = F ] && [ "$nm" = "$name.ship" ]; then
          check_pins "$fx" "$name" "$OUT/item.$n.pins" || rc=1
        fi
      fi
    done
  } > "$OUT/item.$n.out"
  echo "$rc" > "$OUT/item.$n.rc"
}

if [ "$WORKER_MODE" = 1 ]; then
  worker "$3"
  exit 0
fi

# ── corpus enumeration (serial, cheap): one line per item, corpus order, graph last ──
rm -f "$OUT"/item.* "$OUT/PINFAILS"
: > "$OUT/items"
for f in "$ROOT"/test/stack_fixtures/*.mdk "$ROOT"/test/wasm/fixtures/w_trmc_*.mdk \
         "$ROOT"/test/wasm/fixtures/w_deep_append.mdk; do
  [ -f "$f" ] || continue
  printf 'F|%s|%s\n' "$(basename "$f" .mdk)" "$f" >> "$OUT/items"
done
printf 'G|check_main|\n' >> "$OUT/items"
N="$(wc -l < "$OUT/items" | tr -d ' ')"

NCPU="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
JOBS=$(( NCPU / 2 ))
[ "$JOBS" -gt 4 ] && JOBS=4
[ "$JOBS" -lt 1 ] && JOBS=1
JOBS="${TMC_CENSUS_JOBS:-$JOBS}"

# Dispatch: the graph item (N, the largest) first, then the rest in corpus order.
{
  echo "$N"
  i=1
  while [ "$i" -lt "$N" ]; do echo "$i"; i=$((i + 1)); done
} | xargs -P "$JOBS" -n 1 sh "$ROOT/test/tmc_census.sh" --worker "$OUT"

# ── replay in corpus order ───────────────────────────────────────────────────────
fail=0
i=1
while [ "$i" -le "$N" ]; do
  cat "$OUT/item.$i.out" 2>/dev/null
  if [ -s "$OUT/item.$i.pins" ]; then cat "$OUT/item.$i.pins" >> "$OUT/PINFAILS"; fi
  [ "$(cat "$OUT/item.$i.rc" 2>/dev/null)" = 0 ] || fail=1
  i=$((i + 1))
done

# is_shipping_item NAME — true for the SHIPPING-arm items (<x>.ship, and the
# bare check_main module graph), false for the PROBE-arm single-file items.
# The distinction is load-bearing for the comparison below: only the shipping
# arm goes through wasm_emit_modules_main.
is_shipping_item() {
  case "$1" in *.ship | check_main) return 0 ;; *) return 1 ;; esac
}

# ── summary ───────────────────────────────────────────────────────────────────
#
# Comparison semantics differ BY ARM, and that asymmetry is by design:
#
#   • PROBE arm (llvm_emit_main / wasm_emit_main): EXACT parity, as always.
#     Neither probe calls wasmReachFilter, so any set difference at all is a
#     real detection/eligibility drift — exactly what this census exists for.
#
#   • SHIPPING arm (<x>.ship + check_main, emitted by wasm_emit_modules_main):
#     wasm's set may be a strict SUBSET of llvm's.  wasm_emit_modules_main runs
#     wasmReachFilter (compiler/backend/wasm_reach.mdk, the
#     wasm-emit-only-what-runs sprint) over the CProgram AFTER TRMC marking,
#     dropping dispatch-unreachable functions before emission — so a TMC'd
#     helper this fixture never reaches is simply never emitted, and therefore
#     carries no census marker.  LLVM has no such filter: dceFilter
#     (compiler/ir/dce.mdk, shared with wasm and deliberately out of that
#     sprint's scope) never removes an impl/method body, so llvm's shipping set
#     is a superset of anything wasm's pruned set can hold.  wasm ⊆ llvm on this
#     arm is expected and permanent; it is reported as SUBSET, not DIFF.
#
# Still a hard DIFF on EITHER arm — this is what keeps the subset rule honest:
#   • a wasm line with no identical counterpart in llvm.  Lines carry
#     "<fn> <mode>", so this catches BOTH a function wasm TMC'd that llvm did
#     not (impossible via pruning — pruning only ever removes) AND a shared
#     function whose MODE diverges (trmc vs group-root vs group:<root>), which
#     is the eligibility divergence WASM-TMC-GAP-DESIGN.md's "parity by
#     construction" claim is about.
# And the `-- EXPECT-TMC:` pins (check_pins, above) are untouched by any of
# this: a pinned fn missing from EITHER shipping set is still a PINFAIL, so a
# subset can never be licensed all the way down to vacuous.
{
  echo "TMC census — $(ls "$OUT" | grep -c '\.llvm\.tmc$') corpus items — outdir $OUT"
  for l in "$OUT"/*.llvm.tmc; do
    name="$(basename "$l" .llvm.tmc)"; w="$OUT/$name.wasm.tmc"
    nl="$(wc -l < "$l")"; nw="$(wc -l < "$w")"
    # wasm-only lines: present in the wasm set, absent from the llvm set.
    # Both files are `sort -u` output, so comm's precondition holds.
    wasm_only="$(comm -13 "$l" "$w")"
    if cmp -s "$l" "$w"; then echo "same $name (llvm=$nl wasm=$nw)"
    elif is_shipping_item "$name" && [ -z "$wasm_only" ]; then
      echo "SUBSET $name (llvm=$nl wasm=$nw) — wasm set is a subset of llvm's: reachability-pruned, not a divergence"
      comm -23 "$l" "$w" | sed 's/^/    llvm-only (pruned from wasm): /'
    else
      echo "DIFF $name (llvm=$nl wasm=$nw)"
      if is_shipping_item "$name"; then
        echo "    GENUINE BACKEND DIVERGENCE (shipping arm) — wasm TMC'd a function llvm did not,"
        echo "    or TMC'd a shared function at a different mode.  Reachability pruning can only"
        echo "    REMOVE from wasm's set, so this is not a prune artifact.  wasm-only lines:"
        printf '%s\n' "$wasm_only" | sed 's/^/      /'
      else
        echo "    PROBE arm — exact parity required here (wasmReachFilter never runs on this arm)."
      fi
      diff "$l" "$w" | sed 's/^/    /'
    fi
  done
  [ -f "$OUT/PINFAILS" ] && cat "$OUT/PINFAILS"
} | tee "$OUT/SUMMARY"

exit $fail
