#!/usr/bin/env bash
# diff_gzip.sh — WasmGC-vs-native engine parity gate for the gzip library's
# inflater.
#
# Per docs/design/GZIP-DESIGN.md §"Engine parity": the DEFLATE codec is pure
# integer and array work with no platform surface beyond file IO, so it should
# decode IDENTICALLY under the native LLVM backend and the WasmGC backend. Any
# divergence between the two on the SAME `.gz` input is a backend bug in bit
# manipulation — the two-opposite-bit-orders format (LSB-first bit stream,
# MSB-first Huffman codes) is exactly the kind of workload the 3-engine
# differential (test/diff_compiler_engines.sh) has never had to find one with.
#
# Structure and toolchain-degrade discipline mirror test/wasm/diff_sqlite.sh —
# its sibling in the same directory. Difference: sqlite's corpus is many small
# probe *programs* (one build each); gzip's corpus is many *inputs* to ONE
# program (gzip/inflate_demo.mdk), so the two builds (native, wasm) happen
# ONCE up front and only the per-input RUNS are fanned out.
#
# We do NOT capture goldens of our own output (GZIP-DESIGN.md's standing
# discipline: a captured golden records what our codec did, not what is
# correct). Every SUCCESS case below is checked against the ORIGINAL bytes
# (produced independently by the system `gzip`, or read straight off disk for
# the self-referential seed case) as well as against the other engine — so a
# case where both engines agree but are both wrong cannot pass silently.
#
# Reports N/M passing; non-zero exit on any mismatch. Opt-in skip (exit 2)
# when the toolchain (wasm-tools / Node>=22 / clang) is unavailable — printed
# in a form that cannot be mistaken for a pass (see the toolchain checks
# below; "not on PATH" / "no C compiler" match run_gates.sh's LEGIT_SKIP_RE).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
WASM_EMITTER="$ROOT/test/bin/wasm_emit_modules_main"
RUNJS="$ROOT/test/wasm/run.js"
CC="${CC:-clang}"
DEMO="$ROOT/gzip/inflate_demo.mdk"

# Portable timeout (no coreutils `timeout` on macOS) — same shim as
# test/diff_compiler_engines.sh and gzip/test/inflate_oracle.sh. Exit 142
# (128+SIGALRM) signals "hung"; real exit codes pass through unchanged.
run_t() { perl -e 'alarm shift; exec @ARGV' "$@"; }

# ── Per-case worker (parallel fan-out target) ──────────────────────────────
# Re-invoked as `bash "$0" --one <success|error> <name> <gz-path> [expected-path]`
# under an xargs -P pool. Builds are already done (native/wasm binaries passed
# via env); each worker only RUNS both engines on one input and compares.
if [ "${1:-}" = "--one" ]; then
  mode="$2"; name="$3"; gz="$4"; expected="${5:-}"
  [ "$expected" = "-" ] && expected=""
  nout="$WORKDIR/$name.native.out"
  wout="$WORKDIR/$name.wasm.out"
  st=0; msg=""

  run_t 60 "$NATIVE_BIN" "$gz" "$nout" >"$WORKDIR/$name.native.log" 2>&1
  nrc=$?
  MDK_ARGS="$gz $wout" run_t 60 "$NODE" "$RUNJS" "$WASM_BIN" >"$WORKDIR/$name.wasm.log" 2>&1
  wrc=$?

  if [ "$mode" = success ]; then
    if [ "$nrc" -eq 142 ] || [ "$wrc" -eq 142 ]; then
      msg="FAIL $name — HUNG on a valid stream (native rc=$nrc wasm rc=$wrc)"; st=1
    elif [ "$nrc" -ne 0 ] || [ "$wrc" -ne 0 ]; then
      msg="$(printf 'FAIL %s — expected both engines to succeed (native rc=%s wasm rc=%s)\n  --- native log ---\n%s\n  --- wasm log ---\n%s' \
        "$name" "$nrc" "$wrc" "$(cat "$WORKDIR/$name.native.log")" "$(cat "$WORKDIR/$name.wasm.log")")"; st=1
    elif [ -n "$expected" ] && ! cmp -s "$expected" "$nout"; then
      msg="FAIL $name — native output differs from the ORIGINAL bytes (backend bug, not just a parity miss)"; st=1
    elif [ -n "$expected" ] && ! cmp -s "$expected" "$wout"; then
      msg="FAIL $name — wasm output differs from the ORIGINAL bytes (backend bug, not just a parity miss)"; st=1
    elif ! cmp -s "$nout" "$wout"; then
      msg="FAIL $name — native and wasm decoded DIFFERENT bytes from the same input (engine divergence)"; st=1
    else
      sz=$(wc -c < "$nout" | tr -d ' ')
      msg="ok   $name ($sz bytes, native == wasm == original)"
    fi
  elif [ "$mode" = error ]; then
    # error mode: a MALFORMED .gz must be rejected by BOTH engines. One engine
    # accepting bad input while the other rejects it is itself a divergence
    # worth surfacing loudly, not something to average away.
    if [ "$nrc" -eq 142 ] || [ "$wrc" -eq 142 ]; then
      msg="FAIL $name — HUNG on invalid input (native rc=$nrc wasm rc=$wrc); a decompressor must not loop on bad input"; st=1
    elif [ "$nrc" -eq 0 ] && [ "$wrc" -eq 0 ]; then
      msg="FAIL $name — BOTH engines accepted invalid input (exit 0); this case tested nothing"; st=1
    elif [ "$nrc" -eq 0 ] || [ "$wrc" -eq 0 ]; then
      msg="FAIL $name — ENGINE DIVERGENCE on invalid input: native rc=$nrc wasm rc=$wrc (one accepted what the other rejected)"; st=1
    else
      msg="ok   $name (native rc=$nrc, wasm rc=$wrc, both rejected)"
    fi
  else
    # known_divergence: a PINNED, self-draining engine divergence — see
    # docs/design/GZIP-DESIGN.md §"Engine parity" and issue #1349. A stored
    # (BTYPE=00) DEFLATE block of a few thousand bytes or more decodes via
    # gzip/lib/bitio.mdk's `getBytesAlignedGo`, which is written via
    # `do`-notation (desugars to nested `andThen` calls — an interface-method
    # tail call). compiler/backend/wasm_emit.mdk's `emitAppTail` CMethod arm
    # only emits `return_call` for a saturated SELF-call to the impl
    # currently being emitted (`implSelfReturnCall`); any other tail
    # CMethod call — including this one — stays a plain `call … ; return`,
    # so the wasm call stack grows one frame per byte and V8 gives up with
    # "Maximum call stack size exceeded". Native has no such gap and decodes
    # the SAME input correctly. This is a documented, in-repo-comment-
    # acknowledged deferral ("the dispatch fixtures here are not
    # deep-recursive through a method, so a plain return is sound" —
    # falsified by this real input), not a mystery.
    #
    # This case therefore asserts the CURRENT (broken) reality — native
    # succeeds and decodes correctly, wasm crashes with a stack-depth error
    # — rather than papering over it. The moment #1349 is fixed this case
    # will start FAILING (wasm unexpectedly succeeding), which is the
    # self-drain signal to delete this branch and fold the case back into
    # the ordinary `success` corpus above.
    if [ "$nrc" -ne 0 ]; then
      msg="FAIL $name — native regressed (rc=$nrc); this pin only covers the WASM side of #1349, a native failure is a NEW bug"; st=1
    elif [ -n "$expected" ] && ! cmp -s "$expected" "$nout"; then
      msg="FAIL $name — native output differs from the ORIGINAL bytes (a NEW native bug, unrelated to #1349)"; st=1
    elif [ "$wrc" -eq 0 ]; then
      msg="FAIL $name — #1349 appears FIXED: wasm now exits 0 where it used to crash. Promote this case out of known_divergence into the ordinary success corpus and close #1349."; st=1
    elif ! grep -qi "call stack" "$WORKDIR/$name.wasm.log"; then
      msg="$(printf 'FAIL %s — wasm still fails (rc=%s) but NOT with the #1349 stack-depth signature; something else changed\n  --- wasm log ---\n%s' \
        "$name" "$wrc" "$(cat "$WORKDIR/$name.wasm.log")")"; st=1
    else
      msg="ok   $name (KNOWN DIVERGENCE #1349: native rc=0 correct, wasm rc=$wrc stack-depth crash — pinned, not papered over)"
    fi
  fi

  echo "$st" > "$RESULTDIR/$name.status"
  printf '%s\n' "$msg"
  exit 0
fi

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping gzip tandem gate"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) — skipping gzip tandem gate"; exit 2; }
command -v gzip >/dev/null 2>&1 || { echo "gzip not on PATH — skipping gzip tandem gate (needed to build the test corpus)"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not on PATH — skipping gzip tandem gate (needed to build the test corpus)"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build the native compiler first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$WASM_EMITTER" ] || { echo "build the wasm modules emitter: sh test/wasm/build_wasm_oracle.sh (missing $WASM_EMITTER)"; exit 2; }
[ -f "$DEMO" ] || { echo "missing $DEMO"; exit 2; }

# ── Node >= 22 selection (finalized WasmGC encoding — mirror diff_sqlite.sh) ──
NODE=node
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 22 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
if [ "$major" -lt 22 ]; then
  echo "gzip tandem SKIP  Node >= 22 required (have $($NODE --version 2>/dev/null))"
  exit 2
fi

[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"
export MEDAKA_WASM_EMITTER="$WASM_EMITTER"

WORK="$(mktemp -d)"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$WORK" "$RESULTS"' EXIT
mkdir -p "$WORK/inputs"

# ── Build the ONE probe program for both targets, once ─────────────────────
NATIVE_BIN="$WORK/inflate_demo.native"
WASM_BIN="$WORK/inflate_demo.wasm"
if ! "$MEDAKA" build "$DEMO" -o "$NATIVE_BIN" >"$WORK/native_build.log" 2>&1; then
  echo "FAIL: native build of $DEMO failed:"
  cat "$WORK/native_build.log"
  exit 1
fi
if ! "$MEDAKA" build --target wasm "$DEMO" -o "$WASM_BIN" >"$WORK/wasm_build.log" 2>&1; then
  echo "FAIL: wasm build of $DEMO failed:"
  cat "$WORK/wasm_build.log"
  exit 1
fi

# ── Build the test corpus ───────────────────────────────────────────────────
# Reuses the SAME generation shapes as gzip/test/inflate_oracle.sh (the
# design doc's corpus table) rather than checking in new fixtures — that
# script is not sourced/edited here (a concurrent PR is modifying it), this
# just mirrors its recipe for a distinct purpose (engine parity, not
# BTYPE-specific correctness, so no BTYPE assertions here).
add_case() {
  # add_case <mode> <name-prefix> <src-file>   (compresses src with real gzip)
  mode="$1"; name="$2"; src="$3"; level="${4:-6}"
  gz="$WORK/inputs/$name.gz"
  gzip -"$level" -n -c "$src" > "$gz"
  printf '%s\t%s\t%s\t%s\n' "$mode" "$name" "$gz" "$src" >> "$WORK/worklist.tsv"
}

: > "$WORK/worklist.tsv"

# stored blocks (incompressible random data)
head -c 200 /dev/urandom > "$WORK/inputs/small_stored.src"
add_case success small_stored "$WORK/inputs/small_stored.src" 1
head -c 200000 /dev/urandom > "$WORK/inputs/large_stored.src"
# known_divergence, not success — see issue #1349 (filed alongside this gate):
# a multi-block stored (BTYPE=00) DEFLATE stream this large crashes wasm with
# a stack-depth error that native does not have. Pinned honestly rather than
# hidden — see the --one worker's known_divergence arm above for the full
# explanation and the self-drain condition.
add_case known_divergence large_stored "$WORK/inputs/large_stored.src" 1

# fixed-Huffman shapes
printf 'hello world hello world hello world' > "$WORK/inputs/fixed_small.src"
add_case success fixed_small "$WORK/inputs/fixed_small.src" 6
python3 -c "import sys; sys.stdout.buffer.write(b'a' * 2000)" > "$WORK/inputs/fixed_rle.src"
add_case success fixed_rle "$WORK/inputs/fixed_rle.src" 1
python3 -c "import sys; sys.stdout.write(('the quick brown fox ' * 200)[:2000])" > "$WORK/inputs/fixed_phrase.src"
add_case success fixed_phrase "$WORK/inputs/fixed_phrase.src" 1

# dynamic-Huffman shapes
python3 -c "print('the quick brown fox jumps over the lazy dog. ' * 2260, end='')" > "$WORK/inputs/dynamic_repeat.src"
add_case success dynamic_repeat "$WORK/inputs/dynamic_repeat.src" 6
add_case success dynamic_source_file "$ROOT/compiler/frontend/parser.mdk" 6
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
" > "$WORK/inputs/dynamic_allbytes.src"
add_case success dynamic_allbytes "$WORK/inputs/dynamic_allbytes.src" 6
python3 -c "
import sys
data = (b'window boundary probe, ' * 2000)[:32800]
sys.stdout.buffer.write(data)
" > "$WORK/inputs/dynamic_window_boundary.src"
add_case success dynamic_window_boundary "$WORK/inputs/dynamic_window_boundary.src" 6

# self-referential: the committed seed, ~1.7 MB of real dynamic-Huffman data
# already in the repo (design doc §"Self-referential") — no fixture to add.
SEED_GZ="$ROOT/compiler/seed/emitter.ll.gz"
if [ -f "$SEED_GZ" ]; then
  gunzip -c "$SEED_GZ" > "$WORK/inputs/seed_expected.src"
  printf 'success\tseed_emitter\t%s\t%s\n' "$SEED_GZ" "$WORK/inputs/seed_expected.src" >> "$WORK/worklist.tsv"
else
  echo "1" > "$RESULTS/seed_emitter_missing.status"
  echo "FAIL seed_emitter — $SEED_GZ not found"
fi

# ── error paths: malformed / truncated input must be rejected by BOTH ──────
gzip -6 -n -c "$ROOT/compiler/frontend/parser.mdk" > "$WORK/inputs/err_src.gz"
sz=$(wc -c < "$WORK/inputs/err_src.gz")
head -c $((sz / 2)) "$WORK/inputs/err_src.gz" > "$WORK/inputs/truncated_mid.gz"
printf 'error\ttruncated_mid\t%s\t-\n' "$WORK/inputs/truncated_mid.gz" >> "$WORK/worklist.tsv"
head -c 15 "$WORK/inputs/err_src.gz" > "$WORK/inputs/truncated_header.gz"
printf 'error\ttruncated_header\t%s\t-\n' "$WORK/inputs/truncated_header.gz" >> "$WORK/worklist.tsv"
printf 'not a gzip file at all, just text' > "$WORK/inputs/not_a_gzip.gz"
printf 'error\tnot_a_gzip\t%s\t-\n' "$WORK/inputs/not_a_gzip.gz" >> "$WORK/worklist.tsv"

# corrupted trailer CRC-32. OCTAL escapes, not \xNN — /bin/sh here is dash,
# whose printf does not interpret \xNN (it emits the 4 LITERAL characters),
# which would silently APPEND junk instead of REPLACING 4 bytes and shift the
# whole trailer. Same technique + same guard as gzip/test/inflate_oracle.sh.
corrupt_last4() {
  src="$1"; dst="$2"; keep="$3"
  head -c "$keep" "$src" > "$dst"
  printf '\336\255\276\357' >> "$dst"
}
corrupt_last4 "$WORK/inputs/err_src.gz" "$WORK/inputs/corrupted_crc.gz" $((sz - 8))
tail -c 4 "$WORK/inputs/err_src.gz" >> "$WORK/inputs/corrupted_crc.gz"
if [ "$(wc -c < "$WORK/inputs/corrupted_crc.gz")" -ne "$sz" ]; then
  echo "1" > "$RESULTS/corrupted_crc_harness_bug.status"
  echo "FAIL corrupted_crc — harness bug: corrupting the CRC changed the file LENGTH"
else
  printf 'error\tcorrupted_crc\t%s\t-\n' "$WORK/inputs/corrupted_crc.gz" >> "$WORK/worklist.tsv"
fi

# ── Fan the worklist across an xargs -P pool of --one workers ──────────────
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
NODE_ABS="$(command -v "$NODE" 2>/dev/null || echo "$NODE")"

NATIVE_BIN="$NATIVE_BIN" WASM_BIN="$WASM_BIN" NODE="$NODE_ABS" RUNJS="$RUNJS" \
WORKDIR="$WORK" RESULTDIR="$RESULTS" \
  xargs -P "$JOBS" -L 1 bash "$0" --one < "$WORK/worklist.tsv"

pass=0; fail=0
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  if [ "$(cat "$s")" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
