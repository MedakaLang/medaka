#!/bin/sh
# In-language (`medaka test`) gate for pds/test/*_test.mdk (#2527: originally
# these 15 files, ~338 `test` decls of ECDSA/RFC 6979/secp256k1/field/scalar/
# HTTP structural assertions, ran nowhere in CI; S-kdf added pbkdf2_test).
#
# THE ANTI-ROT GUARD (docs/ops/TESTING-DESIGN.md §0: "this didn't run" is
# indistinguishable from "this passed"): a `medaka test` file with ZERO
# assertions exits 0 — vacuously green, and an empty target list is not
# reliably a failure signal either. So exit code alone is never enough. For
# every file we also COUNT the assertions that actually ran ("  ok   " test
# lines + "... OK (" prop lines) and fail if the count is 0. If discovery
# ever silently stops finding the decls, the count drops to 0 and this gate
# goes RED — which is the whole point.
#
# Most files run fine under the default (interpreted) engine. Three need the
# native engine: field_test/scalar_test time out under the interpreter (pure
# arithmetic volume), and repo_tid_test reaches an extern (buildCommit) the
# interpreter's capability policy does not bind — `medaka test` itself names
# `--native` as the fix in its own error text for that last case.
#
# Run from the repo root. Requires a built native `medaka` ($MEDAKA / ./medaka).
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_ROOT

[ -x "$MEDAKA" ] || { echo "build medaka first (missing $MEDAKA)"; exit 2; }

# name:engine — engine is "" for the default (interpreted) engine, or
# "--native" for a file that needs the native engine (see header).
SUITES="
car_store_test:
dagcbor_cid_test:
ecdsa_test:
encodings_test:
field_test:--native
http_test:
mst_test:
pbkdf2_test:--native
repo_tid_test:--native
rfc6979_test:
scalar_test:--native
secp256k1_point_test:
server_core_test:
sign_key_test:
skeleton_test:
xrpc_test:
"

# Exclusion ledger: "name reason (issue TODO)" — none today. Format kept even
# while empty so the next exclusion doesn't need a new mechanism.
EXCLUDED=""

rc=0
total_ran=0
count=0
for spec in $SUITES; do
  [ -n "$spec" ] || continue
  name="${spec%%:*}"
  engine="${spec#*:}"

  case " $EXCLUDED " in
    *" $name "*)
      echo "SKIP: $name.mdk (ledgered exclusion, see EXCLUDED above)"
      continue
      ;;
  esac

  count=$((count + 1))
  path="$ROOT/pds/test/$name.mdk"
  if [ ! -f "$path" ]; then
    echo "FAIL: $name.mdk missing at $path"
    rc=1
    continue
  fi

  if [ -n "$engine" ]; then
    out="$("$MEDAKA" test "$engine" "$path" 2>&1)"
  else
    out="$("$MEDAKA" test "$path" 2>&1)"
  fi
  code=$?

  ok_tests=$(printf '%s\n' "$out" | grep -c '^  ok   ')
  ok_props=$(printf '%s\n' "$out" | grep -c '\.\.\. OK (')
  ran=$((ok_tests + ok_props))
  total_ran=$((total_ran + ran))

  if [ "$code" -ne 0 ]; then
    echo "FAIL: $name.mdk — medaka test${engine:+ $engine} exited $code"
    printf '%s\n' "$out" | tail -20
    rc=1
    continue
  fi
  if [ "$ran" -eq 0 ]; then
    echo "FAIL: $name.mdk — 0 assertions ran (vacuous-green guard)"
    rc=1
    continue
  fi
  echo "PASS: $name.mdk — $ran assertions ran${engine:+ ($engine)}"
done

if [ "$count" -eq 0 ]; then
  echo "FAIL: no files resolved to run (empty target list)"
  exit 1
fi

if [ "$total_ran" -eq 0 ]; then
  echo "FAIL: no assertions ran at all across the pds test suite"
  exit 1
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: pds in-language test suite ($total_ran assertions across $count files)"
fi
exit "$rc"
