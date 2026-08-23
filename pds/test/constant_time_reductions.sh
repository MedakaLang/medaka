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

find_native_symbol() {
  binary=$1
  suffix=$2
  nm "$binary" | awk -v suffix="__$suffix" '$3 ~ (suffix "$") { sub(/^_/, "", $3); print $3; exit }'
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

main = if scalarRoundsWitness then println "PASS scalar-rounds" else panic "FAIL scalar-rounds"
EOF
}

run_probe() {
  file=$1
  expected=$2
  label=$3
  out="$WORK/probe.out"
  if MEDAKA_STRICT=1 "$MEDAKA" run "$file" > "$out" 2>&1 && grep -F -q "$expected" "$out"; then
    pass "$label"
  else
    cat "$out" >&2
    fail "$label"
  fi
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

# Native emitted-control check. Current helpers have one public-counter branch.
# A mutation replacing the arithmetic blend with a secret-derived `if` must add
# a second branch and red both the IR and final-disassembly controls.
cp "$FIELD" "$WORK/field_emit.mdk"
append_field_probe "$WORK/field_emit.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/field_emit.mdk" -o "$WORK/field_emit" --keep-ir > "$WORK/build.log" 2>&1
extract_function selectPCandidate "$WORK/field_emit.ll" "$WORK/select-current.ll"
current_ir_branches=$(grep -c 'br i1' "$WORK/select-current.ll" || true)
[ "$current_ir_branches" -eq 1 ] || fail "current native IR has one public-counter branch (got $current_ir_branches)"
pass 'current native IR has only the public-counter branch'

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

current_symbol=$(find_native_symbol "$WORK/field_emit" selectPCandidate)
mutant_symbol=$(find_native_symbol "$WORK/field_branch_mutant" selectPCandidate)
[ -n "$current_symbol" ] || fail 'current final native select symbol exists'
[ -n "$mutant_symbol" ] || fail 'mutant final native select symbol exists'
disassemble "$WORK/field_emit" "$current_symbol" "$WORK/select-current.asm"
disassemble "$WORK/field_branch_mutant" "$mutant_symbol" "$WORK/select-mutant.asm"
grep -E -q '[[:space:]]imul[[:space:]]' "$WORK/select-current.asm" || fail 'current final native disassembly retains arithmetic blend'
if grep -F -q 'mdk_value_eq' "$WORK/select-current.asm"; then
  fail 'current final native disassembly has no secret equality selection'
fi
grep -F -q 'mdk_value_eq' "$WORK/select-mutant.asm" || fail 'conditional-select mutation is visible in final native disassembly'
if grep -E -q '[[:space:]]imul[[:space:]]' "$WORK/select-mutant.asm"; then
  fail 'conditional-select mutant must not retain arithmetic blend'
fi
pass 'conditional-select mutation is rejected by final native disassembly'

[ "$checked" -ge 14 ] || fail "anti-rot floor (expected at least 14, got $checked)"
printf 'PASS: constant-time reduction controls — %s assertions\n' "$checked"
