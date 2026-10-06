#!/bin/sh
# Native structural closure gate for #1700 step 2.  This is deliberately a
# source/IR/link audit, not a timing benchmark and not a Wasm claim.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
MEDAKA=${MEDAKA:-"$ROOT/medaka"}

# Every `--keep-ir` build goes through here: the kept module is rewritten by
# pds/tools/ct_ir_canonical.awk, so a located array read audits as the plain
# Index impl call (its site literal stripped), and a site that is anything
# but a literal on the trap path fails the build.
ct_build_ir() {
  "$MEDAKA" "$@" || return
  ct_out=
  ct_prev=
  for ct_arg in "$@"; do
    [ "$ct_prev" = -o ] && ct_out=$ct_arg
    ct_prev=$ct_arg
  done
  [ -n "$ct_out" ] && [ -s "$ct_out.ll" ] || { echo "ct_build_ir: no kept IR for -o '$ct_out'" >&2; return 1; }
  awk -f "$ROOT/pds/tools/ct_ir_canonical.awk" "$ct_out.ll" > "$ct_out.ll.canon" || return 1
  mv "$ct_out.ll.canon" "$ct_out.ll"
}
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
  # Re-audited 2026-09-27 when the signing stack moved to `Bytes`: the
  # secret key, digest and every codec are `Bytes`, the ingress takes the
  # byte domain from the type, and the ladder reads its scalar bytes through
  # the `Bytes` index at the public counter `i / 8`. No source branch was
  # added on a secret value; the anchors below say where each moved.
  # Re-audited 2026-09-27 when sign.mdk's transitional `Array Int` secret-key
  # ingress was deleted: every caller now passes `Bytes` to
  # `secretKeyFromBytes`, and the deletion removed a function and its helper
  # without touching any remaining definition.
  # Re-audited 2026-09-30 for the `Sign` label: `signDigest` became private
  # with an unchanged body, and two exported signers that only delegate to it
  # were added. `publicKeyForSecret` and `secretScalar` did not move.
  # Re-pinned 2026-09-30 again for a header-comment rewrite only; no
  # definition changed.
  [ "$(cksum "$tree/pds/lib/sign.mdk" | awk '{print $1 " " $2}')" = '2451873097 6303' ] || return 1
  # Re-audited when Int began trapping on overflow (#3377): secp256k1.mdk's
  # secret condition bits combine through bitAnd/bitOr/bitXor instead of
  # `+ - *`, and the RFC 6979 byte blend runs on U64, so no Int overflow
  # check in it tests a secret operand.
  [ "$(cksum "$tree/pds/lib/secp256k1.mdk" | awk '{print $1 " " $2}')" = '2537316894 24171' ] || return 1
  # Re-audited when both modules' limb arithmetic moved to U64 expressions
  # over Int storage (#3427): every limb step widens through U64.truncate and
  # narrows through U64.toIntTruncating, the secret byte scan's validity and
  # aggregate bits combine through bitAnd, no source branch was added, and the
  # IR checks below pass. constant_time_reductions.sh pins the helper shape.
  # Re-audited for N5: the scalar on 8 x 32 limbs and the field on 5x52 limbs
  # are straight-line U64 code with literal limb indices, and no source branch
  # tests a limb (one fold/carry round and an unconditional subtract-and-select
  # for the field, three folds and the carry-aware subtract-and-select for the
  # scalar). The secret-ingress lines pinned below are unchanged, and
  # constant_time_reductions.sh pins each helper's source and IR shape.
  [ "$(cksum "$tree/pds/lib/scalar.mdk" | awk '{print $1 " " $2}')" = '155881618 41112' ] || return 1
  [ "$(cksum "$tree/pds/lib/field.mdk" | awk '{print $1 " " $2}')" = '3731538746 28626' ] || return 1

  tr -s '[:space:]' ' ' < "$tree/pds/lib/secp256k1.mdk" | grep -F -q 'if i >= 256 then r0' || return 1
  grep -F -q 'let added = pointAddComplete r0 r1' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let doubled0 = pointDoubleComplete r0' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let doubled1 = pointDoubleComplete r1' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let next0 = pointSelect bit doubled0 added' "$tree/pds/lib/secp256k1.mdk" || return 1
  grep -F -q 'let next1 = pointSelect bit added doubled1' "$tree/pds/lib/secp256k1.mdk" || return 1
  # Since 2026-09-27 the candidate parser takes `Bytes`, whose type is the
  # byte domain, so the per-element byte scan and its bit are gone: the
  # aggregate is the range and nonzero bits over the 32-byte limbs, behind a
  # public length test.
  grep -F -q 'if B.length bs /= 32 then (0, scZero) else scSecretCandidate32 bs' "$tree/pds/lib/scalar.mdk" || return 1
  grep -F -q '(bitAnd rangeBit nonzeroBit, candidate)' "$tree/pds/lib/scalar.mdk" || return 1
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

# Every conditional branch in helper $1 tests a value computed only from
# literals and the helper's public counter arguments ($2, `+`-separated
# indexes). Since Int overflow traps (#3377), each Int `+ - *` and each `/` or
# `%` adds a branch (the overflow flag, the zero divisor); this proves every
# such branch here sits on counter arithmetic, never on a limb or a key byte.
branches_public() {
  awk -v pub="$2" '
    BEGIN { n = split(pub, p, "+"); for (k = 1; k <= n; k++) public["%arg" p[k]] = 1 }
    /^  %[A-Za-z0-9_.]+ = / {
      dst = $1
      rest = $0
      sub(/^  %[A-Za-z0-9_.]+ = /, "", rest)
      op = rest
      sub(/ .*/, "", op)
      ok = (op ~ /^(add|sub|mul|sdiv|srem|ashr|lshr|shl|or|and|xor|icmp|zext|sext|trunc|extractvalue|select)$/) ||
        (rest ~ /@llvm\.s(add|sub|mul)\.with\.overflow/)
      body = rest
      sub(/^[^%]*/, "", body)
      all = 1
      while (match(body, /%[A-Za-z0-9_.]+/)) {
        if (!(substr(body, RSTART, RLENGTH) in public)) all = 0
        body = substr(body, RSTART + RLENGTH)
      }
      if (ok && all) public[dst] = 1
    }
    /^  br i1 / {
      c = $3
      sub(/,$/, "", c)
      branches++
      if (!(c in public)) bad++
    }
    END { exit !(branches > 0 && bad == 0) }
  ' "$1"
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
apply_mutation 'M01' "$WORK/pds/lib/secp256k1.mdk" 'scalarLadder bytes r0 r1 i =' 's/(scalarLadder bytes r0 r1 i =\n  if i >= )256/${1}255/'
expect_source_red 'M01 256-to-255 ladder schedule'

apply_mutation 'M02' "$WORK/pds/lib/secp256k1.mdk" 'let next0 = pointSelect bit doubled0 added' 's/let next0 = pointSelect bit doubled0 added/let next0 = if bit == 0 then doubled0 else added/'
expect_source_red 'M02 bit-select-to-secret-if'

apply_mutation 'M03' "$WORK/pds/lib/secp256k1.mdk" 'let byte = U8.toInt bytes[i / 8]' 's/let byte = U8.toInt bytes\[i \/ 8\]/let byte = U8.toInt bytes[bit]/'
expect_source_red 'M03 secret-derived byte index'

apply_mutation 'M04' "$WORK/pds/lib/secp256k1.mdk" 'let afterOpposite = pointSelect opposite afterEqual pointInfinity' 's/let afterOpposite = pointSelect opposite afterEqual pointInfinity/let afterOpposite = afterEqual/'
expect_source_red 'M04 omitted exceptional opposite selection'

apply_mutation 'M05' "$WORK/pds/lib/field.mdk" 'feZeroBit a =' 's/feZeroBit a =\n/feZeroBit a = hashBool (feEqual a feZero)\n\nfeZeroBitRetired a =\n/'
expect_source_red 'M05 Bool/sentinel zero conversion'

apply_mutation 'M06' "$WORK/pds/lib/secp256k1.mdk" 'secretAffine (JPoint x y z) =' 's/secretAffine \(JPoint x y z\) =/secretAffine (JPoint x y z) = if feZeroBit z == 1 then AffinePoint feZero feZero else/'
expect_source_red 'M06 secret infinity early return'

apply_mutation 'M14' "$WORK/pds/lib/secp256k1.mdk" 'fieldSubCt a b = feAdd a (feNegateCt b)' 's/fieldSubCt a b = feAdd a \(feNegateCt b\)/fieldSubCt a b = feAdd a b/'
expect_source_red 'M14 omitted transitive constant-time wrapper'

# M15's byte-domain and per-element early-return mutants retired 2026-09-27
# with the byte scan they mutated: the ingress takes `Bytes`, so no element
# can be out of range. M15-length takes the public length test away instead.
apply_mutation 'M15-length' "$WORK/pds/lib/scalar.mdk" 'if B.length bs /= 32 then (0, scZero) else scSecretCandidate32 bs' 's/if B\.length bs \/= 32 then \(0, scZero\) else scSecretCandidate32 bs/scSecretCandidate32 bs/'
expect_source_red 'M15 public length test omission'

apply_mutation 'M15-range' "$WORK/pds/lib/scalar.mdk" '(bitAnd rangeBit nonzeroBit, candidate)' 's/\(bitAnd rangeBit nonzeroBit, candidate\)/(nonzeroBit, candidate)/'
expect_source_red 'M15 range aggregate omission'

apply_mutation 'M15-zero' "$WORK/pds/lib/scalar.mdk" '(bitAnd rangeBit nonzeroBit, candidate)' 's/\(bitAnd rangeBit nonzeroBit, candidate\)/(rangeBit, candidate)/'
expect_source_red 'M15 zero aggregate omission'

cmp "$ROOT/pds/lib/sign.mdk" "$WORK/pds/lib/sign.mdk"
cmp "$ROOT/pds/lib/secp256k1.mdk" "$WORK/pds/lib/secp256k1.mdk"
cmp "$ROOT/pds/lib/scalar.mdk" "$WORK/pds/lib/scalar.mdk"
cmp "$ROOT/pds/lib/field.mdk" "$WORK/pds/lib/field.mdk"
pass 'all mutations restored exact baseline bytes and task-owned crypto source is clean'

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 ct_build_ir build "$SOURCE" -o "$WORK/public-key" --keep-ir > "$WORK/build.log" 2>&1 || { cat "$WORK/build.log" >&2; fail 'native public-key closure probe builds'; }
BIN="$WORK/public-key"
IR="$WORK/public-key.ll"
"$BIN" > "$WORK/run.out" 2>&1 || { cat "$WORK/run.out" >&2; fail 'native composed public-key probe runs'; }
grep -F -q 'PASS public-key-closure' "$WORK/run.out" || fail 'native composed public-key output is generator G'
pass 'native secret ingress composes to the expected compressed public key'

for symbol in \
  mdk_lib_sign__secretKeyFromBytes mdk_lib_sign__publicKeyForSecret mdk_lib_sign__publicKeyCompressed \
  mdk_lib_scalar__scSecretCandidate mdk_lib_scalar__limbsOfBytes \
  mdk_lib_scalar__secretBelowNBit mdk_lib_scalar__secretNonzeroBit \
  mdk_lib_scalar__reduce256 mdk_lib_scalar__subNSelect__rw \
  mdk_lib_field__canonicalizeLimbs__rw mdk_lib_field__subPSelect__rw mdk_lib_field__feZeroBit \
  mdk_lib_field__feSelect \
  mdk_lib_secp256k1__scalarLadder mdk_lib_secp256k1__pointAddComplete \
  mdk_lib_secp256k1__pointDoubleComplete mdk_lib_secp256k1__secretAffine \
  mdk_lib_secp256k1__publicPointForSecret mdk_lib_secp256k1__pointCompressed
do require_emitted_symbol "$symbol"; done
pass 'emitted LLVM retains every named secret-path helper, including public wrappers'

# At -O2 the three public sign wrappers are intentionally inlined into main;
# their emitted bodies remain closed above.  These non-inlined leaves prove the
# final linked topology still contains ingress and the ladder's complete path.
# secretNonzeroBit, reduce256 and secretAffine are deliberately NOT in this
# list.  All three are branch-free or public-index-bounded, so -O2 is free to
# unroll and inline them, and whether it does is a cost-threshold artifact
# rather than anything about secrets.  Their shapes are pinned structurally in
# the IR below, where the definitions always exist.
# secretBelowNBit is not in it either: `medaka build` links the runtime
# through ThinLTO (#3374), which inlines it into scSecretCandidate. What is
# lost is only the claim that it is a distinct function in the linked binary.
# Its shape is still caught where the definition always exists: it is in the
# emitted-symbol list above, the closed source manifest pins scalar.mdk byte
# for byte, and M15 reds every aggregate omission. (scanSecretBytes, which
# stood beside it here, left the scalar on 2026-09-27 with the byte scan.)
#
# carryFoldRound left this list for reduceCarry when the limb arithmetic moved
# to U64 expressions over Int storage (#3427): the round is now small enough
# that the link inlines it into reduceCarry, which survives. Its shape is
# pinned where its definition always exists, by constant_time_reductions.sh.
# reduceCarry gave way to canonicalizeLimbs__rw when the field moved to 5x52
# limbs (N5), and that raw worker gave way to feMul once a top-level U64
# constant read in U64 code became its literal (N5): the worker is then small
# enough that the link inlines it, and subPSelect__rw with it, into every field
# producer. feMul is the producer the ladder calls most and survives as a
# symbol carrying the inlined round and subtract-and-select; both workers stay
# in the emitted-symbol list above, and constant_time_reductions.sh pins their
# shape where their definitions always exist.
#
# publicPointForSecret left this list when the scalar moved to 8 x 32 limbs
# (N5). Measured on the linked probe: -O2 now inlines it into the surviving
# sign wrapper publicKeyForSecret and keeps secretAffine as a symbol instead,
# the reverse of the split before; the ladder and both complete point
# operations it reaches still survive. It is in the emitted-symbol list above,
# where its definition always exists.
#
# pointAddComplete left this list 2026-09-27, when the ladder began reading
# its scalar bytes through the `Bytes` index. Measured on the linked probe:
# -O2 now inlines the complete addition into scalarLadder, its only caller in
# this program, where the base build kept it as a call. What is lost is only
# the claim that it is a distinct function in this binary: it is in the
# emitted-symbol list above, the emitted ladder below still calls it once per
# round, the linked ladder check below accepts it only inlined whole, and the
# signing gate still requires it as a linked symbol of both of its carriers.
for symbol in \
  mdk_lib_scalar__scSecretCandidate mdk_lib_field__feMul \
  mdk_lib_secp256k1__scalarLadder \
  mdk_lib_secp256k1__pointDoubleComplete mdk_lib_secp256k1__pointCompressed
do require_native_symbol "$symbol"; done
pass 'linked native code retains ingress and complete-ladder helper topology'
check_ir_closure

# The scalar's secret-ingress bits and its reduction are straight-line since
# the scalar moved to 8 x 32 limbs (N5): secretBelowNBit is one fixed borrow
# chain, secretNonzeroBit folds the limbs through zeroLimbsBit, reduce256 hands
# the eight limbs to subNSelect, and subNSelect subtracts n and blends every
# limb arithmetically. What must hold is that none of them branches at all and
# every limb is read at a literal index; whether the linker keeps them as calls
# is the optimizer's business, so the shape is pinned in the emitted IR, where
# the helpers always exist. subNSelect is audited as its raw worker, the body
# every caller reaches.
for helper in secretBelowNBit secretNonzeroBit zeroLimbsBit reduce256 subNSelect__rw; do
  extract_ir_function "$helper" "$IR" "$WORK/$helper.ll"
  [ "$(grep -c 'br i1' "$WORK/$helper.ll" || true)" -eq 0 ] || fail "$helper is straight-line"
  [ "$(grep -E -c 'call i64 @mdk_value_(eq|ne|lt|le|gt|ge)\(' "$WORK/$helper.ll" || true)" -eq 0 ] || fail "$helper makes no value comparisons"
  if grep -F 'call i64 @mdk_impl_Array_index(' "$WORK/$helper.ll" |
    grep -v -E -q 'call i64 @mdk_impl_Array_index\(i64 %[A-Za-z0-9_.]+, i64 -?[0-9]+\)'; then
    fail "$helper reads limbs only at literal indices"
  fi
done
[ "$(grep -E -c 'call i64 @mdk_impl_Array_index\(i64 %[A-Za-z0-9_.]+, i64 -?[0-9]+\)' "$WORK/zeroLimbsBit.ll" || true)" -eq 8 ] || fail 'secret nonzero fold reads each of the eight limbs at a literal index'
[ "$(grep -F -c 'call i64 @mdk_lib_scalar__zeroLimbsBit(' "$WORK/secretNonzeroBit.ll" || true)" -eq 1 ] || fail 'secret nonzero bit folds the limbs once'
[ "$(grep -F -c 'call i64 @mdk_lib_scalar__subNSelect__rw(' "$WORK/reduce256.ll" || true)" -eq 1 ] || fail 'secret reduction runs one subtract-and-select'
pass 'emitted secret ingress bits and reduction are straight-line over literal limb reads'

# secretAffine converts the ladder's Jacobian result to affine.  Its caller has
# already established the point is non-infinity, so the property is that it runs
# exactly one inversion over a straight line with no Z==0 branch -- not that the
# linker keeps it as a distinct symbol.  It moved out of the linked-survival list
# above when its emitted body lost the generic immediate-vs-boxed discriminant
# split (the JPoint roster is always boxed, so that arm was dead), which took the
# body under -O2's inline threshold at its sole call site, publicPointForSecret.
# (Since the 8 x 32 scalar the split is the reverse: secretAffine links and its
# caller inlines; see the list above.)  scalarLadder and both complete point
# operations stay linked, so the ladder topology the list exists to prove is
# unaffected.  Nothing emitter-side
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
# Six branches since Int traps (#3377): the round test, the two zero-divisor
# tests of `i / 8` and `i % 8` it already had, and three overflow checks
# (retagging `i / 8`, `7 - i % 8`, `i + 1`). branches_public proves all six
# test only the round counter; the key byte feeds only shiftRight (amount
# `7 - i % 8`, public) and bitAnd.
[ "$(grep -c 'br i1' "$WORK/scalarLadder.ll" || true)" -eq 6 ] || fail 'scalar ladder has exactly its fixed loop/control topology'
branches_public "$WORK/scalarLadder.ll" 3 || fail 'every scalar ladder branch tests only its public round counter'
# Liveness: with the round counter withheld from the public set, the same
# branches must read as non-public, or the audit could not see a secret one.
if branches_public "$WORK/scalarLadder.ll" 0; then
  fail 'branch-operand audit reds when the round counter is not declared public'
fi
[ "$(grep -F -c '__pointAddComplete' "$WORK/scalarLadder.ll" || true)" -eq 1 ] || fail 'scalar ladder computes one complete addition per round'
[ "$(grep -F -c '__pointDoubleComplete' "$WORK/scalarLadder.ll" || true)" -eq 2 ] || fail 'scalar ladder computes two complete doublings per round'
[ "$(grep -F -c '__pointSelect' "$WORK/scalarLadder.ll" || true)" -eq 2 ] || fail 'scalar ladder makes two arithmetic selections per round'
pass 'emitted scalar ladder preserves 256-round add/two-double/select topology'

ladder_symbol=$(nm "$BIN" | awk '$3 ~ /mdk_lib_secp256k1__scalarLadder$/ { print $3; exit }')
[ -n "$ladder_symbol" ] || fail 'linked scalar ladder symbol exists'
disassemble "$ladder_symbol" "$WORK/scalar-ladder.asm"
# The complete addition is either a call (one per round, beside the two
# doublings and two selections) or inlined whole, which the linked ladder
# shows as the addition's own doubling candidate beside the ladder's two
# (three doubling calls) and its five arithmetic selections beside the
# ladder's two (seven). An inlined addition that dropped a candidate or a
# selection matches neither shape.
ladder_adds=$(grep -F -c '__pointAddComplete' "$WORK/scalar-ladder.asm" || true)
ladder_doubles=$(grep -F -c '__pointDoubleComplete' "$WORK/scalar-ladder.asm" || true)
ladder_selects=$(grep -F -c '__pointSelect' "$WORK/scalar-ladder.asm" || true)
if [ "$ladder_adds" -eq 1 ]; then
  [ "$ladder_doubles" -eq 2 ] || fail 'linked scalar ladder retains both complete doubling calls'
elif [ "$ladder_adds" -eq 0 ]; then
  [ "$ladder_doubles" -eq 3 ] && [ "$ladder_selects" -eq 7 ] ||
    fail "linked scalar ladder inlines the whole complete addition (doublings=$ladder_doubles selections=$ladder_selects)"
else
  fail "linked scalar ladder makes one complete addition per round (got $ladder_adds)"
fi
pass 'linked native ladder retains complete candidate topology'

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
  MEDAKA_STRICT=1 ct_build_ir build "$src" -o "$bin" --keep-ir > "$WORK/bit-witness-build.log" 2>&1 || {
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
[ "$checked" -ge 22 ] || fail "assertion floor (expected at least 22, got $checked)"
printf 'PASS: native public-key constant-time closure — %s assertions\n' "$checked"
