#!/bin/sh
# P4-A identifier and URI syntax validators, graded against the official
# atproto interop syntax corpora (pds/test/vectors/interop_*.txt).
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/atsyntax_vectors_main.mdk"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-atsyntax.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

require_empty() {
  [ ! -s "$1" ] || {
    cat "$1" >&2
    fail "$2 emitted stderr"
  }
}

[ -x "$MEDAKA" ] || fail "build medaka first (missing $MEDAKA)"

sh "$ROOT/pds/test/vector_provenance.sh" --files-for P4-A-IDENTIFIER-SYNTAX > "$WORK/vector-files"
[ "$(wc -l < "$WORK/vector-files" | tr -d ' ')" = 14 ] || fail 'expected exactly 14 ledger-owned P4-A-IDENTIFIER-SYNTAX corpora'

# `vector_provenance.sh --files-for` does not promise an order — pick each of
# the 14 files by name rather than by position.
pick() {
  grep -F "/interop_$1.txt" "$WORK/vector-files" || fail "ledger is missing interop_$1.txt for P4-A-IDENTIFIER-SYNTAX"
}

ATURI_VALID="$ROOT/$(pick aturi_valid)"
ATURI_INVALID="$ROOT/$(pick aturi_invalid)"
ATIDENTIFIER_VALID="$ROOT/$(pick atidentifier_valid)"
ATIDENTIFIER_INVALID="$ROOT/$(pick atidentifier_invalid)"
DID_VALID="$ROOT/$(pick did_valid)"
DID_INVALID="$ROOT/$(pick did_invalid)"
HANDLE_VALID="$ROOT/$(pick handle_valid)"
HANDLE_INVALID="$ROOT/$(pick handle_invalid)"
NSID_VALID="$ROOT/$(pick nsid_valid)"
NSID_INVALID="$ROOT/$(pick nsid_invalid)"
RECORDKEY_VALID="$ROOT/$(pick recordkey_valid)"
RECORDKEY_INVALID="$ROOT/$(pick recordkey_invalid)"
TID_VALID="$ROOT/$(pick tid_valid)"
TID_INVALID="$ROOT/$(pick tid_invalid)"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/native" > "$WORK/build.log" 2>&1; then
  cat "$WORK/build.log" >&2
  fail 'atsyntax driver build failed'
fi

if ! "$WORK/native" \
  "$ATURI_VALID" "$ATURI_INVALID" \
  "$ATIDENTIFIER_VALID" "$ATIDENTIFIER_INVALID" \
  "$DID_VALID" "$DID_INVALID" \
  "$HANDLE_VALID" "$HANDLE_INVALID" \
  "$NSID_VALID" "$NSID_INVALID" \
  "$RECORDKEY_VALID" "$RECORDKEY_INVALID" \
  "$TID_VALID" "$TID_INVALID" \
  > "$WORK/native.out" 2> "$WORK/native.err"
then
  cat "$WORK/native.out" >&2
  cat "$WORK/native.err" >&2
  fail 'atsyntax driver run failed'
fi
require_empty "$WORK/native.err" native

for label in aturi atidentifier did handle nsid recordkey tid \
  repo-validateRkey repo-validateCollection
do
  line=$(grep -E "^$label: [0-9]+/[0-9]+ valid accepted, [0-9]+/[0-9]+ invalid rejected$" "$WORK/native.out") \
    || fail "missing or malformed counted line for $label"
  echo "$line" | awk -F'[ /,]+' -v label="$label" '
    { validTotal = $3; invalidTotal = $7 }
    validTotal == 0 || invalidTotal == 0 { print "FAIL: " label " reported a 0-denominator count"; exit 1 }
  ' || exit 1
done

[ "$(tail -1 "$WORK/native.out")" = 'TOTAL: PASS' ] || {
  cat "$WORK/native.out" >&2
  fail 'atsyntax driver did not end in TOTAL: PASS'
}

cat "$WORK/native.out"
echo "PASS: atsyntax — 7 official atproto interop syntax corpora (aturi atidentifier did handle nsid recordkey tid), plus lib.repo's validateRkey/validateCollection cross-graded"
