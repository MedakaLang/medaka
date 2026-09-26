#!/bin/sh
# Fixed-control regression for #1724's field/scalar reduction contract, and a
# source census that pds credential, JWT and session comparisons on secret
# bytes go only through crypto.hmac.ctEq (#2953).
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
    expected_comparisons=${rest%%:*}
    rest=${rest#*:}
    expected_indices=${rest%%:*}
    rest=${rest#*:}
    expected_sets=${rest%%:*}
    rest=${rest#*:}
    expected_makes=${rest%%:*}
    rest=${rest#*:}
    expected_copies=${rest%%:*}
    rest=${rest#*:}
    expected_total=${rest%%:*}
    rest=${rest#*:}
    expected_allocs=${rest%%:*}
    public_args=${rest##*:}
    body="$dir/$name.ll"
    extract_function "$name" "$ir" "$body"
    helper_ir_ok "$body" "$expected" "$expected_comparisons" "$expected_indices" "$expected_sets" "$expected_makes" "$expected_copies" "$expected_total" "$expected_allocs" || fail "$name native IR operation/control shape"
    ovf_operands_public "$body" "$public_args" || fail "$name overflow checks test only its public counter arguments"
    ir_call_shape_ok "$name" "$body" || fail "$name native IR exact callee graph"
  done
}

# Re-derived when the limbs moved from Int to U64 (#3427), callee by callee
# against the previous pins. In every changed helper the Int runtime bit calls
# (mdk_bit_and, mdk_shift_right) became the u64 module's (mdk_u64__bitAnd,
# mdk_u64__shiftRight, mdk_u64__bitXor) one for one, and the lazy-constant
# forces (mdk_force_*__limbMask, topMask, pLimbs, foldLow, foldHi, nLimbs,
# cLimbs, feZero) are gone because a U64 constant is emitted as static data.
# The public-bit boundaries gained one conversion each: feZeroBit, feEqualBit,
# scZeroBit, scEqualBit and scHighBit call mdk_u64__toIntTruncating, and
# feSelect and scSelect call mdk_u64__truncate. `+ - *` at U64 are inline
# instructions, not calls. No branch moved (helper_ir_ok's counts below); the
# u64 callees themselves are audited by u64_callees_ok.
ir_call_shape_ok() {
  name=$1
  body=$2
  case "$name" in
    canonicalize) expected='444837400 70' ;; carryFoldRound) expected='394656806 112' ;;
    carryAll) expected='136326906 25' ;; carryGo) expected='2429896786 133' ;;
    carryAllUnchecked) expected='2496061766 34' ;; carryGoUnchecked) expected='2695333142 142' ;;
    carryPass) expected='2881939388 28' ;; carryPassGo) expected='220273752 229' ;;
    copyLow) expected='2044746140 68' ;;
    foldAccum) expected='2494560624 57' ;; foldAccumRow) expected='2529586163 115' ;;
    foldOnce) expected='856892605 68' ;; reduceCarry) expected='1494584225 93' ;;
    reduceFixed) expected='2618126692 279' ;; reduceWide) expected='46832935 97' ;;
    selectNCandidate) expected='2597000302 98' ;; selectPCandidate) expected='884186827 97' ;;
    subNCandidate) expected='3275809941 131' ;; subNSelect) expected='662374009 80' ;;
    subPCandidate) expected='2491135283 230' ;; subPSelect) expected='1367941064 78' ;;
    takeHigh) expected='3467411543 120' ;;
    feZeroBit) expected='3823044379 76' ;; feZeroBorrow) expected='1168515091 111' ;;
    feEqualBit) expected='1284814038 99' ;; feEqualBorrow) expected='3906248674 186' ;;
    feSelect) expected='3453253130 104' ;; feSelectGo) expected='1891909016 112' ;;
    feNegateCt) expected='852396593 117' ;; feNegateCtGo) expected='3189841381 209' ;;
    scZeroBit) expected='4108822990 78' ;; scZeroBorrow) expected='3042275777 71' ;;
    scEqualBit) expected='2016533447 102' ;; scEqualBorrow) expected='2666357995 109' ;;
    scSelect) expected='4019753109 107' ;; scSelectGo) expected='2865420383 113' ;;
    scHighBit) expected='1535123734 78' ;; scHighBorrow) expected='883435820 92' ;;
    scNegateCt) expected='2833578003 121' ;; scNegateCtGo) expected='649975833 130' ;;
    *) return 1 ;;
  esac
  actual=$(sed -n 's/.*call i64 @\([^ (]*\).*/\1/p' "$body" | cksum | awk '{ print $1 " " $2 }')
  [ "$actual" = "$expected" ]
}

# Since Int overflow traps (#3377), every Int `+ - *` lowers to an
# llvm.s{add,sub,mul}.with.overflow call and a branch to @mdk_int_overflow. In
# these helpers the only Int arithmetic is on the public limb counters, so each
# such branch must test a value built only from literals and the helper's
# counter arguments ($2, `+`-separated argument indexes). A register is public
# when it is one of those arguments or is computed, by plain arithmetic or an
# overflow intrinsic's extractvalue, from public registers and literals; any
# other call result, load or cell payload is not. Every overflow intrinsic's
# operands must be public, and the branch counts pinned in helper_ir_ok are
# then the loop branch plus one overflow branch per counter operation.
ovf_operands_public() {
  awk -v pub="$2" '
    BEGIN { n = split(pub, p, "+"); for (k = 1; k <= n; k++) public["%arg" p[k]] = 1 }
    /^  %[A-Za-z0-9_.]+ = / {
      dst = $1
      rest = $0
      sub(/^  %[A-Za-z0-9_.]+ = /, "", rest)
      op = rest
      sub(/ .*/, "", op)
      ovf = (rest ~ /@llvm\.s(add|sub|mul)\.with\.overflow/)
      ok = (op ~ /^(add|sub|mul|ashr|shl|or|and|xor|extractvalue)$/) || ovf
      body = rest
      sub(/^[^%]*/, "", body)
      all = 1
      while (match(body, /%[A-Za-z0-9_.]+/)) {
        r = substr(body, RSTART, RLENGTH)
        if (!(r in public)) all = 0
        body = substr(body, RSTART + RLENGTH)
      }
      if (ovf) { seen++; if (!all) bad++ }
      if (ok && all) public[dst] = 1
    }
    END { exit !(bad == 0) }
  ' "$1"
}

# The limb helpers call into stdlib/u64.mdk (#3427), outside the local closure
# that emitted_local_closure_ok walks, so each u64 callee is audited here
# against a closed allowlist. The bit operations and both conversions are
# straight-line. Each shift carries its two amount branches (negative panics,
# then the guard chain's `otherwise`), and every shift call in a helper must
# pass a literal amount (tagged, so 26 is 53): a shift amount is never
# secret-derived (docs/design/ATPROTO-PDS-CONSTANT-TIME.md §5.1). The
# width-64 select inside the shift is an LLVM `select`, not a branch.
u64_callees_ok() {
  ir=$1
  dir=$2
  cat "$dir"/*.ll > "$dir.u64-bodies"
  callees=$(sed -n 's/.*call i64 @\(mdk_u64__[A-Za-z0-9_]*\)(.*/\1/p' "$dir.u64-bodies" | sort -u)
  [ -n "$callees" ] || return 1
  for callee in $callees; do
    case $callee in
      mdk_u64__bitAnd|mdk_u64__bitXor|mdk_u64__truncate|mdk_u64__toIntTruncating) want=0 ;;
      mdk_u64__shiftRight) want=2 ;;
      *) return 1 ;;
    esac
    awk -v s="$callee" '$0 ~ ("^define i64 @" s "\\(") { p = 1 } p { print } p && /^}/ { exit }' "$ir" > "$dir.u64-callee.ll"
    [ -s "$dir.u64-callee.ll" ] || return 1
    [ "$(grep -c 'br i1' "$dir.u64-callee.ll" || true)" -eq "$want" ] || return 1
  done
  shifts=$(grep -c 'call i64 @mdk_u64__shift' "$dir.u64-bodies" || true)
  literal=$(grep -E -c 'call i64 @mdk_u64__shift(Left|Right)\(i64 %[a-z0-9]+, i64 [0-9]+\)' "$dir.u64-bodies" || true)
  [ "$shifts" -gt 0 ] && [ "$shifts" -eq "$literal" ]
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

# A source-level comparison reaches the emitted IR by one of two lowerings: an
# opaque @mdk_value_* call, or -- once the emitter knows both operands are
# scalars -- an inline icmp. The mutation detectors below named only the call
# form, so they went silently blind the day that choice changed: the mutants
# still emitted their secret comparison and the greps stopped finding it.
# `icmp eq` is the discriminator for the inline form. None of the 38 pinned
# clean helpers contains one -- a loop bound lowers to `icmp sge` and the
# truthiness test to `icmp ne %t, 0` -- so an equality appears only where a
# mutation introduced it.
emitted_comparison_present() {
  grep -E -q 'call i64 @mdk_value_(eq|ne|lt|le|gt|ge)\(|= icmp eq i64 ' "$1"
}

# Branch count and value-comparison count are separate properties and are counted
# separately. A helper's branches are its public-counter loop control, which must
# not move; its @mdk_value_* comparisons are opaque runtime calls, which must not
# appear at all on a secret path. These were one shared number until the emitter
# began lowering a comparison on known-scalar operands to an inline icmp, at which
# point "one branch" and "one comparison call" stopped being the same claim.
#
# The optional ninth count is the helper's U64 cell allocations. Since #3427
# every limb is a boxed U64, so each `+ - *` on a limb allocates one 16-byte
# atomic cell inline (`call ptr @mdk_alloc_atomic`, which the `call i64` total
# does not count). The count per call is fixed by the helper's straight-line
# body, so with the branch counts pinned the whole reduction's allocation
# schedule is input-independent; pinning it catches a change to that schedule.
helper_ir_ok() {
  body=$1
  expected=$2
  expected_comparisons=$3
  expected_indices=$4
  expected_sets=$5
  expected_makes=$6
  expected_copies=$7
  expected_total=$8
  expected_allocs=${9:-}
  if [ -n "$expected_allocs" ]; then
    [ "$(grep -F -c 'call ptr @mdk_alloc_atomic(' "$body" || true)" -eq "$expected_allocs" ] || return 1
  fi
  branches=$(grep -c 'br i1' "$body" || true)
  comparisons=$(grep -E -c 'call i64 @mdk_value_(eq|ne|lt|le|gt|ge)\(' "$body" || true)
  hashes=$(grep -F -c 'call i64 @mdk_hash_bool(' "$body" || true)
  indices=$(grep -F -c 'call i64 @mdk_impl_Array_index(' "$body" || true)
  sets=$(grep -F -c 'call i64 @mdk_array__setInPlace(' "$body" || true)
  makes=$(grep -F -c 'call i64 @mdk_array_make(' "$body" || true)
  copies=$(grep -F -c 'call i64 @mdk_array_copy(' "$body" || true)
  total=$(grep -E -c 'call i64 @' "$body" || true)
  [ "$branches" -eq "$expected" ] && [ "$comparisons" -eq "$expected_comparisons" ] &&
    [ "$hashes" -eq 0 ] && [ "$indices" -eq "$expected_indices" ] &&
    [ "$sets" -eq "$expected_sets" ] && [ "$makes" -eq "$expected_makes" ] &&
    [ "$copies" -eq "$expected_copies" ] && [ "$total" -eq "$expected_total" ]
}

# The opaque-value accessors -- rawFe over `Fe (Array Int)` and rawSc over its
# scalar counterpart -- unwrap a single-constructor box and return the limbs.
# The only control they may hold is representation dispatch, never anything
# derived from the limbs.
#
# BRANCH COUNT IS THE PROPERTY; every other count here is its witness.  The
# branches fell from two to one when the emitter began loading a constructor
# discriminant directly for a roster it knows is always boxed: what went was the
# generic immediate-vs-boxed split, whose two arms fetched the same tag word two
# different ways into a phi.  Both accessors moved together and both are at one,
# and the surviving conyes/connext pair compares the constructor tag against a
# compile-time constant.  A branch count alone would be strictly weaker than the
# two it replaces, so the comparisons are pinned too: each must have an integer
# literal right operand, which a comparison on a limb (register right operand)
# cannot satisfy.
#
# That direct load carries a pointer guard, so the comparison count is 2, not 1:
# the second `icmp` tests the scrutinee`s low tag bit and feeds a `select` over
# the ADDRESS to load from, never a branch.  The guard is therefore branchless by
# construction and the accessor`s timing is unchanged -- which is what the pinned
# `select` count below asserts, and what would catch a guard that grew a branch
# instead.  (Same column-audit discipline as FIX-pds-constant-time-audit,
# 9b956cb42: move a pinned constant only with the measurement and the reason.)
raw_accessor_ir_ok() {
  body=$1
  [ "$(grep -c 'br i1' "$body" || true)" -eq 1 ] &&
    [ "$(grep -E -c '= icmp ' "$body" || true)" -eq 2 ] &&
    [ "$(grep -E -c '= icmp eq i64 %t[0-9]+, [0-9]+$' "$body" || true)" -eq 2 ] &&
    [ "$(grep -E -c '= select i1 ' "$body" || true)" -eq 1 ] &&
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
    carryGo|carryGoUnchecked|subNCandidate|selectNCandidate|copyLow|scSelectGo|scNegateCtGo)
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

# Re-derived for the same U64 move (#3427). Each changed body differs from its
# predecessor only in type signatures, `U64.`-qualified bit operations, the
# `(0 : U64)` element of a fresh limb array, and the toIntTruncating/truncate
# at a public-bit boundary; the if/comparison/index/write shape checked below
# is unchanged for every helper.
source_shape_ok() {
  name=$1
  body=$2
  case "$name" in
    canonicalize) expected='1918979222 101' ;; carryAll) expected='3784023453 28' ;;
    carryFoldRound) expected='702085150 126' ;; carryGo) expected='2843291073 275' ;;
    carryAllUnchecked) expected='2587065717 46' ;; carryGoUnchecked) expected='1758010447 197' ;;
    carryPass) expected='1250453555 31' ;; carryPassGo) expected='3660746618 300' ;;
    copyLow) expected='3444459846 115' ;;
    foldAccum) expected='305940905 111' ;; foldAccumRow) expected='1512181526 160' ;;
    foldOnce) expected='3517364329 92' ;; reduceCarry) expected='2596813441 92' ;;
    reduceFixed) expected='3041539658 251' ;; reduceWide) expected='3684934851 136' ;;
    selectNCandidate) expected='1327350681 214' ;; selectPCandidate) expected='3621980786 212' ;;
    subNCandidate) expected='2419756525 238' ;; subNSelect) expected='3219333414 133' ;;
    subPCandidate) expected='3232611083 358' ;; subPSelect) expected='792153305 133' ;;
    feZeroBit) expected='4261807061 64' ;; feZeroBorrow) expected='1071263767 220' ;;
    feEqualBit) expected='2440058190 78' ;; feEqualBorrow) expected='2854987013 258' ;;
    feSelect) expected='2475983951 131' ;; feSelectGo) expected='3969226401 161' ;;
    feNegateCt) expected='1139195637 134' ;; feNegateCtGo) expected='2472039297 322' ;;
    rawFe) expected='714619739 33' ;;
    scZeroBit) expected='2621290499 64' ;; scZeroBorrow) expected='3067078386 164' ;;
    scEqualBit) expected='923624303 78' ;; scEqualBorrow) expected='1506975624 186' ;;
    scSelect) expected='3768238194 131' ;; scSelectGo) expected='2097560298 163' ;;
    scHighBit) expected='47819161 68' ;; scHighBorrow) expected='2694192358 180' ;;
    scNegateCt) expected='3043829585 134' ;; scNegateCtGo) expected='2837055382 236' ;;
    rawSc) expected='3051169895 33' ;;
    takeHigh) expected='2788456482 152' ;; *) return 1 ;;
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
    "carryAllUnchecked:$scalar:0" \
    "carryGoUnchecked:$scalar:1" \
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
      tr -s '[:space:]' ' ' < "$body" | grep -F -q 'if i >= nWide then if carry /= 0 then panic' || return 1
    fi
  done
  return 0
}

# Occurrences of identifier $1 in $2 as a whole word, comment lines excluded.
count_word() {
  awk -v w="$1" '
    /^[[:space:]]*--/ { next }
    {
      line = " " $0 " "
      while (match(line, "[^A-Za-z0-9_\047]" w "[^A-Za-z0-9_\047]")) {
        n++
        line = substr(line, RSTART + RLENGTH - 1)
      }
    }
    END { print n + 0 }
  ' "$2"
}

# One top-level declaration: its signature, its clauses, and their indented
# continuation lines, up to the next column-0 line that belongs to another name.
extract_source_decl() {
  name=$1
  input=$2
  output=$3
  awk -v name="$name" '
    $0 ~ ("^" name " ") { inside = 1; print; next }
    inside && /^[^[:space:]]/ { exit }
    inside && $0 !~ /^[[:space:]]*--/ { print }
  ' "$input" > "$output"
  [ -s "$output" ]
}

# How many `ctEq` calls in $1 compare an argument with itself. The file is read
# as one token stream with comments dropped, so a call split over continuation
# lines is still one call; a column-0 line starts a new declaration, and no
# argument is taken across it. Two arguments match when their tokens match
# after every parenthesis that wraps a single token or a whole argument is
# removed, so `(digest)`, `( digest )` and `digest` are one text. A call's
# arguments are the atoms after `ctEq`; past the `)` of a group in head
# position, as in `(ctEq a) b`; and, when fewer than two follow, the left
# operand of a `|>` feeding `ctEq a` or `(ctEq a)`, or the atom applied to a
# right section `(|> ctEq a)`.
cteq_tautologies() {
  awk '
    function push(t) { ntok++; tok[ntok] = t }
    function tokenize(s,    c, i, op) {
      while (length(s) > 0) {
        if (nest > 0) {
          if (substr(s, 1, 2) == "-}") { nest--; s = substr(s, 3) }
          else if (substr(s, 1, 2) == "{-") { nest++; s = substr(s, 3) }
          else { s = substr(s, 2) }
          continue
        }
        c = substr(s, 1, 1)
        if (c ~ /[[:space:]]/) { s = substr(s, 2); continue }
        if (substr(s, 1, 2) == "{-") { nest++; s = substr(s, 3); continue }
        if (match(s, /^[A-Za-z_][A-Za-z0-9_\047]*(\.[A-Za-z_][A-Za-z0-9_\047]*)*/) ||
            match(s, /^[0-9][A-Za-z0-9_.]*/)) {
          push(substr(s, 1, RLENGTH)); s = substr(s, RLENGTH + 1); continue
        }
        if (c == "\"") {
          i = 2
          while (i <= length(s) && substr(s, i, 1) != "\"") {
            if (substr(s, i, 1) == "\\") { i++ }
            i++
          }
          push(substr(s, 1, i)); s = substr(s, i + 1); continue
        }
        if (c == "\047") {
          i = (substr(s, 2, 1) == "\\") ? 4 : 3
          push(substr(s, 1, i)); s = substr(s, i + 1); continue
        }
        if (match(s, /^[-!#$%&*+.\/<=>?@\\^|~:]+/)) {
          op = substr(s, 1, RLENGTH)
          if (op ~ /^--+$/) { return }
          push(op); s = substr(s, RLENGTH + 1); continue
        }
        push(c); s = substr(s, 2)
      }
    }
    function is_kw(t) {
      return t ~ /^(if|then|else|let|in|match|with|case|of|do|where|when|import|export|public|data|type|interface|impl)$/
    }
    function is_word(t) { return t ~ /^[A-Za-z_0-9"\047]/ && !is_kw(t) }
    function starts_atom(t) { return is_word(t) || t == "(" || t == "[" || t == "{" }
    function ends_atom(t) { return is_word(t) || t == ")" || t == "]" || t == "}" }
    function close_at(i,    d, j) {
      d = 0
      for (j = i; j <= ntok; j++) {
        if (tok[j] == ";") { return 0 }
        if (tok[j] == "(" || tok[j] == "[" || tok[j] == "{") { d++ }
        else if (tok[j] == ")" || tok[j] == "]" || tok[j] == "}") {
          d--
          if (d == 0) { return j }
        }
      }
      return 0
    }
    function open_at(i,    d, j) {
      d = 0
      for (j = i; j >= 1; j--) {
        if (tok[j] == ";") { return 0 }
        if (tok[j] == ")" || tok[j] == "]" || tok[j] == "}") { d++ }
        else if (tok[j] == "(" || tok[j] == "[" || tok[j] == "{") {
          d--
          if (d == 0) { return j }
        }
      }
      return 0
    }
    function atom_end(i) {
      if (is_word(tok[i])) { return i }
      if (tok[i] == "(" || tok[i] == "[" || tok[i] == "{") { return close_at(i) }
      return 0
    }
    function norm(a, b,    out, j, e, inner) {
      while (a + 1 < b && tok[a] == "(" && close_at(a) == b) { a++; b-- }
      out = ""
      for (j = a; j <= b; j++) {
        e = 0
        if (tok[j] == "(") { e = close_at(j) }
        if (e > j + 1 && e <= b) {
          inner = norm(j + 1, e - 1)
          if (index(inner, " ") > 0) { inner = "( " inner " )" }
          out = out (out == "" ? "" : " ") inner
          j = e
        } else {
          out = out (out == "" ? "" : " ") tok[j]
        }
      }
      return out
    }
    function left_operand(p,    q, s, first) {
      first = 0
      q = p - 1
      while (q >= 1 && ends_atom(tok[q])) {
        if (is_word(tok[q])) { s = q } else { s = open_at(q) }
        if (s == 0) { break }
        first = s
        q = s - 1
      }
      return first ? norm(first, p - 1) : ""
    }
    /^[[:space:]]*--/ && nest == 0 { next }
    {
      if (nest == 0 && $0 ~ /^[^[:space:]]/) { push(";") }
      tokenize($0)
    }
    END {
      for (k = 1; k <= ntok; k++) {
        if (tok[k] != "ctEq") { continue }
        nargs = 0
        opens = 0
        while (k - opens - 1 >= 1 && tok[k - opens - 1] == "(") { opens++ }
        closed = 0
        j = k + 1
        while (nargs < 2 && j <= ntok) {
          if (starts_atom(tok[j])) {
            e = atom_end(j)
            if (e == 0) { break }
            arg[++nargs] = norm(j, e)
            j = e + 1
          } else if (tok[j] == ")" && closed < opens && !ends_atom(tok[k - closed - 2])) {
            closed++
            j++
          } else {
            break
          }
        }
        p = k - closed - 1
        if (nargs < 2 && p >= 1 && tok[p] == "|>") {
          if (p > 1 && tok[p - 1] == "(" && tok[j] == ")" && close_at(p - 1) == j &&
              !ends_atom(tok[p - 2]) && starts_atom(tok[j + 1])) {
            e = atom_end(j + 1)
            if (e > 0) { arg[++nargs] = norm(j + 1, e) }
          } else {
            s = left_operand(p)
            if (s != "") { arg[++nargs] = s }
          }
        }
        if (nargs == 2 && arg[1] != "" && arg[1] == arg[2]) { n++ }
      }
      print n + 0
    }
  ' "$1"
}

# The password-digest, JWT-signature and session-fingerprint comparisons reach
# secret bytes only through crypto.hmac.ctEq. Per file: ctEq is the imported one (no
# local definition shadows it), its occurrence count is the call-site roster,
# and no `==`, `/=` or `compare` line names a secret-bearing identifier except
# through `arrayLength`, whose value is public. Per comparing function: its
# stated number of ctEq calls and no other comparison, XOR accumulation or
# indexing beside them. The per-function roster is complete: each file's
# ctEq count is its import plus the roster's calls in that file, so a new
# comparing function the roster does not name fails the census.
# A `||` across session records stays legal -- it reveals which record matched,
# never a byte of one. Three further checks are file-wide, independent of the
# roster: no line builds an equality from `arrayToList`, no `ctEq` reference is
# reached through a dot-qualified name, and no `ctEq` call's two arguments
# have the same text once whitespace, line breaks and redundant parentheses
# are set aside, wherever application places them (`cteq_tautologies`) --
# only the file's own unaliased, selectively-imported `ctEq` counts toward the
# roster above, and only a call whose two argument texts actually differ.
#
# This is a source-text census, and it stays blind to what a call's own
# arguments EVALUATE to: two textually different expressions that are
# dynamically equal -- e.g. a `let`-bound alias beside the name it aliases,
# one argument wrapped in an identity-like call such as `arrayCopy`, two calls
# into a helper that always returns the same secret, a value passed through a
# lambda or a composition, or an alias reached through two different field
# paths -- still
# satisfy the argument-distinctness check above while comparing a value
# against itself, so any OTHER comparator beside it in that function or file
# -- a bare `==`, an `(==)` section, `Ord`'s `<`/`>`, `elem`, a hand-written
# `eq`, or a call into another module -- can still perform the real,
# non-constant-time comparison undetected. Closing that gap needs the IR
# level, tracked as #2838.
secret_comparisons_ok() {
  credential=$1
  jwt=$2
  store=$3
  dir=$4
  mkdir -p "$dir"
  for spec in \
    "$credential:3:digest password derived stored" \
    "$jwt:2:secret expected sigSeg" \
    "$store:9:secret wanted access refresh token fingerprint family consumed previous"
  do
    file=${spec%%:*}
    rest=${spec#*:}
    expected_calls=${rest%%:*}
    secrets=${rest#*:}
    [ "$(grep -F -x -c 'import crypto.hmac.{ctEq}' "$file" || true)" -eq 1 ] || return 1
    [ "$(grep -c '^ctEq[[:space:]]' "$file" || true)" -eq 0 ] || return 1
    [ "$(count_word ctEq "$file")" -eq "$expected_calls" ] || return 1
    leaks=$(awk -v secrets="$secrets" '
      /^[[:space:]]*--/ { next }
      /==|\/=|compare/ {
        line = " " $0 " "
        gsub(/arrayLength [A-Za-z0-9_\047]+/, "", line)
        k = split(secrets, ids, " ")
        for (j = 1; j <= k; j++) {
          if (match(line, "[^A-Za-z0-9_\047.]" ids[j] "[^A-Za-z0-9_\047]")) { n++ }
        }
      }
      END { print n + 0 }
    ' "$file")
    [ "$leaks" -eq 0 ] || return 1
    arraytolist_eq=$(awk '
      /^[[:space:]]*--/ { next }
      /arrayToList/ && /==|\/=|compare/ { n++ }
      END { print n + 0 }
    ' "$file")
    [ "$arraytolist_eq" -eq 0 ] || return 1
    if grep -E -q '[A-Za-z_][A-Za-z0-9_]*\.ctEq' "$file"; then return 1; fi
    [ "$(cteq_tautologies "$file")" -eq 0 ] || return 1
  done
  roster_credential=0
  roster_jwt=0
  roster_store=0
  for spec in \
    "credentialVerify:credential:1" \
    "digestIs:credential:1" \
    "verifySegments:jwt:1" \
    "liveRefresh:store:1" \
    "consumedRefresh:store:1" \
    "withoutConsumed:store:1" \
    "hasAccess:store:1" \
    "withoutRefresh:store:1" \
    "withoutFamily:store:2" \
    "storeSessionClose:store:1"
  do
    name=${spec%%:*}
    rest=${spec#*:}
    which=${rest%%:*}
    calls=${rest#*:}
    case $which in
      credential) file=$credential; roster_credential=$((roster_credential + calls)) ;;
      jwt) file=$jwt; roster_jwt=$((roster_jwt + calls)) ;;
      store) file=$store; roster_store=$((roster_store + calls)) ;;
    esac
    body="$dir/$name.mdk"
    extract_source_decl "$name" "$file" "$body" || return 1
    [ "$(count_word ctEq "$body")" -eq "$calls" ] || return 1
    if grep -E -q '==|/=|compare|bitXor|[A-Za-z0-9_)]\[' "$body"; then return 1; fi
  done
  [ "$(count_word ctEq "$credential")" -eq $((roster_credential + 1)) ] || return 1
  [ "$(count_word ctEq "$jwt")" -eq $((roster_jwt + 1)) ] || return 1
  [ "$(count_word ctEq "$store")" -eq $((roster_store + 1)) ] || return 1
  return 0
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
  let () = setInPlace 9 (U64.shiftLeft 1 43 - 1) raw
  let () = reduceCarry raw
  fieldWitnessGo raw 0

fieldWitnessGo : Array U64 -> Int -> Bool
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
  let raw = ([|
    0x9bf7, 0xe237, 0xc25f, 0xf3f7, 0x70cb, 0x0339, 0xc853, 0xd9cc,
    0, 0, 0, 0, 0, 0, 0, 0,
    0x673a, 0x7df0, 0x6c67, 0x354c, 0xb045, 0x6981, 0xc5d3, 0x8422,
    0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff,
  |] : Array U64)
  let () = reduceFixed raw
  scalarHighZero raw 16

scalarHighZero : Array U64 -> Int -> Bool
scalarHighZero raw i =
  if i >= 32 then True
  else if raw[i] /= (0 : U64) then False
  else scalarHighZero raw (i + 1)

-- reduceFixed runs the unchecked carry pass; the checked one is otherwise
-- unreached. On an admitted workspace (limb 31 zero, every other limb
-- carrying) the two must agree limb for limb.
scalarCarryTwinWitness : Bool
scalarCarryTwinWitness =
  let checked = arrayMake 32 (0x1ffff : U64)
  let unchecked = arrayMake 32 (0x1ffff : U64)
  let () = A.setInPlace 31 0 checked
  let () = A.setInPlace 31 0 unchecked
  let () = carryAll checked
  let () = carryAllUnchecked unchecked
  checked == unchecked && checked[31] == (2 : U64)

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

main = if scalarRoundsWitness && scalarCarryTwinWitness && scalarSelectWitness && scalarCtHelpersWitness then println "PASS scalar-rounds" else panic "FAIL scalar-rounds"
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
  /subPCandidate n diff \(i \+ 1\) \(1 - U64\.shiftRight t 26\)/ {
    print "    subPCandidate n diff (i + 1) (if U64.shiftRight t 26 == 0 then 1 else 0)"
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
    print "    let () = A.setInPlace i (w[i] + 0 * U64.truncate secret) w"
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
    print "    let secretIndex = U64.toIntTruncating (U64.bitAnd original 1)"
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
    print "    let secretIndex = U64.toIntTruncating (U64.bitAnd original 1)"
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
    print "    let k = U64.toIntTruncating borrow"
    next
  }
  /A.setInPlace i \(U64\.bitAnd t limbMask\) diff/ {
    print "    let () = A.setInPlace k (U64.bitAnd t limbMask) diff"
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
    print "leakyShift : U64 -> Int -> U64"
    print "leakyShift x amount = if x == 0 then 0 else U64.shiftRight x amount"
    print ""
  }
  /subNCandidate w diff \(i \+ 1\) \(1 - U64\.shiftRight t 16\)/ {
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
    print "    let copied = if value == (0 : U64) then U64.shiftRight value 0 else value"
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
  /scHighBorrow s \(i \+ 1\) \(1 - U64\.shiftRight t 16\)/ {
    print "    scHighBorrow s (i + 1) (if U64.shiftRight t 16 == 0 then 1 else 0)"
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

CREDENTIAL="$ROOT/pds/lib/credential.mdk"
JWT="$ROOT/pds/lib/jwt.mdk"
STORE="$ROOT/pds/lib/store.mdk"
secret_comparisons_ok "$CREDENTIAL" "$JWT" "$STORE" "$WORK/secret-current" || fail 'credential, JWT and session secret comparisons go only through crypto.hmac.ctEq'
pass 'credential, JWT and session secret comparisons go only through crypto.hmac.ctEq'

awk '
  /^  ctEq digest \(pbkdf2HmacSha256 / {
    sub(/ctEq digest \(pbkdf2HmacSha256 /, "digest == (pbkdf2HmacSha256 ")
  }
  { print }
' "$CREDENTIAL" > "$WORK/credential_eq_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_eq_mutant.mdk"; then
  fail 'credential early-exit mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_eq_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-mutant"; then
  fail 'credential early-exit == mutation is rejected by the secret-comparison census'
fi
pass 'credential early-exit == mutation is rejected by the secret-comparison census'

awk '
  /^hasAccess :/ {
    print "sameBytes : Array Int -> Array Int -> Int -> Bool"
    print "sameBytes a b i ="
    print "  if i >= arrayLength a then True"
    print "  else if a[i] /= b[i] then False"
    print "  else sameBytes a b (i + 1)"
    print ""
  }
  /^  now < expires && ctEq wanted access \|\| hasAccess now wanted rest/ {
    print "  now < expires && (arrayLength wanted == arrayLength access && sameBytes wanted access 0) || hasAccess now wanted rest"
    next
  }
  { print }
' "$STORE" > "$WORK/store_loop_mutant.mdk"
if cmp -s "$STORE" "$WORK/store_loop_mutant.mdk"; then
  fail 'session hand-rolled loop mutation was constructed'
fi
if secret_comparisons_ok "$CREDENTIAL" "$JWT" "$WORK/store_loop_mutant.mdk" "$WORK/secret-store-mutant"; then
  fail 'session hand-rolled early-exit loop mutation is rejected by the secret-comparison census'
fi
pass 'session hand-rolled early-exit loop mutation is rejected by the secret-comparison census'

awk '
  /^  ctEq digest \(pbkdf2HmacSha256 \(toUtf8 password\) salt iterations digestBytes\)$/ {
    print "  ctEq digest digest && sameDigest digest (pbkdf2HmacSha256 (toUtf8 password) salt iterations digestBytes)"
    next
  }
  { print }
  END {
    print ""
    print "sameDigest : Array Int -> Array Int -> Bool"
    print "sameDigest a b = arrayToList a == arrayToList b"
  }
' "$CREDENTIAL" > "$WORK/credential_wrapper_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_wrapper_mutant.mdk"; then
  fail 'credential wrapper-indirection mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_wrapper_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-wrapper-mutant"; then
  fail 'credential same-file wrapper-indirection mutation is rejected by the secret-comparison census'
fi
pass 'credential same-file wrapper-indirection mutation is rejected by the secret-comparison census'

awk '
  /^  ctEq digest \(pbkdf2HmacSha256 \(toUtf8 password\) salt iterations digestBytes\)$/ {
    print "  ctEq digest digest && elem digest [pbkdf2HmacSha256 (toUtf8 password) salt iterations digestBytes]"
    next
  }
  { print }
' "$CREDENTIAL" > "$WORK/credential_tautology_elem_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_elem_mutant.mdk"; then
  fail 'credential tautological-ctEq-plus-elem mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_elem_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-elem-mutant"; then
  fail 'credential tautological ctEq beside an elem comparator is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq beside an elem comparator is rejected by the secret-comparison census'

awk '
  /^  ctEq digest \(pbkdf2HmacSha256 \(toUtf8 password\) salt iterations digestBytes\)$/ {
    print "  ctEq digest digest && not (digest < pbkdf2HmacSha256 (toUtf8 password) salt iterations digestBytes)"
    next
  }
  { print }
' "$CREDENTIAL" > "$WORK/credential_tautology_ord_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_ord_mutant.mdk"; then
  fail 'credential tautological-ctEq-plus-Ord mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_ord_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-ord-mutant"; then
  fail 'credential tautological ctEq beside an Ord comparator is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq beside an Ord comparator is rejected by the secret-comparison census'

awk '
  /^  ctEq digest \(pbkdf2HmacSha256 \(toUtf8 password\) salt iterations digestBytes\)$/ {
    print "  ctEq digest digest && sameDigest digest (pbkdf2HmacSha256 (toUtf8 password) salt iterations digestBytes)"
    next
  }
  { print }
  END {
    print ""
    print "sameDigest : Array Int -> Array Int -> Bool"
    print "sameDigest a b = a == b"
  }
' "$CREDENTIAL" > "$WORK/credential_tautology_wrapper_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_wrapper_mutant.mdk"; then
  fail 'credential tautological-ctEq-plus-wrapper mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_wrapper_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-wrapper-mutant"; then
  fail 'credential tautological ctEq beside a non-arrayToList wrapper comparator is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq beside a non-arrayToList wrapper comparator is rejected by the secret-comparison census'

awk '
  /^  ctEq digest \(pbkdf2HmacSha256 \(toUtf8 password\) salt iterations digestBytes\)$/ {
    print "  ctEq (digest) ( digest ) && elem digest [pbkdf2HmacSha256 (toUtf8 password) salt iterations digestBytes]"
    next
  }
  { print }
' "$CREDENTIAL" > "$WORK/credential_tautology_paren_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_paren_mutant.mdk"; then
  fail 'credential parenthesized tautological-ctEq mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_paren_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-paren-mutant"; then
  fail 'credential tautological ctEq with reparenthesized arguments is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq with reparenthesized arguments is rejected by the secret-comparison census'

awk '
  /^  ctEq digest \(pbkdf2HmacSha256 \(toUtf8 password\) salt iterations digestBytes\)$/ {
    print "  ctEq digest"
    print "    digest && elem digest [pbkdf2HmacSha256 (toUtf8 password) salt iterations digestBytes]"
    next
  }
  { print }
' "$CREDENTIAL" > "$WORK/credential_tautology_multiline_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_multiline_mutant.mdk"; then
  fail 'credential multi-line tautological-ctEq mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_multiline_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-multiline-mutant"; then
  fail 'credential tautological ctEq split across lines is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq split across lines is rejected by the secret-comparison census'

awk '
  /^  ctEq digest \(pbkdf2HmacSha256 \(toUtf8 password\) salt iterations digestBytes\)$/ {
    print "  (digest |> ctEq digest) && elem digest [pbkdf2HmacSha256 (toUtf8 password) salt iterations digestBytes]"
    next
  }
  { print }
' "$CREDENTIAL" > "$WORK/credential_tautology_pipe_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_pipe_mutant.mdk"; then
  fail 'credential piped tautological-ctEq mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_pipe_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-pipe-mutant"; then
  fail 'credential tautological ctEq fed through |> is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq fed through |> is rejected by the secret-comparison census'

awk '
  /^  ctEq digest \(pbkdf2HmacSha256 \(toUtf8 password\) salt iterations digestBytes\)$/ {
    print "  (ctEq digest) digest && elem digest [pbkdf2HmacSha256 (toUtf8 password) salt iterations digestBytes]"
    next
  }
  { print }
' "$CREDENTIAL" > "$WORK/credential_tautology_section_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_section_mutant.mdk"; then
  fail 'credential partially-applied tautological-ctEq mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_section_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-section-mutant"; then
  fail 'credential tautological ctEq through a partial application is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq through a partial application is rejected by the secret-comparison census'

awk '
  /^import crypto\.hmac\.\{ctEq\}$/ {
    print
    print "import crypto.hmac as H"
    next
  }
  /^      SessionRecord _ refresh expires _ => now < expires && ctEq wanted refresh\)$/ {
    print "      SessionRecord _ refresh expires _ => now < expires && H.ctEq wanted refresh)"
    next
  }
  { print }
' "$STORE" > "$WORK/store_alias_mutant.mdk"
if cmp -s "$STORE" "$WORK/store_alias_mutant.mdk"; then
  fail 'store import-alias mutation was constructed'
fi
if secret_comparisons_ok "$CREDENTIAL" "$JWT" "$WORK/store_alias_mutant.mdk" "$WORK/secret-store-alias-mutant"; then
  fail 'store dot-qualified-alias ctEq mutation is rejected by the secret-comparison census'
fi
pass 'store dot-qualified-alias ctEq mutation is rejected by the secret-comparison census'

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
# Spec: name:branches:comparisons:indices:writes:makes:copies:calls:allocs:
# public-counter-args. The #3427 re-derivation moved only the call and
# allocation columns; the call-column changes are the callee swaps listed at
# ir_call_shape_ok. The Int-trap re-derivation (#3377) moved only the branch
# column, and only in the recursive helpers: each gained one overflow branch
# per `+`/`-` on its limb counter (carryPassGo 1 -> 4 for its three `i + 1`;
# the others 1 -> 2 for one `i + 1`), and ovf_operands_public proves every one
# of them tests only the counter arguments named last. The straight-line
# schedule helpers have no Int arithmetic and stayed at 0.
check_emitted_helpers "$WORK/field_emit.ll" "$WORK/field-ir" \
  carryPass:0:0:0:0:0:0:1:0:- carryPassGo:4:0:3:3:0:0:11:1:1 carryFoldRound:0:0:2:2:0:0:5:4:- \
  reduceCarry:0:0:0:0:0:0:3:0:- subPCandidate:2:0:4:2:0:0:11:10:2 \
  selectPCandidate:2:0:2:1:0:0:4:3:3 subPSelect:0:0:0:0:1:0:3:1:- \
  canonicalize:0:0:0:0:0:1:3:0:- \
  feZeroBit:0:0:0:0:0:0:3:0:- feZeroBorrow:2:0:2:0:0:0:5:8:1 \
  feEqualBit:0:0:0:0:0:0:4:0:- feEqualBorrow:2:0:4:0:0:0:9:8:2 \
  feSelect:0:0:0:0:1:0:5:0:- feSelectGo:2:0:3:1:0:0:5:3:4 \
  feNegateCt:0:0:0:0:1:0:5:0:- feNegateCtGo:2:0:4:2:0:0:10:9:2
extract_function rawFe "$WORK/field_emit.ll" "$WORK/field-ir/rawFe.ll"
raw_accessor_ir_ok "$WORK/field-ir/rawFe.ll" || fail 'field opaque-value accessor has only invariant representation dispatch'
emitted_local_closure_ok "$WORK/field-ir" field_emit || fail 'field emitted local call graph is closed'
pass 'field emitted local call graph is closed, including carryPass'
u64_callees_ok "$WORK/field_emit.ll" "$WORK/field-ir" || fail 'field u64 callees are allowlisted, branch only on a shift amount, and every shift amount is a literal'
pass 'field u64 callees are allowlisted, branch only on a shift amount, and every shift amount is a literal'
extract_function selectPCandidate "$WORK/field_emit.ll" "$WORK/select-current.ll"
current_ir_branches=$(grep -c 'br i1' "$WORK/select-current.ll" || true)
[ "$current_ir_branches" -eq 2 ] || fail "current native IR has its loop branch and one counter overflow branch (got $current_ir_branches)"
extract_function subPCandidate "$WORK/field_emit.ll" "$WORK/borrow-current.ll"
field_borrow_ir_branches=$(grep -c 'br i1' "$WORK/borrow-current.ll" || true)
[ "$field_borrow_ir_branches" -eq 2 ] || fail "current field borrow IR has its loop branch and one counter overflow branch (got $field_borrow_ir_branches)"
if emitted_comparison_present "$WORK/select-current.ll" || emitted_comparison_present "$WORK/borrow-current.ll"; then
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
emitted_comparison_present "$WORK/field-helper-select-mutant.ll" || fail 'field helper conditional-select mutation reaches native IR'
[ "$(grep -c 'br i1' "$WORK/field-helper-select-mutant.ll" || true)" -gt 2 ] || fail 'field helper conditional-select mutation adds secret IR control'
pass 'field helper conditional-select mutation is rejected by native IR control'

cp "$WORK/field_borrow_source_mutant.mdk" "$WORK/field_borrow_branch_mutant.mdk"
append_field_probe "$WORK/field_borrow_branch_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/field_borrow_branch_mutant.mdk" -o "$WORK/field_borrow_branch_mutant" --keep-ir > "$WORK/build-borrow-mutant.log" 2>&1
extract_function subPCandidate "$WORK/field_borrow_branch_mutant.ll" "$WORK/borrow-mutant.ll"
borrow_mutant_ir_branches=$(grep -c 'br i1' "$WORK/borrow-mutant.ll" || true)
[ "$borrow_mutant_ir_branches" -gt "$field_borrow_ir_branches" ] || fail 'field borrow mutation is rejected by native IR control'
emitted_comparison_present "$WORK/borrow-mutant.ll" || fail 'field borrow mutation exposes equality in native IR'
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
# Int-trap re-derivation (#3377), as for the field: takeHigh 1 -> 3 (`i - 16`,
# `i + 1`), foldAccumRow 1 -> 3 (`i + j`, `j + 1`), carryGo 2 -> 3, the other
# recursive helpers 1 -> 2; every added branch is a counter overflow check.
check_emitted_helpers "$WORK/scalar_emit.ll" "$WORK/scalar-ir" \
  carryAll:0:0:0:0:0:0:1:0:- carryGo:3:0:1:1:0:0:6:1:1 carryAllUnchecked:0:0:0:0:0:0:1:0:- carryGoUnchecked:2:0:1:1:0:0:6:1:1 \
  takeHigh:3:0:1:2:0:0:5:0:2 foldAccum:2:0:0:0:0:0:2:0:2 \
  foldAccumRow:3:0:3:1:0:0:5:2:2+3 foldOnce:0:0:0:0:1:0:3:0:- reduceFixed:0:0:0:0:0:0:9:0:- \
  subNCandidate:2:0:2:1:0:0:6:5:2 selectNCandidate:2:0:2:1:0:0:4:3:3 \
  subNSelect:0:0:0:0:1:0:3:1:- reduceWide:0:0:0:0:1:0:4:0:- copyLow:2:0:1:1:0:0:3:0:2 \
  scZeroBit:0:0:0:0:0:0:3:0:- scZeroBorrow:2:0:1:0:0:0:3:4:1 \
  scEqualBit:0:0:0:0:0:0:4:0:- scEqualBorrow:2:0:2:0:0:0:5:4:2 \
  scSelect:0:0:0:0:1:0:5:0:- scSelectGo:2:0:3:1:0:0:5:3:4 \
  scHighBit:0:0:0:0:0:0:3:1:- scHighBorrow:2:0:2:0:0:0:4:5:1 \
  scNegateCt:0:0:0:0:1:0:5:0:- scNegateCtGo:2:0:2:1:0:0:6:5:2
extract_function rawSc "$WORK/scalar_emit.ll" "$WORK/scalar-ir/rawSc.ll"
raw_accessor_ir_ok "$WORK/scalar-ir/rawSc.ll" || fail 'scalar opaque-value accessor has only invariant representation dispatch'
emitted_local_closure_ok "$WORK/scalar-ir" scalar_emit || fail 'scalar emitted local call graph is closed'
pass 'scalar emitted local call graph is closed, including carryAll and copyLow'
u64_callees_ok "$WORK/scalar_emit.ll" "$WORK/scalar-ir" || fail 'scalar u64 callees are allowlisted, branch only on a shift amount, and every shift amount is a literal'
pass 'scalar u64 callees are allowlisted, branch only on a shift amount, and every shift amount is a literal'
extract_function selectNCandidate "$WORK/scalar_emit.ll" "$WORK/scalar-select-current.ll"
extract_function subNCandidate "$WORK/scalar_emit.ll" "$WORK/scalar-borrow-current.ll"
[ "$(grep -c 'br i1' "$WORK/scalar-select-current.ll" || true)" -eq 2 ] || fail 'current scalar select IR has only its loop branch and one counter overflow branch'
[ "$(grep -c 'br i1' "$WORK/scalar-borrow-current.ll" || true)" -eq 2 ] || fail 'current scalar borrow IR has only its loop branch and one counter overflow branch'
if emitted_comparison_present "$WORK/scalar-select-current.ll" || emitted_comparison_present "$WORK/scalar-borrow-current.ll"; then
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
emitted_comparison_present "$WORK/scalar-high-branch-mutant.ll" || fail 'scalar high-bit secret-branch mutation reaches native IR'
[ "$(grep -c 'br i1' "$WORK/scalar-high-branch-mutant.ll" || true)" -gt 2 ] || fail 'scalar high-bit mutation adds secret IR control'
pass 'scalar high-bit secret-branch mutation is rejected by native IR control'

cp "$WORK/scalar_select_source_mutant.mdk" "$WORK/scalar_branch_mutant.mdk"
append_scalar_probe "$WORK/scalar_branch_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_branch_mutant.mdk" -o "$WORK/scalar_branch_mutant" --keep-ir > "$WORK/build-scalar-mutant.log" 2>&1
extract_function selectNCandidate "$WORK/scalar_branch_mutant.ll" "$WORK/scalar-select-mutant.ll"
scalar_mutant_ir_branches=$(grep -c 'br i1' "$WORK/scalar-select-mutant.ll" || true)
[ "$scalar_mutant_ir_branches" -gt 2 ] || fail 'scalar conditional-select mutation is rejected by native IR control'
emitted_comparison_present "$WORK/scalar-select-mutant.ll" || fail 'scalar conditional-select mutation exposes equality in native IR'
pass 'scalar conditional-select mutation is rejected by native IR control'

cp "$WORK/scalar_hash_source_mutant.mdk" "$WORK/scalar_hash_mutant.mdk"
append_scalar_probe "$WORK/scalar_hash_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_hash_mutant.mdk" -o "$WORK/scalar_hash_mutant" --keep-ir > "$WORK/build-scalar-hash-mutant.log" 2>&1
extract_function selectNCandidate "$WORK/scalar_hash_mutant.ll" "$WORK/scalar-hash-mutant.ll"
if helper_ir_ok "$WORK/scalar-hash-mutant.ll" 2 0 2 1 0 0 4 3; then
  fail 'scalar comparison/hashBool mutation is rejected by native IR operation allowlist'
fi
grep -F -q 'mdk_hash_bool' "$WORK/scalar-hash-mutant.ll" || fail 'scalar comparison/hashBool mutation reaches native IR'
pass 'scalar comparison/hashBool mutation is rejected by native IR operation allowlist'

cp "$WORK/scalar_index_source_mutant.mdk" "$WORK/scalar_index_mutant.mdk"
append_scalar_probe "$WORK/scalar_index_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_index_mutant.mdk" -o "$WORK/scalar_index_mutant" --keep-ir > "$WORK/build-scalar-index-mutant.log" 2>&1
extract_function selectNCandidate "$WORK/scalar_index_mutant.ll" "$WORK/scalar-index-mutant.ll"
if helper_ir_ok "$WORK/scalar-index-mutant.ll" 2 0 2 1 0 0 4 3; then
  fail 'scalar secret-index mutation is rejected by native IR call shape'
fi
index_calls=$(grep -F -c 'call i64 @mdk_impl_Array_index(' "$WORK/scalar-index-mutant.ll" || true)
[ "$index_calls" -gt 2 ] || fail 'scalar secret-index mutation reaches native IR'
pass 'scalar secret-index mutation is rejected by native IR call shape'

cp "$WORK/scalar_write_source_mutant.mdk" "$WORK/scalar_write_mutant.mdk"
append_scalar_probe "$WORK/scalar_write_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_write_mutant.mdk" -o "$WORK/scalar_write_mutant" --keep-ir > "$WORK/build-scalar-write-mutant.log" 2>&1
extract_function selectNCandidate "$WORK/scalar_write_mutant.ll" "$WORK/scalar-write-mutant.ll"
if helper_ir_ok "$WORK/scalar-write-mutant.ll" 2 0 2 1 0 0 4 3; then
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
# The borrow (%arg3) is a U64 since #3427, so the mutant narrows it to an index
# first; the write's index operand is that narrowing's result.
rebound_index=$(sed -n 's/^  \(%t[0-9]*\) = call i64 @mdk_u64__toIntTruncating(i64 %arg3)$/\1/p' "$WORK/scalar-rebound-index-mutant.ll")
[ -n "$rebound_index" ] && grep -F -q "call i64 @mdk_array__setInPlace(i64 $rebound_index," "$WORK/scalar-rebound-index-mutant.ll" || fail 'scalar rebound secret-index mutation reaches native IR'
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
if helper_ir_ok "$WORK/scalar-copy-mutant.ll" 2 0 1 1 0 0 3 0 && ir_call_shape_ok copyLow "$WORK/scalar-copy-mutant.ll"; then
  fail 'scalar transitive copy mutation is rejected by emitted helper shape'
fi
emitted_comparison_present "$WORK/scalar-copy-mutant.ll" || fail 'scalar transitive copy branch reaches native IR'
pass 'scalar transitive copy mutation is rejected by emitted helper shape'

# A limb-derived shift amount would reach the u64 shift's amount branches with
# a secret operand. The literal-amount audit must red on it, independently of
# the source checker (#3427).
awk '
  /subNCandidate w diff \(i \+ 1\) \(1 - U64\.shiftRight t 16\)/ {
    print "    subNCandidate w diff (i + 1) (1 - U64.shiftRight t (16 + U64.toIntTruncating borrow))"
    next
  }
  { print }
' "$SCALAR" > "$WORK/scalar_shift_amount_mutant.mdk"
if cmp -s "$SCALAR" "$WORK/scalar_shift_amount_mutant.mdk"; then
  fail 'scalar secret shift-amount mutation was constructed'
fi
if source_helpers_ok "$FIELD" "$WORK/scalar_shift_amount_mutant.mdk" "$WORK/source-scalar-shift-amount-mutant"; then
  fail 'scalar secret shift-amount mutation is rejected by source structure'
fi
append_scalar_probe "$WORK/scalar_shift_amount_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_shift_amount_mutant.mdk" -o "$WORK/scalar_shift_amount_mutant" --keep-ir > "$WORK/build-scalar-shift-amount-mutant.log" 2>&1
mkdir -p "$WORK/scalar-shift-amount-ir"
extract_function subNCandidate "$WORK/scalar_shift_amount_mutant.ll" "$WORK/scalar-shift-amount-ir/subNCandidate.ll"
if u64_callees_ok "$WORK/scalar_shift_amount_mutant.ll" "$WORK/scalar-shift-amount-ir"; then
  fail 'scalar secret shift-amount mutation is rejected by the u64 callee audit'
fi
pass 'scalar secret shift-amount mutation is rejected by source structure and the u64 callee audit'

# Int arithmetic on a limb-derived value puts an overflow branch on a secret
# operand (#3377). The overflow-operand audit must red on it.
awk '
  /subNCandidate w diff \(i \+ 1\) \(1 - U64\.shiftRight t 16\)/ {
    print "    subNCandidate w diff (i + 1) (1 - U64.truncate (U64.toIntTruncating (U64.shiftRight t 16) + i))"
    next
  }
  { print }
' "$SCALAR" > "$WORK/scalar_int_arith_mutant.mdk"
if cmp -s "$SCALAR" "$WORK/scalar_int_arith_mutant.mdk"; then
  fail 'scalar secret Int-arithmetic mutation was constructed'
fi
append_scalar_probe "$WORK/scalar_int_arith_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_int_arith_mutant.mdk" -o "$WORK/scalar_int_arith_mutant" --keep-ir > "$WORK/build-scalar-int-arith-mutant.log" 2>&1
extract_function subNCandidate "$WORK/scalar_int_arith_mutant.ll" "$WORK/scalar-int-arith-mutant.ll"
if ovf_operands_public "$WORK/scalar-int-arith-mutant.ll" 2; then
  fail 'scalar secret Int-arithmetic mutation is rejected by the overflow-operand audit'
fi
pass 'scalar secret Int-arithmetic mutation is rejected by the overflow-operand audit'

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

# The per-helper disassembly assertions that stood here were retired when the
# emitter began lowering a comparison on known-scalar operands to an inline
# icmp. They addressed each audited helper by linked symbol and then grepped its
# body for an @mdk_value_eq call. Measured at that change: no mdk_value_* call is
# emitted in ANY of the twelve helper bodies, clean or mutant, so every one of
# the six mutant greps had become undetectable and every clean-arm grep passed
# only because it could no longer fail. The reducer call-graph assertions below
# them went the same way -- clang -O2 inlines the calls they counted.
#
# Keeping them would have been a false green, which is worse than their absence:
# the six mutations they covered are still caught, at source level and in the
# emitted IR, by the assertions above. What is genuinely lost is the narrow
# claim that a clang -O2 plus linker step has not reintroduced a secret-
# dependent branch into this probe. Restoring that needs an emitter-level way to
# mark a function non-inlinable AND a predicate that survives branchless
# lowering -- clang compiles the scHighBorrow mutant with no extra jump at all,
# so a jump-count pin cannot see it. Tracked in #2838; do not reinstate a
# symbol-addressed check without a predicate that discriminates.

# The runtime bit helpers are C, below every generated Medaka helper, and a
# helper that grew a conditional jump would invalidate the arithmetic proof.
# They are not checked as linked symbols of their own: `medaka build` links the
# runtime into the program's ThinLTO unit (#3374), which inlines them into each
# caller, so no such symbol survives. Instead a straight-line witness over
# exactly the helpers under audit is built, and it is reached only as a function
# value, so its body survives as a linked symbol. A helper that grew a branch
# puts a conditional jump into that body wherever it is inlined. Under the plain
# link (MEDAKA_NO_LTO, or a toolchain without lld) the helpers stay calls, and
# every function the witness calls is disassembled in turn.
witness_disassemble() {
  case $(uname -s) in
    Darwin) otool -tvV "$1" | awk -v label="_$2:" '$0 == label { p=1; next } p && /^_[A-Za-z0-9_.$]+:$/ { exit } p { print }' > "$3" ;;
    *) objdump -d --disassemble="$2" "$1" > "$3" ;;
  esac
  [ -s "$3" ] || fail "native disassembly exists for $2"
}

# One line per control transfer: `target <symbol>` for a direct call or tail
# jump to a named function, `stray <mnemonic>` for anything else (a conditional
# jump, an indirect transfer, a jump within the function). A straight-line
# function has no strays.
witness_transfers() {
  awk '
    match($0, /[[:space:]](j[a-z]+|call[a-z]*|b|bl|br|blr|b\.[a-z]+|cbn?z|tbn?z)[[:space:]]/) {
      op = substr($0, RSTART + 1, RLENGTH - 2)
      rest = substr($0, RSTART + RLENGTH)
      if (op ~ /^(jmp[a-z]*|call[a-z]*|b|bl)$/) {
        if (rest ~ /^[[:space:]]*([0-9a-f]+[[:space:]]+)?<[A-Za-z0-9_.$]+>[[:space:]]*$/) {
          sub(/^[^<]*</, "", rest); sub(/>.*$/, "", rest); print "target " rest; next
        }
        if (rest ~ /^[[:space:]]*_[A-Za-z0-9_.$]+[[:space:]]*$/) {
          gsub(/[[:space:]]/, "", rest); sub(/^_/, "", rest); print "target " rest; next
        }
      }
      print "stray " op
    }' "$1"
}

check_bit_witness() {
  expr=$1
  shift
  helpers=" $* "
  src="$WORK/bit_witness.mdk"
  bin="$WORK/bit_witness"
  printf '%s\n' \
    'ctBitWitness : Int -> Int -> Int' \
    "ctBitWitness a b = $expr" \
    '' \
    'applyWitness : List (Int -> Int -> Int) -> Int -> Int -> Int' \
    'applyWitness [] acc _ = acc' \
    'applyWitness (f :: rest) acc b = applyWitness rest (f acc b) b' \
    '' \
    'main = println (applyWitness [ctBitWitness] 12345 678)' > "$src"
  MEDAKA_STRICT=1 "$MEDAKA" build "$src" -o "$bin" --keep-ir > "$WORK/bit-witness-build.log" 2>&1 || {
    cat "$WORK/bit-witness-build.log" >&2
    fail 'bit-helper witness builds'
  }
  awk '/^define i64 @[A-Za-z0-9_]*__ctBitWitness\(/ { p=1 } p { print } p && /^}/ { exit }' "$bin.ll" > "$WORK/bit-witness.ll"
  [ -s "$WORK/bit-witness.ll" ] || fail 'emitted bit-helper witness exists'
  [ "$(grep -c '^  br ' "$WORK/bit-witness.ll" || true)" -eq 0 ] || fail 'emitted bit-helper witness is straight-line'
  for helper in $helpers; do
    grep -F -q "call i64 @$helper(" "$WORK/bit-witness.ll" || fail "emitted bit-helper witness calls $helper"
  done
  pass "emitted bit-helper witness is straight-line over $*"
  pending=$(nm "$bin" | awk '{ name=$3; sub(/^_/, "", name); if (name ~ /^mdk_eta_.*__ctBitWitness/) print name }')
  [ -n "$pending" ] || fail 'linked bit-helper witness symbol exists'
  pass 'linked bit-helper witness symbol exists'
  visited=' '
  while [ -n "$pending" ]; do
    next_round=
    for symbol in $pending; do
      case $visited in *" $symbol "*) continue ;; esac
      visited="$visited$symbol "
      witness_disassemble "$bin" "$symbol" "$WORK/witness-$symbol.asm"
      witness_transfers "$WORK/witness-$symbol.asm" > "$WORK/witness-$symbol.transfers"
      strays=$(grep -c '^stray ' "$WORK/witness-$symbol.transfers" || true)
      [ "$strays" -eq 0 ] || fail "linked $symbol has no conditional jumps (got $strays: $(grep '^stray ' "$WORK/witness-$symbol.transfers" | tr '\n' ' '))"
      for target in $(sed -n 's/^target //p' "$WORK/witness-$symbol.transfers"); do
        case "$helpers" in *" $target "*) next_round="$next_round $target"; continue ;; esac
        case $target in
          *__ctBitWitness) next_round="$next_round $target" ;;
          *) fail "linked $symbol calls only the witness and its helpers (found $target)" ;;
        esac
      done
    done
    pending=$next_round
  done
  pass "linked bit-helper witness and every helper it still calls have no conditional jumps"
}

# Since #3377 the Int shift helpers branch on the AMOUNT (a negative amount
# panics; 63 or more saturates), never on the shifted value. Every witness
# amount here is a literal or `bitAnd b 7`, which the optimizer proves lies in
# 0..7, so both amount tests fold away and the linked body must still be
# straight-line. A surviving conditional jump would therefore be a branch on
# the value, which is what this witness exists to catch. The limb and ladder
# shift amounts are public (docs/design/ATPROTO-PDS-CONSTANT-TIME.md §5.1).
check_bit_witness 'bitXor (bitAnd a b) (shiftRight a (bitAnd b 7))' \
  mdk_bit_and mdk_bit_xor mdk_shift_right

printf 'receipt: target=%s %s\n' "$(uname -s)" "$(uname -m)"
printf 'receipt: compiler=%s\n' "$(clang --version | sed -n '1p')"
printf 'receipt: medaka=%s\n' "$($MEDAKA --version | sed -n '1p')"

# Was 54. Lowered to 47 when the seven vacuous disassembly assertions above were
# retired; raise it again if that layer is ever restored with a live predicate (#2838).
[ "$checked" -ge 47 ] || fail "anti-rot floor (expected at least 47, got $checked)"
printf 'PASS: constant-time reduction controls — %s assertions\n' "$checked"
