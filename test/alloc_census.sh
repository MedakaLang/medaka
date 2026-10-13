#!/bin/sh
# alloc_census.sh -- report-only census, always exits 0 (`make alloc-census`).
#
# Counts heap allocations of `medaka check compiler/driver/medaka_cli.mdk` by
# pointer fate (#4027 allocate-what-it-keeps, #2357 emitted-IR instrument, #503
# item 3 allocation census). Steps:
#   1. build the CLI with --keep-ir and MEDAKA_NO_LTO=1 (a non-LTO build, so
#      the IR is whole and unmerged);
#   2. clang -O2 the kept IR;
#   3. test/alloc_census/escape.py classifies every mdk_alloc/mdk_alloc_atomic
#      site (stays local / escapes only into callee params that don't keep it /
#      returned / stored / unknown call) and rewrites each into a counted call;
#   4. run `check` with the plain and the instrumented binary; the stdout of
#      the two must be byte identical, else the run is labelled INVALID;
#   5. report allocations by class x kind x function, runtime (C) callers, and
#      mdk_string_append / mdk_list_append / mdk_append call counts by caller.
#
# escape.py is a lower bound on "does not escape" (limits in its header): a
# misclassification errs toward "escapes", never toward "free". Counts are of
# the -O2 IR, i.e. after LLVM's own deletions.
#
# Env: MEDAKA_TREE (default: this repo root; needs a built ./medaka),
#      CENSUS_WORK (default: a fresh dir under $TMPDIR), CENSUS_REUSE=1 to
#      reuse a build from CENSUS_WORK (refused unless made at this HEAD + diff),
#      CENSUS_RT (runtime C file to instrument; default runtime/medaka_rt.c).
#      Needs clang, python3, pkg-config bdw-gc. Linux and macOS; macOS skips C-runtime caller symbolization.
set -u
D=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
H="$D/alloc_census"
WT=${MEDAKA_TREE:-$(CDPATH= cd -- "$D/.." && pwd)}
S=${CENSUS_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/alloc_census.XXXXXX")}
TARGET=compiler/driver/medaka_cli.mdk
mkdir -p "$S/cli" "$S/app"
echo "alloc-census: tree=$WT work=$S"
echo "alloc-census: base=$(git -C "$WT" rev-parse HEAD 2>/dev/null)"

fail() { echo "alloc-census: SKIPPED ($1); report-only census, exiting 0"; exit 0; }

[ -x "$WT/medaka" ] || fail "no built $WT/medaka"
command -v clang >/dev/null 2>&1 || fail "no clang"
command -v python3 >/dev/null 2>&1 || fail "no python3"
GCF=$(pkg-config --cflags bdw-gc 2>/dev/null)
GCL=$(pkg-config --libs bdw-gc 2>/dev/null)
[ -n "$GCL" ] || fail "no bdw-gc via pkg-config"

if [ "$(uname -s)" = Darwin ]; then
  PIE=""; SYM=nosym
  echo "alloc-census: note: macOS, skipping C-runtime caller symbolization (addr2line, non-PIE)"
else
  PIE="-no-pie -fno-pie"; SYM=sym
  command -v addr2line >/dev/null 2>&1 || SYM=nosym
fi

# Identity of the source a build came from: HEAD plus the uncommitted diff.
stamp() { printf '%s %s' "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" "$(git -C "$WT" diff HEAD 2>/dev/null | cksum | cut -d' ' -f1)"; }
if [ "${CENSUS_REUSE:-0}" = 1 ] && [ -f "$S/cli/medaka.opt.ll" ] && [ -x "$S/cli/medaka" ]; then
  if [ "$(cat "$S/cli/built.stamp" 2>/dev/null)" != "$(stamp)" ]; then
    echo "alloc-census: INVALID (reused build in $S/cli is from '$(cat "$S/cli/built.stamp" 2>/dev/null)', tree is at '$(stamp)'); rebuild without CENSUS_REUSE"
    exit 0
  fi
  echo "alloc-census: reusing $S/cli/medaka.opt.ll"
else
  echo "alloc-census: [1/5] building non-LTO CLI with --keep-ir"
  (cd "$WT" && MEDAKA_NO_LTO=1 ./medaka build "$TARGET" --allow-internal --keep-ir -o "$S/cli/medaka") > "$S/cli/build.log" 2>&1 \
    || { tail -8 "$S/cli/build.log"; fail "CLI build failed"; }
  [ -f "$S/cli/medaka.ll" ] || fail "--keep-ir left no $S/cli/medaka.ll"
  echo "alloc-census: [2/5] clang -O2 over the kept IR"
  clang -O2 -S -emit-llvm "$S/cli/medaka.ll" -o "$S/cli/medaka.opt.ll" 2> "$S/cli/opt.err" \
    || { tail -8 "$S/cli/opt.err"; fail "clang -O2 failed"; }
  stamp > "$S/cli/built.stamp"
fi

echo "alloc-census: [3/5] classifying sites and linking the instrumented CLI"
python3 -I "$H/escape.py" "$S/cli/medaka.opt.ll" "$S/cli/medaka.inst.ll" "$S/cli/sites.tsv" 2> "$S/cli/escape.err" \
  || { tail -8 "$S/cli/escape.err"; fail "escape.py failed"; }
N=$(( $(wc -l < "$S/cli/sites.tsv") - 1 ))
# alloc_count.c supplies the allocator definitions, so drop the runtime's own
if ! sh "$H/rt_copy.sh" "${CENSUS_RT:-$WT/runtime/medaka_rt.c}" "$S/cli/rt_copy.c"; then
  echo "alloc-census: INVALID (runtime/medaka_rt.c allocator definitions changed)"
  exit 1
fi
# shellcheck disable=SC2086
clang -O2 $PIE -pthread $GCF -DNSITES="$N" -I"$WT/runtime" \
  "$S/cli/medaka.inst.ll" "$S/cli/rt_copy.c" "$H/alloc_count.c" $GCL -lm -o "$S/cli/medaka_inst" 2> "$S/cli/link.err" \
  || { tail -12 "$S/cli/link.err"; fail "instrumented link failed"; }
echo "alloc-census: NSITES=$N"

echo "alloc-census: [4/5] check of $TARGET: plain vs instrumented"
cd "$WT" || exit 0
export MEDAKA_ROOT="$WT"
"$S/cli/medaka" check "$TARGET" > "$S/cli/check.plain.out" 2> "$S/cli/check.plain.err"
PRC=$?
echo "plain rc=$PRC"
ALLOC_COUNT_OUT="$S/cli/check.counts" "$S/cli/medaka_inst" check "$TARGET" > "$S/cli/check.inst.out" 2> "$S/cli/check.inst.err"
IRC=$?
echo "instrumented rc=$IRC"
sh "$H/compare.sh" "$S/cli/check.plain.out" "$S/cli/check.inst.out" "$PRC" "$IRC"
if command -v perf >/dev/null 2>&1; then
  perf stat -x, -e instructions -o "$S/cli/perf.txt" "$S/cli/medaka" check "$TARGET" > /dev/null 2>&1
  echo "plain check instructions (perf stat): $(awk -F, '/instructions/ {print $1}' "$S/cli/perf.txt")"
else
  echo "plain check instructions: perf not available, skipped"
fi

echo
python3 -I "$H/report.py" "$S/cli/sites.tsv" "$S/cli/check.counts" "$S/cli/medaka_inst" "$SYM" \
  || echo "alloc-census: report.py failed (no counts?)"

echo
echo "alloc-census: [5/5] append call counts by caller"
python3 -I "$H/appends.py" "$S/cli/medaka.opt.ll" "$S/app/medaka.app.ll" "$S/app/append_sites.tsv" 2> "$S/app/appends.err"
NA=$(wc -l < "$S/app/append_sites.tsv")
# shellcheck disable=SC2086
if clang -O2 -pthread $GCF -w -DNSITES="$NA" "$S/app/medaka.app.ll" "$WT/runtime/medaka_rt.c" "$H/append_count.c" $GCL -lm -o "$S/app/medaka_app" 2> "$S/app/link.err"; then
  APPEND_COUNT_OUT="$S/app/append.counts" "$S/app/medaka_app" check "$TARGET" > /dev/null 2>&1
  python3 -I "$H/append_report.py" "$S/app/append_sites.tsv" "$S/app/append.counts"
else
  tail -8 "$S/app/link.err"
  echo "alloc-census: append instrumentation link failed; skipped"
fi
echo
echo "alloc-census: done (report-only, exit 0); work dir $S"
exit 0
