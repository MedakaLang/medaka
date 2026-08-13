#!/bin/sh
# Re-run the Phase 3' sprint's in-passing findings against any medaka binary.
#
#   sh .claude/sprint-phase3/repro/run.sh [path-to-medaka]
#
# Defaults to the binary beside the repo root. Exit codes are read from
# redirects, never from a pipe (`medaka build`'s status does not survive one).
# MEDAKA_STRICT=1 turns a stale-binary warning into a hard failure, so this
# cannot silently grade an old binary.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
M=${1:-$ROOT/medaka}
export MEDAKA_STRICT=1
OUT=$(mktemp -d)

echo "binary: $M"
echo

echo "=== F-1  prelude method-name collision (#1450 cell)"
echo "    expect: zub correct on both arms; sub run=2 but the BINARY prints a leaked pointer"
for n in zub sub; do
  "$M" check "$HERE/f1_prelude_name/$n.mdk" > "$OUT/$n.check" 2>&1; c=$?
  "$M" run   "$HERE/f1_prelude_name/$n.mdk" > "$OUT/$n.run"   2>&1; r=$?
  "$M" build "$HERE/f1_prelude_name/$n.mdk" -o "$OUT/$n.bin"  > "$OUT/$n.build" 2>&1; b=$?
  if [ -x "$OUT/$n.bin" ]; then "$OUT/$n.bin" > "$OUT/$n.exec" 2>&1; e=$?; x="[$(cat "$OUT/$n.exec")]"; else e=NOBIN; x=""; fi
  echo "    $n: check=$c run=$r [$(cat "$OUT/$n.run")] build=$b exec=$e $x"
done
echo

echo "=== F-2  function-typed impl head in the noneHeadTag bucket"
echo "    expect: ab=(5,5) ba=(9,9) both WRONG at exit 0, build E-PANICs; ctl=(5,9) correct"
for n in ab ba ctl; do
  "$M" check "$HERE/f2_fnhead/$n.mdk" > "$OUT/$n.check" 2>&1; c=$?
  "$M" run   "$HERE/f2_fnhead/$n.mdk" > "$OUT/$n.run"   2>&1; r=$?
  "$M" build "$HERE/f2_fnhead/$n.mdk" -o "$OUT/$n.bin"  > "$OUT/$n.build" 2>&1; b=$?
  if [ -x "$OUT/$n.bin" ]; then "$OUT/$n.bin" > "$OUT/$n.exec" 2>&1; e=$?; x="[$(cat "$OUT/$n.exec")]"; else e=NOBIN; x=""; fi
  echo "    $n: check=$c run=$r [$(cat "$OUT/$n.run")] build=$b exec=$e $x"
done
echo
echo "scratch: $OUT"
