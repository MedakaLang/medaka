#!/bin/sh
# test/comment_register_census.sh — derived comment-register census. Not a
# gate: this is a reporting tool, run via `make comment-census`. It asserts
# nothing; exits 0 on a healthy run, and refuses (exit 1) only if the file
# corpus comes back empty — see below.
#
# WHY THIS EXISTS (#2281, leg 3 P of crusade #2276): source comments in this
# tree drift into several registers that read fine the day they're written
# and mislead every day after — history narration ("Until 2026-…", "formerly")
# that stops being useful the moment it's stale, reviewer-addressed ruling
# vocabulary ("refuted", "ratified") that belongs on the PR/issue not in the
# source, tombstones for code that no longer exists, emoji shouts, draft
# self-narration ("earlier cut"), and deictic references ("this PR") that
# don't survive the PR merging. #2281's own issue body carried hand-typed
# survey numbers that were already stale in both directions by the time this
# script was written — exactly the kind of encoded fact this project's own
# conventions warn against ([T-STDLIB-IMPORT], the doc-link/doc-symbol rot
# gates, docs/README.md's own generation, and this script's own sibling
# test/fmt_clean_census.sh for #1794). This script derives the counts
# instead, the same way those do: run it, read the answer, never hand-type it.
#
# IMPORTANT: these are LINE CLASSIFICATIONS, NOT DISJOINT DEFECT COUNTS — a
# single comment line can match more than one class (e.g. an emoji-shout line
# that is also reviewer-addressed ruling prose). Do not sum the per-class
# counts and expect the total distinct flagged-line count; the summary
# reports both the per-class counts and the distinct-line total separately.
#
# SCOPE: every git-tracked `*.mdk` file under compiler/ and stdlib/. This
# script matches whole source lines with regex, not a `#`-comment extractor
# — it does not parse Medaka syntax, so a hit can land inside a string
# literal or a diagnostic-message text rather than an actual `#` comment.
# Acceptable for an on-demand census, not for a gate (this is deliberately
# not one) — a human still reads the per-file breakdown before acting on it.
#
# WHY ON-DEMAND, NOT A CI GATE: same rationale as test/fmt_clean_census.sh —
# gating this tree-wide would surface whatever unrelated pre-existing
# comment-register debt already lives in the tree as a sudden required-check
# failure, unconnected to whatever PR happens to trip it. This is a
# developer/agent convenience, not a merge gate.
#
# Needs no built ./medaka — pure text/regex over tracked source files.
# Portable POSIX sh (grep -E, no bash-only features).
#
# Usage:  sh test/comment_register_census.sh
# Output: per-file breakdown, then a per-class summary table. Exits 0 on a
#         healthy run; refuses (exit 1) only if the file corpus comes back
#         empty, which would otherwise misreport as a clean zero.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

IFS='
'
files="$(git -C "$ROOT" ls-files -- 'compiler/*.mdk' 'stdlib/*.mdk')"

if [ -z "$files" ]; then
  echo "comment_register_census: matched ZERO .mdk files under compiler/ or stdlib/ — harness bug, refusing to report" >&2
  exit 1
fi

# Regex per class, numbered per #2281's seven-class list. Applied per-line
# with grep -E, over the whole tracked file (not restricted to text after
# '#' — acceptable at census precision, see header).
#
#  1 history narration — excludes the instrumental "used to" sense
#     ("is/are/was/be/been used to") — a real false-positive shape naive
#     "used to" matching hits; see #2281's adversarial review for measured
#     rates, not asserted here.
re_history='Until 2026-|formerly|The old |withdrawn|used to'
re_history_exclude='(is|are|was|be|been) used to'
#  2 reviewer-addressed ruling vocabulary — MEASURED is provenance this repo
#     wants, tracked as its own separate metric below, never folded in here.
re_ruling='refuted|ratified|withdrawn|"ruling"'
#  3 tombstones — "was HERE and is RETIRED", "do not re-add", and the
#     sibling relocation form (the naive regex undercounts meaningfully
#     without it; see #2281's adversarial review for measured rates, not
#     asserted here).
re_tombstone='was HERE and is RETIRED|do not re-add|now lives in|moved to|now comes from'
#  4 emoji shouts.
re_emoji='🚨|⚠️|🔒'
#  5 draft narration — self-correction phrasing. Also the candidate list for
#     class 7 (see below): not independently greppable.
re_draft='earlier cut|first cut|earlier revision'
#  6 dead deictic citations.
re_deictic='this PR'
#  MEASURED — provenance marker, own metric, NOT one of the seven classes
#     and not folded into class 2 (ruling vocabulary).
re_measured='MEASURED'
#  8 dead-path — a comment citing a repo-relative lib/*.ml* path (the OCaml
#     reference compiler removed 2026-06-26, `oracle-frozen`). Matches
#     .ml/.mli/.mll/.mly.
re_deadpath='lib/[A-Za-z0-9_./]*\.ml[a-z]*'

n_files=0
sum_history=0
sum_ruling=0
sum_tombstone=0
sum_emoji=0
sum_draft=0
sum_deictic=0
sum_measured=0
sum_deadpath=0
sum_commentblocks=0
sum_distinct=0

per_file_report=""

for f in $files; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  n_files=$((n_files + 1))

  c_history=$(grep -E "$re_history" "$f" 2>/dev/null | grep -Evc "$re_history_exclude")
  c_ruling=$(grep -Ec "$re_ruling" "$f" 2>/dev/null)
  c_tombstone=$(grep -Ec "$re_tombstone" "$f" 2>/dev/null)
  c_emoji=$(grep -Ec "$re_emoji" "$f" 2>/dev/null)
  c_draft=$(grep -Ec "$re_draft" "$f" 2>/dev/null)
  c_deictic=$(grep -Ec "$re_deictic" "$f" 2>/dev/null)
  c_measured=$(grep -Ec "$re_measured" "$f" 2>/dev/null)
  c_deadpath=$(grep -Ec "$re_deadpath" "$f" 2>/dev/null)

  # comment-blocks: count RUNS of >=12 consecutive `--`-only comment lines
  # (a run is counted once, when it first reaches 12, not once per line
  # thereafter).
  c_commentblocks=$(awk '
    /^[ \t]*--/ { run++; if (run == 12) blocks++; next }
    { run = 0 }
    END { print blocks + 0 }
  ' "$f" 2>/dev/null)

  # Distinct lines matching >=1 of the seven classes (excluding the history
  # false-positive shape). MEASURED is excluded from this total — it is not
  # one of the seven classes.
  c_distinct=$(grep -E "$re_history|$re_ruling|$re_tombstone|$re_emoji|$re_draft|$re_deictic" "$f" 2>/dev/null | grep -Evc "$re_history_exclude")

  sum_history=$((sum_history + c_history))
  sum_ruling=$((sum_ruling + c_ruling))
  sum_tombstone=$((sum_tombstone + c_tombstone))
  sum_emoji=$((sum_emoji + c_emoji))
  sum_draft=$((sum_draft + c_draft))
  sum_deictic=$((sum_deictic + c_deictic))
  sum_measured=$((sum_measured + c_measured))
  sum_deadpath=$((sum_deadpath + c_deadpath))
  sum_commentblocks=$((sum_commentblocks + c_commentblocks))
  sum_distinct=$((sum_distinct + c_distinct))

  f_total=$((c_history + c_ruling + c_tombstone + c_emoji + c_draft + c_deictic + c_measured + c_deadpath + c_commentblocks))
  if [ "$f_total" -gt 0 ]; then
    per_file_report="$per_file_report$f: history=$c_history ruling=$c_ruling tombstone=$c_tombstone emoji=$c_emoji draft=$c_draft deictic=$c_deictic measured=$c_measured dead-path=$c_deadpath comment-blocks=$c_commentblocks
"
  fi
done

echo "comment_register_census: $n_files tracked .mdk files under compiler/ and stdlib/"
echo
echo "NOTE: these are line CLASSIFICATIONS, not disjoint defect counts — a"
echo "single line can match more than one class (draft/emoji/ruling prose"
echo "frequently overlaps; classes overlapping is expected — see #2281 for"
echo "measured percentages, which are about WHERE emoji lines sit (inside"
echo "essay files), not about class-overlap). Per-class sums do NOT add up"
echo "to the distinct-line total below; both are reported."
echo
echo "-- per-file breakdown (files with at least one hit) --"
if [ -n "$per_file_report" ]; then
  printf '%s' "$per_file_report"
else
  echo "  (none)"
fi
echo
echo "-- per-class summary (the seven classes from #2281) --"
echo "  1. history narration:               $sum_history"
echo "  2. reviewer-addressed ruling vocab:  $sum_ruling"
echo "  3. tombstones (incl. relocation):    $sum_tombstone"
echo "  4. emoji shouts (🚨/⚠️/🔒):           $sum_emoji"
echo "  5. draft narration:                  $sum_draft"
echo "  6. dead deictic citations:           $sum_deictic"
echo "  7. falsified-by-refactor candidates: see class 5 above (not"
echo "     independently greppable — its hits ARE the candidate list,"
echo "     requiring human judgment; not a definitive falsified-count)"
echo "  8. dead-path lib/*.ml citations:     $sum_deadpath"
echo "  9. comment-block essays (12+ lines): $sum_commentblocks"
echo
echo "  distinct lines matching >=1 of the seven classes: $sum_distinct"
echo
echo "-- tracked separately, NOT one of the seven classes --"
echo "  MEASURED provenance markers:        $sum_measured"
echo "  (provenance this repo wants, not litigation — see class 2's note)"

exit 0
