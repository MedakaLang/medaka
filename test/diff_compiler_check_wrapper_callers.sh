#!/bin/sh
# diff_compiler_check_wrapper_callers.sh — pins the CALLER SET of the
# `checkProgram*`/`checkOne*` typecheck-entry wrapper family (E-1 #1115, epic #1122).
#
# WHY THIS GATE EXISTS.
# S-flat-reacher-census found the wrapper family's own consumer census had already
# drifted UNFLAGGED once (`entries/origin_agreement_main.mdk` was added as a caller
# 2026-08-02, four days after the issue's original enumeration, with nothing anywhere
# noticing). The migration slices that followed (S-migrate-check-route,
# S-migrate-tool-consumers[-remainder]) also found that not every caller can move onto
# the Module arm safely — some are PARKED on the Flat-only members of the family for
# measured reasons (a scheme-list-shape gap on `checkOneScheme`, a repeated-call state
# leak on `checkOneToLinesWithRuntime`) that a future editor won't see just by reading
# a call site. A caller set that can silently gain a new member is a caller set nobody
# can trust an audit of.
#
# WHAT IT DOES (pure text analysis — no compiler build, no oracle, fast + safe):
#   1. DERIVES the current caller set: for every `.mdk` file under `compiler/` (other
#      than `compiler/types/typecheck.mdk` itself, the family's home), parse its
#      `import types.typecheck.{ ... }` block (which may span multiple lines) and
#      record which of the 13 wrapper-family names it imports. A name mentioned only
#      in a comment (not imported) is NOT a caller — this gate is keyed on the import,
#      matching how S-migrate-tool-consumers-remainder's own investigation avoided
#      false positives from stale prose mentioning an old function name.
#   2. Compares that DERIVED set against the checked-in ledger
#      (test/CHECK-WRAPPER-CALLERS.txt, `file : comma,separated,names`, one line per
#      caller file, sorted). A file/name pair present in one set but not the other is
#      a FAIL, naming the file and whether it is a NEW caller (ledger update needed)
#      or a STALE ledger row (caller removed, e.g. by a future migration — drop the row).
#   3. Prints `checked N caller file(s)`. N == 0 is a HARD FAILURE — a coverage check
#      that measured nothing must never report green (this suite's own standing rule:
#      grep -rn 'N == 0' test/diff_compiler_perf_stage_census.sh for the sibling gate
#      this one is modeled on).
#
# Usage:  sh test/diff_compiler_check_wrapper_callers.sh
# Exit:   0 the derived caller set matches the ledger exactly; 1 otherwise; 2 setup error.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEDGER="$ROOT/test/CHECK-WRAPPER-CALLERS.txt"

[ -f "$LEDGER" ] || { echo "FAIL: missing $LEDGER — cannot run the caller-set census."; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found (needed for the census set logic)"; exit 2; }

python3 - "$ROOT" "$LEDGER" <<'PY'
import sys, re, pathlib

root, ledger_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

WRAP_NAMES = [
    "checkProgramSchemesWithRuntime", "checkProgramSchemes",
    "checkProgramSeededSplit", "checkProgramSeeded",
    "checkToLinesWithRuntime", "checkErrorsWithRuntime",
    "checkMatchToLines", "checkProgramDiags",
    "checkOneScheme", "checkOneDiags",
    "checkOneToLinesWithRuntime", "checkOneErrorsWithRuntime",
    # `checkToLines` (the prelude-free Flat entry) was MISSING from this list until
    # 2026-08-26, which made the gate demonstrably blind: a new caller importing it
    # passed the census unnoticed, and `compiler/entries/selfproc_tc_probe.mdk` had
    # in fact been such a caller all along, absent from the ledger. Ordered AFTER
    # `checkToLinesWithRuntime` above is not load-bearing (the `\b` after the
    # alternation already stops `checkToLines` from matching inside it), but the
    # family-member count in this gate's header is: keep them in sync.
    "checkToLines",
]
WRAP_SET = set(WRAP_NAMES)
NAME_RE = re.compile(r"\b(" + "|".join(re.escape(n) for n in WRAP_NAMES) + r")\b")
IMPORT_START = re.compile(r"import\s+types\.typecheck\.")

home = root / "compiler" / "types" / "typecheck.mdk"

derived = {}   # relpath -> frozenset(names)
for path in sorted(root.glob("compiler/**/*.mdk")):
    if path == home:
        continue
    text = path.read_text()
    lines = text.splitlines()
    names = set()
    i = 0
    n = len(lines)
    while i < n:
        if IMPORT_START.search(lines[i]):
            j = i
            block = []
            while j < n:
                block.append(lines[j])
                if "}" in lines[j]:
                    break
                j += 1
            block_text = "\n".join(block)
            names |= set(NAME_RE.findall(block_text))
            i = j + 1
        else:
            i += 1
    if names:
        derived[str(path.relative_to(root))] = frozenset(names & WRAP_SET)

ledger = {}
for lineno, raw in enumerate(ledger_path.read_text().splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if " : " not in line:
        print(f"FAIL: {ledger_path}:{lineno}: malformed row (expected 'file : name,name,...'): {raw!r}")
        sys.exit(1)
    f, names_str = line.split(" : ", 1)
    ledger[f.strip()] = frozenset(x for x in names_str.strip().split(",") if x)

fail = False
all_files = sorted(set(derived) | set(ledger))
for f in all_files:
    d = derived.get(f, frozenset())
    l = ledger.get(f, frozenset())
    if d != l:
        fail = True
        added = d - l
        removed = l - d
        if f not in ledger:
            print(f"FAIL: NEW caller not in ledger: {f} : {','.join(sorted(d))}")
            print(f"      -> add this row to {ledger_path.relative_to(root)}")
        elif f not in derived:
            print(f"FAIL: STALE ledger row (no longer a caller): {f} : {','.join(sorted(l))}")
            print(f"      -> remove this row from {ledger_path.relative_to(root)}")
        else:
            if added:
                print(f"FAIL: {f}: gained wrapper name(s) not in ledger: {','.join(sorted(added))}")
            if removed:
                print(f"FAIL: {f}: ledger names no longer imported: {','.join(sorted(removed))}")

n = len(all_files)
if n == 0:
    print("FAIL: checked 0 caller file(s) — a coverage check that measured nothing must never report green.")
    sys.exit(1)

if fail:
    sys.exit(1)

print(f"PASS: checked {n} caller file(s) — derived set matches the ledger exactly.")
PY
