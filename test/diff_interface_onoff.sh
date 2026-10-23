#!/bin/sh
# shell-because: instrumentation - two processes of one binary under different environments over a corpus
# diff_interface_onoff.sh - the shipped prelude interface (stdlib/core.mdki) must
# not change what `check` says. One binary, one tree; arm a sets
# MEDAKA_NO_INTERFACE=1 (typecheck the prelude), arm b loads the interface.
# `check` and `check --json` are compared on exit code, stdout and stderr, byte
# for byte, over the five rejected-program corpora plus a 400-entry sample of
# the rest of test/*.mdk. The sample is derived at run time (LC_ALL=C sort,
# seeded stride) so no committed list enrols this gate in every corpus directory.
#
# Positive control first: a comparison between two arms that both skip the
# interface passes vacuously, so the gate FAILS unless the on arm demonstrably
# loads it (`interface verify` says fresh, and hello's typecheck.module count is
# one below the off arm's). That also covers `make medaka` leaving a fresh
# stdlib/core.mdki at the repo root.
#
# Env: JOBS (parallelism, default 8), SEED (sample seed, default 20261022).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/medaka"
JOBS="${JOBS:-8}"
SEED="${SEED:-20261022}"
WANT=400
unset MEDAKA_STRICT MEDAKA_EMITTER MEDAKA_PRELUDE_OBJ MEDAKA_NO_INTERFACE MEDAKA_STAGE_COUNTS 2>/dev/null || true
export MEDAKA_ROOT="$ROOT"

fail() { echo "FAIL: $*"; exit 1; }

[ -x "$M" ] || fail "$M is not built"
[ -f "$ROOT/stdlib/core.mdki" ] || fail "interface not loaded: $ROOT/stdlib/core.mdki is missing"
V=$(timeout 120 "$M" interface verify "$ROOT/stdlib/core.mdk" 2>&1)
[ "$V" = fresh ] || fail "interface not loaded: interface verify said '$V', not 'fresh'"

HELLO="$ROOT/test/stage_count_fixtures/hello.mdk"
count() {
  env "$1" MEDAKA_STAGE_COUNTS=1 timeout 120 "$M" check "$HELLO" 2>&1 | awk -F'\t' '$2 == "typecheck.module" { print $3 }'
}
CON=$(count MEDAKA_ON=1)
COFF=$(count MEDAKA_NO_INTERFACE=1)
case "$CON$COFF" in
  ''|*[!0-9]*) fail "interface not loaded: no typecheck.module counts (on='$CON' off='$COFF')" ;;
esac
[ $((CON + 1)) -eq "$COFF" ] || fail "interface not loaded: typecheck.module on=$CON off=$COFF, want off = on + 1"

OUT=$(mktemp -d "${TMPDIR:-/tmp}/onoff.XXXXXX") || fail "mktemp"
trap 'rm -rf "$OUT"' EXIT
LIST="$OUT/entries"
: > "$LIST"
for c in test/error_quality_fixtures test/check_json_fixtures test/typecheck_error_fixtures test/must_fail_fixtures; do
  find "$ROOT/$c" -name '*.mdk' -type f | LC_ALL=C sort >> "$LIST"
done
for e in "$ROOT"/test/run_check_agreement_fixtures/*.expected; do
  if head -n 1 "$e" | grep -q '^REJECT'; then
    echo "${e%.expected}.mdk" >> "$LIST"
  fi
done
NFIVE=$(wc -l < "$LIST")
find "$ROOT/test" -name '*.mdk' -type f \
  | grep -v -E '/test/(error_quality_fixtures|check_json_fixtures|typecheck_error_fixtures|must_fail_fixtures|run_check_agreement_fixtures)/' \
  | grep -v '_test\.mdk$' | LC_ALL=C sort > "$OUT/rest"
awk -v want="$WANT" -v seed="$SEED" '
  { line[NR] = $0 }
  END {
    stride = int(NR / want); if (stride < 1) stride = 1
    off = seed % stride
    n = 0
    for (i = 1 + off; i <= NR && n < want; i += stride) { print line[i]; n++ }
  }' "$OUT/rest" >> "$LIST"
N=$(wc -l < "$LIST")

cat > "$OUT/one.sh" <<'EOS'
#!/bin/sh
arm="$1"; entry="$2"; pre="$3"
cd "$(dirname "$entry")" || exit 99
if [ "$arm" = a ]; then export MEDAKA_NO_INTERFACE=1; fi
timeout 120 "$M" check "$entry" > "$pre.out" 2> "$pre.err"
echo $? > "$pre.code"
timeout 120 "$M" check --json "$entry" > "$pre.json" 2> "$pre.jerr"
echo $? > "$pre.jcode"
EOS
export M
n=0
: > "$OUT/jobs"
while IFS= read -r e; do
  n=$((n + 1))
  printf '%s %s %s\n' a "$e" "$OUT/a.$n" >> "$OUT/jobs"
  printf '%s %s %s\n' b "$e" "$OUT/b.$n" >> "$OUT/jobs"
done < "$LIST"
xargs -P "$JOBS" -L 1 sh "$OUT/one.sh" < "$OUT/jobs"

bad=0; rej=0; i=0
: > "$OUT/DIFFS"
while [ "$i" -lt "$n" ]; do
  i=$((i + 1))
  same=1
  for k in code out err json jerr jcode; do
    if [ -f "$OUT/a.$i.$k" ] && [ -f "$OUT/b.$i.$k" ]; then
      cmp -s "$OUT/a.$i.$k" "$OUT/b.$i.$k" || same=0
    else
      same=0
    fi
  done
  [ "$(cat "$OUT/a.$i.code" 2>/dev/null)" != 0 ] && rej=$((rej + 1))
  if [ "$same" = 0 ]; then
    bad=$((bad + 1))
    echo "$i $(sed -n "${i}p" "$LIST")" >> "$OUT/DIFFS"
  fi
done
echo "on/off: $N entries ($NFIVE in the five corpora), $rej rejected (off exit /= 0), $bad differ"
if [ "$bad" -ne 0 ]; then
  head -20 "$OUT/DIFFS"
  fail "parity differences between interface on and off"
fi
[ "$rej" -gt 0 ] || fail "no rejected entries; the corpora were not found"
echo PASS
