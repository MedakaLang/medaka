#!/usr/bin/env bash
# Differential oracle for the gzip library's inflater: the system `gzip` CLI
# compresses, our `gzip/inflate_demo.mdk` decompresses, and the result must be
# BYTE-FOR-BYTE identical to the original.
#
# This is the same discipline as sqlite/test/*oracle.sh — diff against the real
# tool, never against a golden captured from our own output. A golden records
# what this code did; `cmp` against the original records what is CORRECT.
#
# WHY INCOMPRESSIBLE INPUT: as of Phase 2 the inflater implements STORED blocks
# (BTYPE=00) only. There is no `gzip -0` — GNU gzip 1.13 rejects it
# (`invalid option -- '0'`); the levels are -1..-9. gzip falls back to a stored
# block when compressing would EXPAND the data, so /dev/urandom is how you get
# one out of the real tool. Verified:
#     $ head -c 200 /dev/urandom > r.bin && gzip -1 -n -c r.bin | xxd -s 10 -l 6
#     0000000a: 01c8 0037 ff        # 0x01 = BFINAL=1,BTYPE=00; LEN=200; NLEN=~200
#
# ⚠️ gzip's stored fallback is a PER-BLOCK heuristic, not "the whole input did
# not compress" — a 40-byte random sample still came out as BTYPE=01 during
# development. Sizes here are chosen large enough to reliably land on stored
# blocks; if that ever stops holding, this gate fails loudly rather than
# silently testing nothing (see the BTYPE assertion in check_stored below).
#
# Compressible input (fixed/dynamic Huffman) is asserted to fail CLEANLY with a
# named error and a non-zero exit — that is the honest Phase-2/3 boundary, and
# pinning it means the eventual implementation FLIPS this gate red and tells
# whoever lands it to come update this file.
#
# Run from the repo root or anywhere; requires: gzip, a built native `medaka`
# (../medaka) + its emitter, MEDAKA_ROOT pointing at the repo root.
set -u

ROOT="${MEDAKA_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
export MEDAKA_ROOT="$ROOT"

command -v gzip >/dev/null 2>&1 || { echo "SKIP-AS-FAIL: gzip not found (this gate's oracle)"; exit 1; }
[ -x "$MEDAKA" ] || { echo "FAIL: no native medaka at $MEDAKA (build it first)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/inflate_demo"

"$MEDAKA" build "$ROOT/gzip/inflate_demo.mdk" -o "$BIN" >/dev/null 2>&1 \
  || { echo "FAIL: could not build gzip/inflate_demo.mdk"; exit 1; }

pass=0
fail=0

ok()   { pass=$((pass + 1)); echo "ok   $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL $1"; }

# --- stored-block round trip: real gzip output must decode byte-for-byte ------
# Also asserts the stream really IS a stored block, so this can never silently
# degrade into "we tested a shape the inflater rejects anyway".
check_stored() {
  desc="$1"; size="$2"
  head -c "$size" /dev/urandom > "$TMP/in.bin"
  gzip -1 -n -c "$TMP/in.bin" > "$TMP/in.gz"

  btype_byte=$(od -An -tu1 -j 10 -N 1 "$TMP/in.gz" | tr -d ' ')
  # LSB-first: bit0 = BFINAL, bits1-2 = BTYPE. Stored => (byte >> 1) & 3 == 0.
  if [ $(( (btype_byte >> 1) & 3 )) -ne 0 ]; then
    bad "$desc — oracle produced BTYPE=$(( (btype_byte >> 1) & 3 )), not a stored block; this gate tested nothing"
    return
  fi

  if ! "$BIN" "$TMP/in.gz" "$TMP/out.bin" >/dev/null 2>&1; then
    bad "$desc — inflate_demo exited non-zero on a valid stored stream"
    return
  fi
  if cmp -s "$TMP/in.bin" "$TMP/out.bin"; then
    ok "$desc ($size bytes, stored, byte-for-byte)"
  else
    bad "$desc — output DIFFERS from the original"
  fi
}

check_stored "small stored block"        200
check_stored "single stored block"       4000
check_stored "multi-block stored stream" 200000   # >65535 forces several blocks

# --- error paths: must fail cleanly, never hang, never emit garbage ----------
expect_fail() {
  desc="$1"; file="$2"; want="$3"
  out=$(timeout 30 "$BIN" "$file" "$TMP/never.bin" 2>&1)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    bad "$desc — HUNG (timed out); a decompressor must not loop on bad input"
  elif [ "$rc" -eq 0 ]; then
    bad "$desc — exited 0; expected a non-zero exit and an error"
  elif printf '%s' "$out" | grep -q "$want"; then
    ok "$desc (exit $rc, named the reason)"
  else
    bad "$desc — failed as expected but the message did not mention '$want': $out"
  fi
}

head -c 200000 /dev/urandom > "$TMP/big.bin"
gzip -1 -n -c "$TMP/big.bin" > "$TMP/big.gz"
head -c 5000 "$TMP/big.gz" > "$TMP/trunc.gz"
expect_fail "truncated stream"            "$TMP/trunc.gz" "end of input"

head -c 100 "$TMP/big.gz" > "$TMP/trunc2.gz"
expect_fail "severely truncated stream"   "$TMP/trunc2.gz" "end of input"

printf 'not a gzip file at all, just text' > "$TMP/notgz.bin"
expect_fail "not a gzip stream"           "$TMP/notgz.bin" "magic"

# Compressible text => gzip picks fixed Huffman. Pinning the Phase-2 boundary:
# when fixed-Huffman inflate lands, this flips and whoever lands it updates here.
printf 'hello world hello world hello world' | gzip -n -c > "$TMP/fixed.gz"
expect_fail "fixed-Huffman block (Phase 2 boundary)" "$TMP/fixed.gz" "not yet implemented"

# --- corrupted trailer: the CRC must actually be checked ---------------------
head -c 200 /dev/urandom > "$TMP/crc.bin"
gzip -1 -n -c "$TMP/crc.bin" > "$TMP/crc.gz"
sz=$(wc -c < "$TMP/crc.gz")
head -c $((sz - 8)) "$TMP/crc.gz" > "$TMP/crcbad.gz"
printf '\xde\xad\xbe\xef' >> "$TMP/crcbad.gz"
tail -c 4 "$TMP/crc.gz" >> "$TMP/crcbad.gz"
expect_fail "corrupted trailer CRC-32 is rejected" "$TMP/crcbad.gz" "CRC"

echo
echo "$pass ok, $fail failing"
[ "$fail" -eq 0 ] || exit 1
