#!/bin/sh
# test/doc_census.sh — derived doc-disposition census. Not a gate: this is a
# reporting tool, run via `make doc-census` (registry row `doc-disposition
# (#2300)` in test/slop_census.sh). It asserts nothing; exits 0 on a healthy
# run, and refuses (exit 1) only if the doc corpus comes back empty — same
# fail-closed shape as test/comment_register_census.sh and
# test/arch_census.sh.
#
# WHY THIS EXISTS (#2300 part 1, docs-that-are-checked sprint): the doc
# corpus this repo already gates (test/check_doc_links.sh's link-rot check,
# test/check_syntax_examples.sh's tested-example extraction) has no single
# place that reports, PER FILE, what disposition it already carries — is it
# enrolled in the tested-syntax-example corpus, is it excused wholesale from
# link-rot checking (a FILE-tier line in test/DOC-LINK-EXCEPTIONS.txt), does
# it carry a `**Status:**` banner, is it reachable from the generated
# docs/README.md index at all. Without that, a planner deciding what doc
# work to schedule re-derives each of those facts by hand every time. This
# script derives all four in one pass and reports them, per file — it reads
# the existing gates' own definitions of their corpora; it does not
# reimplement their checking logic (link resolution, example extraction) and
# renders no verdict about a file being "too rotten".
#
# WHAT IT REPORTS, per tracked doc:
#   1. last-edit      — the file's most recent commit date (`git log -1
#                        --format=%cs`), not any deeper notion of
#                        "meaningful" (a reformatting-only commit still
#                        counts) — this is the cheap, honest signal, not a
#                        content-diff heuristic.
#   2. syntax-corpus   — Y if the file is in test/check_syntax_examples.sh's
#                        own corpus: any tracked .md carrying a Medaka-family
#                        fence, minus the four path prefixes that gate excludes
#                        (docs/stdlib, archive, sqlite/findings, test). The
#                        selection rule is re-derived below, not copied as a
#                        file list.
#   3. file-exception  — Y if a FILE-tier line in
#                        test/DOC-LINK-EXCEPTIONS.txt names this exact path
#                        (the doc is excused wholesale from link-rot
#                        checking).
#   4. docs-index      — Y if the file is reachable as a link target from
#                        docs/README.md (test/gen_docs_index.sh's generated
#                        output) — "reachable from docs/README.md", not "is
#                        physically under docs/".
#   5. status-banner   — Y if a `**Status:**` marker appears in the file's
#                        first ~10 lines (the live banner convention —
#                        docs/design/ARGS-DESIGN.md, docs/KNOWN-GAPS.md,
#                        etc. — also what test/gen_docs_index.sh reads).
#   6. disposition     — Y if EITHER 5 (status-banner) or 3 (file-exception)
#                        holds — "this doc has SOME standing statement about
#                        its own currency", the union this census exists to
#                        answer.
#
# Needs no built ./medaka — pure git/grep/awk over tracked source files.
# Portable POSIX sh (no bash-only features; the path-normalizer below avoids
# `readlink -f`, which is not portable to macOS's BSD readlink).
#
# Usage:  sh test/doc_census.sh
# Output: one line per doc in the corpus, then a summary count block. Exits 0
#         on a healthy run; refuses (exit 1) only if the corpus is empty,
#         which would otherwise misreport as a clean zero.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

IFS='
'

# ── corpus: same definition test/check_doc_links.sh uses, minus goldens ────
# The golden trees below hold `medaka doc` / `medaka new` OUTPUT, not prose: a
# gate pins their bytes, so they can never carry a **Status:** banner and would
# report `disposition=N` forever, inflating the unadjudicated count with rows
# nobody is allowed to adjudicate. Excluded for the same reason
# test/snapshots/** already is — generated content is answerable at its
# generator (compiler/tools/doc.mdk, compiler/tools/new_cmd.mdk), not here.
git ls-files '*.md' \
  ':!:test/snapshots/**' \
  ':!:test/doc_goldens/**' \
  ':!:test/native_cli_goldens/**' \
  ':!:test/new_golden/**' > "$WORK/corpus.txt"

if [ ! -s "$WORK/corpus.txt" ]; then
  echo "doc_census: git ls-files '*.md' found ZERO files — harness bug, refusing to report" >&2
  exit 1
fi

# ── syntax-example corpus: re-derives check_syntax_examples.sh's rule ──────
# That gate selects every tracked Markdown file carrying a Medaka-family fence,
# minus four path prefixes (docs/stdlib, archive, sqlite/findings, test). The
# rule is re-derived here rather than mirrored as a file list, so this column
# cannot silently encode a corpus the gate has moved past; a drift shows up as
# this census's count disagreeing with the gate's own `covered N documents`.
: > "$WORK/syntax_corpus.txt"
git ls-files '*.md' > "$WORK/syntax_all.txt"
while IFS= read -r _sc_rel; do
  case "$_sc_rel" in
    docs/stdlib/*|archive/*|sqlite/findings/*|test/*) continue ;;
  esac
  grep -qE '^[[:space:]]*(```|~~~)+[[:space:]]*(medaka|mdk)' "$ROOT/$_sc_rel" || continue
  printf '%s\n' "$_sc_rel" >> "$WORK/syntax_corpus.txt"
done < "$WORK/syntax_all.txt"

# ── FILE-tier exceptions from test/DOC-LINK-EXCEPTIONS.txt ─────────────────
# Format (see that file's own header): TAB-separated `KIND<TAB>pattern<TAB>reason`,
# blank lines and '#' comments ignored. We want just the FILE-kind paths.
if [ -f "$ROOT/test/DOC-LINK-EXCEPTIONS.txt" ]; then
  awk -F'\t' '$1 == "FILE" { print $2 }' "$ROOT/test/DOC-LINK-EXCEPTIONS.txt" > "$WORK/file_exceptions.txt"
else
  : > "$WORK/file_exceptions.txt"
fi

# ── docs-index reachability: link targets in docs/README.md ────────────────
# docs/README.md is generated by test/gen_docs_index.sh; every doc it lists
# appears as a markdown link `[...](target)`, resolved relative to docs/
# (docs/README.md's own directory) exactly like a real markdown renderer
# would resolve it. normalize_path collapses "../" segments without
# `readlink -f` (not portable to macOS's BSD readlink).
normalize_path() {
  _np_path="$1"
  _np_result=""
  _np_oldifs="$IFS"
  IFS='/'
  set -- $_np_path
  IFS="$_np_oldifs"
  for _np_part in "$@"; do
    case "$_np_part" in
      "" | ".") continue ;;
      "..") case "$_np_result" in
              */*) _np_result="${_np_result%/*}" ;;
              *)   _np_result="" ;;
            esac ;;
      *)
        if [ -z "$_np_result" ]; then _np_result="$_np_part"; else _np_result="$_np_result/$_np_part"; fi
        ;;
    esac
  done
  printf '%s\n' "$_np_result"
}

: > "$WORK/docs_index_reachable.txt"
if [ -f "$ROOT/docs/README.md" ]; then
  grep -oE '\]\([^)]+\)' "$ROOT/docs/README.md" | sed -e 's/^](//' -e 's/)$//' > "$WORK/readme_links.txt"
  while IFS= read -r _link; do
    [ -n "$_link" ] || continue
    case "$_link" in
      http://*|https://*|mailto:*|'#'*) continue ;;
    esac
    _link="${_link%%#*}"
    [ -n "$_link" ] || continue
    normalize_path "docs/$_link" >> "$WORK/docs_index_reachable.txt"
  done < "$WORK/readme_links.txt"
fi
sort -u "$WORK/docs_index_reachable.txt" -o "$WORK/docs_index_reachable.txt"

n_total=0
n_syntax=0
n_file_exc=0
n_docs_index=0
n_banner=0
n_disposition=0

per_file_report=""

for f in $(cat "$WORK/corpus.txt"); do
  [ -n "$f" ] || continue
  n_total=$((n_total + 1))

  last_edit=$(git -C "$ROOT" log -1 --format=%cs -- "$f" 2>/dev/null)
  [ -n "$last_edit" ] || last_edit="(no-history)"

  in_syntax="N"
  if grep -qxF "$f" "$WORK/syntax_corpus.txt"; then
    in_syntax="Y"
    n_syntax=$((n_syntax + 1))
  fi

  has_file_exc="N"
  if grep -qxF "$f" "$WORK/file_exceptions.txt"; then
    has_file_exc="Y"
    n_file_exc=$((n_file_exc + 1))
  fi

  in_docs_index="N"
  if grep -qxF "$f" "$WORK/docs_index_reachable.txt"; then
    in_docs_index="Y"
    n_docs_index=$((n_docs_index + 1))
  fi

  has_banner="N"
  if [ -f "$ROOT/$f" ] && head -n 10 "$ROOT/$f" 2>/dev/null | grep -q '\*\*Status:\*\*'; then
    has_banner="Y"
    n_banner=$((n_banner + 1))
  fi

  disposition="N"
  if [ "$has_banner" = "Y" ] || [ "$has_file_exc" = "Y" ]; then
    disposition="Y"
    n_disposition=$((n_disposition + 1))
  fi

  per_file_report="$per_file_report$f  last-edit=$last_edit  syntax-corpus=$in_syntax  file-exception=$has_file_exc  docs-index=$in_docs_index  status-banner=$has_banner  disposition=$disposition
"
done

echo "doc_census: $n_total tracked *.md files (git ls-files '*.md' ':!:test/snapshots/**')"
echo
echo "-- per-file report --"
if [ -n "$per_file_report" ]; then
  printf '%s' "$per_file_report"
else
  echo "  (none)"
fi
echo
echo "-- summary --"
echo "  total docs:                          $n_total"
echo "  in syntax-example corpus:            $n_syntax"
echo "  FILE-tier link-rot exception:        $n_file_exc"
echo "  reachable from docs/README.md:       $n_docs_index"
echo "  carries a **Status:** banner:        $n_banner"
echo "  has SOME standing disposition:       $n_disposition"

exit 0
