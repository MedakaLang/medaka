#!/bin/sh
# diff_compiler_gate_balance.sh — the shard balancer's own gate (#2178,
# S-3-S-balancer, epic #2182).
#
# `medaka gate balance` CHOOSES every schedulable gate's ci.yml matrix row from
# the registry's constraints plus the measured cost baseline, and rewrites the
# `shard = "…"` lines of test/gates.toml in place. This gate grades the six
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
#   4. THE BUDGET IS ENFORCED, AND ITS REFUSAL NAMES THE RIGHT CAUSE. Gates are
#      indivisible, so the pole can never fall below the single most expensive
#      gate. When the floor is that gate and the packer still cannot reach it,
#      the message must say so — pointing a reader at "repack harder" when the
#      answer is "this gate must get faster" costs them the whole investigation.
#
#   5. A CLOSED ROW'S MEMBERSHIP IS DECLARED AND CHECKED, NOT OBSERVED (#2205,
#      review finding F3). The packer never moves a gate onto a `full_cores`
#      row or off it, which left that row as the ONE place a `shard` value was
#      still hand-assignable: the balancer seeded it from whatever named it, so
#      a hand edit in either direction was ADOPTED by the next run and reported
#      "already balanced" for ever after. The `pin_intruder` and `pin_deserter`
#      fixtures are those two edits, in registries that are otherwise perfectly
#      healthy — legal, fully costed, pole/floor 1.000, and with the derived
#      open-row assignment equal to the committed one — because that is what
#      made the real injections invisible. `pin_on_open_row` pins the schema's
#      other half: a `pinned_gates` list on a row the packer owns is a
#      declaration the tool would ignore, so it is refused rather than quietly
#      believed.
#
#   6. A ROW IS SCORED BY ITS MAKESPAN, NOT BY THE SUM OF ITS GATES (#2207).
#      CI fans a row's gates out through `run_gates.sh`'s `xargs -P $JOBS` pool,
#      so what CI prints for a row is a makespan over $JOBS workers. The
#      balancer scored a serial SUM until this landed, which over-states every
#      row by a per-row-VARYING factor — a row of one indivisible gate does not
#      shrink under a pool, a row of many small ones nearly halves — so the two
#      models pick different assignments, not merely different numbers. Every
#      other fixture above is scored identically by both, so none of them could
#      catch a regression to the sum; `makespan_vs_sum` is built so they
#      disagree about exactly one gate, and is committed with the SUM's answer
#      so a regression reports "already balanced" and exits 0.
#
#   7. THE INCUMBENT PREFERENCE HOLDS, AND IS BOUNDED (#2218). Scheduled
#      re-ingests made re-derivation routine, and an ordinary +/-2% perturbation
#      of the baseline moved 89-128 of the 202 committed gates. `balPickStable`
#      lets a gate stay where it is committed when its row is legal, open and
#      within `balStabPct` of the lightest legal row. Both halves fail silently
#      and each hides the other: an unbounded preference freezes the matrix
#      against real cost change and still reports a healthy pole, and an absent
#      one just goes back to churning. `stability_preference` carries one gate
#      of each kind, differing only in how heavy their incumbent row had become.
#      This is NOT the hysteresis band #2178 reverted — that one declined to
#      emit the derived value, leaving `--check` nothing to police; this one
#      derives a different value from a wider input, so the fixed-point
#      assertions in 1 and 12 are what keep them distinguishable.
#
#   8. THE ENFORCED STATEMENT IS ABOUT THE PACKING, NOT ABOUT THE SUITE (#2216).
#      `pole / median` moved for reasons the balancer neither caused nor could
#      repair, in BOTH directions: one gate getting 20% slower reds a REQUIRED
#      check with no repair available, and — the perverse half — speeding up
#      every non-pole gate reds it too, because the denominator falls while the
#      pole does not. `pole / floor` divides by the best pole any assignment of
#      this gate set onto these rows could reach, so it is 1.000 exactly when
#      the packing is optimal and moves only when the packing does. Both halves
#      are pinned as fixtures because either alone is satisfiable by a metric
#      that is merely more lenient: `nonpole_speedup` must be GREEN (it was red
#      at 3.333 under the retired metric) and `lpt_packing_gap` must be RED (a
#      real packing failure, at the classic LPT worst case for three rows), and
#      `dominating_gate` holds the seam between them.
#
# Plus: the committed test/gates.toml IS the balancer's own output
# (`--check`), so a hand-edited `shard` field cannot ride in unnoticed.
#
# ⚠️ The fixtures under test/gate_balance_fixtures/ are SYNTHETIC and
# hand-written — never the real baseline. Degenerate cases are the point (one
# gate dominating a row, a constraint set admitting exactly one candidate row),
# and the real numbers move every time the baseline is re-ingested. The three
# `pin_*` fixtures are the exception that proves the rule: they are deliberately
# NON-degenerate, because a closed-row injection is only interesting in a
# registry that is healthy in every other respect.
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
  echo "build native first: make medaka (missing $MEDAKA)"
  exit 2
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

for stem in wasm_only_row dominating_gate uncosted_gate \
            pin_intruder pin_deserter pin_on_open_row makespan_vs_sum \
            thin_evidence calib_staleness outlier_immunity \
            stability_preference nonpole_speedup lpt_packing_gap; do
  cp "$FIX/$stem.toml" "$TMP/$stem.toml"
done

# ── 1. `--check` is NON-MUTATING ──────────────────────────────────────────────
#
# Mirrors `medaka gate ci --check`: it recomputes the assignment in memory and
# compares, rather than writing and then diffing — which would HEAL an
# uncommitted hand-edit before the check could see it, and report green having
# destroyed the very edit it existed to catch.
#
# The committed registry now IS the balancer's output (S-4, #2178): `shard` is
# a derived field, and this run below asserts exactly that — `--check` exits 0
# against the checked-in test/gates.toml and $ROOT/test/gate_cost_baseline.json.
# What this block asserts is narrower than that equality alone, though:
# `--check` reads, reports and writes nothing (S-3's non-mutating property),
# which the byte-identical comparison right below checks independently of
# whether the assignment itself agrees with the baseline.
out="$TMP/real.txt"
cp "$ROOT/test/gates.toml" "$TMP/real_before.toml"
MEDAKA_ROOT="$ROOT" "$MEDAKA" gate balance --check >"$out" 2>&1
check_rc=$?
if cmp -s "$TMP/real_before.toml" "$ROOT/test/gates.toml"; then
  ok "--check left test/gates.toml byte-identical"
else
  bad "--check WROTE to test/gates.toml"
fi

# The committed registry is already balanced, so `--check` must exit 0 here.
# A perturbed baseline whose derived assignment diverges from the committed
# one makes `--check` exit non-zero (F-1's fix, and S-4's own check) — a gate
# that never reads $? would still report every other assertion passing.
if [ "$check_rc" -eq 0 ]; then
  ok "--check exits 0 on the already-balanced committed tree"
else
  bad "--check exited $check_rc on the already-balanced committed tree (expected 0)"
fi

# The projection is the number a reader acts on; assert it is present and that
# the enforced target is stated, not merely computed.
if grep -q 'pole/floor' "$out" && grep -q 'budget pole/floor' "$out" \
   && grep -q '^  floor: the achievable pole — set by ' "$out"; then
  ok "--check prints the projected pole, floor, its provenance and the enforced budget"
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
#
# The refusal must survive the #2216 metric change in RECOGNISABLE form: a
# reader who hits it has to leave knowing the gate must get FASTER (or be
# split), which is the one repair a rebalance cannot make. So this is graded on
# that sentence and on the gate's name, not merely on the exit code.
if _bal dominating_gate "$TMP/d.txt"; then
  bad "a packing with pole/floor 1.200 was accepted"
  sed -e 's/^/        /' "$TMP/d.txt"
else
  if grep -q 'misses the pole/floor budget' "$TMP/d.txt" \
     && grep -q "The floor is 'monolith' alone" "$TMP/d.txt" \
     && grep -q 'has to get FASTER (or be split)' "$TMP/d.txt"; then
    ok "a dominating gate is refused, the message names that gate and says it must get faster"
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

# ── 6. a closed row's membership is an invariant, failing in BOTH directions ──
#
# Graded on the MESSAGE and not merely on the exit code: a refusal that does not
# name the gate and the row sends a reader to `git diff` on a 3500-line
# registry. And graded on the MUTATING form as well as `--check` — the F3
# injections were not dangerous because `--check` missed them, they were
# dangerous because one ordinary `medaka gate balance` run swallowed them into
# the committed pin and every run after that agreed.
_pin_case() {
  _stem="$1"; _needle="$2"; _what="$3"
  if _bal "$_stem" "$TMP/$_stem.txt" --check; then
    bad "$_what was accepted by --check"
    sed -e 's/^/        /' "$TMP/$_stem.txt"
  elif grep -q "$_needle" "$TMP/$_stem.txt"; then
    ok "$_what is refused by --check, and the message names it"
  else
    bad "$_what was refused, but not for the pinned_gates reason"
    sed -e 's/^/        /' "$TMP/$_stem.txt"
  fi
  if _bal "$_stem" "$TMP/$_stem.mut.txt"; then
    bad "$_what was ADOPTED by the mutating form"
  elif cmp -s "$FIX/$_stem.toml" "$TMP/$_stem.toml"; then
    ok "the mutating form refuses it too, and wrote nothing"
  else
    bad "the mutating form refused $_what but rewrote the registry anyway"
  fi
}

_pin_case pin_intruder \
  "'intruder' is committed on this closed row but is not in its pinned_gates" \
  "a gate hand-moved ONTO a closed row"

_pin_case pin_deserter \
  "pinned gate 'pinned1' is committed on row 'a' instead" \
  "the pinned gate hand-moved OFF its closed row"

_pin_case pin_on_open_row \
  "pinned_gates is non-empty" \
  "a pinned_gates list on an OPEN row"

# ── 7. a row is scored by its MAKESPAN, not by the sum of its gates (#2207) ───
#
# CI runs a row's gates through `run_gates.sh`'s `xargs -P $JOBS` pool, so the
# row's wall clock is the makespan over $JOBS workers. Scoring it as a serial
# sum over-states every row, unevenly — a row of one indivisible gate does not
# shrink under a pool and a row of many small ones nearly halves — so the two
# models do not merely differ in scale, they pick DIFFERENT assignments.
#
# Every other fixture here is scored identically by both models, which is why
# none of them can catch a regression to the sum. `makespan_vs_sum` is built so
# they disagree about exactly one gate: at jobs = 2, `small4` belongs on `b`
# under the makespan and on `a` under the sum (the arithmetic is spelled out in
# the fixture's own header). It is committed with the SUM's answer, so a
# balancer that regressed would report "already balanced" and exit 0 — which is
# the silent failure this property exists to make loud.
if _bal makespan_vs_sum "$TMP/m.txt"; then
  got="$(awk '/^name = "small4"$/{f=1} f && /^shard = /{print; exit}' "$TMP/makespan_vs_sum.toml")"
  if [ "$got" = 'shard = "b"' ]; then
    ok "a row is scored by its makespan over the recorded workers, not by the sum"
  else
    bad "small4 landed on the SUM model's row, not the makespan model's: $got"
    sed -e 's/^/        /' "$TMP/m.txt"
  fi
  # The worker count must come from the baseline's recorded `jobs`, never from
  # a literal: a balancer reading a hardcoded 1 would print `jobs*1` here (the
  # borrowed/defaulted marker) while still passing the placement check above on
  # some other fixture's numbers.
  if grep -q 'jobs 2' "$TMP/m.txt" && ! grep -q 'jobs\*' "$TMP/m.txt"; then
    ok "the modelled worker count is the run's recorded jobs, not a fallback"
  else
    bad "the row was not modelled at the recorded jobs = 2"
    sed -e 's/^/        /' "$TMP/m.txt"
  fi
  # The model is reported against something other than itself: the recorded CI
  # wall clock for the same row. A prediction with no calibration line is
  # unfalsifiable by a reader, which is how the sum survived as long as it did.
  if grep -q 'recorded .* predicted .* residual' "$TMP/m.txt"; then
    ok "the report calibrates its prediction against the recorded row wall clock"
  else
    bad "no calibration line: the prediction is reported with nothing to check it against"
    sed -e 's/^/        /' "$TMP/m.txt"
  fi
else
  bad "the balancer failed on the makespan_vs_sum fixture"
  sed -e 's/^/        /' "$TMP/m.txt"
fi

# ── 8. thin evidence is a stated COUNT, not a flag (#2207) ────────────────────
#
# "A gate balanced off a single sample is a fact the tool states, not one a
# reader has to go find." Every other fixture here happens to have every gate
# at `samples = 1`, so a report line that always says "N of N" would pass all
# of them without proving anything is actually being counted. `thin_evidence`
# is deliberately mixed: two gates at `samples = 1` and two above the
# threshold, in ordinary (non-`--check`) output, which is where this must be
# visible — not buried behind a flag.
if _bal thin_evidence "$TMP/t.txt"; then
  if grep -q '2 of 4 gates are scheduled off a single sample' "$TMP/t.txt"; then
    ok "thin-evidence count is a real count, not every-gate-or-none"
  else
    bad "thin-evidence line missing or wrong count"
    sed -e 's/^/        /' "$TMP/t.txt"
  fi
else
  bad "the balancer failed on the thin_evidence fixture"
  sed -e 's/^/        /' "$TMP/t.txt"
fi

# ── 9. calibration lines carry a staleness signal, and only when it's true ────
#
# S2-1 (#2178 review): a residual is only comparable to the committed
# assignment while the recorded run and that assignment describe the SAME
# gate set (see `balCalibLine`'s own caveat). `calib_staleness` pins row `a`
# recorded with fewer gates than are committed to it now, and row `b`
# recorded with the same count it has now — so the annotation must fire on
# `a` and must NOT fire on `b`, proving the count is a real comparison.
if _bal calib_staleness "$TMP/s.txt"; then
  if grep -q '^    a  *recorded.*\[STALE: 2 gates now, 1 when recorded\]$' "$TMP/s.txt"; then
    ok "a row whose recorded gate count differs from committed is annotated STALE"
  else
    bad "row 'a' calibration line missing the staleness annotation"
    sed -e 's/^/        /' "$TMP/s.txt"
  fi
  if grep -q '^    b  *recorded' "$TMP/s.txt" && ! grep -q '^    b  *recorded.*\[STALE' "$TMP/s.txt"; then
    ok "a row whose recorded gate count matches committed is NOT annotated"
  else
    bad "row 'b' calibration line was annotated STALE when it should not be"
    sed -e 's/^/        /' "$TMP/s.txt"
  fi

  # ── 9b. ...and a COUNT is not a SET (S-2, #2223) ───────────────────────────
  #
  # The commonest rebalance is a SWAP, and a swap does not move a count — so
  # rows `c` and `d` are BOTH recorded at exactly the count they carry now and
  # the check above cannot tell them apart. Only the recorded `gatesDigest`
  # separates them: `c` had its one gate swapped out for another, `d` still has
  # the gate it was recorded with. The observed bug was a -96% residual
  # printing entirely clean, which reads as "the model is calibrated" when it
  # means "the model is being graded against a gate set that no longer exists".
  #
  # Row `d` is also the mirror check on the digest itself: it is unannotated
  # only if `gate_cost.gateSetDigest` and `_digest` in test/gate_cost_ingest.sh
  # (which produced the recorded number) agree exactly. A drift between those
  # two turns every calibration line permanently STALE in production.
  if grep -q '^    c  *recorded.*\[STALE: the same 1 gates by COUNT but a DIFFERENT SET' "$TMP/s.txt"; then
    ok "a row whose recorded gate SET differs at EQUAL count is annotated STALE"
  else
    bad "row 'c' calibration line missing the same-count-different-set annotation"
    sed -e 's/^/        /' "$TMP/s.txt"
  fi
  if grep -q '^    d  *recorded' "$TMP/s.txt" && ! grep -q '^    d  *recorded.*\[STALE' "$TMP/s.txt"; then
    ok "a row whose recorded gate set matches committed is NOT annotated"
  else
    bad "row 'd' was annotated STALE — the set digest always fires, or the awk and Medaka digests have drifted"
    sed -e 's/^/        /' "$TMP/s.txt"
  fi
else
  bad "the balancer failed on the calib_staleness fixture"
  sed -e 's/^/        /' "$TMP/s.txt"
fi

# ── 10. the PACKING STATISTIC is the median, and that is load-bearing ─────────
#
# Retained on a measurement, not by default (S-2, #2222): four candidate
# families were compared leave-one-run-out and the median lost on central
# tendency (it is low by a measured -12.6%) and won on the tail, which is the
# axis a packer schedules on. `outlier_immunity` is that trade as a fixture.
#
# `wild` carries one hiccup sample 90x its own median — the shape
# `pds_test_repo_vectors` carries for real in the committed baseline at 50.7x.
# The median prices it at 10 and every unbiased alternative near 306, and the
# two disagree about the ASSIGNMENT: under the median `wild` shares a row with
# `heavy`, and under any statistic one hiccup can move it takes a row alone.
# The assertion is that sharing, which is tie-break-independent.
#
# The second arm is the red half, and it is why this is a divergence pin rather
# than a bare value: the SAME registry against a baseline whose `wild` is
# priced at the mean must MOVE a gate. Without it, a fixture that merely
# passes proves nothing about which statistic produced it.
if _bal outlier_immunity "$TMP/o.txt"; then
  got="$(awk '/^name = "wild"$/{f=1} f && /^shard = /{print; exit}' "$TMP/outlier_immunity.toml")"
  heavy="$(awk '/^name = "heavy"$/{f=1} f && /^shard = /{print; exit}' "$TMP/outlier_immunity.toml")"
  if [ -n "$got" ] && [ "$got" = "$heavy" ]; then
    ok "one hiccup sample does not move a gate's placement ('wild' shares $got with 'heavy')"
  else
    bad "'wild' was placed apart from 'heavy' (wild: $got, heavy: $heavy) — the packing statistic is letting an outlier through"
    sed -e 's/^/        /' "$TMP/o.txt"
  fi

  # Same registry, `wild` re-priced at the MEAN of its own samples (306): the
  # assignment must now change, proving the fixture above discriminates.
  sed 's/"name": "wild", "medianMs": 10/"name": "wild", "medianMs": 306/' \
    "$FIX/outlier_immunity.json" >"$TMP/outlier_mean.json"
  cp "$FIX/outlier_immunity.toml" "$TMP/outlier_mean.toml"
  MEDAKA_ROOT="$ROOT" "$MEDAKA" gate balance \
    --registry "$TMP/outlier_mean.toml" \
    --baseline "$TMP/outlier_mean.json" --check >"$TMP/om.txt" 2>&1
  if grep -q '^  rebalanced' "$TMP/om.txt"; then
    ok "pricing that gate at the mean instead moves it — the fixture discriminates"
  else
    bad "the mean-priced arm did not rebalance; outlier_immunity is not pinning a divergence"
    sed -e 's/^/        /' "$TMP/om.txt"
  fi
else
  bad "the balancer failed on the outlier_immunity fixture"
  sed -e 's/^/        /' "$TMP/o.txt"
fi

# ── 11. the out-of-sample error is STATED, in ordinary output ─────────────────
#
# Before S-2 the balancer scheduled on `medianMs` with no stated error: every
# number in its report was a point estimate presented as exact. The figure is
# derived on every run precisely so it cannot rot the way the two prose claims
# about the baseline's sample state did, both of which were stale within two
# ingests. Asserted against the REAL baseline, not a fixture, because the
# claim is about the committed data; and asserted as a SHAPE (a signed
# percentage), never a pinned number, since a re-ingest legitimately moves it.
#
# ⚠️ THE ASSERTION IS A DISJUNCTION SINCE FR-1 (#2222 review S0-1), and the
# disjunction is the point rather than a weakening. The figure is derivable
# only from samples that carry a recorded runId, and `sampleRuns` was added by
# FR-1: every sample in the committed baseline predates it, so on today's tree
# the honest output is the explicit "not derivable" line, and it becomes a
# number again once enough attributed ingests have landed. What must NEVER
# appear is a third thing — a number inferred from a sample's POSITION in
# `ms`, which is what the block printed before FR-1 and what the oos_misaligned
# fixture below pins. So: a well-formed number OR a stated refusal, and the
# refusal has to carry its own attribution counts rather than being a bare
# absence a reader would have to guess at.
if grep -q '^  out-of-sample error of the packing statistic (leave-one-run-out over the [0-9]* runs' "$out"; then
  if grep -q '^    mean |error| [0-9]*\.[0-9]%   systematic bias [-+][0-9]*\.[0-9]%' "$out"; then
    ok "the balancer states its out-of-sample error, with a magnitude and a signed bias"
  else
    bad "the out-of-sample summary line is missing its mean |error| / systematic bias"
    grep -n 'out-of-sample' -A 5 "$out" | sed -e 's/^/        /'
  fi
elif grep -q '^  out-of-sample error of the packing statistic: not derivable — [0-9]* of [0-9]* retained samples carry run attribution' "$out"; then
  ok "the balancer refuses the out-of-sample figure explicitly, with its attribution counts"
else
  bad "the balancer neither derived nor explicitly refused its out-of-sample error"
  sed -e 's/^/        /' "$out"
fi

# ── 11b. the fold is RUN-ATTRIBUTED, not positional (FR-1, #2222 review S0-1) ─
#
# The three fixtures share one `ms` shape — g1/m1/l1 = [100, 200, 300] and
# g2/m2/l2 = [10, 20, 30] over three recorded runs — because the block the
# review found computed from `ms` and the run COUNT alone. It therefore printed
# the SAME mean |error| 72.2% / bias -33.3% for all three, and only one of them
# is a file that figure is true of. That coincidence is what makes the trio a
# discriminator rather than three separate smoke tests: any reader that falls
# back to position reproduces 72.2% on the two files where it means nothing.
#
# The expected numbers below are hand-derived from the fixture, not captured
# from the tool ([WT-GOLDEN-ENSHRINES]): predicted 220/110/110 against actual
# 110/220/330 gives per-fold +100.0% / -50.0% / -66.6%, mean |error|
# (1000 + 500 + 666)/3 per-mille = 72.2%, and bias (440 - 660)/660 = -33.3%.
for stem in oos_attributed oos_misaligned oos_legacy; do
  cp "$FIX/$stem.toml" "$TMP/$stem.toml"
done

_bal oos_attributed "$TMP/oosa.txt"
if grep -q '^  out-of-sample error of the packing statistic (leave-one-run-out over the 3 runs in runs\[\], across the 2 of 3 schedulable gates' "$TMP/oosa.txt" \
   && grep -q '^    run 1 .* predicted .*0\.2s .* actual .*0\.1s .*+100\.0%$' "$TMP/oosa.txt" \
   && grep -q '^    run 2 .* predicted .*0\.1s .* actual .*0\.2s .*-50\.0%$' "$TMP/oosa.txt" \
   && grep -q '^    run 3 .* predicted .*0\.1s .* actual .*0\.3s .*-66\.6%$' "$TMP/oosa.txt" \
   && grep -q '^    mean |error| 72\.2%   systematic bias -33\.3%' "$TMP/oosa.txt"; then
  ok "an exactly attributed baseline folds to the hand-derived value, excluding the gate short a run"
else
  bad "the out-of-sample fold on a fully attributed baseline is not the hand-derived value"
  sed -e 's/^/        /' "$TMP/oosa.txt"
fi

# The count coincidence itself: `samples` equals the number of retained runIds
# for both gates, and the alignment is still wrong (runs 1/2/4 against retained
# runs 2/3/4). Attribution EXISTS here — 6 of 6 — so the refusal cannot be
# passing merely because the field is absent, which is the legacy case below.
_bal oos_misaligned "$TMP/oosm.txt"
if grep -q '^  out-of-sample error of the packing statistic: not derivable — 6 of 6 retained samples carry run attribution, and no schedulable gate carries an exactly attributed sample from each of the 3 recorded runs$' "$TMP/oosm.txt"; then
  ok "a count coincidence with the wrong alignment refuses, and says how much attribution it had"
else
  bad "the count-coincidence fixture did not produce an explicit refusal"
  sed -e 's/^/        /' "$TMP/oosm.txt"
fi
if grep -q 'mean |error|' "$TMP/oosm.txt"; then
  bad "the count-coincidence fixture printed an out-of-sample figure — the positional inference is back"
  grep -n 'mean |error|' "$TMP/oosm.txt" | sed -e 's/^/        /'
else
  ok "the count-coincidence fixture printed no figure at all"
fi

# A pre-FR-1 baseline: no `sampleRuns` key anywhere. It must PARSE (the field
# is optional on read), still schedule, and refuse with 0-of-N rather than
# crash or guess.
_bal oos_legacy "$TMP/oosl.txt"
_legacy_rc=$?
if [ "$_legacy_rc" -le 1 ] && grep -q 'pole/floor' "$TMP/oosl.txt"; then
  ok "a baseline with no sampleRuns field parses and still schedules"
else
  bad "a baseline with no sampleRuns field failed to parse or to schedule (rc=$_legacy_rc)"
  sed -e 's/^/        /' "$TMP/oosl.txt"
fi
if grep -q '^  out-of-sample error of the packing statistic: not derivable — 0 of 6 retained samples carry run attribution' "$TMP/oosl.txt"; then
  ok "a legacy baseline reports zero attributed samples rather than a positional guess"
else
  bad "the legacy baseline did not report its out-of-sample error as not derivable at 0 attributed"
  sed -e 's/^/        /' "$TMP/oosl.txt"
fi
# A drift between the ingester's awk `median()` and `gate_cost.packStat` would
# mean the tool scores by a rule the committed file was not written with. The
# balancer counts the rows where they disagree; on a healthy tree it says
# nothing, so the WARNING's ABSENCE is the assertion.
if grep -q 'the ingester and gate_cost.packStat have drifted' "$out"; then
  bad "the committed baseline's medianMs values are not what gate_cost.packStat derives"
  grep -n 'drifted' "$out" | sed -e 's/^/        /'
else
  ok "every committed medianMs is reproduced by gate_cost.packStat"
fi

# The real registry's own closed row, asserted by NAME and not by count: the
# whole point of `engines` is WHICH gates are on it (diff_compiler_engines needs
# a whole runner; the other two ride along for the same wasm toolchain), and a
# check that counted three members would pass a swap.
if grep -q '^pinned_gates = \["pds/test/protocol_all_engines", "pds/test/read_routes_all_engines", "diff_compiler_engines", "diff_compiler_rejection_parity"\]$' "$TMP/real_before.toml"; then
  ok "the real engines row declares its four pinned gates, by name"
else
  bad "test/gates.toml's engines row does not declare the expected four pinned gates"
  grep -n 'pinned_gates' "$TMP/real_before.toml" | sed -e 's/^/        /'
fi

# ── 12. the incumbent preference HOLDS, and is BOUNDED (S-3, #2218) ───────────
#
# `balPickStable` lets a gate stay on its committed row when that row is legal,
# open, and no more than `balStabPct` (5%) heavier than the lightest legal row.
# Both halves of that are load-bearing and each hides the other's failure: a
# preference that always held would freeze the matrix against real cost change,
# and one that never held would leave an ordinary +/-2% re-ingest moving 89-128
# of the 202 committed gates (the measurement in `balStabPct`'s own comment).
#
# `stability_preference` puts one of each in one registry, differing in exactly
# one respect — how heavy their incumbent row had become by the time LPT reached
# them. `held` is placed while row `a` is 2.6% heavier than `b` and stays; `mover`
# is placed once `a` is 7.7% heavier and moves. So this section fails if the
# preference is absent, absolute, or retuned by more than a couple of points.
#
# ⚠️ The mirror case is section 3's, and it must keep passing alongside this one:
# there the incumbent is ILLEGAL and is overridden however cheap the repair.
# Cost is what a preference may weigh; legality is not a cost.
if _bal stability_preference "$TMP/sp.txt"; then
  held="$(awk '/^name = "held"$/{f=1} f && /^shard = /{print; exit}' "$TMP/stability_preference.toml")"
  mover="$(awk '/^name = "mover"$/{f=1} f && /^shard = /{print; exit}' "$TMP/stability_preference.toml")"
  if [ "$held" = 'shard = "a"' ]; then
    ok "a legal incumbent inside the slack is held where bare LPT would move it"
  else
    bad "'held' did not stay on its committed row: $held"
    sed -e 's/^/        /' "$TMP/sp.txt"
  fi
  if [ "$mover" = 'shard = "b"' ]; then
    ok "an incumbent row outside the slack loses the preference and the gate moves"
  else
    bad "'mover' stayed on its committed row — the preference is unbounded: $mover"
    sed -e 's/^/        /' "$TMP/sp.txt"
  fi

  # The trade is stated, not implied. Graded on both numbers: the count of gates
  # actually held (1, not the 2 gates the two packings disagree about — holding
  # `held` is what pushed `mover` off `a`), and the pole the hold cost.
  if grep -q '^  stability: 1 of 4 gates held on their committed row' "$TMP/sp.txt"; then
    ok "the report states how many gates the preference held"
  else
    bad "the stability count is missing or wrong"
    grep -n 'stability' "$TMP/sp.txt" | sed -e 's/^/        /'
  fi
  if grep -q 'pole 210.0s against 208.0s unstabilized (+2.0s)' "$TMP/sp.txt"; then
    ok "the report prices the hold against the bare-LPT pole it gave up"
  else
    bad "the stability line does not state the pole it traded away"
    grep -n 'stability' "$TMP/sp.txt" | sed -e 's/^/        /'
  fi

  # Re-running on the preference's own output must settle. This is the property
  # the REVERTED #2178 band failed differently — it never emitted a single value
  # to settle on — and the one that keeps `--check` policing something.
  cp "$TMP/stability_preference.toml" "$TMP/sp_prev.toml"
  if _bal stability_preference "$TMP/sp2.txt" \
     && cmp -s "$TMP/sp_prev.toml" "$TMP/stability_preference.toml"; then
    ok "the stabilized assignment is a fixed point of itself"
  else
    bad "the stabilized assignment moved again on a second run"
    diff "$TMP/sp_prev.toml" "$TMP/stability_preference.toml" | sed -e 's/^/        /' | head -20
  fi
else
  bad "the balancer failed on the stability_preference fixture"
  sed -e 's/^/        /' "$TMP/sp.txt"
fi

# ── 13. the enforced statement grades the PACKING, not the suite (S-4, #2216) ─
#
# `pole / median` was perverse in both directions, and the perverse half is the
# one no exit code ever caught: the suite gets FASTER and the metric gets WORSE,
# because the denominator is a property of the gate set rather than of the
# packing. `nonpole_speedup` is an OPTIMALLY packed 7-gate suite whose six
# non-pole gates have been sped up 4x; measured against the pre-#2216 binary it
# scores pole/median 3.333 and is REFUSED, with the indivisible-gate message —
# a red on `ci-gen-drift`, a REQUIRED check, with no repair available to anyone.
# Under `pole / floor` the same registry is 1.000 and green.
#
# ⚠️ A metric that were merely MORE LENIENT would pass that half too, so the
# second fixture is the discriminator: `lpt_packing_gap` is a genuine packing
# failure — the classic LPT worst case at three rows, 4/3 - 1/(3m) = 11/9 — and
# must still be REFUSED, at 1.222 against the 1.125 budget, with the message
# that blames the packing rather than a gate. Together they say the metric
# moved axis, not threshold.
if _bal nonpole_speedup "$TMP/ns.txt"; then
  if grep -q 'pole/floor 1.000' "$TMP/ns.txt" \
     && grep -q "set by 'pole_gate' alone" "$TMP/ns.txt"; then
    ok "an optimal packing behind one indivisible gate scores 1.000, however fast the rest gets"
  else
    bad "nonpole_speedup did not score 1.000 against a gate-set floor"
    sed -e 's/^/        /' "$TMP/ns.txt"
  fi
  if grep -q 'budget pole/floor 1.125 — MET' "$TMP/ns.txt"; then
    ok "the suite getting faster no longer misses the budget (it did: pole/median 3.333)"
  else
    bad "nonpole_speedup missed the budget — the metric is still a ratio against the suite"
    sed -e 's/^/        /' "$TMP/ns.txt"
  fi
else
  bad "the balancer refused nonpole_speedup — a correctly packed suite"
  sed -e 's/^/        /' "$TMP/ns.txt"
fi

if _bal lpt_packing_gap "$TMP/lg.txt"; then
  bad "a packing 22% above its own achievable floor was accepted"
  sed -e 's/^/        /' "$TMP/lg.txt"
else
  if grep -q 'misses the pole/floor budget of 1.125 (it is 1.222)' "$TMP/lg.txt" \
     && grep -q 'No single gate explains it' "$TMP/lg.txt"; then
    ok "a real packing failure is still refused, and blamed on the packing"
  else
    bad "lpt_packing_gap was refused, but not with the packing explanation"
    sed -e 's/^/        /' "$TMP/lg.txt"
  fi
  if grep -q '^  floor: the achievable pole — set by .* of open work over 3 open worker slots' "$TMP/lg.txt"; then
    ok "the capacity term is stated in worker SLOTS, not in rows"
  else
    bad "the floor's provenance is missing or is not the capacity term"
    sed -e 's/^/        /' "$TMP/lg.txt"
  fi
fi

if [ "$fail" -eq 0 ]; then
  echo "-- gate shard balancer: all checks passed"
  exit 0
fi
echo "-- gate shard balancer: $fail check(s) failed"
exit 1
