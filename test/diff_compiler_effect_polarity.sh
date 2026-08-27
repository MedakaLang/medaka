#!/bin/sh
# diff_compiler_effect_polarity.sh — the effect-row PARAMETER-POLARITY conformance
# matrix (D-2 / #1119, closing the #1098 / #1121 launder family).
#
# Corpus: test/effect_polarity_fixtures/, 12 single-entry projects. Ten of them are
# LAUNDER rows: a value whose type carries an effect row is widened through a type
# PARAMETER that is not covariant — either a write channel (`Ref`-like, the `write-*`
# rows) or a contravariant position (a function argument, the `contra-*` rows) — at
# five wrapper depths each (direct / newtype / two-deep / record field / opaque
# cross-module export). Per docs/spec/EFFECTS-SEMANTICS.md §9 ("no direction of
# weakening is sound in general — only equality is") and §5 (the no-laundering law),
# every one of those ten MUST be REJECTED. The remaining two are CONTROLS in the
# `test/diff_compiler_must_fail.sh` sense: ordinary covariant programs (a plain
# function parameter, a `List` shape) that isolate the one distinguishing feature the
# launder rows have and the controls do not, and which MUST stay ACCEPTED — without
# them, "reject everything" would score a perfect 12/12 here.
#
# ⚠️ POLARITY IS ORDINARY, NOT INVERTED. Unlike diff_compiler_must_fail.sh — whose
# fixtures pin OPEN bugs, so that RED there is the healthy state — this is a plain
# conformance gate. RED here means the compiler regressed: it is either laundering an
# effect row again (a REJECT row went ACCEPT — an S0, silent wrongness) or over-
# rejecting ordinary covariant code (a CONTROL row went REJECT — an S1). Never
# "repair" this gate by editing the expected verdict; the verdicts below come from the
# spec, not from what the engine happened to do.
#
# ── WHY THE EXPECTED VERDICTS LIVE HERE AND NOT IN claim.txt ──────────────────
#
# Each fixture ships a claim.txt, but those record the MEASUREMENT AND DERIVATION at
# the time the row was authored (slice 3 wrote them while the launder rows were still
# wrongly accepted, so several read `status: RED (WRONGLY ACCEPTED)`). Parsing them
# would make this gate assert whatever the prose currently says — a golden that
# records what the engine DID rather than what is CORRECT. The table below is derived
# from EFFECTS-SEMANTICS.md instead, and the completeness check underneath it means a
# fixture added to the corpus without a considered verdict here is a hard FAIL, not a
# silent skip.
#
# ── ASSERTION SHAPE ───────────────────────────────────────────────────────────
#
# A REJECT row must exit 1 AND its diagnostic must name the polarity violation. Exit
# code alone would let an UNRELATED breakage (a parse error, a missing prelude) read
# as "still correctly rejected" — the #463 failure mode. An ACCEPT row must exit 0.
# `checked N fixtures` is printed and N == 0 is a FAILURE: "this didn't run" must
# never look like "this passed".
#
# MEDAKA_STRICT=1 on every invocation so a stale binary fails loudly ([B-STALENESS])
# instead of answering from older source.
#
# Usage: sh test/diff_compiler_effect_polarity.sh [name ...]
#   With no arguments, checks every fixture. With arguments, checks only those.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/effect_polarity_fixtures"
export MEDAKA_ROOT="$ROOT"
export MEDAKA_STRICT=1

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir: $FIXDIR"; exit 2; }

# The substring every polarity rejection must contain. Kept deliberately short and
# free of punctuation that varies with the rendered type, so a reworded diagnostic
# tail does not red this gate, but an unrelated error still cannot match it.
POLARITY_MSG='non-covariant type argument'

# ── the expected-verdict table (derived from EFFECTS-SEMANTICS.md §5/§9) ───────
# reject  <name>  — launder row: widening through a non-covariant parameter
# accept  <name>  — control: ordinary covariant program, must stay green
expected_verdict() {
  case "$1" in
    contra-2deep|contra-direct|contra-newtype|contra-opaque-export|contra-record-field) echo reject ;;
    write-2deep|write-direct|write-newtype|write-opaque-export|write-record-field)      echo reject ;;
    control-direct-function|control-list-shape)                                         echo accept ;;
    *) echo unknown ;;
  esac
}

if [ "$#" -gt 0 ]; then
  names="$*"
else
  names=""
  for d in "$FIXDIR"/*/; do
    [ -d "$d" ] || continue
    names="$names $(basename "$d")"
  done
fi

checked=0
failed=0
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM

for name in $names; do
  entry="$FIXDIR/$name/main.mdk"
  if [ ! -f "$entry" ]; then
    echo "FAIL $name — no main.mdk at $entry"
    failed=$((failed + 1))
    continue
  fi

  want="$(expected_verdict "$name")"
  if [ "$want" = unknown ]; then
    echo "FAIL $name — fixture is in the corpus but has NO expected verdict in this"
    echo "     gate's table. Decide the right answer from docs/spec/EFFECTS-SEMANTICS.md"
    echo "     §5/§9 FIRST, then add a 'reject' or 'accept' row to expected_verdict()."
    failed=$((failed + 1))
    continue
  fi

  "$MEDAKA" check "$entry" >"$tmp" 2>&1
  rc=$?
  checked=$((checked + 1))

  if [ "$want" = accept ]; then
    if [ "$rc" -eq 0 ]; then
      echo "ok   $name — ACCEPT (exit 0), control stays green"
    else
      echo "FAIL $name — expected ACCEPT (exit 0), got exit $rc."
      echo "     A control row rejecting means the polarity analysis now OVER-REJECTS"
      echo "     ordinary covariant code (S1: loud breakage). Diagnostic:"
      sed 's/^/     | /' "$tmp"
      failed=$((failed + 1))
    fi
  else
    if [ "$rc" -eq 0 ]; then
      echo "FAIL $name — expected REJECT (exit 1), got exit 0."
      echo "     An effect row is being LAUNDERED through a non-covariant type"
      echo "     parameter again (S0: silent wrongness; the #1098/#1121 family)."
      failed=$((failed + 1))
    elif ! grep -q "$POLARITY_MSG" "$tmp"; then
      echo "FAIL $name — rejected (exit $rc) but NOT for the polarity reason."
      echo "     Expected the diagnostic to contain: $POLARITY_MSG"
      echo "     An unrelated failure must not launder as 'still correctly rejected'."
      sed 's/^/     | /' "$tmp"
      failed=$((failed + 1))
    else
      echo "ok   $name — REJECT (exit $rc), polarity diagnostic present"
    fi
  fi
done

echo
echo "checked $checked fixtures"

if [ "$checked" -eq 0 ]; then
  echo "FAIL: checked 0 fixtures — 'this didn't run' must never read as 'this passed'."
  exit 1
fi

if [ "$failed" -gt 0 ]; then
  echo "FAIL: $failed of $checked effect-polarity fixtures did not match the spec verdict."
  exit 1
fi

echo "PASS: all $checked effect-polarity fixtures match the spec verdict."
