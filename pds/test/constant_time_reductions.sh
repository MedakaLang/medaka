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

# Re-derived when the limb arithmetic moved to U64 expressions over Int
# storage (#3427), callee by callee against the Int-arithmetic pins. The Int
# runtime bit calls (mdk_bit_and, mdk_shift_right) left every limb helper:
# U64 `+ - *`, the bit operations, the conversions and literal shifts are
# inline kernels now, not calls. The lazy-constant forces of the masks and fold
# constants (limbMask, topMask, foldLow, foldHi, r0, r1) left too, since a U64
# constant is static data; the forces of the Int constant arrays (pLimbs,
# nLimbs, cLimbs, nHalfPlusOneLimbs) and of nWide stay. scHighBit gained one
# mdk_bit_xor, for `1 - borrow` on the secret bit. feZeroBit, feEqualBit,
# feSelect, feNegateCt and their scalar twins are main's shapes again.
#
# The field rows were re-derived for the 5x52 layout (N5), whose helpers are
# straight-line and pass limbs between them as raw U64 registers: an audited
# `*__rw` row is the raw worker, which is what every direct call reaches. The
# only callees left are the array reads (mdk_impl_Array_index, at literal
# indices), the rawFe accessor, the raw workers of carryOut, zeroBitOf,
# canonicalizeLimbs and subPSelect, and u64's bitNot worker (allowlisted in
# u64_callees_ok). Every U64 operation is an inline kernel.
#
# The scalar rows were re-derived from scratch when the scalar moved to 8 x 32
# limbs (N5): every scalar helper is straight-line, so its callees are the
# literal-index reads, the rawSc accessor and the next helper down
# (reduce512__rw, subNSelect__rw, zeroLimbsBit, beWord, limbsOfBytes,
# reduce256). No u64 or Int bit helper remains, and the raw workers are the
# audited bodies: a U64 crosses reduce512 and subNSelect as a register.
#
# The scalar byte-codec rows were re-derived 2026-09-27 when the codecs moved
# to `Bytes`. limbsOfBytes reads its 32 bytes through the `Bytes` index
# (mdk_impl_zZbytes_2e_Bytes_index, literal indices) where it read the array
# index; beWord calls u64's fromU8 raw worker four times, a one-instruction
# untag; scToBytes allocates a MutBytes, reads its eight limbs at literal
# indices, hands each to putLimb's raw worker and freezes the result; and
# putLimb__rw stores four `U8.truncateU64` bytes through MutBytes.setInPlace.
# The `Bytes` index and MutBytes.setInPlace branch on the value's constructor
# tag and on the public index, never on a byte.
ir_call_shape_ok() {
  name=$1
  body=$2
  case "$name" in
    canonicalize) expected='2171586591 143' ;;
    canonicalizeLimbs__rw) expected='2669741125 31' ;;
    subPSelect__rw) expected='4294967295 0' ;;
    carryOut__rw) expected='3139796342 20' ;;
    zeroBitOf__rw) expected='4294967295 0' ;;
    feMul) expected='2590972494 1133' ;;
    feAdd) expected='126786081 292' ;;
    feZeroBit) expected='1094079579 157' ;;
    feEqualBit) expected='3883835114 284' ;;
    feSelect) expected='1870735877 254' ;;
    feNegateCt) expected='1094079579 157' ;;
    subNSelect__rw) expected='4294967295 0' ;;
    reduce512__rw) expected='2556093749 32' ;;
    reduce256) expected='445156908 200' ;;
    scMul) expected='3667540929 413' ;;
    scAdd) expected='953517700 414' ;;
    scNegateCt) expected='79357219 223' ;;
    scSelect) expected='3812397284 382' ;;
    scZeroBit) expected='2129541438 53' ;;
    zeroLimbsBit) expected='1446924398 168' ;;
    scEqualBit) expected='3812397284 382' ;;
    scHighBit) expected='3010223839 191' ;;
    secretBelowNBit) expected='1446924398 168' ;;
    secretNonzeroBit) expected='2074939242 42' ;;
    limbsOfBytes) expected='2436343677 1216' ;;
    beWord) expected='2463314856 80' ;;
    scFromFixedBytesReduce) expected='3885913975 57' ;;
    scToBytes) expected='449973670 465' ;;
    putLimb__rw) expected='675383234 200' ;;
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

# The limb helpers' arithmetic is U64 expressions (#3427). With a literal
# shift amount, `U64.truncate`, `U64.toIntTruncating`, the bit operations and
# the shifts lower as inline kernels fused with the surrounding U64
# arithmetic: no call into stdlib/u64.mdk and no cell allocation. A shift whose
# amount is not a literal still calls the u64 wrapper, whose `k < 0` refusal
# is a branch on the amount. So in the audited helpers no u64 shift call may
# remain (every shift amount is a literal, never secret-derived:
# docs/design/ATPROTO-PDS-CONSTANT-TIME.md §5.1), and any other u64 callee
# must be one of the straight-line helpers on the allowlist. bitNot is not an
# inline kernel; the field's carryOut reaches its raw worker, bitNot__rw.
u64_callees_ok() {
  ir=$1
  dir=$2
  cat "$dir"/*.ll > "$dir.u64-bodies"
  callees=$(sed -n 's/.*call i64 @\(mdk_u64__[A-Za-z0-9_]*\)(.*/\1/p' "$dir.u64-bodies" | sort -u)
  for callee in $callees; do
    case $callee in
      mdk_u64__bitAnd|mdk_u64__bitXor|mdk_u64__truncate|mdk_u64__toIntTruncating|mdk_u64__bitNot__rw|mdk_u64__fromU8__rw) ;;
      *) return 1 ;;
    esac
    awk -v s="$callee" '$0 ~ ("^define i64 @" s "\\(") { p = 1 } p { print } p && /^}/ { exit }' "$ir" > "$dir.u64-callee.ll"
    [ -s "$dir.u64-callee.ll" ] || return 1
    [ "$(grep -c 'br i1' "$dir.u64-callee.ll" || true)" -eq 0 ] || return 1
  done
  [ "$(grep -c 'call i64 @mdk_u64__shift' "$dir.u64-bodies" || true)" -eq 0 ]
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
# `icmp eq` is the discriminator for the inline form. None of the pinned
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
# The index, write and make columns count a `Bytes` read, a MutBytes write
# and a MutBytes allocation alongside the array ones (2026-09-27, the scalar
# byte codecs' move to `Bytes`), so a byte codec's reads and writes stay
# visible to the same columns.
#
# The optional ninth count is the helper's U64 cell allocations
# (`call ptr @mdk_alloc_atomic`, which the `call i64` total does not count).
# The limbs are stored as Int and each U64 expression boxes nothing, so every
# audited helper pins 0 (#3427); a U64 value bound, passed or stored would
# reappear here as a nonzero count.
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
  indices=$(grep -E -c 'call i64 @mdk_impl_(Array|zZbytes_2e_Bytes)_index\(' "$body" || true)
  sets=$(grep -E -c 'call i64 @mdk_(array|mut_bytes)__setInPlace\(' "$body" || true)
  makes=$(grep -E -c 'call i64 @mdk_(array_make|mut_bytes__make)\(' "$body" || true)
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

# An index is a decimal literal or a public counter. The straight-line field
# helpers read their five limbs at the literals 0 through 4. An array
# literal's `[|` and `|]` are not an index; they are rewritten to parentheses
# first, so an index written inside a literal is still checked.
source_indices_ok() {
  body=$1
  awk '
    {
      line=$0
      gsub(/\[\|/, "(", line)
      gsub(/\|\]/, ")", line)
      while (match(line, /\[[^]]+\]/)) {
        idx=substr(line, RSTART + 1, RLENGTH - 2)
        if (idx !~ /^[0-9]+$/ && idx != "i" &&
            idx != "i + 1" && idx != "j" && idx != "k") exit 1
        line=substr(line, RSTART + RLENGTH)
      }
    }
  ' "$body"
}

# A `MutBytes` write (`MB.setInPlace`) counts as a write too, since the
# scalar's byte codec stores through one; its offset must be `off` or
# `off + k` for a literal k, the public offset putLimb is handed.
source_writes_allocations_ok() {
  body=$1
  awk '
    /(^|[[:space:]])((A|MB)\.)?set(InPlace)?[[:space:]]/ &&
      $0 !~ /((A|MB)\.)?set(InPlace)? (0|1|9|i|j|k|off|\(i \+ 1\)|\(i - 16\)|\(off \+ [0-9]+\)) / { exit 1 }
    /arrayMake[[:space:]]/ && $0 !~ /arrayMake (10|16|32) / { exit 1 }
    /MB\.make[[:space:]]/ && $0 !~ /MB\.make 32$/ { exit 1 }
  ' "$body"
}

source_write_shape_ok() {
  name=$1
  body=$2
  writes=$(grep -E -c '(^|[[:space:]])((A|MB)\.)?set(InPlace)?[[:space:]]' "$body" || true)
  case "$name" in
    putLimb) [ "$writes" -eq 4 ] ;;
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

# Re-derived for the same move (#3427). Each changed body differs from main's
# only in computing its limb arithmetic as `U64.toIntTruncating (...)` over
# `U64.truncate`d operands, with a result bound to an Int name before it is
# written, and in `bitXor b 1` for `1 - b` on a secret bit; the
# if/comparison/index/write shape checked below is unchanged for every helper.
# The field rows were re-derived for the 5x52 layout (N5): every field helper
# is new text, straight-line, with no `if`, no comparison, no write and only
# literal indices, which source_helpers_ok checks independently of these pins.
#
# The scalar rows were re-derived from scratch for the 8 x 32 straight-line
# rewrite (N5); each body is pinned as written in pds/lib/scalar.mdk.
#
# Re-derived 2026-09-27 when the scalar byte codecs moved to `Bytes`. The
# limb arithmetic rows are unchanged. limbsOfBytes reads its 32 bytes from a
# `Bytes` at literal indices and beWord widens each `U8` through
# `U64.fromU8`; scToBytes writes its eight limbs through putLimb, a new row,
# which stores four bytes into a `MutBytes` at the public offsets `off` to
# `off + 3`, each byte one `U8.truncateU64` of a literal shift. None of the
# four has an `if`, a comparison or a secret index. scFromFixedBytesReduce's
# body is unchanged; its row moved only because the declaration after it is
# no longer exported.
source_shape_ok() {
  name=$1
  body=$2
  case "$name" in
    canonicalize) expected='3175715183 171' ;;
    canonicalizeLimbs) expected='2456079620 387' ;;
    subPSelect) expected='4052022846 818' ;;
    carryOut) expected='3472123999 119' ;;
    zeroBitOf) expected='1783648097 51' ;;
    feMul) expected='464760015 4759' ;;
    feAdd) expected='771474353 296' ;;
    feZeroBit) expected='861368068 268' ;;
    feEqualBit) expected='1097771623 502' ;;
    feSelect) expected='1373112231 598' ;;
    feNegateCt) expected='3252286959 905' ;;
    rawFe) expected='714619739 33' ;;
    subNSelect) expected='1008917868 1501' ;;
    reduce512) expected='2026303603 7726' ;;
    reduce256) expected='592393441 227' ;;
    scMul) expected='3844309907 7177' ;;
    scAdd) expected='4144040684 897' ;;
    scNegateCt) expected='1322429172 1043' ;;
    scSelect) expected='1875695246 898' ;;
    scZeroBit) expected='285386042 45' ;;
    zeroLimbsBit) expected='4021963566 375' ;;
    scEqualBit) expected='1072094706 739' ;;
    scHighBit) expected='2440456507 821' ;;
    secretBelowNBit) expected='1418687575 841' ;;
    secretNonzeroBit) expected='3876579769 56' ;;
    limbsOfBytes) expected='3299239598 326' ;;
    beWord) expected='2695358797 232' ;;
    scFromFixedBytesReduce) expected='3215920253 57' ;;
    scToBytes) expected='1990994587 445' ;;
    putLimb) expected='3620649717 304' ;;
    rawSc) expected='3051169895 33' ;;
    *) return 1 ;;
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
    "canonicalizeLimbs:$field:0" \
    "subPSelect:$field:0" \
    "canonicalize:$field:0" \
    "carryOut:$field:0" \
    "zeroBitOf:$field:0" \
    "feZeroBit:$field:0" \
    "feEqualBit:$field:0" \
    "feSelect:$field:0" \
    "feNegateCt:$field:0" \
    "feAdd:$field:0" \
    "feMul:$field:0" \
    "rawFe:$field:0" \
    "subNSelect:$scalar:0" \
    "reduce512:$scalar:0" \
    "reduce256:$scalar:0" \
    "scMul:$scalar:0" \
    "scAdd:$scalar:0" \
    "scNegateCt:$scalar:0" \
    "scSelect:$scalar:0" \
    "scZeroBit:$scalar:0" \
    "zeroLimbsBit:$scalar:0" \
    "scEqualBit:$scalar:0" \
    "scHighBit:$scalar:0" \
    "secretBelowNBit:$scalar:0" \
    "secretNonzeroBit:$scalar:0" \
    "limbsOfBytes:$scalar:0" \
    "beWord:$scalar:0" \
    "scFromFixedBytesReduce:$scalar:0" \
    "scToBytes:$scalar:0" \
    "putLimb:$scalar:0" \
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
    [ "$comparisons" -eq "$expected_comparisons" ] || return 1
    if grep -F -q 'hashBool' "$body"; then return 1; fi
    source_indices_ok "$body" || return 1
    source_writes_allocations_ok "$body" || return 1
    source_write_shape_ok "$name" "$body" || return 1
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
# through `arrayLength` or `B.length`, whose value is public (`B.length` since
# 2026-09-27: the credential digest and the session secret are `Bytes` now,
# and their length checks are the same public comparison). Per comparing
# function: its stated number of ctEq calls and no other comparison, XOR
# accumulation or indexing beside them. The per-function roster is complete: each file's
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
        gsub(/(arrayLength|B\.length) [A-Za-z0-9_\047]+/, "", line)
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

-- The conservative-bound witness: limbs 0..3 at 2^53 - 1 and limb 4 at
-- 2^49 - 1, the top of canonicalizeLimbs' admitted precondition. Its value
-- mod p is 0x100000000000010000000000001000000000000100002000007a1.
-- Without the fold/carry round the subtract-and-select reads limbs at or
-- above 2^52 and returns a different value.
fieldRoundsWitness : Bool
fieldRoundsWitness =
  let raw = [|
    0x1fffffffffffff, 0x1fffffffffffff, 0x1fffffffffffff, 0x1fffffffffffff,
    0x1ffffffffffff,
  |]
  let expected = B.fromU8Array [|
    0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0,
    0, 0, 1, 0, 0, 0, 0, 0, 0, 0x10, 0, 2, 0, 0, 7, 0xa1,
  |]
  feToBytes (canonicalize raw) == expected

-- A real producer that needs the round: (p - 1) + (p - 1) = p - 2, whose
-- limb sums 1..3 are 2^53 - 2.
fieldProducerWitness : Bool
fieldProducerWitness =
  let scratch = MB.make 32
  let () = MB.fill 0xff scratch
  let () = MB.setInPlace 27 0xfe scratch
  let () = MB.setInPlace 30 0xfc scratch
  let () = MB.setInPlace 31 0x2e scratch
  let pm1 = MB.freeze scratch
  let () = MB.setInPlace 31 0x2d scratch
  let pm2 = MB.freeze scratch
  let a = feFromBytesReduce pm1
  let two = feAdd feOne feOne
  feToBytes (feAdd a a) == pm2 && feEqual (feMul two two) (feAdd two two)

fieldSelectWitness : Bool
fieldSelectWitness =
  let canonical = canonicalize [|1, 0, 0, 0, 0|]
  B.length (feToBytes canonical) == 32

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

main = if fieldRoundsWitness && fieldProducerWitness && fieldSelectWitness && fieldCtHelpersWitness then println "PASS field-rounds" else panic "FAIL field-rounds"
EOF
}

# The probe's limb workspaces are Array Int written through `A.setInPlace`,
# and scalar.mdk itself no longer imports `array` since its byte codecs moved
# to `Bytes` (2026-09-27), so the import is added beside the module's own.
append_scalar_probe() {
  file=$1
  awk '{ print } $0 == "import u64 as U64" { print "import array as A" }' "$file" > "$file.imports"
  mv "$file.imports" "$file"
  cat >> "$file" <<'EOF'

-- Committed reduce512 workspaces, sixteen 32-bit limbs, least-significant
-- first (docs/design/ATPROTO-PDS-CONSTANT-TIME.md §4). The first three were
-- built by taking a preimage through folds 1 and 2 of a chosen fold-2 result,
-- with the smallest high parts, so each lies below n^2 as a product does.

-- Fold 2 leaves p8 = 2: without fold 3 the value is at least 2^257.
witnessP8Two : Array Int
witnessP8Two = [|
  0xe602b8f9, 0xda53ebcc, 0x8d362507, 0xa6718256, 0xffffffff, 0xffffffff,
  0xffffffff, 0xffffffff, 0x911972c7, 0x1fa37a70, 0xb6e7d742, 0x3b37ceab,
  0x8d592675, 0x90b6e3cd, 0xd50ad6e2, 0x9e87383e,
|]

-- Fold 3 carries out of the eighth limb: the selection needs the carry.
witnessCarry : Array Int
witnessCarry = [|
  0x03caefd1, 0xe65c296d, 0x89fcb43b, 0xcca4ba03, 0xfffffffe, 0xffffffff,
  0xffffffff, 0xffffffff, 0xe35f4ccf, 0xaa296c95, 0xfcaec738, 0x71c3e5be,
  0x8d592674, 0x90b6e3cd, 0xd50ad6e2, 0x9e87383e,
|]

-- Fold 3 leaves a value in [n, 2^256) and no carry: the subtraction is needed.
witnessSubtract : Array Int
witnessSubtract = [|
  0x515d1376, 0x32920880, 0xd77aa334, 0x382914c9, 0xffffffff, 0xffffffff,
  0xffffffff, 0xffffffff, 0x35a526d6, 0x34af5ebb, 0x4275b72f, 0xa84ffcd2,
  0x8d592673, 0x90b6e3cd, 0xd50ad6e2, 0x9e87383e,
|]

-- (n - 1)^2, the largest product: fold 1 fills its top limb, and fold 3
-- leaves n + 1.
witnessSquare : Array Int
witnessSquare = [|
  0x97a19000, 0xc99a9387, 0x5f34583c, 0xb965b9db, 0x5bcd07c7, 0xe697f5e4,
  0x81c69bc5, 0x9d671cd5, 0xa06c8281, 0x7fa4bd19, 0x5e914077, 0x755db9cd,
  0xfffffffd, 0xffffffff, 0xffffffff, 0xffffffff,
|]

-- n, the group order (SEC 2 v2 §2.4.1), least-significant 32-bit limb first.
probeN : Array Int
probeN = [|
  0xd0364141, 0xbfd25e8c, 0xaf48a03b, 0xbaaedce6, 0xfffffffe, 0xffffffff,
  0xffffffff, 0xffffffff,
|]

-- w mod n one bit at a time, most-significant first: double, add the bit, and
-- subtract n when the result is at least n. Plain Int code over 32-bit limbs
-- that shares nothing with the module's arithmetic, so it grades reduce512 and
-- subNSelect by a separate path.
probeModN : Array Int -> Sc
probeModN w =
  let acc = probeModGo w (32 * arrayLength w - 1) (arrayMake 9 0)
  Sc (arrayMakeWith 8 (i => acc[i]))

probeModGo : Array Int -> Int -> Array Int -> Array Int
probeModGo w k acc =
  if k < 0 then acc
  else
    let bit = bitAnd (shiftRight w[shiftRight k 5] (bitAnd k 31)) 1
    let d = arrayMake 9 0
    let () = probeDouble acc d 0 bit
    let () = if d[8] /= 0 || probeGeN d 7 then probeSubN d 0 0 else ()
    probeModGo w (k - 1) d

probeDouble : Array Int -> Array Int -> Int -> Int -> Unit
probeDouble acc d i carry =
  if i >= 8 then A.setInPlace 8 carry d
  else
    let v = 2 * acc[i] + carry
    let () = A.setInPlace i (bitAnd v 0xffffffff) d
    probeDouble acc d (i + 1) (shiftRight v 32)

probeGeN : Array Int -> Int -> Bool
probeGeN d i =
  if i < 0 then True
  else if d[i] /= probeN[i] then d[i] > probeN[i]
  else probeGeN d (i - 1)

probeSubN : Array Int -> Int -> Int -> Unit
probeSubN d i borrow =
  if i >= 8 then A.setInPlace 8 0 d
  else
    let v = d[i] - probeN[i] - borrow
    if v < 0 then
      let () = A.setInPlace i (v + 0x100000000) d
      probeSubN d (i + 1) 1
    else
      let () = A.setInPlace i v d
      probeSubN d (i + 1) 0

reduceWorkspace : Array Int -> Sc
reduceWorkspace w =
  reduce512 (U64.truncate w[0]) (U64.truncate w[1]) (U64.truncate w[2]) (U64.truncate w[3])
    (U64.truncate w[4]) (U64.truncate w[5]) (U64.truncate w[6]) (U64.truncate w[7])
    (U64.truncate w[8]) (U64.truncate w[9]) (U64.truncate w[10]) (U64.truncate w[11])
    (U64.truncate w[12]) (U64.truncate w[13]) (U64.truncate w[14]) (U64.truncate w[15])

workspaceOk : Array Int -> Bool
workspaceOk w = scEqual (reduceWorkspace w) (probeModN w)

-- Each named check that fails prints its name, so a mutation control can
-- require the witness it targets to be the one that fails.
report : List (String, Bool) -> <IO> Bool
report checks = match checks
  [] => True
  (name, ok) :: rest =>
    let () = if ok then () else println "FAIL \{name}"
    let others = report rest
    ok && others

scalarRoundsWitness : Unit -> <IO> Bool
scalarRoundsWitness () =
  let minusOne = scNegateCt scOne
  report [
    ("workspace p8=2", workspaceOk witnessP8Two),
    ("workspace carry", workspaceOk witnessCarry),
    ("workspace subtract", workspaceOk witnessSubtract),
    ("workspace square", workspaceOk witnessSquare),
    ("workspace max", workspaceOk (arrayMake 16 0xffffffff)),
    ("product square", scEqual (scMul minusOne minusOne) scOne),
  ]

-- The byte path: 2^256 - 1 is in [n, 2^256), n - 1 is the largest canonical
-- value, and both reach reduce256 and the secret-ingress bits.
scalarBytesWitness : Unit -> <IO> Bool
scalarBytesWitness () =
  let allOnes = B.fromU8Array (arrayMake 32 255)
  let minusOne = scNegateCt scOne
  let (onesBit, onesSc) = scSecretCandidate allOnes
  let (topBit, topSc) = scSecretCandidate (scToBytes minusOne)
  report [
    (
      "bytes all-ones",
      scEqual (scFromFixedBytesReduce allOnes) (probeModN (arrayMake 8 0xffffffff)),
    ),
    ("bytes secret all-ones", scEqual onesSc (scFromFixedBytesReduce allOnes) && onesBit == 0),
    ("bytes secret n-1", topBit == 1 && scEqual topSc minusOne),
    ("bytes n-1", scEqual (scFromFixedBytesReduce (scToBytes minusOne)) minusOne),
  ]

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

main =
  let rounds = scalarRoundsWitness ()
  let bytes = scalarBytesWitness ()
  if rounds && bytes && scalarCtHelpersWitness then println "PASS scalar-rounds" else panic "FAIL scalar-rounds"
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

# A mutant probe must fail. When $3 is given, the probe must also report that
# named check as failing, so the red is attributed to the witness the mutation
# targets rather than to any check at all.
run_probe_red() {
  file=$1
  label=$2
  expected_failure=${3:-}
  out="$WORK/probe-red.out"
  if MEDAKA_STRICT=1 "$MEDAKA" run "$file" > "$out" 2>&1; then
    cat "$out" >&2
    fail "$label"
  fi
  if [ -n "$expected_failure" ] && ! grep -F -x -q "$expected_failure" "$out"; then
    cat "$out" >&2
    fail "$label (expected the probe to report: $expected_failure)"
  fi
  pass "$label"
}

# The scalar schedule (docs/design/ATPROTO-PDS-CONSTANT-TIME.md §4 and §5):
# reduce512 is three folds with 13, 9 and 8 output limbs, fold 3 takes fold 2's
# whole top column as its high part, and the result goes to subNSelect with
# fold 3's carry; subNSelect subtracts n from all eight limbs with a fixed
# borrow chain and blends every limb by `carry OR no borrow`.
scalar_schedule_ok() {
  file=$1
  dir=$2
  mkdir -p "$dir"
  extract_source_function reduce512 "$file" "$dir/reduce512.mdk" || return 1
  extract_source_function subNSelect "$file" "$dir/subNSelect.mdk" || return 1
  r="$dir/reduce512.mdk"
  s="$dir/subNSelect.mdk"
  [ "$(grep -E -c '^  let m[0-9]+ = ' "$r" || true)" -eq 13 ] || return 1
  [ "$(grep -E -c '^  let p[0-9]+ = ' "$r" || true)" -eq 9 ] || return 1
  [ "$(grep -E -c '^  let r[0-9]+ = ' "$r" || true)" -eq 8 ] || return 1
  [ "$(grep -F -x -c '  let p8 = kb7 + m12' "$r" || true)" -eq 1 ] || return 1
  [ "$(grep -F -x -c '  subNSelect r0 r1 r2 r3 r4 r5 r6 r7 kd7' "$r" || true)" -eq 1 ] || return 1
  [ "$(grep -F -x -c '  let keep = U64.bitOr carry (1 - b7)' "$s" || true)" -eq 1 ] || return 1
  i=0
  while [ "$i" -le 7 ]; do
    [ "$(grep -F -x -c "  let b$i = 1 - U64.shiftRight t$i 32" "$s" || true)" -eq 1 ] || return 1
    [ "$(grep -F -x -c "  let o$i = U64.toIntTruncating (r$i + keep * (d$i - r$i))" "$s" || true)" -eq 1 ] || return 1
    i=$((i + 1))
  done
}

# Every array read in the audited scalar helpers is at a literal index: the
# helpers are straight-line, so an index operand that is a register is an
# index computed from something, and here that something can only be a limb.
scalar_indices_literal() {
  ! grep -h -E 'call i64 @mdk_impl_(Array|zZbytes_2e_Bytes)_index\(' "$@" |
    grep -v -E -q 'call i64 @mdk_impl_(Array|zZbytes_2e_Bytes)_index\(i64 %[A-Za-z0-9_.]+, i64 -?[0-9]+\)'
}

# Source anti-rot: exact schedules and no retired conditional path from the
# reduction entry points. Counts are deliberately file-wide because these
# helper calls are unique to their schedules.
require_line_count 1 '  let x = U64.shiftRight t4 48' "$FIELD" 'field schedule has exactly one fold'
require_line_count 1 '  let u4 = U64.bitAnd t4 mask48 + U64.shiftRight u3 52' "$FIELD" 'field round carries into limb 4 once'
require_line_count 1 '  subPSelect' "$FIELD" 'field round hands its limbs to the subtract-and-select once'
scalar_schedule_ok "$SCALAR" "$WORK/schedule-current" || fail 'scalar schedule is exactly three folds and the carry-aware subtract-and-select'
pass 'scalar schedule is exactly three folds and the carry-aware subtract-and-select'
require_count 0 'subPInPlace' "$FIELD" 'field retired branchy subtraction is absent'
require_count 0 'gtePLimbs' "$FIELD" 'field retired early-exit comparison is absent'
require_count 0 'subNInPlace' "$SCALAR" 'scalar retired branchy subtraction is absent'
require_count 5 ' + keep * (d' "$FIELD" 'field arithmetic select is present on all five limbs'
source_helpers_ok "$FIELD" "$SCALAR" "$WORK/source-current" || fail 'dedicated reduction helpers contain only public-counter source branches'
pass 'dedicated reduction helpers contain only public-counter source branches'

# Replace the one line exactly equal to $3 inside top-level declaration $2 of
# $1 with $4 (`\n` separates lines), writing $5. Fails when the line is not
# found in that declaration, so a mutation can never silently be a copy. The
# limb helpers' recursive calls span several lines, and the same continuation
# line can recur in a sibling helper, hence the declaration scope.
mutate_line() {
  awk -v name="$2" -v old="$3" -v new="$4" '
    $0 ~ ("^" name " ") { inside = 1 }
    inside && /^[^ ]/ && $0 !~ ("^" name " ") { inside = 0 }
    inside && $0 == old && !done {
      n = split(new, parts, "\n")
      for (k = 1; k <= n; k++) print parts[k]
      done = 1
      next
    }
    { print }
    END { exit !done }
  ' "$1" > "$5"
}

# The source checker must reject secret control in either the borrow chain or
# either modulus' blend, not merely protect the current arithmetic spelling.
mutate_line "$FIELD" subPSelect \
  '  let s1 = n1 + mask52 + 1 - mask52 - (1 - U64.shiftRight s0 52)' \
  '  let s1 = n1 + mask52 + 1 - mask52 - (if U64.shiftRight s0 52 == 0 then 1 else 0)' \
  "$WORK/field_borrow_source_mutant.mdk" || fail 'field borrow secret-branch mutation was constructed'
if source_helpers_ok "$WORK/field_borrow_source_mutant.mdk" "$SCALAR" "$WORK/source-field-mutant"; then
  fail 'field borrow secret-branch mutation is rejected by source structure'
fi
pass 'field borrow secret-branch mutation is rejected by source structure'

mutate_line "$SCALAR" subNSelect \
  '  let o0 = U64.toIntTruncating (r0 + keep * (d0 - r0))' \
  '  let o0 = if keep == 1 then U64.toIntTruncating d0 else U64.toIntTruncating r0' \
  "$WORK/scalar_select_source_mutant.mdk" || fail 'scalar select secret-branch mutation was constructed'
if source_helpers_ok "$FIELD" "$WORK/scalar_select_source_mutant.mdk" "$WORK/source-scalar-mutant"; then
  fail 'scalar select secret-branch mutation is rejected by source structure'
fi
pass 'scalar select secret-branch mutation is rejected by source structure'

mutate_line "$SCALAR" subNSelect \
  '  let o0 = U64.toIntTruncating (r0 + keep * (d0 - r0))' \
  '  let secret = hashBool (r0 < d0)\n  let o0 = U64.toIntTruncating (r0 + keep * (d0 - r0) + 0 * U64.truncate secret)' \
  "$WORK/scalar_hash_source_mutant.mdk" || fail 'scalar comparison/hashBool mutation was constructed'
if source_helpers_ok "$FIELD" "$WORK/scalar_hash_source_mutant.mdk" "$WORK/source-scalar-hash-mutant"; then
  fail 'scalar comparison/hashBool mutation is rejected by source structure'
fi
pass 'scalar comparison/hashBool mutation is rejected by source structure'

mutate_line "$SCALAR" scSelect \
  '  let x0 = U64.truncate x[0]' \
  '  let secretIndex = bitAnd bit 1\n  let x0 = U64.truncate x[secretIndex]' \
  "$WORK/scalar_index_source_mutant.mdk" || fail 'scalar secret-index mutation was constructed'
if source_helpers_ok "$FIELD" "$WORK/scalar_index_source_mutant.mdk" "$WORK/source-scalar-index-mutant"; then
  fail 'scalar secret-index mutation is rejected by source structure'
fi
pass 'scalar secret-index mutation is rejected by source structure'

mutate_line "$SCALAR" scSelect \
  '  let x0 = U64.truncate x[0]' \
  '  let scratch = arrayMake 2 0\n  let () = A.setInPlace (bitAnd bit 1) 0 scratch\n  let x0 = U64.truncate x[0]' \
  "$WORK/scalar_write_source_mutant.mdk" || fail 'scalar secret-write mutation was constructed'
if source_helpers_ok "$FIELD" "$WORK/scalar_write_source_mutant.mdk" "$WORK/source-scalar-write-mutant"; then
  fail 'scalar secret-write mutation is rejected by source structure'
fi
pass 'scalar secret-write mutation is rejected by source structure'

# `k` is on the index allowlist (the field's loops use it), so this mutant is
# rejected at source only by the exact body pin; the emitted literal-index
# check below rejects it independently.
mutate_line "$SCALAR" scSelect \
  '  let x0 = U64.truncate x[0]' \
  '  let k = bitAnd bit 1\n  let x0 = U64.truncate x[k]' \
  "$WORK/scalar_rebound_index_source_mutant.mdk" || fail 'scalar rebound secret-index mutation was constructed'
if source_helpers_ok "$FIELD" "$WORK/scalar_rebound_index_source_mutant.mdk" "$WORK/source-scalar-rebound-index-mutant"; then
  fail 'scalar rebound secret-index mutation is rejected by source structure'
fi
pass 'scalar rebound secret-index mutation is rejected by source structure'

mutate_line "$SCALAR" subNSelect \
  '  let b0 = 1 - U64.shiftRight t0 32' \
  '  let b0 = 1 - U64.truncate (leakyShift (U64.toIntTruncating t0) 32)' \
  "$WORK/scalar_wrapper_body.mdk" || fail 'scalar leaky-wrapper mutation was constructed'
awk '
  /^subNSelect :/ {
    print "leakyShift : Int -> Int -> Int"
    print "leakyShift x amount = if x == 0 then 0 else shiftRight x amount"
    print ""
  }
  { print }
' "$WORK/scalar_wrapper_body.mdk" > "$WORK/scalar_wrapper_source_mutant.mdk"
if source_helpers_ok "$FIELD" "$WORK/scalar_wrapper_source_mutant.mdk" "$WORK/source-scalar-wrapper-mutant"; then
  fail 'scalar leaky-wrapper mutation is rejected by exact source graph'
fi
pass 'scalar leaky-wrapper mutation is rejected by exact source graph'

mutate_line "$SCALAR" reduce256 \
  '    (U64.truncate v[0])' \
  '    (if v[0] == 0 then U64.truncate 0 else U64.truncate v[0])' \
  "$WORK/scalar_copy_source_mutant.mdk" || fail 'scalar transitive reducer mutation was constructed'
if source_helpers_ok "$FIELD" "$WORK/scalar_copy_source_mutant.mdk" "$WORK/source-scalar-copy-mutant"; then
  fail 'scalar transitive reducer mutation is rejected by closed source graph'
fi
pass 'scalar transitive reducer mutation is rejected by closed source graph'

awk '
  /^feZeroBit a =/ {
    print "feZeroBit a = hashBool (feEqual a feZero)"
    skip = 1
    next
  }
  skip && /^  / { next }
  { skip = 0; print }
' "$FIELD" > "$WORK/field_zero_sentinel_mutant.mdk"
if source_helpers_ok "$WORK/field_zero_sentinel_mutant.mdk" "$SCALAR" "$WORK/source-field-zero-mutant"; then
  fail 'field sentinel/Bool zero mutation is rejected by source structure'
fi
pass 'field sentinel/Bool zero mutation is rejected by source structure'

awk '
  /^scHighBit s =/ {
    print "scHighBit s = hashBool (scIsHigh s)"
    skip = 1
    next
  }
  skip && /^[[:space:]]/ { next }
  { skip = 0; print }
' "$SCALAR" > "$WORK/scalar_high_bool_mutant.mdk"
if cmp -s "$SCALAR" "$WORK/scalar_high_bool_mutant.mdk"; then
  fail 'scalar Bool high mutation was constructed'
fi
if source_helpers_ok "$FIELD" "$WORK/scalar_high_bool_mutant.mdk" "$WORK/source-scalar-high-mutant"; then
  fail 'scalar Bool high mutation is rejected by source structure'
fi
pass 'scalar Bool high mutation is rejected by source structure'

mutate_line "$SCALAR" scHighBit \
  '  let b0 = 1 - U64.shiftRight t0 32' \
  '  let b0 = if U64.shiftRight t0 32 == 0 then (1 : U64) else 0' \
  "$WORK/scalar_high_branch_mutant.mdk" || fail 'scalar high-bit secret-branch mutation was constructed'
if source_helpers_ok "$FIELD" "$WORK/scalar_high_branch_mutant.mdk" "$WORK/source-scalar-high-branch-mutant"; then
  fail 'scalar high-bit secret-branch mutation is rejected by source structure'
fi
pass 'scalar high-bit secret-branch mutation is rejected by source structure'

mutate_line "$FIELD" feSelect \
  '  let o0 = U64.toIntTruncating (x0 + s * (U64.truncate y[0] - x0))' \
  '  let o0 = if bit == 1 then y[0] else x[0]' \
  "$WORK/field_helper_select_mutant.mdk" || fail 'field helper conditional-select mutation was constructed'
if source_helpers_ok "$WORK/field_helper_select_mutant.mdk" "$SCALAR" "$WORK/source-field-helper-select-mutant"; then
  fail 'field helper conditional-select mutation is rejected by source structure'
fi
pass 'field helper conditional-select mutation is rejected by source structure'

CREDENTIAL="$ROOT/pds/lib/credential.mdk"
JWT="$ROOT/pds/lib/jwt.mdk"
STORE="$ROOT/pds/lib/store.mdk"
secret_comparisons_ok "$CREDENTIAL" "$JWT" "$STORE" "$WORK/secret-current" || fail 'credential, JWT and session secret comparisons go only through crypto.hmac.ctEq'
pass 'credential, JWT and session secret comparisons go only through crypto.hmac.ctEq'

# The credential mutants below rewrite both comparison sites, credentialVerify's
# and digestIs's, each as a `  ctEq digest derived` body line. Re-pinned
# 2026-09-27: the record's digest and the derived key are `Bytes`, so neither
# argument carries a byte-domain door any more, and the formatter keeps
# digestIs's shorter call on its declaration line. `credential_split.mdk` moves
# that call onto a body line of its own so both sites are rewritten, as they
# were before. Both are needed: credentialVerify's call follows a `let` whose
# last token is a word, which the census's layout-blind tokenizer reads as an
# application, so a partially-applied mutant there is seen only at digestIs.
awk '
  /^digestIs \(CredentialRecord _ _ digest\) derived = ctEq digest derived$/ {
    print "digestIs (CredentialRecord _ _ digest) derived ="
    print "  ctEq digest derived"
    next
  }
  { print }
' "$CREDENTIAL" > "$WORK/credential_split.mdk"
[ "$(grep -c '^  ctEq digest derived$' "$WORK/credential_split.mdk")" -eq 2 ] ||
  fail 'credential mutation base has both comparison sites on body lines'
awk '
  /^  ctEq digest derived$/ {
    sub(/ctEq digest /, "digest == ")
  }
  { print }
' "$WORK/credential_split.mdk" > "$WORK/credential_eq_mutant.mdk"
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
  /^  now < expires$/ {
    print "  now < expires && (arrayLength wanted == arrayLength access && sameBytes wanted access 0) || hasAccess now wanted rest"
    skip = 1
    next
  }
  skip && /^    \|\| hasAccess now wanted rest$/ { skip = 0; next }
  skip { next }
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
  /^  ctEq digest derived$/ {
    print "  ctEq digest digest && sameDigest digest (pbkdf2HmacSha256 (encodeUtf8 password) salt iterations digestBytes)"
    next
  }
  { print }
  END {
    print ""
    print "sameDigest : Array Int -> Array Int -> Bool"
    print "sameDigest a b = arrayToList a == arrayToList b"
  }
' "$WORK/credential_split.mdk" > "$WORK/credential_wrapper_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_wrapper_mutant.mdk"; then
  fail 'credential wrapper-indirection mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_wrapper_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-wrapper-mutant"; then
  fail 'credential same-file wrapper-indirection mutation is rejected by the secret-comparison census'
fi
pass 'credential same-file wrapper-indirection mutation is rejected by the secret-comparison census'

awk '
  /^  ctEq digest derived$/ {
    print "  ctEq digest digest && elem digest [pbkdf2HmacSha256 (encodeUtf8 password) salt iterations digestBytes]"
    next
  }
  { print }
' "$WORK/credential_split.mdk" > "$WORK/credential_tautology_elem_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_elem_mutant.mdk"; then
  fail 'credential tautological-ctEq-plus-elem mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_elem_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-elem-mutant"; then
  fail 'credential tautological ctEq beside an elem comparator is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq beside an elem comparator is rejected by the secret-comparison census'

awk '
  /^  ctEq digest derived$/ {
    print "  ctEq digest digest && not (digest < pbkdf2HmacSha256 (encodeUtf8 password) salt iterations digestBytes)"
    next
  }
  { print }
' "$WORK/credential_split.mdk" > "$WORK/credential_tautology_ord_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_ord_mutant.mdk"; then
  fail 'credential tautological-ctEq-plus-Ord mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_ord_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-ord-mutant"; then
  fail 'credential tautological ctEq beside an Ord comparator is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq beside an Ord comparator is rejected by the secret-comparison census'

awk '
  /^  ctEq digest derived$/ {
    print "  ctEq digest digest && sameDigest digest (pbkdf2HmacSha256 (encodeUtf8 password) salt iterations digestBytes)"
    next
  }
  { print }
  END {
    print ""
    print "sameDigest : Array Int -> Array Int -> Bool"
    print "sameDigest a b = a == b"
  }
' "$WORK/credential_split.mdk" > "$WORK/credential_tautology_wrapper_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_wrapper_mutant.mdk"; then
  fail 'credential tautological-ctEq-plus-wrapper mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_wrapper_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-wrapper-mutant"; then
  fail 'credential tautological ctEq beside a non-arrayToList wrapper comparator is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq beside a non-arrayToList wrapper comparator is rejected by the secret-comparison census'

awk '
  /^  ctEq digest derived$/ {
    print "  ctEq (digest) ( digest ) && elem digest [pbkdf2HmacSha256 (encodeUtf8 password) salt iterations digestBytes]"
    next
  }
  { print }
' "$WORK/credential_split.mdk" > "$WORK/credential_tautology_paren_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_paren_mutant.mdk"; then
  fail 'credential parenthesized tautological-ctEq mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_paren_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-paren-mutant"; then
  fail 'credential tautological ctEq with reparenthesized arguments is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq with reparenthesized arguments is rejected by the secret-comparison census'

awk '
  /^  ctEq digest derived$/ {
    print "  ctEq digest"
    print "    digest && elem digest [pbkdf2HmacSha256 (encodeUtf8 password) salt iterations digestBytes]"
    next
  }
  { print }
' "$WORK/credential_split.mdk" > "$WORK/credential_tautology_multiline_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_multiline_mutant.mdk"; then
  fail 'credential multi-line tautological-ctEq mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_multiline_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-multiline-mutant"; then
  fail 'credential tautological ctEq split across lines is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq split across lines is rejected by the secret-comparison census'

awk '
  /^  ctEq digest derived$/ {
    print "  (digest |> ctEq digest) && elem digest [pbkdf2HmacSha256 (encodeUtf8 password) salt iterations digestBytes]"
    next
  }
  { print }
' "$WORK/credential_split.mdk" > "$WORK/credential_tautology_pipe_mutant.mdk"
if cmp -s "$CREDENTIAL" "$WORK/credential_tautology_pipe_mutant.mdk"; then
  fail 'credential piped tautological-ctEq mutation was constructed'
fi
if secret_comparisons_ok "$WORK/credential_tautology_pipe_mutant.mdk" "$JWT" "$STORE" "$WORK/secret-credential-tautology-pipe-mutant"; then
  fail 'credential tautological ctEq fed through |> is rejected by the secret-comparison census'
fi
pass 'credential tautological ctEq fed through |> is rejected by the secret-comparison census'

awk '
  /^  ctEq digest derived$/ {
    print "  (ctEq digest) digest && elem digest [pbkdf2HmacSha256 (encodeUtf8 password) salt iterations digestBytes]"
    next
  }
  { print }
' "$WORK/credential_split.mdk" > "$WORK/credential_tautology_section_mutant.mdk"
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
  /^          && ctEq$/ && !aliased {
    print "          && H.ctEq"
    aliased = 1
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
run_probe "$WORK/field_probe.mdk" 'PASS field-rounds' 'field one-round witness passes'

# The one fold/carry round removed: canonicalizeLimbs hands its arguments
# straight to the subtract-and-select.
awk '
  /^canonicalizeLimbs t0 t1 t2 t3 t4 =/ {
    print
    print "  subPSelect t0 t1 t2 t3 t4"
    skip = 1
    next
  }
  skip && /^  / { next }
  { skip = 0; print }
' "$FIELD" > "$WORK/field_zero_rounds.mdk"
if cmp -s "$FIELD" "$WORK/field_zero_rounds.mdk"; then
  fail 'field 1-to-0 mutation was constructed'
fi
append_field_probe "$WORK/field_zero_rounds.mdk"
run_probe_red "$WORK/field_zero_rounds.mdk" 'field 1-to-0 mutation is rejected'
# Red for the right reason: the witnesses ran and disagreed, not a build error.
grep -F -q 'FAIL field-rounds' "$WORK/probe-red.out" || fail 'field 1-to-0 mutation fails its value witness'
pass 'field 1-to-0 mutation fails its value witness'

cp "$SCALAR" "$WORK/scalar_probe.mdk"
append_scalar_probe "$WORK/scalar_probe.mdk"
run_probe "$WORK/scalar_probe.mdk" 'PASS scalar-rounds' 'scalar third-fold, carry and subtraction witnesses pass'

# The 3 -> 2 control. Fold 3 with its high part zeroed adds nothing, exactly as
# if it were absent. The schedule check and the p8 = 2 witness must both red.
mutate_line "$SCALAR" reduce512 '  let p8 = kb7 + m12' '  let p8 = (0 : U64)' \
  "$WORK/scalar_two_folds.mdk" || fail 'scalar 3-to-2 mutation was constructed'
if scalar_schedule_ok "$WORK/scalar_two_folds.mdk" "$WORK/schedule-two-folds"; then
  fail 'scalar 3-to-2 mutation is rejected by the schedule check'
fi
append_scalar_probe "$WORK/scalar_two_folds.mdk"
run_probe_red "$WORK/scalar_two_folds.mdk" 'scalar 3-to-2 mutation is rejected by the schedule check and the p8 = 2 witness' 'FAIL workspace p8=2'

# The carry out of fold 3 is part of the selection bit; dropping it must red on
# the witness whose fold 3 carries out, the only one that does.
mutate_line "$SCALAR" subNSelect '  let keep = U64.bitOr carry (1 - b7)' '  let keep = 1 - b7' \
  "$WORK/scalar_no_carry.mdk" || fail 'scalar dropped-carry mutation was constructed'
if scalar_schedule_ok "$WORK/scalar_no_carry.mdk" "$WORK/schedule-no-carry"; then
  fail 'scalar dropped-carry mutation is rejected by the schedule check'
fi
append_scalar_probe "$WORK/scalar_no_carry.mdk"
run_probe_red "$WORK/scalar_no_carry.mdk" 'scalar dropped-carry mutation is rejected by the schedule check and the carry witness' 'FAIL workspace carry'

# Selecting on the carry alone skips the subtraction of n; the witness whose
# three-fold result lies in [n, 2^256) must red.
mutate_line "$SCALAR" subNSelect '  let keep = U64.bitOr carry (1 - b7)' '  let keep = carry' \
  "$WORK/scalar_no_subtract.mdk" || fail 'scalar dropped-subtraction mutation was constructed'
if scalar_schedule_ok "$WORK/scalar_no_subtract.mdk" "$WORK/schedule-no-subtract"; then
  fail 'scalar dropped-subtraction mutation is rejected by the schedule check'
fi
append_scalar_probe "$WORK/scalar_no_subtract.mdk"
run_probe_red "$WORK/scalar_no_subtract.mdk" 'scalar dropped-subtraction mutation is rejected by the schedule check and the subtraction witness' 'FAIL workspace subtract'

# Native emitted-control check. Recursive limb helpers have one public-counter
# branch; straight-line helpers have none. Secret-branch mutations in both
# moduli must add control and red independently of the source checker.
cp "$FIELD" "$WORK/field_emit.mdk"
append_field_probe "$WORK/field_emit.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/field_emit.mdk" -o "$WORK/field_emit" --keep-ir > "$WORK/build.log" 2>&1
# Spec: name:branches:comparisons:indices:writes:makes:copies:calls:allocs:
# public-counter-args. Re-derived for the field's 5x52 layout (N5): every field
# helper is straight-line, so every field row has no branch, no comparison, no
# write, no array_make/array_copy and no Int arithmetic (so no overflow check;
# `-` names no counter argument), and allocates no U64 cell. The raw workers
# (`*__rw`) are audited, since every direct call reaches them; each takes and
# returns its limbs as registers. The index column is the limbs read at
# literal indices: 5 per operand. The result array and the Fe box are
# allocated with mdk_alloc, which none of these columns counts.
check_emitted_helpers "$WORK/field_emit.ll" "$WORK/field-ir" \
  canonicalizeLimbs__rw:0:0:0:0:0:0:1:0:- subPSelect__rw:0:0:0:0:0:0:0:0:- \
  canonicalize:0:0:5:0:0:0:6:0:- \
  carryOut__rw:0:0:0:0:0:0:1:0:- zeroBitOf__rw:0:0:0:0:0:0:0:0:- \
  feZeroBit:0:0:5:0:0:0:7:0:- feEqualBit:0:0:10:0:0:0:13:0:- \
  feSelect:0:0:10:0:0:0:12:0:- feNegateCt:0:0:5:0:0:0:7:0:- \
  feAdd:0:0:10:0:0:0:13:0:- feMul:0:0:10:0:0:0:42:0:-
extract_function rawFe "$WORK/field_emit.ll" "$WORK/field-ir/rawFe.ll"
raw_accessor_ir_ok "$WORK/field-ir/rawFe.ll" || fail 'field opaque-value accessor has only invariant representation dispatch'
emitted_local_closure_ok "$WORK/field-ir" field_emit || fail 'field emitted local call graph is closed'
pass 'field emitted local call graph is closed, including the raw workers'
u64_callees_ok "$WORK/field_emit.ll" "$WORK/field-ir" || fail 'field limb helpers make no u64 shift call and only allowlisted straight-line u64 calls'
pass 'field limb helpers make no u64 shift call and only allowlisted straight-line u64 calls'
extract_function subPSelect__rw "$WORK/field_emit.ll" "$WORK/select-current.ll"
current_ir_branches=$(grep -c 'br i1' "$WORK/select-current.ll" || true)
[ "$current_ir_branches" -eq 0 ] || fail "current field subtract-and-select IR is straight-line (got $current_ir_branches branches)"
field_borrow_ir_branches=$current_ir_branches
extract_function canonicalizeLimbs__rw "$WORK/field_emit.ll" "$WORK/round-current.ll"
[ "$(grep -c 'br i1' "$WORK/round-current.ll" || true)" -eq 0 ] || fail 'current field fold/carry round IR is straight-line'
if emitted_comparison_present "$WORK/select-current.ll" || emitted_comparison_present "$WORK/round-current.ll"; then
  fail 'current field reduction IR contains secret equality control'
fi
pass 'current field reduction IR has no control'
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
extract_function feSelect "$WORK/field_helper_select_emit.ll" "$WORK/field-helper-select-mutant.ll"
emitted_comparison_present "$WORK/field-helper-select-mutant.ll" || fail 'field helper conditional-select mutation reaches native IR'
[ "$(grep -c 'br i1' "$WORK/field-helper-select-mutant.ll" || true)" -gt 0 ] || fail 'field helper conditional-select mutation adds secret IR control'
pass 'field helper conditional-select mutation is rejected by native IR control'

cp "$WORK/field_borrow_source_mutant.mdk" "$WORK/field_borrow_branch_mutant.mdk"
append_field_probe "$WORK/field_borrow_branch_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/field_borrow_branch_mutant.mdk" -o "$WORK/field_borrow_branch_mutant" --keep-ir > "$WORK/build-borrow-mutant.log" 2>&1
extract_function subPSelect__rw "$WORK/field_borrow_branch_mutant.ll" "$WORK/borrow-mutant.ll"
borrow_mutant_ir_branches=$(grep -c 'br i1' "$WORK/borrow-mutant.ll" || true)
[ "$borrow_mutant_ir_branches" -gt "$field_borrow_ir_branches" ] || fail 'field borrow mutation is rejected by native IR control'
emitted_comparison_present "$WORK/borrow-mutant.ll" || fail 'field borrow mutation exposes equality in native IR'
pass 'field borrow mutation is rejected by native IR control'

# Int arithmetic on a limb puts an overflow branch on a secret operand
# (#3377). The straight-line field helpers have no counter for the audit to
# admit, so any overflow check in them must red it.
mutate_line "$FIELD" subPSelect \
  '  let o0 = U64.toIntTruncating (n0 + keep * (d0 - n0))' \
  '  let o0 = U64.toIntTruncating n0 + U64.toIntTruncating (keep * (d0 - n0))' \
  "$WORK/field_int_arith_mutant.mdk" || fail 'field secret Int-arithmetic mutation was constructed'
append_field_probe "$WORK/field_int_arith_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/field_int_arith_mutant.mdk" -o "$WORK/field_int_arith_mutant" --keep-ir > "$WORK/build-field-int-arith-mutant.log" 2>&1
extract_function subPSelect__rw "$WORK/field_int_arith_mutant.ll" "$WORK/field-int-arith-mutant.ll"
if ovf_operands_public "$WORK/field-int-arith-mutant.ll" -; then
  fail 'field secret Int-arithmetic mutation is rejected by the overflow-operand audit'
fi
pass 'field secret Int-arithmetic mutation is rejected by the overflow-operand audit'

mutate_line "$FIELD" subPSelect \
  '  let o0 = U64.toIntTruncating (n0 + keep * (d0 - n0))' \
  '  let o0 = if keep == 1 then U64.toIntTruncating d0 else U64.toIntTruncating n0' \
  "$WORK/field_branch_mutant.mdk" || fail 'field conditional-select mutation was constructed'
append_field_probe "$WORK/field_branch_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/field_branch_mutant.mdk" -o "$WORK/field_branch_mutant" --keep-ir > "$WORK/build-mutant.log" 2>&1
extract_function subPSelect__rw "$WORK/field_branch_mutant.ll" "$WORK/select-mutant.ll"
mutant_ir_branches=$(grep -c 'br i1' "$WORK/select-mutant.ll" || true)
[ "$mutant_ir_branches" -gt "$current_ir_branches" ] || fail 'conditional-select mutation is rejected by native IR control'
pass 'conditional-select mutation is rejected by native IR control'

cp "$SCALAR" "$WORK/scalar_emit.mdk"
append_scalar_probe "$WORK/scalar_emit.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_emit.mdk" -o "$WORK/scalar_emit" --keep-ir > "$WORK/build-scalar.log" 2>&1
# Re-derived for the 8 x 32 straight-line scalar (N5). Every audited scalar
# helper has no branch, no comparison, no write, no array_make or copy, and no
# cell allocation: its only calls are literal-index reads, the rawSc accessor
# and the next helper down. reduce512 and subNSelect are audited as their raw
# workers (`__rw`), the bodies every in-module caller reaches, whose U64
# parameters arrive as registers. No limb helper does Int arithmetic, so none
# has a public counter argument (`-`). The byte-codec rows moved 2026-09-27
# (see ir_call_shape_ok): limbsOfBytes' 32 reads are now `Bytes` reads, beWord
# makes four fromU8 calls, scToBytes gains its MutBytes make, eight putLimb
# calls and the freeze, and putLimb__rw's three branches are the overflow
# checks of `off + 1` to `off + 3`, on its public offset argument (1).
check_emitted_helpers "$WORK/scalar_emit.ll" "$WORK/scalar-ir" \
  subNSelect__rw:0:0:0:0:0:0:0:0:- reduce512__rw:0:0:0:0:0:0:1:0:- reduce256:0:0:8:0:0:0:9:0:- \
  scMul:0:0:16:0:0:0:19:0:- scAdd:0:0:16:0:0:0:19:0:- scNegateCt:0:0:8:0:0:0:10:0:- \
  scSelect:0:0:16:0:0:0:18:0:- scZeroBit:0:0:0:0:0:0:2:0:- zeroLimbsBit:0:0:8:0:0:0:8:0:- \
  scEqualBit:0:0:16:0:0:0:18:0:- scHighBit:0:0:8:0:0:0:9:0:- \
  secretBelowNBit:0:0:8:0:0:0:8:0:- secretNonzeroBit:0:0:0:0:0:0:2:0:- \
  limbsOfBytes:0:0:32:0:0:0:40:0:- beWord:0:0:0:0:0:0:4:0:- \
  scFromFixedBytesReduce:0:0:0:0:0:0:2:0:- scToBytes:0:0:8:0:1:0:19:0:- \
  putLimb__rw:3:0:0:4:0:0:8:0:1
extract_function rawSc "$WORK/scalar_emit.ll" "$WORK/scalar-ir/rawSc.ll"
raw_accessor_ir_ok "$WORK/scalar-ir/rawSc.ll" || fail 'scalar opaque-value accessor has only invariant representation dispatch'
emitted_local_closure_ok "$WORK/scalar-ir" scalar_emit || fail 'scalar emitted local call graph is closed'
pass 'scalar emitted local call graph is closed, including reduce512 and subNSelect raw workers'
u64_callees_ok "$WORK/scalar_emit.ll" "$WORK/scalar-ir" || fail 'scalar limb helpers make no u64 shift call and only allowlisted straight-line u64 calls'
pass 'scalar limb helpers make no u64 shift call and only allowlisted straight-line u64 calls'
# The literal-index detector is a negative assertion, so it is first proven
# able to see what it checks: the clean scSelect's sixteen reads must each
# match the literal-operand form it accepts.
[ "$(grep -E -c 'call i64 @mdk_impl_Array_index\(i64 %[A-Za-z0-9_.]+, i64 -?[0-9]+\)' "$WORK/scalar-ir/scSelect.ll" || true)" -eq 16 ] ||
  fail 'literal-index detector matches every read of the clean scSelect'
scalar_indices_literal "$WORK"/scalar-ir/*.ll || fail 'every scalar limb read is at a literal index'
pass 'every scalar limb read is at a literal index (detector proven live on scSelect)'
if emitted_comparison_present "$WORK/scalar-ir/subNSelect__rw.ll" || emitted_comparison_present "$WORK/scalar-ir/reduce512__rw.ll"; then
  fail 'current scalar reduction IR contains secret equality control'
fi
pass 'current scalar IR is straight-line: no branch, comparison, write or cell allocation'
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
extract_function scHighBit "$WORK/scalar_high_branch_emit.ll" "$WORK/scalar-high-branch-mutant.ll"
emitted_comparison_present "$WORK/scalar-high-branch-mutant.ll" || fail 'scalar high-bit secret-branch mutation reaches native IR'
[ "$(grep -c 'br i1' "$WORK/scalar-high-branch-mutant.ll" || true)" -gt 0 ] || fail 'scalar high-bit mutation adds secret IR control'
pass 'scalar high-bit secret-branch mutation is rejected by native IR control'

cp "$WORK/scalar_select_source_mutant.mdk" "$WORK/scalar_branch_mutant.mdk"
append_scalar_probe "$WORK/scalar_branch_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_branch_mutant.mdk" -o "$WORK/scalar_branch_mutant" --keep-ir > "$WORK/build-scalar-mutant.log" 2>&1
extract_function subNSelect__rw "$WORK/scalar_branch_mutant.ll" "$WORK/scalar-select-mutant.ll"
[ "$(grep -c 'br i1' "$WORK/scalar-select-mutant.ll" || true)" -gt 0 ] || fail 'scalar conditional-select mutation is rejected by native IR control'
emitted_comparison_present "$WORK/scalar-select-mutant.ll" || fail 'scalar conditional-select mutation exposes equality in native IR'
pass 'scalar conditional-select mutation is rejected by native IR control'

cp "$WORK/scalar_hash_source_mutant.mdk" "$WORK/scalar_hash_mutant.mdk"
append_scalar_probe "$WORK/scalar_hash_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_hash_mutant.mdk" -o "$WORK/scalar_hash_mutant" --keep-ir > "$WORK/build-scalar-hash-mutant.log" 2>&1
extract_function subNSelect__rw "$WORK/scalar_hash_mutant.ll" "$WORK/scalar-hash-mutant.ll"
if helper_ir_ok "$WORK/scalar-hash-mutant.ll" 0 0 0 0 0 0 0 0; then
  fail 'scalar comparison/hashBool mutation is rejected by native IR operation allowlist'
fi
grep -F -q 'mdk_hash_bool' "$WORK/scalar-hash-mutant.ll" || fail 'scalar comparison/hashBool mutation reaches native IR'
pass 'scalar comparison/hashBool mutation is rejected by native IR operation allowlist'

cp "$WORK/scalar_index_source_mutant.mdk" "$WORK/scalar_index_mutant.mdk"
append_scalar_probe "$WORK/scalar_index_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_index_mutant.mdk" -o "$WORK/scalar_index_mutant" --keep-ir > "$WORK/build-scalar-index-mutant.log" 2>&1
extract_function scSelect "$WORK/scalar_index_mutant.ll" "$WORK/scalar-index-mutant.ll"
if scalar_indices_literal "$WORK/scalar-index-mutant.ll"; then
  fail 'scalar secret-index mutation is rejected by the literal-index check'
fi
pass 'scalar secret-index mutation is rejected by the literal-index check'

cp "$WORK/scalar_write_source_mutant.mdk" "$WORK/scalar_write_mutant.mdk"
append_scalar_probe "$WORK/scalar_write_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_write_mutant.mdk" -o "$WORK/scalar_write_mutant" --keep-ir > "$WORK/build-scalar-write-mutant.log" 2>&1
extract_function scSelect "$WORK/scalar_write_mutant.ll" "$WORK/scalar-write-mutant.ll"
if helper_ir_ok "$WORK/scalar-write-mutant.ll" 0 0 16 0 0 0 18 0; then
  fail 'scalar secret-write mutation is rejected by native IR call multiset'
fi
write_calls=$(grep -F -c 'call i64 @mdk_array__setInPlace(' "$WORK/scalar-write-mutant.ll" || true)
make_calls=$(grep -F -c 'call i64 @mdk_array_make(' "$WORK/scalar-write-mutant.ll" || true)
[ "$write_calls" -gt 0 ] && [ "$make_calls" -gt 0 ] || fail 'scalar secret-write mutation reaches native IR'
pass 'scalar secret-write mutation is rejected by native IR call multiset'

cp "$WORK/scalar_rebound_index_source_mutant.mdk" "$WORK/scalar_rebound_index_mutant.mdk"
append_scalar_probe "$WORK/scalar_rebound_index_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_rebound_index_mutant.mdk" -o "$WORK/scalar_rebound_index_mutant" --keep-ir > "$WORK/build-scalar-rebound-index-mutant.log" 2>&1
extract_function scSelect "$WORK/scalar_rebound_index_mutant.ll" "$WORK/scalar-rebound-index-mutant.ll"
if scalar_indices_literal "$WORK/scalar-rebound-index-mutant.ll"; then
  fail 'scalar rebound secret-index mutation is rejected by the literal-index check'
fi
pass 'scalar rebound secret-index mutation is rejected by the literal-index check'

cp "$WORK/scalar_wrapper_source_mutant.mdk" "$WORK/scalar_wrapper_mutant.mdk"
append_scalar_probe "$WORK/scalar_wrapper_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_wrapper_mutant.mdk" -o "$WORK/scalar_wrapper_mutant" --keep-ir > "$WORK/build-scalar-wrapper-mutant.log" 2>&1
extract_function subNSelect__rw "$WORK/scalar_wrapper_mutant.ll" "$WORK/scalar-wrapper-subn.ll"
if ir_call_shape_ok subNSelect__rw "$WORK/scalar-wrapper-subn.ll"; then
  fail 'scalar leaky-wrapper mutation is rejected by native IR callee graph'
fi
grep -F -q '__leakyShift' "$WORK/scalar-wrapper-subn.ll" || fail 'scalar leaky-wrapper call reaches native IR'
pass 'scalar leaky-wrapper mutation is rejected by native IR callee graph'

cp "$WORK/scalar_copy_source_mutant.mdk" "$WORK/scalar_copy_mutant.mdk"
append_scalar_probe "$WORK/scalar_copy_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_copy_mutant.mdk" -o "$WORK/scalar_copy_mutant" --keep-ir > "$WORK/build-scalar-copy-mutant.log" 2>&1
extract_function reduce256 "$WORK/scalar_copy_mutant.ll" "$WORK/scalar-copy-mutant.ll"
if helper_ir_ok "$WORK/scalar-copy-mutant.ll" 0 0 8 0 0 0 9 0 && ir_call_shape_ok reduce256 "$WORK/scalar-copy-mutant.ll"; then
  fail 'scalar transitive reducer mutation is rejected by emitted helper shape'
fi
emitted_comparison_present "$WORK/scalar-copy-mutant.ll" || fail 'scalar transitive reducer branch reaches native IR'
pass 'scalar transitive reducer mutation is rejected by emitted helper shape'

# A limb-derived shift amount would reach the u64 shift's amount branch with a
# secret operand, and a non-literal amount is exactly what keeps the shift a
# wrapper call rather than an inline kernel. The u64 callee audit must red on
# it, independently of the source checker (#3427).
mutate_line "$SCALAR" subNSelect \
  '  let b0 = 1 - U64.shiftRight t0 32' \
  '  let b0 = 1 - U64.shiftRight t0 (32 + U64.toIntTruncating (U64.bitAnd r0 1))' \
  "$WORK/scalar_shift_amount_mutant.mdk" || fail 'scalar secret shift-amount mutation was constructed'
if source_helpers_ok "$FIELD" "$WORK/scalar_shift_amount_mutant.mdk" "$WORK/source-scalar-shift-amount-mutant"; then
  fail 'scalar secret shift-amount mutation is rejected by source structure'
fi
append_scalar_probe "$WORK/scalar_shift_amount_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_shift_amount_mutant.mdk" -o "$WORK/scalar_shift_amount_mutant" --keep-ir > "$WORK/build-scalar-shift-amount-mutant.log" 2>&1
mkdir -p "$WORK/scalar-shift-amount-ir"
extract_function subNSelect__rw "$WORK/scalar_shift_amount_mutant.ll" "$WORK/scalar-shift-amount-ir/subNSelect__rw.ll"
if u64_callees_ok "$WORK/scalar_shift_amount_mutant.ll" "$WORK/scalar-shift-amount-ir"; then
  fail 'scalar secret shift-amount mutation is rejected by the u64 callee audit'
fi
pass 'scalar secret shift-amount mutation is rejected by source structure and the u64 callee audit'

# Int arithmetic on a limb-derived value puts an overflow branch on a secret
# operand (#3377). The overflow-operand audit must red on it.
mutate_line "$SCALAR" subNSelect \
  '  let o0 = U64.toIntTruncating (r0 + keep * (d0 - r0))' \
  '  let o0 = U64.toIntTruncating r0 + U64.toIntTruncating (keep * (d0 - r0))' \
  "$WORK/scalar_int_arith_mutant.mdk" || fail 'scalar secret Int-arithmetic mutation was constructed'
append_scalar_probe "$WORK/scalar_int_arith_mutant.mdk"
MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/scalar_int_arith_mutant.mdk" -o "$WORK/scalar_int_arith_mutant" --keep-ir > "$WORK/build-scalar-int-arith-mutant.log" 2>&1
extract_function subNSelect__rw "$WORK/scalar_int_arith_mutant.ll" "$WORK/scalar-int-arith-mutant.ll"
if ovf_operands_public "$WORK/scalar-int-arith-mutant.ll" -; then
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
