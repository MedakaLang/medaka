#!/bin/sh
# REFRESH the checked-in IR seed (selfhost/seed/emitter.ll) — the ONLY script that
# uses the OCaml interpreter.  Run on-demand (per-release, or when the emitter
# changes and you want a fresh seed) — NOT on every PR.
#
# The seed is the textual LLVM IR of the BUILD driver
# (selfhost/llvm_emit_modules_main.mdk) emitting its OWN module graph, produced by
# the OCaml interpreter.  It is the bootstrap entry point: test/bootstrap_from_seed.sh
# rebuilds a native emitter from this seed WITHOUT OCaml, and verifies the seed
# reproduces from current sources (the C3a property).  The native emitter emitting
# itself reproduces this seed byte-for-byte (C3b), so OCaml is only needed for the
# very first mint / a deliberate refresh.
#
# Usage:  dune build --root . && sh test/refresh_seed.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
DRIVER="$ROOT/selfhost/llvm_emit_modules_main.mdk"
SEED="$ROOT/selfhost/seed/emitter.ll"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }

mkdir -p "$(dirname "$SEED")"
TMP="$(mktemp)"
echo "minting seed: interpreted emission of the build driver's own graph ..."
"$MAIN" run "$DRIVER" "$ROOT/stdlib/runtime.mdk" "$ROOT/stdlib/core.mdk" \
  "$DRIVER" "$ROOT/selfhost" "$ROOT/stdlib" > "$TMP"

# Trim a trailing "()\n" if a future emit path auto-prints main's Unit (interp does
# not today, but the native-emitter mint path would — keep this robust).
if [ "$(tail -c 3 "$TMP" | od -An -tx1 | tr -d ' \n')" = "28290a" ]; then
  head -c $(( $(wc -c < "$TMP") - 3 )) "$TMP" > "$TMP.trim" && mv "$TMP.trim" "$TMP"
fi

mv "$TMP" "$SEED"
echo "seed refreshed: $SEED ($(wc -c < "$SEED") bytes)"
