#!/bin/sh
# test/arch_census.sh — derived architecture census. Not a gate: this is a
# reporting tool, run via `make arch-census`. It asserts nothing, encodes no
# threshold; exits 0 on a healthy run, and refuses (exit 1) only if the file
# corpus comes back empty — see below.
#
# WHY THIS EXISTS (#2289, leg 4 P of crusade #2276): tracked prose in this
# repo repeatedly hand-typed `.mdk` line counts as LIVE facts — e.g.
# docs/ops/CLI-CONFORMANCE.md's "Splitting `medaka_cli.mdk` (3,646 lines)"
# — and those counts rot the moment the file they describe changes again.
# Same failure shape as `test/fmt_clean_census.sh` (#1794) and
# `test/comment_register_census.sh` (#2281): a hand-maintained encoding of a
# fact this repo can derive on demand. This script derives it instead — run
# it, read the answer, never hand-type it into prose.
#
# THIS IS THE SOFT DETECTOR ONLY. It reports a largest-files table and
# per-directory file/line totals. It encodes NO threshold and renders NO
# verdict on any file or directory being "too big" — that judgment is the
# `architecture` skill's job (S-4 of this sprint), not this script's.
#
# SCOPE: every git-tracked `*.mdk` file under compiler/ and stdlib/,
# EXCLUDING test/ fixtures (same exclusion as fmt_clean_census.sh — a
# corpus fixture's size is not this script's business).
#
# WHY ON-DEMAND, NOT A CI GATE: same rationale as fmt_clean_census.sh and
# comment_register_census.sh — gating this tree-wide, with no threshold,
# would have nothing to assert against. A developer/agent convenience, not
# a merge gate.
#
# Needs no built ./medaka — pure `wc -l` over tracked source files.
# Portable POSIX sh.
#
# Usage:  sh test/arch_census.sh
# Output: largest-files table (top 20), then per-directory file/line
#         totals. Exits 0 on a healthy run; refuses (exit 1) only if the
#         file corpus comes back empty, which would otherwise misreport as
#         a clean zero.
# Reproducibility: deterministic given the same tracked tree — two runs
# against the same commit and worktree state produce byte-identical output.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

IFS='
'
files="$(git -C "$ROOT" ls-files -- 'compiler/*.mdk' 'stdlib/*.mdk' | grep -v '^test/')"
# ('compiler/*.mdk' 'stdlib/*.mdk' never produce anything under 'test/', so
# this exclusion is a no-op today — it's kept only to match
# fmt_clean_census.sh's pattern verbatim, for any future test/ nesting under
# compiler/ or stdlib/. compiler/entries/*.mdk is INCLUDED — the
# `architecture` skill names entries/ as a directory this census should
# show, and comment_register_census.sh's corpus already includes it.)

if [ -z "$files" ]; then
  echo "arch_census: matched ZERO .mdk files under compiler/ or stdlib/ — harness bug, refusing to report" >&2
  exit 1
fi

n_files=0
total_lines=0
counts_file="$(mktemp)"
trap 'rm -f "$counts_file"' EXIT

for f in $files; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  n=$(wc -l < "$f" | tr -d ' ')
  n_files=$((n_files + 1))
  total_lines=$((total_lines + n))
  printf '%s %s\n' "$n" "$f" >> "$counts_file"
done

echo "arch_census: $n_files tracked .mdk files under compiler/ and stdlib/ (excl. test/), $total_lines total lines"
echo
echo "-- largest files (top 20) --"
sort -rn "$counts_file" | head -20 | while IFS= read -r line; do
  n="${line%% *}"
  f="${line#* }"
  printf '  %8s  %s\n' "$n" "$f"
done
echo
echo "-- per-directory totals (immediate subdir of compiler/, plus stdlib/) --"
sed -e 's|^\([0-9]*\) compiler/\([^/]*\)/.*|\1 compiler/\2|' \
    -e 's|^\([0-9]*\) compiler/[^/]*\.mdk|\1 compiler|' \
    -e 's|^\([0-9]*\) stdlib/.*|\1 stdlib|' "$counts_file" |
  awk '{ n[$2] += $1; c[$2] += 1 } END { for (d in n) printf "%s %d %d\n", d, c[d], n[d] }' |
  sort -k3 -rn |
  while IFS=' ' read -r d fc lc; do
    printf '  %-24s %5s files  %8s lines\n' "$d" "$fc" "$lc"
  done

exit 0
