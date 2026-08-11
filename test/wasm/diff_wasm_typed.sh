#!/usr/bin/env bash
# diff_wasm_typed.sh — Slice W5 differential gate (WASMGC-DESIGN §8, typeclass
# dispatch).  The DISPATCH peer of test/wasm/diff_wasm.sh, mirroring the LLVM split
# (diff_compiler_llvm_typed.sh): the W1–W4 scalar/ADT/closure fixtures stay on the
# PRELUDE-FREE annotate entry (wasm_emit_main, never produces CMethod/CDict); the W5
# DISPATCH fixtures go through the TYPED single-file entry (wasm_emit_typed_main),
# which runs elaborateDict and so DOES produce CMethod/CDict/CImplEntry.
#
# Entry strategy = DUAL-ENTRY (see compiler/entries/wasm_emit_typed_main.mdk header).
# The wholesale modules+DCE switch is NOT usable: DCE retains every prelude
# impl/interface whole (dict-passing dispatch can't prune an impl soundly), so a
# real `medaka build` of even a minimal `Eq Color` fixture emits ~274 prelude impl
# functions (Debug/Display strings, Num Float arith, Char/tuple impls) — all
# out-of-slice WasmGC gaps (W6/W7).  The prelude-free typed fixtures define their own
# minimal interfaces; elaborateDict resolves every route with NO prelude surface.
#
# For each fixture in test/wasm/fixtures_typed/:
#   1. oracle = `./medaka build <fixture>` + run (the OCaml-free native-compiled
#      binary's auto-printed value main — same oracle as diff_wasm.sh).
#   2. emit   = test/bin/wasm_emit_typed_main <runtime.mdk> <fixture>  → WAT
#   3. assemble + validate with wasm-tools; run under Node>=22; diff stdout.
#
# Reports N/M; non-zero exit on any divergence.  Opt-in skip (exit 2) when the
# toolchain (wasm-tools / Node>=22 / clang) is unavailable.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
EMITBIN="$ROOT/test/bin/wasm_emit_typed_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/wasm/fixtures_typed"
RUNJS="$ROOT/test/wasm/run.js"
CC="${CC:-clang}"
WASM_SRC="$ROOT/compiler/backend/wasm_emit.mdk"

# X-W.H2a structural ratchet. Keep this before every toolchain/binary skip: the
# private program index is source structure, not a capability of wasm-tools.
legacy_state='fnNameSetW|valNameSetW|fnArMapW|implsByMethodW|lazyGlobalMapRef|recFieldsRef|fnsUsedAsValuesRef|fnsUsedAsValuesSetW|ctorArMapW|ctorTyMapW|ctorOrdMapW|typeCtorsMapW'
legacy_installer='installFnIndexW|installImplIndexW|setFnsUsedAsValuesW|installLazyGlobalMapW|installCtorTablesW'
if grep -E "^($legacy_state)[[:space:]]*:" "$WASM_SRC" >/dev/null ||
   grep -E "^($legacy_installer)[[:space:]]*:" "$WASM_SRC" >/dev/null; then
  echo "FAIL wasm typed index ratchet: legacy Wasm state authority remains"
  exit 1
fi
for sym in WasmProgramIndex progIndex makeWasmProgramIndex indexFnNamesW indexImplsByMethodW indexLazyGlobalsW indexCtorOrdinalsW; do
  grep -E "^$sym[[:space:]]*:|^data $sym" "$WASM_SRC" >/dev/null || {
    echo "FAIL wasm typed index ratchet: missing private carrier/accessor $sym"
    exit 1
  }
done

# ── Per-fixture worker (parallel fan-out target); shared state via env ─────────
# Oracle at -O2 (not -O0): TCO fixtures need clang tail-call opt to avoid overflow.
if [ "${1:-}" = "--one" ]; then
  f="$2"; name="$(basename "$f")"
  obin="$WORKDIR/$name.oracle"; wat="$WORKDIR/$name.wat"; wasm="$WORKDIR/$name.wasm"
  st=0; msg=""
  if ! MEDAKA_CLANG_OPT="${WASM_ORACLE_OPT:--O2}" "$MEDAKA" build "$f" -o "$obin" >"$WORKDIR/$name.build.err" 2>&1; then
    msg="$(printf 'FAIL %s (oracle build)\n%s' "$name" "$(cat "$WORKDIR/$name.build.err")")"; st=1
  else
    ref="$("$obin" 2>/dev/null)"
    if ! "$EMITBIN" "$RUNTIME" "$f" > "$wat" 2>"$WORKDIR/$name.emit.err"; then
      msg="$(printf 'FAIL %s (wasm emit)\n%s' "$name" "$(cat "$WORKDIR/$name.emit.err")")"; st=1
    elif ! wasm-tools parse "$wat" -o "$wasm" 2>"$WORKDIR/$name.parse.err"; then
      msg="$(printf 'FAIL %s (wasm-tools parse)\n%s' "$name" "$(cat "$WORKDIR/$name.parse.err")")"; st=1
    elif ! wasm-tools validate --features=all "$wasm" 2>"$WORKDIR/$name.val.err"; then
      msg="$(printf 'FAIL %s (wasm-tools validate)\n%s' "$name" "$(cat "$WORKDIR/$name.val.err")")"; st=1
    else
      got="$("$NODE" "$RUNJS" "$wasm" 2>"$WORKDIR/$name.run.err")"
      if [ "$ref" = "$got" ]; then msg="ok   $name"
      else msg="$(printf 'FAIL %s\n  oracle: %s\n  wasm  : %s\n  (%s)' "$name" "$ref" "$got" "$(cat "$WORKDIR/$name.run.err")")"; st=1; fi
    fi
  fi
  echo "$st" > "$RESULTDIR/$name.status"
  printf '%s\n' "$msg"
  exit 0
fi

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping W5 gate"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) — skipping W5 gate"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build the native compiler first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITBIN" ] || { echo "build the wasm typed emitter: sh test/wasm/build_wasm_oracle.sh (missing $EMITBIN)"; exit 2; }

# X-W.H1: one process emits one lowered P program with P's complete input, each
# U-derived field in isolation, then P's input again. This distinguishes explicit
# inputs from CProgram changes and proves the final P is not contaminated.
INPUT_WORK="$(mktemp -d)"
trap 'rm -rf "$INPUT_WORK"' EXIT
cat > "$INPUT_WORK/p.mdk" <<'EOF'
interface Score a where
  score : a -> Int

data P = P

impl Score P where
  score = x => 7

data R = R { i : Int, f : Float }

negR : R -> Float
negR r = -r.f

dbl : Float -> Float
dbl x = x + x

data Cell = CInt Int | CFloat Float

cellNumF : Cell -> Float
cellNumF c = match c
  CInt n => intToFloat n
  CFloat f => f

sumCells : List Cell -> Float
sumCells cells = match cells
  [] => 0.0
  c :: rest => cellNumF c + sumCells rest

asFloat : Int -> Float
asFloat n = intToFloat n

data Box = Box Float

negBox : Box -> Float
negBox b = match b
  Box f => -f

main = asFloat 1
EOF
cat > "$INPUT_WORK/u.mdk" <<'EOF'
interface Score a where
  score : a -> Int -> Int

data R = R { f : Float, i : Int }

negR : R -> Int
negR _ = 0

dbl : Int -> Int
dbl x = x + x

cellNumF : Cell -> Int
cellNumF _ = 0

sumCells : List Cell -> Int
sumCells _ = 0

asFloat : Int -> Int
asFloat n = n

data Box = Box Int
EOF
REEMIT_OUT="$($EMITBIN --reemit-input "$RUNTIME" "$INPUT_WORK/p.mdk" "$INPUT_WORK/u.mdk")" || {
  echo "FAIL wasm typed same-process input harness"
  exit 1
}
REEMIT_EXPECTED="$(printf 'P_EQ_PLAST\nP_NE_METHOD\nP_NE_SIG\nP_NE_CTOR\nP_NE_MAIN\nP_NE_RECORD')"
[ "$REEMIT_OUT" = "$REEMIT_EXPECTED" ] || {
  echo "FAIL wasm typed input isolation: an explicit field did not discriminate: $REEMIT_OUT"
  exit 1
}

# X-W.H2a: sequence normal P -> normal U -> gap U -> normal P in one process.
# Compare complete captures in the shell so a marker-only driver cannot satisfy this.
STATE_OUT="$($EMITBIN --reemit-state "$RUNTIME")" || {
  echo "FAIL wasm typed same-process state harness"
  exit 1
}
state_capture() {
  printf '%s\n' "$STATE_OUT" | sed -n "/^$1$/,/^$2$/p" | sed '1d;$d'
}
P1_WAT="$(state_capture REEMIT_P1_BEGIN REEMIT_P1_END)"
U_WAT="$(state_capture REEMIT_U_BEGIN REEMIT_U_END)"
P2_WAT="$(state_capture REEMIT_P2_BEGIN REEMIT_P2_END)"
[ -n "$P1_WAT" ] && [ -n "$U_WAT" ] && [ -n "$P2_WAT" ] || {
  echo "FAIL wasm typed state isolation: empty capture"
  exit 1
}
[ "$P1_WAT" = "$P2_WAT" ] || {
  echo "FAIL wasm typed state isolation: P changed after U and gap U"
  exit 1
}
[ "$P1_WAT" != "$U_WAT" ] || {
  echo "FAIL wasm typed state isolation: P/U positive control did not differ"
  exit 1
}

# ── Node >= 22 selection (finalized WasmGC encoding — see test/wasm/w1.sh) ─────
NODE=node
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 22 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
if [ "$major" -lt 22 ]; then
  echo "W5 SKIP  Node >= 22 required for the finalized WasmGC encoding (have $($NODE --version 2>/dev/null))"
  exit 2
fi

[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"

WORK="$(mktemp -d)"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$INPUT_WORK" "$WORK" "$RESULTS"' EXIT

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
NODE_ABS="$(command -v "$NODE" 2>/dev/null || echo "$NODE")"
ls "$FIXDIR"/*.mdk 2>/dev/null \
  | MEDAKA="$MEDAKA" EMITBIN="$EMITBIN" RUNTIME="$RUNTIME" NODE="$NODE_ABS" RUNJS="$RUNJS" \
    MEDAKA_EMITTER="${MEDAKA_EMITTER:-$EMITTER}" WASM_ORACLE_OPT="${WASM_ORACLE_OPT:-}" \
    WORKDIR="$WORK" RESULTDIR="$RESULTS" \
    xargs -P "$JOBS" -n 1 -I{} sh "$0" --one {}

pass=0; fail=0
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  if [ "$(cat "$s")" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
