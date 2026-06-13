#!/bin/sh
# SELF-COMPILE C3 for the BUILD DRIVER — verify the STRICT multi-module emit driver
# (selfhost/entries/llvm_emit_modules_main.mdk, the one `medaka build` actually shells out to)
# fixpoints, not just the gap-tolerant bootstrap driver.
#
# Same shape as test/selfcompile_fixpoint.sh, but DRIVER = llvm_emit_modules_main.mdk:
#   step 1  INTERP.ll = interpreted emission of the build driver's OWN module graph;
#           clang(INTERP.ll) -> emitA (native build emitter).
#   step 2  IR1 = emitA re-emitting the build driver's graph.
#           C3a: IR1 == INTERP.ll  (native reproduces interpreted).
#   step 3  clang(IR1) -> emitB; IR2 = emitB re-emitting.
#           C3b: IR1 == IR2  (fixpoint).
#
# If C3a or C3b FAIL for this driver, the seed cannot be minted from it — STOP.
#
# Usage:  sh test/selfcompile_build_fixpoint.sh
# Exit:   0 iff C3a AND C3b hold; 2 if build/clang/libgc missing (opt-in); 1 on divergence.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
DRIVER="$ROOT/selfhost/entries/llvm_emit_modules_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/selfhost"
STDLIB="$ROOT/stdlib"
CC="${CC:-clang}"
STACK_SIZE="${STACK_SIZE:-0x20000000}"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then
  GC_CFLAGS="$(pkg-config --cflags bdw-gc)"; GC_LIBS="$(pkg-config --libs bdw-gc)"
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then
  GC_CFLAGS="-I$GC_PREFIX/include"; GC_LIBS="-L$GC_PREFIX/lib -lgc"
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then
  GC_CFLAGS=""; GC_LIBS="-lgc"
else
  echo "libgc (bdw-gc) not found — skipping (install bdw-gc, or set GC_PREFIX)"; exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

trim_unit() {
  f="$1"
  if [ "$(tail -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "28290a" ]; then
    head -c $(( $(wc -c < "$f") - 3 )) "$f" > "$f.trim" && mv "$f.trim" "$f"
  fi
}

# Build-driver emit args: <runtime> <core> <ENTRY=driver> <selfhost> <stdlib>.
# Same root ordering as build_cmd: input_dir(=selfhost) then selfhost then stdlib.
emit() { "$1" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" "$STDLIB"; }

INTERP="$WORK/INTERP.ll"; EMITA="$WORK/emitA"
echo "step 1: interpreted emission of the BUILD driver's own graph ..."
if ! "$MAIN" run "$DRIVER" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" "$STDLIB" > "$INTERP" 2>"$WORK/e1.err"; then
  echo "FAIL (interp-emit build driver): $(cat "$WORK/e1.err")"; exit 1
fi
echo "step 1: clang emitA (stack $STACK_SIZE) ..."
if ! "$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$INTERP" "$RT" $GC_LIBS -o "$EMITA" 2>"$WORK/cc1.err"; then
  echo "FAIL (clang emitA): $(cat "$WORK/cc1.err")"; exit 1
fi

IR1="$WORK/IR1.ll"
echo "step 2: IR1 — emitA re-emitting the build driver's graph ..."
if ! emit "$EMITA" > "$IR1" 2>"$WORK/ir1.err"; then
  echo "FAIL (native emitA crashed):"; cat "$WORK/ir1.err"; exit 1
fi
trim_unit "$IR1"

c3a=0
if cmp -s "$INTERP" "$IR1"; then c3a=1; echo "C3a PASS: IR1 == interpreted, byte-for-byte"
else echo "C3a FAIL"; cmp "$INTERP" "$IR1" | head -3; diff "$INTERP" "$IR1" | head -20; fi

EMITB="$WORK/emitB"
echo "step 3: clang IR1 -> emitB ..."
if ! "$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$IR1" "$RT" $GC_LIBS -o "$EMITB" 2>"$WORK/cc2.err"; then
  echo "FAIL (clang emitB): $(cat "$WORK/cc2.err")"; exit 1
fi
IR2="$WORK/IR2.ll"
echo "step 3: IR2 — emitB re-emitting ..."
if ! emit "$EMITB" > "$IR2" 2>"$WORK/ir2.err"; then
  echo "FAIL (emitB crashed):"; cat "$WORK/ir2.err"; exit 1
fi
trim_unit "$IR2"

c3b=0
if cmp -s "$IR1" "$IR2"; then c3b=1; echo "C3b PASS: IR1 == IR2 — FIXPOINT"
else echo "C3b FAIL"; cmp "$IR1" "$IR2" | head -3; diff "$IR1" "$IR2" | head -20; fi

echo
printf 'BUILD-DRIVER C3a (IR1==interp): %s   C3b (IR1==IR2): %s\n' \
  "$([ "$c3a" -eq 1 ] && echo YES || echo NO)" \
  "$([ "$c3b" -eq 1 ] && echo YES || echo NO)"
[ "$c3a" -eq 1 ] && [ "$c3b" -eq 1 ]
