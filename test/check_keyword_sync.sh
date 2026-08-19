#!/bin/sh
# test/check_keyword_sync.sh — keep the lexer's reserved-word list and its two
# hand-duplicated editor-tooling copies from drifting apart silently (#1451).
#
# WHY THIS EXISTS: the set of Medaka reserved words is defined in exactly one
# place that matters — `keywordOrIdent` in compiler/frontend/lexer.mdk. It is
# then HAND-DUPLICATED into two consumers that no gate checked against it:
#   * editors/vscode-medaka/syntaxes/medaka.tmLanguage.json  (syntax highlight)
#   * playground/medaka_tokenizer.js                         (CodeMirror lexer)
# Nothing mechanically diffed those literals against the lexer's list. A word
# added to or removed from `keywordOrIdent` left both copies silently wrong —
# which is exactly what had already happened: this gate's first run (against
# a tree believed to be in sync) found the vscode grammar missing `effect`
# and `test` (both added to the lexer since the grammar was last hand-synced).
# Fixed alongside this gate landing; see the PR body for the drift found.
#
# WHAT IT CHECKS (pure text analysis — no compiler build, no toolchain, safe
# to run anywhere, always):
#   1. Extracts the authoritative set from every `keywordOrIdent "word" = ...`
#      line in compiler/frontend/lexer.mdk.
#   2. Extracts the vscode grammar's keyword set from the `"keyword"` rule
#      group in medaka.tmLanguage.json (the `\b(a|b|c)\b` alternations across
#      all of that group's patterns).
#   3. Extracts the playground tokenizer's keyword set from its `KEYWORDS`
#      array in medaka_tokenizer.js. That file deliberately colours one extra
#      word, `internal` — a modifier the playground highlights but which is
#      NOT a lexer keyword (see the comment above its own KEYWORDS literal) —
#      so `internal` is allowed as a playground-only extra and excluded from
#      the comparison.
#   4. Reports any set difference (missing / extra words) per consumer and
#      exits nonzero on any mismatch.
#
# Deliberately NOT covered: tree-sitter-medaka/grammar.js. Repo policy is
# "don't sync tree-sitter" (#1451's own explicit scope note).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEXER="$ROOT/compiler/frontend/lexer.mdk"
VSCODE="$ROOT/editors/vscode-medaka/syntaxes/medaka.tmLanguage.json"
PLAYGROUND="$ROOT/playground/medaka_tokenizer.js"

for f in "$LEXER" "$VSCODE" "$PLAYGROUND"; do
  [ -f "$f" ] || { echo "FAIL: expected file not found: $f"; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 1. Authoritative list: compiler/frontend/lexer.mdk ────────────────────────
grep -n '^keywordOrIdent "' "$LEXER" | sed 's/.*"\(.*\)".*/\1/' | sort -u >"$WORK/lexer.txt"
[ -s "$WORK/lexer.txt" ] || {
  echo "FAIL: extracted ZERO keywords from $LEXER — extraction pattern is broken"
  echo "      (grep '^keywordOrIdent \"' compiler/frontend/lexer.mdk found nothing)."
  exit 1
}

# ── 2. vscode grammar: the "keyword" rule group's \b(a|b|c)\b alternations ────
# Isolate the "keyword": { ... } block first, so alternations belonging to
# OTHER rules (e.g. "requires|of", "deriving") in the same file are not
# mistaken for reserved-word coverage.
sed -n '/"keyword": {/,/^    },/p' "$VSCODE" \
  | grep -o '\\\\b([a-zA-Z|]*)\\\\b' \
  | sed 's/\\\\b(//;s/)\\\\b//' \
  | tr '|' '\n' \
  | sort -u >"$WORK/vscode.txt"
[ -s "$WORK/vscode.txt" ] || {
  echo "FAIL: extracted ZERO keywords from $VSCODE — extraction pattern is broken"
  echo "      (the \"keyword\": { ... } block shape in medaka.tmLanguage.json may have changed)."
  exit 1
}

# ── 3. playground tokenizer: the KEYWORDS Set literal ──────────────────────────
sed -n '/^export const KEYWORDS/,/^]);/p' "$PLAYGROUND" \
  | grep -o "'[a-zA-Z]*'" \
  | tr -d "'" \
  | grep -v '^internal$' \
  | sort -u >"$WORK/playground.txt"
[ -s "$WORK/playground.txt" ] || {
  echo "FAIL: extracted ZERO keywords from $PLAYGROUND — extraction pattern is broken"
  echo "      (the KEYWORDS = new Set([ ... ]) literal shape may have changed)."
  exit 1
}

rc=0

report_diff() {
  label="$1"
  file="$2"
  missing="$(comm -23 "$WORK/lexer.txt" "$file")"
  extra="$(comm -13 "$WORK/lexer.txt" "$file")"
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    rc=1
    echo "FAIL: $label keyword list is out of sync with compiler/frontend/lexer.mdk's keywordOrIdent"
    if [ -n "$missing" ]; then
      echo "      missing (in lexer, not in $label):"
      printf '%s\n' "$missing" | sed 's/^/        /'
    fi
    if [ -n "$extra" ]; then
      echo "      extra (in $label, not in lexer):"
      printf '%s\n' "$extra" | sed 's/^/        /'
    fi
  fi
}

report_diff "editors/vscode-medaka" "$WORK/vscode.txt"
report_diff "playground/medaka_tokenizer.js" "$WORK/playground.txt"

lexer_n=$(wc -l <"$WORK/lexer.txt" | tr -d ' ')
if [ "$rc" -eq 0 ]; then
  echo "OK: $lexer_n lexer keywords match both editors/vscode-medaka and playground/medaka_tokenizer.js"
else
  echo
  echo "Authoritative list (compiler/frontend/lexer.mdk keywordOrIdent, $lexer_n words):"
  sed 's/^/  /' "$WORK/lexer.txt"
fi

exit "$rc"
