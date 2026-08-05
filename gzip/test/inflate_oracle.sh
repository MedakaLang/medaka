#!/usr/bin/env bash
# Differential oracle for the gzip library's inflater: the system `gzip` CLI
# compresses, our `gzip/inflate_demo.mdk` decompresses, and the result must be
# BYTE-FOR-BYTE identical to the original.
#
# This is the same discipline as sqlite/test/*oracle.sh — diff against the real
# tool, never against a golden captured from our own output. A golden records
# what this code did; `cmp` against the original records what is CORRECT.
#
# Phase 2 status: STORED (BTYPE=00) and FIXED HUFFMAN (BTYPE=01) blocks both
# decode for real now. DYNAMIC HUFFMAN (BTYPE=10) is still Phase 3 and is
# asserted to fail cleanly with a named error — that is the honest Phase-3
# boundary, and pinning it means the eventual implementation flips this gate
# red and tells whoever lands it to come update this file (same trick the
# Phase-2 boundary used against this same file, until this wave landed it).
#
# ⚠️ We do NOT get to choose which BTYPE the system `gzip` picks for a given
# input — its own heuristics decide, and they are aggressive: anything much
# past ~2-4 KB of non-random input reliably tips into dynamic Huffman, even
# at `-1`. So every case below ASSERTS which BTYPE it actually observed
# rather than assuming — the same discipline `check_stored` already used for
# BTYPE=00, extended to BTYPE=01/02.
#
# There is no `gzip -0`; the levels are -1..-9. See `check_stored`'s own
# comment for the stored-block derivation this file inherited unchanged.
#
# Run from the repo root or anywhere; requires: gzip, python3 (for robust
# gzip-header parsing — real `.gz` files may carry FNAME/FEXTRA/FCOMMENT
# fields, which `-n`-generated fixtures don't, so a fixed byte-10 offset
# is not safe in general), a built native `medaka` (../medaka) + its
# emitter, MEDAKA_ROOT pointing at the repo root.
set -u

ROOT="${MEDAKA_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
export MEDAKA_ROOT="$ROOT"

command -v gzip >/dev/null 2>&1 || { echo "SKIP-AS-FAIL: gzip not found (this gate's oracle)"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP-AS-FAIL: python3 not found (needed for gzip-header parsing)"; exit 1; }
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

# The first DEFLATE block's BTYPE (0/1/2/3), robust to gzip header
# variations (FEXTRA/FNAME/FCOMMENT/FHCRC) that a fixed byte-10 offset
# would get wrong on a real-world `.gz` not produced with `-n`.
first_block_type() {
  python3 - "$1" <<'EOF'
import sys
data = open(sys.argv[1], "rb").read()
assert data[0] == 0x1F and data[1] == 0x8B, "not a gzip file"
flg = data[3]
off = 10
if flg & 4:
    xlen = data[off] | (data[off + 1] << 8)
    off += 2 + xlen
if flg & 8:
    while data[off] != 0:
        off += 1
    off += 1
if flg & 16:
    while data[off] != 0:
        off += 1
    off += 1
if flg & 2:
    off += 2
b = data[off]
print((b >> 1) & 3)
EOF
}

# --- stored-block round trip: real gzip output must decode byte-for-byte ------
# Also asserts the stream really IS a stored block, so this can never silently
# degrade into "we tested a shape the inflater rejects anyway".
check_stored() {
  desc="$1"; size="$2"
  head -c "$size" /dev/urandom > "$TMP/in.bin"
  gzip -1 -n -c "$TMP/in.bin" > "$TMP/in.gz"

  bt=$(first_block_type "$TMP/in.gz")
  if [ "$bt" != "0" ]; then
    bad "$desc — oracle produced BTYPE=$bt, not a stored block; this gate tested nothing"
    return
  fi

  # Under `timeout` like the error paths: a decompressor that loops on VALID
  # input is just as much a defect, and an unbounded success path would hang
  # this gate rather than fail it.
  timeout 60 "$BIN" "$TMP/in.gz" "$TMP/out.bin" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 124 ]; then
    bad "$desc — HUNG on a VALID stored stream"
    return
  elif [ "$rc" -ne 0 ]; then
    bad "$desc — inflate_demo exited $rc on a valid stored stream"
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

# --- fixed-Huffman round trip: real gzip output must decode byte-for-byte ----
# Asserts BTYPE really is 1 (fixed Huffman) before trusting the round trip —
# same discipline as check_stored, since gzip's block-type choice is a
# heuristic we don't control.
check_fixed() {
  desc="$1"; src="$2"; level="$3"
  gzip -"$level" -n -c "$src" > "$TMP/fx.gz"

  bt=$(first_block_type "$TMP/fx.gz")
  if [ "$bt" != "1" ]; then
    bad "$desc (level $level) — oracle produced BTYPE=$bt, not fixed Huffman; this gate tested nothing"
    return
  fi

  timeout 60 "$BIN" "$TMP/fx.gz" "$TMP/fx.out" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 124 ]; then
    bad "$desc (level $level) — HUNG on a VALID fixed-Huffman stream"
    return
  elif [ "$rc" -ne 0 ]; then
    bad "$desc (level $level) — inflate_demo exited $rc on a valid fixed-Huffman stream"
    return
  fi
  if cmp -s "$src" "$TMP/fx.out"; then
    sz=$(wc -c < "$src")
    ok "$desc (level $level, $sz bytes, fixed Huffman, byte-for-byte)"
  else
    bad "$desc (level $level) — output DIFFERS from the original"
  fi
}

# --- dynamic-Huffman boundary: must fail cleanly, naming Phase 3 -------------
# Asserts BTYPE really is 2 (dynamic Huffman) — a gate that "passed" because
# gzip happened to pick a DIFFERENT block type would be testing nothing.
check_dynamic_fail() {
  desc="$1"; gz="$2"
  bt=$(first_block_type "$gz")
  if [ "$bt" != "2" ]; then
    bad "$desc — oracle produced BTYPE=$bt, not dynamic Huffman; this gate tested nothing"
    return
  fi
  out=$(timeout 30 "$BIN" "$gz" "$TMP/never.bin" 2>&1)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    bad "$desc — HUNG (timed out); a decompressor must not loop on bad/unimplemented input"
  elif [ "$rc" -eq 0 ]; then
    bad "$desc — exited 0; expected the Phase-3 dynamic-Huffman error"
  elif printf '%s' "$out" | grep -q "not yet implemented"; then
    ok "$desc (exit $rc, dynamic Huffman, named the Phase-3 boundary)"
  else
    bad "$desc — failed as expected but did not name Phase 3: $out"
  fi
}

# Small compressible text ("hello world" x3, 35 bytes) — the design doc's own
# Phase 2 oracle shape (§"Fixed Huffman"). Verified: `gzip -N -n -c` on this
# exact string is BTYPE=1 at every level 1..9 (checked by hand while writing
# this gate), so the level loop below exercises the SAME real boundary
# `check_fixed` itself asserts, rather than assuming it.
printf 'hello world hello world hello world' > "$TMP/hw.bin"
for lvl in 1 2 3 4 5 6 7 8 9; do
  check_fixed "gzip -$lvl small compressible text" "$TMP/hw.bin" "$lvl"
done

# `printf 'hello' | gzip -n -c` — the exact bytes `gzip/main.mdk` documents as
# BFINAL=1 BTYPE=1 (fixed Huffman) for input this small.
printf 'hello' > "$TMP/hello.bin"
check_fixed "gzip -n hello (documented BFINAL=1 BTYPE=1 shape)" "$TMP/hello.bin" 6

# 2000 bytes of a single repeated byte — real gzip output, still fixed
# Huffman at this size (verified by hand: BTYPE flips to dynamic only past
# ~2-5 KB for this content). This is the DISTANCE=1 overlap case run through
# the real decoder end to end, not just `copyBack`'s own unit tests: nearly
# the whole block is one long run-length back-reference chain.
python3 -c "import sys; sys.stdout.buffer.write(b'a' * 2000)" > "$TMP/rle.bin"
check_fixed "gzip 2000 bytes of one repeated byte (distance=1 RLE)" "$TMP/rle.bin" 1

# 2000 bytes of a repeated short phrase — real gzip output, still fixed
# Huffman at this size, exercising longer (distance>1) back-references than
# the pure-RLE case above.
python3 -c "import sys; sys.stdout.write(('the quick brown fox ' * 200)[:2000])" > "$TMP/phrase.bin"
check_fixed "gzip 2000 bytes of a repeated phrase (long back-references), level 1" "$TMP/phrase.bin" 1
check_fixed "gzip 2000 bytes of a repeated phrase (long back-references), level 9" "$TMP/phrase.bin" 9

# --- Phase 3 boundary: dynamic Huffman is pinned as NOT yet implemented ------

# 100 KB of a repeated short string. This is the design doc's own corpus
# entry for "the distance=1 overlap case, and the maximum-length code" — but
# real gzip switches to DYNAMIC Huffman well before 100 KB (verified: even
# `gzip -1` does, since its block-splitting heuristic is size-driven, not
# just entropy-driven). So at this size the real tool hands us the Phase 3
# shape, not Phase 2 — asserted below rather than assumed.
python3 -c "print('the quick brown fox jumps over the lazy dog. ' * 2260, end='')" > "$TMP/big_repeat.bin"
gzip -6 -n -c "$TMP/big_repeat.bin" > "$TMP/big_repeat.gz"
check_dynamic_fail "100 KB repeated string (Phase 3 boundary)" "$TMP/big_repeat.gz"

# A real .mdk source file from this repo — realistic text, long matches; real
# gzip picks dynamic Huffman at this size too.
gzip -6 -n -c "$ROOT/compiler/frontend/parser.mdk" > "$TMP/mdk_source.gz"
check_dynamic_fail "real .mdk source file (Phase 3 boundary)" "$TMP/mdk_source.gz"

# The committed seed itself: ~1.7 MB of real dynamic-Huffman data, already in
# the repo, no fixture to add (design doc §"Self-referential").
SEED_GZ="$ROOT/compiler/seed/emitter.ll.gz"
if [ -f "$SEED_GZ" ]; then
  check_dynamic_fail "compiler/seed/emitter.ll.gz (real-world corpus, Phase 3 boundary)" "$SEED_GZ"
else
  bad "compiler/seed/emitter.ll.gz not found at $SEED_GZ"
fi

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

# --- corrupted trailer: the CRC must actually be checked ---------------------
# ⚠️ OCTAL escapes, not \xNN. /bin/sh here is dash, whose printf does NOT
# interpret \xNN — it emits the 16 LITERAL characters `\xde\xad\xbe\xef`.
# That silently appends 16 junk bytes instead of replacing 4, which lengthens
# the file and shifts the whole trailer. The CRC case below still "passed"
# that way, for entirely the wrong reason, until an ISIZE case was added and
# failed with a CRC error that made no sense. Measured: hex-escape append
# grew a 223-byte file to 235; octal-escape kept it at 223.
# Guard it rather than trusting the comment — see the size assertion below.
corrupt_last4() {
  src="$1"; dst="$2"; keep="$3"
  head -c "$keep" "$src" > "$dst"
  printf '\336\255\276\357' >> "$dst"
}

head -c 200 /dev/urandom > "$TMP/crc.bin"
gzip -1 -n -c "$TMP/crc.bin" > "$TMP/crc.gz"
sz=$(wc -c < "$TMP/crc.gz")

corrupt_last4 "$TMP/crc.gz" "$TMP/crcbad.gz" $((sz - 8))
tail -c 4 "$TMP/crc.gz" >> "$TMP/crcbad.gz"
if [ "$(wc -c < "$TMP/crcbad.gz")" -ne "$sz" ]; then
  bad "harness bug: corrupting the CRC changed the file LENGTH ($(wc -c < "$TMP/crcbad.gz") vs $sz) — printf escapes are not producing raw bytes"
else
  expect_fail "corrupted trailer CRC-32 is rejected" "$TMP/crcbad.gz" "CRC"
fi

# ISIZE is the OTHER half of the trailer and is checked independently of the
# CRC. Corrupt only the last 4 bytes, leaving the CRC-32 intact, so a
# gunzipMember that validated the checksum but merely computed the length
# would pass the case above and fail here. A field that is computed but never
# compared is decoration, and nothing else in this suite would notice.
corrupt_last4 "$TMP/crc.gz" "$TMP/isizebad.gz" $((sz - 4))
if [ "$(wc -c < "$TMP/isizebad.gz")" -ne "$sz" ]; then
  bad "harness bug: corrupting ISIZE changed the file LENGTH ($(wc -c < "$TMP/isizebad.gz") vs $sz)"
else
  expect_fail "corrupted trailer ISIZE is rejected" "$TMP/isizebad.gz" "ISIZE"
fi

echo
echo "$pass ok, $fail failing"
[ "$fail" -eq 0 ] || exit 1
