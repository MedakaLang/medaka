#!/bin/sh
# IR-GOLDEN gate over an INSTALLING emitter entry (issue #587).
#
# ── WHY THIS GATE EXISTS ──────────────────────────────────────────────────────
# diff_compiler_llvm.sh is our headline IR-golden gate ("220 ok, byte-identical
# IR"), but its entry — compiler/entries/llvm_emit_main.mdk — constructs an empty
# explicit EmitInput. So under that entry every declaration-derived input path runs
# in its degenerate state, and ANY change to those inputs is a NO-OP that the
# 220-fixture gate cannot see. Meanwhile diff_compiler_llvm_typed.sh and
# diff_compiler_llvm_modules.sh construct populated EmitInput values but compare program
# and diff_compiler_llvm_modules.sh — compare program OUTPUT, not IR, so an IR
# PESSIMIZATION that still computes the right answer is invisible to them BY
# CONSTRUCTION (e.g. a specialized `@mdk_list_append` call degrading to a generic
# `@mdk_append` — same result, worse code). #587 proved this: applying #357's
# reset-the-seven-at-emitProgram change moved emitted IR and STILL passed
# "220 ok / 48 ok / 16 ok" across all three existing gates.
#
# This gate closes that hole: it drives the SAME explicit-input entry the typed OUTPUT
# gate uses (test/bin/llvm_emit_typed_main, from compiler/entries/llvm_emit_typed_main.mdk),
# but compares the EMITTED LLVM IR byte-for-byte
# against committed goldens. A change that moves the IR — including an inert
# pessimization — flips a golden RED here even when the program's output is
# unchanged.
#
# ── CORPUS: the WHOLE typed corpus, on purpose ────────────────────────────────
# Every fixture under test/llvm_fixtures_typed/ gets an IR golden. This is the
# same corpus diff_compiler_llvm_typed.sh drives; adding an .ll.golden sibling
# enrolls no new fixture and changes no other gate's fixture set. The emitted IR is
# fully deterministic (sequential %tN temporaries, deterministic mangled symbol
# names, no target triple — the seed cold-bootstraps x86/arm from one byte stream),
# so a whole-corpus pin has no flake surface and needs no curation. It IS noisier
# than diff_compiler_llvm.sh in the sense the issue warns about — a typed entry's IR
# moves for more reasons — but that noise is exactly the signal: an emitter change
# that moves IR must be BLESSED here in the same commit, the same discipline as the
# snapshot corpora. We deliberately do NOT curate a subset: a curated subset that
# silently drops fixtures re-creates #587's own bug one level up (a gate whose
# window is narrower than its reputation). If a future maintainer must curate, this
# gate MUST print exactly which fixtures it dropped.
#
# ── GOLDEN CAPTURE ────────────────────────────────────────────────────────────
# CAPTURE=1 sh test/diff_compiler_llvm_typed_ir.sh   (re)writes every <name>.ll.golden
# from test/bin/llvm_emit_typed_main. A capture that would write ZERO goldens is a
# FAILURE, not a silent pass (a stale golden's classic ship path). The golden is the
# emitter's exact stdout — no post-processing — so the gate compares precisely what
# the backend emitted.
#
# ── FOUR QUESTIONS (issue #587 / ORCHESTRATING.md) ────────────────────────────
#  1. Where is it skipped? It runs in the `backend` CI shard (globbed by
#     'diff_compiler_llvm*' in .github/workflows/ci.yml) — i.e. it runs on exactly
#     the PRs that touch the emitter/input seam, which is never a docs-only PR.
#  2. Is the caught bug-class the skip's trigger-class? Yes: it fails iff emitted IR
#     moves, and an emitter/input change is precisely what moves emitted IR.
#  3. Seen it fail? Yes — applying #357's reset-the-seven at emitProgram degraded
#     @mdk_list_append -> @mdk_append and this gate named the fixture; reverted.
#  4. Can it no-op? No: N==0 (no fixtures, or no goldens) is a hard FAILURE below.
#
# Usage:  sh test/diff_compiler_llvm_typed_ir.sh
#         CAPTURE=1 sh test/diff_compiler_llvm_typed_ir.sh   # (re)capture goldens
# Exit:   0 every fixture's emitted IR matches its golden; 1 a mismatch / missing
#         golden / zero fixtures; 2 the emit binary is not built.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITBIN="$ROOT/test/bin/llvm_emit_typed_main"
EMITTER="$ROOT/compiler/backend/llvm_emit.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/llvm_fixtures_typed"
RT="$ROOT/runtime/medaka_rt.c"
CC="${CC:-clang}"

# ── Per-fixture worker (parallel fan-out target); shared state via env ─────────
if [ "${1:-}" = "--one" ]; then
  f="$2"
  name="$(basename "$f")"
  golden="${f%.mdk}.ll.golden"
  raw="$WORKDIR/$name.ll"
  st=0; msg=""
  # Check $EMITBIN's OWN exit status directly (dash has no pipefail; see #443/#632).
  "$EMITBIN" "$RUNTIME" "$f" > "$raw" 2>"$WORKDIR/$name.emit.err"
  emit_rc=$?
  if [ "$emit_rc" -ne 0 ]; then
    msg="$(printf 'FAIL %s (emit)\n%s' "$name" "$(cat "$WORKDIR/$name.emit.err")")"; st=1
  elif [ "${CAPTURE:-0}" = "1" ]; then
    cp "$raw" "$golden"
    msg="captured $name"
  elif [ ! -f "$golden" ]; then
    msg="no golden for $name (run CAPTURE=1 sh test/diff_compiler_llvm_typed_ir.sh)"; st=1
  elif diff -u "$golden" "$raw" > "$WORKDIR/$name.diff" 2>&1; then
    msg="ok   $name"
  else
    msg="$(printf 'FAIL %s (emitted IR differs from golden)\n%s' "$name" "$(cat "$WORKDIR/$name.diff")")"; st=1
  fi
  printf '%s\n' "$msg" > "$RESULTDIR/$name.out"
  echo "$st" > "$RESULTDIR/$name.status"
  printf '%s\n' "$msg"
  exit 0
fi

# X-N.H2 structural ratchet: every mutable physical cell belongs to `Emit`, whose
# fields are indented. A top-level Ref declaration reintroduces process-global
# emission state and must fail before an output golden can normalize it away.
if LC_ALL=C grep -En '^(export[[:space:]]+)?[[:alnum:]_]+[[:space:]]*:[[:space:]]*Ref([[:space:](]|$)' "$EMITTER" \
  || LC_ALL=C grep -En '^[[:alnum:]_]+[[:space:]]*=[[:space:]]*Ref([[:space:](]|$)' "$EMITTER"; then
  echo 'FAIL: compiler/backend/llvm_emit.mdk declares module-level Ref state; move it into Emit'
  exit 1
fi
printf 'checked LLVM physical-state ownership (no module-level Ref declarations)\n'

[ -x "$EMITBIN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$EMITBIN") (missing $EMITBIN)"; exit 2; }

WORK="$(mktemp -d)"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$WORK" "$RESULTS"' EXIT

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"

fixtures="$(ls "$FIXDIR"/*.mdk 2>/dev/null)"
n_fixtures=0
if [ -n "$fixtures" ]; then
  n_fixtures="$(printf '%s\n' "$fixtures" | wc -l | tr -d ' ')"
  printf '%s\n' "$fixtures" \
    | EMITBIN="$EMITBIN" RUNTIME="$RUNTIME" WORKDIR="$WORK" RESULTDIR="$RESULTS" CAPTURE="${CAPTURE:-0}" \
      xargs -P "$JOBS" -I{} sh "$0" --one {}
fi

# N == 0 MUST be a FAILURE, not a pass (issue #587 Q4): a gate that checked nothing
# must never report green — the whole disease this suite is being hardened against.
if [ "$n_fixtures" -eq 0 ]; then
  echo "FAIL: no fixtures found under $FIXDIR — this gate checked NOTHING, which is a failure, not a pass."
  exit 1
fi

pass=0; fail=0; seen=0
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  seen=$((seen+1))
  if [ "$(cat "$s")" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done

# Completeness check (issue #637): a worker killed mid-run under xargs -P writes no
# .status file, so it would otherwise vanish from BOTH pass and fail.
if [ "$seen" -ne "$n_fixtures" ]; then
  missing=$((n_fixtures - seen))
  echo "FAIL: $missing of $n_fixtures workers produced no result — a worker died/was killed; this run is INCOMPLETE, not green."
  exit 1
fi

if [ "${CAPTURE:-0}" = "1" ]; then
  # A capture that wrote zero goldens is a stale-golden ship path — refuse it.
  if [ "$pass" -eq 0 ]; then
    echo "FAIL: CAPTURE wrote 0 goldens ($fail failed to emit) — refusing a zero-write capture."
    exit 1
  fi
  printf '\ncaptured %d IR goldens, %d failed to emit\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
else
  printf '\nchecked %d, %d ok, %d failing\n' "$n_fixtures" "$pass" "$fail"
  [ "$fail" -eq 0 ] || exit 1
  # Same-process P -> P+U -> P control. P calls Mark, consuming method-arity
  # metadata; the middle input adds U's unrelated owner/impl under the same Mark
  # interface/method spelling. This single-file entry has no import graph, so it
  # makes no module-order claim; the module emitter owns that separate dimension.
  # These private temp files are not a shared fixture corpus.
  command -v "$CC" >/dev/null 2>&1 || { echo "FAIL: no C compiler for isolation control"; exit 1; }
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then
    GC_CFLAGS="$(pkg-config --cflags bdw-gc)"; GC_LIBS="$(pkg-config --libs bdw-gc)"
  elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then
    GC_CFLAGS="-I$GC_PREFIX/include"; GC_LIBS="-L$GC_PREFIX/lib -lgc"
  else
    GC_CFLAGS=""; GC_LIBS="-lgc"
  fi
  ISO="$WORK/isolation"; mkdir "$ISO"
  printf '%s\n' 'interface Mark a where' '  mark : a -> Int' 'data P = P' 'impl Mark P where' '  mark P = 7' 'main = mark P' > "$ISO/p.mdk"
  printf '%s\n' 'interface Mark a where' '  mark : a -> Int' 'data U = U' 'impl Mark U where' '  mark U = 11' 'main = mark U' > "$ISO/u.mdk"
  printf '%s\n' 'interface Mark a where' '  mark : a -> Int' 'data P = P' 'data U = U' 'impl Mark P where' '  mark P = 7' 'impl Mark U where' '  mark U = 11' 'main = mark U' > "$ISO/positive.mdk"
  "$EMITBIN" --isolation "$RUNTIME" "$ISO/p.mdk" "$ISO/positive.mdk" > "$ISO/isolation.ll" 2> "$ISO/isolation.err"
  isolation_rc=$?
  if [ "$isolation_rc" -ne 0 ]; then
    printf 'FAIL: same-process EmitInput isolation control\n%s\n' "$(cat "$ISO/isolation.err")"
    exit 1
  fi
  isolation_verdict="$(cat "$ISO/isolation.ll")"
  [ "$isolation_verdict" = "LLVM_EMIT_ISOLATION_OK" ] || {
    printf 'FAIL: same-process EmitInput isolation verdict was %s\n' "$isolation_verdict"
    exit 1
  }
  for n in p positive; do
    "$EMITBIN" "$RUNTIME" "$ISO/$n.mdk" > "$ISO/$n.ll" 2> "$ISO/$n.err" || { cat "$ISO/$n.err"; exit 1; }
    "$CC" $GC_CFLAGS "$ISO/$n.ll" "$RT" $GC_LIBS -lm -o "$ISO/$n.bin" || exit 1
  done
  p_out="$("$ISO/p.bin")"; positive_out="$("$ISO/positive.bin")"
  [ "$p_out" = 7 ] && [ "$positive_out" = 11 ] || {
    printf 'FAIL: isolation control expected P=7 P+U=11; got P=%s P+U=%s\n' "$p_out" "$positive_out"
    exit 1
  }
  printf 'checked same-process LLVM emission isolation (P -> P+U -> P; distinct IR; P=7, P+U=11)\n'
  # Second same-process P -> P+U -> P control, shaped to reach core_ir_lower.mdk's
  # hoistNullaryMemo memo-CAF machinery, which the Mark control above never touches
  # (mark : a -> Int has non-empty positions, so it never enters memoKeys). theUnit
  # is nullary/return-position: P has a sole HasUnit impl (Box, hoisted directly, no
  # memo CAF needed); P+U adds a second impl (Cup), so both become multi-impl and
  # recordMultiImplMemo fires, synthesizing per-tag memo CAFs. These private temp
  # files are not a shared fixture corpus.
  printf '%s\n' 'interface HasUnit a where' '  theUnit : a' 'data Box = Box' 'impl HasUnit Box where' '  theUnit = Box' 'useTwice : HasUnit a => (a -> String) -> String' 'useTwice f = f theUnit' 'boxTag : Box -> String' 'boxTag Box = "box"' 'main = useTwice boxTag' > "$ISO/hu_p.mdk"
  printf '%s\n' 'interface HasUnit a where' '  theUnit : a' 'data Box = Box' 'data Cup = Cup' 'impl HasUnit Box where' '  theUnit = Box' 'impl HasUnit Cup where' '  theUnit = Cup' 'useTwice : HasUnit a => (a -> String) -> String' 'useTwice f = f theUnit' 'cupTag : Cup -> String' 'cupTag Cup = "cup"' 'main = useTwice cupTag' > "$ISO/hu_pu.mdk"
  "$EMITBIN" --isolation "$RUNTIME" "$ISO/hu_p.mdk" "$ISO/hu_pu.mdk" > "$ISO/hu_isolation.ll" 2> "$ISO/hu_isolation.err"
  hu_isolation_rc=$?
  if [ "$hu_isolation_rc" -ne 0 ]; then
    printf 'FAIL: same-process LowerState/memo-CAF isolation control (HasUnit)\n%s\n' "$(cat "$ISO/hu_isolation.err")"
    exit 1
  fi
  hu_isolation_verdict="$(cat "$ISO/hu_isolation.ll")"
  [ "$hu_isolation_verdict" = "LLVM_EMIT_ISOLATION_OK" ] || {
    printf 'FAIL: same-process LowerState/memo-CAF isolation verdict was %s (HasUnit)\n' "$hu_isolation_verdict"
    exit 1
  }
  for n in hu_p hu_pu; do
    "$EMITBIN" "$RUNTIME" "$ISO/$n.mdk" > "$ISO/$n.ll" 2> "$ISO/$n.err" || { cat "$ISO/$n.err"; exit 1; }
    "$CC" $GC_CFLAGS "$ISO/$n.ll" "$RT" $GC_LIBS -lm -o "$ISO/$n.bin" || exit 1
  done
  hu_p_out="$("$ISO/hu_p.bin")"; hu_pu_out="$("$ISO/hu_pu.bin")"
  [ "$hu_p_out" = box ] && [ "$hu_pu_out" = cup ] || {
    printf 'FAIL: HasUnit isolation control expected P=box P+U=cup; got P=%s P+U=%s\n' "$hu_p_out" "$hu_pu_out"
    exit 1
  }
  printf 'checked same-process LLVM emission isolation (HasUnit: P -> P+U -> P; distinct IR; nullary memo path; P=box, P+U=cup)\n'
  "$EMITBIN" --gap-isolation > "$ISO/gap-isolation.out" 2> "$ISO/gap-isolation.err"
  gap_rc=$?
  [ "$gap_rc" -ne 0 ] || {
    echo 'FAIL: strict LLVM emission inherited Record mode after a same-process recorded gap'
    exit 1
  }
  [ "$(cat "$ISO/gap-isolation.out")" = 'LLVM_GAP_RECORD_OK' ] || {
    printf 'FAIL: recorded-gap control did not reach its positive marker\n%s\n' "$(cat "$ISO/gap-isolation.out")"
    exit 1
  }
  grep -F 'unsupported Core IR node CMatch' "$ISO/gap-isolation.err" >/dev/null || {
    printf 'FAIL: strict-after-record control did not report CMatch\n%s\n' "$(cat "$ISO/gap-isolation.err")"
    exit 1
  }
  printf 'checked same-process LLVM gap isolation (Record -> Strict CMatch)\n'
fi
