#!/bin/sh
# test/fmt_clean_census.sh — derived fmt-clean census. Not a gate: this is a
# reporting tool, run via `make fmt-clean-census`. It asserts nothing and
# always exits 0.
#
# WHY THIS EXISTS (#1794): AGENTS.md used to hand-maintain a two-line claim —
# "Tree is NOT fmt-clean: sqlite/lib/varint.mdk, stdlib/byteparser.mdk" — as
# the complete list of `.mdk` files that fail `medaka fmt --check`. It rotted
# silently: `gzip/lib/inflate.mdk` landed on `main` unformatted with no entry
# anywhere, and by the time this script was written the original two files
# had themselves been reformatted clean, so the hand-typed list was wrong in
# BOTH directions at once — stale entries for files that are now clean, and
# missing a file that wasn't. A hand-maintained enumeration of "every file
# with property X" is exactly the kind of encoded fact this project's own
# conventions warn against elsewhere ([T-STDLIB-IMPORT], the doc-link/
# doc-symbol rot gates, docs/README.md's own generation) — it never notices
# its own drift. This script derives the list instead, the same way
# `test/gen_docs_index.sh` derives docs/README.md: run it, read the answer,
# never hand-type it.
#
# SCOPE: every git-tracked `*.mdk` file in the repo, EXCLUDING `test/` (the
# pre-commit hook already excludes `test/` fixtures from fmt/lint — see
# AGENTS.md's "Pre-commit hook" section — so a corpus fixture deliberately
# holding malformed/unusual layout is not this script's business either).
#
# WHY ON-DEMAND, NOT A CI GATE (see #1794's own discussion, and the caution
# from #1654): gating this tree-wide would risk surfacing whatever unrelated
# pre-existing formatting debt already lives in the tree as a sudden required-
# check failure, unconnected to whatever PR happens to trip it — exactly the
# kind of blast-radius surprise this repo's gates are designed to avoid. This
# script is a developer/agent convenience and a `make docs-index`-style
# regeneration aid for AGENTS.md's fmt-clean claim, not a merge gate. If the
# tree is ever driven to (and kept at) fully fmt-clean, wiring this in as a
# gate becomes cheap and safe — until then, on demand is the honest scope.
#
# Needs a built ./medaka (uses `medaka fmt --check`). Portable POSIX sh.
#
# Usage:  sh test/fmt_clean_census.sh
# Output: one line per NOT-formatted file, plus a summary count. Always
#         exits 0 — this is a report, not a pass/fail check.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

MEDAKA="$ROOT/medaka"
if [ ! -x "$MEDAKA" ]; then
  echo "fmt_clean_census: no built ./medaka at $MEDAKA — run 'make medaka' first" >&2
  exit 1
fi

total=0
dirty=0
dirty_list=""

# Split on newline only — some paths could in principle contain spaces.
IFS='
'
files="$(git -C "$ROOT" ls-files -- '*.mdk' | grep -v '^test/')"

for f in $files; do
  [ -n "$f" ] || continue
  total=$((total + 1))
  if ! "$MEDAKA" fmt --check "$f" >/dev/null 2>&1; then
    dirty=$((dirty + 1))
    dirty_list="$dirty_list$f
"
  fi
done

if [ "$total" -eq 0 ]; then
  echo "fmt_clean_census: matched ZERO .mdk files outside test/ — harness bug, refusing to report" >&2
  exit 1
fi

if [ "$dirty" -gt 0 ]; then
  echo "NOT fmt-clean ($dirty of $total tracked .mdk files outside test/):"
  printf '%s' "$dirty_list" | while IFS= read -r f; do
    [ -n "$f" ] && echo "  $f"
  done
else
  echo "fmt-clean: all $total tracked .mdk files outside test/ pass 'medaka fmt --check'."
fi

exit 0
