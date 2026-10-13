#!/usr/bin/env bash
# build_wasm_oracle.sh — compile the WasmGC emitter entries to native binaries via
# the OCaml-free `medaka build`, so the W2/W5 diff gates run without OCaml.  Peer of
# the ENTRIES rows in test/build_oracles.sh.
#
# DUAL-ENTRY (W5): two emitter binaries are built —
#   * test/bin/wasm_emit_main        — the W1–W4 PRELUDE-FREE scalar/ADT/closure
#     spike entry (annotateProgram path; never produces CMethod/CDict).  Gate:
#     test/wasm/diff_wasm.sh.
#   * test/bin/wasm_emit_typed_main  — the W5 TYPED dispatch entry (elaborateModules
#     path; produces CMethod/CDict/CImplEntry from prelude-free fixtures that define
#     their own minimal interfaces).  Gate: test/wasm/diff_wasm_typed.sh.
#   * test/bin/wasm_emit_modules_main — the MULTI-MODULE entry.  Gates:
#     test/wasm/diff_wasm_modules.sh, test/wasm/diff_sqlite.sh, test/build_wasm_cmd.sh,
#     and (the only one it needs) test/lib_engines_differential.sh, the body of the
#     test/diff_compiler_engines_part*.sh gates.
#
# ── targeted modes ────────────────────────────────────────────────────────────
# --modules-only builds only wasm_emit_modules_main. lib_engines_differential.sh reads
# exactly that binary and would otherwise pay ~2.6x for binaries its runner never opens.
# --typed-only builds only wasm_emit_typed_main for targeted diff_wasm_typed.sh recovery.
# The default remains unchanged and builds all three for the `wasm:` job's full gate set.
set -u

MODE=all
for a in "$@"; do
  case "$a" in
    --modules-only)
      [ "$MODE" = all ] || { echo "usage: $0 [--modules-only | --typed-only]" >&2; exit 2; }
      MODE=modules
      ;;
    --typed-only)
      [ "$MODE" = all ] || { echo "usage: $0 [--modules-only | --typed-only]" >&2; exit 2; }
      MODE=typed
      ;;
    *) echo "usage: $0 [--modules-only | --typed-only]" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
ENTRY="$ROOT/compiler/entries/wasm_emit_main.mdk"
ENTRY_TYPED="$ROOT/compiler/entries/wasm_emit_typed_main.mdk"
ENTRY_MODULES="$ROOT/compiler/entries/wasm_emit_modules_main.mdk"
OUT="$ROOT/test/bin/wasm_emit_main"
OUT_TYPED="$ROOT/test/bin/wasm_emit_typed_main"
OUT_MODULES="$ROOT/test/bin/wasm_emit_modules_main"

command -v clang >/dev/null 2>&1 || { echo "no clang — skipping (W2/W5 oracle needs the native build path)"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build the native compiler first: make medaka"; exit 2; }
[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"

mkdir -p "$ROOT/test/bin"
# Cold-build cost (#2209): each build appends one sample to ORACLE_TIMING_LOG when
# set (see test/build_oracles.sh); a no-op otherwise.
_ms() { # epoch ms; whole seconds where date has no %N (BSD/macOS)
  _n=$(date +%s%N 2>/dev/null)
  case "$_n" in ''|*[!0-9]*) echo $(( $(date +%s) * 1000 )) ;; *) echo $(( _n / 1000000 )) ;; esac
}
# WASM_EMITTER_OPT=-O0 builds the emitters unoptimised and without ThinLTO. They emit
# the same WAT, and the link is ~4x cheaper than the production -O2 + ThinLTO one, but
# the emitter then runs ~1.4x slower: that pays for a job that builds the emitters once
# and runs them a few hundred times (the `wasm` CI job), not for the engines gates,
# which run the modules emitter on every corpus row. Unset keeps the production link.
# MEDAKA_RT_OBJ / MEDAKA_PRELUDE_OBJ are compiled for the detected link mode, so the
# plain link compiles its own.
_build_timed() { # <entry> <out>
  _t0=$(_ms)
  if [ -n "${WASM_EMITTER_OPT:-}" ]; then
    env MEDAKA_NO_LTO=1 MEDAKA_RT_OBJ= MEDAKA_PRELUDE_OBJ= MEDAKA_CLANG_OPT="$WASM_EMITTER_OPT" \
      "$MEDAKA" build --allow-internal "$1" -o "$2" || return 1
  else
    "$MEDAKA" build --allow-internal "$1" -o "$2" || return 1
  fi
  sh "$ROOT/test/build_oracles.sh" --record-sample "$(basename "$2")" "$(( $(_ms) - _t0 ))" "${JOBS:-1}"
}
_build_one() { # <entry> <out>
  _build_timed "$1" "$2" || { echo "build failed for $1"; return 1; }
  echo "built $1 -> $2"
}
# --allow-internal: the emitter entries pull in the compiler graph, which uses the
# internal-only array-kernel externs (arrayGetUnsafe, …) — the same flag the LLVM
# entry oracles pass in test/build_oracles.sh.
#
# WASM_ORACLE_JOBS>1 builds every requested emitter at once (default 1: a box may be
# shared, and each build is single-threaded work, so CI is what sets it).
_pairs=""
if [ "$MODE" = all ]; then _pairs="$ENTRY|$OUT"; fi
if [ "$MODE" = all ] || [ "$MODE" = typed ]; then _pairs="$_pairs $ENTRY_TYPED|$OUT_TYPED"; fi
if [ "$MODE" = all ] || [ "$MODE" = modules ]; then _pairs="$_pairs $ENTRY_MODULES|$OUT_MODULES"; fi

_jobs="${WASM_ORACLE_JOBS:-1}"
_rc=0
if [ "$_jobs" -le 1 ]; then
  for _p in $_pairs; do
    _build_one "${_p%%|*}" "${_p##*|}" || exit 1
  done
else
  _pids=""
  for _p in $_pairs; do
    _build_one "${_p%%|*}" "${_p##*|}" &
    _pids="$_pids $!"
  done
  for _pid in $_pids; do wait "$_pid" || _rc=1; done
  exit "$_rc"
fi
