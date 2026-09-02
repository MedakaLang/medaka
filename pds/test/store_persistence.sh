#!/bin/sh
# P7 durable store: a repository persisted by one process is resumed, byte for
# byte, by a SEPARATE process; a tampered block file is rejected rather than
# served; and no file the adapter wrote contains the signing key.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/store_persistence_main.mdk"
# Must match `secretHex` in the driver.
SECRET_HEX=c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-persist.XXXXXX")
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

# Every byte of every file below `$1`, as one lowercase hex string. Reading the
# tree as hex catches the key whether it was written raw or as hex text.
tree_hex() {
  find "$1" -type f -exec cat {} + | od -An -v -tx1 | tr -d ' \n'
}

[ -x "$MEDAKA" ] || fail "build medaka first (missing $MEDAKA)"

# The adapter is native-only: every file extern it uses is unimplemented in the
# interpreter and permanently rejected by Wasm (design row P9), so this gate
# grades the native engine alone.
if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/driver" \
  > "$WORK/build.log" 2>&1
then
  cat "$WORK/build.log" >&2
  fail 'native driver build failed'
fi

DATA="$WORK/data"

# ── 1. save, in one process ─────────────────────────────────────────────────
"$WORK/driver" save "$DATA" > "$WORK/save.out" 2> "$WORK/save.err"
require_empty "$WORK/save.err" save
[ "$(tail -1 "$WORK/save.out")" = 'SAVE: PASS' ] || fail 'save route did not pass'
grep -q '^SAVE records 3$' "$WORK/save.out" || fail 'save did not write three records'

# ── 2. load, in a SEPARATE process invocation ───────────────────────────────
"$WORK/driver" load "$DATA" > "$WORK/load.out" 2> "$WORK/load.err"
require_empty "$WORK/load.err" load
[ "$(tail -1 "$WORK/load.out")" = 'LOAD: PASS' ] || fail 'load route did not pass'

sed -n 's/^SAVE /STATE /p' "$WORK/save.out" > "$WORK/save.state"
sed -n 's/^LOAD /STATE /p' "$WORK/load.out" > "$WORK/load.state"
[ -s "$WORK/save.state" ] || fail 'save produced no state summary'
cmp "$WORK/save.state" "$WORK/load.state" \
  || fail 'reloaded head commit CID / record count / getRepo CAR differ'
grep -q '^STATE car .* decodes$' "$WORK/save.state" || fail 'exported CAR did not decode'
echo "resumed $(sed -n 's/^STATE head //p' "$WORK/save.state")"

# ── 3. no persisted file carries the signing key ────────────────────────────
FILES=$(find "$DATA" -type f | wc -l | tr -d ' ')
[ "$FILES" -ge 2 ] || fail "expected persisted files, found $FILES"
tree_hex "$DATA" > "$WORK/data.hex"
if grep -q -F "$SECRET_HEX" "$WORK/data.hex"; then
  fail 'a persisted file contains the raw signing-key bytes'
fi
# The same key spelled as hex text is those ASCII digits, i.e. hex-of-hex.
KEY_AS_TEXT=$(printf '%s' "$SECRET_HEX" | od -An -v -tx1 | tr -d ' \n')
if grep -q -F "$KEY_AS_TEXT" "$WORK/data.hex"; then
  fail 'a persisted file contains the signing key as hex text'
fi
echo "key absent from $FILES persisted files (raw bytes and hex text)"

# ── 4. a tampered block file is rejected, not served ────────────────────────
cp -R "$DATA" "$WORK/tampered"
VICTIM=$(find "$WORK/tampered/blocks" -type f | sort | sed -n '1p')
[ -n "$VICTIM" ] || fail 'no persisted block file to tamper with'
cp "$VICTIM" "$WORK/victim.orig"
# Same file name, same length, different bytes: only the content moved.
printf '\000' | dd of="$VICTIM" bs=1 count=1 conv=notrunc 2>/dev/null
if cmp -s "$VICTIM" "$WORK/victim.orig"; then
  printf '\001' | dd of="$VICTIM" bs=1 count=1 conv=notrunc 2>/dev/null
fi
cmp -s "$VICTIM" "$WORK/victim.orig" && fail 'tamper did not change the block file'
[ "$(wc -c < "$VICTIM")" = "$(wc -c < "$WORK/victim.orig")" ] \
  || fail 'tamper changed the block length; the test wants a pure content change'

"$WORK/driver" reject "$WORK/tampered" > "$WORK/reject.out" 2> "$WORK/reject.err"
require_empty "$WORK/reject.err" reject
grep -q '^REJECT: PASS ' "$WORK/reject.out" || {
  cat "$WORK/reject.out" >&2
  fail 'tampered block file was not rejected'
}
sed -n 's/^REJECT: PASS /rejected: /p' "$WORK/reject.out"

echo 'PASS: store persistence — cross-process resume; tamper rejected; key absent'
