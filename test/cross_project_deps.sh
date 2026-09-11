#!/bin/sh
# Cross-project dependency resolution gate (native loader).
#
# A project's medaka.toml may declare a [dependencies] section of the form
#
#     [dependencies]
#     <name> = "<relative-or-abs-path-to-sibling-project-root>"
#
# An import whose FIRST dotted segment equals a declared dep name is resolved by
# stripping that segment and resolving the remainder under the dep's root
# (`minilib.lib.minilib` -> `<minilib-root>/lib/minilib.mdk`).  A dep's OWN
# stdlib imports still resolve via the normal stdlib root.  This is a NATIVE /
# loader-only feature (compiler/driver/loader.mdk); the frozen OCaml oracle is
# untouched, so this is a fresh dedicated gate (no oracle leg).
#
# Fixture (test/cross_project_fixtures/):
#   minilib/        — a single-module dependency project (lib/minilib.mdk, which
#                     itself `import list.{reverse, sort}` from stdlib).
#   consumer/       — declares `minilib = "../minilib"` and
#                     `import minilib.lib.minilib.{revSorted, double}`.
#   consumer/probe_test.mdk
#                   — the same import behind a doctest and a `test "…"` decl, so
#                     both native `medaka test` probe engines are covered too.
#
# Asserts native `medaka check` / `run` / `build`+exec all resolve the
# cross-project import and produce the expected output.  Goldens strip any
# absolute path so they are location-independent.
#
# Usage:  sh test/cross_project_deps.sh
# Exit:   0 if every subtest matches, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIX="$ROOT/test/cross_project_fixtures"
GOLD="$ROOT/test/cross_project_fixtures/goldens"
CONSUMER="$FIX/consumer/main.mdk"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$EMITTER"

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

# Replace the repo root with a stable token so goldens are location-independent.
strip_paths() { sed "s#$ROOT#<ROOT>#g"; }
# Unit-main no longer auto-prints, but keep the safety net (see diff_native_cli.sh).
strip_unit() { sed '${/^0$/d;}'; }

pass=0; fail=0

check_one() {
  name="$1"; got="$2"; goldf="$GOLD/$name.golden"
  if [ ! -f "$goldf" ]; then
    echo "MISSING GOLDEN: $goldf"; fail=$((fail + 1)); return
  fi
  if [ "$got" = "$(cat "$goldf")" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $name"
    echo "  --- expected ---"; cat "$goldf" | sed 's/^/  /'
    echo "  --- got ---";      printf '%s\n' "$got" | sed 's/^/  /'
  fi
}

# ── check ──────────────────────────────────────────────────────────────────
got=$(bound "$MEDAKA" check "$CONSUMER" 2>&1 | strip_paths)
check_one check "$got"

# ── run ────────────────────────────────────────────────────────────────────
got=$(bound "$MEDAKA" run "$CONSUMER" 2>&1 | strip_unit | strip_paths)
check_one run "$got"

# ── build + exec ─────────────────────────────────────────────────────────────
OUT="$(mktemp)"
bound "$MEDAKA" build "$CONSUMER" -o "$OUT" >/dev/null 2>&1
got=$(bound "$OUT" 2>&1 | strip_unit | strip_paths)
rm -f "$OUT"
check_one build "$got"

# ── same source, two packages ────────────────────────────────────────────────
# samesrc/proj/user.mdk and samesrc/depdir/user.mdk are BYTE-IDENTICAL; the
# loader rewrites each one's `import helper` for the package that owns it, and
# only proj's helper exports `h`.  A per-analyze desugar memo keyed on source
# text alone hands the dep's module the consumer's tree and the genuine
# R-PRIVATE-NAME on depdir/user.mdk goes silent (check --json exit 0).  The memo
# is keyed on path + source; this pins the reject on the machine channel, where
# the human path (a plain desugar) never showed the difference.
SAMESRC="$FIX/samesrc/proj/main.mdk"
got=$(bound "$MEDAKA" check --json "$SAMESRC" 2>/dev/null)
rc=$?
if [ "$rc" -eq 1 ] \
  && printf '%s' "$got" | grep -q 'R-PRIVATE-NAME' \
  && printf '%s' "$got" | grep -q 'depdir/user.mdk'; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL samesrc_check_json: expected exit 1 with R-PRIVATE-NAME on depdir/user.mdk, got exit $rc"
  printf '%s\n' "$got" | sed 's/^/  /' | head -20
fi

# ── native `medaka test` probes span the dep, from a RELATIVE target ─────────
# Both native engines compile their probe inside a synthesized scratch project
# (`scratchProjectManifest`, compiler/driver/build_cmd.mdk).  A scratch manifest
# without the target project's own [dependencies] cannot resolve
# `minilib.lib.minilib` however many search roots the emitter is handed, so the
# probe fails to build while the interpreter arm passes (#2749).
#
# The target is named RELATIVELY on purpose: dep paths are joined onto the
# project root literally, so a relative root yields a relative dep path that is
# re-resolved against the scratch dir.  An absolute invocation passes vacuously.
PROBE_REL="test/cross_project_fixtures/consumer/probe_test.mdk"
got=$(cd "$ROOT" && MEDAKA_STRICT=1 bound "$MEDAKA" test --native "$PROBE_REL" 2>&1)
rc=$?
# One "1/1 passed" from the doctest engine, one from the test-decl engine.
n_ok=$(printf '%s\n' "$got" | grep -c '1/1 passed')
if [ "$rc" -eq 0 ] && [ "$n_ok" -eq 2 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL native_test_relative: expected exit 0 and two '1/1 passed', got exit $rc ($n_ok)"
  printf '%s\n' "$got" | sed 's/^/  /' | head -20
fi

# The interpreter arm is the floor the native arm is differenced against.
got=$(cd "$ROOT" && MEDAKA_STRICT=1 bound "$MEDAKA" test "$PROBE_REL" 2>&1)
rc=$?
n_ok=$(printf '%s\n' "$got" | grep -c '1/1 passed')
if [ "$rc" -eq 0 ] && [ "$n_ok" -eq 2 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL eval_test_relative: expected exit 0 and two '1/1 passed', got exit $rc ($n_ok)"
  printf '%s\n' "$got" | sed 's/^/  /' | head -20
fi

echo "cross_project_deps: $pass/$((pass + fail))"
[ "$fail" -eq 0 ]
