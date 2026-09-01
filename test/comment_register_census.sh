#!/bin/sh
# test/comment_register_census.sh — derived, diffable census of the
# comment-register classes named by #2281 (the anti-slop crusade, leg 3).
#
# ── IT ASSERTS NOTHING. IT IS A CENSUS, NOT A GATE. ──────────────────────────
# Pure grep/awk over tracked `.mdk` source — no built `./medaka` is needed or
# used. Always exits 0. Listed in test/CI-COVERAGE-TOOLS.txt, not
# test/gates.toml (see AGENTS.md F3 / [W-SHARD-DERIVED] does not apply here).
#
# WHY THIS EXISTS: the crusade's premise is that a stale or falsified comment
# teaches the next reader (human or agent) something false about live code.
# This script is the burn-down instrument — run it before and after a
# relocation/deletion slice and diff the two outputs; the classes below should
# move in the stated direction (AGENTS.md's comment-register paragraph names
# the destination-pointer shape a relocation must leave behind).
#
# CLASSES COUNTED (each a *line classification*, not a disjoint defect count —
# a single line can and does land in more than one class, e.g. an emoji-shout
# line inside a tombstone paragraph):
#   dead-path      a comment citing a `lib/*.ml` (or `.mll`/`.mly`) path — the
#                  OCaml reference compiler removed 2026-06-26 (oracle-frozen).
#   tombstone      "X was HERE and is RETIRED" / "do not re-add".
#   tombstone-sib  the softer sibling form: "now lives in" / "moved to" /
#                  "now comes from" (#2281: undercounted by >2x if omitted).
#   ruling-vocab   refuted / ratified / withdrawn / ruling — litigating a
#                  review decision. Deliberately EXCLUDES "MEASURED": that
#                  word carries dated, reproducible provenance this repo
#                  wants kept, not narrative to relocate (#2281's own
#                  correction — do not add it to this class).
#   history        "Until 20…" / "formerly" / "The old " — narrating what
#                  used to be true. Excludes the instrumental sense "(is/are/
#                  was/be/been) used to" (~20% false-positive rate on that
#                  phrasing per #2281).
#   draft-correct  "earlier cut" / "first cut" / "earlier revision" / "an
#                  earlier draft" — a draft correcting itself in place. Remedy
#                  is deletion, not relocation (#2280 carve-out).
#   this-pr-raw    case-insensitive substring "this pr" — DELIBERATELY NAIVE:
#                  a superset that also catches "this practice", "this
#                  predicate", etc. Reported only as the raw/tight contrast.
#   this-pr-tight  literal, case-sensitive, whole-word "this PR" — the actual
#                  dead-deictic hits (a phrase that outlives the PR it names).
#   emoji-shout    🚨 / ⚠️ / 🔒 — counted, never swept (mass-convert declined
#                  epic-wide; see AGENTS.md's snapshot-corpus/LEG-A/fixpoint
#                  reasoning).
#   comment-lines  every line whose only content (after leading whitespace) is
#                  a `--` line comment. Not a defect signal by itself — #2281
#                  is explicit that a length ratchet on this teaches short bad
#                  comments instead of good ones. Reported for context only.
#   comment-blocks a comment-lines RUN of 12 or more consecutive lines — the
#                  in-body-essay signal slices 2-5 triage against.
#
# Scope: every git-tracked `*.mdk` file under compiler/ and stdlib/. The
# comparison baseline (AGENTS.md's [T-STDLIB-IMPORT]-style "already settled"
# numbers) is compiler/-only; stdlib/ is read here but not a target of any
# relocation this sprint licenses (#2441 owns stdlib/ edits this cycle).
#
# Usage:  sh test/comment_register_census.sh [compiler|stdlib|both]
# Output: one summary line per class per scope, then a per-file breakdown
#         (nonzero files only, sorted by path — git ls-files is already
#         sorted, so two runs over the same tree diff byte-identical).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

SCOPE_ARG="${1:-both}"

list_files() {
  # $1 = glob root (compiler|stdlib)
  git ls-files -- "$1/*.mdk"
}

# Count MATCHING LINES (grep -c) of $2 (an ERE) summed over the file list in
# $1 (a newline-separated list, read from stdin via the caller). Prints
# "TOTAL" on stdout; per-file nonzero counts go to the file named by $3 (a
# scratch path), one "count\tfile" line per nonzero file.
count_class() {
  # $1 = pattern (ERE)   $2 = grep extra flags (e.g. "-i" or "")   $3 = files-list-file
  # $4 = scratch out file for per-file breakdown
  pat=$1
  flags=$2
  fileslist=$3
  out=$4
  total=0
  : >"$out"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$(grep $flags -c -E "$pat" "$f" 2>/dev/null)
    n=${n:-0}
    if [ "$n" -gt 0 ]; then
      total=$((total + n))
      printf '%s\t%s\n' "$n" "$f" >>"$out"
    fi
  done <"$fileslist"
  echo "$total"
}

# Comment lines + 12-line-run blocks, computed together per file with awk (a
# single pass keeps this cheap over the whole corpus).
count_comment_and_blocks() {
  fileslist=$1
  clines_out=$2
  blocks_out=$3
  total_c=0
  total_b=0
  : >"$clines_out"
  : >"$blocks_out"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    res=$(awk '
      /^[ \t]*--/ { c++; run++; next }
      { if (run >= 12) blocks++; run = 0 }
      END { if (run >= 12) blocks++; printf "%d %d", c+0, blocks+0 }
    ' "$f")
    c=${res% *}
    b=${res#* }
    if [ "${c:-0}" -gt 0 ]; then
      total_c=$((total_c + c))
      printf '%s\t%s\n' "$c" "$f" >>"$clines_out"
    fi
    if [ "${b:-0}" -gt 0 ]; then
      total_b=$((total_b + b))
      printf '%s\t%s\n' "$b" "$f" >>"$blocks_out"
    fi
  done <"$fileslist"
  echo "$total_c $total_b"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

report_scope() {
  scope=$1
  list_files "$scope" >"$TMP/files.$scope"
  nfiles=$(wc -l <"$TMP/files.$scope" | tr -d ' ')
  ntotal=$(xargs cat <"$TMP/files.$scope" 2>/dev/null | wc -l | tr -d ' ')

  echo "== $scope ($nfiles files, $ntotal lines) =="

  cb=$(count_comment_and_blocks "$TMP/files.$scope" "$TMP/$scope.comment-lines" "$TMP/$scope.comment-blocks")
  echo "comment-lines: ${cb% *}"
  echo "comment-blocks(12+): ${cb#* }"

  t=$(count_class 'lib/[A-Za-z0-9_./]*\.ml[a-z]*' '' "$TMP/files.$scope" "$TMP/$scope.dead-path")
  fcount=$(wc -l <"$TMP/$scope.dead-path" | tr -d ' ')
  echo "dead-path(lib/*.ml): $t ($fcount files)"

  t=$(count_class 'was HERE and is RETIRED|do not re-add' '' "$TMP/files.$scope" "$TMP/$scope.tombstone")
  echo "tombstone: $t"

  t=$(count_class 'now lives in|moved to|now comes from' '' "$TMP/files.$scope" "$TMP/$scope.tombstone-sib")
  echo "tombstone-sib: $t"

  t=$(count_class '\brefuted\b|\bratified\b|\bwithdrawn\b|\bruling\b' '-i' "$TMP/files.$scope" "$TMP/$scope.ruling-vocab")
  echo "ruling-vocab(excl. MEASURED): $t"

  raw=0
  net=0
  : >"$TMP/$scope.history"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    res=$(awk '
      BEGIN { IGNORECASE = 0 }
      /Until 20|formerly|The old / {
        raw++
        line = $0
        low = tolower(line)
        if (low !~ /(is|are|was|be|been) used to/) net++
      }
      END { printf "%d %d", raw+0, net+0 }
    ' "$f")
    r=${res% *}
    n=${res#* }
    if [ "${r:-0}" -gt 0 ]; then
      raw=$((raw + r))
      net=$((net + n))
      printf '%s\t%s\n' "$n" "$f" >>"$TMP/$scope.history"
    fi
  done <"$TMP/files.$scope"
  echo "history(raw): $raw  (net after excluding instrumental \"used to\": $net)"

  t=$(count_class 'earlier cut|first cut|earlier revision|an earlier draft' '-i' "$TMP/files.$scope" "$TMP/$scope.draft-correct")
  echo "draft-correct: $t"

  t=$(count_class 'this pr' '-i' "$TMP/files.$scope" "$TMP/$scope.this-pr-raw")
  echo "this-pr-raw(naive substring): $t"

  t=$(count_class '\bthis PR\b' '' "$TMP/files.$scope" "$TMP/$scope.this-pr-tight")
  echo "this-pr-tight(literal, case-sensitive): $t"

  t=$(count_class '🚨|⚠️|🔒' '' "$TMP/files.$scope" "$TMP/$scope.emoji")
  echo "emoji-shout: $t"

  echo "-- per-file breakdown (nonzero, sorted) --"
  for cls in dead-path tombstone tombstone-sib ruling-vocab history draft-correct this-pr-tight emoji comment-blocks; do
    f="$TMP/$scope.$cls"
    if [ -s "$f" ]; then
      echo "  [$cls]"
      sort -t"$(printf '\t')" -k2 "$f" | while IFS="$(printf '\t')" read -r n path; do
        echo "    $n  $path"
      done
    fi
  done
  echo
}

case "$SCOPE_ARG" in
  compiler) report_scope compiler ;;
  stdlib) report_scope stdlib ;;
  both) report_scope compiler; report_scope stdlib ;;
  *) echo "usage: $0 [compiler|stdlib|both]" >&2; exit 1 ;;
esac

echo "NOTE: classes OVERLAP — a single line can land in more than one class"
echo "(e.g. an emoji-shout line inside an essay-length comment-block run)."
echo "This is a set of line classifications, not a count of disjoint defects."

exit 0
