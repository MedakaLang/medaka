#!/bin/sh
# P7 durable store: a repository persisted by one process is resumed, byte for
# byte, by a SEPARATE process; a tampered block file is rejected rather than
# served; and no file the adapter wrote contains the signing key. The same
# three claims are then made for the BLOB half, which persists beside the
# repository under `<data>/blobs` — plus a fourth, that a blob the pure layer
# refuses never reaches a file at all.
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

# ── 2b. the blob half saves and reloads across a process boundary ──────────
# Written into the SAME $DATA directory the repository uses, so the key check
# below covers every blob file this gate wrote without a second sweep.
"$WORK/driver" blob-save "$DATA" > "$WORK/blobsave.out" 2> "$WORK/blobsave.err"
require_empty "$WORK/blobsave.err" blob-save
[ "$(tail -1 "$WORK/blobsave.out")" = 'BLOB-SAVE: PASS' ] \
  || fail 'blob save route did not pass'

"$WORK/driver" blob-load "$DATA" > "$WORK/blobload.out" 2> "$WORK/blobload.err"
require_empty "$WORK/blobload.err" blob-load
[ "$(tail -1 "$WORK/blobload.out")" = 'BLOB-LOAD: PASS' ] \
  || fail 'blob load route did not pass'

sed -n 's/^BLOBSAVE /BLOBSTATE /p' "$WORK/blobsave.out" > "$WORK/blobsave.state"
sed -n 's/^BLOBLOAD /BLOBSTATE /p' "$WORK/blobload.out" > "$WORK/blobload.state"
[ -s "$WORK/blobsave.state" ] || fail 'blob save produced no state summary'
cmp "$WORK/blobsave.state" "$WORK/blobload.state" \
  || fail 'reloaded blob CID / declared MIME type / bytes differ'
echo "resumed $(grep -c '^BLOBSTATE blob ' "$WORK/blobsave.state") blob(s)"

# The declared MIME type is the part content addressing does NOT carry, so a
# reload that recovered the bytes and lost the type would still be a loss.
grep -q '^BLOBSTATE blob .* text/plain ' "$WORK/blobload.state" \
  || fail 'the reloaded blob lost its declared MIME type'

# ── 3. no persisted file carries the signing key ────────────────────────────
# `tree_hex` sweeps `$DATA` whole, so the blob half is inside its scope by
# construction — but only if blob files are actually there, which is asserted
# rather than assumed: two blobs, each a byte file plus its MIME sidecar.
BLOB_FILES=$(find "$DATA/blobs" -type f | wc -l | tr -d ' ')
[ "$BLOB_FILES" -eq 4 ] \
  || fail "expected 4 blob files under $DATA/blobs, found $BLOB_FILES"
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
echo "key absent from $FILES persisted files ($BLOB_FILES of them blob files; raw bytes and hex text)"

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

# ── 5. a tampered BLOB file is rejected, not served ────────────────────────
cp -R "$DATA" "$WORK/blobtampered"
BLOB_VICTIM=$(find "$WORK/blobtampered/blobs" -type f ! -name '*.mime' | sort \
  | sed -n '1p')
[ -n "$BLOB_VICTIM" ] || fail 'no persisted blob file to tamper with'
cp "$BLOB_VICTIM" "$WORK/blobvictim.orig"
printf '\000' | dd of="$BLOB_VICTIM" bs=1 count=1 conv=notrunc 2>/dev/null
if cmp -s "$BLOB_VICTIM" "$WORK/blobvictim.orig"; then
  printf '\001' | dd of="$BLOB_VICTIM" bs=1 count=1 conv=notrunc 2>/dev/null
fi
cmp -s "$BLOB_VICTIM" "$WORK/blobvictim.orig" \
  && fail 'tamper did not change the blob file'
[ "$(wc -c < "$BLOB_VICTIM")" = "$(wc -c < "$WORK/blobvictim.orig")" ] \
  || fail 'tamper changed the blob length; the test wants a pure content change'

"$WORK/driver" blob-reject "$WORK/blobtampered" > "$WORK/blobreject.out" \
  2> "$WORK/blobreject.err"
require_empty "$WORK/blobreject.err" blob-reject
grep -q '^BLOB-REJECT: PASS ' "$WORK/blobreject.out" || {
  cat "$WORK/blobreject.out" >&2
  fail 'tampered blob file was not rejected'
}
sed -n 's/^BLOB-REJECT: PASS /blob rejected: /p' "$WORK/blobreject.out"

# ── 6. an oversize blob is refused BEFORE any bytes reach the disk ─────────
# A fresh directory, so "no blob file exists" is an assertion about this
# upload and not about a directory that was already empty of other blobs.
OVERSIZE="$WORK/oversize"
mkdir -p "$OVERSIZE"
"$WORK/driver" blob-oversize "$OVERSIZE" > "$WORK/oversize.out" \
  2> "$WORK/oversize.err"
require_empty "$WORK/oversize.err" blob-oversize
[ "$(tail -1 "$WORK/oversize.out")" = 'BLOB-OVERSIZE: PASS nothing was written' ] \
  || {
    cat "$WORK/oversize.out" >&2
    fail 'an oversize blob was not refused before writing'
  }
sed -n 's/^BLOB-OVERSIZE refused /oversize refused: /p' "$WORK/oversize.out"
OVERSIZE_FILES=$(find "$OVERSIZE" -type f | wc -l | tr -d ' ')
[ "$OVERSIZE_FILES" = '0' ] \
  || fail "an oversize blob left $OVERSIZE_FILES file(s) on disk"

echo 'PASS: store persistence — cross-process resume (repository and blobs); tamper rejected in both halves; oversize blob refused before any write; key absent'
