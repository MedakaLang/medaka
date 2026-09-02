#!/bin/sh
# Gate for the async runtime (docs/design/ASYNC-RUNTIME-DESIGN.md, tracking #500).
#
# Async I/O is native-first: the readiness externs (ioPoll, netTry*) are bound
# by the LLVM backend only, so — exactly like test/diff_net.sh — this is a
# dedicated build-and-run gate rather than an interpreter-goldened one.  For
# each fixture under test/async_fixtures/, `medaka build` it on the native
# target, run the binary, and diff its stdout against the committed
# `<name>.expected`.
#
# What the corpus proves (guarantees G1–G9 of the design doc):
#   overlap_sleeps   G6/G7 — parked tasks overlap; the program times itself and
#                    prints "overlapped" only if three 100 ms sleeps finish in
#                    under 250 ms (an order-of-magnitude margin, never a tight one).
#   echo_overlap     the A3 payoff — one thread, an accept loop that spawns a
#                    handler per connection, a slow client that does not stall a
#                    fast one, a deadline that fires, and a serve loop that ends
#                    when its listener closes (so the program exits).
#
# No I/O completion order is pinned beyond what the fixtures make deterministic
# by construction (G2): every ordering claim in an .expected rests on a sleep
# that is at least an order of magnitude longer than a loopback round trip.
#
# Usage:  sh test/diff_async.sh
# Exit:   0 if every fixture matches its .expected; 1 otherwise; 2 if the native
#         `medaka` / `medaka_emitter` build is missing.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIXDIR="$ROOT/test/async_fixtures"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .mdk)"
  expected="$FIXDIR/$name.expected"
  if [ ! -f "$expected" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no .expected)\n' "$name"; continue
  fi
  want="$(cat "$expected")"
  bin="$WORK/$name.bin"
  if ! ( export MEDAKA_ROOT="$ROOT"; export MEDAKA_EMITTER="$EMITTER"; bound "$MEDAKA" build "$f" -o "$bin" ) >"$WORK/build.out" 2>"$WORK/build.err"; then
    fail=$((fail+1)); printf 'FAIL %s (build)\n%s\n' "$name" "$(cat "$WORK/build.err")"; continue
  fi
  if [ ! -x "$bin" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no binary produced)\n' "$name"; continue
  fi
  got="$(bound "$bin" 2>"$WORK/run.err")"
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n  stderr: %s\n' "$name" "$want" "$got" "$(cat "$WORK/run.err")"
  fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
