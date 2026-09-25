#!/bin/sh
# Validation for the NATIVE medaka CLI (Phase C), RE-ROOTED off the OCaml oracle
# (REROOT-PLAN §2d).  compiler/driver/medaka_cli.mdk, native-compiled to ./medaka,
# must reproduce committed goldens for check / fmt / new / repl / run / test / build.
#
# Per subtest the OCaml oracle leg is replaced by a committed golden (originally
# captured from the OCaml reference, now re-minted from native — OCaml-free).
# Re-mint ALL subsections in one command: `sh test/capture_goldens.sh --frozen
# native_cli` (#621 — mirrors this gate's own producers exactly). The native leg
# stays `./medaka <subcmd>`.  Goldens live under test/native_cli_goldens/{check,fmt,
# new,run,test,build} + the inline fixtures are committed under
# test/native_cli_fixtures/{run,test}.
#
#   check  — native `./medaka check <f>`  ==  check/<n>.golden (check_main inferred-
#            signature dump, sorted; both sides sorted).
#   fmt    — native `./medaka fmt --stdout <f>`  ==  fmt/<n>.golden.
#   new    — native `./medaka new proj` tree  ==  new/proj (file contents).
#   run    — native `./medaka run <f>`  ==  run/<n>.golden.
#   test   — native `./medaka test <f>`  ==  test/<n>.golden.
#   build  — native `./medaka build <f> -o X && X`  ==  build/<n>.golden (program
#            runtime stdout from the OCaml-built binary).  Emit host = the native
#            ./medaka_emitter (MEDAKA_EMITTER) — OCaml-free.
#
# DOCUMENTED EXCEPTIONS (REROOT-PLAN STOP guardrail):
#   repl/session — the OCaml `medaka repl` and the self-hosted repl DIVERGE on
#     post-error prompt behaviour (see diff_compiler_repl.sh header).  The native
#     repl is CANONICAL, so this subtest diffs native `./medaka repl` against the
#     SAME canonical native golden (test/repl_fixtures/session.golden), NOT OCaml.
#   lsp/session — the native `./medaka lsp` host is now buildable (import-scoped
#     multi-module typecheck seeding, commit d2d12a4), so this leg drives the
#     CANONICAL native LSP through an initialize/didOpen/documentSymbol/hover
#     session and diffs the decoded responses against a committed native golden
#     (test/native_cli_goldens/lsp/session.ndjson).  OCaml-free.
#   test/dir — `medaka test <dir>` (#82 row 2) post-dates OCaml removal
#     entirely (OCaml `medaka test` was always single-file), so this leg is
#     OCaml-free by construction: it diffs native `./medaka test
#     test/native_cli_fixtures/test_dir` against a committed native golden
#     (test/native_cli_goldens/test/dir.golden).
#
# The native runtime auto-prints main's Unit value as a trailing "0"; strip it
# (strip_unit) before comparing.  Every invocation is bounded by perl alarm.
#
# Usage:  sh test/diff_native_cli.sh
# Exit:   0 if every wired subtest matches its golden (lsp SKIPPED), else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
GOLD="$ROOT/test/native_cli_goldens"
FIX="$ROOT/test/native_cli_fixtures"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

# A Unit-returning `main` no longer auto-prints (gated in llvm_emit.mdk), so the
# native CLI emits no trailing "0" line.  This delete-if-bare-"0" form is a no-op
# now, but stays as a safety net; the old `s/0$//` suffix-strip corrupted any
# real last line ending in 0 (e.g. "10" -> "1") once the trailing line vanished.
strip_unit() { sed '${/^0$/d;}'; }

pass=0; fail=0

# ── check ─────────────────────────────────────────────────────────────────────
for f in "$ROOT"/test/diff_fixtures/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"; n="$(basename "$f" .mdk)"
  golden="$GOLD/check/$n.golden"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL check/%s (no golden)\n' "$name"; continue; }
  want="$(cat "$golden")"
  # --types: preserve the full prelude+user scheme dump these goldens capture
  # (bare `check`, since audit #6, filters the dump down to the file's own
  # bindings — see checkRoute in medaka_cli.mdk).
  got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check --types "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   check/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL check/%s\n' "$name"
    printf '  want: %s\n  got:  %s\n' "$want" "$got"; fi
done

# ── fmt ───────────────────────────────────────────────────────────────────────
for f in "$ROOT"/test/fmt_fixtures/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"; n="$(basename "$f" .mdk)"
  golden="$GOLD/fmt/$n.golden"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL fmt/%s (no golden)\n' "$name"; continue; }
  want="$(cat "$golden")"
  got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" fmt --stdout "$f" 2>/dev/null | strip_unit)"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   fmt/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL fmt/%s\n' "$name"; fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── check (terse success line, #916) ────────────────────────────────────────
# Bare `medaka check <clean file>` (no `--types`) used to give no unambiguous
# success signal — the check/*.golden subtest above never exercises this: it
# always passes `--types`, which is the byte-identical historical full-dump
# escape hatch and is deliberately NOT where #916's terse line appears. No
# existing golden anywhere in the tree captures bare `check`'s stdout on a
# clean file (confirmed: only `check/*.golden`, always run with `--types`) —
# this closes that coverage hole, which is also why the #916 fix moved only
# ONE snapshot (medaka_cli.mdk's own).
#
# Inline fixtures, not test/diff_fixtures/* (avoids enrolling in that shared
# corpus's other consumers, and lets the expected declaration COUNT be known
# by construction rather than derived from a fixture nobody wrote for this).
mkdir -p "$TMP/terse"
cat > "$TMP/terse/two_decls.mdk" <<'EOF'
export addOne x = x + 1
export double x = x * 2
EOF
cat > "$TMP/terse/main_only.mdk" <<'EOF'
main = println "hi"
EOF

name="check_terse/two_decls"
got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/terse/two_decls.mdk" 2>/dev/null | strip_unit)"
got_last="$(printf '%s\n' "$got" | tail -1)"
want_line="-- $TMP/terse/two_decls.mdk: ok (2 declaration(s) checked, 0 errors)"
if [ "$got_last" = "$want_line" ]; then
  pass=$((pass+1)); printf 'ok   %s\n' "$name"
else
  fail=$((fail+1)); printf 'FAIL %s\n  want last line: %s\n  got:\n%s\n' "$name" "$want_line" "$got"
fi

name="check_terse/main_only"
got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/terse/main_only.mdk" 2>/dev/null | strip_unit)"
got_last="$(printf '%s\n' "$got" | tail -1)"
want_line="-- $TMP/terse/main_only.mdk: ok (1 declaration(s) checked, 0 errors)"
if [ "$got_last" = "$want_line" ]; then
  pass=$((pass+1)); printf 'ok   %s\n' "$name"
else
  fail=$((fail+1)); printf 'FAIL %s\n  want last line: %s\n  got:\n%s\n' "$name" "$want_line" "$got"
fi

# ── new ───────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/nat"
( cd "$TMP/nat" && MEDAKA_ROOT="$ROOT" bound "$MEDAKA" new proj >/dev/null 2>&1 )
goldfiles="$(cd "$GOLD/new/proj" 2>/dev/null && find . -type f | LC_ALL=C sort)"
natfiles="$(cd "$TMP/nat/proj" 2>/dev/null && find . -type f | LC_ALL=C sort)"
if [ "$goldfiles" = "$natfiles" ] && [ -n "$goldfiles" ]; then
  new_ok=1
  for rel in $goldfiles; do
    if ! cmp -s "$GOLD/new/proj/$rel" "$TMP/nat/proj/$rel"; then new_ok=0;
      printf '  differ: %s\n' "$rel"; fi
  done
  if [ "$new_ok" = 1 ]; then pass=$((pass+1)); printf 'ok   new/tree\n'
  else fail=$((fail+1)); printf 'FAIL new/tree (file contents differ)\n'; fi
else
  fail=$((fail+1)); printf 'FAIL new/tree (file lists differ)\n'
  printf '  gold: %s\n  nat:  %s\n' "$goldfiles" "$natfiles"
fi

# ── repl (native vs CANONICAL native golden — documented exception) ───────────
REPL_IN="$ROOT/test/repl_fixtures/session.in"
REPL_GOLDEN="$ROOT/test/repl_fixtures/session.golden"
REPL_WIRED=1
if [ "$REPL_WIRED" = 1 ] && [ -f "$REPL_IN" ] && [ -f "$REPL_GOLDEN" ]; then
  repl_want="$(cat "$REPL_GOLDEN")"
  repl_got="$(printf '%s' "$(cat "$REPL_IN")
" | MEDAKA_ROOT="$ROOT" bound "$MEDAKA" repl 2>/dev/null | strip_unit)"
  if [ "$repl_got" = "$repl_want" ]; then
    pass=$((pass+1)); printf 'ok   repl/session (vs canonical native golden)\n'
  else
    fail=$((fail+1)); printf 'FAIL repl/session\n'
    printf '  want: [%s]\n  got:  [%s]\n' "$repl_want" "$repl_got"
  fi
else
  printf 'skip repl/* (native repl not yet wired or golden missing)\n'
fi

# ── lsp (DOCUMENTED EXCEPTION — native lsp host unbuildable; SKIPPED) ─────────
# ── lsp (CANONICAL native LSP — initialize/didOpen/documentSymbol/hover) ──────
LSP_GOLDEN="$GOLD/lsp/session.ndjson"
if [ -f "$LSP_GOLDEN" ]; then
  lframe() { python3 - "$1" <<'PY'
import sys
b=sys.argv[1].encode("utf-8")
sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n"%len(b)); sys.stdout.buffer.write(b)
PY
  }
  ldecode() { python3 - "$1" <<'PY'
import sys,re,json,os
data=open(sys.argv[1],"rb").read()
def stab(o):
    if isinstance(o,dict): return {k:stab(v) for k,v in o.items()}
    if isinstance(o,list): return [stab(x) for x in o]
    if isinstance(o,str) and o.startswith("file://"): return "file:///"+os.path.basename(o)
    return o
for p in re.split(rb"Content-Length: \d+\r\n", data):
    s=p.decode("utf-8","replace"); i=s.find("{")
    if i<0: continue
    s=s[i:].strip()
    try: obj,_=json.JSONDecoder().raw_decode(s)
    except Exception: continue
    print(json.dumps(stab(obj),sort_keys=True))
PY
  }
  LIN="$TMP/lsp_in.bin"; : > "$LIN"
  LSRC='greet x = x + 1\nmain = println (greet 41)\n'
  for m in \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
    '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///lsp_sess.mdk","languageId":"medaka","version":1,"text":"'"$LSRC"'"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///lsp_sess.mdk"}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///lsp_sess.mdk"},"position":{"line":0,"character":1}}}' \
    '{"jsonrpc":"2.0","method":"exit","params":{}}'; do lframe "$m" >> "$LIN"; done
  MEDAKA_ROOT="$ROOT" bound "$MEDAKA" lsp < "$LIN" > "$TMP/lsp_out.bin" 2>/dev/null
  ldecode "$TMP/lsp_out.bin" > "$TMP/lsp_out.ndjson"
  if cmp -s "$TMP/lsp_out.ndjson" "$LSP_GOLDEN"; then
    pass=$((pass+1)); printf 'ok   lsp/session (vs canonical native golden)\n'
  else
    fail=$((fail+1)); printf 'FAIL lsp/session\n'
    diff "$LSP_GOLDEN" "$TMP/lsp_out.ndjson" | head -8 | sed 's/^/  /'
  fi
else
  printf 'skip lsp/session (golden missing — run sh test/capture_goldens.sh --frozen native_cli)\n'
fi

# ── run ───────────────────────────────────────────────────────────────────────
RUN_FIXTURES="hello arith recur adt listsum strcat"
RUN_WIRED=1
if [ "$RUN_WIRED" = 1 ]; then
  for base in $RUN_FIXTURES; do
    f="$FIX/run/$base.mdk"
    golden="$GOLD/run/$base.golden"
    [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL run/%s (no golden)\n' "$base"; continue; }
    want="$(cat "$golden")"
    got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$f" 2>/dev/null | strip_unit)"
    if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   run/%s\n' "$base"
    else fail=$((fail+1)); printf 'FAIL run/%s\n' "$base"
      printf '  want: [%s]\n  got:  [%s]\n' "$want" "$got"; fi
  done
else
  printf 'skip run/* (native run not yet wired)\n'
fi

# ── run: non-Unit main shape (#1681) ─────────────────────────────────────────
# `run/main_shape_nonunit.mdk` is `main = 3 + 1` — main's inferred type is Int,
# not Unit, so `run` never applies/prints it (unchanged, deliberate no-op) and
# emits the rejection-shaped W-MAIN-SHAPE warning on stderr. Before #1681 the
# process still exited 0 with 0 bytes of stdout — indistinguishable, by exit
# code, from a correct silent program. Fixed: `run` now exits 1 for this shape
# (compiler/driver/medaka_cli.mdk's finishRunEval), aligning the exit code with
# what the message already implies. Pin both halves: exit code AND that stdout
# stays genuinely empty (the underlying no-op behavior is intentional and
# unchanged — see the 0.1.0 audit #3 note in medaka_cli.mdk).
if [ "$RUN_WIRED" = 1 ]; then
  nu_f="$FIX/run/main_shape_nonunit.mdk"
  nu_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$nu_f" 2>/dev/null)"
  nu_status=$?
  if [ "$nu_status" -eq 1 ] && [ -z "$nu_out" ]; then
    pass=$((pass+1)); printf 'ok   run/main_shape_nonunit (exit 1, empty stdout)\n'
  else
    fail=$((fail+1)); printf 'FAIL run/main_shape_nonunit (want exit 1 + empty stdout, got exit %s stdout [%s])\n' "$nu_status" "$nu_out"
  fi
fi

# ── run: sequence bounds guards, interpreter arm (#3267, #3192, #3256) ───────
# The four `Slice` impls (`Bytes`, `Array a`, `String`, `List a`) and
# `array.blit` reject an out-of-range range. Each fixture feeds a range whose
# `hi - lo` (or `off + len`) WRAPS, so a guard written in that additive form
# admits it and reaches an unchecked read.
#
# This arm is the interpreter's; the built binary's reuses `mb_case` below. The
# two engines share the stdlib guard but not the abort path, and only one of
# them was loud before the fix: `slice_bytes_wrap` printed `[|1|]` at exit 0
# under `run` while the built binary segfaulted, so pinning one engine would
# have left the silent half uncovered.
sl_run_case() {
  sl_name="$1"; sl_f="$FIX/run/$sl_name.mdk"; sl_want="$2"
  sl_err="$TMP/nat_${sl_name}_interp.err"
  MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$sl_f" >/dev/null 2>"$sl_err"
  sl_status=$?
  if [ "$sl_status" -eq 1 ] && grep -q "$sl_want" "$sl_err"; then
    pass=$((pass+1)); printf 'ok   run/%s (exit 1, abort on stderr)\n' "$sl_name"
  else
    fail=$((fail+1)); printf 'FAIL run/%s (want exit 1 + stderr containing [%s], got exit %s stderr [%s])\n' \
      "$sl_name" "$sl_want" "$sl_status" "$(cat "$sl_err" 2>/dev/null)"
  fi
}
if [ "$RUN_WIRED" = 1 ]; then
  sl_run_case slice_bytes_wrap    "E-SLICE-OOB"
  sl_run_case slice_bytes_oob     "E-SLICE-OOB"
  sl_run_case slice_array_wrap    "E-SLICE-OOB"
  sl_run_case slice_array_oob     "E-SLICE-OOB"
  sl_run_case slice_string_wrap   "E-SLICE-OOB"
  sl_run_case slice_string_oob    "E-SLICE-OOB"
  sl_run_case slice_list_wrap     "E-SLICE-OOB"
  sl_run_case slice_list_oob      "E-SLICE-OOB"
  sl_run_case array_blit_src_oob  "Array.blit: source out of bounds"
  sl_run_case array_blit_dst_oob  "Array.blit: destination out of bounds"
fi

# ── test ──────────────────────────────────────────────────────────────────────
TEST_FIXTURES="doc prop nodoc"
TEST_WIRED=1
if [ "$TEST_WIRED" = 1 ]; then
  for base in $TEST_FIXTURES; do
    f="$FIX/test/$base.mdk"
    golden="$GOLD/test/$base.golden"
    [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL test/%s (no golden)\n' "$base"; continue; }
    want="$(cat "$golden")"
    got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" test "$f" 2>/dev/null | sed "s#$ROOT/##g" | strip_unit)"
    if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   test/%s\n' "$base"
    else fail=$((fail+1)); printf 'FAIL test/%s\n' "$base"
      printf '  want: [%s]\n  got:  [%s]\n' "$want" "$got"; fi
  done

  # #82 row 2 (dir/project support, this branch): `medaka test <dir>` walks
  # EVERY .mdk file under it (same expandLintTarget/collectMdkFiles walk
  # lint/fmt use) and aggregates. DOCUMENTED EXCEPTION (like repl/lsp above):
  # this capability post-dates the OCaml oracle's removal, so its golden is
  # captured from the current CANONICAL native binary, not an OCaml reference.
  # test_dir/ has fail.mdk (failing doctest) + ok.mdk (passing doctest, but
  # the DIRECTORY run must still exit nonzero because its sibling failed) —
  # this is also the #212 regression check for the directory route: a bad
  # target used to print an error and still exit 0.
  dir_golden="$GOLD/test/dir.golden"
  if [ -f "$dir_golden" ]; then
    dir_want="$(cat "$dir_golden")"
    dir_got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" test "$FIX/test_dir" 2>/dev/null | sed "s#$ROOT/##g" | strip_unit)"
    if [ "$dir_got" = "$dir_want" ]; then pass=$((pass+1)); printf 'ok   test/dir (multi-file directory report)\n'
    else fail=$((fail+1)); printf 'FAIL test/dir\n'
      printf '  want: [%s]\n  got:  [%s]\n' "$dir_want" "$dir_got"; fi
  else
    fail=$((fail+1)); printf 'FAIL test/dir (no golden)\n'
  fi
  MEDAKA_ROOT="$ROOT" bound "$MEDAKA" test "$FIX/test_dir" >/dev/null 2>&1
  dir_code=$?
  if [ "$dir_code" -ne 0 ]; then
    pass=$((pass+1)); printf 'ok   test/dir exit code (%d != 0, fail.mdk has a FAILing doctest)\n' "$dir_code"
  else
    fail=$((fail+1)); printf 'FAIL test/dir exit code: expected nonzero, got 0\n'
  fi

  # Empty dir: "no .mdk files" is reported on STDERR at exit 1.  C3
  # (docs/ops/CLI-CONFORMANCE.md §3) ratified "found nothing is a usage error",
  # one (stderr, 1) pair for every verb, and named `test`'s old vacuous exit-0
  # pass as the load-bearing case: a test command that ran zero tests and exited
  # 0 is the "didn't run looks like passed" failure the test arc exists to
  # close.  This assertion used to pin exit 0; it now pins the convention.
  # runTest's single-file zero-doctest pass is a DIFFERENT case and unchanged.
  # Uses a throwaway tmp dir (not a committed fixture — nothing to walk means
  # nothing to bless).
  empty_dir="$(mktemp -d)"
  empty_got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" test "$empty_dir" 2>&1)"
  empty_code=0
  MEDAKA_ROOT="$ROOT" bound "$MEDAKA" test "$empty_dir" >/dev/null 2>&1 || empty_code=$?
  rmdir "$empty_dir"
  case "$empty_got" in
    *"no .mdk files found"*)
      if [ "$empty_code" -eq 1 ]; then
        pass=$((pass+1)); printf 'ok   test/empty-dir (message + exit 1)\n'
      else
        fail=$((fail+1)); printf 'FAIL test/empty-dir: expected exit 1, got %d\n' "$empty_code"
      fi
      ;;
    *)
      fail=$((fail+1)); printf 'FAIL test/empty-dir: expected "no .mdk files found", got [%s]\n' "$empty_got"
      ;;
  esac

  # ── test with no target (#3443) ──────────────────────────────────────────
  # Bare `medaka test` tests the project enclosing the cwd: the NEAREST
  # medaka.toml at or above it, walked exactly as `medaka test <root>` walks a
  # directory, with the chosen root named on stderr. Outside any project it
  # refuses (exit 1) and never tests the cwd; `--json` refuses too. This path
  # used to print usage and exit 1 unconditionally, so every assertion below
  # checks what ran as well as the exit code ([W-QUIETER]).
  #
  # Scratch projects under $TMP, not committed fixtures: the cases need a
  # medaka.toml at a known depth, and the outside-project case needs a
  # directory with NO manifest above it, which no path inside the repo is.
  # Only the first case runs the default (native) engine; the rest pass
  # `--engines eval` to keep the clang builds to two.
  nt="$TMP/notarget"
  mkdir -p "$nt/proj/sub/deep" "$nt/failing" "$nt/ws/a" "$nt/noproj"
  printf '[package]\nname = "proj"\nversion = "0.1.0"\n' > "$nt/proj/medaka.toml"
  printf '%s\n' '-- > top 1' '-- 2' 'top x = x + 1' > "$nt/proj/top.mdk"
  printf '%s\n' '-- > inner 1' '-- 10' 'inner x = x * 10' > "$nt/proj/sub/deep/inner.mdk"
  printf '[package]\nname = "failing"\nversion = "0.1.0"\n' > "$nt/failing/medaka.toml"
  printf '%s\n' '-- > good 1' '-- 1' 'good x = x' > "$nt/failing/good.mdk"
  printf '%s\n' '-- > bad 1' '-- 99' 'bad x = x' > "$nt/failing/bad.mdk"
  printf '[workspace]\nmembers = ["a"]\n' > "$nt/ws/medaka.toml"
  printf '%s\n' '-- > wsTool 1' '-- 1' 'wsTool x = x' > "$nt/ws/tool.mdk"
  printf '[package]\nname = "a"\nversion = "0.1.0"\n' > "$nt/ws/a/medaka.toml"
  printf '%s\n' '-- > member 1' '-- 1' 'member x = x' > "$nt/ws/a/member.mdk"
  printf '%s\n' '-- > stray 1' '-- 1' 'stray x = x' > "$nt/noproj/stray.mdk"
  proj_root="$(cd "$nt/proj" && pwd -P)"
  ws_root="$(cd "$nt/ws" && pwd -P)"
  member_root="$(cd "$nt/ws/a" && pwd -P)"

  # Runs `medaka test <args>` with cwd $1; sets nt_out / nt_err / nt_rc.
  nt_run() {
    _nt_dir=$1; shift
    nt_rc=0
    (cd "$_nt_dir" && MEDAKA_ROOT="$ROOT" bound "$MEDAKA" test "$@") \
      >"$TMP/nt.out" 2>"$TMP/nt.err" || nt_rc=$?
    nt_out="$(cat "$TMP/nt.out")"; nt_err="$(cat "$TMP/nt.err")"
  }
  nt_ok() { pass=$((pass+1)); printf 'ok   test/no-target/%s\n' "$1"; }
  nt_bad() {
    fail=$((fail+1)); printf 'FAIL test/no-target/%s: %s\n' "$1" "$2"
    printf '  rc=%s\n  stdout: [%s]\n  stderr: [%s]\n' "$nt_rc" "$nt_out" "$nt_err"
  }
  nt_has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

  # 1. From the project root, default engine: both files run, root named.
  nt_run "$nt/proj"
  if [ "$nt_rc" -ne 0 ]; then nt_bad root "want exit 0"
  elif ! nt_has "$nt_out" "top.mdk: 1/1 passed" || ! nt_has "$nt_out" "inner.mdk: 1/1 passed"; then
    nt_bad root "want top.mdk and sub/deep/inner.mdk each 1/1 passed"
  elif ! nt_has "$nt_err" "testing the project at $proj_root"; then
    nt_bad root "want stderr to name the root $proj_root"
  else nt_ok root; fi

  # 2. From a nested subdirectory: widens to the whole project, and says so.
  nt_run "$nt/proj/sub/deep" --engines eval
  if [ "$nt_rc" -ne 0 ]; then nt_bad walk-up "want exit 0"
  elif ! nt_has "$nt_out" "top.mdk: 1/1 passed" || ! nt_has "$nt_out" "inner.mdk: 1/1 passed"; then
    nt_bad walk-up "want the whole project (top.mdk too), not just the subdirectory"
  elif ! nt_has "$nt_err" "testing the project at $proj_root"; then
    nt_bad walk-up "want stderr to name the root $proj_root"
  else nt_ok walk-up; fi

  # 3. Flags behave as with an explicit target: --filter narrows the walk, and
  #    stdout AND exit code match `medaka test <root>` with the same flags. The
  #    exit code is compared, not fixed: a directory run currently fails a file
  #    whose tests all miss the filter (top.mdk here), and that is the explicit
  #    target's behavior to keep or change, not this path's.
  nt_run "$nt/proj/sub" --engines eval --filter inner --seed 7 --cases 5
  nt_flag_out=$nt_out; nt_flag_rc=$nt_rc
  nt_run "$nt/noproj" --engines eval --filter inner --seed 7 --cases 5 "$proj_root"
  if ! nt_has "$nt_flag_out" "inner.mdk:1: inner 1" || nt_has "$nt_flag_out" "top 1"; then
    nt_out=$nt_flag_out; nt_rc=$nt_flag_rc
    nt_bad flags "want --filter inner to keep inner's doctest and drop top's"
  elif [ "$nt_flag_out" != "$nt_out" ] || [ "$nt_flag_rc" -ne "$nt_rc" ]; then
    printf '  no-target: rc=%s stdout: [%s]\n' "$nt_flag_rc" "$nt_flag_out"
    nt_bad flags "want stdout and exit code identical to 'medaka test <root>' with the same flags"
  else nt_ok flags; fi

  # 4. A project with a failing doctest exits nonzero, having run both files.
  nt_run "$nt/failing" --engines eval
  if [ "$nt_rc" -eq 0 ]; then nt_bad failing "want nonzero exit (bad.mdk fails)"
  elif ! nt_has "$nt_out" "bad.mdk: 0/1 passed" || ! nt_has "$nt_out" "good.mdk: 1/1 passed"; then
    nt_bad failing "want bad.mdk 0/1 and good.mdk 1/1"
  else nt_ok failing; fi

  # 5. Workspace: the nearest manifest wins. At the workspace root the walk
  #    reaches the member beneath it; inside the member, only the member runs.
  nt_run "$nt/ws" --engines eval
  if [ "$nt_rc" -ne 0 ]; then nt_bad workspace-root "want exit 0"
  elif ! nt_has "$nt_out" "tool.mdk: 1/1 passed" || ! nt_has "$nt_out" "member.mdk: 1/1 passed"; then
    nt_bad workspace-root "want the root's tool.mdk and member a's member.mdk"
  elif ! nt_has "$nt_err" "testing the project at $ws_root"; then
    nt_bad workspace-root "want stderr to name $ws_root"
  else nt_ok workspace-root; fi
  nt_run "$nt/ws/a" --engines eval
  if [ "$nt_rc" -ne 0 ]; then nt_bad workspace-member "want exit 0"
  elif ! nt_has "$nt_out" "member.mdk: 1/1 passed" || nt_has "$nt_out" "tool.mdk"; then
    nt_bad workspace-member "want member.mdk only, not the workspace root's tool.mdk"
  elif ! nt_has "$nt_err" "testing the project at $member_root"; then
    nt_bad workspace-member "want stderr to name $member_root"
  else nt_ok workspace-member; fi

  # 6. No medaka.toml anywhere above: exit 1, names both fixes, tests nothing
  #    (noproj/stray.mdk has a doctest that must not run). The precondition is
  #    checked, not assumed: a manifest above $TMP would make this a project.
  nt_up=$(cd "$nt/noproj" && pwd -P); nt_manifest=""
  while :; do
    [ -f "$nt_up/medaka.toml" ] && { nt_manifest="$nt_up/medaka.toml"; break; }
    [ "$nt_up" = / ] && break
    nt_up=$(dirname "$nt_up")
  done
  nt_run "$nt/noproj"
  if [ -n "$nt_manifest" ]; then nt_bad no-project "precondition: $nt_manifest sits above the scratch dir"
  elif [ "$nt_rc" -ne 1 ]; then nt_bad no-project "want exit 1"
  elif [ -n "$nt_out" ]; then nt_bad no-project "want empty stdout (nothing may run)"
  elif ! nt_has "$nt_err" "no medaka.toml" || ! nt_has "$nt_err" "pass a file.mdk or directory target" \
       || ! nt_has "$nt_err" "run inside a project"; then
    nt_bad no-project "want stderr naming the missing manifest and both fixes"
  else nt_ok no-project; fi

  # 7. --json with no target refuses inside a project too, and says why.
  nt_run "$nt/proj" --json
  if [ "$nt_rc" -ne 1 ]; then nt_bad json "want exit 1"
  elif [ -n "$nt_out" ]; then nt_bad json "want empty stdout (no envelope, nothing run)"
  elif ! nt_has "$nt_err" "medaka test --json: needs a single file.mdk target" \
       || ! nt_has "$nt_err" "whole enclosing project"; then
    nt_bad json "want stderr saying --json needs one file and a no-target run is the whole project"
  else nt_ok json; fi
else
  printf 'skip test/* (native test not yet wired)\n'
fi

# ── build (native binary stdout vs OCaml-built-binary golden; native emit host) ─
build_skip=0
command -v "${CC:-clang}" >/dev/null 2>&1 || build_skip=1
if [ "$build_skip" = 0 ]; then
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
  elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
  elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "${CC:-clang}" -x c - -lgc -o /dev/null 2>/dev/null; then :
  else build_skip=1; fi
fi
if [ "$build_skip" = 1 ]; then
  printf 'skip build/* (no clang or libgc)\n'
elif [ ! -x "$EMITTER" ]; then
  printf 'skip build/* (native emitter missing — make medaka)\n'
else
  printf 'note build emit host: native-emitter (OCaml-free) %s\n' "$EMITTER"
  for base in $RUN_FIXTURES; do
    f="$FIX/run/$base.mdk"
    golden="$GOLD/build/$base.golden"
    [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL build/%s (no golden)\n' "$base"; continue; }
    want="$(cat "$golden")"
    ( export MEDAKA_ROOT="$ROOT"; export MEDAKA_EMITTER="$EMITTER"; bound "$MEDAKA" build "$f" -o "$TMP/nat_$base" ) >/dev/null 2>&1
    got="$("$TMP/nat_$base" 2>/dev/null)"
    if [ -x "$TMP/nat_$base" ] && [ "$got" = "$want" ]; then
      pass=$((pass+1)); printf 'ok   build/%s\n' "$base"
    else fail=$((fail+1)); printf 'FAIL build/%s\n' "$base"
      printf '  want: [%s]\n  got:  [%s]\n' "$want" "$got"; fi
  done

  # ── build: non-Unit main shape (#2246) ────────────────────────────────────
  # The `build`-routed sibling of the run/main_shape_nonunit case above, on the
  # SAME fixture (`main = 3 + 1`).  `medaka build` reaches the warning through
  # typecheckGateRoute's single-module arm (compiler/driver/medaka_cli.mdk),
  # whose `mainShapeWarnings` call #2246 changed: the first three arguments are
  # ignored by that function unconditionally, so the two `desugar (parse …)`
  # prelude re-parses that used to compute them were deleted and `[] [] []` is
  # passed instead.  That edit is only inert if this warning still fires — and
  # nothing else in this gate covered the build route's main-shape surface, so
  # a regression to "silently no warning" (the [W-QUIETER] direction) would have
  # been invisible.  Pin all three halves: exit 0, the warning on STDERR, and a
  # binary actually produced (the warning must not become an error).
  nub_f="$FIX/run/main_shape_nonunit.mdk"
  nub_err="$TMP/nat_main_shape_nonunit_build.err"
  ( export MEDAKA_ROOT="$ROOT"; export MEDAKA_EMITTER="$EMITTER"; bound "$MEDAKA" build "$nub_f" -o "$TMP/nat_build_nonunit" ) >/dev/null 2>"$nub_err"
  nub_status=$?
  if [ "$nub_status" -eq 0 ] && [ -x "$TMP/nat_build_nonunit" ] &&
     grep -q "must be a value of type Unit" "$nub_err"; then
    pass=$((pass+1)); printf 'ok   build/main_shape_nonunit (exit 0, W-MAIN-SHAPE on stderr)\n'
  else
    fail=$((fail+1)); printf 'FAIL build/main_shape_nonunit (want exit 0 + binary + W-MAIN-SHAPE on stderr, got exit %s stderr [%s])\n' "$nub_status" "$(cat "$nub_err" 2>/dev/null)"
  fi

  # ── build: MutBytes/Builder panic messages (stdlib/mut_bytes.mdk,
  # stdlib/bytebuilder.mdk) ──────────────────────────────────────────────────
  # Ten `panic` arms across the two types that no other vehicle reaches:
  # MutBytes.setInPlace's value-range and bounds checks, MutBytes.make's
  # negative-length check, MutBytes.fill's value-range check, MutBytes.blit's
  # three negative-argument checks and two bounds checks, and Builder.emitU8's
  # value-range check. Pin the runtime abort text and exit code for each so a
  # change to any of the ten messages, or a regression that drops the guard
  # entirely, is caught. The two blit bounds fixtures pass an offset of Int's
  # maximum: a guard written as `off + len > length` wraps negative, passes,
  # and reaches an unchecked memmove, so the failure is a segfault rather than
  # a panic.
  mb_case() {
    mb_name="$1"; mb_f="$FIX/run/$mb_name.mdk"; mb_want="$2"
    mb_bin="$TMP/nat_build_$mb_name"; mb_err="$TMP/nat_${mb_name}_run.err"
    ( export MEDAKA_ROOT="$ROOT"; export MEDAKA_EMITTER="$EMITTER"; bound "$MEDAKA" build "$mb_f" -o "$mb_bin" ) >/dev/null 2>&1
    if [ ! -x "$mb_bin" ]; then
      fail=$((fail+1)); printf 'FAIL build/%s (build failed)\n' "$mb_name"; return
    fi
    bound "$mb_bin" >/dev/null 2>"$mb_err"
    mb_status=$?
    if [ "$mb_status" -eq 1 ] && grep -q "$mb_want" "$mb_err"; then
      pass=$((pass+1)); printf 'ok   build/%s (exit 1, panic on stderr)\n' "$mb_name"
    else
      fail=$((fail+1)); printf 'FAIL build/%s (want exit 1 + stderr containing [%s], got exit %s stderr [%s])\n' \
        "$mb_name" "$mb_want" "$mb_status" "$(cat "$mb_err" 2>/dev/null)"
    fi
  }
  mb_case mutbytes_set_range "MutBytes.setInPlace: value out of range 0..255"
  mb_case mutbytes_set_oob   "MutBytes.setInPlace: index out of bounds"
  mb_case mutbytes_make_neg  "MutBytes.make: negative length"
  mb_case mutbytes_fill_range "MutBytes.fill: value out of range 0..255"
  mb_case mutbytes_blit_neg_len "MutBytes.blit: negative length"
  mb_case mutbytes_blit_neg_srcoff "MutBytes.blit: negative srcOff"
  mb_case mutbytes_blit_neg_dstoff "MutBytes.blit: negative dstOff"
  mb_case mutbytes_blit_src_oob "MutBytes.blit: source out of bounds"
  mb_case mutbytes_blit_dst_oob "MutBytes.blit: destination out of bounds"
  mb_case emitu8_range       "Builder.emitU8: value out of range 0..255"
  mb_case emitu8_negative    "Builder.emitU8: value out of range 0..255"

  # ── build: sequence bounds guards (#3267, #3192, #3256) ─────────────────
  # The built-binary arm of the `sl_run_case` rows above, on the same ten
  # fixtures: `mb_case`'s contract (build it, expect exit 1 and this text on
  # stderr) is what these need too, so they share it rather than a copy.
  # Native codegen is where the missing guard was loudest — `slice_bytes_wrap`
  # segfaulted here while the interpreter printed a wrong byte at exit 0.
  mb_case slice_bytes_wrap    "E-SLICE-OOB"
  mb_case slice_bytes_oob     "E-SLICE-OOB"
  mb_case slice_array_wrap    "E-SLICE-OOB"
  mb_case slice_array_oob     "E-SLICE-OOB"
  mb_case slice_string_wrap   "E-SLICE-OOB"
  mb_case slice_string_oob    "E-SLICE-OOB"
  mb_case slice_list_wrap     "E-SLICE-OOB"
  mb_case slice_list_oob      "E-SLICE-OOB"
  mb_case array_blit_src_oob  "Array.blit: source out of bounds"
  mb_case array_blit_dst_oob  "Array.blit: destination out of bounds"
fi

# error/* — RETIRED with the OCaml oracle (native canonical; oracle-coupled leg
# deleted per LIB-REMOVAL-DESIGN §6 Stage C).

# ── dirguard (#165) — readFile/readFileBytes on a real directory must fail
# clean, not GC-OOM.  Before the fix, fopen(2) opens a directory fine, so
# fseek(SEEK_END)+ftell reported an absurd size (LONG_MAX on ext4), which
# overflowed mdk_alloc and sent the GC after ~2^63 bytes (spews "GC Warning:
# Failed to expand heap ..." / "Out of Memory!"); on filesystems where ftell
# behaves, fread on the dir FD silently returned 0, giving a quiet "" instead
# of an error.  `runtime/medaka_rt.c`'s mdk_read_file / mdk_read_file_bytes
# now stat() the path and reject S_ISDIR up front — filesystem-independent,
# so this is CI-safe.  DIR is test/native_cli_fixtures/run (this gate's own
# fixture dir, not a scratch path), so no shared-corpus footgun.
DIR="$FIX/run"
dir_got="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$DIR" 2>&1)"; dir_ec=$?
case "$dir_got" in
  *"GC Warning"*|*"Out of Memory"*)
    fail=$((fail+1)); printf 'FAIL dirguard/check (GC-OOM spew on a directory)\n'
    printf '  got:  [%s]\n' "$dir_got" ;;
  *"Is a directory"*)
    if [ "$dir_ec" -ne 0 ]; then
      pass=$((pass+1)); printf 'ok   dirguard/check\n'
    else
      fail=$((fail+1)); printf 'FAIL dirguard/check (clean message but exit 0)\n'
    fi ;;
  *)
    fail=$((fail+1)); printf 'FAIL dirguard/check (unexpected output)\n'
    printf '  got:  [%s]\n' "$dir_got" ;;
esac

# ── version provenance (issue #74 W8) ─────────────────────────────────────
# `--version`/`version` must print version + commit + build date, all from
# ONE definition (compiler/driver/medaka_cli.mdk's `medakaVersionString`).
# Pin the SHAPE only — "medaka <ver> (<parenthesized commit+date group>)" —
# never the literal commit/date, which would break on every future commit.
# Both invocation forms must produce the SAME line.
ver1="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" --version 2>/dev/null)"
ver2="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" version 2>/dev/null)"
case "$ver1" in
  "medaka "*" ("*")")
    if [ "$ver1" = "$ver2" ]; then
      pass=$((pass+1)); printf 'ok   version/shape (--version == version, [%s])\n' "$ver1"
    else
      fail=$((fail+1)); printf 'FAIL version/shape (--version [%s] != version [%s])\n' "$ver1" "$ver2"
    fi ;;
  *)
    fail=$((fail+1)); printf 'FAIL version/shape (want "medaka <ver> (...)", got [%s])\n' "$ver1" ;;
esac

# ── toolchain-missing messages (#2514 review F-4) ─────────────────────────
# `medaka build` must name a missing clang/libgc and give the platform's
# install command, never the raw "clang failed compiling ... / No such file
# or directory" pair a bare exec failure prints (compiler/driver/build_cmd.mdk
# probeClang/clangMissingError, libgcMissingError). Nothing previously
# regression-gated this behavior — a revert was only caught by the source-
# shape snapshot (test/snapshots/compiler/build_cmd.md), not a behavioral
# assertion. `CC=<bogus>` and `GC_PREFIX=<bogus>` trigger the two failure
# modes deterministically without touching PATH (which this script's own
# tooling needs intact).
tc_got="$(CC=/nonexistent-cc-binary-2514 MEDAKA_ROOT="$ROOT" bound "$MEDAKA" build "$FIX/run/hello.mdk" -o /tmp/tc-clang-out 2>&1)"
case "$tc_got" in
  *"install clang"*)
    pass=$((pass+1)); printf 'ok   toolchain/clang-missing\n' ;;
  *)
    fail=$((fail+1)); printf 'FAIL toolchain/clang-missing (want an "install clang" message)\n'
    printf '  got:  [%s]\n' "$tc_got" ;;
esac

tc_got2="$(GC_PREFIX=/nonexistent-gc-prefix-2514 MEDAKA_ROOT="$ROOT" bound "$MEDAKA" build "$FIX/run/hello.mdk" -o /tmp/tc-gc-out 2>&1)"
case "$tc_got2" in
  *"install bdw-gc"*|*"libgc-dev"*)
    pass=$((pass+1)); printf 'ok   toolchain/libgc-missing\n' ;;
  *)
    fail=$((fail+1)); printf 'FAIL toolchain/libgc-missing (want an "install bdw-gc"/"libgc-dev" message)\n'
    printf '  got:  [%s]\n' "$tc_got2" ;;
esac

# ── build --json surfaces build-stage notes (#2243) ───────────────────────
# `medaka build --json` used to print the front-end gate's envelope verbatim on
# a successful build, so anything the BUILD stage itself had to say — a
# `--keep-ir` copy that failed — reached the plain CLI and vanished from the
# machine channel.  A directory at `<out>.ll` makes that copy fail
# deterministically without making the build fail (the note is best-effort by
# design, see keepIrOutcome in compiler/driver/build_cmd.mdk).  Both arms must
# exit 0: the plain one printing its long-standing wording unchanged, the JSON
# one carrying the same warning as a W-KEEP-IR-FAILED diagnostic inside the one
# {"files":[...]} envelope rather than on a second channel.
ki_dir="$TMP/ki_plain.bin.ll"
rm -rf "$ki_dir"; mkdir -p "$ki_dir"
ki_plain="$(MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" bound "$MEDAKA" build \
  "$FIX/run/hello.mdk" -o "$TMP/ki_plain.bin" --keep-ir 2>&1)"
ki_plain_rc=$?
case "$ki_plain$ki_plain_rc" in
  *"warning: could not keep IR at $ki_dir: "*0)
    pass=$((pass+1)); printf 'ok   build/keep-ir-plain-warning\n' ;;
  *)
    fail=$((fail+1))
    printf 'FAIL build/keep-ir-plain-warning (want "warning: could not keep IR at %s: ..." and exit 0)\n' "$ki_dir"
    printf '  got:  [%s] rc=%s\n' "$ki_plain" "$ki_plain_rc" ;;
esac

ki_jdir="$TMP/ki_json.bin.ll"
rm -rf "$ki_jdir"; mkdir -p "$ki_jdir"
ki_json="$(MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" bound "$MEDAKA" build --json \
  "$FIX/run/hello.mdk" -o "$TMP/ki_json.bin" --keep-ir 2>/dev/null)"
ki_json_rc=$?
case "$ki_json$ki_json_rc" in
  *'"code":"W-KEEP-IR-FAILED"'*"could not keep IR at $ki_jdir"*0)
    pass=$((pass+1)); printf 'ok   build/keep-ir-json-warning\n' ;;
  *)
    fail=$((fail+1))
    printf 'FAIL build/keep-ir-json-warning (want a W-KEEP-IR-FAILED diagnostic naming %s, exit 0)\n' "$ki_jdir"
    printf '  got:  [%s] rc=%s\n' "$ki_json" "$ki_json_rc" ;;
esac

# ── test --json carries the engine and a real location ────────────────────
# `medaka test --json` had no gate anywhere: the plain-text `test/` goldens
# above pin the human report and nothing pinned the machine one, so the two
# fields an agent reads a `tests` entry BY could both regress silently.
# Asserted on CONTENT rather than against a golden, because the report embeds
# the target path and a golden would pin the harness's cwd along with it.
#
# `"engine"` is asserted at the TOP LEVEL specifically — each `tests` entry
# carries its own `"engine"` too, so a top-level regression is invisible to a
# bare substring search. `"file"` is the first field of the envelope
# (cliTestReportJson, compiler/tools/test_cmd.mdk), so `","engine":"native",`
# can only match after it closes; a nested one is preceded by a bare comma.
# `native` because no engine flag is passed and native is the default.
#
# The fixture's single `test` decl has a bare-operator body, the shape with no
# span of its own to read a location off — `"line":0` is what reading one off
# it yields, and is what this rejects.
tj_f="$FIX/test/test_decl_json.mdk"
tj_json="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" test --json "$tj_f" 2>/dev/null)"
tj_rc=$?
tj_ok=1
case "$tj_json" in '{"file":"'*'","engine":"native",'*) ;; *) tj_ok=0 ;; esac
case "$tj_json" in *'"name":"a bare binop body still reports its own line","line":'*'"status":"pass"'*) ;; *) tj_ok=0 ;; esac
case "$tj_json" in *'"line":0,'*) tj_ok=0 ;; esac
if [ "$tj_ok" -eq 1 ] && [ "$tj_rc" -eq 0 ]; then
  pass=$((pass+1)); printf 'ok   test/json-engine-and-line\n'
else
  fail=$((fail+1))
  printf 'FAIL test/json-engine-and-line (want a top-level "engine":"native", the test entry passing at a NONZERO line, exit 0)\n'
  printf '  got:  [%s] rc=%s\n' "$tj_json" "$tj_rc"
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
