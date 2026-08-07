#!/bin/sh
# test/check_spec_clause_labels.sh — spec clause-label definition gate.
#
# WHY THIS EXISTS. docs/spec/SHADOW-SEMANTICS.md declares a numbered clause set
# (S1, S2, ...). Commit 9c6dcee5 (2026-07-17) — whose subject was re-probing an
# unrelated matrix row — rewrote one clause in a 173-line hunk and silently
# carried three sibling clauses (S6, S7, S8) out with it. Its own commit message
# cites S7 twice AS A LIVE CLAUSE, in the very commit that deleted S7's text.
# Nobody noticed for three weeks, during which the document kept citing all
# three: the matrix, the narrative, a row asserting "S6 now holds VACUOUSLY"
# (which presupposes S6's content), and a line reading "S7's own note above
# says why: ..." pointing at nothing.
#
# `make docs-links` (test/check_doc_links.sh) checks that cited PATHS exist.
# `make agent-doc-symbols` (test/check_agent_doc_symbols.sh) checks that
# backticked SYMBOLS resolve. Neither checks that a cited clause LABEL has a
# definition. This gate does.
#
# WHAT IT CHECKS (pure text analysis — no compiler, no toolchain):
#   For every docs/spec/*.md file that DEFINES a numbered clause set — a line
#   matching `^- \*\*<Prefix><N> ` (e.g. SHADOW's "- **S1 (shadow-hood).**",
#   DICT's "- **G1 -- Uniform abstraction.**", EMITTER's
#   "- **DL1 -- Elaboration decides, the backend transcribes.**") or
#   `^#+ <Prefix><N> ` (e.g. SHADOW's "### S9 -- a CONSTRAINED standalone")
#   where <Prefix> is a ONE- or TWO-letter uppercase run — every OTHER
#   occurrence of a same-prefix label (a "citation") in that SAME document
#   must resolve to a definition in that same document.
#
# CORPUS, DERIVED NOT ASSUMED. Every docs/spec/*.md file is scanned for the
# definition patterns above; a file that defines at least one label is IN the
# corpus:
#   SHADOW-SEMANTICS.md   — S-series
#   DICT-SEMANTICS.md     — C/D/G/I/M/T/U-series (single-letter)
#   EFFECTS-SEMANTICS.md  — Q-series
#   EMITTER-SEMANTICS.md  — D/M/N/R/S/T/V-series (single-letter) AND a
#                            SEPARATE DL-series (two-letter) -- note EMITTER's
#                            own S1-S3 tail-call clauses are ALSO a series
#                            entirely separate from SHADOW's S1-S9, correctly
#                            distinguished because this gate only ever
#                            compares a citation against definitions IN THE
#                            SAME FILE
#   WASM-SEMANTICS.md     — WP-series and WH-series (two-letter) -- found only
#                            by widening the prefix search past one letter;
#                            the task brief that commissioned this gate named
#                            SHADOW/DICT/EFFECTS as likely candidates and did
#                            NOT mention this file at all
# LAYOUT-SEMANTICS.md, SYNTAX.md, STYLE.md, language-design.md define no such
# series at all (verified:
# `grep -nE '^- \*\*[A-Z][A-Z]?[0-9]+ |^#+ [A-Z][A-Z]?[0-9]+ ' <file>` is empty
# for all four) and are reported as SKIPPED, not silently ignored.
#
# EXPLICIT NON-GOAL, FOUND BY THE SAME WIDENING AND DELIBERATELY NOT CHASED:
# DICT-SEMANTICS.md ALSO has an "OD1-OD6" series defined WITHOUT the leading
# "- " bullet (bare "**OD1 -- a predicate...**" paragraphs), and a "W1"/"W2"
# pair defined only inline mid-sentence ("resolution is decidable only if
# (W1) the superclass relation is acyclic ... and (W2) ..." -- W3 alone gets
# a proper bare-paragraph header). Neither idiom is regular enough to detect
# without a real parser, and chasing it would have meant either widening
# indefinitely or excusing an over-wide match. Both stay OUT OF SCOPE: this
# gate never adds "O" or "W" to DICT's defined-prefix set, so OD-series and
# W-series citations are never examined (verified below, in this file's own
# citation totals) -- consistent with the STOP option in this gate's brief:
# "a narrow gate that says plainly what it covers beats a general-looking one
# that quietly covers less."
#
# WHY "ONLY THE SAME-PREFIX LETTERS THIS DOC DEFINES" MATTERS. This repo's
# severity ladder (AGENTS.md: "S0: silent wrongness" ... "S3: friction & debt")
# and its own P0/P1 issue-priority prose collide, letter-for-letter, with the
# clause-label alphabet: SHADOW-SEMANTICS.md is full of "P0" (issue priority,
# never a SHADOW clause) and DICT-SEMANTICS.md is full of bare "S0"/"S1"/"S2"
# cross-references to SHADOW-SEMANTICS.md's OWN S-series and to the severity
# ladder, and WASM-SEMANTICS.md cites EMITTER's "DL1-DL3" by name. Scoping
# citation-checking to "prefixes THIS document itself defines" resolves
# nearly all of this for free: DICT never defines an S-clause, so its many
# "S0"/"S1"/"SHADOW S1" mentions are never even examined; SHADOW never
# defines a P-clause, so its "P0" issue-priority mentions are never examined;
# WASM-SEMANTICS.md never defines a DL-clause, so its "DL1-DL3" mentions are
# never examined either.
#
# THE ONE COLLISION THAT SURVIVES THAT SCOPING: literal "S0" inside a document
# that DOES define an S-series (SHADOW-SEMANTICS.md, EMITTER-SEMANTICS.md) is
# always this repo's severity-ladder floor ("an S0 silent wrongness"), never a
# clause -- no clause series anywhere in docs/spec/*.md is numbered from 0
# (verified: `grep -nE '^- \*\*[A-Z][A-Z]?0 |^#+ [A-Z][A-Z]?0 ' docs/spec/*.md`
# is empty). That is a repo-wide convention, not a per-file accident, so it is
# excused once, narrowly, by exact token -- see
# test/SPEC-CLAUSE-LABEL-EXCEPTIONS.txt. Two further one-off collisions
# (DICT-SEMANTICS.md's "D6"/"D10", both DELIBERATE contrasts with a different
# series, not omissions) are excused the same way. See that file's header for
# the self-drain rules on all of them.
#
# NEVER SILENTLY NO-OP: prints how many citations it checked; checking ZERO is
# a FAILURE (exit 1), not a quiet pass -- the same harness-bug shape this
# repo has been bitten by before (see test/check_doc_links.sh).
#
# Usage:  sh test/check_spec_clause_labels.sh
# Exit:   0 every citation resolves (modulo the ledger's exceptions);
#         1 an undefined citation, a stale/orphan ledger entry, or zero
#           citations checked (harness bug).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXC="$ROOT/test/SPEC-CLAUSE-LABEL-EXCEPTIONS.txt"
cd "$ROOT" || exit 1

command -v git >/dev/null 2>&1 || { echo "FAIL: git not found (needed to enumerate docs/spec/*.md)"; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "FAIL: awk not found"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 1. Enumerate every tracked docs/spec/*.md file. ─────────────────────────
git ls-files 'docs/spec/*.md' > "$WORK/spec_files.txt"

if [ ! -s "$WORK/spec_files.txt" ]; then
  echo "FAIL: git ls-files 'docs/spec/*.md' found NOTHING (harness bug -- wrong cwd, or docs/spec missing)"
  exit 1
fi

# ── 2. Load the exceptions ledger. TAB-separated: doc <TAB> LABEL <TAB> reason. ──
# `doc` is the exact git-relative path (as this gate's own file list prints it),
# never a bare basename -- unambiguous, no resolution step needed.
: > "$WORK/exceptions.tsv"
if [ -f "$EXC" ]; then
  while IFS="$(printf '\t')" read -r doc label reason; do
    case "$doc" in
      ''|'#'*) continue ;;
    esac
    [ -z "${label:-}" ] && continue
    if [ -z "${reason:-}" ]; then
      echo "FAIL: $EXC has an entry for '$doc $label' with NO reason -- every exception needs one"
      exit 1
    fi
    printf '%s\t%s\t%s\n' "$doc" "$label" "$reason" >> "$WORK/exceptions.tsv"
  done < "$EXC"
fi

# ── 3. The actual analysis, in one awk pass over the file list (two internal
#      passes: definitions, then citations), so per-file state (which labels
#      and which letters are DEFINED) lives in memory across both. ──────────
awk -v listfile="$WORK/spec_files.txt" -v excfile="$WORK/exceptions.tsv" '
BEGIN {
  # ---- load the exceptions ledger ----
  nExc = 0
  while ((getline eline < excfile) > 0) {
    n = split(eline, ef, "\t")
    if (n < 3) continue
    ekey = ef[1] SUBSEP ef[2]
    excReason[ekey] = ef[3]
    excSeen[nExc] = ekey
    nExc++
  }
  close(excfile)

  # ---- enumerate files ----
  nFiles = 0
  while ((getline fname < listfile) > 0) {
    nFiles++
    files[nFiles] = fname
  }
  close(listfile)

  # ---- pass 1: DEFINITIONS ----
  # A definition line is `^- \*\*<Prefix><digits> ` (bullet form, e.g. SHADOWs
  # S-clauses, DICTs G/M/C/T/D/U/I-clauses, EFFECTSs Q-clauses, EMITTERs
  # D/M/N/R/S/T/V-clauses and DL-clauses, WASM-SEMANTICS.mds WP/WH-clauses) or
  # `^#+ <Prefix><digits> ` (heading form, e.g. SHADOWs "### S9 -- ..."), where
  # <Prefix> is one or two uppercase letters. Both require a trailing SPACE
  # after the number -- that is what excludes a compound sub-heading like
  # "### S1-RESIDUAL-A -- ..." (hyphen, not space, right after the digits) from
  # being mistaken for a definition of the bare clause.
  nCorpus = 0
  for (i = 1; i <= nFiles; i++) {
    fname = files[i]
    inCorpus = 0
    while ((getline line < fname) > 0) {
      dm = 0
      if (match(line, /^- \*\*[A-Z][A-Z]?[0-9]+ /)) { full = substr(line, RSTART, RLENGTH); dm = 1 }
      else if (match(line, /^#+ [A-Z][A-Z]?[0-9]+ /)) { full = substr(line, RSTART, RLENGTH); dm = 1 }
      if (dm) {
        match(full, /[A-Z][A-Z]?[0-9]+/)
        label = substr(full, RSTART, RLENGTH)
        # The PREFIX is the whole leading letter-run (1 OR 2 chars), not just
        # the first character -- a document may define both a 1-letter series
        # and a DIFFERENT 2-letter series sharing the same leading letter
        # (EMITTER-SEMANTICS.md has both "D1-D4" and "DL1-DL3"; keying on
        # substr(label,1,1) would conflate "D" and "DL" into one prefix and
        # let a "DL9" citation silently pass as if it were a "D" citation).
        match(label, /[0-9]/)
        letter = substr(label, 1, RSTART - 1)
        dkey = fname SUBSEP label
        if (!(dkey in defined)) defined[dkey] = 1
        pkey = fname SUBSEP letter
        if (!(pkey in prefixDefined)) prefixDefined[pkey] = 1
        if (!inCorpus) { inCorpus = 1; nCorpus++; corpus[fname] = 1 }
      }
    }
    close(fname)
  }

  # ---- pass 2: CITATIONS (corpus files only) ----
  # A citation is any `[A-Z][A-Z]?[0-9]+` TOKEN (word-bounded by hand: the
  # character immediately before and after must not be alnum/underscore --
  # this awk dialect is kept portable, no \b/\< \> GNU extensions) whose
  # PREFIX (the whole leading letter-run, not just its first character -- see
  # the note in pass 1) is one this same file already defines at least one
  # clause under. That scoping is what keeps a cross-document reference
  # (SHADOW citing "DICT-SEMANTICS.md S8 I5", DICT citing "SHADOW-SEMANTICS.md
  # S1", WASM-SEMANTICS.md citing EMITTER DL1-DL3) from ever being examined:
  # SHADOW never defines an I-clause, DICT never defines an S-clause,
  # WASM-SEMANTICS.md never defines a DL-clause, so none of those ever
  # enters this loop for the other documents letters.
  checked = 0
  undefined = 0
  excused = 0
  for (i = 1; i <= nFiles; i++) {
    fname = files[i]
    if (!(fname in corpus)) continue
    lineno = 0
    while ((getline line < fname) > 0) {
      lineno++
      work = line
      # PORTABILITY, VERIFIED, NOT ASSUMED: the citation regex below is
      # `[A-Z][A-Z]?[0-9]+`, NOT the POSIX-legal `[A-Z]{1,2}[0-9]+` it started
      # as. The `{1,2}` FORM IS SILENTLY WRONG UNDER MAWK. Isolated repro: a
      # docs/spec/WASM-SEMANTICS.md table row containing
      # "...`mdk_exit`** -- WH4 (checkmark) ) | ..." --
      #   gawk with {1,2}:      first match "WH4" (correct)
      #   mawk  with {1,2}:      first match  "H4" (drops the leading letter)
      #   mawk  with [A-Z][A-Z]?: first match "WH4" (correct, matches gawk)
      # Both engines agree once `{1,2}` is replaced by `[A-Z][A-Z]?`. This was
      # NOT a multi-byte-character/locale issue (a same-line em-dash was the
      # first suspect and was ruled out directly: forcing byte-vs-character
      # indexing to agree did not fix it, only dropping `{1,2}` did) -- it
      # reproduces on the bare bounded-repetition operator. `/bin/sh` here is
      # dash and gates run as `sh test/...` (not bash), and this boxs default
      # `/usr/bin/awk` is gawk, but this repo also has to run under mawk-as-
      # awk boxes and macOSs own non-gawk `awk` -- so `{n,m}` intervals are
      # avoided here on the same portability footing as the printf/timeout
      # traps this repo already tracks elsewhere. A tree-wide search for the
      # `{n,m}` interval-expression syntax finds it in NO other gate script.
      #
      # `prevCh` is the character immediately before the remainder of the
      # line still in `work` -- "" at the true start of the line (a boundary
      # by definition), carried across iterations instead of a numeric
      # absolute offset into `line` purely as a second, independent
      # portability margin: every substr() below stays RELATIVE to whichever
      # string it slices, so this loop does not care whether a given awk
      # counts a multi-byte codepoint as one unit or several.
      prevCh = ""
      while (match(work, /[A-Z][A-Z]?[0-9]+/)) {
        # Save RSTART/RLENGTH from THIS match before any nested match() call
        # (letter-run extraction below) clobbers the globals -- the
        # boundary check and the work/prevCh advancement below depend on them.
        mStart = RSTART; mLen = RLENGTH
        label = substr(work, mStart, mLen)
        match(label, /[0-9]/)
        letter = substr(label, 1, RSTART - 1)

        beforeOk = 1
        if (mStart > 1) {
          beforeCh = substr(work, mStart - 1, 1)
        } else {
          beforeCh = prevCh
        }
        if (beforeCh ~ /[A-Za-z0-9_]/) beforeOk = 0
        afterCh = substr(work, mStart + mLen, 1)
        afterOk = 1
        if (afterCh ~ /[A-Za-z0-9_]/) afterOk = 0

        if (beforeOk && afterOk) {
          pkey = fname SUBSEP letter
          if (pkey in prefixDefined) {
            checked++
            ckey = fname SUBSEP label
            everCited[ckey] = 1
            dkey = fname SUBSEP label
            if (!(dkey in defined)) {
              if (ckey in excReason) {
                excused++
                excHit[ckey] = 1
              } else {
                undefined++
                print fname ":" lineno ": UNDEFINED CLAUSE CITATION -> " label " (never defined in this document)"
              }
            }
          }
        }

        # The next iterations "before" character (if its match starts at
        # position 1 of the new `work`) is the last character of THIS match
        # -- still a relative substr() on the current `work`, same units.
        prevCh = substr(work, mStart + mLen - 1, 1)
        work = substr(work, mStart + mLen)
      }
    }
    close(fname)
  }

  # ---- report: corpus membership ----
  print "docs/spec/*.md clause-set corpus:"
  for (i = 1; i <= nFiles; i++) {
    fname = files[i]
    if (fname in corpus) {
      print "  " fname "  -- clause set present, checked"
    } else {
      print "  " fname "  -- no clause-set definitions found, SKIPPED"
    }
  }
  print ""

  if (checked == 0) {
    print "FAIL: checked 0 clause citations across " nCorpus " documents -- extraction matched nothing."
    print "      A fresh clone must never report 0 checked as a pass (harness bug)."
    exit 1
  }

  print "checked " checked " clause citations across " nCorpus " documents"
  print "  undefined: " undefined
  print "  excused:   " excused " (against " nExc " ledger entr" (nExc == 1 ? "y" : "ies") ")"

  rc = 0
  if (undefined > 0) {
    print ""
    print "FAIL: " undefined " clause citation(s) with no definition in the same document. See above."
    rc = 1
  }

  # ---- ledger ratchet: every exception must ACTIVELY EARN ITS PLACE ----
  # STALE  -- the excused label is now actually DEFINED in that document: the
  #           citation this line excused is no longer undefined, so leaving
  #           the line in would silently excuse a FUTURE, unrelated,
  #           genuinely-undefined re-use of the same label.
  # ORPHAN -- the excused label is no longer cited (as a boundary-matched,
  #           same-prefix-defined token) anywhere in that document at all: the
  #           line excuses nothing, and its reason string is fiction.
  stale = 0
  for (j = 0; j < nExc; j++) {
    ekey = excSeen[j]
    n = split(ekey, kp, SUBSEP)
    doc = kp[1]; label = kp[2]
    if (!(doc in corpus)) {
      # doc must at least be one of the currently-tracked files, or the
      # document itself is gone / renamed and the ledger line is fiction.
      found = 0
      for (i = 1; i <= nFiles; i++) if (files[i] == doc) found = 1
      if (!found) {
        print "FAIL: STALE EXCEPTION -- ledger names " doc " which is not in docs/spec/ (reason: " excReason[ekey] ")"
        stale++
        continue
      }
    }
    dkey = doc SUBSEP label
    if (dkey in defined) {
      print "FAIL: STALE EXCEPTION -- " doc " clause " label " is now actually DEFINED; delete this ledger line (reason on file: " excReason[ekey] ")"
      stale++
    }
    ckey = doc SUBSEP label
    if (!(ckey in everCited)) {
      print "FAIL: ORPHAN EXCEPTION -- " doc " clause " label " is no longer cited anywhere in that document; delete this ledger line (reason on file: " excReason[ekey] ")"
      stale++
    }
  }
  if (stale > 0) rc = 1

  print ""
  if (rc == 0) {
    print "PASS: every clause citation in docs/spec/*.md resolves to a same-document definition (modulo " nExc " ledger exception(s))."
  }
  exit rc
}
'
