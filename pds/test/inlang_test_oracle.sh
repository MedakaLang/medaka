#!/usr/bin/env bash
# In-language (`medaka test`) gate for the `pds/` project.
#
# Runs the pure-Medaka `test "…"` / `prop "…"` suites under `pds/test/*_test.mdk`
# and asserts they are DISCOVERED and PASS.
#
# It lives in pds/test/ and is enrolled by the `sqlite` CI shard's glob
# ('pds/test/*') — deliberately ONE directory level deep, unlike the sibling
# `sqlite`/`gzip` gates' `*oracle` convention: any .sh landing DIRECTLY under
# pds/test/ is auto-enrolled as a CI gate by that glob, so no future pds/
# in-language gate needs a ci.yml edit. See pds/README.md's "CI classification
# policy" section for the full rule (RUN-PDS0-001 A4 / RUN-PDS0-003(a)).
#
# THE ANTI-ROT GUARD (docs/ops/TESTING-DESIGN.md §0: "this didn't run" is
# indistinguishable from "this passed"): a `medaka test` file with ZERO
# assertions exits 0 — vacuously green. So exit-0 alone is NOT enough. For every
# file we also COUNT the assertions that actually ran ("  ok   " test lines +
# "... OK (" prop lines) and fail if the count falls below a per-file floor. If
# discovery ever silently stops finding the decls, the count drops to 0 and this
# gate goes RED — which is the whole point.
#
# Run from the repo root. Requires a built native `medaka` ($MEDAKA / ../medaka);
# no external oracle needed (`medaka test` runs the interpreter).
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_ROOT

[ -x "$MEDAKA" ] || { echo "build medaka first (missing $MEDAKA)"; exit 2; }

# file:floor — floor = the assertion count committed today. Adding tests only
# raises the real count (>= floor still passes); removing them, or a discovery
# regression, drops below the floor and fails. Raise a floor when you add tests.
SUITES="skeleton_test:4 encodings_test:29 field_test:26 scalar_test:34"

rc=0
total_ran=0

# THE ROSTER IS SELF-DRAINING (RUN-PDS0-012). This gate's header promises it runs
# the suites under pds/test/*_test.mdk, but SUITES above is hand-maintained: a new
# *_test.mdk with no row would never be counted while this gate printed PASS —
# "this didn't run" indistinguishable from "this passed", inside the anti-rot gate.
for f in "$ROOT"/pds/test/*_test.mdk; do
  [ -e "$f" ] || continue          # unmatched glob stays LITERAL in sh; do not fail on an empty corpus
  base="$(basename "$f" .mdk)"
  case " $SUITES " in
    *" $base:"*) ;;                # PREFIX match on the `name:` half, space-anchored:
                                   # a row for subfield_test must not satisfy field_test.mdk
    *) echo "FAIL: pds/test/$base.mdk has no SUITES row — add '$base:<floor>' to SUITES in $0 (floor = the assertion count it commits today)"
       rc=1 ;;
  esac
done

for spec in $SUITES; do
  name="${spec%%:*}"
  floor="${spec##*:}"
  path="$ROOT/pds/test/$name.mdk"
  if [ ! -f "$path" ]; then
    echo "FAIL: $name.mdk missing at $path"; rc=1; continue
  fi

  out="$("$MEDAKA" test "$path" 2>&1)"
  code=$?

  # Assertions that actually executed: passing `test` lines + passing `prop` lines.
  ok_tests=$(printf '%s\n' "$out" | grep -c '^  ok   ')
  ok_props=$(printf '%s\n' "$out" | grep -c '\.\.\. OK (')
  ran=$((ok_tests + ok_props))
  total_ran=$((total_ran + ran))

  if [ "$code" -ne 0 ]; then
    echo "FAIL: $name.mdk — medaka test exited $code (assertion failed)"
    printf '%s\n' "$out"
    rc=1
    continue
  fi
  # A non-numeric count makes `[` ERROR rather than compare, and with `set -e`
  # off control falls through to the PASS branch — so the floor guard could
  # never fail on the one thing it exists to catch (RUN-PDS0-040, F20). Check
  # numeric-ness first.
  case "$ran" in
    ''|*[!0-9]*)
      echo "FAIL: $name.mdk — assertion count is not a number ('$ran') — the driver's summary line did not parse; the anti-rot floor could not be graded."
      rc=1
      continue ;;
  esac
  if [ "$ran" -lt "$floor" ]; then
    echo "FAIL: $name.mdk — only $ran assertions ran, expected >= $floor (vacuous-green guard: discovery may have silently stopped finding tests)"
    printf '%s\n' "$out"
    rc=1
    continue
  fi
  echo "PASS: $name.mdk — $ran assertions ran (floor $floor)"
done

if [ "$total_ran" -eq 0 ]; then
  echo "FAIL: no assertions ran at all across the pds in-language suite"
  exit 1
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: pds in-language test suite ($total_ran assertions across the suite)"
fi
exit "$rc"
