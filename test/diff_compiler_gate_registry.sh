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
#   5. every entry's `corpus` value is a real DIRECTORY (S-5).
#   6. every entry `name` is UNIQUE (#2199) — with `shard` on the entry, two
#      twins make "which matrix row does `foo` go in" ambiguous.
#   7. every `name` — a gate's and a `[[shard]]` row's — is inside a
#      conservative charset (#2204, S-4). A name is interpolated into ci.yml
#      as YAML and then re-read as an UNQUOTED SHELL WORD, so a quote, a `$`,
#      a `;` or a space in one does not make a bad name, it makes a different
#      workflow or a different command, silently. Nothing else looks at a
#      name's spelling — check 4 proves a name is SELECTABLE, and a name full
#      of metacharacters selects perfectly well.
#
# TEXT-ONLY, NO BUILD beyond `./medaka` itself already existing — this does not
# invoke clang, an oracle probe, or any other compiler. `verify` shells out to
# `git ls-files` (twice, mirroring test/preflight.sh exactly) and to
# `test/build_oracles.sh --list` (which itself builds nothing).
#
# A fixture-driven self-test of the violation classes was considered and
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
