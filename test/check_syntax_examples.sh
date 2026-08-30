#!/bin/sh
# check_syntax_examples.sh — turns syntax documentation into tested artifacts.
#
# SYNTAX.md and the written guide chapters make claims about accepted syntax.
# This gate extracts every tagged Medaka example and runs it through `medaka
# check`, so a stale/wrong example fails CI instead of silently rotting.
#
# Fence-tagging convention (the info string right after the opening ```):
#   ```medaka             a COMPLETE, self-contained, checkable file. Checked
#                          verbatim with `medaka check`.
#   ```medaka-project     a multi-file example. Content is split on lines of
#                          the exact form `-- file: NAME.mdk` into that many
#                          files inside one synthetic project (with a
#                          generated medaka.toml); every file matching
#                          `main*.mdk` is checked as an entry point.
#   ```medaka-nocheck: reason
#                          genuinely not checkable as a standalone example
#                          (a bare grammar fragment / type-signature-only
#                          illustration). SKIPPED, but the reason is printed
#                          so a skip is visible, not silent. As of this
#                          writing SYNTAX.md uses none of these — every
#                          example was made checkable instead.
#   ```mdk                legacy ambiguous tag. REJECTED so a Medaka sample
#                          cannot silently fall out of the checked corpus.
#   ```  / ```sh / ...    anything else (plain fence, `sh`, prose) is not a
#                          Medaka example and is ignored.
#
# Fence info strings are parsed as a whole. Any other `medaka*` or `mdk*`
# spelling is rejected, and EOF before the exact closing ``` fence is a
# failure, so a typo or truncated example cannot silently leave the corpus.
#
# MUST NOT SILENTLY NO-OP: if any selected document checks zero examples, that
# is a FAILURE (exit 1), not a quiet pass.
#
# Usage: sh test/check_syntax_examples.sh
# Exit:  0 if every checked example passed and every selected document checked
#        at least one example
#        1 otherwise (including "found nothing to check" and "binary missing")

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"

if [ ! -x "$MEDAKA" ]; then
  echo "check_syntax_examples: native binary not found/executable at $MEDAKA" >&2
  echo "check_syntax_examples: build it first (make medaka) — refusing to skip-and-exit-0" >&2
  exit 1
fi

WORK="$(mktemp -d)" || { echo "check_syntax_examples: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

FENCE='```'
NOCHECK_PREFIX="${FENCE}medaka-nocheck: "

checked=0
failed=0
skipped=0
zero_docs=0
fail_report=""
doc_index=0

# ── check one self-contained ```medaka block ────────────────────────────────
check_medaka_block() {
  check_file="$1"
  check_line="$2"
  checked=$((checked + 1))
  doc_checked=$((doc_checked + 1))
  out="$("$MEDAKA" check "$check_file" --json 2>&1)"
  rc=$?
  errs=$(printf '%s\n' "$out" | grep -c '"severity":1')
  if [ "$rc" -ne 0 ] || [ "$errs" -gt 0 ]; then
    failed=$((failed + 1))
    doc_failed=$((doc_failed + 1))
    fail_report="$fail_report
=== FAIL: $doc_label:$check_line (medaka block) ===
$out"
  fi
}

# ── check one ```medaka-project (multi-file) block ─────────────────────────
check_project_block() {
  project_file="$1"
  project_line="$2"
  pdir="$WORK/proj_${doc_index}_$project_line"
  mkdir -p "$pdir"
  printf '[project]\nname = "syntax_check_%s_%s"\n' "$doc_index" "$project_line" > "$pdir/medaka.toml"

  cur=""
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in
      "-- file: "*)
        cur="${l#-- file: }"
        : > "$pdir/$cur"
        ;;
      *)
        if [ -n "$cur" ]; then
          printf '%s\n' "$l" >> "$pdir/$cur"
        fi
        ;;
    esac
  done < "$project_file"

  any_main=0
  for mf in "$pdir"/main*.mdk; do
    [ -e "$mf" ] || continue
    any_main=1
    checked=$((checked + 1))
    doc_checked=$((doc_checked + 1))
    out="$("$MEDAKA" check "$mf" --json 2>&1)"
    rc=$?
    errs=$(printf '%s\n' "$out" | grep -c '"severity":1')
    if [ "$rc" -ne 0 ] || [ "$errs" -gt 0 ]; then
      failed=$((failed + 1))
      doc_failed=$((doc_failed + 1))
      fail_report="$fail_report
=== FAIL: $doc_label:$project_line (medaka-project, entry $(basename "$mf")) ===
$out"
    fi
  done
  if [ "$any_main" -eq 0 ]; then
    failed=$((failed + 1))
    doc_failed=$((doc_failed + 1))
    fail_report="$fail_report
=== FAIL: $doc_label:$project_line (medaka-project has no main*.mdk entry point) ==="
  fi
}

check_document() {
  doc="$1"
  doc_label="${doc#"$ROOT"/}"
  if [ ! -f "$doc" ]; then
    echo "check_syntax_examples: selected document not found at $doc" >&2
    zero_docs=$((zero_docs + 1))
    return
  fi

  doc_index=$((doc_index + 1))
  doc_checked=0
  doc_failed=0
  doc_skipped=0
  blockfile="$WORK/block_$doc_index.mdk"
  in_block=0
  tag=""
  block_start=0
  lineno=0

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ "$in_block" -eq 0 ]; then
      case "$line" in
        "$FENCE"medaka)
          in_block=1
          tag="medaka"
          block_start=$lineno
          : > "$blockfile"
          ;;
        "$FENCE"medaka-project)
          in_block=1
          tag="project"
          block_start=$lineno
          : > "$blockfile"
          ;;
        "$NOCHECK_PREFIX"[![:space:]]*)
          reason="${line#"$NOCHECK_PREFIX"}"
          echo "SKIPPED (nocheck) $doc_label:$lineno: $reason"
          skipped=$((skipped + 1))
          doc_skipped=$((doc_skipped + 1))
          in_block=1
          tag="nocheck"
          block_start=$lineno
          ;;
        ${FENCE}medaka*|${FENCE}mdk*)
          info="${line#"$FENCE"}"
          failed=$((failed + 1))
          doc_failed=$((doc_failed + 1))
          fail_report="$fail_report
=== FAIL: $doc_label:$lineno (invalid Medaka fence info string '$info'; expected medaka, medaka-project, or medaka-nocheck: reason) ==="
          in_block=1
          tag="invalid"
          block_start=$lineno
          ;;
        *)
          ;;
      esac
    else
      if [ "$line" = "$FENCE" ]; then
        in_block=0
        case "$tag" in
          medaka) check_medaka_block "$blockfile" "$block_start" ;;
          project) check_project_block "$blockfile" "$block_start" ;;
          nocheck|invalid) ;;
        esac
        tag=""
      else
        case "$tag" in
          nocheck|invalid) ;;
          *) printf '%s\n' "$line" >> "$blockfile" ;;
        esac
      fi
    fi
  done < "$doc"

  if [ "$in_block" -eq 1 ]; then
    failed=$((failed + 1))
    doc_failed=$((doc_failed + 1))
    fail_report="$fail_report
=== FAIL: $doc_label:$block_start (unterminated $tag fence; expected exact closing fence) ==="
  fi

  echo "$doc_label: checked $doc_checked examples ($doc_skipped skipped, $doc_failed failed)"
  if [ "$doc_checked" -eq 0 ]; then
    zero_docs=$((zero_docs + 1))
    echo "check_syntax_examples: FAILURE — $doc_label checked 0 examples; every selected document must contribute" >&2
  fi
}

check_document "$ROOT/docs/spec/SYNTAX.md"
guide_docs="$WORK/guide_docs"
if ! find "$ROOT/docs/guide" -type f -name '*.md' ! -path "$ROOT/docs/guide/OUTLINE.md" -print > "$guide_docs.unsorted"; then
  echo "check_syntax_examples: failed to enumerate guide documents" >&2
  exit 1
fi
LC_ALL=C sort "$guide_docs.unsorted" > "$guide_docs"
while IFS= read -r doc; do
  check_document "$doc"
done < "$guide_docs"

echo "---"
echo "checked $checked examples ($skipped skipped, $failed failed, $zero_docs documents with zero checked)"

if [ -n "$fail_report" ]; then
  printf '%s\n' "$fail_report"
fi

if [ "$zero_docs" -gt 0 ]; then
  echo "check_syntax_examples: FAILED ($zero_docs selected document(s) checked zero examples)" >&2
  exit 1
fi

if [ "$failed" -gt 0 ]; then
  echo "check_syntax_examples: FAILED ($failed/$checked)" >&2
  exit 1
fi

echo "check_syntax_examples: PASSED ($checked/$checked)"
exit 0
