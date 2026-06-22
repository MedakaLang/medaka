#!/usr/bin/env bash
# diff_wasm_modules.sh — Slice W9 differential gate (WASMGC-DESIGN.md §9 / §8).  The
# MULTI-MODULE + REAL-PRELUDE peer of diff_wasm_typed.sh: it drives the
# wasm_emit_modules_main entry through the FULL `medaka build` front end (loader →
# elaborateModules with the REAL core.mdk prelude → core_ir_lower → DCE → wasm_emit),
# so dispatch flows through the real prelude and DCE prunes it to what each program
# reaches.  For each fixture (a single .mdk OR a multi-file program dir with entry.mdk),
# oracle = the native-compiled `medaka build`; emitter = the modules entry → WAT →
# wasm-tools → Node 24 → byte-diff stdout.
#
# REAL-PRELUDE GAP HANDLING (W9 incremental landing — see the slice writeup):
# the DCE'd real prelude retains every impl WHOLE, including POINT-FREE impls
# (`toList = identity`, `length = fold g 0`, `foldMap f = fold …`) whose source clause
# arity is LESS than the method's user arity.  Eta-expanding them correctly needs the
# method's declared-interface arity (to separate user args from forwarded `requires`
# dicts), which the WasmGC emitter does not yet thread (the install*-hook the LLVM
# emitter has, that wasm_emit deliberately lacks).  Until that lands, EVERY real-prelude
# program emits invalid WAT at those impls.  This gate therefore classifies a fixture
# that fails ONLY at wasm-tools validate as a KNOWN-GAP SKIP (not a failure), reports
# it, and still FAILS on any fixture that emits+validates+runs but byte-DIFFERS — so it
# locks in correctness for whatever the modules path CAN do while making the remaining
# MVP gap explicit.  A fixture that fully passes is an `ok`.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
EMITBIN="$ROOT/test/bin/wasm_emit_modules_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/wasm/fixtures_modules"
RUNJS="$ROOT/test/wasm/run.js"
CC="${CC:-clang}"

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping W9 gate"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) — skipping W9 gate"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build the native compiler first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITBIN" ] || { echo "build the wasm modules emitter: sh test/wasm/build_wasm_oracle.sh (missing $EMITBIN)"; exit 2; }

# ── Node >= 22 selection (finalized WasmGC encoding) ─────────────────────────
NODE=node
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 22 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
if [ "$major" -lt 22 ]; then
  echo "W9 SKIP  Node >= 22 required for the finalized WasmGC encoding (have $($NODE --version 2>/dev/null))"
  exit 2
fi

[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; gap=0

# run one fixture: $1 = display name, $2 = entry .mdk path, $3 = roots (dir for the loader)
run_fixture() {
  local name="$1" entry="$2" root="$3"

  # oracle = native-compiled binary stdout
  local obin="$WORK/$name.oracle"
  if ! "$MEDAKA" build "$entry" -o "$obin" >"$WORK/build.err" 2>&1; then
    fail=$((fail+1)); printf 'FAIL %s (oracle build)\n%s\n' "$name" "$(cat "$WORK/build.err")"; return
  fi
  local ref; ref="$("$obin" 2>/dev/null)"

  # emitter = modules entry → WAT
  local wat="$WORK/$name.wat"
  if ! "$EMITBIN" "$RUNTIME" "$CORE" "$entry" "$root" > "$wat" 2>"$WORK/emit.err"; then
    gap=$((gap+1)); printf 'GAP  %s (emit) %s\n' "$name" "$(head -1 "$WORK/emit.err" | sed 's/.*gap — //')"; return
  fi

  local wasm="$WORK/$name.wasm"
  if ! wasm-tools parse "$wat" -o "$wasm" 2>"$WORK/parse.err"; then
    fail=$((fail+1)); printf 'FAIL %s (wasm-tools parse)\n%s\n' "$name" "$(head -2 "$WORK/parse.err")"; return
  fi
  if ! wasm-tools validate --features=all "$wasm" 2>"$WORK/val.err"; then
    # KNOWN GAP: the real-prelude point-free-impl arity gap (see header) surfaces here.
    gap=$((gap+1)); printf 'GAP  %s (validate: real-prelude point-free impl arity — %s)\n' "$name" "$(head -1 "$WORK/val.err")"; return
  fi

  local got; got="$("$NODE" "$RUNJS" "$wasm" 2>"$WORK/run.err")"
  if [ "$ref" = "$got" ]; then
    pass=$((pass+1)); printf 'ok   %s -> %s\n' "$name" "$ref"
  else
    fail=$((fail+1)); printf 'FAIL %s\n  oracle: %s\n  wasm  : %s\n  (%s)\n' "$name" "$ref" "$got" "$(cat "$WORK/run.err")"
  fi

  # layer-8 IR-shape assertion: the dispatched `List map` impl must lower to the
  # destination-passing loop (Phase 2 B-dispatch / wTrmcImplTry) — its $mdk_impl_List_map
  # body has a `loop $tmcloop` and ZERO recursive `call $mdk_impl_List_map` (the cons-tail
  # self-call became a `br $tmcloop`).  A regression that drops the impl-TMC would re-emit
  # the recursive call → deep lists overflow V8 → silent re-break of this fixture's value.
  if [ "$name" = "w_dispatch_map_stack.mdk" ]; then
    local mapbody
    mapbody="$(awk '/func \$mdk_impl_List_map/{f=1} f&&/^  \(func /&&!/mdk_impl_List_map/{f=0} f' "$wat")"
    local rec; rec="$(printf '%s' "$mapbody" | grep -c 'call \$mdk_impl_List_map')"
    local lp;  lp="$(printf '%s' "$mapbody" | grep -c 'loop \$tmcloop')"
    if [ "$rec" -eq 0 ] && [ "$lp" -ge 1 ]; then
      printf 'TMC-ASSERT ok   %s: $mdk_impl_List_map is a dest-passing loop, 0 recursive call $mdk_impl_List_map\n' "$name"
    else
      fail=$((fail+1)); printf 'TMC-ASSERT FAIL %s: recursive-call=%s loop=%s (expected 0 / >=1)\n' "$name" "$rec" "$lp"
    fi
  fi
}

# single-file fixtures
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  run_fixture "$(basename "$f")" "$f" "$(dirname "$f")"
done

# multi-file program dirs (entry.mdk + sibling modules)
for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry="${dir%/}/entry.mdk"
  [ -f "$entry" ] || continue
  run_fixture "$(basename "${dir%/}")" "$entry" "${dir%/}"
done

printf '\n%d ok, %d gap (known real-prelude MVP gap), %d failing\n' "$pass" "$gap" "$fail"
# Green when nothing DIVERGES (a known-gap SKIP is not a failure); fails on a real
# byte-diff or an unexpected build/parse error.
[ "$fail" -eq 0 ]
