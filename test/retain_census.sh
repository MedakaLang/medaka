#!/bin/sh
# retain_census.sh -- report-only census, always exits 0 (`make retain-census`).
#
# What `medaka check compiler/driver/medaka_cli.mdk` keeps LIVE, by the site that
# allocated it (#4090). Boehm's marking cost grows with the live set it re-marks
# at each collection, and Boehm has no type information, so every allocation is
# tagged instead:
#   1. build the CLI with --keep-ir and MEDAKA_NO_LTO=1, clang -O2 the IR;
#   2. test/alloc_census/escape.py numbers every mdk_alloc site (sites.tsv) and
#      append_sites.py numbers every `++` call site (appsites.tsv);
#   3. link against retain_count.c, which gives each object a hidden header word
#      naming its site, and every RETAIN_STEP bytes allocated forces a collection
#      and sums reachable bytes per site;
#   4. run `check` with the plain and the instrumented binary; their stdout must
#      be byte identical, else the run is labelled INVALID;
#   5. report the live series and, at three points, live bytes by allocating
#      function and by module (retain_report.py).
#
# The header adds 8 bytes to every object, so live bytes read high by about
# 8 x the object count; compare sites with each other, not with GC_PRINT_STATS.
#
# "Who holds it": RETAIN_REF_SITES=<ids> (sites.tsv rows) and/or
# RETAIN_REF_APP=<ids> (appsites.tsv rows) make each census also count, per
# referrer site, the fields that point into those objects. Follow a chain by
# re-running with the top referrer as the next target (RETAIN_REUSE=1 skips the
# build).
#
# Env: MEDAKA_TREE (default: this repo root; needs a built ./medaka),
#      RETAIN_WORK (default: a fresh dir under $TMPDIR), RETAIN_REUSE=1 to reuse
#      the build in RETAIN_WORK (refused unless made at this HEAD + diff),
#      RETAIN_STEP (bytes between censuses, default 1000000000),
#      RETAIN_REF_SITES / RETAIN_REF_APP (comma-separated ids, see above).
#      Needs clang, python3, pkg-config bdw-gc. Linux; macOS skips runtime-caller
#      symbolization (addr2line, non-PIE).
set -u
D=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
H="$D/alloc_census"
WT=${MEDAKA_TREE:-$(CDPATH= cd -- "$D/.." && pwd)}
S=${RETAIN_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/retain_census.XXXXXX")}
TARGET=compiler/driver/medaka_cli.mdk
mkdir -p "$S"
echo "retain-census: tree=$WT work=$S"

fail() { echo "retain-census: SKIPPED ($1); report-only census, exiting 0"; exit 0; }

[ -x "$WT/medaka" ] || fail "no built $WT/medaka"
command -v clang >/dev/null 2>&1 || fail "no clang"
command -v python3 >/dev/null 2>&1 || fail "no python3"
GCF=$(pkg-config --cflags bdw-gc 2>/dev/null)
GCL=$(pkg-config --libs bdw-gc 2>/dev/null)
[ -n "$GCL" ] || fail "no bdw-gc via pkg-config"
if [ "$(uname -s)" = Darwin ]; then PIE=""; else PIE="-no-pie -fno-pie"; fi

stamp() { printf '%s %s' "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" "$(git -C "$WT" diff HEAD 2>/dev/null | cksum | cut -d' ' -f1)"; }
if [ "${RETAIN_REUSE:-0}" = 1 ] && [ -x "$S/medaka_retain" ]; then
  if [ "$(cat "$S/built.stamp" 2>/dev/null)" != "$(stamp)" ]; then
    echo "retain-census: INVALID (reused build in $S is from '$(cat "$S/built.stamp" 2>/dev/null)', tree is at '$(stamp)'); rebuild without RETAIN_REUSE"
    exit 0
  fi
  echo "retain-census: reusing $S/medaka_retain"
else
  echo "retain-census: [1/4] building the non-LTO CLI with --keep-ir, clang -O2"
  (cd "$WT" && MEDAKA_NO_LTO=1 ./medaka build "$TARGET" --allow-internal --keep-ir -o "$S/medaka") > "$S/build.log" 2>&1 \
    || { tail -8 "$S/build.log"; fail "CLI build failed"; }
  [ -f "$S/medaka.ll" ] || fail "--keep-ir left no $S/medaka.ll"
  clang -O2 -S -emit-llvm "$S/medaka.ll" -o "$S/medaka.opt.ll" 2> "$S/opt.err" \
    || { tail -8 "$S/opt.err"; fail "clang -O2 failed"; }
  echo "retain-census: [2/4] numbering allocation and ++ sites"
  python3 -I "$H/escape.py" "$S/medaka.opt.ll" "$S/medaka.inst.ll" "$S/sites.tsv" 2> "$S/escape.err" \
    || { tail -8 "$S/escape.err"; fail "escape.py failed"; }
  python3 -I "$H/append_sites.py" "$S/medaka.inst.ll" "$S/medaka.app.ll" "$S/appsites.tsv" 2> "$S/append.err" \
    || { tail -8 "$S/append.err"; fail "append_sites.py failed"; }
  [ "$(wc -l < "$S/appsites.tsv")" -le 16384 ] || fail "more ++ sites than retain_count.c's APP_SLOTS"
  if ! sh "$H/rt_copy.sh" "$WT/runtime/medaka_rt.c" "$S/rt_copy.c"; then
    echo "retain-census: INVALID (runtime/medaka_rt.c allocator definitions changed)"
    exit 0
  fi
  N=$(( $(wc -l < "$S/sites.tsv") - 1 ))
  echo "retain-census: [3/4] linking the instrumented CLI (NSITES=$N)"
  # shellcheck disable=SC2086
  clang -O2 $PIE -pthread $GCF -w -DNSITES="$N" -I"$WT/runtime" \
    "$S/medaka.app.ll" "$S/rt_copy.c" "$H/retain_count.c" $GCL -lm -o "$S/medaka_retain" 2> "$S/link.err" \
    || { tail -12 "$S/link.err"; fail "instrumented link failed"; }
  stamp > "$S/built.stamp"
fi

echo "retain-census: [4/4] check of $TARGET: plain vs instrumented"
cd "$WT" || exit 0
export MEDAKA_ROOT="$WT"
GC_MARKERS=1 "$S/medaka" check "$TARGET" > "$S/check.plain.out" 2> "$S/check.plain.err"
PRC=$?
GC_MARKERS=1 RETAIN_OUT="$S/retain.out" "$S/medaka_retain" check "$TARGET" > "$S/check.inst.out" 2> "$S/check.inst.err"
IRC=$?
sh "$H/compare.sh" "$S/check.plain.out" "$S/check.inst.out" "$PRC" "$IRC"
echo
python3 -I "$H/retain_report.py" "$S" || echo "retain-census: retain_report.py failed (no censuses?)"
echo
echo "retain-census: done (report-only, exit 0); work dir $S"
exit 0
