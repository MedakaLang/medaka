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
# generates, from going unnoticed — this gate closes that gap the same way
# `ci.yml`'s "Docs index must be regenerated, not hand-edited" step closes it
# for `docs/README.md`: regenerate, then diff.
#
# `medaka gate ci` is IN-BINARY (it reads test/gates.toml and rewrites
# .github/workflows/ci.yml), so this gate is NOT binary-free — same accepted
# gap as diff_compiler_gate_registry.sh. It rewrites ci.yml IN PLACE when
# regeneration differs from what's on disk; that is the same behavior
# `make gen-ci` already has, and is what lets `git diff --exit-code` below
# show the drift.
#
# Usage:  sh test/diff_compiler_ci_gen_drift.sh
# Exit:   0 ci.yml already matches what test/gates.toml generates; 1 it
#         drifted (message names the fix); 2 no native medaka binary to run
#         it with.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

if ! MEDAKA_ROOT="$ROOT" LC_ALL=C "$MEDAKA" gate ci; then
  echo "::error::medaka gate ci failed (see its message above) — fix test/gates.toml and re-run 'make gen-ci'."
  exit 1
fi
if ! git -C "$ROOT" diff --exit-code -- .github/workflows/ci.yml; then
  echo "::error::.github/workflows/ci.yml's generated gates-matrix region is stale or was hand-edited. Run 'make gen-ci' and commit the result."
  exit 1
fi
