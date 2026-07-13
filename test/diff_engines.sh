#!/usr/bin/env bash
# diff_engines.sh — the THREE-ENGINE differential gate (TESTING-DESIGN.md §4.4).
#
# Medaka owns three independent implementations of its own semantics:
#
#   eval    the tree-walking interpreter   compiler/eval/eval.mdk      (`medaka run`)
#   native  the LLVM backend               compiler/backend/llvm_emit.mdk (`medaka build`)
#   wasm    the WasmGC backend             compiler/backend/wasm_emit.mdk
#
# …and, before this gate, no program in the tree was ever compared across all
# three.  The one two-way check that existed (diff_compiler_llvm.sh) diffs the
# native binary's stdout against a `.eval.golden` FILE — a frozen capture of the
# interpreter — so an interpreter bug that got captured became the *expected*
# answer for the backend too.  This gate removes that circularity: it runs all
# three engines LIVE on the same source and diffs them against EACH OTHER.
#
#   for each fixture f:   eval(f) == native(f) == wasm(f)   else FAIL
#
# ── The auto-print contract (why there is an `eval_autoprint_main` probe) ──────
# Nearly every fixture in both corpora is a bare VALUE main (`main = 1 + 2`).
# `medaka build` rewrites that to `main = println <e>` (driver/main_autoprint.mdk)
# and the WasmGC emitter mirrors the same auto-print — but `medaka run` REFUSES a
# value main by design ("'main' must be a value of type Unit").  That is a CLI/UX
# decision, not a semantic difference, so using `medaka run` verbatim would report
# every fixture as a spurious three-way disagreement.  The interpreter arm is
# therefore compiler/entries/eval_autoprint_main.mdk = `medaka run`'s exact
# load→elaborate→evalModules path PLUS the same auto-print wrap.
#
# ── Arms ──────────────────────────────────────────────────────────────────────
#   eval    test/bin/eval_autoprint_main <runtime> <core> <f> <dir(f)> <stdlib>
#   native  medaka build --allow-internal <f> -o <UNIQUE>.bin && <UNIQUE>.bin
#   wasm    test/bin/wasm_emit_main <f> | wasm-tools parse+validate | node run.js
#
# ⚠️ The native arm's `-o` basename MUST be unique per fixture.  build_cmd.mdk
# derives its scratch IR path from the output BASENAME, not the full path
# (`/tmp/medaka_build_<baseOf outPath>.ll`, build_cmd.mdk:173), so N concurrent
# builds that all write `-o <somedir>/bin` all fight over `/tmp/medaka_build_bin.ll`
# and silently produce each other's programs.  (This gate hit exactly that: it
# reported a stable-looking 20-vs-8 "backend disagreement" that was really one
# worker's IR linked into another's binary.)
#
# The wasm arm goes through the PRELUDE-FREE annotate entry (wasm_emit_main), the
# same entry test/wasm/diff_wasm.sh uses.  The real-prelude WasmGC path
# (wasm_emit_modules_main) still has the point-free-impl eta-expansion gap
# documented in test/wasm/diff_wasm_modules.sh, so it cannot run this corpus.  A
# fixture the wasm arm cannot emit/validate is reported as a wasm N/A, never a
# silent skip (TESTING-DESIGN.md §2.3).
#
# Usage:  bash test/diff_engines.sh              # whole union corpus
#         bash test/diff_engines.sh --one <f>    # single fixture (worker entry)
#         JOBS=4 bash test/diff_engines.sh
#         VERBOSE=1 bash test/diff_engines.sh    # print every fixture's verdict
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
EVALBIN="$ROOT/test/bin/eval_autoprint_main"
WASMBIN="$ROOT/test/bin/wasm_emit_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
STDLIB="$ROOT/stdlib"
RUNJS="$ROOT/test/wasm/run.js"
TIMEOUT="${TIMEOUT:-60}"

# run <secs> <cmd...> — portable alarm-based timeout (no coreutils `timeout` on mac).
run_t() { perl -e 'alarm shift; exec @ARGV' "$@"; }

# ── per-fixture worker ────────────────────────────────────────────────────────
# Produces one TSV line on stdout:  <name> \t <verdict> \t <eval-st> \t <native-st> \t <wasm-st>
# and, on disagreement, a human block on fd 3 (collected into $RESULTDIR/<name>.detail).
if [ "${1:-}" = "--one" ]; then
  f="$2"
  # key by CORPUS + basename: 5 basenames (adt_option, fn_factorial, fn_gcd,
  # fn_tailsum, global_chain) exist in BOTH corpora as different files; keying on
  # the bare basename would race two workers onto one work/result dir.
  case "$f" in
    */llvm_fixtures/*) name="llvm/$(basename "$f" .mdk)" ;;
    */wasm/fixtures/*) name="wasm/$(basename "$f" .mdk)" ;;
    *)                 name="other/$(basename "$f" .mdk)" ;;
  esac
  key="${name//\//__}"
  W="$WORKDIR/$key"; mkdir -p "$W"

  # -- eval ---------------------------------------------------------------------
  if run_t "$TIMEOUT" "$EVALBIN" "$RUNTIME" "$CORE" "$f" "$(dirname "$f")" "$STDLIB" \
       >"$W/eval.out" 2>"$W/eval.err"; then est=ok; else est="err$?"; fi
  # the probe reports loader/parse failures on stderr and still exits 0 — treat a
  # non-empty stderr with empty stdout as an eval N/A, not an empty-output answer.
  if [ "$est" = ok ] && [ ! -s "$W/eval.out" ] && [ -s "$W/eval.err" ]; then est=na; fi

  # -- native -------------------------------------------------------------------
  nst=ok
  if ! run_t "$TIMEOUT" "$MEDAKA" build --allow-internal "$f" -o "$W/$key.bin" >"$W/build.err" 2>&1; then
    nst=build
  else
    run_t "$TIMEOUT" "$W/$key.bin" >"$W/native.out" 2>"$W/native.err" || nst="exit$?"
  fi

  # -- wasm ---------------------------------------------------------------------
  wst=ok
  if ! run_t "$TIMEOUT" "$WASMBIN" "$f" >"$W/w.wat" 2>"$W/wemit.err"; then
    wst=emit
  elif ! wasm-tools parse "$W/w.wat" -o "$W/w.wasm" 2>"$W/wparse.err"; then
    wst=parse
  elif ! wasm-tools validate --features=all "$W/w.wasm" 2>"$W/wval.err"; then
    wst=validate
  else
    run_t "$TIMEOUT" "$NODE" "$RUNJS" "$W/w.wasm" >"$W/wasm.out" 2>"$W/wrun.err" || wst="exit$?"
  fi

  # -- compare ------------------------------------------------------------------
  # Only arms that RAN (ok, or a non-zero exit that still produced its stdout —
  # the abort_* fixtures legitimately exit non-zero) take part in the diff.  An
  # arm that could not even produce a program (build/emit/parse/validate/na) is
  # N/A and is excluded, and reported as such.
  ran_eval=0; ran_native=0; ran_wasm=0
  case "$est" in ok|exit*) ran_eval=1 ;; esac
  case "$nst" in ok|exit*) ran_native=1 ;; esac
  case "$wst" in ok|exit*) ran_wasm=1 ;; esac

  verdict=agree; n=0
  [ $ran_eval  = 1 ] && n=$((n+1))
  [ $ran_native = 1 ] && n=$((n+1))
  [ $ran_wasm  = 1 ] && n=$((n+1))
  if [ "$n" -lt 2 ]; then verdict=insufficient; fi

  if [ "$verdict" = agree ]; then
    if [ $ran_eval = 1 ] && [ $ran_native = 1 ] && ! cmp -s "$W/eval.out" "$W/native.out"; then verdict=DISAGREE; fi
    if [ $ran_eval = 1 ] && [ $ran_wasm  = 1 ] && ! cmp -s "$W/eval.out" "$W/wasm.out";  then verdict=DISAGREE; fi
    if [ $ran_native = 1 ] && [ $ran_wasm = 1 ] && ! cmp -s "$W/native.out" "$W/wasm.out"; then verdict=DISAGREE; fi
    if [ "$verdict" = agree ] && [ "$n" -eq 3 ]; then verdict=agree3; fi
  fi

  if [ "$verdict" = DISAGREE ]; then
    {
      printf '### %s\n' "$name"
      printf '  eval  [%s]: %s\n' "$est" "$(head -c 300 "$W/eval.out" 2>/dev/null | tr '\n' '|')"
      printf '  nativ [%s]: %s\n' "$nst" "$(head -c 300 "$W/native.out" 2>/dev/null | tr '\n' '|')"
      printf '  wasm  [%s]: %s\n' "$wst" "$(head -c 300 "$W/wasm.out" 2>/dev/null | tr '\n' '|')"
    } > "$RESULTDIR/$key.detail"
  fi
  # keep the first line of each arm's failure reason for the N/A census
  { printf 'eval:%s\n' "$(head -1 "$W/eval.err" 2>/dev/null)"
    printf 'native:%s\n' "$(head -1 "$W/build.err" 2>/dev/null)"
    printf 'wasm:%s\n' "$(head -1 "$W/wemit.err" 2>/dev/null; head -1 "$W/wval.err" 2>/dev/null; head -1 "$W/wrun.err" 2>/dev/null)"
  } > "$RESULTDIR/$key.why"

  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$verdict" "$est" "$nst" "$wst" > "$RESULTDIR/$key.tsv"
  [ -n "${VERBOSE:-}" ] && printf '%-10s %-40s eval=%-6s native=%-6s wasm=%s\n' "$verdict" "$name" "$est" "$nst" "$wst"
  rm -rf "$W"
  exit 0
fi

# ── driver ────────────────────────────────────────────────────────────────────
[ -x "$MEDAKA" ]  || { echo "build the native compiler first: make medaka"; exit 2; }
[ -x "$EVALBIN" ] || { echo "missing $EVALBIN — build it: medaka build --allow-internal compiler/entries/eval_autoprint_main.mdk -o test/bin/eval_autoprint_main"; exit 2; }
[ -x "$WASMBIN" ] || { echo "missing $WASMBIN — build it: sh test/wasm/build_wasm_oracle.sh"; exit 2; }
command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH"; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "no clang"; exit 2; }

NODE="${NODE:-node}"
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 24 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
[ "$major" -ge 24 ] || { echo "Node >= 24 required for finalized WasmGC (have $($NODE --version 2>/dev/null))"; exit 2; }
NODE="$(command -v "$NODE")"

[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"

WORK="$(mktemp -d)"; RESULTS="$(mktemp -d)"
trap 'rm -rf "$WORK" "$RESULTS"' EXIT

# the union corpus: LLVM fixtures + WasmGC fixtures (5 overlap by basename; both
# copies are run — they are different files under different roots).
CORPUS="$(ls "$ROOT"/test/llvm_fixtures/*.mdk "$ROOT"/test/wasm/fixtures/*.mdk 2>/dev/null)"
JOBS="${JOBS:-4}"

printf '%s\n' "$CORPUS" \
  | MEDAKA="$MEDAKA" EVALBIN="$EVALBIN" WASMBIN="$WASMBIN" RUNTIME="$RUNTIME" CORE="$CORE" \
    STDLIB="$STDLIB" RUNJS="$RUNJS" NODE="$NODE" TIMEOUT="$TIMEOUT" VERBOSE="${VERBOSE:-}" \
    MEDAKA_EMITTER="${MEDAKA_EMITTER:-}" WORKDIR="$WORK" RESULTDIR="$RESULTS" \
    xargs -P "$JOBS" -n 1 -I{} bash "$0" --one {}

cat "$RESULTS"/*.tsv > "$WORK/all.tsv" 2>/dev/null

total=$(wc -l < "$WORK/all.tsv" | tr -d ' ')
agree3=$(awk -F'\t' '$2=="agree3"' "$WORK/all.tsv" | wc -l | tr -d ' ')
agree2=$(awk -F'\t' '$2=="agree"' "$WORK/all.tsv" | wc -l | tr -d ' ')
disagree=$(awk -F'\t' '$2=="DISAGREE"' "$WORK/all.tsv" | wc -l | tr -d ' ')
insuf=$(awk -F'\t' '$2=="insufficient"' "$WORK/all.tsv" | wc -l | tr -d ' ')

ev_ok=$(awk -F'\t' '$3=="ok"||$3~/^exit/' "$WORK/all.tsv" | wc -l | tr -d ' ')
na_ok=$(awk -F'\t' '$4=="ok"||$4~/^exit/' "$WORK/all.tsv" | wc -l | tr -d ' ')
wa_ok=$(awk -F'\t' '$5=="ok"||$5~/^exit/' "$WORK/all.tsv" | wc -l | tr -d ' ')

echo
echo "──────────────────────────────────────────────────────────────"
printf 'corpus              %s fixtures\n' "$total"
printf 'eval   can run      %s\n' "$ev_ok"
printf 'native can run      %s\n' "$na_ok"
printf 'wasm   can run      %s\n' "$wa_ok"
echo
printf 'agree (all 3)       %s\n' "$agree3"
printf 'agree (2 engines)   %s\n' "$agree2"
printf 'DISAGREE            %s\n' "$disagree"
printf '<2 engines ran      %s\n' "$insuf"
echo "──────────────────────────────────────────────────────────────"

if [ "$disagree" -gt 0 ]; then
  echo
  echo "DISAGREEMENTS:"
  cat "$RESULTS"/*.detail 2>/dev/null
fi

# machine-readable dump for triage
[ -n "${DUMP:-}" ] && { cp "$WORK/all.tsv" "$DUMP.tsv"; cat "$RESULTS"/*.why > "$DUMP.why" 2>/dev/null; \
  for w in "$RESULTS"/*.why; do echo "== $(basename "$w" .why)"; cat "$w"; done > "$DUMP.why"; }

[ "$disagree" -eq 0 ]
