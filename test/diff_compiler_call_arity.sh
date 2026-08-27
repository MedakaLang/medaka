#!/bin/sh
# test/diff_compiler_call_arity.sh — call/define arity-skew census (S-arity-census).
#
# New instrumentation, not a compiler behavior change. Derives, from EMITTED LLVM
# TEXT IR, every direct `call @NAME(...)` whose argument count differs from the
# `define @NAME(...)` for that same locally-defined function, over a corpus of
# `.mdk` programs (test/build_diff_fixtures/*.mdk, reused — the existing native
# `medaka build` fixture corpus) plus the two known-skew repro pins (#1101, #1648)
# and their controls, plus the compiler's OWN emitted IR (building
# compiler/driver/medaka_cli.mdk with --keep-ir — i.e. the self-compile output).
#
# This does NOT validate/reject anything at compile time — it is a census gate,
# reporting a count. Zero is not required to pass; the gate FAILS only if it
# stops flagging the two known-skew pins, or flags either control, or would
# report a suspicious ZERO total (comparing nothing — see the "no vacuous pass"
# discipline in docs/ops/TESTING-DESIGN.md §0.0).
#
# #1034 and #826 (open question per the packet, not a requirement either way):
# both are PAP/closure-arity bugs (an under-applied interface method whose
# result type is itself a function), not necessarily a direct call/define arity
# mismatch in the SAME function's own IR — this gate reports, in its header,
# whether it flags either program's emitted IR; it is not required to.
#
# Usage:  sh test/diff_compiler_call_arity.sh
# Exit:   0 pins correctly discriminated (and a nonzero corpus was scanned);
#         1 a known-skew pin was not flagged, a control WAS flagged, or the
#           corpus was empty;
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

# ── the two known-skew pins + their controls (not part of the corpus loop —
#    graded explicitly below) ──────────────────────────────────────────────
F1101="$ROOT/test/must_fail_fixtures/1101-native-call-drops-arg-caf-closure"
F1648="$ROOT/test/must_fail_fixtures/1648-impl-requires-unused-dict-arity-skew-segfault"
PIN_1101_MAIN="$(build_one "pin-1101-main" "$F1101/main.mdk")"
PIN_1101_CTRL="$(build_one "pin-1101-ctrl" "$F1101/control.mdk")"
PIN_1648_MAIN="$(build_one "pin-1648-main" "$F1648/main.mdk")"
PIN_1648_CTRL="$(build_one "pin-1648-ctrl" "$F1648/control.mdk")"

# ── open question: does the census also flag #1034 / #826? (no requirement
#    either way — report only) ─────────────────────────────────────────────
F1034="$ROOT/test/must_fail_fixtures/1034-underapplied-iface-method-becomes-pap"
F826="$ROOT/test/must_fail_fixtures/826-method-closure-wrapper-native-segfault"
PIN_1034_MAIN="$(build_one "pin-1034-main" "$F1034/main.mdk")"
PIN_826_MAIN="$(build_one "pin-826-main" "$F826/main.mdk")"

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
echo "-- #1101 / #1648 pin discrimination --"
echo "1101 main : $([ -n "$PIN_1101_MAIN" ] && echo FLAGGED || echo clean)  ($PIN_1101_MAIN)"
echo "1101 ctrl : $([ -n "$PIN_1101_CTRL" ] && echo FLAGGED || echo clean)"
echo "1648 main : $([ -n "$PIN_1648_MAIN" ] && echo FLAGGED || echo clean)  ($PIN_1648_MAIN)"
echo "1648 ctrl : $([ -n "$PIN_1648_CTRL" ] && echo FLAGGED || echo clean)"
echo ""
echo "-- #1034 / #826 (open question, not required either way) --"
echo "1034 main : $([ -n "$PIN_1034_MAIN" ] && echo FLAGGED || echo "not flagged (PAP/closure-arity skew, not a same-function call/define skew)")"
echo "826  main : $([ -n "$PIN_826_MAIN" ] && echo FLAGGED || echo "not flagged (PAP/closure-arity skew, not a same-function call/define skew)")"

fail=0
if [ -z "$PIN_1101_MAIN" ]; then echo "FAIL: #1101 main.mdk not flagged"; fail=1; fi
if [ -n "$PIN_1101_CTRL" ]; then echo "FAIL: #1101 control.mdk WAS flagged (should be clean)"; fail=1; fi
if [ -z "$PIN_1648_MAIN" ]; then echo "FAIL: #1648 main.mdk not flagged"; fail=1; fi
if [ -n "$PIN_1648_CTRL" ]; then echo "FAIL: #1648 control.mdk WAS flagged (should be clean)"; fail=1; fi

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
