#!/bin/sh
# test/diff_compiler_call_arity.sh — call/define arity-skew census (S-arity-census).
#
# New instrumentation, not a compiler behavior change. Derives, from EMITTED LLVM
# TEXT IR, every direct `call @NAME(...)` whose argument count differs from the
# `define @NAME(...)` for that same locally-defined function, over a corpus of
# `.mdk` programs (test/build_diff_fixtures/*.mdk, reused — the existing native
# `medaka build` fixture corpus) plus the known-skew repro pin (#1101) and its
# control, plus the compiler's OWN emitted IR (building
# compiler/driver/medaka_cli.mdk with --keep-ir — i.e. the self-compile output).
#
# This does NOT validate/reject anything at compile time — it is a census gate,
# reporting a count. Zero is not required to pass; the gate FAILS only if it
# stops flagging the known-skew pin, flags its control, flags the #1648
# regression fixture, or would report a suspicious ZERO total (comparing nothing
# — see the "no vacuous pass" discipline in docs/ops/TESTING-DESIGN.md §0.0).
#
# #1648 (impl-`requires` dict-param arity skew) is FIXED and its must-fail fixture
# is drained and deleted, so its arm here is INVERTED: the replacement regression
# fixture test/build_diff_fixtures/impl_requires_dict_arity_conformance.mdk must
# stay CLEAN, and the gate proves that fixture still exists so the absence
# assertion is not vacuous. #1034 and #826 were likewise fixed and deleted; the
# report-only rows that named them are gone with their paths.
#
# Usage:  sh test/diff_compiler_call_arity.sh
# Exit:   0 pins correctly discriminated (and a nonzero corpus was scanned);
#         1 a known-skew pin was not flagged, a control or the #1648 regression
#           fixture WAS flagged, that fixture is missing, or the corpus was empty;
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

# ── the known-skew pin + its control (not part of the corpus loop — graded
#    explicitly below) ───────────────────────────────────────────────────────
F1101="$ROOT/test/must_fail_fixtures/1101-native-call-drops-arg-caf-closure"
PIN_1101_MAIN="$(build_one "pin-1101-main" "$F1101/main.mdk")"
PIN_1101_CTRL="$(build_one "pin-1101-ctrl" "$F1101/control.mdk")"

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

# ── the compiler's own emitted IR (self-compile output) ───────────────────────
COMPILER_OUT="$(build_one "compiler-self" "$ROOT/compiler/driver/medaka_cli.mdk")"

# ── tallies ─────────────────────────────────────────────────────────────────
n_corpus="$(grep -c . "$CORPUS_OUT" 2>/dev/null)"; n_corpus="${n_corpus:-0}"
n_compiler="$(printf '%s\n' "$COMPILER_OUT" | grep -c . 2>/dev/null)"; n_compiler="${n_compiler:-0}"
[ -n "$COMPILER_OUT" ] || n_compiler=0
n_total=$((n_corpus + n_compiler))
n_programs_scanned="$(printf '%s\n' "$PROGRAMS" | wc -l | tr -d ' ')"

echo "=== call/define arity-skew census (S-arity-census) ==="
echo "corpus: test/build_diff_fixtures/*.mdk ($n_programs_scanned programs)"
echo "$n_total sites, $n_corpus in corpus + $n_compiler in compiler's own IR"
echo ""
echo "-- corpus skews --"
[ -s "$CORPUS_OUT" ] && cat "$CORPUS_OUT" || echo "  (none)"
echo ""
echo "-- compiler's own IR skews (compiler/driver/medaka_cli.mdk --keep-ir) --"
[ -n "$COMPILER_OUT" ] && printf '%s\n' "$COMPILER_OUT" || echo "  (none)"
echo ""
echo "-- #1101 pin discrimination --"
echo "1101 main : $([ -n "$PIN_1101_MAIN" ] && echo FLAGGED || echo clean)  ($PIN_1101_MAIN)"
echo "1101 ctrl : $([ -n "$PIN_1101_CTRL" ] && echo FLAGGED || echo clean)"
echo ""
echo "-- #1648 regression (impl-\`requires\` dict-param arity, FIXED) --"
echo "1648 regression fixture : $([ -n "$REG_1648" ] && echo "FLAGGED  ($REG_1648)" || echo clean)"

fail=0
if [ -z "$PIN_1101_MAIN" ]; then echo "FAIL: #1101 main.mdk not flagged"; fail=1; fi
if [ -n "$PIN_1101_CTRL" ]; then echo "FAIL: #1101 control.mdk WAS flagged (should be clean)"; fail=1; fi
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

if [ "$fail" -eq 0 ]; then
  echo ""
  echo "PASS: pins correctly discriminated; $n_total sites recorded ($n_corpus corpus + $n_compiler compiler-self)."
fi
exit "$fail"
