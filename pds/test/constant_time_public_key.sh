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

# The checksums are a deliberately closed source manifest.  The four files are
# the complete Medaka secret path: ingress -> scalar -> point -> public wrapper.
# A change requires re-auditing the source, emitted IR, and linked code below;
# it cannot silently widen the trusted callee set.
source_closure_ok() {
  tree=$1
  [ "$(cksum "$tree/pds/lib/sign.mdk" | awk '{print $1 " " $2}')" = '250986905 1892' ] || return 1
  [ "$(cksum "$tree/pds/lib/secp256k1.mdk" | awk '{print $1 " " $2}')" = '2739052739 23936' ] || return 1
  [ "$(cksum "$tree/pds/lib/scalar.mdk" | awk '{print $1 " " $2}')" = '2702220718 31363' ] || return 1
  [ "$(cksum "$tree/pds/lib/field.mdk" | awk '{print $1 " " $2}')" = '2995963130 26246' ] || return 1

  grep -F -q 'if i >= 256 then r0' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let added = pointAddComplete r0 r1' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let doubled0 = pointDoubleComplete r0' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let doubled1 = pointDoubleComplete r1' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let next0 = pointSelect bit doubled0 added' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let next1 = pointSelect bit added doubled1' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let bytesBit = scanSecretBytes bs safeBytes 0 1' "$tree/pds/lib/scalar.mdk" || return 1
  grep -F -q '(bytesBit * rangeBit * nonzeroBit, candidate)' "$tree/pds/lib/scalar.mdk" || return 1
  grep -F -q 'scanSecretBytes bs safeBytes (i + 1) (validBit * byteBit)' "$tree/pds/lib/scalar.mdk" || return 1
  grep -F -q 'fieldSubCt a b = feAdd a (feNegateCt b)' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'pointSelect opposite afterEqual pointInfinity' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'publicKeyForSecret (SecretKey scalar) = PublicKey (publicPointForSecret scalar)' "$tree/pds/lib/sign.mdk" || return 1
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

disassemble() {
  symbol=$1 output=$2
  case $(uname -s) in
    Darwin) otool -tvV "$BIN" | awk -v label="_$symbol:" '$0 == label { p=1; next } p && /^_[A-Za-z0-9_.$]+:$/ { exit } p { print }' > "$output" ;;
    *) objdump -d --disassemble="$symbol" "$BIN" > "$output" ;;
  esac
  [ -s "$output" ] || fail "native disassembly exists for $symbol"
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
apply_mutation 'M01' "$WORK/pds/lib/secp256k1.mdk" 'if i >= 256 then r0' 's/if i >= 256 then r0/if i >= 255 then r0/'
expect_source_red 'M01 256-to-255 ladder schedule'

apply_mutation 'M02' "$WORK/pds/lib/secp256k1.mdk" 'let next0 = pointSelect bit doubled0 added' 's/let next0 = pointSelect bit doubled0 added/let next0 = if bit == 0 then doubled0 else added/'
expect_source_red 'M02 bit-select-to-secret-if'

apply_mutation 'M03' "$WORK/pds/lib/secp256k1.mdk" 'let byte = bytes[i / 8]' 's/let byte = bytes\[i \/ 8\]/let byte = bytes[bit]/'
expect_source_red 'M03 secret-derived byte index'

apply_mutation 'M04' "$WORK/pds/lib/secp256k1.mdk" 'let afterOpposite = pointSelect opposite afterEqual pointInfinity' 's/let afterOpposite = pointSelect opposite afterEqual pointInfinity/let afterOpposite = afterEqual/'
expect_source_red 'M04 omitted exceptional opposite selection'

apply_mutation 'M05' "$WORK/pds/lib/field.mdk" 'feZeroBit a = feZeroBorrow (rawFe a) 0 1' 's/feZeroBit a = feZeroBorrow \(rawFe a\) 0 1/feZeroBit a = hashBool (feEqual a feZero)/'
expect_source_red 'M05 Bool/sentinel zero conversion'

apply_mutation 'M06' "$WORK/pds/lib/secp256k1.mdk" 'secretAffine (JPoint x y z) =' 's/secretAffine \(JPoint x y z\) =/secretAffine (JPoint x y z) = if feZeroBit z == 1 then AffinePoint feZero feZero else/'
expect_source_red 'M06 secret infinity early return'

apply_mutation 'M14' "$WORK/pds/lib/secp256k1.mdk" 'fieldSubCt a b = feAdd a (feNegateCt b)' 's/fieldSubCt a b = feAdd a \(feNegateCt b\)/fieldSubCt a b = feAdd a b/'
expect_source_red 'M14 omitted transitive constant-time wrapper'

apply_mutation 'M15-byte' "$WORK/pds/lib/scalar.mdk" '(bytesBit * rangeBit * nonzeroBit, candidate)' 's/\(bytesBit \* rangeBit \* nonzeroBit, candidate\)/(rangeBit * nonzeroBit, candidate)/'
expect_source_red 'M15 byte-domain aggregate omission'

apply_mutation 'M15-range' "$WORK/pds/lib/scalar.mdk" '(bytesBit * rangeBit * nonzeroBit, candidate)' 's/\(bytesBit \* rangeBit \* nonzeroBit, candidate\)/(bytesBit * nonzeroBit, candidate)/'
expect_source_red 'M15 range aggregate omission'

apply_mutation 'M15-zero' "$WORK/pds/lib/scalar.mdk" '(bytesBit * rangeBit * nonzeroBit, candidate)' 's/\(bytesBit \* rangeBit \* nonzeroBit, candidate\)/(bytesBit * rangeBit, candidate)/'
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
for symbol in \
  mdk_lib_scalar__scSecretCandidate mdk_lib_scalar__scanSecretBytes \
  mdk_lib_scalar__secretBelowNBorrow mdk_lib_scalar__secretNonzeroBorrow \
  mdk_lib_scalar__reduceFixed mdk_lib_field__carryFoldRound \
  mdk_lib_secp256k1__scalarLadder mdk_lib_secp256k1__pointAddComplete \
  mdk_lib_secp256k1__pointDoubleComplete mdk_lib_secp256k1__secretAffine \
  mdk_lib_secp256k1__publicPointForSecret mdk_lib_secp256k1__pointCompressed
do require_native_symbol "$symbol"; done
pass 'linked native code retains ingress and complete-ladder helper topology'
check_ir_closure

extract_ir_function scalarLadder "$IR" "$WORK/scalarLadder.ll"
[ "$(grep -c 'br i1' "$WORK/scalarLadder.ll" || true)" -eq 3 ] || fail 'scalar ladder has exactly its fixed loop/control topology'
[ "$(grep -F -c '__pointAddComplete' "$WORK/scalarLadder.ll" || true)" -eq 1 ] || fail 'scalar ladder computes one complete addition per round'
[ "$(grep -F -c '__pointDoubleComplete' "$WORK/scalarLadder.ll" || true)" -eq 2 ] || fail 'scalar ladder computes two complete doublings per round'
[ "$(grep -F -c '__pointSelect' "$WORK/scalarLadder.ll" || true)" -eq 2 ] || fail 'scalar ladder makes two arithmetic selections per round'
pass 'emitted scalar ladder preserves 256-round add/two-double/select topology'

ladder_symbol=$(nm "$BIN" | awk '$3 ~ /mdk_lib_secp256k1__scalarLadder$/ { print $3; exit }')
[ -n "$ladder_symbol" ] || fail 'linked scalar ladder symbol exists'
disassemble "$ladder_symbol" "$WORK/scalar-ladder.asm"
[ "$(grep -F -c '__pointAddComplete' "$WORK/scalar-ladder.asm" || true)" -eq 1 ] || fail 'linked scalar ladder retains complete addition call'
[ "$(grep -F -c '__pointDoubleComplete' "$WORK/scalar-ladder.asm" || true)" -eq 2 ] || fail 'linked scalar ladder retains both complete doubling calls'
pass 'linked native ladder retains complete candidate topology'

for helper in mdk_bit_and mdk_bit_xor mdk_shift_right; do
  symbol=$(nm "$BIN" | awk -v wanted="$helper" '$3 == wanted || $3 == "_" wanted { sub(/^_/, "", $3); print $3; exit }')
  [ -n "$symbol" ] || fail "linked runtime helper $helper exists"
  disassemble "$symbol" "$WORK/$helper.asm"
  jumps=$(conditional_jumps "$WORK/$helper.asm") || fail "supported target for $helper disassembly"
  [ "$jumps" -eq 0 ] || fail "runtime helper $helper has no conditional jumps (got $jumps)"
  pass "runtime helper $helper has no conditional jumps"
done

printf 'receipt: target=%s %s\n' "$(uname -s)" "$(uname -m)"
printf 'receipt: compiler=%s\n' "$(clang --version | sed -n '1p')"
[ "$checked" -ge 22 ] || fail "assertion floor (expected at least 22, got $checked)"
printf 'PASS: native public-key constant-time closure — %s assertions\n' "$checked"
