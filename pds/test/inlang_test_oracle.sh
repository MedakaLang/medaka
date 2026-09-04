#!/usr/bin/env bash
# In-language (`medaka test`) gate for the `pds/` project.
#
# Runs the pure-Medaka `test "…"` / `prop "…"` suites under `pds/test/*_test.mdk`
# and asserts they are DISCOVERED and PASS.
#
# CI enrollment is explicit and cost-based: this gate is named directly in a
# shard pattern. A future pds/test/*.sh gate therefore needs its own measured
# shard placement; directory location alone does not enroll it.
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
SUITES="skeleton_test:2 http_test:74 xrpc_test:29 server_core_test:11 encodings_test:29 dagcbor_cid_test:12 mst_test:12 car_store_test:14 repo_tid_test:9 field_test:30 scalar_test:38 sign_key_test:11 secp256k1_point_test:8 rfc6979_test:4 ecdsa_test:2 pbkdf2_test:4 jwt_test:26 credential_test:20 session_routes_test:29 auth_seam_test:31"

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

# NATIVE-ENGINE EXCEPTIONS (2026-09-03, native-test-vehicle sprint's review
# round): the eval-arm capability pre-check (#2588) added this sprint is a
# deliberate OVER-approximation of what a `test "…"` body's run would reach (a
# branch never taken still counts — test_runner.mdk's own header says so).
# `repo_tid_test.mdk`'s "rejects invalid signing key BEFORE commit
# construction" test never actually calls `buildCommit` (it errors out first,
# confirmed: 9/9 pass under `--native`, matching this file's own eval floor
# exactly) but statically reaches it through `lib.repo.repoInitFromKeyBytes`'s
# full call graph, so the pre-check refuses the whole file before eval's
# unbound-identifier panic that USED to let it run clean ever gets a chance to
# not fire. Named per-file rather than switching the whole harness to
# `--native` (slower per-file compile, unverified across all 14 suites, and
# out of this sprint's own stated scope). Delete a row here if that file's
# capability surface changes and it passes under eval again.
#
# pbkdf2_test/jwt_test/credential_test/session_routes_test/auth_seam_test are
# a second, distinct reason for the same mechanism: PBKDF2/SHA-256 volume that
# runs several times slower under the interpreter (`pds/test/unit_suite.sh`
# already routes these five through `--native` for the identical reason;
# pbkdf2_test alone ran for minutes of CPU time under eval without finishing
# in a manual measurement).
NATIVE_ENGINE_EXCEPTIONS=" repo_tid_test pbkdf2_test jwt_test credential_test session_routes_test auth_seam_test "

for spec in $SUITES; do
  name="${spec%%:*}"
  floor="${spec##*:}"
  path="$ROOT/pds/test/$name.mdk"
  if [ ! -f "$path" ]; then
    echo "FAIL: $name.mdk missing at $path"; rc=1; continue
  fi

  case "$NATIVE_ENGINE_EXCEPTIONS" in
    *" $name "*) engine_flag="--native" ;;
    *) engine_flag="" ;;
  esac
  out="$("$MEDAKA" test $engine_flag "$path" 2>&1)"
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
