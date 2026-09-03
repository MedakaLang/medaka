#!/bin/sh
# shell-because: trust-anchor — circular: checks the machinery a native gate would run inside
# diff_compiler_ci_gen_drift.sh — the generated gates-matrix region's own
# drift gate (#2177, S-3).
#
# `.github/workflows/ci.yml`'s `gates` job matrix (the `full_cores`/`wasm_arm`
# rows) is a GENERATED region, marked out by the exact whole-line markers
# `GENERATED:BEGIN gates-matrix` / `GENERATED:END gates-matrix` and produced
# from `test/gates.toml` by `medaka gate ci` (`make gen-ci`,
# `compiler/tools/gate_cmd.mdk`). Nothing stops a hand-edit inside those
# markers, or a registry entry drifting out of sync with the workflow it
# generates, from going unnoticed — this gate closes that gap.
#
# ── WHY IT DOES NOT REGENERATE-THEN-DIFF (F-1) ───────────────────────────────
#
# It used to: run `medaka gate ci` in WRITE mode, then `git diff --exit-code`
# on the whole file, the way `ci.yml`'s "Docs index must be regenerated, not
# hand-edited" step does for `docs/README.md`. That shape has two defects,
# one root cause:
#
#   * it HEALS what it is checking. An uncommitted hand-edit inside the region
#     is overwritten by the write step BEFORE the diff runs, so the gate
#     reports PASS having silently destroyed the edit;
#   * it MISATTRIBUTES. `git diff --exit-code` on the whole file fires on any
#     uncommitted change to ci.yml, including one entirely outside the
#     generated region, and then blames "the generated gates-matrix region".
#
# `medaka gate ci --check` does the same comparison in memory and writes
# nothing. It is also correctly SCOPED: `ciNewText` copies every line before
# the BEGIN marker and every line from the END marker onward verbatim, so an
# edit outside the region appears identically on both sides of the compare and
# can never make the check fire.
#
# `medaka gate ci` is IN-BINARY (it reads test/gates.toml and
# .github/workflows/ci.yml), so this gate is NOT binary-free — same accepted
# gap as diff_compiler_gate_registry.sh.
#
# ⚠️ THIS GATE IS REQUIRED-TIER: the `ci-gen-drift` job that runs it is one of
# the repo ruleset's required status-check contexts (derive it, never trust a
# list — AGENTS.md [W-REQUIRED-CHECKS]). An earlier revision of this comment
# called it advisory; it was wrong, and check 2 below is placed here BECAUSE
# the tier is required.
#
# ── CHECK 2 (S-4, #2178): `shard` IS DERIVED, AND HAND EDITS MUST RED ────────
#
# Check 1 above proves ci.yml's matrix agrees with the `shard` values in
# test/gates.toml. That is satisfied by a SELF-CONSISTENT HAND EDIT: change a
# gate's `shard`, run `make gen-ci` so the matrix follows, and check 1 is
# happy — the registry and the workflow agree with each other about a row
# nothing derived.
#
# Check 2 closes it by asserting the other half: that the `shard` values are
# themselves what `medaka gate balance` derives from test/gate_cost_baseline.json.
# Together the two say ci.yml == f(registry) AND registry == g(baseline), which
# is the whole claim of #2178 — `shard` is a generated output, not hand-edited
# data.
#
# `medaka gate balance --check` writes nothing, for the same reason check 1
# does not regenerate-then-diff: a mutating run would HEAL the hand edit before
# anything could see it.
#
# Usage:  sh test/diff_compiler_ci_gen_drift.sh
# Exit:   0 ci.yml's generated region matches what test/gates.toml generates
#         AND the committed shard assignment is the derived one; 1 either
#         drifted (the message names the offending gate/line and the fix);
#         2 no native medaka binary to run it with.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

fail=0

if ! MEDAKA_ROOT="$ROOT" LC_ALL=C "$MEDAKA" gate ci --check; then
  echo "::error::medaka gate ci --check failed (its message above says whether .github/workflows/ci.yml's generated gates-matrix region drifted, or test/gates.toml itself is bad). If it drifted, run 'make gen-ci' and commit the result."
  fail=1
fi

if ! MEDAKA_ROOT="$ROOT" LC_ALL=C "$MEDAKA" gate balance --check; then
  echo "::error::medaka gate balance --check failed: test/gates.toml's shard assignment is not the one derived from test/gate_cost_baseline.json. \`shard\` is DERIVED DATA (#2178), not a field to edit by hand — run 'medaka gate balance' then 'make gen-ci' and commit both. (If the message above is a refusal rather than a divergence — an uncosted gate, or a dominating one — fix that first; it is not a drift.)"
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
