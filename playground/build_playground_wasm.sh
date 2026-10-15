#!/usr/bin/env bash
# build_playground_wasm.sh — Stage-2 playground artifact builder.
#
# Produces the in-browser Medaka COMBINED compiler: the diagnostics+emit entry
# (compiler/entries/playground_main.mdk) self-compiled to a WasmGC module.  Unlike
# compiler.wasm (the bare emit entry, which TRAPS on a broken program), this module
# runs the front end once and EITHER prints check --json diagnostics (broken) OR
# emits the program's WAT (clean), demuxed by a first-line marker — so the browser
# can surface compile errors with NO server.  See playground/compile.mjs for the
# host-side seam and the marker protocol.
#
# Idempotent.  Emits into playground/dist/ (gitignored):
#   * playground.wasm   — the combined compiler, as WasmGC  (do NOT commit)
#   * runtime.mdk       — copy of stdlib/runtime.mdk (browser feeds via vfs)
#   * core.mdk          — copy of stdlib/core.mdk     (browser feeds via vfs)
#   * <id>.mdk          — every other stdlib module   (browser feeds via vfs)
#   * stdlib_modules.json — the ids of those modules, generated (do NOT commit)
#
# Pipeline:
#   1. make medaka                         -> native OCaml-free compiler (./medaka)
#      test/wasm/build_wasm_oracle.sh       -> test/bin/wasm_emit_modules_main
#   2. wasm_emit_modules_main <runtime> <core> <ENTRY=playground_main.mdk> compiler stdlib
#        -> playground.wat ; wasm-tools parse -> playground.wasm ; validate
#
# NOTE the two ROOT dirs `compiler stdlib`: playground_main.mdk imports both
# compiler modules AND stdlib/json (+ transitively hash_map via dce.mdk), so BOTH
# roots are required or the loader reports `unknown module: …`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/playground/dist"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
EMITBIN="$ROOT/test/bin/wasm_emit_modules_main"
ENTRY="$ROOT/compiler/entries/playground_main.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

command -v wasm-tools >/dev/null 2>&1 || { echo "FAIL: wasm-tools not on PATH"; exit 2; }
command -v dune >/dev/null 2>&1 || export PATH="$HOME/.opam/5.4.1/bin:$PATH"

mkdir -p "$DIST"

# ── step 1: native compiler + the native modules-emitter binary ──────────────────
#
# Skipped when `medaka` and the modules emitter (the only one this script runs) are
# newer than every compiler/stdlib/runtime source. The other two emitters are not
# checked here; build_wasm_oracle.sh is what refreshes them.
native_fresh() {
  [ -x "$MEDAKA" ] && [ -x "$EMITBIN" ] || return 1
  # A failing find (missing dir, unsupported primary) must read as stale, not fresh.
  newer=$(find "$ROOT/compiler" "$ROOT/stdlib" "$ROOT/runtime" -type f \
            \( -name '*.mdk' -o -name '*.c' -o -name '*.h' \) \
            \( -newer "$MEDAKA" -o -newer "$EMITBIN" \) -print) || return 1
  [ -z "$newer" ]
}
if native_fresh; then
  echo "[1/2] native compiler + wasm emitter binary are up to date; skipping rebuild"
  [ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"
else
  echo "[1/2] building native compiler + wasm emitter binary ..."
  ( cd "$ROOT" && make medaka )
  [ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"
  ( cd "$ROOT" && bash test/wasm/build_wasm_oracle.sh )
fi
[ -x "$MEDAKA" ]  || { echo "FAIL: missing $MEDAKA";  exit 1; }
[ -x "$EMITBIN" ] || { echo "FAIL: missing $EMITBIN"; exit 1; }

# ── step 2: compile the combined entry to wasm (playground.wasm) ─────────────────
echo "[2/2] compiling the combined diagnostics+emit entry to WasmGC ..."
WAT="$DIST/playground.wat"
WASM="$DIST/playground.wasm"
"$EMITBIN" "$RUNTIME" "$CORE" "$ENTRY" "$ROOT/compiler" "$ROOT/stdlib" > "$WAT"
[ -s "$WAT" ] || { echo "FAIL: emitter produced empty WAT"; exit 1; }
echo "  playground.wat: $(wc -l < "$WAT") lines"

wasm-tools parse "$WAT" -o "$WASM"
echo "  ASSEMBLE_OK"
wasm-tools validate --features=all "$WASM"
echo "  VALIDATE_OK"
wasm-tools strip --all "$WASM" -o "$WASM"   # drop the debug name section (same as wasmAssemble)
echo "  STRIP_OK"
# Size pass: -Os cuts the module ~24% raw and ~3% brotli (what Cloudflare serves).
# Optional: without binaryen the unoptimised module is still correct.
if command -v wasm-opt >/dev/null 2>&1; then
  wasm-opt --all-features -Os "$WASM" -o "$WASM.opt"
  # -Os leaves dead `ref.test/ref.cast (ref none)` + `i31.get_u` branches that the spec
  # accepts and JavaScriptCore (so every iOS browser) rejects at compile time:
  # "i31.get_u ref to type (ref none) expected I31ref". A second cleanup round folds them.
  wasm-opt --all-features --dce --optimize-instructions --precompute-propagate \
    --vacuum --remove-unused-brs "$WASM.opt" -o "$WASM.opt2"
  mv "$WASM.opt2" "$WASM.opt"
  wasm-tools validate --features=all "$WASM.opt"
  # wasm-tools accepts the leftover, so look for it directly. Any survivor fails the build.
  none_casts=$(wasm-tools print "$WASM.opt" | grep -c 'ref\.\(cast\|test\) (ref \(null \)\?none)' || true)
  if [ "$none_casts" -ne 0 ]; then
    echo "FAIL: $none_casts ref.cast/ref.test to (ref none) survive wasm-opt; WebKit would reject the module (i31.get_u on a none-typed operand)" >&2
    exit 1
  fi
  mv "$WASM.opt" "$WASM"
  echo "  WASMOPT_OK"
else
  echo "  WASMOPT_SKIP (wasm-opt not on PATH)"
fi
rm -f "$WAT"  # keep dist lean; WAT is huge and regenerable

# ── stage the stdlib sources the browser vfs will feed ───────────────────────────
cp "$RUNTIME" "$DIST/runtime.mdk"
cp "$CORE"    "$DIST/core.mdk"

# Every stdlib module ships (docs/design/TARGETS-DESIGN.md §6.4): a program that
# uses one whose labels `wasmgc/browser-worker` withholds is refused by the
# compiler's target check, with the same located T-TARGET-CAPABILITY diagnostic
# `medaka check --target` gives, rather than by a module that is missing.
# The module ids are derived from stdlib/ and stdlib/crypto/ (no `_test`
# siblings), staged flat as dist/<id>.mdk (`crypto.sha256` -> dist/crypto.sha256.mdk),
# and listed in dist/stdlib_modules.json: the one list main.js fetches from and
# build_site.sh checks the site against.
EXTRA_MODULES=$(
  cd "$ROOT/stdlib"
  for f in *.mdk crypto/*.mdk; do
    case "$f" in
      *_test.mdk|runtime.mdk|core.mdk) ;;
      *) echo "$f" | sed 's/\.mdk$//; s#/#.#g' ;;
    esac
  done | LC_ALL=C sort
)
[ -n "$EXTRA_MODULES" ] || { echo "FAIL: no stdlib modules found under $ROOT/stdlib"; exit 1; }
for m in $EXTRA_MODULES; do
  cp "$ROOT/stdlib/$(echo "$m" | tr . /).mdk" "$DIST/$m.mdk"
done
printf '%s\n' $EXTRA_MODULES \
  | awk 'BEGIN { printf "[" } { printf "%s\"%s\"", (NR > 1 ? "," : ""), $0 } END { print "]" }' \
  > "$DIST/stdlib_modules.json"

echo
echo "artifacts in $DIST:"
for f in playground.wasm runtime.mdk core.mdk stdlib_modules.json $(for m in $EXTRA_MODULES; do echo "$m.mdk"; done); do
  [ -f "$DIST/$f" ] && printf '  %-20s %10d bytes\n' "$f" "$(wc -c < "$DIST/$f")"
done
echo "DONE"
