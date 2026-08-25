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

write_claimed_source_files() {
  for rel in \
    pds/lib/field.mdk \
    pds/lib/scalar.mdk \
    pds/lib/sha256.mdk \
    pds/lib/hmac_sha256.mdk \
    pds/lib/secp256k1.mdk \
    pds/test/constant_time_signing_main.mdk
  do
    printf '%s\n' "$rel"
  done
}

write_source_manifest() {
  tree=$1 claimed=$2
  while IFS= read -r rel; do
    printf '%s  %s\n' "$(blob_hash "$tree/$rel")" "$rel"
  done < "$claimed"
}

expected_source_manifest() {
  cat <<'EOF'
2995963130 26246  pds/lib/field.mdk
344284241 31757  pds/lib/scalar.mdk
3537888636 12958  pds/lib/sha256.mdk
2659055724 1983  pds/lib/hmac_sha256.mdk
3222566514 23967  pds/lib/secp256k1.mdk
1507350302 4544  pds/test/constant_time_signing_main.mdk
EOF
}

derive_source_files() {
  tree=$1 output=$2
  printf '%s\n' pds/test/constant_time_signing_main.mdk > "$WORK/source-derived.current"
  while :; do
    cp "$WORK/source-derived.current" "$WORK/source-derived.next"
    while IFS= read -r rel; do
      sed -n 's/^import lib\.\([A-Za-z0-9_]*\).*/pds\/lib\/\1.mdk/p' "$tree/$rel" >> "$WORK/source-derived.next"
    done < "$WORK/source-derived.current"
    LC_ALL=C sort -u "$WORK/source-derived.next" > "$WORK/source-derived.sorted"
    if cmp "$WORK/source-derived.current" "$WORK/source-derived.sorted" >/dev/null; then break; fi
    cp "$WORK/source-derived.sorted" "$WORK/source-derived.current"
  done
  cp "$WORK/source-derived.current" "$output"
}

source_claim_matches_derived() {
  tree=$1 claimed=$2
  derive_source_files "$tree" "$WORK/source-derived.actual"
  LC_ALL=C sort -u "$claimed" > "$WORK/source-claimed.sorted"
  cmp "$WORK/source-claimed.sorted" "$WORK/source-derived.actual" >/dev/null
}

source_integrity_ok() {
  tree=$1 claimed=$2
  write_source_manifest "$tree" "$claimed" > "$WORK/source.actual"
  expected_source_manifest > "$WORK/source.expected"
  cmp "$WORK/source.expected" "$WORK/source.actual" >/dev/null || return 1
  source_claim_matches_derived "$tree" "$claimed" || return 1
}

source_routes_ok() {
  tree=$1
  secp="$tree/pds/lib/secp256k1.mdk"
  scalar="$tree/pds/lib/scalar.mdk"
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
  grep -F -q 'let r = scFromFixedBytesReduce (feToBytes x)' "$secp" || return 1
  grep -F -q 'scFromFixedBytesReduce bs = reduceWide (wideOfRaw (limbsOfBytes bs))' "$scalar" || return 1
  [ "$(grep -F -c 'sha256FixedBytes (joined (keyPad key 0x36) message)' "$hmac" || true)" -eq 1 ] || return 1
  [ "$(grep -F -c 'sha256FixedBytes outerInput' "$hmac" || true)" -eq 1 ] || return 1
  grep -F -q 'sha256FixedBytes msg = sha256AssumeByteDomain msg' "$sha" || return 1
  return 0
}

source_closure_ok() {
  tree=$1 claimed=$2
  source_integrity_ok "$tree" "$claimed" || return 1
  source_routes_ok "$tree"
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
  source_closure_ok "$WORK" "$WORK/source.claimed" || fail 'restored signing source tree matches its exact manifest and derived closure'
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

expect_route_red() {
  id=$1
  if source_routes_ok "$WORK"; then fail "$id unexpectedly green"; fi
  pass "$id is rejected by its route-specific source anchor"
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
  rm -f "$WORK/closure.calls" "$WORK/closure.current" "$WORK/closure.next" "$WORK/closure.sorted"
  printf '%s\n' "$root" > "$WORK/closure.current"
  while :; do
    cp "$WORK/closure.current" "$WORK/closure.next"
    rm -f "$WORK/closure.calls"
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
write_claimed_source_files > "$WORK/source.claimed"
source_closure_ok "$ROOT" "$WORK/source.claimed" || fail 'baseline signing source matches the exact manifest and independently derived closure'
pass 'source closure includes field/scalar, SHA/HMAC, RFC 6979, both signing candidates, compact output, and carrier'

printf '\n-- integrity-only comment drift\n' >> "$WORK/pds/lib/secp256k1.mdk"
if source_integrity_ok "$WORK" "$WORK/source.claimed"; then fail 'comment-only source drift unexpectedly preserves integrity'; fi
source_routes_ok "$WORK" || fail 'comment-only source drift changed a semantic route anchor'
pass 'comment-only checksum drift is integrity evidence, not route-mutation evidence'
restore_source_tree

# Contract mutations 7--14 and 16. Mutation 15 remains independently owned by
# constant_time_public_key.sh's parser aggregate controls.
apply_mutation M07 "$WORK/pds/lib/secp256k1.mdk" \
  'let candidate1Bytes = hmacSha256FixedKey rejectionKey rejectionValue' \
  's/let candidate1Bytes = hmacSha256FixedKey rejectionKey rejectionValue/let candidate1Bytes = candidate0Bytes/'
expect_route_red 'M07 two RFC candidates reduced to one'

apply_mutation M08 "$WORK/pds/lib/secp256k1.mdk" \
  'let signed1 = signCandidate secret digest (injectedCandidate bytes1 valid1)' \
  's/let signed1 = signCandidate secret digest \(injectedCandidate bytes1 valid1\)/let signed1 = if valid0 == 1 then signed0 else signCandidate secret digest (injectedCandidate bytes1 valid1)/'
expect_route_red 'M08 candidate validity changed to an early skip of complete candidate 1'

apply_mutation M08-zero "$WORK/pds/lib/secp256k1.mdk" \
  'let safeNonce = scSelect (1 - nonceValidBit) nonce scOne' \
  's/let safeNonce = scSelect \(1 - nonceValidBit\) nonce scOne/let safeNonce = if nonceValidBit == 1 then nonce else scOne/'
expect_route_red 'M08-zero invalid nonce placeholder changed to a secret branch'

apply_mutation M09 "$WORK/pds/lib/secp256k1.mdk" \
  'let lowS = scSelect (scHighBit rawS) rawS (scNegateCt rawS)' \
  's/let lowS = scSelect \(scHighBit rawS\) rawS \(scNegateCt rawS\)/let lowS = if scIsHigh rawS then scNegateCt rawS else rawS/'
expect_route_red 'M09 arithmetic low-S selection changed to a branch'

apply_mutation M10 "$WORK/pds/lib/secp256k1.mdk" \
  'if scIsZero r || scIsZero s || scIsHigh s then False' \
  's/if scIsZero r \|\| scIsZero s \|\| scIsHigh s then False/if scIsZero r || scIsZero s then False/'
expect_route_red 'M10 verifier high-S boundary disabled'

apply_mutation M11 "$WORK/pds/lib/secp256k1.mdk" \
  'let out = arrayMake 64 0' \
  's/let out = arrayMake 64 0/let out = arrayMake 65 0/'
expect_route_red 'M11 compact output fixed width drifted'

cp "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt" "$WORK/wycheproof.baseline"
sed '1d' "$WORK/wycheproof.baseline" > "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt"
expect_corpus_red 'M12-delete Wycheproof row deletion'
cp "$WORK/wycheproof.baseline" "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt"
perl -0pi -e 's/ high reject\n/ high accept\n/' "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt"
expect_corpus_red 'M12-flip Wycheproof expectation flip'
cp "$ROOT/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt" "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt"
cmp "$ROOT/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt" "$WORK/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt" >/dev/null

cp "$WORK/pds/tools/gen_signing_corpus.sh" "$WORK/generator.baseline"
apply_mutation M13-alias "$WORK/pds/tools/gen_signing_corpus.sh" \
  'K256_RUNNER="$WORK/k256-runner"' \
  's|K256_RUNNER="\$WORK/k256-runner"|K256_RUNNER="\$WORK/k256-runner"\n  K256_RUNNER="\$WORK/libsecp-sign" # alias the prepared k256 slot to libsecp|'
expect_corpus_red 'M13-alias real k256 runner directly rebound to libsecp with cargo anchor retained'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-copy "$WORK/pds/tools/gen_signing_corpus.sh" \
  'chmod +x "$WORK/libsecp-control-runner" "$WORK/k256-control-runner"' \
  's|chmod \+x "\$WORK/libsecp-control-runner" "\$WORK/k256-control-runner"|chmod +x "\$WORK/libsecp-control-runner" "\$WORK/k256-control-runner"\n  cp "\$WORK/libsecp-control-runner" "\$WORK/k256-control-runner" # same bytes, distinct path|'
expect_corpus_red 'M13-copy second runner replaced by a same-content copy at a distinct path'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-identity-omit "$WORK/pds/tools/gen_signing_corpus.sh" \
  'attest_oracle_runners "$libsecp_runner" "$k256_runner" "$receipt"' \
  's|attest_oracle_runners "\$libsecp_runner" "\$k256_runner" "\$receipt"|attest_oracle_runners "\$libsecp_runner" "\$k256_runner" "\$receipt"\n  : > "\$receipt" # omit runtime runner identity receipt|'
expect_corpus_red 'M13-identity-omit runtime runner identity receipt omitted'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-identity-forge "$WORK/pds/tools/gen_signing_corpus.sh" \
  '"$LIBSECP_RUNNER_PATH_SHA" "$LIBSECP_RUNNER_FILE_ID" "$LIBSECP_RUNNER_CONTENT_SHA" >> "$receipt"' \
  's|"\$LIBSECP_RUNNER_PATH_SHA" "\$LIBSECP_RUNNER_FILE_ID" "\$LIBSECP_RUNNER_CONTENT_SHA" >> "\$receipt"|"forged-\$LIBSECP_RUNNER_PATH_SHA" "\$LIBSECP_RUNNER_FILE_ID" "\$LIBSECP_RUNNER_CONTENT_SHA" >> "\$receipt"|'
expect_corpus_red 'M13-identity-forge runtime runner identity receipt forged'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-libsecp "$WORK/pds/tools/gen_signing_corpus.sh" \
  'ORACLE_WORK="$WORK" "$libsecp_runner" "$input" > "$libsecp_output"' \
  's/ORACLE_WORK="\$WORK" "\$libsecp_runner" "\$input" > "\$libsecp_output"/: > "\$libsecp_output" # disable common-path libsecp runner/'
expect_corpus_red 'M13-libsecp common-path first signing oracle disabled'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-k256 "$WORK/pds/tools/gen_signing_corpus.sh" \
  'ORACLE_WORK="$WORK" "$k256_runner" "$input" > "$k256_output"' \
  's/ORACLE_WORK="\$WORK" "\$k256_runner" "\$input" > "\$k256_output"/: > "\$k256_output" # disable common-path k256 runner/'
expect_corpus_red 'M13-k256 common-path second signing oracle disabled'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-early "$WORK/pds/tools/gen_signing_corpus.sh" \
  '# ORACLE_MODE_SETUP_COMPLETE' \
  's/# ORACLE_MODE_SETUP_COMPLETE/# ORACLE_MODE_SETUP_COMPLETE\nexit 0 # disable common execution while preserving real command text/'
expect_corpus_red 'M13-early post-setup exit with both real command strings retained'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-compare "$WORK/pds/tools/gen_signing_corpus.sh" \
  'compare_oracle_outputs "$libsecp_output" "$k256_output" "$receipt"' \
  's/compare_oracle_outputs "\$libsecp_output" "\$k256_output" "\$receipt"/: # skip common-path oracle comparison/'
expect_corpus_red 'M13-compare common-path output comparison skipped'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-stale "$WORK/pds/tools/gen_signing_corpus.sh" \
  'rm -f "$receipt" "$libsecp_output" "$k256_output"' \
  's/rm -f "\$receipt" "\$libsecp_output" "\$k256_output"/: # retain stale pre-existing oracle outputs/'
expect_corpus_red 'M13-stale pre-existing oracle outputs retained for reuse'
cp "$ROOT/pds/tools/gen_signing_corpus.sh" "$WORK/pds/tools/gen_signing_corpus.sh"
cmp "$ROOT/pds/tools/gen_signing_corpus.sh" "$WORK/pds/tools/gen_signing_corpus.sh" >/dev/null

cp "$WORK/source.claimed" "$WORK/manifest.baseline"
sed '/pds\/lib\/hmac_sha256.mdk/d' "$WORK/manifest.baseline" > "$WORK/manifest.mutated"
if source_claim_matches_derived "$ROOT" "$WORK/manifest.mutated"; then fail 'M14 closure omission unexpectedly green'; fi
pass 'M14 claimed HMAC wrapper omission is rejected by independently derived source closure'
cmp "$WORK/manifest.baseline" "$WORK/source.claimed" >/dev/null || fail 'M14 claimed source manifest restores byte-exactly'

apply_mutation M16 "$WORK/pds/lib/secp256k1.mdk" \
  'let signed1 = signCandidate secret digest (injectedCandidate bytes1 valid1)' \
  's/let signed1 = signCandidate secret digest \(injectedCandidate bytes1 valid1\)/let signed1 = signed0/'
expect_route_red 'M16 candidate-1 and exhaustion signing seam disconnected'

apply_mutation M-secret-reducer "$WORK/pds/lib/secp256k1.mdk" \
  'let r = scFromFixedBytesReduce (feToBytes x)' \
  's/let r = scFromFixedBytesReduce \(feToBytes x\)/let r = scFromBytesReduce (feToBytes x)/'
expect_route_red 'secret r conversion restored to the public branch-bearing reducer'

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
[ "$closure_grade" = '2499938860 4924' ] || fail "emitted transitive closure drifted ($closure_grade)"
for prefix in field scalar sha256 hmac_sha256 secp256k1; do
  grep -F -q "mdk_lib_${prefix}__" "$WORK/full-closure.lst" || fail "emitted closure reaches $prefix"
done
if grep -F -q 'mdk_lib_sha256__byteDomainOk' "$WORK/full-closure.lst"; then
  fail 'signing HMAC closure re-entered the secret-derived public byte-domain scan'
fi
pass "emitted LLVM closes every transitive helper from the signing carrier ($(wc -l < "$WORK/full-closure.lst") definitions)"

cp "$WORK/full-closure.lst" "$WORK/signing-full-closure.lst"
collect_full_closure mdk_lib_secp256k1__signCandidate
if grep -E -q 'mdk_lib_scalar__(byteArrayOk|byteRangeGo)' "$WORK/full-closure.lst"; then
  fail 'secret signCandidate closure reaches the public byte validator'
fi
grep -F -q 'mdk_lib_scalar__scFromFixedBytesReduce' "$WORK/full-closure.lst" || fail 'secret signCandidate closure contains the admitted-byte scalar reducer'
pass 'secret signCandidate LLVM closure excludes byteArrayOk/byteRangeGo and contains the admitted-byte reducer'
cp "$WORK/signing-full-closure.lst" "$WORK/full-closure.lst"

write_control_manifest > "$WORK/control.manifest"
control_grade=$(cksum "$WORK/control.manifest" | awk '{print $1 " " $2}')
[ "$control_grade" = '2875306919 7373' ] || fail "emitted control/index/allocation manifest drifted ($control_grade)"
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

disassemble mdk_lib_secp256k1__signCandidate "$WORK/signCandidate.asm"
if grep -E -q 'mdk_lib_scalar__(scFromBytesReduce|byteArrayOk|byteRangeGo)' "$WORK/signCandidate.asm"; then
  fail 'linked signCandidate path calls the public branch-bearing scalar reducer'
fi
pass 'linked signCandidate path excludes scFromBytesReduce/byteArrayOk/byteRangeGo'

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
