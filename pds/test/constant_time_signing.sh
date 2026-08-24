#!/bin/sh
# Native structural closure and transactional contract controls for #1700
# step 3. This is a source/IR/link audit, not a timing benchmark or Wasm claim.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
SOURCE="$ROOT/pds/test/constant_time_signing_main.mdk"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-ct-signing.XXXXXX")
cleanup() {
  if [ "${KEEP_WORK:-0}" = 1 ]; then printf 'kept work directory: %s\n' "$WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT HUP INT TERM

checked=0
pass() { checked=$((checked + 1)); printf 'ok %s - %s\n' "$checked" "$1"; }
fail() { printf 'not ok %s - %s\n' "$((checked + 1))" "$1" >&2; exit 1; }
blob_hash() { cksum "$1" | awk '{print $1 " " $2}'; }

write_source_manifest() {
  tree=$1
  for rel in \
    pds/lib/field.mdk \
    pds/lib/scalar.mdk \
    pds/lib/sha256.mdk \
    pds/lib/hmac_sha256.mdk \
    pds/lib/secp256k1.mdk \
    pds/test/constant_time_signing_main.mdk
  do
    printf '%s  %s\n' "$(blob_hash "$tree/$rel")" "$rel"
  done
}

expected_source_manifest() {
  cat <<'EOF'
2995963130 26246  pds/lib/field.mdk
2702220718 31363  pds/lib/scalar.mdk
3537888636 12958  pds/lib/sha256.mdk
2659055724 1983  pds/lib/hmac_sha256.mdk
2739052739 23936  pds/lib/secp256k1.mdk
2929554113 2639  pds/test/constant_time_signing_main.mdk
EOF
}

source_closure_ok() {
  tree=$1
  write_source_manifest "$tree" > "$WORK/source.actual"
  expected_source_manifest > "$WORK/source.expected"
  cmp "$WORK/source.expected" "$WORK/source.actual" >/dev/null || return 1
  secp="$tree/pds/lib/secp256k1.mdk"
  hmac="$tree/pds/lib/hmac_sha256.mdk"
  sha="$tree/pds/lib/sha256.mdk"
  grep -F -q 'let candidate1Bytes = hmacSha256FixedKey rejectionKey rejectionValue' "$secp" || return 1
  grep -F -q 'let signed0 = signCandidate secret digest candidate0' "$secp" || return 1
  grep -F -q 'let signed1 = signCandidate secret digest candidate1' "$secp" || return 1
  grep -F -q 'let safeNonce = scSelect (1 - nonceValidBit) nonce scOne' "$secp" || return 1
  grep -F -q 'let lowS = scSelect (scHighBit rawS) rawS (scNegateCt rawS)' "$secp" || return 1
  grep -F -q 'if scIsZero r || scIsZero s || scIsHigh s then False' "$secp" || return 1
  grep -F -q 'let out = arrayMake 64 0' "$secp" || return 1
  grep -F -q 'let signed1 = signCandidate secret digest (injectedCandidate bytes1 valid1)' "$secp" || return 1
  [ "$(grep -F -c 'sha256FixedBytes (joined (keyPad key 0x36) message)' "$hmac" || true)" -eq 1 ] || return 1
  [ "$(grep -F -c 'sha256FixedBytes outerInput' "$hmac" || true)" -eq 1 ] || return 1
  grep -F -q 'sha256FixedBytes msg = sha256AssumeByteDomain msg' "$sha" || return 1
  return 0
}

restore_source_tree() {
  for rel in \
    pds/lib/field.mdk \
    pds/lib/scalar.mdk \
    pds/lib/sha256.mdk \
    pds/lib/hmac_sha256.mdk \
    pds/lib/secp256k1.mdk \
    pds/test/constant_time_signing_main.mdk
  do
    cp "$ROOT/$rel" "$WORK/$rel"
    cmp "$ROOT/$rel" "$WORK/$rel" >/dev/null
  done
  source_closure_ok "$WORK" || fail 'restored signing source tree matches its exact manifest'
}

apply_mutation() {
  id=$1 file=$2 anchor=$3 program=$4
  matches=$(grep -F -c "$anchor" "$file" || true)
  [ "$matches" -eq 1 ] || fail "$id mutation anchor is unique (got $matches)"
  before=$(blob_hash "$file")
  perl -0pi -e "$program" "$file"
  after=$(blob_hash "$file")
  [ "$before" != "$after" ] || fail "$id mutation changed its target blob"
}

expect_source_red() {
  id=$1
  if source_closure_ok "$WORK"; then fail "$id unexpectedly green"; fi
  pass "$id is rejected by the closed source audit"
  restore_source_tree
}

expect_corpus_red() {
  id=$1
  if python3 "$WORK/pds/tools/signing_corpus_check.py" "$WORK" > "$WORK/corpus-mutation.out" 2>&1; then
    fail "$id unexpectedly green"
  fi
  pass "$id is rejected by the existing signing authority gate"
}

extract_ir_function() {
  symbol=$1 input=$2 output=$3
  awk -v symbol="$symbol" '$0 ~ ("^define i64 @" symbol "\\(") { inside = 1 } inside { print } inside && /^}/ { exit }' "$input" > "$output"
  [ -s "$output" ] || return 1
}

is_ir_definition() {
  symbol=$1
  grep -F -q "define i64 @$symbol(" "$IR"
}

collect_full_closure() {
  root=$1
  printf '%s\n' "$root" > "$WORK/closure.current"
  while :; do
    cp "$WORK/closure.current" "$WORK/closure.next"
    while IFS= read -r symbol; do
      extract_ir_function "$symbol" "$IR" "$WORK/function.ll" || fail "emitted closure helper $symbol exists"
      sed -n 's/.*call i64 @\(mdk_[^ (]*\).*/\1/p' "$WORK/function.ll" >> "$WORK/closure.calls"
    done < "$WORK/closure.current"
    if [ -f "$WORK/closure.calls" ]; then
      while IFS= read -r callee; do
        if is_ir_definition "$callee"; then printf '%s\n' "$callee" >> "$WORK/closure.next"; fi
      done < "$WORK/closure.calls"
    fi
    LC_ALL=C sort -u "$WORK/closure.next" > "$WORK/closure.sorted"
    if cmp "$WORK/closure.current" "$WORK/closure.sorted" >/dev/null; then break; fi
    cp "$WORK/closure.sorted" "$WORK/closure.current"
    rm -f "$WORK/closure.calls"
  done
  cp "$WORK/closure.current" "$WORK/full-closure.lst"
}

write_control_manifest() {
  while IFS= read -r symbol; do
    extract_ir_function "$symbol" "$IR" "$WORK/function.ll" || exit 1
    branches=$(grep -c 'br i1' "$WORK/function.ll" || true)
    comparisons=$(grep -E -c 'call i64 @mdk_value_(eq|ne|lt|le|gt|ge)\(' "$WORK/function.ll" || true)
    indices=$(grep -F -c 'call i64 @mdk_impl_Array_index(' "$WORK/function.ll" || true)
    sets=$(grep -F -c 'call i64 @mdk_array__set(' "$WORK/function.ll" || true)
    makes=$(grep -F -c 'call i64 @mdk_array_make(' "$WORK/function.ll" || true)
    copies=$(grep -F -c 'call i64 @mdk_array_copy(' "$WORK/function.ll" || true)
    total=$(grep -E -c 'call i64 @' "$WORK/function.ll" || true)
    printf '%s %s %s %s %s %s %s %s\n' "$symbol" "$branches" "$comparisons" "$indices" "$sets" "$makes" "$copies" "$total"
  done < "$WORK/full-closure.lst"
}

require_native_symbol() {
  symbol=$1
  nm "$BIN" | awk -v wanted="$symbol" '{ name=$3; sub(/^_/, "", name); if (name == wanted) found=1 } END { exit !found }' || fail "linked native closure contains $symbol"
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
source_closure_ok "$ROOT" || fail 'baseline signing source matches the exact closure manifest'
pass 'source closure includes field/scalar, SHA/HMAC, RFC 6979, both signing candidates, compact output, and carrier'

# Contract mutations 7--14 and 16. Mutation 15 remains independently owned by
# constant_time_public_key.sh's parser aggregate controls.
apply_mutation M07 "$WORK/pds/lib/secp256k1.mdk" \
  'let candidate1Bytes = hmacSha256FixedKey rejectionKey rejectionValue' \
  's/let candidate1Bytes = hmacSha256FixedKey rejectionKey rejectionValue/let candidate1Bytes = candidate0Bytes/'
expect_source_red 'M07 two RFC candidates reduced to one'

apply_mutation M08 "$WORK/pds/lib/secp256k1.mdk" \
  'rfc6979RejectState key value =' \
  's/rfc6979RejectState key value =\n  let rejectionKey = hmacSha256FixedKey key \(rfc6979Message33 value\)\n  let rejectionValue = hmacSha256FixedKey rejectionKey value\n  Rfc6979State rejectionKey rejectionValue/rfc6979RejectState key value = Rfc6979State key value/'
expect_source_red 'M08 candidate rejection changed to an early return'

apply_mutation M08-zero "$WORK/pds/lib/secp256k1.mdk" \
  'let safeNonce = scSelect (1 - nonceValidBit) nonce scOne' \
  's/let safeNonce = scSelect \(1 - nonceValidBit\) nonce scOne/let safeNonce = if nonceValidBit == 1 then nonce else scOne/'
expect_source_red 'M08-zero invalid nonce placeholder changed to a secret branch'

apply_mutation M09 "$WORK/pds/lib/secp256k1.mdk" \
  'let lowS = scSelect (scHighBit rawS) rawS (scNegateCt rawS)' \
  's/let lowS = scSelect \(scHighBit rawS\) rawS \(scNegateCt rawS\)/let lowS = if scIsHigh rawS then scNegateCt rawS else rawS/'
expect_source_red 'M09 arithmetic low-S selection changed to a branch'

apply_mutation M10 "$WORK/pds/lib/secp256k1.mdk" \
  'if scIsZero r || scIsZero s || scIsHigh s then False' \
  's/if scIsZero r \|\| scIsZero s \|\| scIsHigh s then False/if scIsZero r || scIsZero s then False/'
expect_source_red 'M10 verifier high-S boundary disabled'

apply_mutation M11 "$WORK/pds/lib/secp256k1.mdk" \
  'let out = arrayMake 64 0' \
  's/let out = arrayMake 64 0/let out = arrayMake 65 0/'
expect_source_red 'M11 compact output fixed width drifted'

cp "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt" "$WORK/wycheproof.baseline"
sed '1d' "$WORK/wycheproof.baseline" > "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt"
expect_corpus_red 'M12-delete Wycheproof row deletion'
cp "$WORK/wycheproof.baseline" "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt"
perl -0pi -e 's/ high reject\n/ high accept\n/' "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt"
expect_corpus_red 'M12-flip Wycheproof expectation flip'
cp "$ROOT/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt" "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt"
cmp "$ROOT/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt" "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt" >/dev/null

cp "$WORK/pds/tools/gen_signing_corpus.sh" "$WORK/generator.baseline"
apply_mutation M13-libsecp "$WORK/pds/tools/gen_signing_corpus.sh" \
  '"$WORK/libsecp-sign" "$HERE/signing_inputs.txt" > "$WORK/libsecp.out"' \
  's/"\$WORK\/libsecp-sign" "\$HERE\/signing_inputs\.txt" > "\$WORK\/libsecp\.out"/: > "\$WORK\/libsecp.out"/'
expect_corpus_red 'M13-libsecp first signing oracle disabled'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-k256 "$WORK/pds/tools/gen_signing_corpus.sh" \
  'cargo run --quiet --locked --manifest-path "$WORK/rust/Cargo.toml" -- "$HERE/signing_inputs.txt" > "$WORK/k256.out"' \
  's/cargo run --quiet --locked --manifest-path "\$WORK\/rust\/Cargo\.toml" -- "\$HERE\/signing_inputs\.txt" > "\$WORK\/k256\.out"/: > "\$WORK\/k256.out"/'
expect_corpus_red 'M13-k256 second signing oracle disabled'
cp "$ROOT/pds/tools/gen_signing_corpus.sh" "$WORK/pds/tools/gen_signing_corpus.sh"
cmp "$ROOT/pds/tools/gen_signing_corpus.sh" "$WORK/pds/tools/gen_signing_corpus.sh" >/dev/null

write_source_manifest "$ROOT" > "$WORK/manifest.baseline"
sed '/pds\/lib\/hmac_sha256.mdk/d' "$WORK/manifest.baseline" > "$WORK/manifest.mutated"
if cmp "$WORK/manifest.mutated" "$WORK/source.expected" >/dev/null; then fail 'M14 closure omission unexpectedly green'; fi
pass 'M14 transitive HMAC wrapper omission is rejected by the exact source manifest'
cmp "$WORK/manifest.baseline" "$WORK/source.expected" >/dev/null || fail 'M14 source manifest restores byte-exactly'

apply_mutation M16 "$WORK/pds/lib/secp256k1.mdk" \
  'let signed1 = signCandidate secret digest (injectedCandidate bytes1 valid1)' \
  's/let signed1 = signCandidate secret digest \(injectedCandidate bytes1 valid1\)/let signed1 = signed0/'
expect_source_red 'M16 candidate-1 and exhaustion signing seam disconnected'

cmp "$ROOT/pds/lib/secp256k1.mdk" "$WORK/pds/lib/secp256k1.mdk" >/dev/null
cmp "$ROOT/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt" "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt" >/dev/null
cmp "$ROOT/pds/tools/gen_signing_corpus.sh" "$WORK/pds/tools/gen_signing_corpus.sh" >/dev/null
pass 'all contract mutations restored task-owned blobs byte-exactly'

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$SOURCE" -o "$WORK/signing" --keep-ir > "$WORK/build.log" 2>&1 || {
  cat "$WORK/build.log" >&2
  fail 'native signing closure probe builds'
}
BIN="$WORK/signing"
IR="$WORK/signing.ll"
"$BIN" > "$WORK/run.out" 2>&1 || { cat "$WORK/run.out" >&2; fail 'native signing closure carrier runs'; }
[ "$(tail -1 "$WORK/run.out")" = 'PASS signing-value-carrier' ] || fail 'native signing closure carrier returns expected signature and witnesses'
pass 'native signing carrier returns the exact signature plus candidate-1/exhaustion and public rejection witnesses'

collect_full_closure mdk_lib_secp256k1__ecdsaSignDigestForTest
closure_grade=$(cksum "$WORK/full-closure.lst" | awk '{print $1 " " $2}')
[ "$closure_grade" = '22155719 4885' ] || fail "emitted transitive closure drifted ($closure_grade)"
for prefix in field scalar sha256 hmac_sha256 secp256k1; do
  grep -F -q "mdk_lib_${prefix}__" "$WORK/full-closure.lst" || fail "emitted closure reaches $prefix"
done
if grep -F -q 'mdk_lib_sha256__byteDomainOk' "$WORK/full-closure.lst"; then
  fail 'signing HMAC closure re-entered the secret-derived public byte-domain scan'
fi
pass "emitted LLVM closes every transitive helper from the signing carrier ($(wc -l < "$WORK/full-closure.lst") definitions)"

write_control_manifest > "$WORK/control.manifest"
control_grade=$(cksum "$WORK/control.manifest" | awk '{print $1 " " $2}')
[ "$control_grade" = '3630957456 7320' ] || fail "emitted control/index/allocation manifest drifted ($control_grade)"
pass 'emitted helper bodies retain the audited branch/index/allocation shape; only fixed public controls remain'

for symbol in \
  mdk_lib_secp256k1__ecdsaSignDigestForTest \
  mdk_lib_secp256k1__ecdsaSignFixed \
  mdk_lib_secp256k1__signCandidate \
  mdk_lib_secp256k1__selectSigningCandidates \
  mdk_lib_secp256k1__rfc6979NonceSchedule \
  mdk_lib_hmac_sha256__hmacSha256FixedKey \
  mdk_lib_sha256__sha256FixedBytes \
  mdk_lib_sha256__sha256AssumeByteDomain \
  mdk_lib_secp256k1__scalarLadder \
  mdk_lib_secp256k1__pointAddComplete \
  mdk_lib_scalar__scInverse \
  mdk_lib_scalar__scSelect \
  mdk_lib_scalar__scHighBit \
  mdk_lib_scalar__scNegateCt
do
  grep -F -q "$symbol" "$WORK/full-closure.lst" || fail "emitted closure manifest contains $symbol"
done
pass 'emitted closure contains RFC/HMAC/SHA, both complete point paths, inverse, arithmetic validity/low-S/first-valid, and compact carrier'

# Clang may inline wrappers, so require the audited non-inlined leaves rather
# than pretending every emitted definition survives as a symbol.
for symbol in \
  mdk_lib_secp256k1__signCandidate \
  mdk_lib_secp256k1__rfc6979NonceSchedule \
  mdk_lib_hmac_sha256__hmacSha256FixedKey \
  mdk_lib_sha256__compressRounds \
  mdk_lib_secp256k1__scalarLadder \
  mdk_lib_secp256k1__pointAddComplete \
  mdk_lib_secp256k1__pointDoubleComplete \
  mdk_lib_scalar__scInverse \
  mdk_lib_scalar__scSelect \
  mdk_lib_scalar__scNegateCt
do require_native_symbol "$symbol"; done
pass 'linked native code retains the audited HMAC/SHA, two-signature, point, inverse, and arithmetic-selection topology'

for helper in mdk_bit_and mdk_bit_or mdk_bit_xor mdk_bit_not mdk_shift_left mdk_shift_right; do
  require_native_symbol "$helper"
  disassemble "$helper" "$WORK/$helper.asm"
  jumps=$(conditional_jumps "$WORK/$helper.asm") || fail "supported target for $helper disassembly"
  [ "$jumps" -eq 0 ] || fail "runtime bit helper $helper has conditional jumps (got $jumps)"
done
pass 'all six linked runtime bit helpers exist and have no conditional jumps'

printf 'receipt: target=%s %s\n' "$(uname -s)" "$(uname -m)"
printf 'receipt: compiler=%s\n' "$(clang --version | sed -n '1p')"
[ "$checked" -ge 20 ] || fail "assertion floor (expected at least 20, got $checked)"
printf 'PASS: native signing constant-time closure — %s assertions\n' "$checked"
