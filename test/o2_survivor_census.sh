#!/bin/sh
# o2_survivor_census.sh — report-only census over the S2-o2-survivor-report
# corpus (#2357, LLVM arm): for each single-construct probe under
# test/o2_survivor_fixtures/, emit pre-`-O2` LLVM IR via `medaka build
# --keep-ir`, run `clang -O2 -S -emit-llvm` on it, extract the probe's own
# function body from the OPTIMIZED output, and report what survives,
# bucketed:
#
#   OPAQUE_CALL   — a `call`/`tail call` to an `@mdk_*` runtime or `@mdk.dispatch.*` dispatch
#                   helper (`runtime/medaka_rt.c`) that -O2 did not inline
#                   away. Excludes calls to module-qualified user functions
#                   (encoded `@mdk.user.<hex>`; legacy `@mdk_<module>__<name>`
#                   calls are also excluded) — a surviving user-fn call is
#                   not counted here.
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
# test/gates.toml.
#
# A probe that never reaches the OPAQUE_CALL/ALLOCATION/LOAD/TAG_ARITH report
# lands in one of two DISTINCT rows (#2521) — never a single generic MISSING
# bucket, because the two outcomes mean opposite things:
#
#   BUILD_FAILED  — `medaka build` itself failed, `--keep-ir` produced no
#                   output, or `clang -O2` failed on the emitted IR. An
#                   infra/tooling failure: bad, worth investigating.
#   ELIMINATED    — the build and the -O2 pass both succeeded, but the
#                   probe's own symbol is absent from the optimized output
#                   (fully eliminated or renamed). For a probe whose whole
#                   point is testing whether -O2 can remove a construct
#                   entirely, this is the OPTIMAL outcome: good, not bad.
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
    /^define/ && index($0, "@" sym "(") { found = 1 }
    found { print }
    found && /^}$/ { exit }
  ' "$file"
}

n_probes=0
n_build_failed=0
n_eliminated=0

for f in "$CORPUS"/*.mdk; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .mdk)"
  n_probes=$((n_probes + 1))
  sym="$(python3 -c 'import sys; m = sys.argv[1]; print("mdk.user." + ("m" + m.encode().hex() + "__probe").encode().hex())' "$base")"
  sym="${O2_CENSUS_SELECTOR_OVERRIDE:-$sym}"
  out="$WORK/$base"

  echo "== $base (probe : @$sym) =="

  if ! MEDAKA_STRICT=1 "$BIN" build "$f" -o "$out" --keep-ir >"$WORK/$base.build.log" 2>&1; then
    echo "  BUILD_FAILED — build failed:"
    sed 's/^/    /' "$WORK/$base.build.log"
    n_build_failed=$((n_build_failed + 1))
    echo
    continue
  fi

  ir="$out.ll"
  if [ ! -f "$ir" ]; then
    echo "  BUILD_FAILED — build succeeded but --keep-ir produced no $ir"
    n_build_failed=$((n_build_failed + 1))
    echo
    continue
  fi

  # A whole-mode build emits every function `internal`, and -O2 deletes an
  # internal probe once it is inlined into main, which would read as
  # ELIMINATED for every probe. Give the probe alone external linkage so its
  # optimized body survives to be measured.
  if ! python3 - "$ir" "$sym" <<'PYCODE'
import re, sys
text = open(sys.argv[1]).read()
names = re.findall(r'^define\s+[^\n]*@([^ (]+)\(', text, re.M)
probes = []
for name in names:
    if name.startswith('mdk.user.'):
        try:
            logical = bytes.fromhex(name[9:]).decode('utf-8')
        except (ValueError, UnicodeDecodeError):
            continue
        if re.fullmatch(r'm(?:[0-9a-f]{2})*__probe', logical):
            probes.append(name)
if probes and sys.argv[2] not in probes:
    print('selector mismatch: expected ' + sys.argv[2] + ', found ' + ', '.join(probes), file=sys.stderr)
    sys.exit(1)
PYCODE
  then
    echo "  BUILD_FAILED — selector mismatch in emitted IR"
    n_build_failed=$((n_build_failed + 1))
    echo
    continue
  fi
  awk -v sym="$sym" 'index($0, "define internal ") == 1 && index($0, "@" sym "(") { sub(/^define internal /, "define ") } { print }' "$ir" > "$WORK/$base.ext.ll"
  opt="$WORK/$base.opt.ll"
  if ! clang -O2 -S -emit-llvm "$WORK/$base.ext.ll" -o "$opt" >"$WORK/$base.clang.log" 2>&1; then
    echo "  BUILD_FAILED — clang -O2 failed:"
    sed 's/^/    /' "$WORK/$base.clang.log"
    n_build_failed=$((n_build_failed + 1))
    echo
    continue
  fi

  body="$(extract_fn "$opt" "$sym")"
  if [ -z "$body" ] && grep -F "@$sym(" "$ir" >/dev/null; then
    echo "  BUILD_FAILED — selected definition missing from optimized output"
    n_build_failed=$((n_build_failed + 1))
    echo
    continue
  fi
  if [ -z "$body" ]; then
    echo "  ELIMINATED — @$sym not found in the -O2 output (fully eliminated or renamed) — optimal, not a failure"
    n_eliminated=$((n_eliminated + 1))
    echo
    continue
  fi

  opaque="$(printf '%s\n' "$body" | grep -E 'call[^@]*@(mdk_[A-Za-z0-9_]*|"?mdk\.dispatch\.[0-9a-f]*\.[0-9a-f]*\.[0-9]+\.[0-9]+\.[0-9]+"?)\(' | grep -Ev '@mdk_[A-Za-z0-9_]*alloc' | grep -Ev '@mdk_[A-Za-z0-9_]*__[A-Za-z0-9_]*\(' || true)"
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

echo "-- summary: $n_probes probe(s), $n_build_failed BUILD_FAILED, $n_eliminated ELIMINATED --"

exit 0
