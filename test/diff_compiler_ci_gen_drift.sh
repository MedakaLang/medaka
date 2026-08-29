#!/bin/sh
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
# ⚠️ This gate is ADVISORY-tier. The same `--check` call also runs inside the
# REQUIRED test/diff_compiler_ci_shard_coverage.sh, so the required tier does
# not depend on this gate for the drift half.
#
# Usage:  sh test/diff_compiler_ci_gen_drift.sh
# Exit:   0 ci.yml's generated region already matches what test/gates.toml
#         generates; 1 it drifted (the message names the first differing line
#         and the fix); 2 no native medaka binary to run it with.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

if ! MEDAKA_ROOT="$ROOT" LC_ALL=C "$MEDAKA" gate ci --check; then
  echo "::error::medaka gate ci --check failed (its message above says whether .github/workflows/ci.yml's generated gates-matrix region drifted, or test/gates.toml itself is bad). If it drifted, run 'make gen-ci' and commit the result."
  exit 1
fi
