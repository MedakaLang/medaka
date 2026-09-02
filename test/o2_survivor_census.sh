#!/bin/sh
# o2_survivor_census.sh — report-only census over the S2-o2-survivor-report
# corpus (#2357, LLVM arm): for each single-construct probe under
# test/o2_survivor_fixtures/, emit pre-`-O2` LLVM IR via `medaka build
# --keep-ir`, run `clang -O2 -S -emit-llvm` on it, extract the probe's own
# function body from the OPTIMIZED output, and report what survives,
# bucketed:
#
#   OPAQUE_CALL   — a `call`/`tail call` to an `@mdk_*` runtime or dispatch
#                   helper that -O2 did not inline away.
#   ALLOCATION    — a `call` to an allocator (`@GC_malloc`/`@mdk_*alloc*`).
#   LOAD          — a `load` instruction; flagged REDUNDANT when the same
#                   source pointer register is loaded more than once.
#   TAG_ARITH     — an `and`/`or`/`add`/`sub`/`ashr`/`shl`/`xor` on the
#                   tagged i64 representation (the collapsed case: no opaque
#                   call needed, just tag bit-twiddling).
#
# This corpus is DELIBERATELY separate from test/bench_fixtures/ (S1/S4's
# whole-program bench corpus, #2357 contract §3) — these are tiny
# single-construct probes, not benchmarks.
#
# ── IT ASSERTS NOTHING. IT IS A CENSUS, NOT A GATE. ─────────────────────────
# It always exits 0 and is listed in test/CI-COVERAGE-TOOLS.txt, not
# test/gates.toml. A probe whose build (or whose clang -O2 pass) fails
# reports MISSING for that row, never a silent zero-count line.
#
# Usage:
#   sh test/o2_survivor_census.sh          # or: make o2-survivor-census
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

BIN="$ROOT/medaka"
CORPUS="$ROOT/test/o2_survivor_fixtures"

if [ ! -x "$BIN" ]; then
  echo "o2_survivor_census: no built $BIN — run 'make medaka' first" >&2
  exit 0
fi

if ! command -v clang >/dev/null 2>&1; then
  echo "o2_survivor_census: no clang on PATH — cannot run the -O2 comparison" >&2
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Extract one function body (from its `define` line to the first line that
# is exactly a closing brace) out of an LLVM IR text file.
extract_fn() {
  file="$1"
  sym="$2"
  awk -v sym="$sym" '
    $0 ~ ("^define.*@" sym "\\(") { found = 1 }
    found { print }
    found && /^}$/ { exit }
  ' "$file"
}

n_probes=0
n_missing=0

for f in "$CORPUS"/*.mdk; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .mdk)"
  n_probes=$((n_probes + 1))
  sym="mdk_${base}__probe"
  out="$WORK/$base"

  echo "== $base (probe : @$sym) =="

  if ! MEDAKA_STRICT=1 "$BIN" build "$f" -o "$out" --keep-ir >"$WORK/$base.build.log" 2>&1; then
    echo "  MISSING — build failed:"
    sed 's/^/    /' "$WORK/$base.build.log"
    n_missing=$((n_missing + 1))
    echo
    continue
  fi

  ir="$out.ll"
  if [ ! -f "$ir" ]; then
    echo "  MISSING — build succeeded but --keep-ir produced no $ir"
    n_missing=$((n_missing + 1))
    echo
    continue
  fi

  opt="$WORK/$base.opt.ll"
  if ! clang -O2 -S -emit-llvm "$ir" -o "$opt" >"$WORK/$base.clang.log" 2>&1; then
    echo "  MISSING — clang -O2 failed:"
    sed 's/^/    /' "$WORK/$base.clang.log"
    n_missing=$((n_missing + 1))
    echo
    continue
  fi

  body="$(extract_fn "$opt" "$sym")"
  if [ -z "$body" ]; then
    echo "  MISSING — @$sym not found in the -O2 output (fully eliminated or renamed)"
    n_missing=$((n_missing + 1))
    echo
    continue
  fi

  opaque="$(printf '%s\n' "$body" | grep -E 'call[^@]*@mdk_[A-Za-z0-9_]*\(' | grep -Ev '@mdk_[A-Za-z0-9_]*alloc' || true)"
  alloc="$(printf '%s\n' "$body" | grep -E 'call[^@]*@(GC_malloc|mdk_[A-Za-z0-9_]*alloc)' || true)"
  loads="$(printf '%s\n' "$body" | grep -E '= *load ' || true)"
  n_loads=$(printf '%s\n' "$loads" | grep -c . || true)
  redundant=$(printf '%s\n' "$loads" | sed -E 's/.*, *ptr +([%A-Za-z0-9_.]+).*/\1/' | sort | uniq -d)
  arith="$(printf '%s\n' "$body" | grep -E '= *(and|or|add|sub|ashr|shl|xor) i64' || true)"
  n_arith=$(printf '%s\n' "$arith" | grep -c . || true)

  if [ -n "$opaque" ]; then
    echo "  OPAQUE_CALL survives:"
    printf '%s\n' "$opaque" | sed 's/^/    /'
  else
    echo "  OPAQUE_CALL: none"
  fi

  if [ -n "$alloc" ]; then
    echo "  ALLOCATION survives:"
    printf '%s\n' "$alloc" | sed 's/^/    /'
  else
    echo "  ALLOCATION: none"
  fi

  echo "  LOAD: $n_loads total$( [ -n "$redundant" ] && echo ", REDUNDANT pointer(s): $(printf '%s' "$redundant" | tr '\n' ' ')" )"
  echo "  TAG_ARITH: $n_arith op(s)$( [ "$n_arith" -gt 0 ] && [ -z "$opaque" ] && echo " (collapsed — no opaque call needed)" )"
  echo
done

echo "-- summary: $n_probes probe(s), $n_missing MISSING --"

exit 0
