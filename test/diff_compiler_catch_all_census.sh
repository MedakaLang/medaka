#!/bin/sh
# test/diff_compiler_catch_all_census.sh — catch-all clause RATCHET over
# compiler/types/typecheck.mdk and compiler/types/repr.mdk (#2551).
#
# WHAT IT PINS. Every top-level multi-clause function in those two files that
# dispatches on an `Expr` or `Decl` constructor at some parameter position
# while its FINAL clause is a catch-all (`_` or a bare variable) there, and the
# constructors it names do not cover the whole sum. Such a clause silently
# absorbs any constructor added to the sum later — AGENTS.md [T-GLOBAL-TABLE]
# says outright that gates cannot catch that, and it is what a migration trips
# first. This ratchet makes ADDING one a decision rather than an accident.
#
# NOT A LINT RULE. `medaka lint` has no type environment (its oracle is
# constructors only), so "this parameter is `Expr`-typed" is not expressible
# there. test/catch_all_census.py derives the constructor sets from
# compiler/frontend/ast.mdk and the clause heads from the source text.
#
# THE LEDGER. test/catch_all_census.ledger holds the current site list, one
# `<function>\t<sum>\t<named>/<total>` row per function, derived from the
# tree — never hand-typed. Keyed by function name, not line, so an unrelated
# edit above a site does not move it. ANY drift fails: a NEW site means a
# catch-all was added (justify it, or add the missing arms); a VANISHED site
# means one was retired and the ledger owes a re-derivation in the same diff
# (`sh test/diff_compiler_catch_all_census.sh --update`). The ledger shrinks
# over time; it does not have to reach zero.
#
# MISSING, NEVER 0. The census exits 3 when it cannot find its subject (no
# ast.mdk, no constructor sets, zero clause groups, zero sites); this gate
# treats that as a harness failure, not as a clean tree.
#
# A SECOND, INDEPENDENT ledger lives in this same gate: test/decl_runner.ledger
# pins, for every `Decl` constructor `ast.mdk` declares, which verb/runner
# executes it (`medaka run`, `medaka test`'s doctest/prop runner, …) or an
# explicit `compile-time-only` reason. The constructor SET is derived from
# `ast.mdk` same as above; the RUNNER a constructor names is hand-authored in
# `test/catch_all_census.py`'s DECL_RUNNERS and cannot be derived from source
# shape. A constructor with no DECL_RUNNERS entry gets a `TODO` placeholder
# row rather than being silently dropped, and the check arm below FAILS while
# any placeholder remains — so `--update` can regenerate the ledger but can
# never make a newly added constructor's row satisfy the gate on its own; a
# human has to name its runner.
#
# Needs no built ./medaka — pure text over tracked source. Needs python3.
# Portable POSIX sh.
#
# Usage:  sh test/diff_compiler_catch_all_census.sh           # check
#         sh test/diff_compiler_catch_all_census.sh --update  # re-derive both ledgers
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEDGER="$ROOT/test/catch_all_census.ledger"
DECL_LEDGER="$ROOT/test/decl_runner.ledger"
CENSUS="$ROOT/test/catch_all_census.py"

[ -f "$CENSUS" ] || { echo "catch_all_census: missing $CENSUS"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "catch_all_census: python3 not found"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 "$CENSUS" "$ROOT" > "$TMP/now" 2> "$TMP/err"
st=$?
if [ "$st" -ne 0 ]; then
  echo "catch_all_census: MISSING — the census could not derive its subject (exit $st):"
  cat "$TMP/err"
  exit 1
fi

python3 "$CENSUS" "$ROOT" --decl-runners > "$TMP/decl_now" 2> "$TMP/decl_err"
dst=$?
if [ "$dst" -ne 0 ]; then
  echo "catch_all_census: MISSING — the decl-runner ledger could not derive its subject (exit $dst):"
  cat "$TMP/decl_err"
  exit 1
fi

if [ "${1:-}" = "--update" ]; then
  cp "$TMP/now" "$LEDGER"
  cp "$TMP/decl_now" "$DECL_LEDGER"
  echo "catch_all_census: ledger re-derived, $(wc -l < "$LEDGER" | tr -d ' ') sites"
  echo "catch_all_census: decl_runner.ledger re-derived, $(wc -l < "$DECL_LEDGER" | tr -d ' ') constructors"
  exit 0
fi

[ -f "$LEDGER" ] || { echo "catch_all_census: missing ledger $LEDGER (run with --update)"; exit 1; }
[ -f "$DECL_LEDGER" ] || { echo "catch_all_census: missing ledger $DECL_LEDGER (run with --update)"; exit 1; }

fail=0

if diff -u "$LEDGER" "$TMP/now" > "$TMP/diff"; then
  echo "catch_all_census: $(wc -l < "$LEDGER" | tr -d ' ') catch-all sites over Expr/Decl in the typechecker, ledger unchanged"
else
  added="$(grep -c '^+[^+]' "$TMP/diff")"
  gone="$(grep -c '^-[^-]' "$TMP/diff")"
  echo "catch_all_census: FAIL — ledger drift ($added new site(s), $gone retired)"
  echo "  a NEW site is a catch-all clause over Expr/Decl added to the typechecker: add the"
  echo "  missing arms, or justify it in a comment and re-derive the ledger;"
  echo "  a RETIRED site owes the re-derivation in the same diff:"
  echo "    sh test/diff_compiler_catch_all_census.sh --update"
  cat "$TMP/diff"
  fail=1
fi

if diff -u "$DECL_LEDGER" "$TMP/decl_now" > "$TMP/decl_diff"; then
  echo "catch_all_census: $(wc -l < "$DECL_LEDGER" | tr -d ' ') Decl constructors have a runner row, ledger unchanged"
else
  echo "catch_all_census: FAIL — decl_runner.ledger drift"
  echo "  a Decl constructor was added or removed from ast.mdk: re-derive with"
  echo "    sh test/diff_compiler_catch_all_census.sh --update"
  echo "  then name the new constructor's runner (the placeholder check below still fails"
  echo "  until you do)."
  cat "$TMP/decl_diff"
  fail=1
fi

if grep -q 'TODO$' "$DECL_LEDGER"; then
  echo "catch_all_census: FAIL — decl_runner.ledger has an unfilled TODO runner:"
  grep 'TODO$' "$DECL_LEDGER"
  echo "  name the consumer that runs this Decl constructor (a verb, a runner, or an"
  echo "  explicit compile-time-only reason) in DECL_RUNNERS, test/catch_all_census.py."
  fail=1
fi

exit "$fail"
