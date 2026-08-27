#!/bin/sh
# test/diff_compiler_call_arity.sh — call/define arity-skew census (S-arity-census).
#
# New instrumentation, not a compiler behavior change. Derives, from EMITTED LLVM
# TEXT IR, every direct `call @NAME(...)` whose argument count differs from the
# `define @NAME(...)` for that same locally-defined function, over a corpus of
# `.mdk` programs (test/build_diff_fixtures/*.mdk, reused — the existing native
# `medaka build` fixture corpus) plus the compiler's OWN emitted IR (building
# compiler/driver/medaka_cli.mdk with --keep-ir — i.e. the self-compile output).
#
# This does NOT validate/reject anything at compile time — it is a census gate,
# reporting a count. Zero is not required to pass; the gate FAILS only if one of
# the regression fixtures below is FLAGGED or MISSING, or if it would report a
# suspicious ZERO total (comparing nothing — see the "no vacuous pass"
# discipline in docs/ops/TESTING-DESIGN.md §0.0).
#
# ALL of this gate's pinned arms are now INVERTED — every skew it was built to
# pin has been fixed, so what it asserts is the ABSENCE of each skew in the
# regression fixture that replaced the drained must-fail row, plus the presence
# of that fixture so the absence assertion is not vacuous:
#   * #1648 (impl-`requires` dict-param arity skew) ->
#     test/build_diff_fixtures/impl_requires_dict_arity_conformance.mdk
#   * #1101 (unconditional direct call from `emitFnBody`'s tail-position
#     known-fn arm — an over- or under-applied tail call went straight into a
#     mis-arity'd `define`) ->
#     test/build_diff_fixtures/tail_over_application_arity_conformance.mdk
# Both are auto-enrolled by the corpus `*.mdk` glob, so their verdicts are read
# out of the corpus scan rather than paying a second build. #1034 and #826 were
# likewise fixed and deleted; the report-only rows that named them are gone with
# their paths.
#
# #2078 (S1, OPEN, deliberately unfixed this sprint): emitApp's known-fn arm uses
# fnArity (signature arity) instead of defArityOf (emitted define arity), so an
# eta-short point-free wrapper segfaults. This is exactly the shape this gate
# flags. Its 9-line issue-body repro is scanned as a REPORT-ONLY row (no
# pass/fail requirement, labeled "known, filed, not required to be clean") so
# the headline site count is honest rather than reading as a stronger
# conformance claim than the gate actually supports.
#
# R8: a corpus program that fails to BUILD is silently dropped from the scan
# with no trace in the report (the failed-build message went to stderr only).
# build_one now also appends the label to a build-failures tally, and the
# summary prints an n_build_failures count. A build failure on either named
# regression fixture (REG_1101_LABEL / REG_1648_LABEL) is a hard FAIL — a
# regression fixture that didn't build is UNSCANNED, not "clean".
#
# Usage:  sh test/diff_compiler_call_arity.sh
# Exit:   0 the regression fixtures are clean and present (and a nonzero corpus
#           was scanned, and neither regression fixture failed to build);
#         1 a regression fixture WAS flagged, missing, or failed to build, or
#           the corpus was empty;
#         2 native medaka/emitter missing, no C compiler, or no python3.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIX="$ROOT/test/build_diff_fixtures"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "no C compiler (clang) on PATH — skipping"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 on PATH — skipping"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BUILD_FAILURES_OUT="$WORK/build_failures.out"
: > "$BUILD_FAILURES_OUT"

# ── the arity scanner: reads one emitted .ll, prints one line per skew ────────
scan() {
  python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", errors="replace") as f:
    text = f.read()

def split_top_level_args(s):
    s = s.strip()
    if not s:
        return []
    depth = 0
    parts = []
    cur = []
    for ch in s:
        if ch in "([{":
            depth += 1
            cur.append(ch)
        elif ch in ")]}":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return [p for p in parts if p.strip()]

def find_paren_body(text, open_idx):
    depth = 0
    i = open_idx
    n = len(text)
    start = open_idx + 1
    while i < n:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[start:i]
        i += 1
    return text[start:]

DEFINE_RE = re.compile(r'^define\s+[^@]*@([A-Za-z0-9_.$]+)\s*\(', re.M)
CALL_RE = re.compile(r'\bcall\s+[a-zA-Z0-9_() ,%*\[\]]*?@([A-Za-z0-9_.$]+)\s*\(')

defines = {}
for m in DEFINE_RE.finditer(text):
    name = m.group(1)
    open_idx = m.end() - 1
    body = find_paren_body(text, open_idx)
    arity = len(split_top_level_args(body))
    defines.setdefault(name, arity)

lines = text.splitlines()
n_skew = 0
for m in CALL_RE.finditer(text):
    name = m.group(1)
    if name not in defines:
        continue
    open_idx = m.end() - 1
    body = find_paren_body(text, open_idx)
    call_arity = len(split_top_level_args(body))
    def_arity = defines[name]
    if call_arity != def_arity:
        line_no = text.count("\n", 0, m.start()) + 1
        line_text = lines[line_no - 1].strip() if line_no <= len(lines) else ""
        print(f"{name} define={def_arity} call={call_arity} line={line_no}: {line_text}")
        n_skew += 1
sys.exit(0)
PY
}

# build_one <label> <src.mdk>  — build to $WORK/<label>.ll via --keep-ir, print
# scan() output prefixed with the label, and echo the skew count on stderr fd 3.
build_one() {
  label="$1"; src="$2"
  bin="$WORK/$label.bin"
  if ! MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" MEDAKA_STRICT=1 \
       "$MEDAKA" build "$src" -o "$bin" --keep-ir >"$WORK/$label.build.log" 2>&1; then
    echo "  [build FAILED: $label — $(tail -3 "$WORK/$label.build.log" | tr '\n' ' ')]" >&2
    echo "$label" >> "$BUILD_FAILURES_OUT"
    return 0
  fi
  # --keep-ir writes the IR to outPath ++ ".ll" (build_cmd.mdk) — NOT
  # "$label.ll"; bin already has ".bin", so the IR lands at "$bin.ll".
  if [ ! -f "$bin.ll" ]; then
    echo "  [no .ll produced for $label]" >&2
    return 0
  fi
  scan "$bin.ll" | sed "s/^/$label: /"
}

# ── corpus: reuse the existing native build fixture directory ─────────────────
PROGRAMS="$(cd "$FIX" && ls -- *.mdk 2>/dev/null | sed 's/\.mdk$//' | sort)"
[ -n "$PROGRAMS" ] || { echo "test/build_diff_fixtures/*.mdk is empty — nothing to scan"; exit 1; }

CORPUS_OUT="$WORK/corpus.out"
: > "$CORPUS_OUT"
for p in $PROGRAMS; do
  build_one "corpus-$p" "$FIX/$p.mdk" >> "$CORPUS_OUT"
done

# ── #1101 (FIXED, S-caf-closure-apply): `emitFnBody`'s tail-position known-fn arm
#    emitted an UNCONDITIONAL direct call with every flattened argument, so an
#    over-applied tail call passed surplus words to a smaller `define` and the
#    returned closure was never invoked (silent S0). Its must-fail fixture drained
#    and was deleted, so this arm INVERTED just as #1648's did: the replacement
#    regression fixture must stay CLEAN. It covers a wider shape than #1101's own
#    repro — the CAF the issue claimed was required is NOT (measured by the slice's
#    spike); the true conditions are a non-saturated known-fn application sitting in
#    TAIL position of a non-`main` top-level binding. Auto-enrolled by the corpus
#    glob above, so read its verdict from that scan.
REG_1101_LABEL="corpus-tail_over_application_arity_conformance"
REG_1101="$(grep "^$REG_1101_LABEL: " "$CORPUS_OUT" 2>/dev/null)"
REG_1101_PRESENT="$(cd "$FIX" && ls -- tail_over_application_arity_conformance.mdk 2>/dev/null)"

# ── #1648 (FIXED, S-dict-param-arity): its must-fail fixture drained and was
#    deleted, so this gate's #1648 arm INVERTED — from "the pin must be flagged"
#    to "the regression fixture that replaced it must stay CLEAN". The fixture is
#    test/build_diff_fixtures/impl_requires_dict_arity_conformance.mdk, already
#    scanned by the corpus loop above (it is auto-enrolled by the *.mdk glob), so
#    read the verdict out of that scan rather than paying a second build.
#    #1034 and #826 were likewise fixed and their fixtures deleted (slice
#    S-method-arity-lowering); the census rows that reported on them are gone with
#    them — they were "report only, no requirement either way" and their paths no
#    longer exist.
REG_1648_LABEL="corpus-impl_requires_dict_arity_conformance"
REG_1648="$(grep "^$REG_1648_LABEL: " "$CORPUS_OUT" 2>/dev/null)"
REG_1648_PRESENT="$(cd "$FIX" && ls -- impl_requires_dict_arity_conformance.mdk 2>/dev/null)"

# ── #2078 (KNOWN, FILED, OPEN — deliberately unfixed this sprint) ─────────────
#    emitApp's known-fn arm (compiler/backend/llvm_emit.mdk:4247) measures a
#    call site's arity with fnArity (signature/clause arity) instead of
#    defArityOf (emitted define arity). An eta-short point-free wrapper's
#    define gets eta-saturated to a wider arity than its own signature, so the
#    call site under-applies the actual define and the binary segfaults. This
#    is exactly the shape this gate is built to flag. Scanned as a REPORT-ONLY
#    row — no pass/fail requirement — so the gate's headline site count is
#    honest about a known instance rather than reading as a stronger
#    conformance claim than it supports.
KNOWN_2078_SRC="$WORK/known_2078_eta_short_wrapper.mdk"
cat > "$KNOWN_2078_SRC" <<'MDK'
add : Int -> Int -> Int
add a b = a + b

mk : Int -> Int -> Int
mk n = add n

apply1 : (Int -> Int) -> Int -> Int
apply1 f x = f x

main = println (apply1 (mk 1) 2)
MDK
KNOWN_2078_OUT="$(build_one "known-2078" "$KNOWN_2078_SRC")"

# ── the compiler's own emitted IR (self-compile output) ───────────────────────
COMPILER_OUT="$(build_one "compiler-self" "$ROOT/compiler/driver/medaka_cli.mdk")"

# ── tallies ─────────────────────────────────────────────────────────────────
n_corpus="$(grep -c . "$CORPUS_OUT" 2>/dev/null)"; n_corpus="${n_corpus:-0}"
n_compiler="$(printf '%s\n' "$COMPILER_OUT" | grep -c . 2>/dev/null)"; n_compiler="${n_compiler:-0}"
[ -n "$COMPILER_OUT" ] || n_compiler=0
n_known_2078="$(printf '%s\n' "$KNOWN_2078_OUT" | grep -c . 2>/dev/null)"; n_known_2078="${n_known_2078:-0}"
[ -n "$KNOWN_2078_OUT" ] || n_known_2078=0
n_total=$((n_corpus + n_compiler + n_known_2078))
n_programs_scanned="$(printf '%s\n' "$PROGRAMS" | wc -l | tr -d ' ')"
n_build_failures="$(grep -c . "$BUILD_FAILURES_OUT" 2>/dev/null)"; n_build_failures="${n_build_failures:-0}"

echo "=== call/define arity-skew census (S-arity-census) ==="
echo "corpus: test/build_diff_fixtures/*.mdk ($n_programs_scanned programs)"
echo "$n_total sites, $n_corpus in corpus + $n_compiler in compiler's own IR + $n_known_2078 in #2078 report-only row"
echo "n_build_failures: $n_build_failures"
echo ""
echo "-- corpus skews --"
[ -s "$CORPUS_OUT" ] && cat "$CORPUS_OUT" || echo "  (none)"
echo ""
echo "-- compiler's own IR skews (compiler/driver/medaka_cli.mdk --keep-ir) --"
[ -n "$COMPILER_OUT" ] && printf '%s\n' "$COMPILER_OUT" || echo "  (none)"
echo ""
echo "-- #2078 known/filed report-only row (NOT required to be clean — OPEN, deliberately unfixed this sprint) --"
[ -n "$KNOWN_2078_OUT" ] && printf '%s\n' "$KNOWN_2078_OUT" || echo "  (none — unexpected; see #2078)"
echo ""
echo "-- build failures (R8: unscanned, not tallied as clean) --"
[ -s "$BUILD_FAILURES_OUT" ] && cat "$BUILD_FAILURES_OUT" || echo "  (none)"
echo ""
echo "-- #1101 regression (tail-position call/define arity, FIXED) --"
echo "1101 regression fixture : $([ -n "$REG_1101" ] && echo "FLAGGED  ($REG_1101)" || echo clean)"
echo ""
echo "-- #1648 regression (impl-\`requires\` dict-param arity, FIXED) --"
echo "1648 regression fixture : $([ -n "$REG_1648" ] && echo "FLAGGED  ($REG_1648)" || echo clean)"

fail=0
if [ -n "$REG_1101" ]; then
  echo "FAIL: #1101 REGRESSED — tail_over_application_arity_conformance.mdk has a call/define"
  echo "      arity skew again. A non-saturated application of a known top-level function in"
  echo "      TAIL position of a non-\`main\` top-level binding is being emitted as an"
  echo "      unconditional direct call instead of routing through emitApp's arity-disciplined"
  echo "      emitKnownFnSat (emitOverApp / emitPapClosure)."
  fail=1
fi
# The #1101 arm is an absence assertion, so it must prove it looked at something.
if [ -z "$REG_1101_PRESENT" ]; then
  echo "FAIL: the #1101 regression fixture (tail_over_application_arity_conformance.mdk) is"
  echo "      MISSING from $FIX — its 'clean' verdict above asserted nothing."
  fail=1
fi
if [ -n "$REG_1648" ]; then
  echo "FAIL: #1648 REGRESSED — impl_requires_dict_arity_conformance.mdk has a call/define"
  echo "      arity skew again. An impl-\`requires\` method whose body never reads its dict is"
  echo "      being DEFINED without the leading dict param and CALLED with it (or vice versa)."
  fail=1
fi
# The #1648 arm is an absence assertion, so it must prove it looked at something.
if [ -z "$REG_1648_PRESENT" ]; then
  echo "FAIL: the #1648 regression fixture (impl_requires_dict_arity_conformance.mdk) is"
  echo "      MISSING from $FIX — its 'clean' verdict above asserted nothing."
  fail=1
fi

# Never pass having scanned nothing (docs/ops/TESTING-DESIGN.md §0.0).
if [ "$n_programs_scanned" -eq 0 ]; then
  echo "FAIL: the corpus loop scanned ZERO programs — this gate compared nothing."
  fail=1
fi

# R8: a build failure on either named regression fixture means it was never
# SCANNED — that is not "clean", and reporting it as clean would be a false pass.
if grep -qx "$REG_1101_LABEL" "$BUILD_FAILURES_OUT" 2>/dev/null; then
  echo "FAIL: #1101 regression fixture (tail_over_application_arity_conformance.mdk)"
  echo "      FAILED TO BUILD — unscanned, not clean. See the build-failures list above."
  fail=1
fi
if grep -qx "$REG_1648_LABEL" "$BUILD_FAILURES_OUT" 2>/dev/null; then
  echo "FAIL: #1648 regression fixture (impl_requires_dict_arity_conformance.mdk)"
  echo "      FAILED TO BUILD — unscanned, not clean. See the build-failures list above."
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo ""
  echo "PASS: regression fixtures clean, present, and built; $n_total sites recorded"
  echo "      ($n_corpus corpus + $n_compiler compiler-self + $n_known_2078 #2078 report-only); n_build_failures=$n_build_failures."
fi
exit "$fail"
