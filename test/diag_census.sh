#!/bin/sh
# diag_census.sh — re-derive a conformance table over the error-quality corpus
# from the BUILT BINARY, at run time. #2446/#2304/#2302.
#
# `test/error_quality_fixtures/GRADING.md`'s L/X/A columns were hand-scored
# once, by eye, against a specific base commit — and its own prose claim ("no
# fixture reaches A=2, no code/kind/fix exists") was already FALSE at
# `44b678464` (F6: `--json` emits `code`/`kind` on resolve/type/lex/eval/build
# diagnostics today). A hand-typed table like that rots the moment the binary
# improves and nobody re-grades it. This script re-derives the MACHINE-
# CHECKABLE facts every time, by running each fixture fresh:
#
#   - human prefix  : does the plain-channel output start a diagnostic with
#                      `error:`/`warning:` (case-insensitive)?
#   - caret         : does the plain-channel output include a caret
#                      (`  | ... ^`) pointing at a column?
#   - location      : is a real `file:line:col:` present (not
#                      `<unknown location>`, not silent)?
#   - json code/kind/range: does `--json` emit `code`, `kind`, and a `range`
#                      object on at least one diagnostic?
#   - diag count    : number of diagnostic objects in the `--json` envelope
#                      (a cheap cascade proxy — 1 is clean, >1 is a storm).
#
# It also derives a CODE-COVERAGE set: every code named in
# `compiler/DIAGNOSTIC-CODES-DESIGN.md` (the doc's own inventory) vs. every
# code this corpus run actually observed firing — so "documented but never
# exercised by this corpus" and "firing but undocumented" are both visible,
# not asserted from memory.
#
# ── IT ASSERTS NOTHING. IT IS A CENSUS, NOT A GATE. ─────────────────────────
# It always exits 0 — same convention as test/cli_conformance_census.sh and
# test/fmt_clean_census.sh (listed in test/CI-COVERAGE-TOOLS.txt, not
# test/gates.toml). The ENFORCING check that this corpus's plain-text
# baseline hasn't silently drifted is test/diff_compiler_error_quality_baseline.sh
# (CHECK=1 over test/error_quality_fixtures/capture.sh); this script is the
# map, not the assertion.
#
# Usage:
#   sh test/diag_census.sh          # or: make diag-census
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/medaka"
DIR="$ROOT/test/error_quality_fixtures"
DESIGN_DOC="$ROOT/compiler/DIAGNOSTIC-CODES-DESIGN.md"
TIMEOUT=60

[ -x "$BIN" ] || { echo "build first: make medaka (missing $BIN)"; exit 2; }

# Same stage->subcommand mapping test/error_quality_fixtures/capture.sh uses
# (duplicated here rather than sourced: capture.sh has no importable function
# boundary of its own, and this is the one line of logic that matters).
subcmd_for() {
  case "$1" in
    eval)  echo run ;;
    build) echo build ;;
    *)     echo check ;;
  esac
}

run_timed() {
  perl -e 'alarm shift; exec @ARGV or exit 127' "$TIMEOUT" "$@"
}

strip_paths() { sed "s|$ROOT/|ROOT/|g"; }

TABLE="$(mktemp)"
CODES_SEEN="$(mktemp)"
trap 'rm -f "$TABLE" "$CODES_SEEN"' EXIT

total=0
n_human=0; n_caret=0; n_loc=0; n_jcode=0; n_jkind=0; n_jrange=0

printf '%-42s %-10s %-6s %-6s %-6s %-6s %-6s %-6s %-6s\n' \
  "fixture" "stage" "human" "caret" "loc" "j.code" "j.kind" "j.range" "n_diag" > "$TABLE"

for stage_dir in "$DIR"/*/; do
  stage="$(basename "$stage_dir")"
  cmd="$(subcmd_for "$stage")"
  for f in "$stage_dir"*.mdk; do
    [ -f "$f" ] || continue
    total=$((total + 1))
    rel="test/error_quality_fixtures/$stage/$(basename "$f")"
    name="$(basename "${f%.mdk}")"

    plain="$(cd "$ROOT" && run_timed "$BIN" "$cmd" "$rel" 2>&1 | strip_paths)"
    json="$(cd "$ROOT" && run_timed "$BIN" "$cmd" --json "$rel" 2>&1 | strip_paths)"

    human=no; caret=no; loc=no; jcode=no; jkind=no; jrange=no; ndiag=0

    if printf '%s\n' "$plain" | grep -qiE '^(error|warning):'; then human=yes; n_human=$((n_human+1)); fi
    if printf '%s\n' "$plain" | grep -qE '^ *\| *.*\^'; then caret=yes; n_caret=$((n_caret+1)); fi
    if printf '%s\n' "$plain" | grep -qE ':[0-9]+:[0-9]+:' && ! printf '%s\n' "$plain" | grep -q '<unknown location>'; then
      loc=yes; n_loc=$((n_loc+1))
    fi

    ndiag="$(printf '%s' "$json" | grep -oE '"code":"[^"]*"' | wc -l | tr -d ' ')"
    [ -z "$ndiag" ] && ndiag=0
    if [ "$ndiag" -gt 0 ]; then
      jcode=yes; n_jcode=$((n_jcode+1))
      if printf '%s' "$json" | grep -q '"kind":'; then jkind=yes; n_jkind=$((n_jkind+1)); fi
      if printf '%s' "$json" | grep -q '"range":{'; then jrange=yes; n_jrange=$((n_jrange+1)); fi
      printf '%s' "$json" | grep -oE '"code":"[^"]*"' | sed -E 's/"code":"([^"]*)"/\1/' >> "$CODES_SEEN"
    fi

    printf '%-42s %-10s %-6s %-6s %-6s %-6s %-6s %-6s %-6s\n' \
      "$name" "$stage" "$human" "$caret" "$loc" "$jcode" "$jkind" "$jrange" "$ndiag" >> "$TABLE"
  done
done

cat "$TABLE"

echo "----------------------------------------"
echo "fixtures:                 $total"
echo "human-prefix present:     $n_human / $total"
echo "caret present:            $n_caret / $total"
echo "real location present:    $n_loc / $total"
echo "json code present:        $n_jcode / $total"
echo "json kind present:        $n_jkind / $total"
echo "json range present:       $n_jrange / $total"

echo "----------------------------------------"
echo "code coverage (compiler/DIAGNOSTIC-CODES-DESIGN.md vs. this corpus run)"

if [ -f "$DESIGN_DOC" ]; then
  DOC_CODES="$(mktemp)"
  grep -oE '`[A-Z]+-[A-Z0-9-]+`' "$DESIGN_DOC" | tr -d '`' | sort -u > "$DOC_CODES"
  sort -u "$CODES_SEEN" -o "$CODES_SEEN"

  n_doc="$(wc -l < "$DOC_CODES" | tr -d ' ')"
  n_seen="$(wc -l < "$CODES_SEEN" | tr -d ' ')"
  n_both="$(comm -12 "$DOC_CODES" "$CODES_SEEN" | wc -l | tr -d ' ')"
  n_undoc="$(comm -13 "$DOC_CODES" "$CODES_SEEN" | wc -l | tr -d ' ')"

  echo "documented codes (design doc inventory): $n_doc"
  echo "codes observed firing in this corpus:    $n_seen"
  echo "  of which also documented:              $n_both"
  echo "  of which NOT in the design doc:         $n_undoc"
  if [ "$n_undoc" -gt 0 ]; then
    echo "  undocumented codes observed:"
    comm -13 "$DOC_CODES" "$CODES_SEEN" | sed 's/^/    /'
  fi
  rm -f "$DOC_CODES"
else
  echo "  (design doc not found at $DESIGN_DOC — skipping)"
fi

exit 0
