#!/bin/sh
# test/comment_register_census.sh — derived comment-register census, plus the
# baseline ratchet built on the same scanner. The DEFAULT (no-flag) mode is a
# reporting tool, run via `make comment-census`: it asserts nothing, exits 0 on
# a healthy run, and refuses (exit 1) only if the file corpus comes back empty
# — see below. The `--write`/`--check` modes are the GATED path: `--check` is a
# verdict (exit 1 on a baselined count that rose), consumed by
# .githooks/pre-commit check 6b and by test/diff_compiler_comment_shout_diff.sh,
# which is a merge-tier gate.
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
# reports both the per-class counts (ten of them) and the distinct-line
# total separately.
#
# SCOPE: every git-tracked `*.mdk` file under compiler/ and stdlib/. This
# script matches whole source lines with regex, not a `#`-comment extractor
# — it does not parse Medaka syntax, so a hit can land inside a string
# literal or a diagnostic-message text rather than an actual `#` comment.
# Acceptable for the on-demand census — a human still reads the per-file
# breakdown before acting on it — but too loose to carry a verdict, which is
# why --write/--check narrow to comment-scope lines instead (see below).
#
# WHY THE REPORT ITSELF IS ON-DEMAND: same rationale as
# test/fmt_clean_census.sh — asserting a clean tree-wide count would surface
# whatever unrelated pre-existing comment-register debt already lives in the
# tree as a sudden required-check failure, unconnected to whatever PR happens
# to trip it. The --check ratchet is what makes the register gateable anyway:
# it pins today's debt per (file, class) and only ever lets a count fall, so a
# PR fails on the debt it ADDS and never on the debt it inherited.
#
# Needs no built ./medaka — pure text/regex over tracked source files.
# Portable POSIX sh (grep -E, no bash-only features).
#
# Usage:  sh test/comment_register_census.sh
#         sh test/comment_register_census.sh --write <path>
#         sh test/comment_register_census.sh --check <baseline> [<file> ...]
#         sh test/comment_register_census.sh --comment-scope <file>|-
#
# Default (no args): per-file breakdown, then a per-class summary table.
# Exits 0 on a healthy run; refuses (exit 1) only if the file corpus comes
# back empty, which would otherwise misreport as a clean zero. Unchanged by
# the modes below (#3034).
#
# The default report reads WHOLE files; --write and --check read only the
# comment-scope lines of each file (comment_scope_lines below). A baselined
# count is therefore not the same number the summary table prints for the
# same class, and can only ever be lower: a gated count must not move on an
# ALL-CAPS string literal or an identifier, which is what the summary's own
# SCOPE note above says it cannot tell apart.
#
# --write <path>: regenerate the per-(file,class) count baseline (one
# [[entry]] per file/class with a nonzero count) to <path>, over the 8
# baselined classes only (1/2/3/4/5/6/8/10 — see test/comment_register_baseline.toml's
# own header for which two classes are excluded and why). Sanctioned way to
# move a baselined count; never hand-edit the generated file.
#
# --check <baseline> [<file> ...]: the ratchet — for each of the 8 baselined
# classes, over the given files (default: every tracked compiler/*.mdk and
# stdlib/*.mdk file, i.e. the same corpus the default mode scans), fail if
# the CURRENT count exceeds the count pinned for that (file, class) in
# <baseline> (a missing row reads as 0, so a brand-new nonzero count fails
# closed). A count that fell is fine. Prints the regen command on failure.
# Used by .githooks/pre-commit (per staged file, cheap) and by
# test/diff_compiler_comment_shout_diff.sh (whole tree, so --no-verify
# cannot smuggle a rise past the hook).
#
# --comment-scope <file>|-: print the comment-scope lines of <file> (or of
# stdin, for `-`) and exit. Exposed so .githooks/pre-commit and
# test/diff_compiler_comment_shout_diff.sh can scope an added line the same
# way the baseline does without a second copy of the scanner.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

IFS='
'
files="$(git -C "$ROOT" ls-files -- 'compiler/*.mdk' 'stdlib/*.mdk' 'pds/*.mdk')"

if [ -z "$files" ]; then
  echo "comment_register_census: matched ZERO .mdk files under compiler/, stdlib/ or pds/ — harness bug, refusing to report" >&2
  exit 1
fi

# Regex per class, numbered per #2281's original seven-class list plus the
# two classes (8, 9: dead-path and comment-blocks) F-census-merge added,
# plus class 10 (shout register, sigil-free, #2766) — ten classes below.
# Class 10 is numbered out of sequence, after 4, because it reads paired
# with class 4 in the summary rather than standing alone. Applied per-line
# with grep -E, over the whole tracked
# file (not restricted to text after '#' — acceptable at census precision,
# see header).
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
#  10 shout register, sigil-free — a line carrying the SAME ALL-CAPS shout
#     prose as class 4 but with no 🚨/⚠️/🔒 marker (#2766: a sigil strip that
#     keeps the shout sentence intact must not read as a drain). Matches a
#     run of 3+ consecutive space-separated ALL-CAPS words (each 2+ letters,
#     optional single trailing punctuation), which is how every surviving
#     sigil-stripped shout line in the tree reads. Deliberately excludes
#     mixed-case identifiers (`EMethodAt`, `LTFloat`) and underscore-joined
#     single tokens (`MEDAKA_STRICT`), so it does not fire on constructor
#     names or env-var names; it can still land inside a string literal or
#     CLI help/error text, same scope tradeoff as every other class here.
#     Read together with class 4 in the summary below, never independently.
re_shout='([A-Z][A-Z]+[,.:;)]? ){2,}[A-Z][A-Z]+'
#  5 draft narration — self-correction phrasing. Also the candidate list for
#     class 7 (see below): not independently greppable.
re_draft='earlier cut|first cut|earlier revision'
#  6 dead deictic citations.
re_deictic='this PR'
#  MEASURED — provenance marker, own metric, NOT one of the ten classes
#     and not folded into class 2 (ruling vocabulary).
re_measured='MEASURED'
#  8 dead-path — a comment citing a repo-relative lib/*.ml* path (the OCaml
#     reference compiler removed 2026-06-26, `oracle-frozen`). Matches
#     .ml/.mli/.mll/.mly.
re_deadpath='lib/[A-Za-z0-9_./]*\.ml[a-z]*'

# The 8 BASELINED classes (#3034) — per-LINE-count classes
# only; class 9 (comment-block essays) counts RUNS, a different mechanism,
# and class 7 has no independent regex (it IS class 5's hit list). Fixed
# order, shared by --write and --check so both walk the same sequence.
# Newline-separated, matching the file-global IFS set above (a space-joined
# list would not split under it).
baselined_classes="history
ruling
tombstone
emoji
draft
deictic
dead-path
shout"

# Emits the COMMENT-SCOPE lines of file $1 ("-" for stdin): a `--` line
# comment, or a line inside a (possibly nested) `{- ... -}` block comment,
# the opening and closing lines included. Blank lines are dropped — they
# carry no class, and an empty line is a `grep -Fx` pattern that matches
# every line, which would silently widen the consumers that test an added
# line for membership in this set.
#
# Approximate, at the same precision as the class regexes: this does not
# parse Medaka syntax, so a `{-` or `-}` inside a string literal opens or
# closes a block that the lexer never sees, and the over-inclusion runs to
# the end of the file. A `--` outside a block ends the line's delimiter
# scan, which is the one refinement the tree cannot do without: line
# comments that merely MENTION `{-` outnumber real block openers, and
# without it a single such mention swallows every following line.
comment_scope_lines() {
  awk '
    {
      entry_depth = depth
      n = length($0)
      touched = 0
      for (i = 1; i < n; i++) {
        two = substr($0, i, 2)
        if (two == "{-") { depth++; touched = 1; i++ }
        else if (two == "-}") { if (depth > 0) depth--; touched = 1; i++ }
        else if (two == "--" && depth == 0) { break }
      }
      if ($0 ~ /^[ \t]*$/) next
      if (entry_depth > 0 || touched || $0 ~ /^[ \t]*--/) print
    }
  ' "$1"
}

if [ "${1:-}" = "--comment-scope" ]; then
  src="${2:--}"
  [ "$src" = "-" ] || [ -f "$src" ] || { echo "comment_register_census: no such file: $src" >&2; exit 2; }
  comment_scope_lines "$src"
  exit 0
fi

# Sets $bc_<slug> for every slug in $baselined_classes, for file $1. Shares
# the class regexes above with the default summary loop below rather than
# redefining them, but — unlike that loop — reads only the file's
# comment-scope lines, so a gated count cannot move on a code line.
compute_baselined_counts() {
  bc_file="$1"
  bc_scope="$(comment_scope_lines "$bc_file")"
  bc_history=$(printf '%s\n' "$bc_scope" | grep -E "$re_history" | grep -Evc "$re_history_exclude")
  bc_ruling=$(printf '%s\n' "$bc_scope" | grep -Ec "$re_ruling")
  bc_tombstone=$(printf '%s\n' "$bc_scope" | grep -Ec "$re_tombstone")
  bc_emoji=$(printf '%s\n' "$bc_scope" | grep -Ec "$re_emoji")
  bc_draft=$(printf '%s\n' "$bc_scope" | grep -Ec "$re_draft")
  bc_deictic=$(printf '%s\n' "$bc_scope" | grep -Ec "$re_deictic")
  bc_dead_path=$(printf '%s\n' "$bc_scope" | grep -Ec "$re_deadpath")
  bc_shout=$(printf '%s\n' "$bc_scope" | grep -Ec "$re_shout")
}

# Reads $bc_<slug> (as set by compute_baselined_counts) for the given class
# slug ($1), printing the count. Indirection because POSIX sh has no arrays.
baselined_count_for() {
  case "$1" in
    history) printf '%s' "$bc_history" ;;
    ruling) printf '%s' "$bc_ruling" ;;
    tombstone) printf '%s' "$bc_tombstone" ;;
    emoji) printf '%s' "$bc_emoji" ;;
    draft) printf '%s' "$bc_draft" ;;
    deictic) printf '%s' "$bc_deictic" ;;
    dead-path) printf '%s' "$bc_dead_path" ;;
    shout) printf '%s' "$bc_shout" ;;
  esac
}

if [ "${1:-}" = "--write" ]; then
  outpath="${2:-}"
  [ -n "$outpath" ] || { echo "comment_register_census: --write needs a <path>" >&2; exit 2; }
  {
    echo "# comment-register count baseline — GENERATED, never hand-edited (#3034)."
    echo "#"
    echo "# One [[entry]] per (file, class) with a nonzero count, over the 8"
    echo "# per-LINE-count comment-register classes test/comment_register_census.sh"
    echo "# computes: history, ruling, tombstone, emoji, draft, deictic, dead-path,"
    echo "# shout. A file may drop below its count freely; exceeding it is an"
    echo "# error, and so is having a nonzero count for a class with no row here"
    echo "# at all."
    echo "#"
    echo "# OUT OF SCOPE (not baselined here): class 9 (comment-block essays) counts"
    echo "# RUNS of consecutive comment lines, not individual lines — a different"
    echo "# counting mechanism from every class above; class 7 (falsified-by-"
    echo "# refactor candidates) is not independently greppable — its hits ARE"
    echo "# class 5's (draft narration) hit list, needing human judgment, not a"
    echo "# regex count."
    echo "#"
    echo "# Enforced by .githooks/pre-commit check 6b (per staged file) and by"
    echo "# test/diff_compiler_comment_shout_diff.sh (whole tree, so --no-verify"
    echo "# cannot smuggle a rise past the hook)."
    echo "#"
    echo "# Regenerate from the repo root, never by hand:"
    echo "#"
    echo "#   sh test/comment_register_census.sh --write test/comment_register_baseline.toml"
    echo "#"
    echo "# Paths are relative to the repo root, matching every consumer above."
    for f in $files; do
      [ -f "$f" ] || continue
      compute_baselined_counts "$f"
      for cls in $baselined_classes; do
        n="$(baselined_count_for "$cls")"
        if [ "$n" -gt 0 ]; then
          echo ""
          echo "[[entry]]"
          echo "file = \"$f\""
          echo "class = \"$cls\""
          echo "count = $n"
        fi
      done
    done
  } >"$outpath"
  exit 0
fi

if [ "${1:-}" = "--check" ]; then
  shift
  baseline="${1:-}"
  [ -n "$baseline" ] || { echo "comment_register_census: --check needs a <baseline> path" >&2; exit 2; }
  [ -f "$baseline" ] || { echo "FAIL: missing baseline $baseline" >&2; exit 1; }
  shift
  if [ "$#" -gt 0 ]; then
    targets=""
    for f in "$@"; do
      case "$f" in
        compiler/*.mdk | stdlib/*.mdk | pds/*.mdk)
          if [ -z "$targets" ]; then
            targets="$f"
          else
            targets="$targets
$f"
          fi
          ;;
      esac
    done
  else
    targets="$files"
  fi

  # Parse the baseline's [[entry]] blocks into file\tclass\tcount rows —
  # awk, not the shell, so a hand-edited or malformed row still parses
  # deterministically rather than however field-splitting happens to fall.
  parsed="$(mktemp)"
  awk '
    /^\[\[entry\]\]/ { if (f != "") print f "\t" c "\t" n; f = ""; c = ""; n = ""; next }
    /^file[ \t]*=/ { s = $0; sub(/^file[ \t]*=[ \t]*"/, "", s); sub(/"[ \t]*$/, "", s); f = s; next }
    /^class[ \t]*=/ { s = $0; sub(/^class[ \t]*=[ \t]*"/, "", s); sub(/"[ \t]*$/, "", s); c = s; next }
    /^count[ \t]*=/ { s = $0; sub(/^count[ \t]*=[ \t]*/, "", s); n = s; next }
    END { if (f != "") print f "\t" c "\t" n }
  ' "$baseline" >"$parsed"

  fail=0
  for f in $targets; do
    [ -f "$f" ] || continue
    compute_baselined_counts "$f"
    for cls in $baselined_classes; do
      cur="$(baselined_count_for "$cls")"
      base="$(awk -F'\t' -v f="$f" -v c="$cls" '$1 == f && $2 == c { print $3 }' "$parsed")"
      [ -n "$base" ] || base=0
      if [ "$cur" -gt "$base" ]; then
        fail=1
        echo "FAIL: $f: class '$cls' count rose to $cur (baseline: $base)"
      fi
    done
  done
  rm -f "$parsed"

  if [ "$fail" -ne 0 ]; then
    echo ""
    echo "  A baselined comment-register class's per-file count may only FALL."
    echo "  Regenerate the baseline after fixing (or deliberately re-pinning):"
    echo "    sh test/comment_register_census.sh --write test/comment_register_baseline.toml"
    exit 1
  fi
  echo "-- comment register baseline: ok"
  exit 0
fi

n_files=0
sum_history=0
sum_ruling=0
sum_tombstone=0
sum_emoji=0
sum_shout=0
sum_emoji_or_shout=0
sum_draft=0
sum_deictic=0
sum_measured=0
sum_deadpath=0
sum_deadpath_compiler=0
sum_deadpath_stdlib=0
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
  c_shout=$(grep -Ec "$re_shout" "$f" 2>/dev/null)
  c_emoji_or_shout=$(grep -Ec "$re_emoji|$re_shout" "$f" 2>/dev/null)
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

  case "$f" in
    compiler/*) sum_deadpath_compiler=$((sum_deadpath_compiler + c_deadpath)) ;;
    stdlib/*) sum_deadpath_stdlib=$((sum_deadpath_stdlib + c_deadpath)) ;;
  esac

  # Distinct lines matching >=1 of the ten classes (excluding the history
  # false-positive shape). MEASURED is excluded from this total — it is not
  # one of the ten classes. Eight of the ten (history/ruling/tombstone/
  # emoji/shout/draft/deictic/dead-path) are single-line regex matches,
  # unioned directly with grep -E. comment-blocks is a DIFFERENT counting
  # mechanism (a run of 12+ consecutive lines, not a single-line regex), so
  # it can't join that alternation — instead, every line belonging to a run
  # that reached the 12-line threshold is emitted by line number and unioned
  # in via `sort -u`, so a comment-blocks-only line still counts once toward
  # the distinct total without being double-counted against a line that also
  # matched one of the other nine classes.
  c_class_lines=$(grep -nE "$re_history|$re_ruling|$re_tombstone|$re_emoji|$re_shout|$re_draft|$re_deictic|$re_deadpath" "$f" 2>/dev/null | grep -Ev "$re_history_exclude" | cut -d: -f1)
  c_block_lines=$(awk '
    /^[ \t]*--/ { run++; buf[run] = NR; next }
    {
      if (run >= 12) { for (i = 1; i <= run; i++) print buf[i] }
      run = 0
    }
    END {
      if (run >= 12) { for (i = 1; i <= run; i++) print buf[i] }
    }
  ' "$f" 2>/dev/null)
  c_distinct=$(printf '%s\n%s\n' "$c_class_lines" "$c_block_lines" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')

  sum_history=$((sum_history + c_history))
  sum_ruling=$((sum_ruling + c_ruling))
  sum_tombstone=$((sum_tombstone + c_tombstone))
  sum_emoji=$((sum_emoji + c_emoji))
  sum_shout=$((sum_shout + c_shout))
  sum_emoji_or_shout=$((sum_emoji_or_shout + c_emoji_or_shout))
  sum_draft=$((sum_draft + c_draft))
  sum_deictic=$((sum_deictic + c_deictic))
  sum_measured=$((sum_measured + c_measured))
  sum_deadpath=$((sum_deadpath + c_deadpath))
  sum_commentblocks=$((sum_commentblocks + c_commentblocks))
  sum_distinct=$((sum_distinct + c_distinct))

  f_total=$((c_history + c_ruling + c_tombstone + c_emoji + c_shout + c_draft + c_deictic + c_measured + c_deadpath + c_commentblocks))
  if [ "$f_total" -gt 0 ]; then
    per_file_report="$per_file_report$f: history=$c_history ruling=$c_ruling tombstone=$c_tombstone emoji=$c_emoji shout=$c_shout draft=$c_draft deictic=$c_deictic measured=$c_measured dead-path=$c_deadpath comment-blocks=$c_commentblocks
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
echo "-- per-class summary (ten classes) --"
echo "  1. history narration:               $sum_history"
echo "  2. reviewer-addressed ruling vocab:  $sum_ruling"
echo "  3. tombstones (incl. relocation):    $sum_tombstone"
echo "  4. emoji shouts (🚨/⚠️/🔒):           $sum_emoji"
echo " 10. shout register, sigil-free:       $sum_shout"
echo "     4+10 combined (a sigil strip alone must not move this):  $sum_emoji_or_shout"
echo "  5. draft narration:                  $sum_draft"
echo "  6. dead deictic citations:           $sum_deictic"
echo "  7. falsified-by-refactor candidates: see class 5 above (not"
echo "     independently greppable — its hits ARE the candidate list,"
echo "     requiring human judgment; not a definitive falsified-count)"
echo "  8. dead-path lib/*.ml citations:     $sum_deadpath (compiler/: $sum_deadpath_compiler, stdlib/: $sum_deadpath_stdlib)"
echo "  9. comment-block essays (12+ lines): $sum_commentblocks"
echo
echo "  distinct lines matching >=1 of the ten classes: $sum_distinct"
echo
echo "-- tracked separately, NOT one of the ten classes --"
echo "  MEASURED provenance markers:        $sum_measured"
echo "  (provenance this repo wants, not litigation — see class 2's note)"

exit 0
