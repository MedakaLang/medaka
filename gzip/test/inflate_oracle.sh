#!/usr/bin/env bash
# Differential oracle for the gzip library's inflater: the system `gzip` CLI
# compresses, our `gzip/inflate_demo.mdk` decompresses, and the result must be
# BYTE-FOR-BYTE identical to the original.
#
# This is the same discipline as sqlite/test/*oracle.sh — diff against the real
# tool, never against a golden captured from our own output. A golden records
# what this code did; `cmp` against the original records what is CORRECT.
#
# Phase 3 status: STORED (BTYPE=00), FIXED HUFFMAN (BTYPE=01), and DYNAMIC
# HUFFMAN (BTYPE=10) blocks all decode for real now. The old Phase-3
# boundary case (`check_dynamic_fail` — assert dynamic Huffman fails
# cleanly, naming "not yet implemented") is GONE, replaced by real
# round-trip assertions (`check_fixed`, reused for BTYPE=2 as well — it
# was already generic over the observed BTYPE, see below) plus the
# design doc's self-referential case (`compiler/seed/emitter.ll.gz`).
#
# ⚠️ We do NOT get to choose which BTYPE the system `gzip` picks — its own
# block-splitting heuristic decides, and the deciding factor is SYMBOL
# DIVERSITY, not size. Measured at -1: english-like prose tips into dynamic
# Huffman at ~200 bytes and source code at ~100, while a repeated phrase is
# still fixed at 4 KB (full table in the design doc). An earlier "~2-4 KB of
# non-random input" rule of thumb was measured only on repetitive corpora and
# does not generalize.
#
# Which is exactly why every case below ASSERTS the BTYPE it actually
# observed rather than inferring one from a size — the same discipline
# `check_stored` already used for BTYPE=00, extended to BTYPE=01/10. A gate
# that assumed the block type from an input size would silently test nothing
# the moment the heuristic disagreed.
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

# Portable timeout. NOT coreutils `timeout` — macOS has no such binary, and
# every build/test script here must run on Linux AND macOS (nothing enforces
# that: all 11 CI jobs are ubuntu-latest, so a macOS-only break ships green).
# Same shim as test/diff_compiler_engines.sh:215.
#
# ⚠️ Expiry code differs from coreutils: the shim is killed by SIGALRM and the
# shell reports 128+14 = 142, where `timeout` would report 124. Real exit codes
# pass through unchanged (measured: expiry 142, success 0, `exit 3` -> 3).
run_t() { perl -e 'alarm shift; exec @ARGV' "$@"; }

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
  run_t 60 "$BIN" "$TMP/in.gz" "$TMP/out.bin" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 142 ]; then
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

# --- Huffman round trip: real gzip output must decode byte-for-byte ---------
# Asserts BTYPE really is what `expect_bt` says (1 = fixed, 2 = dynamic)
# before trusting the round trip — same discipline as check_stored, since
# gzip's block-type choice is a heuristic we don't control. Generic over
# BOTH Huffman BTYPEs (fixed and dynamic share this one function) rather
# than forking a second near-identical copy for dynamic Huffman.
check_huffman() {
  desc="$1"; src="$2"; level="$3"; expect_bt="$4"; bt_name="$5"

  gzip -"$level" -n -c "$src" > "$TMP/fx.gz"

  bt=$(first_block_type "$TMP/fx.gz")
  if [ "$bt" != "$expect_bt" ]; then
    bad "$desc (level $level) — oracle produced BTYPE=$bt, not $bt_name (expected $expect_bt); this gate tested nothing"
    return
  fi

  run_t 60 "$BIN" "$TMP/fx.gz" "$TMP/fx.out" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 142 ]; then
    bad "$desc (level $level) — HUNG on a VALID $bt_name stream"
    return
  elif [ "$rc" -ne 0 ]; then
    bad "$desc (level $level) — inflate_demo exited $rc on a valid $bt_name stream"
    return
  fi
  if cmp -s "$src" "$TMP/fx.out"; then
    sz=$(wc -c < "$src")
    ok "$desc (level $level, $sz bytes, $bt_name, byte-for-byte)"
  else
    bad "$desc (level $level) — output DIFFERS from the original"
  fi
}

check_fixed() { check_huffman "$1" "$2" "$3" 1 "fixed Huffman"; }
check_dynamic() { check_huffman "$1" "$2" "$3" 2 "dynamic Huffman"; }

# Same shape as check_huffman, but for a pre-existing REAL .gz file (not one
# this script compresses itself) — the self-referential case, where the
# fixture is `compiler/seed/emitter.ll.gz` and there is no "original" to
# re-gzip, only the file itself and its expected inflated bytes (obtained
# from the SYSTEM `gunzip`, never from our own inflater — see the module
# header's discipline).
check_dynamic_file() {
  desc="$1"; gz="$2"; expected_plain="$3"
  # Optional 4th arg: what the expected bytes were obtained from, for the ok/
  # fail messages. Defaults to the original "system gunzip" wording (the
  # self-referential seed case below) — override it when `expected_plain`
  # came from somewhere else honest, e.g. a hand-built fixture's own known
  # plaintext, so the log never claims an oracle it didn't use.
  oracle_desc="${4:-system gunzip}"

  bt=$(first_block_type "$gz")
  if [ "$bt" != "2" ]; then
    bad "$desc — oracle input is BTYPE=$bt, not dynamic Huffman; this gate tested nothing"
    return
  fi

  run_t 60 "$BIN" "$gz" "$TMP/df.out" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 142 ]; then
    bad "$desc — HUNG on a VALID dynamic-Huffman stream"
    return
  elif [ "$rc" -ne 0 ]; then
    bad "$desc — inflate_demo exited $rc on a valid dynamic-Huffman stream"
    return
  fi
  if cmp -s "$expected_plain" "$TMP/df.out"; then
    sz=$(wc -c < "$expected_plain")
    ok "$desc ($sz bytes, dynamic Huffman, byte-for-byte vs $oracle_desc)"
  else
    bad "$desc — output DIFFERS from $oracle_desc"
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

# The design doc's corpus table names two entries this file never covered:
# the empty file (zero-length stream, BFINAL on an empty block) and the
# one-byte file (degenerate Huffman alphabets). Both are checked below with
# `check_fixed`, NOT because we assumed fixed Huffman, but because we
# verified by hand (`gzip -N -n -c` on a genuinely 0-byte and a genuinely
# 1-byte file, N = 1..9) that the system tool picks BTYPE=1 at every level
# for both — its block-splitting heuristic never has enough symbol
# diversity to justify a custom code table at this size. `check_fixed`
# itself still asserts the observed BTYPE rather than trusting this
# comment, so a future `gzip` that behaves differently would fail loudly
# here instead of silently testing nothing.
#
# `wc -c` on each fixture below is not a stray sanity check — an "empty"
# file that turned out to hold a stray newline would silently test the
# one-byte case twice and the true empty case never, exactly the harness
# bug this discipline exists to catch.
: > "$TMP/empty.bin"
[ "$(wc -c < "$TMP/empty.bin")" -eq 0 ] || bad "harness bug: empty.bin fixture is not actually empty"
check_fixed "gzip empty file (zero-length stream)" "$TMP/empty.bin" 1

printf 'x' > "$TMP/onebyte.bin"
[ "$(wc -c < "$TMP/onebyte.bin")" -eq 1 ] || bad "harness bug: onebyte.bin fixture is not exactly one byte"
check_fixed "gzip one-byte file (degenerate Huffman alphabet)" "$TMP/onebyte.bin" 1

# --- dynamic-Huffman round trip: real gzip output must decode byte-for-byte -

# 100 KB of a repeated short string. This is the design doc's own corpus
# entry for "the distance=1 overlap case, and the maximum-length code" — but
# real gzip switches to DYNAMIC Huffman well before 100 KB (verified: even
# `gzip -1` does, since its block-splitting heuristic is size-driven, not
# just entropy-driven). So at this size the real tool hands us the dynamic
# shape, not fixed — asserted (via `check_dynamic`) rather than assumed.
python3 -c "print('the quick brown fox jumps over the lazy dog. ' * 2260, end='')" > "$TMP/big_repeat.bin"
check_dynamic "100 KB repeated string, multiple dynamic blocks" "$TMP/big_repeat.bin" 6

# A real .mdk source file from this repo — realistic text, long matches; real
# gzip picks dynamic Huffman at this size too.
check_dynamic "real .mdk source file" "$ROOT/compiler/frontend/parser.mdk" 6

# A full byte-value corpus (every byte 0..255 appears) at a size/diversity
# real gzip pushes into dynamic Huffman — catches a lit/len table off-by-one
# at the 255/256 boundary that a text-only corpus above would never exercise
# (design doc's corpus table, "A file with every byte value 0-255"). Plain
# `bytes(range(256))` repeated is too REGULAR — verified by hand, gzip -6
# keeps picking fixed Huffman for it even at 10 KB (its heuristic is
# entropy-driven, not just "is every byte value present") — so this mixes in
# shuffled-word text ahead of three literal 0..255 sweeps to get real
# symbol-diversity pressure while still guaranteeing full byte coverage.
python3 -c "
import sys, random
random.seed(7)
words = ['the', 'quick', 'brown', 'fox', 'jumps', 'over', 'lazy', 'dog',
         'medaka', 'gzip', 'deflate', 'huffman', 'dynamic', 'static', 'compress']
lines = []
for i in range(400):
    random.shuffle(words)
    lines.append(' '.join(words))
text = ('\n'.join(lines)).encode()
data = text + bytes(range(256)) * 3
sys.stdout.buffer.write(data)
" > "$TMP/allbytes.bin"
check_dynamic "every byte value 0..255 present, mixed with diverse text" "$TMP/allbytes.bin" 6

# --- dynamic Huffman with ZERO used distance codes (numUsed==0) -------------
# The design doc's "one byte" corpus entry was originally meant to exercise a
# degenerate Huffman alphabet, but its real observed shape is BTYPE=1 (fixed
# Huffman, no alphabet construction at all) — see the two check_fixed cases
# above and GZIP-DESIGN.md's corrected corpus-table row. This is the case
# that actually exercises PR #1332's `kraftCheck` widening to accept
# `numUsed == 0` (an alphabet with every code length zero — the shape the
# DISTANCE alphabet takes when a dynamic block is all-literals, no
# back-references at all): RFC 1951 §3.2.7 permits HDIST's one required code
# to have length zero, meaning "no distance codes used at all."
#
# Neither the system `gzip` nor Python's `zlib` (any strategy, including
# Z_HUFFMAN_ONLY which disables LZ77 matching outright) ever produces this
# shape — zlib's own encoder pads the distance tree to at least 2 real codes
# whenever usage is 0 or 1 ("to avoid special checks later on", its own
# trees.c comment). So this fixture is hand-built by
# gen_zerodist_fixture.py: a from-scratch canonical-Huffman encoder over a
# shuffled permutation of all 256 byte values (every literal used exactly
# once, no repeated bytes to back-reference), with the distance alphabet's
# single required code explicitly given length 0.
#
# The generator independently VERIFIES its own construction two ways before
# writing anything: (1) its own bit-level reader decodes the block header
# back and asserts BTYPE really is 10 (dynamic) and the distance code table
# really has zero used codes — not assumed, checked; (2) Python's own
# `zlib.decompressobj` (NOT our inflater) independently confirms the hand
# built bytes decode to the exact plaintext used to build them. Both are
# printed to stderr for this gate's log.
python3 "$ROOT/gzip/test/gen_zerodist_fixture.py" "$TMP/zerodist.gz" "$TMP/zerodist.expected" \
  || { bad "zero-distance-code fixture generator failed (see stderr above)"; }
if [ -s "$TMP/zerodist.gz" ]; then
  check_dynamic_file "dynamic Huffman with zero used distance codes (numUsed==0, all-literal block)" \
    "$TMP/zerodist.gz" "$TMP/zerodist.expected" \
    "the known plaintext the fixture was hand-built from (independently cross-checked with Python's zlib.decompressobj, never our own inflater)"
fi

# Just over the 32768-byte window boundary — catches an off-by-one in the
# sliding-window wrap logic that a smaller corpus would never reach (design
# doc's corpus table, "A file just over 32768 bytes").
python3 -c "
import sys
data = (b'window boundary probe, ' * 2000)[:32800]
sys.stdout.buffer.write(data)
" > "$TMP/window_boundary.bin"
check_dynamic "just over the 32768-byte window boundary" "$TMP/window_boundary.bin" 6

# The committed seed itself: ~1.7 MB of real dynamic-Huffman data, already in
# the repo, no fixture to add (design doc §"Self-referential"). Decoded with
# OUR inflater, checked against the SYSTEM `gunzip`'s own decompression of
# the exact same bytes — never against a golden captured from our own code.
SEED_GZ="$ROOT/compiler/seed/emitter.ll.gz"
if [ -f "$SEED_GZ" ]; then
  gunzip -c "$SEED_GZ" > "$TMP/seed_expected.bin"
  check_dynamic_file "compiler/seed/emitter.ll.gz (self-referential, real-world corpus)" "$SEED_GZ" "$TMP/seed_expected.bin"
else
  bad "compiler/seed/emitter.ll.gz not found at $SEED_GZ"
fi

# --- error paths: must fail cleanly, never hang, never emit garbage ----------
expect_fail() {
  desc="$1"; file="$2"; want="$3"
  out=$(run_t 30 "$BIN" "$file" "$TMP/never.bin" 2>&1)
  rc=$?
  if [ "$rc" -eq 142 ]; then
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

# --- dynamic-Huffman error paths: truncation and CRC corruption, the design
# doc's corpus-table pair this Phase makes reachable for real (before Phase
# 3 there was no dynamic-Huffman DECODE path to truncate/corrupt into) -----
gzip -6 -n -c "$ROOT/compiler/frontend/parser.mdk" > "$TMP/dyn.gz"
bt=$(first_block_type "$TMP/dyn.gz")
if [ "$bt" != "2" ]; then
  bad "dynamic-Huffman error-path setup — oracle produced BTYPE=$bt, not dynamic Huffman; these cases tested nothing"
else
  dynsz=$(wc -c < "$TMP/dyn.gz")

  # Truncated well into the compressed body (past the header, mid-Huffman
  # tables or mid-block) — must Err, not hang, not read out of bounds.
  head -c $((dynsz / 2)) "$TMP/dyn.gz" > "$TMP/dyn_trunc_mid.gz"
  expect_fail "dynamic Huffman: truncated mid-stream (half the file)" "$TMP/dyn_trunc_mid.gz" "end of input"

  # Truncated immediately after the gzip header, inside the dynamic block's
  # HLIT/HDIST/HCLEN/code-length-table region itself — the narrowest place
  # this Phase's new code can read out of bounds if it's going to.
  head -c 15 "$TMP/dyn.gz" > "$TMP/dyn_trunc_header.gz"
  expect_fail "dynamic Huffman: truncated inside the HLIT/HDIST/HCLEN header" "$TMP/dyn_trunc_header.gz" "end of input"

  # Corrupted trailer CRC-32 on a real dynamic-Huffman stream (distinct from
  # the stored-block CRC case above, which never exercises this Phase's
  # decode path at all).
  corrupt_last4 "$TMP/dyn.gz" "$TMP/dyn_crcbad.gz" $((dynsz - 8))
  tail -c 4 "$TMP/dyn.gz" >> "$TMP/dyn_crcbad.gz"
  if [ "$(wc -c < "$TMP/dyn_crcbad.gz")" -ne "$dynsz" ]; then
    bad "harness bug: corrupting the dynamic-Huffman CRC changed the file LENGTH"
  else
    expect_fail "dynamic Huffman: corrupted trailer CRC-32 is rejected" "$TMP/dyn_crcbad.gz" "CRC"
  fi
fi

echo
echo "$pass ok, $fail failing"
[ "$fail" -eq 0 ] || exit 1
