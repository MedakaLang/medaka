#!/bin/sh
# Fixed-control regression for #1724's field/scalar reduction contract.
# POSIX sh; runs on Linux and macOS. Value correctness remains owned by the
# 944-row field and 1028-row scalar corpus gates.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
FIELD="$ROOT/pds/lib/field.mdk"
SCALAR="$ROOT/pds/lib/scalar.mdk"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/medaka-ct-reductions.XXXXXX")
cleanup() {
  if [ "${KEEP_WORK:-0}" = 1 ]; then
    printf 'kept work directory: %s\n' "$WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT HUP INT TERM

checked=0

pass() {
  checked=$((checked + 1))
  printf 'ok %s - %s\n' "$checked" "$1"
}

fail() {
  printf 'not ok %s - %s\n' "$((checked + 1))" "$1" >&2
  exit 1
}

require_count() {
  expected=$1
  pattern=$2
  file=$3
  label=$4
  actual=$(grep -F -c "$pattern" "$file" || true)
  [ "$actual" -eq "$expected" ] || fail "$label (expected $expected, got $actual)"
  pass "$label"
}

require_line_count() {
  expected=$1
  line=$2
  file=$3
  label=$4
  actual=$(grep -F -x -c "$line" "$file" || true)
  [ "$actual" -eq "$expected" ] || fail "$label (expected $expected, got $actual)"
  pass "$label"
}

extract_function() {
  suffix=$1
  input=$2
  output=$3
  awk -v suffix="$suffix" '
    $0 ~ ("^define i64 @.*__" suffix "\\(") { inside = 1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$input" > "$output"
  [ -s "$output" ] || fail "emitted helper *__$suffix exists"
}

check_emitted_helpers() {
  ir=$1
  dir=$2
  shift 2
  mkdir -p "$dir"
  for spec in "$@"; do
    name=${spec%%:*}
    rest=${spec#*:}
    expected=${rest%%:*}
    rest=${rest#*:}
    expected_indices=${rest%%:*}
    rest=${rest#*:}
    expected_sets=${rest%%:*}
    rest=${rest#*:}
    expected_makes=${rest%%:*}
    rest=${rest#*:}
    expected_copies=${rest%%:*}
    expected_total=${rest##*:}
    body="$dir/$name.ll"
    extract_function "$name" "$ir" "$body"
    helper_ir_ok "$body" "$expected" "$expected_indices" "$expected_sets" "$expected_makes" "$expected_copies" "$expected_total" || fail "$name native IR operation/control shape"
    ir_call_shape_ok "$name" "$body" || fail "$name native IR exact callee graph"
  done
}

ir_call_shape_ok() {
  name=$1
  body=$2
  case "$name" in
    canonicalize) expected='444837400 70' ;; carryFoldRound) expected='623455845 255' ;;
    carryAll) expected='4232113032 67' ;; carryGo) expected='3104229516 246' ;;
    carryPass) expected='2372681006 49' ;; carryPassGo) expected='929309996 455' ;;
    copyLow) expected='1052357539 123' ;;
    foldAccum) expected='3786743205 133' ;; foldAccumRow) expected='3580882342 200' ;;
    foldOnce) expected='3086817660 152' ;; reduceCarry) expected='1494584225 93' ;;
    reduceFixed) expected='4074489195 234' ;; reduceWide) expected='1838799703 160' ;;
    selectNCandidate) expected='2353378859 153' ;; selectPCandidate) expected='2694484873 152' ;;
    subNCandidate) expected='1109142635 335' ;; subNSelect) expected='1807119209 206' ;;
    subPCandidate) expected='4245653428 638' ;; subPSelect) expected='253077062 204' ;;
    takeHigh) expected='3607616228 196' ;;
    feZeroBit) expected='1334897826 93' ;; feZeroBorrow) expected='3190414508 366' ;;
    feEqualBit) expected='3866854817 116' ;; feEqualBorrow) expected='1799738399 454' ;;
    feSelect) expected='2431464765 149' ;; feSelectGo) expected='3685324955 167' ;;
    feNegateCt) expected='2191561892 230' ;; feNegateCtGo) expected='2485150926 579' ;;
    scZeroBit) expected='735493066 95' ;; scZeroBorrow) expected='2133022951 217' ;;
    scEqualBit) expected='803674573 119' ;; scEqualBorrow) expected='768047878 251' ;;
    scSelect) expected='721711084 152' ;; scSelectGo) expected='3389893739 168' ;;
    scHighBit) expected='2703992254 116' ;; scHighBorrow) expected='2129175628 279' ;;
    scNegateCt) expected='1081324241 235' ;; scNegateCtGo) expected='937536410 334' ;;
    *) return 1 ;;
  esac
  actual=$(sed -n 's/.*call i64 @\([^ (]*\).*/\1/p' "$body" | cksum | awk '{ print $1 " " $2 }')
  [ "$actual" = "$expected" ]
}

emitted_local_closure_ok() {
  dir=$1
  prefix=$2
  for body in "$dir"/*.ll; do
    sed -n "s/.*call i64 @mdk_${prefix}__\([^ (]*\).*/\1/p" "$body"
  done | sort -u | while IFS= read -r callee; do
    [ -z "$callee" ] && continue
    [ -s "$dir/$callee.ll" ] || exit 1
  done
}

helper_ir_ok() {
  body=$1
  expected=$2
  expected_indices=$3
  expected_sets=$4
  expected_makes=$5
  expected_copies=$6
  expected_total=$7
  branches=$(grep -c 'br i1' "$body" || true)
  comparisons=$(grep -E -c 'call i64 @mdk_value_(eq|ne|lt|le|gt|ge)\(' "$body" || true)
  hashes=$(grep -F -c 'call i64 @mdk_hash_bool(' "$body" || true)
  indices=$(grep -F -c 'call i64 @mdk_impl_Array_index(' "$body" || true)
  sets=$(grep -F -c 'call i64 @mdk_array__setInPlace(' "$body" || true)
  makes=$(grep -F -c 'call i64 @mdk_array_make(' "$body" || true)
  copies=$(grep -F -c 'call i64 @mdk_array_copy(' "$body" || true)
  total=$(grep -E -c 'call i64 @' "$body" || true)
  [ "$branches" -eq "$expected" ] && [ "$comparisons" -eq "$expected" ] &&
    [ "$hashes" -eq 0 ] && [ "$indices" -eq "$expected_indices" ] &&
    [ "$sets" -eq "$expected_sets" ] && [ "$makes" -eq "$expected_makes" ] &&
    [ "$copies" -eq "$expected_copies" ] && [ "$total" -eq "$expected_total" ]
}

raw_accessor_ir_ok() {
  body=$1
  [ "$(grep -c 'br i1' "$body" || true)" -eq 2 ] &&
    [ "$(grep -E -c 'call i64 @mdk_value_(eq|ne|lt|le|gt|ge)\(' "$body" || true)" -eq 0 ] &&
    [ "$(grep -F -c 'call i64 @mdk_hash_bool(' "$body" || true)" -eq 0 ] &&
    [ "$(grep -E -c 'call i64 @mdk_(impl_Array_index|array__set(InPlace)?|array_make|array_copy)\(' "$body" || true)" -eq 0 ]
}

source_indices_ok() {
  body=$1
  awk '
    {
      line=$0
      while (match(line, /\[[^]]+\]/)) {
        idx=substr(line, RSTART + 1, RLENGTH - 2)
        if (idx != "0" && idx != "1" && idx != "9" && idx != "i" &&
            idx != "i + 1" && idx != "j" && idx != "k") exit 1
        line=substr(line, RSTART + RLENGTH)
      }
    }
  ' "$body"
}

source_writes_allocations_ok() {
  body=$1
  awk '
    /(^|[[:space:]])(A\.)?set(InPlace)?[[:space:]]/ &&
      $0 !~ /(A\.)?set(InPlace)? (0|1|9|i|j|k|\(i \+ 1\)|\(i - 16\)) / { exit 1 }
    /arrayMake[[:space:]]/ && $0 !~ /arrayMake (10|16|32) / { exit 1 }
  ' "$body"
}

source_write_shape_ok() {
  name=$1
  body=$2
  writes=$(grep -E -c '(^|[[:space:]])(A\.)?set(InPlace)?[[:space:]]' "$body" || true)
  case "$name" in
    carryPassGo)
      [ "$writes" -eq 3 ] && [ "$(grep -F -c 'setInPlace 9 ' "$body" || true)" -eq 1 ] &&
        [ "$(grep -F -c 'setInPlace i ' "$body" || true)" -eq 1 ] &&
        [ "$(grep -F -c 'setInPlace (i + 1) ' "$body" || true)" -eq 1 ] ;;
    carryFoldRound)
      [ "$writes" -eq 2 ] && [ "$(grep -F -c 'setInPlace 0 ' "$body" || true)" -eq 1 ] &&
        [ "$(grep -F -c 'setInPlace 1 ' "$body" || true)" -eq 1 ] ;;
    subPCandidate|feNegateCtGo)
      [ "$writes" -eq 2 ] && [ "$(grep -F -c 'setInPlace 9 ' "$body" || true)" -eq 1 ] &&
        [ "$(grep -F -c 'setInPlace i ' "$body" || true)" -eq 1 ] ;;
    selectPCandidate|feSelectGo)
      [ "$writes" -eq 1 ] && [ "$(grep -F -c 'setInPlace i ' "$body" || true)" -eq 1 ] ;;
    carryGo|subNCandidate|selectNCandidate|copyLow|scSelectGo|scNegateCtGo)
      [ "$writes" -eq 1 ] && [ "$(grep -F -c 'A.setInPlace i ' "$body" || true)" -eq 1 ] ;;
    takeHigh)
      [ "$writes" -eq 2 ] && [ "$(grep -F -c 'A.setInPlace (i - 16) ' "$body" || true)" -eq 1 ] &&
        [ "$(grep -F -c 'A.setInPlace i ' "$body" || true)" -eq 1 ] ;;
    foldAccumRow)
      [ "$writes" -eq 1 ] && [ "$(grep -F -c 'A.setInPlace k ' "$body" || true)" -eq 1 ] ;;
    *) [ "$writes" -eq 0 ] ;;
  esac
}

extract_source_function() {
  name=$1
  input=$2
  output=$3
  awk -v name="$name" '
    $0 ~ ("^" name " :") { found = 1; next }
    found && $0 ~ ("^" name " ") { inside = 1 }
    inside && /^[A-Za-z][A-Za-z0-9]* :/ { exit }
    inside && $0 !~ /^[[:space:]]*--/ { print }
  ' "$input" > "$output"
  [ -s "$output" ] || return 1
}

source_shape_ok() {
  name=$1
  body=$2
  case "$name" in
    canonicalize) expected='1918979222 101' ;; carryAll) expected='3784023453 28' ;;
    carryFoldRound) expected='702085150 126' ;; carryGo) expected='2473884978 265' ;;
    carryPass) expected='1250453555 31' ;; carryPassGo) expected='1857917920 284' ;;
    copyLow) expected='2185712744 111' ;;
    foldAccum) expected='1811712224 107' ;; foldAccumRow) expected='2020878519 156' ;;
    foldOnce) expected='1770996279 84' ;; reduceCarry) expected='2596813441 92' ;;
    reduceFixed) expected='736687942 206' ;; reduceWide) expected='1389933683 128' ;;
    selectNCandidate) expected='868510668 210' ;; selectPCandidate) expected='1063104259 208' ;;
    subNCandidate) expected='3519783463 226' ;; subNSelect) expected='1155645251 125' ;;
    subPCandidate) expected='714167625 342' ;; subPSelect) expected='764393686 125' ;;
    feZeroBit) expected='1598842918 42' ;; feZeroBorrow) expected='2456388451 212' ;;
    feEqualBit) expected='243104385 56' ;; feEqualBorrow) expected='1904311731 242' ;;
    feSelect) expected='564879547 108' ;; feSelectGo) expected='3738294658 157' ;;
    feNegateCt) expected='2668735364 126' ;; feNegateCtGo) expected='2165366212 310' ;;
    rawFe) expected='714619739 33' ;;
    scZeroBit) expected='1698366246 42' ;; scZeroBorrow) expected='2082986577 156' ;;
    scEqualBit) expected='1611320584 56' ;; scEqualBorrow) expected='3496656700 174' ;;
    scSelect) expected='1808119660 108' ;; scSelectGo) expected='161536967 159' ;;
    scHighBit) expected='601342344 46' ;; scHighBorrow) expected='1879936321 172' ;;
    scNegateCt) expected='1370341835 126' ;; scNegateCtGo) expected='3026427442 224' ;;
    rawSc) expected='3051169895 33' ;;
    takeHigh) expected='2180466419 148' ;; *) return 1 ;;
  esac
  actual=$(cksum "$body" | awk '{ print $1 " " $2 }')
  [ "$actual" = "$expected" ]
}

source_helpers_ok() {
  field=$1
  scalar=$2
  dir=$3
  mkdir -p "$dir"
  for spec in \
    "carryPass:$field:0" \
    "carryPassGo:$field:1" \
    "carryFoldRound:$field:0" \
    "reduceCarry:$field:0" \
    "subPCandidate:$field:1" \
    "selectPCandidate:$field:1" \
    "subPSelect:$field:0" \
    "canonicalize:$field:0" \
    "feZeroBit:$field:0" \
    "feZeroBorrow:$field:1" \
    "feEqualBit:$field:0" \
    "feEqualBorrow:$field:1" \
    "feSelect:$field:0" \
    "feSelectGo:$field:1" \
    "feNegateCt:$field:0" \
    "feNegateCtGo:$field:1" \
    "rawFe:$field:0" \
    "carryAll:$scalar:0" \
    "carryGo:$scalar:2" \
    "foldOnce:$scalar:0" \
    "takeHigh:$scalar:1" \
    "foldAccum:$scalar:1" \
    "foldAccumRow:$scalar:1" \
    "reduceFixed:$scalar:0" \
    "subNCandidate:$scalar:1" \
    "selectNCandidate:$scalar:1" \
    "subNSelect:$scalar:0" \
    "reduceWide:$scalar:0" \
    "copyLow:$scalar:1" \
    "scZeroBit:$scalar:0" \
    "scZeroBorrow:$scalar:1" \
    "scEqualBit:$scalar:0" \
    "scEqualBorrow:$scalar:1" \
    "scSelect:$scalar:0" \
    "scSelectGo:$scalar:1" \
    "scHighBit:$scalar:0" \
    "scHighBorrow:$scalar:1" \
    "scNegateCt:$scalar:0" \
    "scNegateCtGo:$scalar:1" \
    "rawSc:$scalar:0"
  do
    name=${spec%%:*}
    rest=${spec#*:}
    file=${rest%:*}
    allowed=${spec##*:}
    body="$dir/$name.mdk"
    extract_source_function "$name" "$file" "$body" || return 1
    source_shape_ok "$name" "$body" || return 1
    actual=$(awk '{ line=$0; while (match(line, /if[[:space:]]/)) { n++; line=substr(line, RSTART + RLENGTH) } } END { print n + 0 }' "$body")
    [ "$actual" -eq "$allowed" ] || return 1
    comparisons=$(awk '{ line=$0; while (match(line, /(==|\/=|<=|>=| < | > )/)) { n++; line=substr(line, RSTART + RLENGTH) } } END { print n + 0 }' "$body")
    expected_comparisons=$allowed
    if [ "$name" = carryGo ]; then expected_comparisons=3; fi
    [ "$comparisons" -eq "$expected_comparisons" ] || return 1
    if grep -F -q 'hashBool' "$body"; then return 1; fi
    source_indices_ok "$body" || return 1
    source_writes_allocations_ok "$body" || return 1
    source_write_shape_ok "$name" "$body" || return 1
    if [ "$name" = carryGo ]; then
      grep -F -q 'if i >= nWide then if carry /= 0 then panic' "$body" || return 1
    fi
  done
  return 0
}

find_native_symbol() {
  binary=$1
  suffix=$2
  nm "$binary" | awk -v suffix="__$suffix" '$3 ~ (suffix "$") { sub(/^_/, "", $3); print $3; exit }'
}

find_exact_symbol() {
  binary=$1
  wanted=$2
  nm "$binary" | awk -v wanted="$wanted" '{ name=$3; sub(/^_/, "", name); if (name == wanted) { print name; exit } }'
}

append_field_probe() {
  file=$1
  cat >> "$file" <<'EOF'

fieldRoundsWitness : Bool
fieldRoundsWitness =
  let raw = arrayMake 10 limbMask
  let () = setInPlace 9 (shiftLeft 1 43 - 1) raw
  let () = reduceCarry raw
  fieldWitnessGo raw 0

fieldWitnessGo : Array Int -> Int -> Bool
fieldWitnessGo raw i =
  if i >= 9 then raw[9] <= topMask
  else if raw[i] > limbMask then False
  else fieldWitnessGo raw (i + 1)

fieldSelectWitness : Bool
fieldSelectWitness =
  let canonical = canonicalize [|1, 0, 0, 0, 0, 0, 0, 0, 0, 0|]
  arrayLength (feToBytes canonical) == 32

fieldCtHelpersWitness : Bool
fieldCtHelpersWitness =
  let two = feAdd feOne feOne
  feZeroBit feZero == 1
    && feZeroBit feOne == 0
    && feEqualBit feOne feOne == 1
    && feEqualBit feOne two == 0
    && feEqual (feSelect 0 feOne two) feOne
    && feEqual (feSelect 1 feOne two) two
    && feEqual (feNegateCt feZero) feZero
    && feEqual (feAdd two (feNegateCt two)) feZero

main = if fieldRoundsWitness && fieldSelectWitness && fieldCtHelpersWitness then println "PASS field-rounds" else panic "FAIL field-rounds"
EOF
}

append_scalar_probe() {
  file=$1
  cat >> "$file" <<'EOF'

scalarRoundsWitness : Bool
scalarRoundsWitness =
  -- Constructed by taking a preimage through two folds of 2^257 - 1.
  -- After three folds the high half is still 1; the fourth clears it.
  let raw = [|
    0x9bf7, 0xe237, 0xc25f, 0xf3f7, 0x70cb, 0x0339, 0xc853, 0xd9cc,
    0, 0, 0, 0, 0, 0, 0, 0,
    0x673a, 0x7df0, 0x6c67, 0x354c, 0xb045, 0x6981, 0xc5d3, 0x8422,
    0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff,
  |]
  let () = reduceFixed raw
  scalarHighZero raw 16

scalarHighZero : Array Int -> Int -> Bool
scalarHighZero raw i =
  if i >= 32 then True
  else if raw[i] /= 0 then False
  else scalarHighZero raw (i + 1)

scalarSelectWitness : Bool
scalarSelectWitness =
  let canonical = reduceWide (arrayMake 32 0)
  arrayLength (scToBytes canonical) == 32

scalarCtHelpersWitness : Bool
scalarCtHelpersWitness =
  let two = scAdd scOne scOne
  let high = scNegateCt scOne
  scZeroBit scZero == 1
    && scZeroBit scOne == 0
    && scEqualBit scOne scOne == 1
    && scEqualBit scOne two == 0
    && scEqual (scSelect 0 scOne two) scOne
    && scEqual (scSelect 1 scOne two) two
    && scEqual (scNegateCt scZero) scZero
    && scEqual (scAdd two (scNegateCt two)) scZero
    && scHighBit scZero == 0
    && scHighBit high == 1

main = if scalarRoundsWitness && scalarSelectWitness && scalarCtHelpersWitness then println "PASS scalar-rounds" else panic "FAIL scalar-rounds"
EOF
}

run_probe() {
  file=$1
  expected=$2
  label=$3
  out="$WORK/probe.out"
  if ! MEDAKA_STRICT=1 "$MEDAKA" run "$file" > "$out" 2>&1 || ! grep -F -q "$expected" "$out"; then
    cat "$out" >&2
    fail "$label"
  fi
  native="$WORK/probe-native"
  if ! MEDAKA_STRICT=1 "$MEDAKA" build "$file" -o "$native" > "$WORK/probe-native-build.log" 2>&1 || ! "$native" > "$WORK/probe-native.out" 2>&1 || ! grep -F -q "$expected" "$WORK/probe-native.out"; then
    cat "$WORK/probe-native-build.log" "$WORK/probe-native.out" >&2
    fail "$label"
  fi
  engines=eval/native
  wasm_emitter=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
  if [ -x "$wasm_emitter" ] && command -v node >/dev/null 2>&1 && command -v wasm-tools >/dev/null 2>&1; then
    if ! MEDAKA_WASM_EMITTER="$wasm_emitter" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$file" -o "$WORK/probe.wasm" > "$WORK/probe-wasm-build.log" 2>&1 || ! node "$ROOT/test/wasm/run.js" "$WORK/probe.wasm" > "$WORK/probe-wasm.out" 2>&1 || ! grep -F -q "$expected" "$WORK/probe-wasm.out"; then
      cat "$WORK/probe-wasm-build.log" "$WORK/probe-wasm.out" >&2
      fail "$label"
    fi
    engines=$engines/Wasm
  elif [ "${MEDAKA_REQUIRE_WASM:-0}" = 1 ]; then
    fail "$label (Wasm required but unavailable)"
  fi
  pass "$label ($engines)"
}

run_probe_red() {
  file=$1
  label=$2
  out="$WORK/probe-red.out"
  if MEDAKA_STRICT=1 "$MEDAKA" run "$file" > "$out" 2>&1; then
    cat "$out" >&2
    fail "$label"
  fi
  pass "$label"
}

# Source anti-rot: exact schedules and no retired conditional path from the
# reduction entry points. Counts are deliberately file-wide because these
# helper calls are unique to their schedules.
require_line_count 2 '  let () = carryFoldRound n' "$FIELD" 'field schedule has two sequenced rounds'
require_line_count 1 '  carryFoldRound n' "$FIELD" 'field schedule has the third terminal round'
require_line_count 4 '  let () = foldOnce w' "$SCALAR" 'scalar schedule is exactly four folds'
require_count 0 'subPInPlace' "$FIELD" 'field retired branchy subtraction is absent'
require_count 0 'subNInPlace' "$SCALAR" 'scalar retired branchy subtraction is absent'
require_count 1 'original + keepDiff * (diff[i] - original)' "$FIELD" 'field arithmetic select is present'
require_count 1 'original + keepDiff * (diff[i] - original)' "$SCALAR" 'scalar arithmetic select is present'
source_helpers_ok "$FIELD" "$SCALAR" "$WORK/source-current" || fail 'dedicated reduction helpers contain only public-counter source branches'
pass 'dedicated reduction helpers contain only public-counter source branches'

# The source checker must reject secret control in either the borrow chain or
# either modulus' blend, not merely protect the current arithmetic spelling.
awk '
  /subPCandidate n diff \(i \+ 1\) \(1 - shiftRight t 26\)/ {
    print "    subPCandidate n diff (i + 1) (if shiftRight t 26 == 0 then 1 else 0)"
    next
  }
  { print }
' "$FIELD" > "$WORK/field_borrow_source_mutant.mdk"
if source_helpers_ok "$WORK/field_borrow_source_mutant.mdk" "$SCALAR" "$WORK/source-field-mutant"; then
  fail 'field borrow secret-branch mutation is rejected by source structure'
fi
pass 'field borrow secret-branch mutation is rejected by source structure'

awk '
  /let \(\) = A.setInPlace i \(original \+ keepDiff \* \(diff\[i\] - original\)\) w/ {
    print "    let () = if keepDiff == 1 then A.setInPlace i diff[i] w else A.setInPlace i original w"
    next
  }
  { print }
' "$SCALAR" > "$WORK/scalar_select_source_mutant.mdk"
if source_helpers_ok "$FIELD" "$WORK/scalar_select_source_mutant.mdk" "$WORK/source-scalar-mutant"; then
  fail 'scalar select secret-branch mutation is rejected by source structure'
fi
pass 'scalar select secret-branch mutation is rejected by source structure'

awk '
  /selectNCandidate w diff keepDiff \(i \+ 1\)/ {
    print "    let secret = hashBool (original < diff[i])"
    print "    let () = A.setInPlace i (w[i] + 0 * secret) w"
    print
    next
  }
  { print }
' "$SCALAR" > "$WORK/scalar_hash_source_mutant.mdk"
if source_helpers_ok "$FIELD" "$WORK/scalar_hash_source_mutant.mdk" "$WORK/source-scalar-hash-mutant"; then
  fail 'scalar comparison/hashBool mutation is rejected by source structure'
fi
pass 'scalar comparison/hashBool mutation is rejected by source structure'

awk '
  /selectNCandidate w diff keepDiff \(i \+ 1\)/ {
    print "    let secretIndex = bitAnd original 1"
    print "    let sampled = w[secretIndex]"
    print "    let () = A.setInPlace i (w[i] + 0 * sampled) w"
    print
    next
  }
  { print }
' "$SCALAR" > "$WORK/scalar_index_source_mutant.mdk"
if source_helpers_ok "$FIELD" "$WORK/scalar_index_source_mutant.mdk" "$WORK/source-scalar-index-mutant"; then
  fail 'scalar secret-index mutation is rejected by source structure'
fi
pass 'scalar secret-index mutation is rejected by source structure'

awk '
  /let \(\) = A.setInPlace i \(original \+ keepDiff \* \(diff\[i\] - original\)\) w/ {
    print "    let secretIndex = bitAnd original 1"
    print "    let scratch = arrayMake 2 0"
    print "    let () = A.setInPlace secretIndex 0 scratch"
    print
    next
  }
  { print }
' "$SCALAR" > "$WORK/scalar_write_source_mutant.mdk"
if source_helpers_ok "$FIELD" "$WORK/scalar_write_source_mutant.mdk" "$WORK/source-scalar-write-mutant"; then
  fail 'scalar secret-write mutation is rejected by source structure'
fi
pass 'scalar secret-write mutation is rejected by source structure'

awk '
  /let t = w\[i\] \+ limbMask \+ 1 - nLimbs\[i\] - borrow/ {
    print
    print "    let k = borrow"
    next
  }
  /A.setInPlace i \(bitAnd t limbMask\) diff/ {
    print "    let () = A.setInPlace k (bitAnd t limbMask) diff"
    next
  }
  { print }
' "$SCALAR" > "$WORK/scalar_rebound_index_source_mutant.mdk"
if source_helpers_ok "$FIELD" "$WORK/scalar_rebound_index_source_mutant.mdk" "$WORK/source-scalar-rebound-index-mutant"; then
  fail 'scalar rebound secret-index mutation is rejected by source structure'
fi
pass 'scalar rebound secret-index mutation is rejected by source structure'

awk '
  /^subNCandidate :/ {
    print "leakyShift : Int -> Int -> Int"
    print "leakyShift x amount = if x == 0 then 0 else shiftRight x amount"
    print ""
  }
  /subNCandidate w diff \(i \+ 1\) \(1 - shiftRight t 16\)/ {
    print "    subNCandidate w diff (i + 1) (1 - leakyShift t 16)"
    next
  }
  { print }
' "$SCALAR" > "$WORK/scalar_wrapper_source_mutant.mdk"
if source_helpers_ok "$FIELD" "$WORK/scalar_wrapper_source_mutant.mdk" "$WORK/source-scalar-wrapper-mutant"; then
  fail 'scalar leaky-wrapper mutation is rejected by exact source graph'
fi
pass 'scalar leaky-wrapper mutation is rejected by exact source graph'

awk '
  /let \(\) = A.setInPlace i w\[i\] out/ {
    print "    let value = w[i]"
    print "    let copied = if value == 0 then shiftRight value 0 else value"
    print "    let () = A.setInPlace i copied out"
    next
  }
  { print }
' "$SCALAR" > "$WORK/scalar_copy_source_mutant.mdk"
if source_helpers_ok "$FIELD" "$WORK/scalar_copy_source_mutant.mdk" "$WORK/source-scalar-copy-mutant"; then
  fail 'scalar transitive copy mutation is rejected by closed source graph'
fi
pass 'scalar transitive copy mutation is rejected by closed source graph'

awk '
  /^feZeroBit a =/ {
    print "feZeroBit a = hashBool (feEqual a feZero)"
    next
  }
  { print }
' "$FIELD" > "$WORK/field_zero_sentinel_mutant.mdk"
if source_helpers_ok "$WORK/field_zero_sentinel_mutant.mdk" "$SCALAR" "$WORK/source-field-zero-mutant"; then
  fail 'field sentinel/Bool zero mutation is rejected by source structure'
fi
pass 'field sentinel/Bool zero mutation is rejected by source structure'

awk '
  /^scHighBit s =/ {
    print "scHighBit s = hashBool (scIsHigh s)"
    next
  }
  { print }
' "$SCALAR" > "$WORK/scalar_high_bool_mutant.mdk"
if source_helpers_ok "$FIELD" "$WORK/scalar_high_bool_mutant.mdk" "$WORK/source-scalar-high-mutant"; then
  fail 'scalar Bool high mutation is rejected by source structure'
fi
pass 'scalar Bool high mutation is rejected by source structure'

awk '
  /scHighBorrow s \(i \+ 1\) \(1 - shiftRight t 16\)/ {
    print "    scHighBorrow s (i + 1) (if shiftRight t 16 == 0 then 1 else 0)"
    next
  }
  { print }
' "$SCALAR" > "$WORK/scalar_high_branch_mutant.mdk"
if source_helpers_ok "$FIELD" "$WORK/scalar_high_branch_mutant.mdk" "$WORK/source-scalar-high-branch-mutant"; then
  fail 'scalar high-bit secret-branch mutation is rejected by source structure'
fi
pass 'scalar high-bit secret-branch mutation is rejected by source structure'

awk '
  /let \(\) = setInPlace i \(a\[i\] \+ bit \* \(b\[i\] - a\[i\]\)\) out/ {
    print "    let () = if bit == 1 then setInPlace i b[i] out else setInPlace i a[i] out"
    next
  }
  { print }
' "$FIELD" > "$WORK/field_helper_select_mutant.mdk"
if source_helpers_ok "$WORK/field_helper_select_mutant.mdk" "$SCALAR" "$WORK/source-field-helper-select-mutant"; then
  fail 'field helper conditional-select mutation is rejected by source structure'
fi
pass 'field helper conditional-select mutation is rejected by source structure'

# Private same-module witnesses. The mutation copies never touch the worktree.
cp "$FIELD" "$WORK/field_probe.mdk"
append_field_probe "$WORK/field_probe.mdk"
run_probe "$WORK/field_probe.mdk" 'PASS field-rounds' 'field third-round witness passes'

awk '
  /^reduceCarry n =/ { in_reduce = 1 }
  in_reduce && /let \(\) = carryFoldRound n/ && !removed { removed = 1; next }
  in_reduce && /^[^ ]/ && !/^reduceCarry n =/ { in_reduce = 0 }
  { print }
' "$FIELD" > "$WORK/field_two_rounds.mdk"
append_field_probe "$WORK/field_two_rounds.mdk"
run_probe_red "$WORK/field_two_rounds.mdk" 'field 3-to-2 mutation is rejected'

cp "$SCALAR" "$WORK/scalar_probe.mdk"
append_scalar_probe "$WORK/scalar_probe.mdk"
run_probe "$WORK/scalar_probe.mdk" 'PASS scalar-rounds' 'scalar fourth-fold witness passes'

awk '
  /let \(\) = foldOnce w/ { seen++ }
  /let \(\) = foldOnce w/ && seen == 4 { next }
  { print }
' "$SCALAR" > "$WORK/scalar_three_folds.mdk"
append_scalar_probe "$WORK/scalar_three_folds.mdk"
run_probe_red "$WORK/scalar_three_folds.mdk" 'scalar 4-to-3 mutation is rejected'

# Native emitted-control check. Recursive limb helpers have one public-counter
# branch; straight-line schedule helpers have none. Secret-branch mutations in
# both moduli must add control and red independently of the source checker.
cp "$FIELD" "$WORK/field_emit.mdk"
append_field_probe "$WORK/field_emit.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/field_emit.mdk" -o "$WORK/field_emit" --keep-ir > "$WORK/build.log" 2>&1
check_emitted_helpers "$WORK/field_emit.ll" "$WORK/field-ir" \
  carryPass:0:0:0:0:0:2 carryPassGo:1:3:3:0:0:22 carryFoldRound:0:2:2:0:0:11 \
  reduceCarry:0:0:0:0:0:3 subPCandidate:1:4:2:0:0:29 \
  selectPCandidate:1:2:1:0:0:7 subPSelect:0:0:0:1:0:9 \
  canonicalize:0:0:0:0:1:3 \
  feZeroBit:0:0:0:0:0:4 feZeroBorrow:1:2:0:0:0:17 \
  feEqualBit:0:0:0:0:0:5 feEqualBorrow:1:4:0:0:0:22 \
  feSelect:0:0:0:1:0:7 feSelectGo:1:3:1:0:0:8 \
  feNegateCt:0:0:0:1:0:10 feNegateCtGo:1:4:2:0:0:26
extract_function rawFe "$WORK/field_emit.ll" "$WORK/field-ir/rawFe.ll"
raw_accessor_ir_ok "$WORK/field-ir/rawFe.ll" || fail 'field opaque-value accessor has only invariant representation dispatch'
emitted_local_closure_ok "$WORK/field-ir" field_emit || fail 'field emitted local call graph is closed'
pass 'field emitted local call graph is closed, including carryPass'
extract_function selectPCandidate "$WORK/field_emit.ll" "$WORK/select-current.ll"
current_ir_branches=$(grep -c 'br i1' "$WORK/select-current.ll" || true)
[ "$current_ir_branches" -eq 1 ] || fail "current native IR has one public-counter branch (got $current_ir_branches)"
extract_function subPCandidate "$WORK/field_emit.ll" "$WORK/borrow-current.ll"
field_borrow_ir_branches=$(grep -c 'br i1' "$WORK/borrow-current.ll" || true)
[ "$field_borrow_ir_branches" -eq 1 ] || fail "current field borrow IR has one public-counter branch (got $field_borrow_ir_branches)"
if grep -F -q 'mdk_value_eq' "$WORK/select-current.ll" "$WORK/borrow-current.ll"; then
  fail 'current field reduction IR contains secret equality control'
fi
pass 'current field IR has only public-counter control'
pass 'complete field reducer IR matches the approved helper control shape'

cp "$WORK/field_zero_sentinel_mutant.mdk" "$WORK/field_zero_sentinel_emit.mdk"
append_field_probe "$WORK/field_zero_sentinel_emit.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/field_zero_sentinel_emit.mdk" -o "$WORK/field_zero_sentinel_emit" --keep-ir > "$WORK/build-field-zero-mutant.log" 2>&1
extract_function feZeroBit "$WORK/field_zero_sentinel_emit.ll" "$WORK/field-zero-mutant.ll"
grep -F -q 'mdk_hash_bool' "$WORK/field-zero-mutant.ll" || fail 'field sentinel/Bool zero mutation reaches native IR'
grep -F -q '__feEqual' "$WORK/field-zero-mutant.ll" || fail 'field sentinel zero mutation calls branch-bearing equality'
pass 'field sentinel/Bool zero mutation is rejected by native IR closure'

cp "$WORK/field_helper_select_mutant.mdk" "$WORK/field_helper_select_emit.mdk"
append_field_probe "$WORK/field_helper_select_emit.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/field_helper_select_emit.mdk" -o "$WORK/field_helper_select_emit" --keep-ir > "$WORK/build-field-helper-select-mutant.log" 2>&1
extract_function feSelectGo "$WORK/field_helper_select_emit.ll" "$WORK/field-helper-select-mutant.ll"
grep -F -q 'mdk_value_eq' "$WORK/field-helper-select-mutant.ll" || fail 'field helper conditional-select mutation reaches native IR'
[ "$(grep -c 'br i1' "$WORK/field-helper-select-mutant.ll" || true)" -gt 1 ] || fail 'field helper conditional-select mutation adds secret IR control'
pass 'field helper conditional-select mutation is rejected by native IR control'

cp "$WORK/field_borrow_source_mutant.mdk" "$WORK/field_borrow_branch_mutant.mdk"
append_field_probe "$WORK/field_borrow_branch_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/field_borrow_branch_mutant.mdk" -o "$WORK/field_borrow_branch_mutant" --keep-ir > "$WORK/build-borrow-mutant.log" 2>&1
extract_function subPCandidate "$WORK/field_borrow_branch_mutant.ll" "$WORK/borrow-mutant.ll"
borrow_mutant_ir_branches=$(grep -c 'br i1' "$WORK/borrow-mutant.ll" || true)
[ "$borrow_mutant_ir_branches" -gt "$field_borrow_ir_branches" ] || fail 'field borrow mutation is rejected by native IR control'
grep -F -q 'mdk_value_eq' "$WORK/borrow-mutant.ll" || fail 'field borrow mutation exposes equality in native IR'
pass 'field borrow mutation is rejected by native IR control'

awk '
  /let \(\) = setInPlace i \(original \+ keepDiff \* \(diff\[i\] - original\)\) n/ {
    print "    let () = if keepDiff == 1 then setInPlace i diff[i] n else setInPlace i original n"
    next
  }
  { print }
' "$FIELD" > "$WORK/field_branch_mutant.mdk"
append_field_probe "$WORK/field_branch_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/field_branch_mutant.mdk" -o "$WORK/field_branch_mutant" --keep-ir > "$WORK/build-mutant.log" 2>&1
extract_function selectPCandidate "$WORK/field_branch_mutant.ll" "$WORK/select-mutant.ll"
mutant_ir_branches=$(grep -c 'br i1' "$WORK/select-mutant.ll" || true)
[ "$mutant_ir_branches" -gt "$current_ir_branches" ] || fail 'conditional-select mutation is rejected by native IR control'
pass 'conditional-select mutation is rejected by native IR control'

cp "$SCALAR" "$WORK/scalar_emit.mdk"
append_scalar_probe "$WORK/scalar_emit.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_emit.mdk" -o "$WORK/scalar_emit" --keep-ir > "$WORK/build-scalar.log" 2>&1
check_emitted_helpers "$WORK/scalar_emit.ll" "$WORK/scalar-ir" \
  carryAll:0:0:0:0:0:3 carryGo:2:1:1:0:0:12 takeHigh:1:1:2:0:0:9 foldAccum:1:0:0:0:0:6 \
  foldAccumRow:1:3:1:0:0:9 foldOnce:0:0:0:1:0:7 reduceFixed:0:0:0:0:0:9 \
  subNCandidate:1:2:1:0:0:15 selectNCandidate:1:2:1:0:0:7 \
  subNSelect:0:0:0:1:0:9 reduceWide:0:0:0:1:0:7 copyLow:1:1:1:0:0:6 \
  scZeroBit:0:0:0:0:0:4 scZeroBorrow:1:1:0:0:0:10 \
  scEqualBit:0:0:0:0:0:5 scEqualBorrow:1:2:0:0:0:12 \
  scSelect:0:0:0:1:0:7 scSelectGo:1:3:1:0:0:8 \
  scHighBit:0:0:0:0:0:5 scHighBorrow:1:2:0:0:0:12 \
  scNegateCt:0:0:0:1:0:10 scNegateCtGo:1:2:1:0:0:15
extract_function rawSc "$WORK/scalar_emit.ll" "$WORK/scalar-ir/rawSc.ll"
raw_accessor_ir_ok "$WORK/scalar-ir/rawSc.ll" || fail 'scalar opaque-value accessor has only invariant representation dispatch'
emitted_local_closure_ok "$WORK/scalar-ir" scalar_emit || fail 'scalar emitted local call graph is closed'
pass 'scalar emitted local call graph is closed, including carryAll and copyLow'
extract_function selectNCandidate "$WORK/scalar_emit.ll" "$WORK/scalar-select-current.ll"
extract_function subNCandidate "$WORK/scalar_emit.ll" "$WORK/scalar-borrow-current.ll"
[ "$(grep -c 'br i1' "$WORK/scalar-select-current.ll" || true)" -eq 1 ] || fail 'current scalar select IR has only its public-counter branch'
[ "$(grep -c 'br i1' "$WORK/scalar-borrow-current.ll" || true)" -eq 1 ] || fail 'current scalar borrow IR has only its public-counter branch'
if grep -F -q 'mdk_value_eq' "$WORK/scalar-select-current.ll" "$WORK/scalar-borrow-current.ll"; then
  fail 'current scalar reduction IR contains secret equality control'
fi
grep -F -q 'call i64 @mdk_array__setInPlace(i64 %arg2,' "$WORK/scalar-borrow-current.ll" || fail 'scalar borrow IR writes only at its public index argument'
pass 'current scalar IR has only public-counter control'
pass 'complete scalar reducer IR matches the approved helper control shape'

cp "$WORK/scalar_high_bool_mutant.mdk" "$WORK/scalar_high_bool_emit.mdk"
append_scalar_probe "$WORK/scalar_high_bool_emit.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_high_bool_emit.mdk" -o "$WORK/scalar_high_bool_emit" --keep-ir > "$WORK/build-scalar-high-mutant.log" 2>&1
extract_function scHighBit "$WORK/scalar_high_bool_emit.ll" "$WORK/scalar-high-mutant.ll"
grep -F -q 'mdk_hash_bool' "$WORK/scalar-high-mutant.ll" || fail 'scalar Bool high mutation reaches native IR'
grep -F -q '__scIsHigh' "$WORK/scalar-high-mutant.ll" || fail 'scalar high mutation calls branch-bearing predicate'
pass 'scalar Bool high mutation is rejected by native IR closure'

cp "$WORK/scalar_high_branch_mutant.mdk" "$WORK/scalar_high_branch_emit.mdk"
append_scalar_probe "$WORK/scalar_high_branch_emit.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_high_branch_emit.mdk" -o "$WORK/scalar_high_branch_emit" --keep-ir > "$WORK/build-scalar-high-branch-mutant.log" 2>&1
extract_function scHighBorrow "$WORK/scalar_high_branch_emit.ll" "$WORK/scalar-high-branch-mutant.ll"
grep -F -q 'mdk_value_eq' "$WORK/scalar-high-branch-mutant.ll" || fail 'scalar high-bit secret-branch mutation reaches native IR'
[ "$(grep -c 'br i1' "$WORK/scalar-high-branch-mutant.ll" || true)" -gt 1 ] || fail 'scalar high-bit mutation adds secret IR control'
pass 'scalar high-bit secret-branch mutation is rejected by native IR control'

cp "$WORK/scalar_select_source_mutant.mdk" "$WORK/scalar_branch_mutant.mdk"
append_scalar_probe "$WORK/scalar_branch_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_branch_mutant.mdk" -o "$WORK/scalar_branch_mutant" --keep-ir > "$WORK/build-scalar-mutant.log" 2>&1
extract_function selectNCandidate "$WORK/scalar_branch_mutant.ll" "$WORK/scalar-select-mutant.ll"
scalar_mutant_ir_branches=$(grep -c 'br i1' "$WORK/scalar-select-mutant.ll" || true)
[ "$scalar_mutant_ir_branches" -gt 1 ] || fail 'scalar conditional-select mutation is rejected by native IR control'
grep -F -q 'mdk_value_eq' "$WORK/scalar-select-mutant.ll" || fail 'scalar conditional-select mutation exposes equality in native IR'
pass 'scalar conditional-select mutation is rejected by native IR control'

cp "$WORK/scalar_hash_source_mutant.mdk" "$WORK/scalar_hash_mutant.mdk"
append_scalar_probe "$WORK/scalar_hash_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_hash_mutant.mdk" -o "$WORK/scalar_hash_mutant" --keep-ir > "$WORK/build-scalar-hash-mutant.log" 2>&1
extract_function selectNCandidate "$WORK/scalar_hash_mutant.ll" "$WORK/scalar-hash-mutant.ll"
if helper_ir_ok "$WORK/scalar-hash-mutant.ll" 1 2 1 0 0 7; then
  fail 'scalar comparison/hashBool mutation is rejected by native IR operation allowlist'
fi
grep -F -q 'mdk_hash_bool' "$WORK/scalar-hash-mutant.ll" || fail 'scalar comparison/hashBool mutation reaches native IR'
pass 'scalar comparison/hashBool mutation is rejected by native IR operation allowlist'

cp "$WORK/scalar_index_source_mutant.mdk" "$WORK/scalar_index_mutant.mdk"
append_scalar_probe "$WORK/scalar_index_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_index_mutant.mdk" -o "$WORK/scalar_index_mutant" --keep-ir > "$WORK/build-scalar-index-mutant.log" 2>&1
extract_function selectNCandidate "$WORK/scalar_index_mutant.ll" "$WORK/scalar-index-mutant.ll"
if helper_ir_ok "$WORK/scalar-index-mutant.ll" 1 2 1 0 0 7; then
  fail 'scalar secret-index mutation is rejected by native IR call shape'
fi
index_calls=$(grep -F -c 'call i64 @mdk_impl_Array_index(' "$WORK/scalar-index-mutant.ll" || true)
[ "$index_calls" -gt 2 ] || fail 'scalar secret-index mutation reaches native IR'
pass 'scalar secret-index mutation is rejected by native IR call shape'

cp "$WORK/scalar_write_source_mutant.mdk" "$WORK/scalar_write_mutant.mdk"
append_scalar_probe "$WORK/scalar_write_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_write_mutant.mdk" -o "$WORK/scalar_write_mutant" --keep-ir > "$WORK/build-scalar-write-mutant.log" 2>&1
extract_function selectNCandidate "$WORK/scalar_write_mutant.ll" "$WORK/scalar-write-mutant.ll"
if helper_ir_ok "$WORK/scalar-write-mutant.ll" 1 2 1 0 0 7; then
  fail 'scalar secret-write mutation is rejected by native IR call multiset'
fi
write_calls=$(grep -F -c 'call i64 @mdk_array__setInPlace(' "$WORK/scalar-write-mutant.ll" || true)
make_calls=$(grep -F -c 'call i64 @mdk_array_make(' "$WORK/scalar-write-mutant.ll" || true)
[ "$write_calls" -gt 1 ] && [ "$make_calls" -gt 0 ] || fail 'scalar secret-write mutation reaches native IR'
pass 'scalar secret-write mutation is rejected by native IR call multiset'

cp "$WORK/scalar_rebound_index_source_mutant.mdk" "$WORK/scalar_rebound_index_mutant.mdk"
append_scalar_probe "$WORK/scalar_rebound_index_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_rebound_index_mutant.mdk" -o "$WORK/scalar_rebound_index_mutant" --keep-ir > "$WORK/build-scalar-rebound-index-mutant.log" 2>&1
extract_function subNCandidate "$WORK/scalar_rebound_index_mutant.ll" "$WORK/scalar-rebound-index-mutant.ll"
# Positive control for the operand-provenance detector below (#2437).  That detector is a
# NEGATIVE assertion — it passes when its grep finds nothing — so a pattern that has quietly
# stopped being able to match anything is indistinguishable from a clean tree.  The
# `array.set` -> `array.setInPlace` rename retargeted the emitted callee once already.  Prove
# the exact pattern CAN still fire, against the clean tree's own public-index write, before
# reading its non-match against the mutant as evidence of anything.
grep -F -q 'call i64 @mdk_array__setInPlace(i64 %arg2,' "$WORK/scalar-borrow-current.ll" ||
  fail 'secret-index operand-provenance detector still matches a real public-index write'
pass 'secret-index operand-provenance detector is proven live against a known public-index write'
if grep -F -q 'call i64 @mdk_array__setInPlace(i64 %arg2,' "$WORK/scalar-rebound-index-mutant.ll"; then
  fail 'scalar rebound secret-index mutation is rejected by native IR operand provenance'
fi
grep -F -q 'call i64 @mdk_array__setInPlace(i64 %arg3,' "$WORK/scalar-rebound-index-mutant.ll" || fail 'scalar rebound secret-index mutation reaches native IR'
pass 'scalar rebound secret-index mutation is rejected by native IR operand provenance'

cp "$WORK/scalar_wrapper_source_mutant.mdk" "$WORK/scalar_wrapper_mutant.mdk"
append_scalar_probe "$WORK/scalar_wrapper_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_wrapper_mutant.mdk" -o "$WORK/scalar_wrapper_mutant" --keep-ir > "$WORK/build-scalar-wrapper-mutant.log" 2>&1
extract_function subNCandidate "$WORK/scalar_wrapper_mutant.ll" "$WORK/scalar-wrapper-subn.ll"
if ir_call_shape_ok subNCandidate "$WORK/scalar-wrapper-subn.ll"; then
  fail 'scalar leaky-wrapper mutation is rejected by native IR callee graph'
fi
grep -F -q '__leakyShift' "$WORK/scalar-wrapper-subn.ll" || fail 'scalar leaky-wrapper call reaches native IR'
pass 'scalar leaky-wrapper mutation is rejected by native IR callee graph'

cp "$WORK/scalar_copy_source_mutant.mdk" "$WORK/scalar_copy_mutant.mdk"
append_scalar_probe "$WORK/scalar_copy_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_copy_mutant.mdk" -o "$WORK/scalar_copy_mutant" --keep-ir > "$WORK/build-scalar-copy-mutant.log" 2>&1
extract_function copyLow "$WORK/scalar_copy_mutant.ll" "$WORK/scalar-copy-mutant.ll"
if helper_ir_ok "$WORK/scalar-copy-mutant.ll" 1 1 1 0 0 6 && ir_call_shape_ok copyLow "$WORK/scalar-copy-mutant.ll"; then
  fail 'scalar transitive copy mutation is rejected by emitted helper shape'
fi
grep -F -q 'mdk_value_eq' "$WORK/scalar-copy-mutant.ll" || fail 'scalar transitive copy branch reaches native IR'
pass 'scalar transitive copy mutation is rejected by emitted helper shape'

disassemble() {
  binary=$1
  symbol=$2
  output=$3
  case $(uname -s) in
    Darwin)
      otool -tvV "$binary" | awk -v label="_$symbol:" '
        $0 == label { inside = 1; next }
        inside && /^_[A-Za-z0-9_.$]+:$/ { exit }
        inside { print }
      ' > "$output"
      ;;
    *) objdump -d --disassemble="$symbol" "$binary" > "$output" ;;
  esac
}

conditional_jump_count() {
  file=$1
  case $(uname -m) in
    x86_64|amd64) grep -E -c '[[:space:]]j[a-z]+[[:space:]]' "$file" || true ;;
    arm64|aarch64) grep -E -c '[[:space:]](b\.[a-z]+|cbz|cbnz|tbz|tbnz)[[:space:]]' "$file" || true ;;
    *) return 2 ;;
  esac
}

current_symbol=$(find_native_symbol "$WORK/field_emit" selectPCandidate)
mutant_symbol=$(find_native_symbol "$WORK/field_branch_mutant" selectPCandidate)
[ -n "$current_symbol" ] || fail 'current final native select symbol exists'
[ -n "$mutant_symbol" ] || fail 'mutant final native select symbol exists'
disassemble "$WORK/field_emit" "$current_symbol" "$WORK/select-current.asm"
disassemble "$WORK/field_branch_mutant" "$mutant_symbol" "$WORK/select-mutant.asm"
if grep -F -q 'mdk_value_eq' "$WORK/select-current.asm"; then
  fail 'current final native disassembly has no secret equality selection'
fi
grep -F -q 'mdk_value_eq' "$WORK/select-mutant.asm" || fail 'conditional-select mutation is visible in final native disassembly'
pass 'conditional-select mutation is rejected by final native disassembly'

scalar_current_symbol=$(find_native_symbol "$WORK/scalar_emit" selectNCandidate)
scalar_mutant_symbol=$(find_native_symbol "$WORK/scalar_branch_mutant" selectNCandidate)
[ -n "$scalar_current_symbol" ] || fail 'current final native scalar select symbol exists'
[ -n "$scalar_mutant_symbol" ] || fail 'mutant final native scalar select symbol exists'
disassemble "$WORK/scalar_emit" "$scalar_current_symbol" "$WORK/scalar-select-current.asm"
disassemble "$WORK/scalar_branch_mutant" "$scalar_mutant_symbol" "$WORK/scalar-select-mutant.asm"
if grep -F -q 'mdk_value_eq' "$WORK/scalar-select-current.asm"; then
  fail 'current final native scalar select has no secret equality selection'
fi
grep -F -q 'mdk_value_eq' "$WORK/scalar-select-mutant.asm" || fail 'scalar conditional-select mutation is visible in final native disassembly'
pass 'scalar conditional-select mutation is rejected by final native disassembly'

field_helper_select_symbol=$(find_native_symbol "$WORK/field_emit" feSelectGo)
field_helper_select_mutant_symbol=$(find_native_symbol "$WORK/field_helper_select_emit" feSelectGo)
[ -n "$field_helper_select_symbol" ] || fail 'current final native field helper select symbol exists'
[ -n "$field_helper_select_mutant_symbol" ] || fail 'mutant final native field helper select symbol exists'
disassemble "$WORK/field_emit" "$field_helper_select_symbol" "$WORK/field-helper-select-current.asm"
disassemble "$WORK/field_helper_select_emit" "$field_helper_select_mutant_symbol" "$WORK/field-helper-select-mutant.asm"
if grep -F -q 'mdk_value_eq' "$WORK/field-helper-select-current.asm"; then
  fail 'current final field helper select has no secret equality selection'
fi
grep -F -q 'mdk_value_eq' "$WORK/field-helper-select-mutant.asm" || fail 'field helper conditional-select mutation is visible in final native helper'
pass 'field helper conditional-select mutation is rejected by final native control'

scalar_high_symbol=$(find_native_symbol "$WORK/scalar_emit" scHighBorrow)
scalar_high_mutant_symbol=$(find_native_symbol "$WORK/scalar_high_branch_emit" scHighBorrow)
[ -n "$scalar_high_symbol" ] || fail 'current final native scalar high-bit symbol exists'
[ -n "$scalar_high_mutant_symbol" ] || fail 'mutant final native scalar high-bit symbol exists'
disassemble "$WORK/scalar_emit" "$scalar_high_symbol" "$WORK/scalar-high-current.asm"
disassemble "$WORK/scalar_high_branch_emit" "$scalar_high_mutant_symbol" "$WORK/scalar-high-mutant.asm"
if grep -F -q 'mdk_value_eq' "$WORK/scalar-high-current.asm"; then
  fail 'current final scalar high-bit borrow has no secret equality control'
fi
grep -F -q 'mdk_value_eq' "$WORK/scalar-high-mutant.asm" || fail 'scalar high-bit secret-branch mutation is visible in final native helper'
pass 'scalar high-bit secret-branch mutation is rejected by final native control'

wrapper_symbol=$(find_native_symbol "$WORK/scalar_wrapper_mutant" subNCandidate)
[ -n "$wrapper_symbol" ] || fail 'scalar leaky-wrapper final native helper symbol exists'
disassemble "$WORK/scalar_wrapper_mutant" "$wrapper_symbol" "$WORK/scalar-wrapper-subn.asm"
grep -F -q 'mdk_value_eq' "$WORK/scalar-wrapper-subn.asm" || fail 'scalar leaky-wrapper branch reaches final native helper'
pass 'scalar leaky-wrapper mutation is visible in final native helper'

copy_symbol=$(find_native_symbol "$WORK/scalar_copy_mutant" copyLow)
[ -n "$copy_symbol" ] || fail 'scalar transitive copy final native helper symbol exists'
disassemble "$WORK/scalar_copy_mutant" "$copy_symbol" "$WORK/scalar-copy-mutant.asm"
grep -F -q 'mdk_value_eq' "$WORK/scalar-copy-mutant.asm" || fail 'scalar transitive copy branch reaches final native helper'
pass 'scalar transitive copy mutation is visible in final native helper'

field_reducer_symbol=$(find_native_symbol "$WORK/field_emit" fieldSelectWitness)
scalar_reducer_symbol=$(find_native_symbol "$WORK/scalar_emit" scalarSelectWitness)
[ -n "$field_reducer_symbol" ] || fail 'final native field reducer witness symbol exists'
[ -n "$scalar_reducer_symbol" ] || fail 'final native scalar reducer witness symbol exists'
disassemble "$WORK/field_emit" "$field_reducer_symbol" "$WORK/field-reducer.asm"
disassemble "$WORK/scalar_emit" "$scalar_reducer_symbol" "$WORK/scalar-reducer.asm"
field_round_calls=$(grep -F -c '__carryFoldRound' "$WORK/field-reducer.asm" || true)
[ "$field_round_calls" -eq 3 ] || fail "final field reducer has three fixed carry-round calls (got $field_round_calls)"
grep -F -q '__subPCandidate' "$WORK/field-reducer.asm" || fail 'final field reducer calls arithmetic subtraction candidate'
grep -F -q '__selectPCandidate' "$WORK/field-reducer.asm" || fail 'final field reducer calls arithmetic select'
pass 'final linked field reducer calls the approved helpers'
grep -F -q '__reduceFixed' "$WORK/scalar-reducer.asm" || fail 'final scalar reducer calls fixed fold schedule'
scalar_schedule_symbol=$(find_native_symbol "$WORK/scalar_emit" reduceFixed)
[ -n "$scalar_schedule_symbol" ] || fail 'final native scalar fixed schedule symbol exists'
disassemble "$WORK/scalar_emit" "$scalar_schedule_symbol" "$WORK/scalar-schedule.asm"
scalar_fold_calls=$(grep -F -c '__takeHigh' "$WORK/scalar-schedule.asm" || true)
[ "$scalar_fold_calls" -eq 4 ] || fail "final scalar reducer has four fixed fold bodies (got $scalar_fold_calls)"
scalar_carry_calls=$(grep -F -c '__carryGo' "$WORK/scalar-schedule.asm" || true)
[ "$scalar_carry_calls" -eq 5 ] || fail "final scalar reducer has five fixed carry calls (got $scalar_carry_calls)"
grep -F -q '__subNCandidate' "$WORK/scalar-reducer.asm" || fail 'final scalar reducer calls arithmetic subtraction candidate'
grep -F -q '__selectNCandidate' "$WORK/scalar-reducer.asm" || fail 'final scalar reducer calls arithmetic select'
pass 'final linked scalar reducer calls the approved helpers'

# Native bit helpers are C calls below the generated Medaka helpers. Inspect
# the linked implementations on the tested target; either helper growing a
# conditional jump invalidates the arithmetic proof.
for helper in mdk_bit_and mdk_bit_xor mdk_shift_right; do
  symbol=$(find_exact_symbol "$WORK/field_emit" "$helper")
  [ -n "$symbol" ] || fail "final native $helper symbol exists"
  disassemble "$WORK/field_emit" "$symbol" "$WORK/$helper.asm"
  jumps=$(conditional_jump_count "$WORK/$helper.asm") || fail "supported native target for $helper disassembly"
  [ "$jumps" -eq 0 ] || fail "final native $helper has no conditional jumps (got $jumps)"
  pass "final native $helper has no conditional jumps"
done

printf 'receipt: target=%s %s\n' "$(uname -s)" "$(uname -m)"
printf 'receipt: compiler=%s\n' "$(clang --version | sed -n '1p')"
printf 'receipt: medaka=%s\n' "$($MEDAKA --version | sed -n '1p')"

[ "$checked" -ge 54 ] || fail "anti-rot floor (expected at least 54, got $checked)"
printf 'PASS: constant-time reduction controls — %s assertions\n' "$checked"
