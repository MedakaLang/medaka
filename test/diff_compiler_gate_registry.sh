#!/bin/sh
# diff_compiler_gate_registry.sh — the gate registry's own drift gate (#2176, S-4).
#
# Wraps `medaka gate verify` (compiler/tools/gate_cmd.mdk), which checks:
#
#   1. every gate CANDIDATE (test/preflight.sh's own `_gate_candidates` —
#      tracked-or-untracked `*.sh`, minus every name in
#      test/CI-COVERAGE-TOOLS.txt) is enrolled (some entry's `run` field
#      equals its path) or excluded there. No third state.
#   2. every entry's `run` target exists on disk.
#   3. every entry's non-empty `oracles` names a real `test/build_oracles.sh
#      --list` entry (or the small named wasm-foreign exception — see
#      `gate_cmd.mdk`'s `foreignOracles`).
#   4. every entry is reachable by at least one selector.
#
# TEXT-ONLY, NO BUILD beyond `./medaka` itself already existing — this does not
# invoke clang, an oracle probe, or any other compiler. `verify` shells out to
# `git ls-files` (twice, mirroring test/preflight.sh exactly) and to
# `test/build_oracles.sh --list` (which itself builds nothing).
#
# A fixture-driven self-test of the four violation classes was considered and
# rejected in favor of a one-off manual demonstration recorded in this slice's
# report (`/var/tmp/medaka-sprints/gate-registry/reports/S-4-gate-verify.md`):
# each class was reproduced by hand against a temp-copied, mutated registry
# and confirmed to red with the right violation named, then the tree was
# restored. Baking that into the gate would mean shipping a SECOND copy of
# "how to construct a violating registry" that has to stay in sync with the
# schema `gate_cmd.mdk` reads — the shipped gate instead simply runs `verify`
# on the real tree, which is what CI actually needs protected.
#
# Usage:  sh test/diff_compiler_gate_registry.sh
# Exit:   0 medaka gate verify reports zero violations; 1 it reds; 2 no native
#         medaka binary to run it with.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

MEDAKA_ROOT="$ROOT" "$MEDAKA" gate verify
