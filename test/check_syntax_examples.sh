#!/bin/sh
# check_syntax_examples.sh — turns syntax documentation into tested artifacts.
#
# SYNTAX.md and the written guide chapters make claims about accepted syntax.
# This gate extracts every tagged Medaka example and runs it through `medaka
# check`, so a stale/wrong example fails CI instead of silently rotting.
#
# An example may ALSO declare the stdout it produces (see ```medaka-expect
# below). Such an example is additionally EXECUTED with `medaka run` and its
# actual stdout diffed against the declaration, so a guide that says "this
# prints 7" fails CI when it no longer does. Prose claims about output are the
# half `medaka check` cannot see: a program that type-checks perfectly can
# still print the wrong thing.
#
# Fence-tagging convention (the info string after a CommonMark fence opener):
#   ```medaka             a COMPLETE, self-contained, checkable file. Checked
#                          after CommonMark content de-indentation with
#                          `medaka check`.
#   ```medaka-project     a multi-file example. Content is split on lines of
#                          the exact form `-- file: NAME.mdk` into that many
#                          files inside one synthetic project (with a
#                          generated medaka.toml); every file matching
#                          `main*.mdk` is checked as an entry point.
#   ```medaka-expect      the expected stdout of the IMMEDIATELY PRECEDING
#                          ```medaka / ```medaka-project block — "immediately"
#                          meaning no other fenced block may intervene (prose
#                          between the two is fine and expected, e.g. "Its
#                          output is:"). The preceding example is run with
#                          `medaka run` and its actual stdout compared against
#                          this block's content, ignoring only a trailing
#                          newline. An expectation is OPT-IN: a Medaka block
#                          with no following medaka-expect stays check-only,
#                          exactly as before — it is NOT skipped. It is,
#                          however, REPORTED: every such block prints a
#                          `CHECKED-ONLY (no stdout expectation)` line and is
#                          counted separately in the summary, so "type-checks
#                          but its output is unverified" is a visible
#                          category rather than an indistinguishable share of
#                          the `checked` total. A
#                          medaka-expect block with no preceding Medaka block
#                          is a FAILURE, so a misplaced or orphaned
#                          expectation cannot silently assert nothing. On a
#                          medaka-project block the expectation requires
#                          exactly one main*.mdk entry point (otherwise
#                          "the" stdout is ambiguous), which is likewise a
#                          FAILURE rather than a skip. The block renders as a
#                          plain code block in Markdown, so the declaration is
#                          also what the reader sees.
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
# spelling is rejected. Backtick and tilde fences of three or more characters
# are tracked through a same-character closer at least as long as the opener;
# EOF in a Medaka-looking block fails so a typo or truncated example cannot
# silently leave the corpus.
#
# MUST NOT SILENTLY NO-OP: if any selected document checks zero examples, that
# is a FAILURE (exit 1), not a quiet pass.
#
# Usage: sh test/check_syntax_examples.sh
# Exit:  0 if every checked example passed, every declared stdout matched, and
#        every selected document checked at least one example
#        1 otherwise (including "found nothing to check" and "binary missing")

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"

# ── optional extraction dump (consumed by test/first_hour_census.sh) ───────
# When SYNTAX_EXTRACT_DIR is set, every extracted ```medaka / ```medaka-project
# block is ALSO copied there (as well as being checked, exactly as always) —
# a manifest.tsv row records how to find it. This is the one reusable
# extraction seam licensed by S-first-hour-rank's packet (F9): it rides along
# on the SAME extraction/parsing state machine below rather than duplicating
# it, and does nothing (no directory, no manifest, zero behavior change) when
# the variable is unset — which is how this script's own checked/failed/exit
# behavior stays byte-for-byte unchanged for every other caller.
SYNTAX_EXTRACT_DIR="${SYNTAX_EXTRACT_DIR:-}"
extract_counter=0
extract_dump_medaka() {
  [ -n "$SYNTAX_EXTRACT_DIR" ] || return 0
  extract_counter=$((extract_counter + 1))
  dest="$SYNTAX_EXTRACT_DIR/mdk_$(printf '%04d' "$extract_counter").mdk"
  cp "$1" "$dest"
  printf '%s\tmedaka\t%s:%s\t%s\n' "$extract_counter" "$doc_label" "$2" "$dest" \
    >> "$SYNTAX_EXTRACT_DIR/manifest.tsv"
}
extract_dump_project() {
  [ -n "$SYNTAX_EXTRACT_DIR" ] || return 0
  extract_counter=$((extract_counter + 1))
  dest_dir="$SYNTAX_EXTRACT_DIR/proj_$(printf '%04d' "$extract_counter")"
  cp -r "$1" "$dest_dir"
  mains=""
  for mf in "$dest_dir"/main*.mdk; do
    [ -e "$mf" ] || continue
    mains="$mains $(basename "$mf")"
  done
  printf '%s\tproject\t%s:%s\t%s\t%s\n' "$extract_counter" "$doc_label" "$2" "$dest_dir" "$mains" \
    >> "$SYNTAX_EXTRACT_DIR/manifest.tsv"
}

if [ ! -x "$MEDAKA" ]; then
  echo "check_syntax_examples: native binary not found/executable at $MEDAKA" >&2
  echo "check_syntax_examples: build it first (make medaka) — refusing to skip-and-exit-0" >&2
  exit 1
fi

WORK="$(mktemp -d)" || { echo "check_syntax_examples: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

# ── verify one extracted file is canonically `medaka fmt`-formatted ────────
# The guide is the reference for how Medaka is written, so every checkable
# example must already be what `medaka fmt --stdout` would produce for it —
# reformatting on drift instead of catching it here would let hand-edits
# quietly re-diverge. On mismatch this appends a fail_report entry (counted
# in `failed`, same as any other example failure) carrying the actual vs.
# expected diff, and returns 1; it does NOT touch `checked`/`expected` — the
# fmt check rides along on an already-counted example, it is not a new kind
# of example.
# Args: $1 = file to fmt-check, $2 = label for the fail_report entry.
check_fmt() {
  fmt_target="$1"
  fmt_label="$2"
  # KNOWN `medaka fmt` DEFECT (found while adding this check, not yet filed
  # as an issue): a bodyless `interface X a` (no `where`, no methods — a
  # valid, documented marker-interface shape) is not round-tripped by fmt;
  # it synthesizes a spurious `where` plus an empty/whitespace body line
  # regardless of any trailing comment. SYNTAX.md's "Empty a" example exists
  # specifically to demonstrate the where-less form and says so in its own
  # comment ("no `where`") — canonicalizing it to fmt's output would delete
  # the very construct the example teaches, which this gate must not do
  # (it only enforces STYLE, never rewrites what an example demonstrates).
  # Exempt by content, not path/line, so this cannot silently widen to cover
  # an unrelated future block at the same spot — matches only the exact
  # bodyless-interface header shape known to be unformattable. This skips
  # the fmt check for the WHOLE containing file (the block this construct
  # sits in is checked as one unit), not just this one line; the rest of
  # that block was hand-verified canonical when this exemption was added.
  if grep -q '^interface [A-Za-z_][A-Za-z0-9_]* [a-z][A-Za-z0-9_]*[[:space:]]*\(--.*\)\?$' "$fmt_target" 2>/dev/null; then
    return 0
  fi
  # A medaka-project block's per-file extraction (check_project_block) keeps
  # the blank line that separates one `-- file:` section from the next as
  # part of the extracted file — that separator is markdown structure, not
  # file content, and `medaka fmt` normalizes it away regardless. Trim
  # trailing blank lines before comparing so the fmt check judges the code,
  # not the fence's own spacing convention.
  awk '{a[NR]=$0} END{n=NR; while (n > 0 && a[n] == "") n--; for (i = 1; i <= n; i++) print a[i]}' \
    "$fmt_target" > "$WORK/fmt_trimmed"
  fmt_out="$("$MEDAKA" fmt --stdout "$WORK/fmt_trimmed" 2>"$WORK/fmt_err")"
  fmt_rc=$?
  if [ "$fmt_rc" -ne 0 ]; then
    failed=$((failed + 1))
    doc_failed=$((doc_failed + 1))
    fail_report="$fail_report
=== FAIL: $fmt_label (medaka fmt --stdout exited $fmt_rc) ===
$(cat "$WORK/fmt_err")"
    return 1
  fi
  printf '%s\n' "$fmt_out" > "$WORK/fmt_expected"
  if ! diff -u "$WORK/fmt_trimmed" "$WORK/fmt_expected" > "$WORK/fmt_diff"; then
    failed=$((failed + 1))
    doc_failed=$((doc_failed + 1))
    fail_report="$fail_report
=== FAIL: $fmt_label (not canonically \`medaka fmt\`-formatted) ===
$(cat "$WORK/fmt_diff")"
    return 1
  fi
  return 0
}

checked=0
failed=0
skipped=0
expected=0
checkonly=0
zero_docs=0
fail_report=""
doc_index=0

# The example a ```medaka-expect block would attach to, if one comes next.
# pending_kind is "" once anything other than a medaka-expect fence opener has
# been seen, which is what makes "immediately preceding" enforceable in one
# streaming pass. pending_prog is the runnable file; it is "" when the
# preceding block exists but cannot be run unambiguously (a medaka-project
# block whose main*.mdk entry point is not unique), and pending_why then
# carries the reason to report.
pending_kind=""
pending_prog=""
pending_line=0
pending_why=""

# Parse a CommonMark fence opener. On success, OPEN_CHAR, OPEN_COUNT, and
# OPEN_INFO describe it. At most three literal leading spaces are accepted.
parse_fence_opener() {
  open_text="$1"
  open_indent=0
  while [ "$open_indent" -lt 3 ]; do
    case "$open_text" in
      " "*) open_text=${open_text# }; open_indent=$((open_indent + 1)) ;;
      *) break ;;
    esac
  done

  case "$open_text" in
    \`*) OPEN_CHAR='`' ;;
    ~*) OPEN_CHAR='~' ;;
    *) return 1 ;;
  esac

  OPEN_COUNT=0
  while :; do
    case "$open_text" in
      "$OPEN_CHAR"*)
        OPEN_COUNT=$((OPEN_COUNT + 1))
        open_text=${open_text#"$OPEN_CHAR"}
        ;;
      *) break ;;
    esac
  done
  [ "$OPEN_COUNT" -ge 3 ] || return 1

  # CommonMark forbids backticks in a backtick fence's info string.
  if [ "$OPEN_CHAR" = '`' ]; then
    case "$open_text" in *\`*) return 1 ;; esac
  fi

  # Fence/info separation is optional; when present it is whitespace.
  while :; do
    case "$open_text" in
      " "*) open_text=${open_text# } ;;
      "	"*) open_text=${open_text#"	"} ;;
      *) break ;;
    esac
  done
  OPEN_INFO=$open_text
  return 0
}

# #2404: a line that WANTED to be a Medaka fence opener but was rejected above.
# CommonMark forbids backticks in a backtick fence's info string, so
# "```medaka-nocheck: after a one-line `data` decl ..." is not an opener at all —
# it is paragraph text, and the ``` meant to CLOSE it then reads as a fresh
# opener that swallows the next real example up to the following closer. The
# rejection is correct; the silence is the bug. Anything shaped like a Medaka
# tag that did not parse as an opener is reported as a failure, so a doc that
# renders wrongly on GitHub cannot also quietly shrink the checked corpus.
# REJECT_INFO carries the offending text.
looks_like_medaka_fence() {
  reject_text="$1"
  reject_indent=0
  while [ "$reject_indent" -lt 3 ]; do
    case "$reject_text" in
      " "*) reject_text=${reject_text# }; reject_indent=$((reject_indent + 1)) ;;
      *) break ;;
    esac
  done
  case "$reject_text" in
    \`\`\`*) ;;
    *) return 1 ;;
  esac
  while :; do
    case "$reject_text" in
      \`*) reject_text=${reject_text#\`} ;;
      *) break ;;
    esac
  done
  while :; do
    case "$reject_text" in
      " "*) reject_text=${reject_text# } ;;
      "	"*) reject_text=${reject_text#"	"} ;;
      *) break ;;
    esac
  done
  case "$reject_text" in
    medaka*|mdk*) REJECT_INFO=$reject_text; return 0 ;;
    *) return 1 ;;
  esac
}

# A closer uses the opener's character, is at least as long, permits at most
# three leading spaces, and has only trailing whitespace after the run.
is_matching_fence_closer() {
  close_text="$1"
  close_indent=0
  while [ "$close_indent" -lt 3 ]; do
    case "$close_text" in
      " "*) close_text=${close_text# }; close_indent=$((close_indent + 1)) ;;
      *) break ;;
    esac
  done

  close_count=0
  while :; do
    case "$close_text" in
      "$block_fence_char"*)
        close_count=$((close_count + 1))
        close_text=${close_text#"$block_fence_char"}
        ;;
      *) break ;;
    esac
  done
  [ "$close_count" -ge "$block_fence_count" ] || return 1
  case "$close_text" in
    *[![:space:]]*) return 1 ;;
    *) return 0 ;;
  esac
}

# ── report an example that acquired no ```medaka-expect ────────────────────
# A ```medaka / ```medaka-project block whose expectation window closes with no
# expectation attached is CHECK-ONLY: it type-checks, but nothing verifies what
# it prints. That is neither a skip nor a failure, so it used to be invisible —
# indistinguishable from a stdout-compared block inside the `checked` total.
# Report it, and count it, the way `medaka-nocheck` reasons are reported.
# Called wherever the window closes: at any subsequent fence opener, and at
# end of document.
flush_pending() {
  if [ -n "$pending_kind" ]; then
    echo "CHECKED-ONLY (no stdout expectation) $doc_label:$pending_line"
    checkonly=$((checkonly + 1))
    doc_checkonly=$((doc_checkonly + 1))
  fi
  pending_kind=""
  pending_prog=""
  pending_why=""
}

# ── check one self-contained ```medaka block ────────────────────────────────
check_medaka_block() {
  check_file="$1"
  check_line="$2"
  checked=$((checked + 1))
  doc_checked=$((doc_checked + 1))
  out="$("$MEDAKA" check "$check_file" --json 2>&1)"
  rc=$?
  errs=$(printf '%s\n' "$out" | grep -c '"severity":1')
  main_shape=$(printf '%s\n' "$out" | grep -c '"code":"W-MAIN-SHAPE"')
  if [ "$rc" -ne 0 ] || [ "$errs" -gt 0 ] || [ "$main_shape" -gt 0 ]; then
    failed=$((failed + 1))
    doc_failed=$((doc_failed + 1))
    fail_report="$fail_report
=== FAIL: $doc_label:$check_line (medaka block) ===
$out"
  fi
  check_fmt "$check_file" "$doc_label:$check_line (medaka block)"
  extract_dump_medaka "$check_file" "$check_line"

  # Offer this example to a ```medaka-expect block that may follow. The
  # snapshot is a copy: $blockfile is reused by the next block in the document.
  pending_kind="medaka"
  pending_prog="$WORK/pending_${doc_index}_$check_line.mdk"
  pending_line="$check_line"
  pending_why=""
  cp "$check_file" "$pending_prog"
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
  main_count=0
  sole_main=""
  for mf in "$pdir"/main*.mdk; do
    [ -e "$mf" ] || continue
    any_main=1
    main_count=$((main_count + 1))
    sole_main="$mf"
    checked=$((checked + 1))
    doc_checked=$((doc_checked + 1))
    out="$("$MEDAKA" check "$mf" --json 2>&1)"
    rc=$?
    errs=$(printf '%s\n' "$out" | grep -c '"severity":1')
    main_shape=$(printf '%s\n' "$out" | grep -c '"code":"W-MAIN-SHAPE"')
    if [ "$rc" -ne 0 ] || [ "$errs" -gt 0 ] || [ "$main_shape" -gt 0 ]; then
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

  # fmt-check every per-file section, not just the main*.mdk entry points —
  # a helper module's formatting drifts exactly the same way an entry
  # point's does, and the guide teaches both.
  for pf in "$pdir"/*.mdk; do
    [ -e "$pf" ] || continue
    check_fmt "$pf" "$doc_label:$project_line (medaka-project, file $(basename "$pf"))"
  done
  extract_dump_project "$pdir" "$project_line"

  # Offer this example to a ```medaka-expect block that may follow. "The"
  # stdout of a project with several entry points is not well defined, so the
  # offer carries a reason instead of a program in that case; declaring an
  # expectation on it then FAILS rather than quietly checking nothing.
  pending_kind="project"
  pending_line="$project_line"
  if [ "$main_count" -eq 1 ]; then
    pending_prog="$sole_main"
    pending_why=""
  else
    pending_prog=""
    pending_why="medaka-expect needs exactly one main*.mdk entry point to run; this medaka-project block has $main_count"
  fi
}

# ── run the pending example and diff its stdout against a ```medaka-expect ──
check_expect_block() {
  expect_file="$1"
  expect_start="$2"
  expected=$((expected + 1))
  doc_expected=$((doc_expected + 1))

  if [ -z "$pending_prog" ]; then
    failed=$((failed + 1))
    doc_failed=$((doc_failed + 1))
    fail_report="$fail_report
=== FAIL: $doc_label:$expect_start (medaka-expect for the block at :$pending_line — $pending_why) ==="
    pending_kind=""
    return
  fi

  # Hermeticity: a documented example may write to a CWD-RELATIVE path (the
  # file-IO chapter's `logPath = "expenses.log"` does). Inheriting the caller's
  # CWD then drops that file in the repo root on every gate run. Execute in a
  # fresh scratch directory instead, so such a write lands under $WORK and is
  # reaped by the EXIT trap. $pending_prog and $WORK are absolute, so neither
  # the program nor medaka.toml root walk-up is affected by the move.
  run_cwd="$WORK/rundir_${doc_index}_$pending_line"
  mkdir -p "$run_cwd"

  # Command substitution strips trailing newlines from BOTH sides, which is
  # exactly the one difference an expectation should not be sensitive to.
  run_out="$(cd "$run_cwd" && "$MEDAKA" run "$pending_prog" 2>"$WORK/run_err.$doc_index")"
  run_rc=$?
  want="$(cat "$expect_file")"
  if [ -z "$want" ]; then
    want_lines=0
  else
    want_lines=$(printf '%s\n' "$want" | wc -l | tr -d ' ')
  fi

  if [ "$run_rc" -ne 0 ]; then
    failed=$((failed + 1))
    doc_failed=$((doc_failed + 1))
    fail_report="$fail_report
=== FAIL: $doc_label:$pending_line (medaka run exited $run_rc; expectation at :$expect_start) ===
--- stderr ---
$(cat "$WORK/run_err.$doc_index")
--- stdout ---
$run_out"
  elif [ "$run_out" != "$want" ]; then
    failed=$((failed + 1))
    doc_failed=$((doc_failed + 1))
    fail_report="$fail_report
=== FAIL: $doc_label:$pending_line (stdout does not match the medaka-expect block at :$expect_start) ===
--- expected ---
$want
--- actual ---
$run_out"
  else
    echo "RAN (stdout matched) $doc_label:$pending_line: $want_lines line(s), expectation at :$expect_start"
  fi

  pending_kind=""
  pending_prog=""
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
  doc_expected=0
  doc_checkonly=0
  blockfile="$WORK/block_$doc_index.mdk"
  expectfile="$WORK/expect_$doc_index.txt"
  pending_kind=""
  pending_prog=""
  pending_line=0
  pending_why=""
  in_block=0
  tag=""
  block_start=0
  block_fence_char=""
  block_fence_count=0
  block_content_indent=0
  lineno=0

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ "$in_block" -eq 0 ]; then
      if parse_fence_opener "$line"; then
        in_block=1
        block_start=$lineno
        block_fence_char=$OPEN_CHAR
        block_fence_count=$OPEN_COUNT
        block_content_indent=$open_indent
        case "$OPEN_INFO" in
        medaka)
          tag="medaka"
          : > "$blockfile"
          ;;
        medaka-project)
          tag="project"
          : > "$blockfile"
          ;;
        medaka-expect)
          if [ -n "$pending_kind" ]; then
            tag="expect"
            : > "$expectfile"
          else
            failed=$((failed + 1))
            doc_failed=$((doc_failed + 1))
            fail_report="$fail_report
=== FAIL: $doc_label:$lineno (orphan medaka-expect: no medaka/medaka-project block immediately precedes it) ==="
            tag="invalid"
          fi
          ;;
        "medaka-nocheck: "[![:space:]]*)
          reason=${OPEN_INFO#"medaka-nocheck: "}
          echo "SKIPPED (nocheck) $doc_label:$lineno: $reason"
          skipped=$((skipped + 1))
          doc_skipped=$((doc_skipped + 1))
          tag="nocheck"
          ;;
        medaka*|mdk*)
          failed=$((failed + 1))
          doc_failed=$((doc_failed + 1))
          fail_report="$fail_report
=== FAIL: $doc_label:$lineno (invalid Medaka fence info string '$OPEN_INFO'; expected medaka, medaka-project, medaka-expect, or medaka-nocheck: reason) ==="
          tag="invalid"
          ;;
        *)
          tag="other"
          ;;
        esac
        # "Immediately preceding" is enforced here: ANY other fence ends the
        # window in which an expectation could attach to the last example.
        case "$OPEN_INFO" in
          medaka-expect) ;;
          *) flush_pending ;;
        esac
      elif looks_like_medaka_fence "$line"; then
        failed=$((failed + 1))
        doc_failed=$((doc_failed + 1))
        fail_report="$fail_report
=== FAIL: $doc_label:$lineno (malformed Medaka fence opener '$REJECT_INFO'; CommonMark forbids backticks in a backtick fence's info string — remove them or use a ~~~ fence) ==="
      fi
    else
      if is_matching_fence_closer "$line"; then
        in_block=0
        case "$tag" in
          medaka) check_medaka_block "$blockfile" "$block_start" ;;
          project) check_project_block "$blockfile" "$block_start" ;;
          expect) check_expect_block "$expectfile" "$block_start" ;;
          nocheck|invalid|other) ;;
        esac
        tag=""
      else
        case "$tag" in
          nocheck|invalid|other) ;;
          medaka|project|expect)
            content_line=$line
            content_indent=0
            while [ "$content_indent" -lt "$block_content_indent" ]; do
              case "$content_line" in
                " "*) content_line=${content_line# }; content_indent=$((content_indent + 1)) ;;
                *) break ;;
              esac
            done
            if [ "$tag" = "expect" ]; then
              printf '%s\n' "$content_line" >> "$expectfile"
            else
              printf '%s\n' "$content_line" >> "$blockfile"
            fi
            ;;
        esac
      fi
    fi
  done < "$doc"

  # End of document closes the last expectation window too.
  flush_pending

  if [ "$in_block" -eq 1 ]; then
    case "$tag" in
      medaka|project|expect|nocheck|invalid)
        failed=$((failed + 1))
        doc_failed=$((doc_failed + 1))
        fail_report="$fail_report
=== FAIL: $doc_label:$block_start (unterminated $tag fence; expected matching '$block_fence_char' fence of at least $block_fence_count characters) ==="
        ;;
      other) ;;
    esac
  fi

  echo "$doc_label: checked $doc_checked examples ($doc_skipped skipped, $doc_expected stdout-compared, $doc_checkonly check-only, $doc_failed failed)"
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
echo "checked $checked examples ($skipped skipped, $expected stdout-compared, $checkonly check-only, $failed failed, $zero_docs documents with zero checked)"

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

echo "check_syntax_examples: PASSED ($checked/$checked checked, $expected/$expected stdout expectations matched)"
exit 0
