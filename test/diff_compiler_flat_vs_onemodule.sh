#!/bin/sh
# diff_compiler_flat_vs_onemodule.sh — pins the Module one-file and split-module
# paths against the same default-method and prelude-shadowing programs. The
# historical filename remains the registered gate name.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
ONE_BIN="$ROOT/test/bin/check_one_diags_main"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$ONE_BIN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one check_one_diags_main (missing $ONE_BIN)"; exit 2; }

run_t() { perl -e 'alarm shift; exec @ARGV' "$@"; }
LIMIT=180
WORK="$(mktemp -d)" || { echo "mktemp -d failed"; exit 2; }
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
RTFILE="$ROOT/stdlib/runtime.mdk"
COREFILE="$ROOT/stdlib/core.mdk"

IFACE_DECLS='public export data Box = Box Int

export interface Basic t where
  label : t -> String

export interface Fancy t requires Basic t where
  describe : t -> String
  describe x = "fancy:\{label x}"'
IFACE_IMPL='export impl Basic Box where
  label (Box n) = "box\{n}"

export impl Fancy Box where'
IFACE_MAIN='main = println (describe (Box 7))'

SHADOW_HELPER='export three : Int
three = 3'
SHADOW_DIFF='isEven n = "s\{n}"'
SHADOW_SAME='isEven : Int -> Bool
isEven n = n % 2 == 1'

mkdir -p "$WORK/default-one" "$WORK/default-split" "$WORK/shadow-diff-one" "$WORK/shadow-diff-split" "$WORK/shadow-same-one" "$WORK/shadow-same-split"
printf '%s\n\n%s\n\n%s\n' "$IFACE_DECLS" "$IFACE_IMPL" "$IFACE_MAIN" > "$WORK/default-one/main.mdk"
printf '%s\n' "$IFACE_DECLS" > "$WORK/default-split/iface.mdk"
printf 'import iface.{Box, Basic, Fancy, label, describe}\n\n%s\n\n%s\n' "$IFACE_IMPL" "$IFACE_MAIN" > "$WORK/default-split/main.mdk"
printf '%s\n\nmain = println (isEven 3)\n' "$SHADOW_DIFF" > "$WORK/shadow-diff-one/main.mdk"
printf '%s\n' "$SHADOW_HELPER" > "$WORK/shadow-diff-split/helper.mdk"
printf 'import helper.{three}\n\n%s\n\nmain = println (isEven three)\n' "$SHADOW_DIFF" > "$WORK/shadow-diff-split/main.mdk"
printf '%s\n\nmain = println (isEven 3)\n' "$SHADOW_SAME" > "$WORK/shadow-same-one/main.mdk"
printf '%s\n' "$SHADOW_HELPER" > "$WORK/shadow-same-split/helper.mdk"
printf 'import helper.{three}\n\n%s\n\nmain = println (isEven three)\n' "$SHADOW_SAME" > "$WORK/shadow-same-split/main.mdk"

# case | row | path | arm | expected value
ROWS='
default_method|onefile|default-one/main.mdk|ONE|fancy:box7
default_method|split|default-split/main.mdk|MODULE|fancy:box7
user_shadows_prelude_standalone|onefile|shadow-diff-one/main.mdk|ONE|s3
user_shadows_prelude_standalone|split|shadow-diff-split/main.mdk|MODULE|s3
user_shadows_prelude_samesig|onefile|shadow-same-one/main.mdk|ONE|True
user_shadows_prelude_samesig|split|shadow-same-split/main.mdk|MODULE|True'

fails=0
checked=0
comparisons=0
VALUES="$WORK/.values"
: > "$VALUES"
printf '%-34s %-10s %-8s %s\n' CASE ROW VERDICT VALUE
IFS='
'
for row in $ROWS; do
  [ -n "$row" ] || continue
  case_name="$(printf '%s' "$row" | cut -d'|' -f1)"
  label="$(printf '%s' "$row" | cut -d'|' -f2)"
  rel="$(printf '%s' "$row" | cut -d'|' -f3)"
  arm="$(printf '%s' "$row" | cut -d'|' -f4)"
  want="$(printf '%s' "$row" | cut -d'|' -f5)"
  file="$WORK/$rel"
  checked=$((checked + 1))

  if [ "$arm" = ONE ]; then
    out="$(run_t "$LIMIT" "$ONE_BIN" "$RTFILE" "$COREFILE" "$file" 2> "$WORK/.oneerr")"
    verdict="$(printf '%s\n' "$out" | sed -n '1p')"
  else
    run_t "$LIMIT" "$MEDAKA" check "$file" > "$WORK/.check" 2> "$WORK/.checkerr"; ec=$?
    case "$ec" in 0) verdict=ACCEPT ;; 1) verdict=REJECT ;; *) verdict="EXIT$ec" ;; esac
  fi

  value='-'
  if [ "$verdict" = ACCEPT ]; then
    run_t "$LIMIT" "$MEDAKA" run "$file" > "$WORK/.run" 2> "$WORK/.runerr"; ec=$?
    if [ "$ec" -eq 0 ]; then value="$(head -1 "$WORK/.run")"; else value="!!RUN-EXIT$ec"; fi
    printf '%s=%s\n' "$case_name" "$value" >> "$VALUES"
  fi
  printf '%-34s %-10s %-8s %s\n' "$case_name" "$label" "$verdict" "$value"
  if [ "$verdict" != ACCEPT ] || [ "$value" != "$want" ]; then
    echo "    FAIL: expected ACCEPT/$want"
    fails=$((fails + 1))
  fi
done
unset IFS

for case_name in default_method user_shadows_prelude_standalone user_shadows_prelude_samesig; do
  n="$(grep "^$case_name=" "$VALUES" | wc -l | tr -d ' ')"
  distinct="$(grep "^$case_name=" "$VALUES" | sed "s/^$case_name=//" | sort -u | wc -l | tr -d ' ')"
  if [ "$n" -ne 2 ] || [ "$distinct" -ne 1 ]; then
    echo "FAIL [$case_name]: one-file/split Module paths disagree"
    fails=$((fails + 1))
  else
    comparisons=$((comparisons + 1))
    printf 'ok   [%s]: %s Module paths, one value\n' "$case_name" "$n"
  fi
done

if [ "$checked" -eq 0 ] || [ "$comparisons" -eq 0 ]; then
  echo "FAIL: checked $checked row(s); $comparisons comparison(s)"
  exit 1
fi
printf 'checked %s row(s); %s accepting one-file/split comparison(s)\n' "$checked" "$comparisons"
[ "$fails" -eq 0 ] || exit 1
echo 'PASS: Module one-file and split-module pins hold.'
