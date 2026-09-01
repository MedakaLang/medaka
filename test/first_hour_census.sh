#!/bin/sh
# first_hour_census.sh — MUTATION CENSUS over the docs guide corpus.
# #2446 (tracking), amends #2302 (Anti-slop 8: diagnostic rubric-conformance
# census ranked by first-hour reachability), contributes to #2304.
#
# `test/diag_census.sh` re-derives conformance facts from the fixtures that
# ALREADY exist under test/error_quality_fixtures/ — hand-authored, one
# defect each. This script asks a different question: of the examples a
# total beginner sees in the FIRST HOUR (the guide itself, docs/guide/*.md,
# plus docs/spec/SYNTAX.md), which small "I typo'd this" mistake surfaces
# which diagnostic how often? It is `test/diag_census.sh`'s SIBLING, not a
# rewrite: same "always exits 0, census not gate" convention, same
# fixed-width-table shape, different corpus and a MUTATION step in between.
#
# ── extraction (reused, not duplicated) ─────────────────────────────────────
# Every checkable ```medaka / ```medaka-project example is extracted by
# test/check_syntax_examples.sh ITSELF, via its SYNTAX_EXTRACT_DIR seam (see
# that script's header) — this script does not parse a single fence; it lets
# check_syntax_examples.sh's own fence state machine do that (as it must:
# duplicating parse_fence_opener/is_matching_fence_closer/flush_pending in a
# second file was explicitly out of scope, F9).
#
# ── mutation (a small fixed set — F9's ~3-5 kinds/fence budget) ─────────────
#   drop-paren   remove the LAST `)` (or, if none, `}`) on the first line
#                that has one
#   drop-import  remove the first `import ...` line — medaka-project only
#   drop-arm     remove the first match-arm line (first non-blank char `|`)
#   typo-ident   drop the last character of the first bare identifier
#   dedent       remove one 2-space indent level from the first indented
#                body line after line 1
# A mutation kind that does not apply to a given example (e.g. no `)`/`}`,
# no `import`, no `|`-arm) is SKIPPED for that example, not forced — the
# resulting mutant count is corpus-dependent, not a fixed N per example.
#
# ── ranking ──────────────────────────────────────────────────────────────
# Every mutant is run through `./medaka check --json`. A mutant whose fired
# diagnostic code is `P-PARSE` (the parseErrCode catch-all — 60 `failP` sites
# collapse to this one code, F8) is bucketed by its MESSAGE TEXT (first 40
# characters) instead of by code, exactly as the packet licenses; every other
# mutant is bucketed by `code`. A mutant that type-checks clean (no
# diagnostic, exit 0) is its own bucket, `SILENT-ACCEPT` — that is itself a
# first-hour-reachability finding (a beginner mistake the compiler didn't
# notice), not a script defect.
#
# ── IT ASSERTS NOTHING. IT IS A CENSUS, NOT A GATE. ─────────────────────────
# Always exits 0 (barring a missing binary or manifest, exit 2/0 — see
# below), same convention as test/diag_census.sh. Listed in
# test/CI-COVERAGE-TOOLS.txt as a census; NOT in test/gates.toml.
#
# Usage: sh test/first_hour_census.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/medaka"
TIMEOUT=60

[ -x "$BIN" ] || { echo "build first: make medaka (missing $BIN)"; exit 2; }

WORK="$(mktemp -d)" || { echo "first_hour_census: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT INT TERM

EXTRACT_DIR="$WORK/extract"
mkdir -p "$EXTRACT_DIR"

run_timed() {
  perl -e 'alarm shift; exec @ARGV or exit 127' "$TIMEOUT" "$@"
}

# ── step 1: extraction, delegated entirely to check_syntax_examples.sh ─────
echo "first_hour_census: extracting via test/check_syntax_examples.sh ..."
SYNTAX_EXTRACT_DIR="$EXTRACT_DIR" sh "$ROOT/test/check_syntax_examples.sh" > "$WORK/extract.log" 2>&1
extract_rc=$?
if [ "$extract_rc" -ne 0 ]; then
  echo "first_hour_census: NOTE check_syntax_examples.sh exited $extract_rc during extraction" \
       "(continuing with whatever it extracted — see $WORK/extract.log while this run lasts)"
fi
MANIFEST="$EXTRACT_DIR/manifest.tsv"
if [ ! -f "$MANIFEST" ]; then
  echo "first_hour_census: no manifest produced — nothing extracted, nothing to mutate"
  exit 0
fi

# ── mutation helpers ─────────────────────────────────────────────────────--
# Each returns via files, not stdout: writes $dest, and the caller decides
# applicability by diffing $src vs $dest (unchanged == not applicable).

try_drop_char() {
  # $1=src $2=dest $3=char — removes the LAST occurrence of $3 on the FIRST
  # line that contains it, restricted to the CODE portion of the line (before
  # a ` --` comment marker, if any) — a stray `)` inside a trailing comment
  # (`-- triple-quoted String (may span lines)` genuinely occurs in
  # SYNTAX.md) is not a beginner mistake in the code, and mutating it there
  # produced a false SILENT-ACCEPT on this script's first run: dropping
  # comment punctuation changes nothing the parser sees.
  awk -v ch="$3" '
    BEGIN { done = 0 }
    done == 0 {
      trimmed = $0
      sub(/^[ \t]+/, "", trimmed)
      cend = length($0)
      if (trimmed ~ /^--/) cend = 0
      else if (match($0, / --/)) cend = RSTART - 1
      code = substr($0, 1, cend)
      if (index(code, ch) > 0) {
        pos = 0
        for (i = 1; i <= length(code); i++) if (substr(code, i, 1) == ch) pos = i
        $0 = substr($0, 1, pos - 1) substr($0, pos + 1)
        done = 1
      }
    }
    { print }
  ' "$1" > "$2"
}

mutate() {
  # $1=mutation kind $2=src file $3=dest file
  # NOTE: POSIX sh functions have no local scope — deliberately named
  # mut_kind/mut_src/mut_dest here, NOT kind/src/dest, because the caller
  # (the manifest-reading `while read` loop below) already owns globals
  # named kind/dest for its own row fields; reusing those names here
  # silently clobbered the caller's loop state (found live: it made
  # `cmp -s "$dest" "$mut"` always compare a file to itself, so this script
  # counted 0 mutants on first run).
  mut_kind="$1"; mut_src="$2"; mut_dest="$3"
  case "$mut_kind" in
    drop-paren)
      try_drop_char "$mut_src" "$mut_dest" ')'
      if cmp -s "$mut_src" "$mut_dest"; then try_drop_char "$mut_src" "$mut_dest" '}'; fi
      ;;
    drop-import)
      awk 'done==0 && /^import / { done=1; next } { print }' "$mut_src" > "$mut_dest"
      ;;
    drop-arm)
      awk 'done==0 && /^[ \t]*\|/ { done=1; next } { print }' "$mut_src" > "$mut_dest"
      ;;
    typo-ident)
      # Restricted to the code portion of the line (before ` --`), same
      # reasoning as try_drop_char above — an identifier-looking word inside
      # a comment is not a beginner code mistake.
      awk '
        done == 0 {
          trimmed = $0
          sub(/^[ \t]+/, "", trimmed)
          cend = length($0)
          if (trimmed ~ /^--/) cend = 0
          else if (match($0, / --/)) cend = RSTART - 1
          code = substr($0, 1, cend)
          if (match(code, /[A-Za-z_][A-Za-z0-9_]*/)) {
            w = substr(code, RSTART, RLENGTH)
            if (length(w) > 1) {
              $0 = substr($0, 1, RSTART - 1) substr(w, 1, length(w) - 1) substr($0, RSTART + RLENGTH)
              done = 1
            }
          }
        }
        { print }
      ' "$mut_src" > "$mut_dest"
      ;;
    dedent)
      awk 'NR==1 { print; next } done==0 && /^  / { sub(/^  /, ""); done=1 } { print }' "$mut_src" > "$mut_dest"
      ;;
  esac
}

MUTATION_KINDS="drop-paren drop-import drop-arm typo-ident dedent"

BUCKETS="$WORK/buckets.tsv"     # kind<TAB>bucket<TAB>fixture
: > "$BUCKETS"
mutant_count=0
crashed_count=0

# ── classify one mutant: run --json, decide bucket ──────────────────────--
classify_mutant() {
  # $1 = mutant file, $2 = kind, $3 = fixture label (for the report)
  mfile="$1"; mkind="$2"; mlabel="$3"
  json="$(cd "$ROOT" && run_timed "$BIN" check --json "$mfile" 2>&1)"
  mrc=$?
  code="$(printf '%s' "$json" | grep -oE '"code":"[^"]*"' | head -n1 | sed -E 's/"code":"([^"]*)"/\1/')"
  if [ -z "$code" ] && [ "$mrc" -ne 0 ]; then
    # "no code in --json" is NOT by itself evidence the mutant was accepted.
    # `run_timed`'s `alarm` exits 127 on a $TIMEOUT-second hang, and a bare
    # crash writes no JSON at all — both land here with an empty `code` and
    # would otherwise have been counted as SILENT-ACCEPT, i.e. as the
    # compiler noticing nothing, when in fact it died.  Only a genuine rc=0
    # is an acceptance; everything else gets its own visible bucket, keyed by
    # rc so a timeout (127) is distinguishable from an ordinary failure.
    bucket="MUTANT-CRASHED rc=$mrc"
    crashed_count=$((crashed_count + 1))
  elif [ -z "$code" ]; then
    bucket="SILENT-ACCEPT"
  elif [ "$code" = "P-PARSE" ]; then
    msg="$(printf '%s' "$json" | grep -oE '"message":"[^"]*"' | head -n1 | sed -E 's/"message":"([^"]*)"/\1/')"
    bucket="P-PARSE: $(printf '%s' "$msg" | cut -c1-40)"
  else
    bucket="$code"
  fi
  printf '%s\t%s\t%s\n' "$mkind" "$bucket" "$mlabel" >> "$BUCKETS"
  mutant_count=$((mutant_count + 1))
}

# ── step 2: mutate + classify every extracted medaka block ─────────────────
while IFS="$(printf '\t')" read -r idx kind loc dest rest; do
  [ -f "$dest" ] || continue
  case "$kind" in
    medaka)
      for mk in $MUTATION_KINDS; do
        mut="$WORK/mut_${idx}_${mk}.mdk"
        mutate "$mk" "$dest" "$mut"
        if ! cmp -s "$dest" "$mut"; then
          classify_mutant "$mut" "$mk" "$loc"
        fi
      done
      ;;
    project)
      mains="$rest"
      main1="$(printf '%s' "$mains" | awk '{print $1}')"
      [ -n "$main1" ] || continue
      mainfile="$dest/$main1"
      [ -f "$mainfile" ] || continue
      for mk in $MUTATION_KINDS; do
        mut="$WORK/mut_${idx}_${mk}.mdk"
        mutate "$mk" "$mainfile" "$mut"
        if ! cmp -s "$mainfile" "$mut"; then
          orig="$WORK/orig_${idx}_${mk}"
          cp "$mainfile" "$orig"
          cp "$mut" "$mainfile"
          classify_mutant "$mainfile" "$mk" "$loc ($main1)"
          cp "$orig" "$mainfile"
        fi
      done
      ;;
  esac
done < "$MANIFEST"

echo "first_hour_census: $mutant_count mutants classified"
# Said out loud rather than left to be spotted in the ranked table: a nonzero
# figure here means that many mutants produced NO diagnostic AND a nonzero exit
# (hang or crash), so they are neither an acceptance nor a rejection and belong
# in no code bucket.  Zero is the expected reading.
echo "first_hour_census: $crashed_count mutants died with no JSON diagnostic (MUTANT-CRASHED; not counted as SILENT-ACCEPT)"
echo "----------------------------------------"
echo "ranked table — non-parse codes (by code)"
printf '%-8s %6s\n' "count" "code"
awk -F'\t' '$2 != "" && $2 !~ /^P-PARSE:/ { print $2 }' "$BUCKETS" | sort | uniq -c | sort -rn | \
  awk '{ cnt=$1; $1=""; printf "%-8s %s\n", cnt, $0 }'

echo "----------------------------------------"
echo "ranked table — P-PARSE mutants, by MESSAGE TEXT (F8: code alone is useless here)"
printf '%-8s %s\n' "count" "message prefix"
awk -F'\t' '$2 ~ /^P-PARSE:/ { print $2 }' "$BUCKETS" | sort | uniq -c | sort -rn | \
  awk '{ cnt=$1; $1=""; printf "%-8s %s\n", cnt, $0 }'

echo "----------------------------------------"
echo "mutants applied per mutation kind (which beginner mistake was applicable how often)"
printf '%-8s %s\n' "count" "kind"
awk -F'\t' '{ print $1 }' "$BUCKETS" | sort | uniq -c | sort -rn

exit 0
