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
    expected_indices=${rest##*:}
    body="$dir/$name.ll"
    extract_function "$name" "$ir" "$body"
    helper_ir_ok "$body" "$expected" "$expected_indices" || fail "$name native IR operation/control shape"
  done
}

helper_ir_ok() {
  body=$1
  expected=$2
  expected_indices=$3
  branches=$(grep -c 'br i1' "$body" || true)
  comparisons=$(grep -E -c 'call i64 @mdk_value_(eq|ne|lt|le|gt|ge)\(' "$body" || true)
  hashes=$(grep -F -c 'call i64 @mdk_hash_bool(' "$body" || true)
  indices=$(grep -F -c 'call i64 @mdk_impl_Array_index(' "$body" || true)
  [ "$branches" -eq "$expected" ] && [ "$comparisons" -eq "$expected" ] && [ "$hashes" -eq 0 ] && [ "$indices" -eq "$expected_indices" ]
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
    "reduceWide:$scalar:0"
  do
    name=${spec%%:*}
    rest=${spec#*:}
    file=${rest%:*}
    allowed=${spec##*:}
    body="$dir/$name.mdk"
    extract_source_function "$name" "$file" "$body" || return 1
    actual=$(awk '{ line=$0; while (match(line, /if[[:space:]]/)) { n++; line=substr(line, RSTART + RLENGTH) } } END { print n + 0 }' "$body")
    [ "$actual" -eq "$allowed" ] || return 1
    comparisons=$(awk '{ line=$0; while (match(line, /(==|\/=|<=|>=| < | > )/)) { n++; line=substr(line, RSTART + RLENGTH) } } END { print n + 0 }' "$body")
    expected_comparisons=$allowed
    if [ "$name" = carryGo ]; then expected_comparisons=3; fi
    [ "$comparisons" -eq "$expected_comparisons" ] || return 1
    if grep -F -q 'hashBool' "$body"; then return 1; fi
    source_indices_ok "$body" || return 1
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
  let () = set 9 (shiftLeft 1 43 - 1) raw
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

main = if fieldRoundsWitness && fieldSelectWitness then println "PASS field-rounds" else panic "FAIL field-rounds"
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

main = if scalarRoundsWitness && scalarSelectWitness then println "PASS scalar-rounds" else panic "FAIL scalar-rounds"
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
  /let \(\) = A.set i \(original \+ keepDiff \* \(diff\[i\] - original\)\) w/ {
    print "    let () = if keepDiff == 1 then A.set i diff[i] w else A.set i original w"
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
    print "    let () = A.set i (w[i] + 0 * secret) w"
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
    print "    let () = A.set i (w[i] + 0 * sampled) w"
    print
    next
  }
  { print }
' "$SCALAR" > "$WORK/scalar_index_source_mutant.mdk"
if source_helpers_ok "$FIELD" "$WORK/scalar_index_source_mutant.mdk" "$WORK/source-scalar-index-mutant"; then
  fail 'scalar secret-index mutation is rejected by source structure'
fi
pass 'scalar secret-index mutation is rejected by source structure'

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
  carryPassGo:1:3 carryFoldRound:0:2 reduceCarry:0:0 subPCandidate:1:4 \
  selectPCandidate:1:2 subPSelect:0:0 canonicalize:0:0
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

cp "$WORK/field_borrow_source_mutant.mdk" "$WORK/field_borrow_branch_mutant.mdk"
append_field_probe "$WORK/field_borrow_branch_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/field_borrow_branch_mutant.mdk" -o "$WORK/field_borrow_branch_mutant" --keep-ir > "$WORK/build-borrow-mutant.log" 2>&1
extract_function subPCandidate "$WORK/field_borrow_branch_mutant.ll" "$WORK/borrow-mutant.ll"
borrow_mutant_ir_branches=$(grep -c 'br i1' "$WORK/borrow-mutant.ll" || true)
[ "$borrow_mutant_ir_branches" -gt "$field_borrow_ir_branches" ] || fail 'field borrow mutation is rejected by native IR control'
grep -F -q 'mdk_value_eq' "$WORK/borrow-mutant.ll" || fail 'field borrow mutation exposes equality in native IR'
pass 'field borrow mutation is rejected by native IR control'

awk '
  /let \(\) = set i \(original \+ keepDiff \* \(diff\[i\] - original\)\) n/ {
    print "    let () = if keepDiff == 1 then set i diff[i] n else set i original n"
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
  carryGo:2:1 takeHigh:1:1 foldAccum:1:0 foldAccumRow:1:3 foldOnce:0:0 reduceFixed:0:0 \
  subNCandidate:1:2 selectNCandidate:1:2 subNSelect:0:0 reduceWide:0:0
extract_function selectNCandidate "$WORK/scalar_emit.ll" "$WORK/scalar-select-current.ll"
extract_function subNCandidate "$WORK/scalar_emit.ll" "$WORK/scalar-borrow-current.ll"
[ "$(grep -c 'br i1' "$WORK/scalar-select-current.ll" || true)" -eq 1 ] || fail 'current scalar select IR has only its public-counter branch'
[ "$(grep -c 'br i1' "$WORK/scalar-borrow-current.ll" || true)" -eq 1 ] || fail 'current scalar borrow IR has only its public-counter branch'
if grep -F -q 'mdk_value_eq' "$WORK/scalar-select-current.ll" "$WORK/scalar-borrow-current.ll"; then
  fail 'current scalar reduction IR contains secret equality control'
fi
pass 'current scalar IR has only public-counter control'
pass 'complete scalar reducer IR matches the approved helper control shape'

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
if helper_ir_ok "$WORK/scalar-hash-mutant.ll" 1 2; then
  fail 'scalar comparison/hashBool mutation is rejected by native IR operation allowlist'
fi
grep -F -q 'mdk_hash_bool' "$WORK/scalar-hash-mutant.ll" || fail 'scalar comparison/hashBool mutation reaches native IR'
pass 'scalar comparison/hashBool mutation is rejected by native IR operation allowlist'

cp "$WORK/scalar_index_source_mutant.mdk" "$WORK/scalar_index_mutant.mdk"
append_scalar_probe "$WORK/scalar_index_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_index_mutant.mdk" -o "$WORK/scalar_index_mutant" --keep-ir > "$WORK/build-scalar-index-mutant.log" 2>&1
extract_function selectNCandidate "$WORK/scalar_index_mutant.ll" "$WORK/scalar-index-mutant.ll"
if helper_ir_ok "$WORK/scalar-index-mutant.ll" 1 2; then
  fail 'scalar secret-index mutation is rejected by native IR call shape'
fi
index_calls=$(grep -F -c 'call i64 @mdk_impl_Array_index(' "$WORK/scalar-index-mutant.ll" || true)
[ "$index_calls" -gt 2 ] || fail 'scalar secret-index mutation reaches native IR'
pass 'scalar secret-index mutation is rejected by native IR call shape'

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
for helper in mdk_bit_and mdk_shift_right; do
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

[ "$checked" -ge 31 ] || fail "anti-rot floor (expected at least 31, got $checked)"
printf 'PASS: constant-time reduction controls — %s assertions\n' "$checked"
