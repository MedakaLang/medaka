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
#   8. every entry's `cost` is one of `cheap`/`medium`/`heavy` (FR-5, review
#      finding S2-3) — an unrecognized string used to fall through
#      `timeoutFor`'s `otherwise = 900` fallback silently.
#
# TEXT-ONLY, NO BUILD beyond `./medaka` itself already existing — this does not
# invoke clang, an oracle probe, or any other compiler. `verify` shells out to
# `git ls-files` (twice, mirroring test/preflight.sh exactly) and to
# `test/build_oracles.sh --list` (which itself builds nothing).
#
# A fixture-driven self-test of checks 1-7 was considered and rejected in
# favor of a one-off manual demonstration recorded in this slice's report
# (`/var/tmp/medaka-sprints/gate-registry/reports/S-4-gate-verify.md`): each
# class was reproduced by hand against a temp-copied, mutated registry and
# confirmed to red with the right violation named, then the tree was
# restored. Baking that into the gate would mean shipping a SECOND copy of
# "how to construct a violating registry" that has to stay in sync with the
# schema `gate_cmd.mdk` reads — the shipped gate instead simply runs `verify`
# on the real tree, which is what CI actually needs protected.
#
# Check 8 is the one exception, deliberately: unlike 1-7 (which only re-check
# invariants the real committed tree already satisfies), an unvalidated
# `cost` string used to fall through SILENTLY — no gate anywhere pinned that
# a typo like `cost = "banana"` gets caught — so this is a real NEW behavior
# that needs its own red/green regression, not a restatement of something the
# real tree already proves. `test/gate_registry_fixtures/{invalid_cost,
# valid_cost}.toml` isolate exactly the `cost` field. Run against a THROWAWAY
# `MEDAKA_ROOT` (a freshly `git init`'d dir holding only the fixture's own
# `run` target) rather than the real repo root — pointing `--registry` at a
# 1-entry fixture while `MEDAKA_ROOT` stays the real tree would flood check 1
# (unenrolled gate scripts, which scans the WHOLE real tree via `git
# ls-files`) with hundreds of irrelevant violations, which is exactly the
# practical problem the "no fixture corpus for checks 1-7" decision above was
# avoiding.
#
# Usage:  sh test/diff_compiler_gate_registry.sh
# Exit:   0 medaka gate verify reports zero violations; 1 it reds; 2 no native
#         medaka binary to run it with.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

MEDAKA_ROOT="$ROOT" "$MEDAKA" gate verify
verify_rc=$?

# ── check 8's own regression: invalid_cost.toml must red, valid_cost.toml
#    must stay green, against a throwaway root ────────────────────────────
FIXTMP="$(mktemp -d)"
trap 'rm -rf "$FIXTMP"' EXIT

mkdir -p "$FIXTMP/test/gate_shards"
printf '#!/bin/sh\ntrue\n' >"$FIXTMP/test/tidy.sh"
chmod +x "$FIXTMP/test/tidy.sh"
printf 'a\n' >"$FIXTMP/test/gate_shards/a.txt"
( cd "$FIXTMP" && git init -q && git add -A && git -c user.name=test -c user.email=test@example.invalid commit -q -m init ) || {
  echo "diff_compiler_gate_registry: could not init the throwaway fixture root"
  exit 2
}

if MEDAKA_ROOT="$FIXTMP" "$MEDAKA" gate verify \
    --registry "$ROOT/test/gate_registry_fixtures/invalid_cost.toml" \
    >"$FIXTMP/invalid.out" 2>&1; then
  echo "diff_compiler_gate_registry: FAIL — invalid_cost.toml did not red:"
  cat "$FIXTMP/invalid.out"
  verify_rc=1
elif ! grep -q "cost 'banana' is not one of cheap/medium/heavy" "$FIXTMP/invalid.out"; then
  echo "diff_compiler_gate_registry: FAIL — invalid_cost.toml reds for the wrong reason:"
  cat "$FIXTMP/invalid.out"
  verify_rc=1
else
  echo "OK    check 8 regression: invalid_cost.toml reds with the cost-class message"
fi

if MEDAKA_ROOT="$FIXTMP" "$MEDAKA" gate verify \
    --registry "$ROOT/test/gate_registry_fixtures/valid_cost.toml" \
    >"$FIXTMP/valid.out" 2>&1; then
  echo "OK    check 8 regression: valid_cost.toml stays green"
else
  echo "diff_compiler_gate_registry: FAIL — valid_cost.toml (cost = \"cheap\") reds:"
  cat "$FIXTMP/valid.out"
  verify_rc=1
fi

# ── check 9's own regression (#2181): invalid_tiers.toml must red, and
#    valid_cost.toml is its control too — the two fixtures differ in exactly
#    one line, so a green control proves the red is about `tiers` and nothing
#    else. ─────────────────────────────────────────────────────────────────
if MEDAKA_ROOT="$FIXTMP" "$MEDAKA" gate verify \
    --registry "$ROOT/test/gate_registry_fixtures/invalid_tiers.toml" \
    >"$FIXTMP/invalid_tiers.out" 2>&1; then
  echo "diff_compiler_gate_registry: FAIL — invalid_tiers.toml did not red:"
  cat "$FIXTMP/invalid_tiers.out"
  verify_rc=1
elif ! grep -q "mixes 'ondemand' with a real run" "$FIXTMP/invalid_tiers.out"; then
  echo "diff_compiler_gate_registry: FAIL — invalid_tiers.toml reds for the wrong reason:"
  cat "$FIXTMP/invalid_tiers.out"
  verify_rc=1
else
  echo "OK    check 9 regression: invalid_tiers.toml reds with the tiers message"
fi

exit "$verify_rc"
