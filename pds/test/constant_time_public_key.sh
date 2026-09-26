#!/bin/sh
# Native structural closure gate for #1700 step 2.  This is deliberately a
# source/IR/link audit, not a timing benchmark and not a Wasm claim.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
SOURCE="$ROOT/pds/test/constant_time_public_key_main.mdk"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/medaka-ct-public-key.XXXXXX")
cleanup() {
  if [ "${KEEP_WORK:-0}" = 1 ]; then printf 'kept work directory: %s\n' "$WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT HUP INT TERM

checked=0
pass() { checked=$((checked + 1)); printf 'ok %s - %s\n' "$checked" "$1"; }
fail() { printf 'not ok %s - %s\n' "$((checked + 1))" "$1" >&2; exit 1; }

# The checksums are a deliberately closed source manifest covering the
# arithmetic secret path: ingress -> scalar -> point -> public wrapper. It
# does not cover stdlib/bytes.mdk or the runtime's byte-block copy, which also
# hold key material since SecretKey moved to pointer-free storage (#3389).
# A change to these four files requires re-auditing the source, emitted IR,
# and linked code below; it cannot silently widen this trusted callee set.
source_closure_ok() {
  tree=$1
  [ "$(cksum "$tree/pds/lib/sign.mdk" | awk '{print $1 " " $2}')" = '1576054259 4921' ] || return 1
  [ "$(cksum "$tree/pds/lib/secp256k1.mdk" | awk '{print $1 " " $2}')" = '1691956410 24617' ] || return 1
  # Re-audited when both modules' limbs moved from Int to U64 (#3427): every
  # limb operation is a builtin U64 op or a u64 bit helper, the secret byte
  # scan and the *Bit predicates cross Int/U64 only through the masking
  # truncate/toIntTruncating, no branch was added, and the IR checks below
  # pass unchanged. constant_time_reductions.sh pins the helper-level shape.
  [ "$(cksum "$tree/pds/lib/scalar.mdk" | awk '{print $1 " " $2}')" = '3318702853 33856' ] || return 1
  [ "$(cksum "$tree/pds/lib/field.mdk" | awk '{print $1 " " $2}')" = '3367372070 26913' ] || return 1

  tr -s '[:space:]' ' ' < "$tree/pds/lib/secp256k1.mdk" | grep -F -q 'if i >= 256 then r0' || return 1
  grep -F -q 'let added = pointAddComplete r0 r1' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let doubled0 = pointDoubleComplete r0' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let doubled1 = pointDoubleComplete r1' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let next0 = pointSelect bit doubled0 added' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let next1 = pointSelect bit added doubled1' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let bytesBit = scanSecretBytes bs safeBytes 0 1' "$tree/pds/lib/scalar.mdk" || return 1
  grep -F -q '(U64.toIntTruncating (bytesBit * rangeBit * nonzeroBit), candidate)' "$tree/pds/lib/scalar.mdk" || return 1
  grep -F -q 'scanSecretBytes bs safeBytes (i + 1) (validBit * byteBit)' "$tree/pds/lib/scalar.mdk" || return 1
  grep -F -q 'fieldSubCt a b = feAdd a (feNegateCt b)' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'pointSelect opposite afterEqual pointInfinity' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'publicKeyForSecret key = PublicKey (publicPointForSecret (secretScalar key))' "$tree/pds/lib/sign.mdk" || return 1
}

restore_tree() {
  cp "$ROOT/pds/lib/sign.mdk" "$WORK/pds/lib/sign.mdk"
  cp "$ROOT/pds/lib/secp256k1.mdk" "$WORK/pds/lib/secp256k1.mdk"
  cp "$ROOT/pds/lib/scalar.mdk" "$WORK/pds/lib/scalar.mdk"
  cp "$ROOT/pds/lib/field.mdk" "$WORK/pds/lib/field.mdk"
  source_closure_ok "$WORK" || fail 'restored mutation tree matches the closed source manifest'
  cmp "$ROOT/pds/lib/sign.mdk" "$WORK/pds/lib/sign.mdk"
  cmp "$ROOT/pds/lib/secp256k1.mdk" "$WORK/pds/lib/secp256k1.mdk"
  cmp "$ROOT/pds/lib/scalar.mdk" "$WORK/pds/lib/scalar.mdk"
  cmp "$ROOT/pds/lib/field.mdk" "$WORK/pds/lib/field.mdk"
}

expect_source_red() {
  id=$1
  if source_closure_ok "$WORK"; then fail "$id unexpectedly green (closed source audit)"; fi
  pass "$id is rejected by the closed source audit"
  restore_tree
}

blob_hash() { cksum "$1" | awk '{print $1 " " $2}'; }

apply_mutation() {
  id=$1 file=$2 anchor=$3 program=$4
  matches=$(grep -F -c "$anchor" "$file" || true)
  [ "$matches" -eq 1 ] || fail "$id mutation anchor is unique (got $matches matches)"
  before=$(blob_hash "$file")
  perl -0pi -e "$program" "$file"
  after=$(blob_hash "$file")
  [ "$before" != "$after" ] || fail "$id mutation changed its target blob"
}

extract_ir_function() {
  suffix=$1 input=$2 output=$3
  awk -v suffix="__$suffix" '$0 ~ ("^define i64 @.*" suffix "\\(") { inside = 1 } inside { print } inside && /^}/ { exit }' "$input" > "$output"
  [ -s "$output" ] || fail "emitted helper $suffix exists"
}

require_emitted_symbol() {
  symbol=$1
  grep -F -q "define i64 @$symbol(" "$IR" || fail "emitted secret closure contains $symbol"
}

require_native_symbol() {
  symbol=$1
  nm "$BIN" | awk -v symbol="$symbol" '$3 == symbol || $3 == "_" symbol { found = 1 } END { exit !found }' || fail "linked native closure contains $symbol"
}

check_ir_closure() {
  sed -n 's/.*call i64 @\(mdk_\(force_\)\?lib_\(sign\|secp256k1\|scalar\|field\)__[^ (]*\).*/\1/p' "$IR" | sort -u > "$WORK/callees"
  while IFS= read -r symbol; do
    [ -n "$symbol" ] || continue
    grep -F -q "define i64 @$symbol(" "$IR" || fail "emitted local callee graph is closed at $symbol"
  done < "$WORK/callees"
  pass 'emitted secret-path local callee graph is closed'
}

conditional_jumps() {
  case $(uname -m) in
    x86_64|amd64) grep -E -c '[[:space:]]j[a-z]+[[:space:]]' "$1" || true ;;
    arm64|aarch64) grep -E -c '[[:space:]](b\.[a-z]+|cbz|cbnz|tbz|tbnz)[[:space:]]' "$1" || true ;;
    *) return 2 ;;
  esac
}

cp -R "$ROOT/pds" "$WORK/pds"
source_closure_ok "$WORK" || fail 'baseline source matches the closed secret-path manifest'
pass 'source closure covers ingress, scalar/field reducers, point ladder, and public wrapper'

# Contract mutations 1--6, 14, and 15.  Each mutation is confined to the
# disposable copy, must turn the closed audit red, and is restored byte-exactly.
apply_mutation 'M01' "$WORK/pds/lib/secp256k1.mdk" 'scalarLadder bytes r0 r1 i =' 's/(scalarLadder bytes r0 r1 i =\n  if i >= )256/${1}255/'
expect_source_red 'M01 256-to-255 ladder schedule'

apply_mutation 'M02' "$WORK/pds/lib/secp256k1.mdk" 'let next0 = pointSelect bit doubled0 added' 's/let next0 = pointSelect bit doubled0 added/let next0 = if bit == 0 then doubled0 else added/'
expect_source_red 'M02 bit-select-to-secret-if'

apply_mutation 'M03' "$WORK/pds/lib/secp256k1.mdk" 'let byte = bytes[i / 8]' 's/let byte = bytes\[i \/ 8\]/let byte = bytes[bit]/'
expect_source_red 'M03 secret-derived byte index'

apply_mutation 'M04' "$WORK/pds/lib/secp256k1.mdk" 'let afterOpposite = pointSelect opposite afterEqual pointInfinity' 's/let afterOpposite = pointSelect opposite afterEqual pointInfinity/let afterOpposite = afterEqual/'
expect_source_red 'M04 omitted exceptional opposite selection'

apply_mutation 'M05' "$WORK/pds/lib/field.mdk" 'feZeroBit a = U64.toIntTruncating (feZeroBorrow (rawFe a) 0 1)' 's/feZeroBit a = U64\.toIntTruncating \(feZeroBorrow \(rawFe a\) 0 1\)/feZeroBit a = hashBool (feEqual a feZero)/'
expect_source_red 'M05 Bool/sentinel zero conversion'

apply_mutation 'M06' "$WORK/pds/lib/secp256k1.mdk" 'secretAffine (JPoint x y z) =' 's/secretAffine \(JPoint x y z\) =/secretAffine (JPoint x y z) = if feZeroBit z == 1 then AffinePoint feZero feZero else/'
expect_source_red 'M06 secret infinity early return'

apply_mutation 'M14' "$WORK/pds/lib/secp256k1.mdk" 'fieldSubCt a b = feAdd a (feNegateCt b)' 's/fieldSubCt a b = feAdd a \(feNegateCt b\)/fieldSubCt a b = feAdd a b/'
expect_source_red 'M14 omitted transitive constant-time wrapper'

apply_mutation 'M15-byte' "$WORK/pds/lib/scalar.mdk" '(bytesBit * rangeBit * nonzeroBit), candidate)' 's/\(bytesBit \* rangeBit \* nonzeroBit\), candidate\)/(rangeBit * nonzeroBit), candidate)/'
expect_source_red 'M15 byte-domain aggregate omission'

apply_mutation 'M15-range' "$WORK/pds/lib/scalar.mdk" '(bytesBit * rangeBit * nonzeroBit), candidate)' 's/\(bytesBit \* rangeBit \* nonzeroBit\), candidate\)/(bytesBit * nonzeroBit), candidate)/'
expect_source_red 'M15 range aggregate omission'

apply_mutation 'M15-zero' "$WORK/pds/lib/scalar.mdk" '(bytesBit * rangeBit * nonzeroBit), candidate)' 's/\(bytesBit \* rangeBit \* nonzeroBit\), candidate\)/(bytesBit * rangeBit), candidate)/'
expect_source_red 'M15 zero aggregate omission'

apply_mutation 'M15-early' "$WORK/pds/lib/scalar.mdk" 'let byteBit = secretByteBit b' 's/let byteBit = secretByteBit b/if b < 0 then validBit else\n    let byteBit = secretByteBit b/'
expect_source_red 'M15 per-element secret early return'

cmp "$ROOT/pds/lib/sign.mdk" "$WORK/pds/lib/sign.mdk"
cmp "$ROOT/pds/lib/secp256k1.mdk" "$WORK/pds/lib/secp256k1.mdk"
cmp "$ROOT/pds/lib/scalar.mdk" "$WORK/pds/lib/scalar.mdk"
cmp "$ROOT/pds/lib/field.mdk" "$WORK/pds/lib/field.mdk"
pass 'all mutations restored exact baseline bytes and task-owned crypto source is clean'

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$SOURCE" -o "$WORK/public-key" --keep-ir > "$WORK/build.log" 2>&1 || { cat "$WORK/build.log" >&2; fail 'native public-key closure probe builds'; }
BIN="$WORK/public-key"
IR="$WORK/public-key.ll"
"$BIN" > "$WORK/run.out" 2>&1 || { cat "$WORK/run.out" >&2; fail 'native composed public-key probe runs'; }
grep -F -q 'PASS public-key-closure' "$WORK/run.out" || fail 'native composed public-key output is generator G'
pass 'native secret ingress composes to the expected compressed public key'

for symbol in \
  mdk_lib_sign__secretKeyFromBytes mdk_lib_sign__publicKeyForSecret mdk_lib_sign__publicKeyCompressed \
  mdk_lib_scalar__scSecretCandidate mdk_lib_scalar__scanSecretBytes \
  mdk_lib_scalar__secretBelowNBorrow mdk_lib_scalar__secretNonzeroBorrow \
  mdk_lib_scalar__reduceFixed mdk_lib_scalar__selectNCandidate \
  mdk_lib_field__reduceCarry mdk_lib_field__feZeroBorrow mdk_lib_field__feSelectGo \
  mdk_lib_secp256k1__scalarLadder mdk_lib_secp256k1__pointAddComplete \
  mdk_lib_secp256k1__pointDoubleComplete mdk_lib_secp256k1__secretAffine \
  mdk_lib_secp256k1__publicPointForSecret mdk_lib_secp256k1__pointCompressed
do require_emitted_symbol "$symbol"; done
pass 'emitted LLVM retains every named secret-path helper, including public wrappers'

# At -O2 the three public sign wrappers are intentionally inlined into main;
# their emitted bodies remain closed above.  These non-inlined leaves prove the
# final linked topology still contains ingress and the ladder's complete path.
# secretNonzeroBorrow, reduceFixed and secretAffine are deliberately NOT in this
# list.  All three are branch-free or public-index-bounded, so -O2 is free to
# unroll and inline them, and whether it does is a cost-threshold artifact
# rather than anything about secrets.  Their shapes are pinned structurally in
# the IR below, where the definitions always exist.
# scanSecretBytes and secretBelowNBorrow left this list when `medaka build`
# linked the runtime through ThinLTO (#3374), which inlines both into
# scSecretCandidate. What is lost is only the claim that each is a distinct
# function in the linked binary. Their shape is still caught where the
# definitions always exist: both are in the emitted-symbol list above, the
# closed source manifest pins scalar.mdk byte for byte, and M15 reds every
# aggregate omission and a per-element early return in scanSecretBytes.
#
# scSecretCandidate, scalarLadder, pointAddComplete, publicPointForSecret and
# pointCompressed left this list when the field and scalar limbs moved to U64
# (#3427). A U64 constant is static data, so the lazy-constant forces those
# paths called (pointInfinity, scZero, scOne, feZero, feOne and the limb
# constants) are gone, each wrapper shrank, and in this probe the link now
# inlines the ingress and the whole ladder into the program's main. Measured
# on the #3427 tree: of the named secret-path functions only carryFoldRound,
# pointDoubleComplete and pointSelect survive as symbols. What is lost is the
# claim that the ladder and its complete addition are distinct functions in
# this binary, and with it the disassembly check of the linked ladder that
# stood below. Their shape is still pinned where the definitions always
# exist: the emitted-symbol list above, the emitted scalarLadder topology
# check below (256 rounds, one complete addition, two doublings, two
# selections per round), and the closed source manifest. The signing gate's
# internal carrier still links scalarLadder and pointAddComplete as symbols.
for symbol in \
  mdk_lib_field__carryFoldRound \
  mdk_lib_secp256k1__pointDoubleComplete mdk_lib_secp256k1__pointSelect
do require_native_symbol "$symbol"; done
pass 'linked native code retains the field reducer, complete doubling and arithmetic-selection leaves'
check_ir_closure

# secretNonzeroBorrow walks the limbs to fold a nonzero test.  What must hold is
# that every branch it takes is on the public limb index and every secret limb
# flows through straight-line arithmetic; whether the linker keeps it as a call
# is the optimizer's business.  Pin that shape in the emitted IR, where the
# helper always exists.
extract_ir_function secretNonzeroBorrow "$IR" "$WORK/secretNonzeroBorrow.ll"
[ "$(grep -c 'br i1' "$WORK/secretNonzeroBorrow.ll" || true)" -eq 1 ] || fail 'secret nonzero fold branches exactly once'
grep -q '^  %t0 = icmp sge i64 %arg1, ' "$WORK/secretNonzeroBorrow.ll" || fail 'secret nonzero fold branches on its public limb index'
[ "$(grep -E -c 'call i64 @mdk_value_(eq|ne|lt|le|gt|ge)\(' "$WORK/secretNonzeroBorrow.ll" || true)" -eq 0 ] || fail 'secret nonzero fold makes no value comparisons'
[ "$(grep -F -c 'call i64 @mdk_lib_scalar__secretNonzeroBorrow(' "$WORK/secretNonzeroBorrow.ll" || true)" -eq 1 ] || fail 'secret nonzero fold recurses exactly once per limb'
pass 'emitted secret nonzero fold branches only on its public limb index'

# reduceFixed is an unconditional fixed schedule: the reduction must run the same
# carry/fold rounds regardless of the value being reduced.  That is the property,
# not its survival as a distinct linked symbol.
extract_ir_function reduceFixed "$IR" "$WORK/reduceFixed.ll"
[ "$(grep -c 'br i1' "$WORK/reduceFixed.ll" || true)" -eq 0 ] || fail 'fixed reduction is unconditional'
[ "$(grep -F -c '@mdk_lib_scalar__carryAllUnchecked(' "$WORK/reduceFixed.ll" || true)" -eq 5 ] || fail 'fixed reduction runs five carry passes'
[ "$(grep -F -c '@mdk_lib_scalar__foldOnce(' "$WORK/reduceFixed.ll" || true)" -eq 4 ] || fail 'fixed reduction runs four folds'
pass 'emitted fixed reduction runs its schedule unconditionally'

# secretAffine converts the ladder's Jacobian result to affine.  Its caller has
# already established the point is non-infinity, so the property is that it runs
# exactly one inversion over a straight line with no Z==0 branch -- not that the
# linker keeps it as a distinct symbol.  It moved out of the linked-survival list
# above when its emitted body lost the generic immediate-vs-boxed discriminant
# split (the JPoint roster is always boxed, so that arm was dead), which took the
# body under -O2's inline threshold at its sole call site, publicPointForSecret --
# still linked, as are scalarLadder and both complete point operations, so the
# ladder topology the list exists to prove is unaffected.  Nothing emitter-side
# steers that decision: the emitted IR carries no inline attributes at all.  Pin
# the shape here instead, where the definition always exists.
#
# BRANCH COUNT IS THE PROPERTY; the comparison count is only its witness.  The one
# surviving branch must be a comparison against a compile-time constructor tag,
# never against a value: an integer-literal right operand is what makes it so.
# The comparison count rose 1 -> 2 when the all-boxed discriminant load regained
# its pointer guard: the second `icmp` tests the scrutinee's low tag bit and feeds
# a `select` over the ADDRESS to load from, never a branch, so the guard is
# branchless by construction and this function's timing is unchanged.  The branch
# assertion below is what would catch a guard that grew a branch instead; it is
# pinned at 1 and must stay there.  (Same column-audit discipline as
# FIX-pds-constant-time-audit, 9b956cb42: move a pinned constant only with the
# measurement and the reason.)
extract_ir_function secretAffine "$IR" "$WORK/secretAffine.ll"
[ "$(grep -c 'br i1' "$WORK/secretAffine.ll" || true)" -eq 1 ] || fail 'secret affine conversion branches exactly once'
[ "$(grep -E -c '= icmp ' "$WORK/secretAffine.ll" || true)" -eq 2 ] || fail 'secret affine conversion makes exactly two comparisons (one tag test, one branchless pointer guard)'
[ "$(grep -E -c '= select i1 ' "$WORK/secretAffine.ll" || true)" -eq 1 ] || fail 'secret affine pointer guard is a select, not a branch'
[ "$(grep -E -c '= icmp eq i64 %t[0-9]+, [0-9]+$' "$WORK/secretAffine.ll" || true)" -eq 2 ] || fail 'both secret affine comparisons have a constant right operand (constructor tag, low-bit guard)'
[ "$(grep -E -c 'call i64 @mdk_value_(eq|ne|lt|le|gt|ge)\(' "$WORK/secretAffine.ll" || true)" -eq 0 ] || fail 'secret affine conversion makes no value comparisons'
[ "$(grep -F -c 'call i64 @mdk_lib_field__feInverse(' "$WORK/secretAffine.ll" || true)" -eq 1 ] || fail 'secret affine conversion runs exactly one inversion'
[ "$(grep -F -c 'call i64 @mdk_lib_field__feSquare(' "$WORK/secretAffine.ll" || true)" -eq 1 ] || fail 'secret affine conversion runs exactly one squaring'
[ "$(grep -F -c 'call i64 @mdk_lib_field__feMul(' "$WORK/secretAffine.ll" || true)" -eq 3 ] || fail 'secret affine conversion runs exactly three multiplications'
pass 'emitted secret affine conversion is one unconditional inversion over a constant-tag branch'

extract_ir_function scalarLadder "$IR" "$WORK/scalarLadder.ll"
[ "$(grep -c 'br i1' "$WORK/scalarLadder.ll" || true)" -eq 3 ] || fail 'scalar ladder has exactly its fixed loop/control topology'
[ "$(grep -F -c '__pointAddComplete' "$WORK/scalarLadder.ll" || true)" -eq 1 ] || fail 'scalar ladder computes one complete addition per round'
[ "$(grep -F -c '__pointDoubleComplete' "$WORK/scalarLadder.ll" || true)" -eq 2 ] || fail 'scalar ladder computes two complete doublings per round'
[ "$(grep -F -c '__pointSelect' "$WORK/scalarLadder.ll" || true)" -eq 2 ] || fail 'scalar ladder makes two arithmetic selections per round'
pass 'emitted scalar ladder preserves 256-round add/two-double/select topology'

# The linked-ladder disassembly check that stood here retired with the ladder's
# symbol (#3427; see the native-symbol list above). The link inlines the ladder
# into main, whose body is not the ladder alone, so pinning its call counts
# would pin an inlining decision rather than the ladder's topology.

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

check_bit_witness 'bitXor (bitAnd a b) (shiftRight a (bitAnd b 7))' \
  mdk_bit_and mdk_bit_xor mdk_shift_right

printf 'receipt: target=%s %s\n' "$(uname -s)" "$(uname -m)"
printf 'receipt: compiler=%s\n' "$(clang --version | sed -n '1p')"
[ "$checked" -ge 22 ] || fail "assertion floor (expected at least 22, got $checked)"
printf 'PASS: native public-key constant-time closure — %s assertions\n' "$checked"
