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
# Needs no built ./medaka — pure text over tracked source. Needs python3.
# Portable POSIX sh.
#
# Usage:  sh test/diff_compiler_catch_all_census.sh           # check
#         sh test/diff_compiler_catch_all_census.sh --update  # re-derive the ledger
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEDGER="$ROOT/test/catch_all_census.ledger"
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

if [ "${1:-}" = "--update" ]; then
  cp "$TMP/now" "$LEDGER"
  echo "catch_all_census: ledger re-derived, $(wc -l < "$LEDGER" | tr -d ' ') sites"
  exit 0
fi

[ -f "$LEDGER" ] || { echo "catch_all_census: missing ledger $LEDGER (run with --update)"; exit 1; }

if diff -u "$LEDGER" "$TMP/now" > "$TMP/diff"; then
  echo "catch_all_census: $(wc -l < "$LEDGER" | tr -d ' ') catch-all sites over Expr/Decl in the typechecker, ledger unchanged"
  exit 0
fi

added="$(grep -c '^+[^+]' "$TMP/diff")"
gone="$(grep -c '^-[^-]' "$TMP/diff")"
echo "catch_all_census: FAIL — ledger drift ($added new site(s), $gone retired)"
echo "  a NEW site is a catch-all clause over Expr/Decl added to the typechecker: add the"
echo "  missing arms, or justify it in a comment and re-derive the ledger;"
echo "  a RETIRED site owes the re-derivation in the same diff:"
echo "    sh test/diff_compiler_catch_all_census.sh --update"
cat "$TMP/diff"
exit 1
