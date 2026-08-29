#!/bin/sh
# diff_compiler_gate_balance.sh — the shard balancer's own gate (#2178,
# S-3-S-balancer, epic #2182).
#
# `medaka gate balance` CHOOSES every schedulable gate's ci.yml matrix row from
# the registry's constraints plus the measured cost baseline, and rewrites the
# `shard = "…"` lines of test/gates.toml in place. This gate grades the four
# properties that make that safe to run unattended. Every one of them fails
# SILENTLY if it regresses — a wrong packing still produces a well-formed
# registry, a green build, and eight green `gates (<row>)` checks.
#
#   1. IDEMPOTENCE. Running the balancer twice on an unchanged baseline is a
#      no-op the second time. Without it, every `make` that touched the
#      registry would reshuffle 200 gates and every downstream required check
#      would churn for nothing. Proved by running it twice on a scratch copy
#      and diffing, not by reading the "DECLINED" line it prints about itself.
#
#   2. THE HYSTERESIS BAND NEVER PRESERVES AN ILLEGAL ASSIGNMENT. A gate needing
#      wasm-tools/node may only land on a row with `wasm_arm = true`. The
#      `wasm_only_row` fixture puts such a gate on a row without it, where the
#      legal move costs 10ms out of 310 — well inside the 5% band. The first
#      draft of the balancer damped that repair and exited 0, leaving the gate
#      scheduled where its toolchain is absent. Cost is what a margin may weigh;
#      legality is not a cost.
#
#   3. A GATE WITH NO MEASURED COST IS A REFUSAL, NOT A ZERO. The baseline is
#      keyed by run_gates.sh's own gate label (script path, `/`->`_`, leading
#      `test_` dropped), NOT by the registry's `name`. The two agree on every
#      gate under test/ and disagree on all 53 that live elsewhere, so a join on
#      `name` looks perfect on three quarters of the registry while costing the
#      rest at zero — and a zero-cost gate is piled onto whichever row is
#      lightest. The `uncosted_gate` fixture pins the refusal.
#
#   4. THE TARGET IS ENFORCED, AND ITS REFUSAL NAMES THE RIGHT CAUSE. Gates are
#      indivisible, so the pole can never fall below the single most expensive
#      gate. When that alone blows the pole/median target the message must say
#      so — pointing a reader at "repack harder" when the answer is "this gate
#      must get faster" costs them the whole investigation.
#
# Plus: the committed test/gates.toml IS the balancer's own output
# (`--check`), so a hand-edited `shard` field cannot ride in unnoticed.
#
# ⚠️ The fixtures under test/gate_balance_fixtures/ are SYNTHETIC and
# hand-written — never the real baseline. Degenerate cases are the point (one
# gate dominating a row, a constraint set admitting exactly one candidate row),
# and the real numbers move every time the baseline is re-ingested.
#
# Every mutating run below goes against a COPY under `mktemp -d`. This gate
# never writes to the tree.
#
# Usage:  sh test/diff_compiler_gate_balance.sh
# Exit:   0 all checks pass, 1 a check failed.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
FIX="$ROOT/test/gate_balance_fixtures"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

echo "── gate shard balancer (#2178) ─────────────────────────────────────────"

if [ ! -x "$MEDAKA" ]; then
  echo "  SKIP  no medaka binary at $MEDAKA (build with 'make medaka')"
  exit 0
fi

# Run the balancer against a fixture pair. $1 = fixture stem, $2 = output file,
# rest = extra flags. The registry argument is always the SCRATCH copy.
_bal() {
  _stem="$1"; _out="$2"; shift 2
  MEDAKA_ROOT="$ROOT" "$MEDAKA" gate balance \
    --registry "$TMP/$_stem.toml" \
    --baseline "$FIX/$_stem.json" \
    "$@" >"$_out" 2>&1
}

for stem in wasm_only_row dominating_gate uncosted_gate; do
  cp "$FIX/$stem.toml" "$TMP/$stem.toml"
done

# ── 1. `--check` is NON-MUTATING ──────────────────────────────────────────────
#
# Mirrors `medaka gate ci --check`: it recomputes the assignment in memory and
# compares, rather than writing and then diffing — which would HEAL an
# uncommitted hand-edit before the check could see it, and report green having
# destroyed the very edit it existed to catch.
#
# ⚠️ NOT "the committed registry equals the balancer's output". It does not, on
# purpose: test/gates.toml still carries S-1's HAND assignment, because the
# derived assignment and the ci.yml matrix generated FROM it have to land in
# one commit (test/diff_compiler_ci_shard_coverage.sh compares the two), and
# ci.yml belongs to the next slice. That equality is S-4's check to add, once
# it can regenerate the matrix in the same breath. What is asserted here is the
# part that is S-3's: `--check` reads, reports and writes nothing.
out="$TMP/real.txt"
cp "$ROOT/test/gates.toml" "$TMP/real_before.toml"
MEDAKA_ROOT="$ROOT" "$MEDAKA" gate balance --check >"$out" 2>&1
if cmp -s "$TMP/real_before.toml" "$ROOT/test/gates.toml"; then
  ok "--check left test/gates.toml byte-identical"
else
  bad "--check WROTE to test/gates.toml"
fi

# The projection is the number a reader acts on; assert it is present and that
# the enforced target is stated, not merely computed.
if grep -q 'pole/median' "$out" && grep -q 'target pole/median' "$out"; then
  ok "--check prints the projected pole, median and enforced target"
else
  bad "--check did not print its projection"
  sed -e 's/^/        /' "$out"
fi

# ── 2. idempotence, proved by diff and not by the tool's own verdict ──────────
cp "$ROOT/test/gates.toml" "$TMP/real1.toml"
_bal_real() {
  MEDAKA_ROOT="$ROOT" "$MEDAKA" gate balance --registry "$TMP/real1.toml" \
    --baseline "$ROOT/test/gate_cost_baseline.json" >"$1" 2>&1
}
if _bal_real "$TMP/r1.txt"; then
  cp "$TMP/real1.toml" "$TMP/real2.toml"
  if _bal_real "$TMP/r2.txt" && cmp -s "$TMP/real1.toml" "$TMP/real2.toml"; then
    ok "re-running on an unchanged baseline is a byte-identical no-op"
  else
    bad "the second run changed the registry — hysteresis is not holding"
    diff "$TMP/real2.toml" "$TMP/real1.toml" | sed -e 's/^/        /' | head -20
  fi
else
  bad "the balancer failed on the real registry"
  sed -e 's/^/        /' "$TMP/r1.txt"
fi

# ── 3. a wasm gate reaches its one legal row, band or no band ─────────────────
#
# `gw` is authored on row `a` (wasm_arm = false); `w` is the only open row with
# the toolchain. The move is worth 10ms of a 310ms pole — inside the 5% band —
# so this fails if legality is ever weighed as if it were cost.
if _bal wasm_only_row "$TMP/w.txt"; then
  got="$(awk '/^name = "gw"$/{f=1} f && /^shard = /{print; exit}' "$TMP/wasm_only_row.toml")"
  if [ "$got" = 'shard = "w"' ]; then
    ok "a wasm-constrained gate lands on the only row with wasm_arm = true"
  else
    bad "wasm-constrained gate landed on the wrong row: $got"
  fi
  if grep -q 'OVERRIDDEN (illegal assignment)' "$TMP/w.txt"; then
    ok "the hysteresis band reports being overridden for a legality repair"
  else
    bad "the band was not overridden — an illegal assignment can survive it"
    sed -e 's/^/        /' "$TMP/w.txt"
  fi
else
  bad "the balancer failed on the wasm_only_row fixture"
  sed -e 's/^/        /' "$TMP/w.txt"
fi

# Same fixture, run again: the repair must settle rather than oscillate.
cp "$TMP/wasm_only_row.toml" "$TMP/wasm_prev.toml"
if _bal wasm_only_row "$TMP/w2.txt" && cmp -s "$TMP/wasm_prev.toml" "$TMP/wasm_only_row.toml"; then
  ok "the repaired fixture is a fixed point"
else
  bad "the repaired fixture moved again on a second run"
fi

# ── 4. one dominating gate: refuse, and blame the gate, not the packing ───────
if _bal dominating_gate "$TMP/d.txt"; then
  bad "a packing with pole/median 6.6 was accepted"
  sed -e 's/^/        /' "$TMP/d.txt"
else
  if grep -q 'no packing can meet the pole/median target' "$TMP/d.txt" \
     && grep -q "'monolith' alone costs" "$TMP/d.txt"; then
    ok "a dominating gate is refused, and the message names that gate"
  else
    bad "refused, but not with the indivisible-gate explanation"
    sed -e 's/^/        /' "$TMP/d.txt"
  fi
  if cmp -s "$FIX/dominating_gate.toml" "$TMP/dominating_gate.toml"; then
    ok "the refused run wrote nothing"
  else
    bad "the refused run rewrote the registry anyway"
  fi
fi

# ── 5. an uncosted schedulable gate is a refusal, never a free gate ───────────
if _bal uncosted_gate "$TMP/u.txt"; then
  bad "a gate with no measured cost was packed anyway"
  sed -e 's/^/        /' "$TMP/u.txt"
else
  if grep -q 'no row in the cost baseline' "$TMP/u.txt" && grep -q 'orphan' "$TMP/u.txt"; then
    ok "an uncosted gate is refused, and the message names it"
  else
    bad "refused, but not for the missing-cost reason"
    sed -e 's/^/        /' "$TMP/u.txt"
  fi
fi

if [ "$fail" -eq 0 ]; then
  echo "-- gate shard balancer: all checks passed"
  exit 0
fi
echo "-- gate shard balancer: $fail check(s) failed"
exit 1
