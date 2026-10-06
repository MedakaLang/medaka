#!/usr/bin/env bash
# diff_wasm.sh — Slice W2 differential gate (WASMGC-DESIGN.md §8).  Peer of
# test/diff_compiler_llvm.sh: for every fixture in the W2 corpus, emit a WasmGC
# WAT module, assemble+validate it with wasm-tools, run it under a WasmGC engine
# (Node >= 22), and diff its stdout against the ORACLE.
#
# ── The oracle (OCaml-free) ──────────────────────────────────────────────────
# The native-COMPILED binary `./medaka build <fixture> && ./<bin>`.  This is the
# faithful peer of the LLVM gate's oracle (eval_probe / a compiled binary that
# AUTO-PRINTS the value `main`).  NOTE: `./medaka run <fixture>` (the interpreter)
# does NOT auto-print a value main (Phase "Unit main no auto-print"); only the
# native-compiled binary applies the pp_value auto-print contract.  The WasmGC
# emitter mirrors that auto-print, so the compiled binary is the correct oracle —
# both are OCaml-free.  (This resolves the task's "diff against `medaka run`"
# framing, which would print nothing for these value mains.)
#
# A fixture that must stop with a coded runtime error (the Int overflow traps,
# arith_int63_*) pins its exact stderr line in a `-- expect-stderr: <line>` comment;
# both engines must exit 1 with exactly that line (a `<fixture>:LINE:COL: ` prefix
# pins the native trap site, see the worker).  Every other fixture must exit 0
# with empty stderr (w8_stderr_write excepted).
#
# Reports N/M passing; non-zero exit if any fixture diverges.  Opt-in skip (exit 2)
# when the toolchain (wasm-tools / Node>=22 / clang) is unavailable, mirroring the
# other native diff scripts.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
EMITBIN="$ROOT/test/bin/wasm_emit_main"
FIXDIR="$ROOT/test/wasm/fixtures"
RUNJS="$ROOT/test/wasm/run.js"
CC="${CC:-clang}"

# ── Per-fixture worker (parallel fan-out target) ───────────────────────────────
# Re-invoked as `bash "$0" --one <fixture>` under an xargs -P pool. All shared state
# (MEDAKA/EMITBIN/NODE-abs-path/RUNJS/WORKDIR/RESULTDIR/MEDAKA_EMITTER) arrives via
# env, so the worker skips the one-time tool + Node-version setup below.
# Per-fixture .err files (no shared scratch) so N run concurrently.
# NOTE: the oracle is built at -O2 (WASM_ORACLE_OPT), NOT -O0: the deep TCO
# fixtures (clos_deep_tco, clos_reftco_indirect) rely on clang's tail-call
# optimization to not stack-overflow — at -O0 the native oracle crashes on deep
# recursion and its (empty) output mismatches the return_call'd wasm. -O2 matches
# the pre-parallelization behavior exactly.
if [ "${1:-}" = "--one" ]; then
  f="$2"; name="$(basename "$f")"
  obin="$WORKDIR/$name.oracle"; wat="$WORKDIR/$name.wat"; wasm="$WORKDIR/$name.wasm"
  native_out="$WORKDIR/$name.native.out"; native_err="$WORKDIR/$name.native.err"
  node_out="$WORKDIR/$name.node.out"; node_err="$WORKDIR/$name.node.err"
  st=0; msg=""
  # A fixture that is MEANT to stop with a coded runtime error declares the exact
  # stderr line in a `-- expect-stderr: <line>` comment: both engines must then exit
  # 1 with exactly that stderr.  Every other fixture must exit 0 with empty stderr.
  # A located trap writes the line as `<fixture>:LINE:COL: <banner>`: the native
  # oracle expects the fixture's own path there, while this gate's prelude-free
  # wasm driver parses without a file name, has no site table and prints the
  # banner alone.
  exp_line="$(sed -n 's/^-- expect-stderr: //p' "$f")"
  case "$exp_line" in
    '<fixture>:'*)
      exp_nat="$f:${exp_line#<fixture>:}"
      exp_wasm="$(printf '%s\n' "$exp_line" | sed 's/^<fixture>:[0-9]*:[0-9]*: //')" ;;
    *) exp_nat="$exp_line"; exp_wasm="$exp_line" ;;
  esac
  exp_err="$exp_line"
  if ! MEDAKA_CLANG_OPT="${WASM_ORACLE_OPT:--O2}" "$MEDAKA" build --allow-internal "$f" -o "$obin" >"$WORKDIR/$name.build.err" 2>&1; then
    msg="$(printf 'FAIL %s (oracle build)\n%s' "$name" "$(cat "$WORKDIR/$name.build.err")")"; st=1
  else
    "$obin" >"$native_out" 2>"$native_err"; nrc=$?
    if [ -n "$exp_err" ] && { [ "$nrc" -ne 1 ] || ! printf '%s\n' "$exp_nat" | cmp -s - "$native_err"; }; then
      msg="$(printf 'FAIL %s (native trap contract: exit %s)\n  want: %s\n  got : %s' "$name" "$nrc" "$exp_nat" "$(cat "$native_err")")"; st=1
    elif [ -z "$exp_err" ] && [ "$nrc" -ne 0 ]; then
      msg="$(printf 'FAIL %s (native oracle run)\n%s' "$name" "$(cat "$native_err")")"; st=1
    elif [ -z "$exp_err" ] && [ "$name" = "w8_stderr_write.mdk" ] && ! printf 'diagnostic to stderr\n' | cmp -s - "$native_err"; then
      msg="FAIL $name (native stderr contract)"; st=1
    elif [ -z "$exp_err" ] && [ "$name" != "w8_stderr_write.mdk" ] && [ -s "$native_err" ]; then
      msg="$(printf 'FAIL %s (native oracle stderr)\n%s' "$name" "$(cat "$native_err")")"; st=1
    elif ! "$EMITBIN" "$f" > "$wat" 2>"$WORKDIR/$name.emit.err"; then
      msg="$(printf 'FAIL %s (wasm emit)\n%s' "$name" "$(cat "$WORKDIR/$name.emit.err")")"; st=1
    elif [ "$name" = "w8b_math_host_import.mdk" ] &&
         { ! grep -F '(import "env" "mdk_sin"' "$wat" >/dev/null ||
           ! grep -F 'call $mdk_sin' "$wat" >/dev/null; }; then
      msg="FAIL $name (missing mdk_sin host import/direct call)"; st=1
    elif ! wasm-tools parse "$wat" -o "$wasm" 2>"$WORKDIR/$name.parse.err"; then
      msg="$(printf 'FAIL %s (wasm-tools parse)\n%s' "$name" "$(cat "$WORKDIR/$name.parse.err")")"; st=1
    elif ! wasm-tools validate --features=all "$wasm" 2>"$WORKDIR/$name.val.err"; then
      msg="$(printf 'FAIL %s (wasm-tools validate)\n%s' "$name" "$(cat "$WORKDIR/$name.val.err")")"; st=1
    else
      "$NODE" "$RUNJS" "$wasm" >"$node_out" 2>"$node_err"; wrc=$?
      if [ -n "$exp_err" ] && { [ "$wrc" -ne 1 ] || ! printf '%s\n' "$exp_wasm" | cmp -s - "$node_err"; }; then
        msg="$(printf 'FAIL %s (wasm trap contract: exit %s)\n  want: %s\n  got : %s' "$name" "$wrc" "$exp_wasm" "$(cat "$node_err")")"; st=1
      elif [ -z "$exp_err" ] && [ "$wrc" -ne 0 ]; then
        msg="$(printf 'FAIL %s (wasm run)\n%s' "$name" "$(cat "$node_err")")"; st=1
      elif [ -n "$exp_err" ]; then
        if cmp -s "$native_out" "$node_out"; then
          msg="ok   $name"
        else
          msg="$(printf 'FAIL %s\n  oracle: %s\n  wasm  : %s' "$name" "$(cat "$native_out")" "$(cat "$node_out")")"; st=1
        fi
      elif [ "$name" = "w8_stderr_write.mdk" ] && ! printf 'diagnostic to stderr\n' | cmp -s - "$node_err"; then
        msg="FAIL $name (wasm stderr contract)"; st=1
      elif [ "$name" != "w8_stderr_write.mdk" ] && [ -s "$node_err" ]; then
        msg="$(printf 'FAIL %s (wasm stderr)\n%s' "$name" "$(cat "$node_err")")"; st=1
      elif [ "$name" = "w11_char_from_code_pointfree.mdk" ] &&
           { ! printf 'A\n' | cmp -s - "$native_out" || ! printf 'A\n' | cmp -s - "$node_out"; }; then
        msg="FAIL $name (expected exact stdout A)"; st=1
      elif cmp -s "$native_out" "$node_out"; then
        msg="ok   $name"
      else
        msg="$(printf 'FAIL %s\n  oracle: %s\n  wasm  : %s' "$name" "$(cat "$native_out")" "$(cat "$node_out")")"; st=1
      fi
    fi
  fi
  echo "$st" > "$RESULTDIR/$name.status"
  printf '%s\n' "$msg"
  exit 0
fi

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping W2 gate"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) — skipping W2 gate"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build the native compiler first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITBIN" ] || { echo "build the wasm emitter oracle: sh test/wasm/build_wasm_oracle.sh (missing $EMITBIN)"; exit 2; }

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
  echo "W2 SKIP  Node >= 22 required for the finalized WasmGC encoding (have $($NODE --version 2>/dev/null))"
  exit 2
fi

# the native-compiled oracle needs the native emitter so `medaka build` is OCaml-free.
[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"

WORK="$(mktemp -d)"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$WORK" "$RESULTS"' EXIT

# Fan fixtures across an xargs -P pool of --one workers (see top of file).
# Each worker does: medaka build oracle (-O0) + run, wasm emit, wasm-tools
# parse/validate, node run, diff. NODE is resolved to its absolute path here (post
# nvm selection) so the fresh worker shells don't re-run the Node-version dance.
# --allow-internal: the w10 array-kernel fixtures use internal-only externs.
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
NODE_ABS="$(command -v "$NODE" 2>/dev/null || echo "$NODE")"
fixtures=("$FIXDIR"/*.mdk)
[ -e "${fixtures[0]}" ] || { echo "FAIL W2: no fixtures in $FIXDIR"; exit 1; }
fixture_count="${#fixtures[@]}"
if ! printf '%s\n' "${fixtures[@]}" \
  | MEDAKA="$MEDAKA" EMITBIN="$EMITBIN" NODE="$NODE_ABS" RUNJS="$RUNJS" \
    MEDAKA_EMITTER="${MEDAKA_EMITTER:-$EMITTER}" WASM_ORACLE_OPT="${WASM_ORACLE_OPT:-}" \
    WORKDIR="$WORK" RESULTDIR="$RESULTS" \
    xargs -P "$JOBS" -I{} bash "$0" --one {}; then
  echo "FAIL W2: fixture worker pipeline"
  exit 1
fi

pass=0; fail=0
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  if [ "$(cat "$s")" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
status_count=$((pass + fail))
[ "$status_count" -eq "$fixture_count" ] || {
  echo "FAIL W2: expected $fixture_count statuses, found $status_count"
  exit 1
}

printf '\n%d ok, %d failing\n' "$pass" "$fail"

# ── W4 TCO IR-shape assertion (decisive: prove return_call FIRED, not just that the
# program completed) ─────────────────────────────────────────────────────────────
# A deep tail-recursive fn must lower its tail self-call to `return_call`, never a
# plain `call`+fall-through (which would grow the wasm stack and crash at depth).
# We re-emit two tail-recursive fixtures and grep their recursive fn bodies.
tco_assert() {
  fix="$1"; fn="$2"
  wat="$WORK/$fix.tco.wat"
  "$EMITBIN" "$FIXDIR/$fix" > "$wat" 2>/dev/null || { echo "TCO-ASSERT FAIL $fix (emit)"; tco_fail=1; return; }
  # isolate the function body: from `(func $<fn>` to its closing `  )`.
  body="$(awk "/\\(func \\\$$fn /{f=1} f{print} f&&/^  \\)\$/{exit}" "$wat")"
  if printf '%s' "$body" | grep -q 'return_call'; then
    # also assert NO plain `call $<fn>` survives in the tail (would be non-TCO).
    if printf '%s' "$body" | grep -qE "^\s*call \\\$$fn\b"; then
      echo "TCO-ASSERT FAIL $fix: a plain 'call \$$fn' survives in the tail (not TCO'd)"; tco_fail=1
    else
      echo "TCO-ASSERT ok   $fix: \$$fn tail-self-call emits return_call"
    fi
  else
    echo "TCO-ASSERT FAIL $fix: \$$fn body has no return_call (TCO did not fire)"; tco_fail=1
  fi
}
tco_fail=0
if [ "$fail" -eq 0 ]; then
  tco_assert clos_deep_tco.mdk loop
  tco_assert clos_reftco_indirect.mdk loop
  tco_assert fn_tailsum.mdk sumTo
fi

# ── (b′) dispatch-TMC IR-shape assertion (WASMGC-TRMC Stage 2) ─────────────────
# The synthetic dispatch fixture's `scan`-rooted group must lower to a reset wrapper
# `$scan` + an inner loop `$scan__disploop`, and NO spine cons leaf may emit a
# recursive `call $scan` (the overflow shape) — every spine edge is a `return_call`
# to the inner loop.  Proves "dispatch-TMC fired", not merely "the program ran".
disp_fail=0
if [ "$fail" -eq 0 ]; then
  dwat="$WORK/w_trmc_dispatch.disp.wat"
  if "$EMITBIN" "$FIXDIR/w_trmc_dispatch.mdk" > "$dwat" 2>/dev/null; then
    # the group bodies = every fn EXCEPT main/lenAcc (which legitimately call the $scan
    # wrapper as a normal, non-recursive entry).  Extract the scan/scanAt/leaf* funcs.
    groupbodies="$(awk '/\(func \$(scan|scanAt|leafA|leafB|leafC|next|scan__disploop) /{f=1} f{print} f&&/^  \)$/{f=0}' "$dwat")"
    if ! grep -q '(func \$scan__disploop ' "$dwat"; then
      echo "DISP-ASSERT FAIL w_trmc_dispatch: no \$scan__disploop inner loop (group not detected)"; disp_fail=1
    elif printf '%s' "$groupbodies" | grep -qE '(^|[^_a-zA-Z])call \$scan( |$)'; then
      echo "DISP-ASSERT FAIL w_trmc_dispatch: a recursive 'call \$scan' survives in a group body (overflow shape)"; disp_fail=1
    elif ! grep -q 'return_call \$scan__disploop' "$dwat"; then
      echo "DISP-ASSERT FAIL w_trmc_dispatch: no 'return_call \$scan__disploop' (spine leaf not redirected)"; disp_fail=1
    else
      echo "DISP-ASSERT ok   w_trmc_dispatch: \$scan group lowers to reset-wrapper + \$scan__disploop, 0 recursive call \$scan in group bodies"
    fi
  else
    echo "DISP-ASSERT FAIL w_trmc_dispatch (emit)"; disp_fail=1
  fi
fi

# ── Stage-1b self-TMC IR-shape assertion (WASMGC-TRMC Stage 1b) ────────────────
# The `stripComments`-shaped fixture's `strip` fn is a MULTI-CLAUSE, PATTERN-PARAM
# self-recursive builder {cons-tail + plain-tail-drop + base}.  Stage-1b routes its
# clause-dispatch chain through the destination-passing loop, so NO recursive
# `call $strip` survives in the loop body — every leaf edge is a `br $tmcloop`
# (cons-into-dest / plain-tail-drop) or `br $tmcexit` (base).  Proves "self-TMC fired
# for the patterned multi-clause shape", not merely that the program ran.
strip_fail=0
if [ "$fail" -eq 0 ]; then
  swat="$WORK/w_trmc_strip_clauses.s1b.wat"
  if "$EMITBIN" "$FIXDIR/w_trmc_strip_clauses.mdk" > "$swat" 2>/dev/null; then
    sbody="$(awk '/\(func \$strip /{f=1} f{print} f&&/^  \)$/{exit}' "$swat")"
    if printf '%s' "$sbody" | grep -qE '^\s*call \$strip\b'; then
      echo "S1B-ASSERT FAIL w_trmc_strip_clauses: a recursive 'call \$strip' survives in the loop (overflow shape)"; strip_fail=1
    elif ! printf '%s' "$sbody" | grep -q 'br \$tmcloop'; then
      echo "S1B-ASSERT FAIL w_trmc_strip_clauses: no 'br \$tmcloop' in \$strip (self-TMC did not fire)"; strip_fail=1
    elif ! printf '%s' "$sbody" | grep -q 'br \$tmcexit'; then
      echo "S1B-ASSERT FAIL w_trmc_strip_clauses: no 'br \$tmcexit' in \$strip (base leaf not redirected)"; strip_fail=1
    else
      echo "S1B-ASSERT ok   w_trmc_strip_clauses: \$strip (multi-clause patterned {cons-tail+plain-tail-drop+base}) lowers to the dest-passing loop, 0 recursive call \$strip"
    fi
  else
    echo "S1B-ASSERT FAIL w_trmc_strip_clauses (emit)"; strip_fail=1
  fi
fi

# ── Entry assertion: `start` runs only the value inits; the program is `mdk_main` ──
# Instantiate an emitted module WITHOUT calling the export: no stdout, no stderr, no
# exit.  Then call `mdk_main` on the same instance: stdout must equal the oracle's.
# One scalar-mode fixture (value globals, so `start` does real work) and one
# ref-mode fixture.  Imports beyond the two write channels throw, so a module that
# reached any other host import before `mdk_main` fails loudly here.
entry_fail=0
if [ "$fail" -eq 0 ]; then
  for fix in global_chain.mdk str_putstrln.mdk; do
    got="$WORK/$fix.entry.out"
    if "$NODE" -e '
      const fs = require("fs");
      const mod = new WebAssembly.Module(fs.readFileSync(process.argv[1]));
      const out = [], err = [];
      const env = {};
      for (const i of WebAssembly.Module.imports(mod))
        env[i.name] = () => { throw new Error("host import " + i.name + " reached"); };
      env.mdk_write_byte = (b) => { out.push(b & 0xff); };
      env.mdk_write_err_byte = (b) => { err.push(b & 0xff); };
      const inst = new WebAssembly.Instance(mod, { env });
      if (out.length || err.length) {
        console.error("instantiated without mdk_main wrote " + out.length + " stdout / " + err.length + " stderr bytes");
        process.exit(1);
      }
      inst.exports.mdk_main();
      fs.writeFileSync(process.argv[2], Buffer.from(out));
    ' "$WORK/$fix.wasm" "$got" 2>"$WORK/$fix.entry.err"; then
      if cmp -s "$WORK/$fix.native.out" "$got"; then
        echo "ENTRY-ASSERT ok   $fix: instantiated without mdk_main prints nothing; mdk_main prints the oracle's $(wc -c <"$got" | tr -d ' ') bytes"
      else
        echo "ENTRY-ASSERT FAIL $fix: mdk_main output differs from the oracle"; entry_fail=1
      fi
    else
      echo "ENTRY-ASSERT FAIL $fix: $(cat "$WORK/$fix.entry.err")"; entry_fail=1
    fi
  done
  # A module from before the split calls `main` from `start` and lacks the
  # `mdk_entry_split` marker.  Rebuild that shape from an emitted module and
  # require run.js to refuse it before instantiation: exit 1, the named error on
  # stderr, and no program output (calling `mdk_main` would run `main` twice).
  fix=str_putstrln.mdk
  old="$WORK/$fix.oldshape"
  awk '/entry_split/ { next }
       $0 == "  (start $__init)" { print "    call $__main"; print prev; print; held = 0; next }
       { if (held) print prev; prev = $0; held = 1 }
       END { if (held) print prev }' "$WORK/$fix.wat" > "$old.wat"
  if ! grep -q '^    call \$__main$' "$old.wat" || ! wasm-tools parse "$old.wat" -o "$old.wasm" 2>"$old.parse.err"; then
    echo "ENTRY-ASSERT FAIL $fix: could not build the old-shape module: $(cat "$old.parse.err" 2>/dev/null)"; entry_fail=1
  else
    "$NODE" "$RUNJS" "$old.wasm" >"$old.out" 2>"$old.err"; orc=$?
    if [ "$orc" -eq 1 ] && [ ! -s "$old.out" ] && grep -q 'built by an older compiler' "$old.err"; then
      echo "ENTRY-ASSERT ok   $fix: an old-shape module (main in start, no marker) is refused with exit 1 and no output"
    else
      echo "ENTRY-ASSERT FAIL $fix: old-shape module not refused: exit $orc, stdout $(wc -c <"$old.out" | tr -d ' ') bytes, stderr: $(cat "$old.err")"; entry_fail=1
    fi
  fi
fi

[ "$fail" -eq 0 ] && [ "$tco_fail" -eq 0 ] && [ "$disp_fail" -eq 0 ] && [ "$strip_fail" -eq 0 ] && [ "$entry_fail" -eq 0 ]
