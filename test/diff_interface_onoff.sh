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
# The stdlib/core.mdke half (the tree arm: `run`, `build`, `test`, `repl`,
# `check-policy`, `manifest`) follows the check-family half, with its own
# positive control (`run hello` typechecks one module fewer) and the fallback
# rows: an altered, truncated, foreign-version, missing or disabled core.mdke in
# a scratch MEDAKA_ROOT must give the disabled arm's output plus at most one
# stale notice.
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

# ---------------------------------------------------------------------------
# The tree arm: stdlib/core.mdke seeds the elaborated prelude into `run`,
# `build`, `test`, `repl`, `check-policy` and `manifest`. Arm a is
# MEDAKA_NO_INTERFACE=1, arm b loads the files (with MEDAKA_STRICT=1 on arm b
# only, so a stale file fails loudly rather than falling back to arm a's path).
# Env: EWANT (engines entries, default 60), TWANT (sampled *_test.mdk, default 4).
# ---------------------------------------------------------------------------
EWANT="${EWANT:-60}"
TWANT="${TWANT:-4}"
FIX="$ROOT/test/stage_count_fixtures"

# sample WANT: seeded stride sample of the sorted lines on stdin.
sample() {
  awk -v want="$1" -v seed="$SEED" '
    { line[NR] = $0 }
    END {
      stride = int(NR / want); if (stride < 1) stride = 1
      off = seed % stride
      n = 0
      for (i = 1 + off; i <= NR && n < want; i += stride) { print line[i]; n++ }
    }'
}

# Positive control for the tree arm: the on arm's `run hello` typechecks one
# module fewer (core is not elaborated).
runcount() {
  env "$1" MEDAKA_STAGE_COUNTS=1 timeout 120 "$M" run "$HELLO" 2>&1 >/dev/null | awk -F'\t' '$2 == "typecheck.module" { print $3 }'
}
RON=$(runcount MEDAKA_ON=1)
ROFF=$(runcount MEDAKA_NO_INTERFACE=1)
for c in "$RON" "$ROFF"; do
  case "$c" in
    ''|*[!0-9]*) fail "tree arm not loaded: no run typecheck.module count (on='$RON' off='$ROFF'); a run that fails on the tree arm prints none" ;;
  esac
done
[ $((RON + 1)) -eq "$ROFF" ] || fail "tree arm not loaded: run hello typecheck.module on=$RON off=$ROFF, want off = on + 1"

# Engines corpora: run, then build and run the binary.
: > "$OUT/eall"
for c in test/engine_fixtures test/llvm_fixtures test/llvm_fixtures_typed test/wasm/fixtures test/wasm/fixtures_typed; do
  find "$ROOT/$c" -maxdepth 1 -name '*.mdk' -type f >> "$OUT/eall"
done
for sub in "$ROOT"/test/llvm_fixtures_modules/*/; do
  [ -f "${sub}main.mdk" ] && echo "${sub}main.mdk" >> "$OUT/eall"
done
LC_ALL=C sort "$OUT/eall" | sample "$EWANT" > "$OUT/elist"
EN=$(wc -l < "$OUT/elist")

cat > "$OUT/eone.sh" <<'EOS'
#!/bin/sh
arm="$1"; entry="$2"; pre="$3"
cd "$(dirname "$entry")" || exit 99
if [ "$arm" = a ]; then export MEDAKA_NO_INTERFACE=1; else export MEDAKA_STRICT=1; fi
timeout 60 "$M" run "$entry" > "$pre.out" 2> "$pre.err" < /dev/null
echo $? > "$pre.code"
timeout 120 "$M" build "$entry" -o "$pre.bin" > "$pre.bout" 2> "$pre.berr" < /dev/null
echo $? > "$pre.bcode"
if [ -x "$pre.bin" ]; then
  timeout 60 "$pre.bin" > "$pre.xout" 2> "$pre.xerr" < /dev/null
  echo $? > "$pre.xcode"
  rm -f "$pre.bin"
fi
sed -i "s#$pre\.bin#BIN#g" "$pre.bout" "$pre.berr"
EOS
n=0
: > "$OUT/ejobs"
while IFS= read -r e; do
  n=$((n + 1))
  printf '%s %s %s\n' a "$e" "$OUT/ea.$n" >> "$OUT/ejobs"
  printf '%s %s %s\n' b "$e" "$OUT/eb.$n" >> "$OUT/ejobs"
done < "$OUT/elist"
xargs -P "$JOBS" -L 1 sh "$OUT/eone.sh" < "$OUT/ejobs"

ebad=0; erun=0; i=0
: > "$OUT/EDIFFS"
while [ "$i" -lt "$n" ]; do
  i=$((i + 1))
  same=1
  for k in code out err bcode bout berr xcode xout xerr; do
    if [ -f "$OUT/ea.$i.$k" ] || [ -f "$OUT/eb.$i.$k" ]; then
      cmp -s "$OUT/ea.$i.$k" "$OUT/eb.$i.$k" || same=0
    fi
  done
  [ "$(cat "$OUT/ea.$i.code" 2>/dev/null)" = 0 ] && erun=$((erun + 1))
  if [ "$same" = 0 ]; then
    ebad=$((ebad + 1))
    echo "$i $(sed -n "${i}p" "$OUT/elist")" >> "$OUT/EDIFFS"
  fi
done
echo "on/off run+build: $EN engines entries, $erun run exit 0, $ebad differ"
if [ "$ebad" -ne 0 ]; then
  head -20 "$OUT/EDIFFS"
  fail "parity differences between tree arm on and off (run / build)"
fi
[ "$erun" -gt 0 ] || fail "no engines entry ran; the corpora were not found"

# test (native and --engines eval), check-policy, manifest, repl.
find "$ROOT/test" -name '*_test.mdk' -type f | LC_ALL=C sort | sample "$TWANT" > "$OUT/tlist"
: > "$OUT/probes"
for f in doc docimp props_doc arbitrary t_only test_probe; do
  echo "test_native_$f test $FIX/$f.mdk" >> "$OUT/probes"
  echo "test_eval_$f test --engines eval $FIX/$f.mdk" >> "$OUT/probes"
done
t=0
while IFS= read -r f; do
  t=$((t + 1))
  echo "test_native_s$t test $f" >> "$OUT/probes"
  echo "test_eval_s$t test --engines eval $f" >> "$OUT/probes"
done < "$OUT/tlist"
{
  echo "run_async run $FIX/async_main.mdk"
  echo "checkpolicy check-policy $FIX/hello.mdk"
  echo "manifest manifest $FIX/hello.mdk"
  echo "repl repl"
} >> "$OUT/probes"
printf '1 + 1\n' > "$OUT/repl.in"

cat > "$OUT/mone.sh" <<'EOS'
#!/bin/sh
arm="$1"; name="$2"; shift 2
cd "$FIX" || exit 99
if [ "$arm" = a ]; then export MEDAKA_NO_INTERFACE=1; else export MEDAKA_STRICT=1; fi
timeout 300 "$M" "$@" > "$OUT/m.$arm.$name.out" 2> "$OUT/m.$arm.$name.err" < "$OUT/repl.in"
echo $? > "$OUT/m.$arm.$name.code"
EOS
export FIX OUT
mn=0
: > "$OUT/mjobs"
while IFS= read -r line; do
  mn=$((mn + 1))
  printf 'a %s\nb %s\n' "$line" "$line" >> "$OUT/mjobs"
done < "$OUT/probes"
xargs -P "$JOBS" -L 1 sh "$OUT/mone.sh" < "$OUT/mjobs"
mbad=0
while IFS= read -r line; do
  name=${line%% *}
  for k in out err code; do
    cmp -s "$OUT/m.a.$name.$k" "$OUT/m.b.$name.$k" || { mbad=$((mbad + 1)); echo "DIFF $name $k"; }
  done
done < "$OUT/probes"
echo "on/off test/check-policy/manifest/repl: $mn probes, $mbad differing streams"
[ "$mbad" -eq 0 ] || fail "parity differences between tree arm on and off (test / misc verbs)"

# Fallback rows. Each runs in a scratch MEDAKA_ROOT whose stdlib/core.mdke is
# altered (the tree's own file is never touched). A stale file must give the
# disabled arm's output plus exactly one notice; missing and disabled are silent.
FB="$OUT/fb"
mkdir -p "$FB"
DOC="$FIX/doc.mdk"

mkroot() {
  r="$FB/root.$1"
  mkdir -p "$r"
  cp -r "$ROOT/stdlib" "$r/stdlib"
  cp -r "$ROOT/compiler" "$r/compiler"
  ln -s "$ROOT/runtime" "$r/runtime"
}

# fbrow NAME ENVASSIGN: every verb under the scratch root; results in $FB/NAME/.
fbrow() {
  name=$1; envx=$2; r="$FB/root.$name"; o="$FB/$name"
  mkdir -p "$o"
  e() { env MEDAKA_ROOT="$r" "$envx" "$@"; }
  e "$M" run "$HELLO" > "$o/run.out" 2> "$o/run.err" < /dev/null; echo $? > "$o/run.code"
  e MEDAKA_STAGE_COUNTS=1 "$M" run "$HELLO" 2>&1 > /dev/null < /dev/null | awk -F'\t' '$2 == "typecheck.module" { print $3 }' > "$o/run.stage"
  e "$M" run --json "$HELLO" > "$o/runj.out" 2> "$o/runj.err" < /dev/null; echo $? > "$o/runj.code"
  e MEDAKA_STRICT=1 "$M" run "$HELLO" > "$o/runs.out" 2> "$o/runs.err" < /dev/null; echo $? > "$o/runs.code"
  e "$M" build "$HELLO" -o "$o/bin" > "$o/build.out" 2> "$o/build.err" < /dev/null; echo $? > "$o/build.code"
  sed -i "s#$o/bin#BIN#g" "$o/build.out" "$o/build.err"
  "$o/bin" > "$o/bin.out" 2>&1 < /dev/null; echo $? > "$o/bin.code"; rm -f "${o:?}/bin"
  e "$M" build --json "$HELLO" -o "$o/binj" > "$o/buildj.out" 2> "$o/buildj.err" < /dev/null; echo $? > "$o/buildj.code"; rm -f "${o:?}/binj"
  sed -i "s#$o/binj#BIN#g" "$o/buildj.out" "$o/buildj.err"
  e MEDAKA_STRICT=1 "$M" build "$HELLO" -o "$o/bins" > "$o/builds.out" 2> "$o/builds.err" < /dev/null; echo $? > "$o/builds.code"; rm -f "${o:?}/bins"
  e "$M" test "$DOC" > "$o/test.out" 2> "$o/test.err" < /dev/null; echo $? > "$o/test.code"
  e MEDAKA_STRICT=1 "$M" test "$DOC" > "$o/tests.out" 2> "$o/tests.err" < /dev/null; echo $? > "$o/tests.code"
}

want() { [ "$1" = "$2" ] || fail "fallback row $ROWNAME: $3 (want '$2', got '$1')"; }

mkroot disabled
fbrow disabled MEDAKA_NO_INTERFACE=1
D="$FB/disabled"
[ "$(cat "$D/run.code")" = 0 ] || fail "fallback reference: run hello exits $(cat "$D/run.code")"
[ -s "$D/run.out" ] || fail "fallback reference: run hello printed nothing"
ROFFS=$(cat "$D/run.stage")

fbcheck() {
  ROWNAME=$1; comp=$2
  o="$FB/$1"
  line="prelude trees stale: elaborating stdlib/core.mdk ($comp)"
  for k in run.out run.code bin.out bin.code test.out test.code; do
    cmp -s "$o/$k" "$D/$k" || fail "fallback row $ROWNAME: $k differs from the disabled arm"
  done
  want "$(cat "$o/run.stage")" "$ROFFS" "run hello typecheck.module is not the disabled arm's (the fallback elaborates core)"
  if [ -n "$comp" ]; then
    printf '%s\n' "$line" > "$o/line"
    cmp -s "$o/run.err" "$o/line" || fail "fallback row $ROWNAME: run stderr is not exactly the one stale line"
    cmp -s "$o/build.err" "$o/line" || fail "fallback row $ROWNAME: build stderr is not exactly the one stale line"
    cmp -s "$o/test.err" "$o/line" || fail "fallback row $ROWNAME: test stderr is not exactly the one stale line (the native child must stay silent)"
    grep -F -q "\"stalePreludeTrees\":\"$line\"" "$o/runj.err" || fail "fallback row $ROWNAME: run --json stderr lacks stalePreludeTrees"
    cat "$o/buildj.out" "$o/buildj.err" | grep -F -q "\"stalePreludeTrees\":\"$line\"" || fail "fallback row $ROWNAME: build --json lacks stalePreludeTrees"
    for v in runs builds tests; do
      want "$(cat "$o/$v.code")" 1 "STRICT $v exit code"
      grep -F -q "$line" "$o/$v.err" || fail "fallback row $ROWNAME: STRICT $v stderr lacks the stale line"
    done
  else
    for k in run.err build.err test.err runj.err; do
      [ ! -s "$o/$k" ] || fail "fallback row $ROWNAME: $k is not empty: $(head -c 200 "$o/$k")"
    done
    if cat "$o/buildj.out" "$o/buildj.err" | grep -q stalePreludeTrees; then
      fail "fallback row $ROWNAME: build --json carries a stale notice"
    fi
    for v in runs builds tests; do
      want "$(cat "$o/$v.code")" 0 "STRICT $v exit code"
    done
  fi
}

mkroot header
sed -i '1s/(compiler \([0-9a-f]*\))/(compiler 0\1)/' "$FB/root.header/stdlib/core.mdke"
fbrow header MEDAKA_ON=1
fbcheck header compiler

mkroot truncated
head -c 100000 "$ROOT/stdlib/core.mdke" > "$FB/root.truncated/stdlib/core.mdke"
fbrow truncated MEDAKA_ON=1
fbcheck truncated file

mkroot version
sed -i '1s/^(medaka-elab 1 /(medaka-elab 9 /' "$FB/root.version/stdlib/core.mdke"
fbrow version MEDAKA_ON=1
fbcheck version format

mkroot missing
rm -f "$FB/root.missing/stdlib/core.mdke"
fbrow missing MEDAKA_ON=1
fbcheck missing ""

fbcheck disabled ""
if cmp -s "$FB/root.header/stdlib/core.mdke" "$ROOT/stdlib/core.mdke"; then fail "fallback row header: the edit did not change the file"; fi
if cmp -s "$FB/root.version/stdlib/core.mdke" "$ROOT/stdlib/core.mdke"; then fail "fallback row version: the edit did not change the file"; fi
echo "fallback rows: header, truncated, version, missing, disabled ok"
echo PASS
