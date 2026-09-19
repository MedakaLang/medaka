#!/bin/sh
# test/bytes_census.sh — derived `Array Int` type-position census, plus the
# baseline ratchet built on the same scanner. Modelled EXACTLY on
# test/comment_register_census.sh's three-mode shape (#2281's pattern, reused
# here for the Bytes epic, #3134). The DEFAULT (no-flag) mode is a reporting
# tool, run via `make bytes-census`: it asserts nothing and exits 0 on a
# healthy run, refusing (exit 1) only if the file corpus comes back empty.
# The `--write`/`--check` modes are the GATED path, consumed by
# test/diff_compiler_bytes_census.sh, a merge-tier gate.
#
# The scanner matches the literal two-word text "Array Int" on a single line
# (see count_positions below), so a type split across a line wrap, or with
# unusual internal spacing, under-counts. It is a FLOOR, not an exact count.
#
# WHY THIS EXISTS: epic #3134 is retiring `Array Int` as the ad-hoc
# representation of a byte sequence in favor of the packed `Bytes` type
# (stdlib/bytes.mdk). `Array Int` is not going away entirely — it remains the
# FFI-crossable set (limb arrays, general-purpose Int arrays unrelated to
# bytes) — so this is not a tree-wide "drive it to zero" ratchet. It is a
# PER-FILE count that, once a file opts in by getting a baseline row, may
# only fall for that file. A file with no row is UNCONSTRAINED: this census
# counts POSITIONS, not semantics, so it cannot tell a byte-sequence use from
# a limb array or an FFI signature — a tree-wide ratchet would false-positive
# on those every time. The one deliberate non-goal: stdlib/bytes.mdk itself
# never gets a row — its own `Array Int` positions (the ctor payload, the two
# conversions to/from `Array Int`) are the epic's permanent bridge, not debt.
#
# SCOPE: every git-tracked `*.mdk` file, tree-wide — unlike
# test/comment_register_census.sh (compiler/+stdlib/+pds/ only), this counts
# `pds/` and `gzip/` too, since neither sits under `$LINT_ROOTS`
# (.githooks/pre-commit) and no lint rule can see them.
#
# Counts occurrences of the literal two-word type-position text "Array Int"
# per file (`grep -o`), the same precision `git grep -o "Array Int"` gives at
# the tree-wide level. This is a TEXT match, not a parse: it can land inside
# a string literal or a comment, same tradeoff test/comment_register_census.sh
# documents for its own regexes. Acceptable for an opt-in per-file ratchet
# that a human decided to enroll a specific file into; too loose to ever
# become a tree-wide assertion, which is why this script only gates the files
# a baseline row explicitly names.
#
# Needs no built ./medaka — pure text/grep over tracked source files.
# Portable POSIX sh (grep -E, no bash-only features).
#
# Usage:  sh test/bytes_census.sh
#         sh test/bytes_census.sh --write <path> <file> [<file> ...]
#         sh test/bytes_census.sh --check <baseline> [<file> ...]
#
# Default (no args): per-file `Array Int` position count (files with at
# least one hit), then a tree-wide total. Exits 0 on a healthy run; refuses
# (exit 1) only if the file corpus comes back empty, which would otherwise
# misreport as a clean zero.
#
# --write <path> <file> [<file> ...]: (re)generate the baseline at <path>
# with exactly one row per NAMED file (its current `Array Int` count),
# whatever that count is — this does NOT scan the whole corpus for nonzero
# counts the way test/comment_register_census.sh's --write does, because
# most of the tree's `Array Int` occurrences are legitimate (limbs, FFI) and
# must stay UNRATCHETED. Only a human naming a file here opts it into the
# ratchet. Sanctioned way to move a baselined count or enroll a new file;
# never hand-edit the generated file.
#
# Floor check (#3177): before overwriting, --write reads <path>'s
# CURRENTLY-COMMITTED row (if any) for each named file. A file with no old
# row is a first enrollment and is always allowed. A file WITH an old row
# whose freshly-counted `Array Int` total exceeds that row's committed count
# is refused (nonzero exit) — writing a higher count would silently loosen
# an already-pinned ratchet. Pass --allow-increase (anywhere in the
# arguments) to deliberately re-pin a file upward.
#
# --check <baseline> [<file> ...]: the ratchet — for every (file, count) row
# already present in <baseline> (optionally intersected with the given
# <file> args, if any are passed), fail if the file's CURRENT count exceeds
# the row's pinned count. A file that appears in <file> args but has NO row
# in <baseline> is skipped entirely — unconstrained, per this script's
# design (see header) — never defaulted to a base of 0 the way
# test/comment_register_census.sh's classes are, since a bare `Array Int`
# count is not naturally zero almost everywhere the way a comment-register
# hit is.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

IFS='
'
files="$(git -C "$ROOT" ls-files -- '*.mdk')"

if [ -z "$files" ]; then
  echo "bytes_census: matched ZERO tracked .mdk files — harness bug, refusing to report" >&2
  exit 1
fi

# Prints the current "Array Int" position count for file $1. `grep -c`
# counts MATCHING LINES, not occurrences — a line with two occurrences must
# still count as 2 here (common in a tuple/record field list), so this uses
# -o | wc -l instead of -c.
count_positions() {
  grep -o 'Array Int' "$1" 2>/dev/null | wc -l | tr -d ' '
}

if [ "${1:-}" = "--write" ]; then
  outpath="${2:-}"
  [ -n "$outpath" ] || { echo "bytes_census: --write needs a <path>" >&2; exit 2; }
  shift 2
  [ "$#" -gt 0 ] || { echo "bytes_census: --write needs at least one <file>" >&2; exit 2; }

  allow_increase=0
  files_to_write=""
  for a in "$@"; do
    if [ "$a" = "--allow-increase" ]; then
      allow_increase=1
    else
      if [ -z "$files_to_write" ]; then
        files_to_write="$a"
      else
        files_to_write="$files_to_write
$a"
      fi
    fi
  done
  [ -n "$files_to_write" ] || { echo "bytes_census: --write needs at least one <file>" >&2; exit 2; }

  # Read the OLD committed baseline (if any) into file\tcount rows, same
  # parse shape as --check's, so a re-run of --write can never silently
  # raise an already-pinned count (#3177).
  old_parsed=""
  if [ -f "$outpath" ]; then
    old_parsed="$(mktemp)"
    awk '
      /^\[\[entry\]\]/ { if (f != "") print f "\t" n; f = ""; n = ""; next }
      /^file[ \t]*=/ { s = $0; sub(/^file[ \t]*=[ \t]*"/, "", s); sub(/"[ \t]*$/, "", s); f = s; next }
      /^count[ \t]*=/ { s = $0; sub(/^count[ \t]*=[ \t]*/, "", s); n = s; next }
      END { if (f != "") print f "\t" n }
    ' "$outpath" >"$old_parsed"
  fi

  if [ "$allow_increase" -eq 0 ] && [ -n "$old_parsed" ]; then
    floor_fail=0
    for f in $files_to_write; do
      old_count="$(awk -F'\t' -v f="$f" '$1 == f { print $2 }' "$old_parsed")"
      [ -n "$old_count" ] || continue
      new_count="$(count_positions "$f")"
      if [ "$new_count" -gt "$old_count" ]; then
        floor_fail=1
        echo "FAIL: $f: --write would raise the pinned Array Int count from $old_count to $new_count" >&2
      fi
    done
    if [ "$floor_fail" -ne 0 ]; then
      rm -f "$old_parsed"
      echo "" >&2
      echo "  A baselined file's Array Int position count may only FALL at write time." >&2
      echo "  Pass --allow-increase to deliberately re-pin a file upward." >&2
      exit 1
    fi
  fi
  rm -f "$old_parsed"

  set -- $files_to_write
  {
    echo "# test/bytes_census_baseline.toml — Array Int position count baseline,"
    echo "# GENERATED, never hand-edited (epic #3134)."
    echo "#"
    echo "# One [[entry]] per file this census has been explicitly enrolled for. A"
    echo "# file's count may drop freely; exceeding its own pinned count is an"
    echo "# error. A file with NO row here is UNCONSTRAINED — see"
    echo "# test/bytes_census.sh's header for why this is a per-file opt-in"
    echo "# ratchet, never a tree-wide one (stdlib/bytes.mdk deliberately gets no"
    echo "# row: its Array Int positions are the epic's permanent bridge)."
    echo "#"
    echo "# Enforced by test/diff_compiler_bytes_census.sh (merge-tier)."
    echo "#"
    echo "# Regenerate from the repo root, never by hand:"
    echo "#"
    echo "#   sh test/bytes_census.sh --write test/bytes_census_baseline.toml <file> ..."
    echo "#"
    echo "# Paths are relative to the repo root, matching every consumer above."
    for f in "$@"; do
      [ -f "$f" ] || { echo "bytes_census: --write: no such file: $f" >&2; exit 2; }
      n="$(count_positions "$f")"
      echo ""
      echo "[[entry]]"
      echo "file = \"$f\""
      echo "count = $n"
    done
  } >"$outpath"
  exit 0
fi

if [ "${1:-}" = "--check" ]; then
  shift
  baseline="${1:-}"
  [ -n "$baseline" ] || { echo "bytes_census: --check needs a <baseline> path" >&2; exit 2; }
  [ -f "$baseline" ] || { echo "FAIL: missing baseline $baseline" >&2; exit 1; }
  shift

  # Parse the baseline's [[entry]] blocks into file\tcount rows — awk, not
  # the shell, so a hand-edited or malformed row still parses deterministically.
  parsed="$(mktemp)"
  awk '
    /^\[\[entry\]\]/ { if (f != "") print f "\t" n; f = ""; n = ""; next }
    /^file[ \t]*=/ { s = $0; sub(/^file[ \t]*=[ \t]*"/, "", s); sub(/"[ \t]*$/, "", s); f = s; next }
    /^count[ \t]*=/ { s = $0; sub(/^count[ \t]*=[ \t]*/, "", s); n = s; next }
    END { if (f != "") print f "\t" n }
  ' "$baseline" >"$parsed"

  if [ "$#" -gt 0 ]; then
    targets=""
    for f in "$@"; do
      if [ -z "$targets" ]; then
        targets="$f"
      else
        targets="$targets
$f"
      fi
    done
  else
    targets="$(cut -f1 "$parsed")"
  fi

  fail=0
  checked=0
  for f in $targets; do
    base="$(awk -F'\t' -v f="$f" '$1 == f { print $2 }' "$parsed")"
    [ -n "$base" ] || continue
    checked=$((checked + 1))
    [ -f "$f" ] || { echo "FAIL: $f: baselined but file no longer exists"; fail=1; continue; }
    cur="$(count_positions "$f")"
    if [ "$cur" -gt "$base" ]; then
      fail=1
      echo "FAIL: $f: Array Int position count rose to $cur (baseline: $base)"
    fi
  done
  rm -f "$parsed"

  if [ "$fail" -ne 0 ]; then
    echo ""
    echo "  A baselined file's Array Int position count may only FALL."
    echo "  Regenerate the baseline after fixing (or deliberately re-pinning):"
    echo "    sh test/bytes_census.sh --write test/bytes_census_baseline.toml <file> ..."
    exit 1
  fi
  if [ "$checked" -eq 0 ]; then
    echo "FAIL: NOTHING CHECKED — every row was skipped (missing baseline entry" >&2
    echo "  or missing file). This is not a pass." >&2
    exit 1
  fi
  echo "-- bytes census baseline: ok ($checked file(s) checked)"
  exit 0
fi

n_files=0
total=0
per_file_report=""

for f in $files; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  n_files=$((n_files + 1))
  c="$(count_positions "$f")"
  total=$((total + c))
  if [ "$c" -gt 0 ]; then
    per_file_report="$per_file_report$f: $c
"
  fi
done

echo "bytes_census: $n_files tracked .mdk files tree-wide"
echo
echo "NOTE: this counts TEXT POSITIONS of the literal 'Array Int' type"
echo "occurrence — it cannot distinguish a byte sequence from a limb array or"
echo "an FFI signature. A per-file baseline ratchet (test/bytes_census.sh"
echo "--check) only constrains files a human has explicitly enrolled via"
echo "--write; every other file is unconstrained by design (see this"
echo "script's header)."
echo
echo "-- per-file breakdown (files with at least one hit) --"
if [ -n "$per_file_report" ]; then
  printf '%s' "$per_file_report"
else
  echo "  (none)"
fi
echo
echo "-- tree-wide total: $total"

exit 0
