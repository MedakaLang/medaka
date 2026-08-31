#!/usr/bin/env bash
# Differential oracle for the gzip library's deflater (Phase 4,
# `gzip/lib/deflate.mdk`): our `gzip/deflate_demo.mdk` compresses, the
# SYSTEM `gunzip` decompresses, and the result must be BYTE-FOR-BYTE
# identical to the original. This is the load-bearing proof of RFC
# conformance — see `docs/design/GZIP-DESIGN.md` §"Compression (Phases
# 4-5)" and `gzip/lib/deflate.mdk`'s own module header: matching zlib's
# exact bit stream is an explicit non-goal, so "the system gunzip accepts
# it and reproduces the input" is the only correctness bar.
#
# Same discipline as `gzip/test/inflate_oracle.sh` and `sqlite/test/*
# oracle.sh` — diff against the real tool, never against a golden captured
# from our own output.
#
# This script ALSO runs an internal `inflate (deflate x) == x` round trip
# (via `gzip/inflate_demo.mdk`, our OWN decompressor) for every corpus file,
# clearly labeled: that direction proves only SELF-CONSISTENCY, never
# conformance — our deflater and inflater share this file tree, so a bug
# both sides agree on (a shared misreading of the RFC) would round-trip
# cleanly there while the real `gunzip` rejected the output outright. The
# `gunzip`-acceptance checks are the ones that gate this script's exit code
# on their own; the internal round trip is checked too (and reported), but
# is a fast-fail sanity signal, not the proof.
#
# Corpus (see `docs/design/GZIP-DESIGN.md`'s corpus table for why each entry
# is here — reasons repeated inline at each case below):
#   - empty file
#   - one byte
#   - 100 KB of one repeated byte (distance=1 self-overlapping match, and
#     the maximum-length code)
#   - /dev/urandom output (must fall back to stored blocks; must NOT grow
#     beyond input size + a small fixed overhead)
#   - a real .mdk source file from this repo
#   - a file containing every byte value 0-255 (catches a lit/len table
#     off-by-one at the 255/256 boundary)
#   - a file just over 32768 bytes (the sliding-window boundary)
#
# ⚠️ No golden is ever captured from our own encoder's output here. Every
# assertion is either `cmp` against the original input, or the system
# `gzip`/`gunzip` tool's own behavior (its exit code, or decoding OUR
# output). Capturing our own output as a golden would enshrine an encoder
# bug as the expected answer — see `gzip/README.md` "Testing policy".
set -u

ROOT="${MEDAKA_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
export MEDAKA_ROOT="$ROOT"

command -v gzip >/dev/null 2>&1 || { echo "SKIP-AS-FAIL: gzip not found (this gate's oracle)"; exit 1; }
[ -x "$MEDAKA" ] || { echo "FAIL: no native medaka at $MEDAKA (build it first)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DEFLATE_BIN="$TMP/deflate_demo"
INFLATE_BIN="$TMP/inflate_demo"

"$MEDAKA" build "$ROOT/gzip/deflate_demo.mdk" -o "$DEFLATE_BIN" >/dev/null 2>&1 \
  || { echo "FAIL: could not build gzip/deflate_demo.mdk"; exit 1; }
"$MEDAKA" build "$ROOT/gzip/inflate_demo.mdk" -o "$INFLATE_BIN" >/dev/null 2>&1 \
  || { echo "FAIL: could not build gzip/inflate_demo.mdk"; exit 1; }

pass=0
fail=0

ok()   { pass=$((pass + 1)); echo "ok   $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL $1"; }

# Portable timeout — NOT coreutils `timeout` (absent on macOS; every script
# here must run on both, and nothing in CI enforces that — see AGENTS.md).
# Same shim as gzip/test/inflate_oracle.sh:72 / test/diff_compiler_engines.sh:215.
# ⚠️ Expiry reports 142 (SIGALRM), not coreutils' 124 — real exit codes pass
# through unchanged.
run_t() { perl -e 'alarm shift; exec @ARGV' "$@"; }

# ── Per-input time budget (#2275) ────────────────────────────────────────────
#
# This helper used to be a flat `run_t 60` for every case, across a corpus
# spanning 0 bytes to the 15,899,967-byte seed. That constant was ~1.19x the
# largest case's real time and reddened `gates_8` on a slow runner:
#
#   deflate of the 15.9 MB seed, this box, quiet, warm binary, 3 runs:
#     49.8s / 49.8s / 50.9s   (~318 KB/s)
#
# A GitHub runner is materially slower than this box — the run that failed had
# `gates_4` at 11m21s against its usual ~6m, i.e. ~1.9x — so 60s could not hold.
#
# The budget is now derived from the INPUT SIZE against a deliberately
# pessimistic floor rate, so it states its assumption instead of hiding it:
#
#   budget = 30s fixed  +  1s per 100 KB of input
#
# For the seed that is 30 + 158 = 188s, ~3.7x the measured time — room for a
# runner several times slower than this box, while still bounding a real hang.
# For every small case it is ~30s, unchanged in spirit from the old constant.
#
# ⚠️ If deflate gets FASTER, this budget does not need revisiting; if it gets
# SLOWER, the right response is to ask why (~318 KB/s is itself worth a look —
# tracked separately as the perf half of #2275), not to raise the floor rate.
budget_for() {
  # $1 = input size in bytes
  echo $(( 30 + $1 / 100000 ))
}

# The system `gunzip -t` step is orders of magnitude faster than our deflater
# (system gunzip of this same seed is well under a second), so it keeps a flat,
# generous constant rather than a derived one.
SYS_BUDGET=60

# The real proof: deflate with OURS, gunzip with the SYSTEM tool, cmp
# against the original. `desc`/`src` identify the case; `max_overhead`, if
# given (bytes), additionally asserts the compressed size never exceeds
# `input size + max_overhead` — the "must not grow" guarantee
# (`gzip/lib/deflate.mdk`'s stored-block fallback bound: `n + 5 *
# ceil(n/65535)` for the DEFLATE payload, plus the fixed 18-byte gzip
# container overhead (10-byte header + 8-byte trailer) this module always
# emits — so `max_overhead` should be `18 + 5 * ceil(n/65535)`, computed per
# case below since it depends on `n`).
check_gunzip() {
  desc="$1"; src="$2"; max_overhead="${3:-}"

  insz_pre=$(wc -c < "$src")
  budget=$(budget_for "$insz_pre")

  run_t "$budget" "$DEFLATE_BIN" "$src" "$TMP/out.gz" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 142 ]; then
    # NOT "HUNG" — a budget breach is a cost verdict, not a liveness one, and
    # calling it a hang sends the reader hunting an infinite loop that is not
    # there (#2275). Say which number was exceeded so the next reader can tell
    # a slow runner from a real regression without re-deriving the budget.
    bad "$desc — deflate_demo exceeded its ${budget}s budget for $insz_pre bytes (see budget_for; NOT necessarily a hang — a slow runner reads the same)"
    return
  elif [ "$rc" -ne 0 ]; then
    bad "$desc — deflate_demo exited $rc"
    return
  fi

  run_t "$SYS_BUDGET" gunzip -t "$TMP/out.gz" >/dev/null 2>&1
  grc=$?
  if [ "$grc" -eq 142 ]; then
    bad "$desc — system gunzip -t exceeded its ${SYS_BUDGET}s budget on our output"
    return
  elif [ "$grc" -ne 0 ]; then
    bad "$desc — system gunzip -t REJECTED our output (rc=$grc); not RFC-conformant"
    return
  fi

  gunzip -c "$TMP/out.gz" > "$TMP/roundtrip.out" 2>/dev/null
  if ! cmp -s "$src" "$TMP/roundtrip.out"; then
    bad "$desc — system gunzip decoded our output but bytes DIFFER from the original"
    return
  fi

  insz=$(wc -c < "$src")
  outsz=$(wc -c < "$TMP/out.gz")

  if [ -n "$max_overhead" ]; then
    limit=$((insz + max_overhead))
    if [ "$outsz" -gt "$limit" ]; then
      bad "$desc — output GREW beyond the stored-fallback bound: $outsz bytes for $insz input (limit $limit)"
      return
    fi
  fi

  ok "$desc (in=$insz out=$outsz, gunzip -t=0, byte-for-byte)"
}

# The cheap fast-fail: our OWN inflater on our OWN deflater's output.
# Self-consistency ONLY — see this script's own header. Reported separately
# from `check_gunzip` (which alone gates this script's exit code) so a
# divergence between the two proofs is itself informative: if `gunzip`
# accepts our output but our OWN inflater doesn't reproduce it identically,
# that is a bug in the INFLATER (or a shared misunderstanding neither
# direction would catch alone).
check_self_roundtrip() {
  desc="$1"; src="$2"

  budget=$(budget_for "$(wc -c < "$src")")

  run_t "$budget" "$DEFLATE_BIN" "$src" "$TMP/self.gz" >/dev/null 2>&1 || {
    bad "$desc (self round-trip) — deflate_demo failed"
    return
  }
  run_t "$budget" "$INFLATE_BIN" "$TMP/self.gz" "$TMP/self.out" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$desc (self round-trip, SELF-CONSISTENCY ONLY) — our OWN inflate_demo rejected our OWN deflate_demo's output (rc=$rc)"
    return
  fi
  if cmp -s "$src" "$TMP/self.out"; then
    ok "$desc (self round-trip, SELF-CONSISTENCY ONLY — not a conformance proof)"
  else
    bad "$desc (self round-trip, SELF-CONSISTENCY ONLY) — our own inflate_demo output DIFFERS from the original"
  fi
}

# --- corpus -------------------------------------------------------------

# Empty file: zero-length stream, BFINAL on an empty block.
printf '' > "$TMP/empty.bin"
check_gunzip "empty file" "$TMP/empty.bin" 25
check_self_roundtrip "empty file" "$TMP/empty.bin"

# One byte: degenerate Huffman alphabets.
printf 'A' > "$TMP/one.bin"
check_gunzip "one byte" "$TMP/one.bin" 25
check_self_roundtrip "one byte" "$TMP/one.bin"

# 100 KB of one repeated byte: the distance=1 self-overlapping match case,
# and the maximum-length (258) code — this content is HIGHLY compressible,
# so no "must not grow" bound is asserted here (that bound is for
# incompressible content, below).
python3 -c "import sys; sys.stdout.buffer.write(b'z' * 100000)" > "$TMP/rle.bin" 2>/dev/null \
  || perl -e 'print "z" x 100000' > "$TMP/rle.bin"
check_gunzip "100 KB of one repeated byte (distance=1 RLE)" "$TMP/rle.bin"
check_self_roundtrip "100 KB of one repeated byte (distance=1 RLE)" "$TMP/rle.bin"

# /dev/urandom output: incompressible input MUST fall back to stored
# blocks and must NOT grow beyond the exact bound `deflate`'s module header
# proves: DEFLATE payload <= n + 5*ceil(n/65535), plus the fixed 18-byte
# gzip container. For n=50000 (one stored chunk): 18 + 5*1 = 23.
head -c 50000 /dev/urandom > "$TMP/rand.bin"
check_gunzip "50000 bytes of /dev/urandom (incompressible, must not grow)" "$TMP/rand.bin" 23
check_self_roundtrip "50000 bytes of /dev/urandom" "$TMP/rand.bin"

# A larger /dev/urandom file spanning FOUR stored chunks (>65535 bytes):
# ceil(200000 / 65535) = 4, so 18 + 5*4 = 38.
head -c 200000 /dev/urandom > "$TMP/rand_big.bin"
check_gunzip "200000 bytes of /dev/urandom (incompressible, multi-chunk stored, must not grow)" "$TMP/rand_big.bin" 38
check_self_roundtrip "200000 bytes of /dev/urandom (multi-chunk stored)" "$TMP/rand_big.bin"

# A real .mdk source file from this repo: realistic text, long matches,
# real dynamic-Huffman territory for the SYSTEM gzip (irrelevant to us —
# we only ever emit fixed/stored — but real text is exactly the shape that
# exercises the LZ77 matcher's hash chains and lazy matching for real).
check_gunzip "real .mdk source file (compiler/frontend/parser.mdk)" "$ROOT/compiler/frontend/parser.mdk"
check_self_roundtrip "real .mdk source file (compiler/frontend/parser.mdk)" "$ROOT/compiler/frontend/parser.mdk"

# A second, larger real .mdk source file, for more LZ77 mileage.
check_gunzip "real .mdk source file (compiler/types/typecheck.mdk)" "$ROOT/compiler/types/typecheck.mdk"
check_self_roundtrip "real .mdk source file (compiler/types/typecheck.mdk)" "$ROOT/compiler/types/typecheck.mdk"

# Every byte value 0-255 present: catches a lit/len table off-by-one at the
# 255/256 boundary. Repeated a few times so there is SOME structure for the
# matcher to find (a single 256-byte sweep has zero 3-byte repeats by
# construction, which is a fine but less interesting case) — repetition
# also, incidentally, tests very-nearby matches (distance 256) cleanly.
python3 -c "import sys; sys.stdout.buffer.write(bytes(range(256)) * 8)" > "$TMP/allbytes.bin" 2>/dev/null \
  || { for i in $(seq 1 8); do head -c 256 /dev/zero | tr '\0' '\001' >> "$TMP/allbytes.bin"; done; }
check_gunzip "every byte value 0-255 present (x8)" "$TMP/allbytes.bin"
check_self_roundtrip "every byte value 0-255 present (x8)" "$TMP/allbytes.bin"

# A file just over the 32768-byte window boundary: catches an off-by-one in
# the sliding-window wrap logic (our matcher's `windowSize` bound in
# `findMatchChain`) that a smaller corpus would never reach.
python3 -c "
import sys
data = (b'window boundary probe, ' * 2000)[:32800]
sys.stdout.buffer.write(data)
" > "$TMP/window.bin" 2>/dev/null || perl -e 'print "window boundary probe, " x 2000' | head -c 32800 > "$TMP/window.bin"
check_gunzip "just over the 32768-byte window boundary" "$TMP/window.bin"
check_self_roundtrip "just over the 32768-byte window boundary" "$TMP/window.bin"

# The committed seed itself: 15,899,967 bytes of real, already-in-the-repo data —
# no fixture to add, and a genuinely large real-world input (matches the
# design doc's "self-referential" case for the inflate oracle; there is no
# gzip-of-a-gzip equivalent here, so this just re-compresses the SEED'S OWN
# decompressed bytes, obtained via the system `gunzip`, never via our own
# inflater).
SEED_GZ="$ROOT/compiler/seed/emitter.ll.gz"
if [ -f "$SEED_GZ" ]; then
  gunzip -c "$SEED_GZ" > "$TMP/seed_plain.bin"
  check_gunzip "compiler/seed/emitter.ll.gz's decompressed bytes (self-referential, real-world corpus)" "$TMP/seed_plain.bin"
else
  bad "compiler/seed/emitter.ll.gz not found at $SEED_GZ"
fi

echo
echo "$pass ok, $fail failing"
[ "$fail" -eq 0 ] || exit 1
