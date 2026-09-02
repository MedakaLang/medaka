#!/bin/sh
# diff_compiler_argtag_matrix.sh — the ARG-TAG DECIDABILITY MATRIX (#2445 S-1, #2032).
#
# ── WHAT THIS GATE IS FOR ─────────────────────────────────────────────────────
#
# `T-LOCAL-CONSTRAINED-MONO` (docs/KNOWN-GAPS.md, "Known over-reject") rejects a whole
# REGION of programs at check time: any local binding whose body reaches a constrained
# method call and which is then used at two types. Because the region is rejected, what
# the compiler WOULD do with those programs is unobservable — and #2032's whole question
# ("can the pin be narrowed?") is a question ABOUT that unobservable region. The prior
# sprint answered it with a hand-picked sample and its reviewer correctly called that
# "a lower bound, not closed."
#
# This gate makes the region observable and BOUNDED. `MEDAKA_ARGTAG_UNPIN=1` arms the
# test-only hatch (`setLocalPinDisabled`, driver/medaka_cli.mdk → `localPinPairs`,
# types/typecheck.mdk), which drops every pin channel so the region typechecks; the
# fixtures below then drive a head-shape x impl-shape MATRIX through it and grade what
# each cell actually does on `check`, on `run` (eval) and on `build` + execute (the
# native arg-tag chain).
#
# ── ⚠️ THIS IS A PIN, NOT A GOLDEN. A CELL THAT FLIPS MUST BE RE-CLASSIFIED ────
#
# Every `expected.txt` here was written by hand from the MECHANISM (see CENSUS.md),
# never captured from the engine — [WT-GOLDEN-ENSHRINES]. Several cells deliberately
# pin a WRONG ANSWER, because that wrong answer is the evidence that the shape is
# UNDECIDABLE BY CONSTRUCTION on the arg-tag route and therefore that the pin cannot be
# narrowed over it. Re-blessing such a cell from engine output would enshrine the wrong
# answer as correct forever and delete the finding.
#
# So: when a cell goes red, do NOT edit expected.txt to match. Work out which of the
# three classifications the new behaviour belongs to, update CENSUS.md's argument, and
# only then move the pin. A cell moving from `bug` or `undecidable-by-construction` to
# `decidable` is GOOD NEWS about #2032 and should be reported as such.
#
# ── ⚠️ EXIT CODES ARE READ FROM FILE REDIRECTS, NEVER A PIPELINE ──────────────
#
# [D-BUILD-PIPE]: `medaka build x.mdk | tail` reports tail's status, so a build that
# failed at exit 1 reads as exit 0. Every invocation below redirects to a file and reads
# `$?` on the next statement. The same trap cost this suite's sibling
# (`diff_compiler_must_fail.sh`) three separate people.
#
# Usage:  sh test/diff_compiler_argtag_matrix.sh [--dump]
#         --dump prints each cell's ACTUAL transcript instead of grading it. It is an
#         authoring aid for reading a new cell's behaviour; it never writes expected.txt,
#         because deciding a cell is a semantic act, not a capture.
# Exit:   0 every cell matches its written-from-semantics pin
#         1 a cell diverged (re-classify it), or the corpus is malformed
#         2 infra error (no binary, no clang, no fixtures)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/argtag_matrix_fixtures"
CENSUS="$FIXDIR/CENSUS.md"
export MEDAKA_ROOT="$ROOT"

# Freshness: a stale binary answers this gate's question with the OLD compiler's pin
# behaviour and looks exactly like a pass. [B-STALENESS]/[B-STDERR] — the warning is
# stderr-only and exit 0, so it must be promoted to a hard failure here.
export MEDAKA_STRICT=1

DUMP=0
[ $# -gt 0 ] && [ "$1" = "--dump" ] && DUMP=1

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir: $FIXDIR"; exit 2; }
[ -f "$CENSUS" ] || { echo "missing census: $CENSUS"; exit 2; }
# Every cell drives `medaka build`, which shells out to clang. A skip that exits 0 is the
# silent-green this whole suite exists to prevent (#590) — fail loudly instead.
command -v clang >/dev/null 2>&1 || {
  echo "clang not found, but every cell in this matrix drives 'medaka build'."
  echo "This is an INFRA ERROR, not a skip: a matrix that silently skipped its build half"
  echo "would report GREEN having graded only the interpreter."
  exit 2
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# [WT-TIMEOUT]: coreutils `timeout` does not exist on macOS, and every line here must run
# on both platforms ([B-DUAL-PLATFORM]). This shim reports 142 (128+SIGALRM), which is not
# any cell's pinned exit — a fuse-kill therefore reads as a DIVERGENCE (loud) rather than
# as a match, which is the safe direction.
bound() { perl -e 'alarm shift; exec @ARGV' 120 "$@"; }

# Fold a captured stream into ONE line so a cell's pin is a single comparable string:
# newlines become a literal backslash-n, an empty stream becomes <empty>, and two kinds of
# absolute path are erased so the pin does not encode where the tree or the scratch dir
# happens to live — the fixture's own directory, and the mktemp output path `medaka build`
# echoes back (which is fresh on every run and could never match a fixed pin).
norm() {
  _f="$1"; _d="$2"
  if [ ! -s "$_f" ]; then printf '<empty>'; return; fi
  sed -e "s#$_d/##g" -e "s#$FIXDIR/##g" -e "s#$TMP/[^ ]*#<BIN>#g" "$_f" \
    | awk '{ printf "%s\\n", $0 }' | sed -e 's/\\n$//'
}

# One cell: emit the five pinned lines on stdout, in a fixed order.
transcript() {
  _dir="$1"; _name="$2"
  _cls="$(sed -n 's/^class:[[:space:]]*//p' "$_dir/expected.txt" | head -1)"
  printf 'class: %s\n' "$_cls"
  printf 'correct: %s\n' "$(sed -n 's/^correct:[[:space:]]*//p' "$_dir/expected.txt" | head -1)"

  MEDAKA_ARGTAG_UNPIN=1 bound "$MEDAKA" check "$_dir/main.mdk" >"$TMP/o" 2>"$TMP/e"
  printf 'check: %s\n' "$?"

  MEDAKA_ARGTAG_UNPIN=1 bound "$MEDAKA" run "$_dir/main.mdk" >"$TMP/o" 2>"$TMP/e"
  _rc=$?
  cat "$TMP/e" >>"$TMP/o"
  printf 'run: %s | %s\n' "$_rc" "$(norm "$TMP/o" "$_dir")"

  MEDAKA_ARGTAG_UNPIN=1 bound "$MEDAKA" build "$_dir/main.mdk" -o "$TMP/$_name.bin" >"$TMP/o" 2>&1
  _brc=$?
  printf 'build: %s | %s\n' "$_brc" "$(norm "$TMP/o" "$_dir")"

  if [ "$_brc" -ne 0 ]; then
    # No binary was produced, so there is nothing to execute. `n/a` is a DISTINCT verdict
    # from any exit code — a build that starts succeeding cannot masquerade as a match.
    printf 'exec: n/a\n'
  else
    MEDAKA_ARGTAG_UNPIN=1 bound "$TMP/$_name.bin" >"$TMP/o" 2>"$TMP/e"
    _erc=$?
    cat "$TMP/e" >>"$TMP/o"
    printf 'exec: %s | %s\n' "$_erc" "$(norm "$TMP/o" "$_dir")"
  fi
}

fail=0
n=0
for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  n=$((n + 1))

  if [ ! -f "$dir/main.mdk" ] || [ ! -f "$dir/expected.txt" ]; then
    printf 'MALFORMED  %-44s needs both main.mdk and expected.txt\n' "$name"
    fail=1
    continue
  fi
  # A cell absent from the census is a cell nobody argued about. §6.3 of the S-1 packet
  # requires that a `bug` cell be CLASSIFIED rather than silently absent; this is what
  # makes that mechanical instead of a promise.
  if ! grep -q "^### $name\$" "$CENSUS"; then
    printf 'MALFORMED  %-44s no "### %s" section in CENSUS.md\n' "$name" "$name"
    fail=1
    continue
  fi

  if [ "$DUMP" -eq 1 ]; then
    printf '===== %s =====\n' "$name"
    transcript "$dir" "$name"
    continue
  fi

  transcript "$dir" "$name" >"$TMP/got.txt"
  if diff -u "$dir/expected.txt" "$TMP/got.txt" >"$TMP/d.txt" 2>&1; then
    printf 'ok         %-44s %s\n' "$name" \
      "$(sed -n 's/^class:[[:space:]]*//p' "$dir/expected.txt" | head -1)"
  else
    printf 'DIVERGED   %-44s see diff below\n' "$name"
    sed 's/^/    /' "$TMP/d.txt"
    fail=1
  fi
done

# N == 0 must never look like a pass — every silent-green defect in this repo is that
# sentence.
if [ "$n" -eq 0 ]; then
  echo "no fixtures found under $FIXDIR — a matrix that graded nothing is not a pass"
  exit 2
fi

[ "$DUMP" -eq 1 ] && exit 0

echo "-- checked $n matrix cells"
if [ "$fail" -ne 0 ]; then
  echo ""
  echo "A cell DIVERGED from its pin. Do NOT edit expected.txt to match the engine —"
  echo "these pins are written from the mechanism (test/argtag_matrix_fixtures/CENSUS.md),"
  echo "and several deliberately pin a WRONG answer as the evidence that a shape is"
  echo "undecidable on the arg-tag route. Re-derive the cell's classification, update"
  echo "CENSUS.md's argument, and only then move the pin. A cell that moved to"
  echo "'decidable' is progress on #2032 and should be reported as such."
  exit 1
fi
exit 0
