#!/bin/sh
# Native structural closure and transactional contract controls for #1700
# step 4. This is a source/IR/link audit plus a memcheck taint run over the
# linked -O2 binary (#3361); it is not a timing benchmark or Wasm claim.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
INTERNAL_SOURCE="$ROOT/pds/test/constant_time_signing_main.mdk"
PUBLIC_SOURCE="$ROOT/pds/test/constant_time_signing_public_main.mdk"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-ct-signing.XXXXXX")
cleanup() {
  if [ "${KEEP_WORK:-0}" = 1 ]; then printf 'kept work directory: %s\n' "$WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT HUP INT TERM

checked=0
pass() { checked=$((checked + 1)); printf 'ok %s - %s\n' "$checked" "$1"; }
fail() { printf 'not ok %s - %s\n' "$((checked + 1))" "$1" >&2; exit 1; }
blob_hash() { cksum "$1" | awk '{print $1 " " $2}'; }

write_internal_claimed_source_files() {
  for rel in \
    pds/lib/field.mdk \
    pds/lib/scalar.mdk \
    stdlib/crypto/sha256.mdk \
    stdlib/crypto/hmac.mdk \
    stdlib/u32.mdk \
    pds/lib/hmac_sha256.mdk \
    pds/lib/secp256k1.mdk \
    pds/test/constant_time_signing_main.mdk
  do
    printf '%s\n' "$rel"
  done
}

write_public_claimed_source_files() {
  for rel in \
    pds/lib/field.mdk \
    pds/lib/scalar.mdk \
    stdlib/crypto/sha256.mdk \
    stdlib/crypto/hmac.mdk \
    stdlib/u32.mdk \
    pds/lib/hmac_sha256.mdk \
    pds/lib/secp256k1.mdk \
    pds/lib/sign.mdk \
    pds/test/constant_time_signing_public_main.mdk
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

expected_internal_source_manifest() {
  cat <<'EOF'
2128618670 25697  pds/lib/field.mdk
75163897 32282  pds/lib/scalar.mdk
1010065562 13066  stdlib/crypto/sha256.mdk
2034797298 8367  stdlib/crypto/hmac.mdk
2973717346 9537  stdlib/u32.mdk
1390942859 1217  pds/lib/hmac_sha256.mdk
1691956410 24617  pds/lib/secp256k1.mdk
3267398383 4682  pds/test/constant_time_signing_main.mdk
EOF
}

expected_public_source_manifest() {
  cat <<'EOF'
2128618670 25697  pds/lib/field.mdk
75163897 32282  pds/lib/scalar.mdk
1010065562 13066  stdlib/crypto/sha256.mdk
2034797298 8367  stdlib/crypto/hmac.mdk
2973717346 9537  stdlib/u32.mdk
1390942859 1217  pds/lib/hmac_sha256.mdk
1691956410 24617  pds/lib/secp256k1.mdk
1576054259 4921  pds/lib/sign.mdk
2846312137 3153  pds/test/constant_time_signing_public_main.mdk
EOF
}

# The signing closure's SHA-256 and HMAC live in stdlib/crypto/, reached by
# `import crypto.sha256` / `import crypto.hmac` rather than `import lib.<mod>`,
# and SHA-256's word arithmetic is stdlib/u32.mdk, reached by `import u32`.
# Following only the `lib.` form would silently shrink the audited closure to
# the pds half, which is the one failure this whole function exists to
# prevent, so the second arm below follows those stdlib imports too. It is
# restricted to the stdlib modules whose code the signing path actually
# carries: a blanket `^import <anything>` arm would drag in `array`, `string`
# and every transitive leaf (u32.mdk's own u8/u16/bytes imports among them,
# none of which reach the emitted closure), and the manifest is a
# hand-maintained claim about the SIGNING source, not about the stdlib.
# Entries are paths under stdlib/ without the extension; the import form is
# the path with `/` spelled `.`.
SIGNING_STDLIB_MODULES='crypto/sha256 crypto/hmac u32'

derive_stdlib_imports() {
  file=$1
  for rel in $SIGNING_STDLIB_MODULES; do
    pattern=$(printf '%s' "$rel" | sed 's|/|\\.|g')
    if grep -E -q "^import ${pattern}(\.|\$| )" "$file"; then
      printf 'stdlib/%s.mdk\n' "$rel"
    fi
  done
}

derive_source_files() {
  tree=$1 source=$2 output=$3
  printf '%s\n' "$source" > "$WORK/source-derived.current"
  while :; do
    cp "$WORK/source-derived.current" "$WORK/source-derived.next"
    while IFS= read -r rel; do
      sed -n 's/^import lib\.\([A-Za-z0-9_]*\).*/pds\/lib\/\1.mdk/p' "$tree/$rel" >> "$WORK/source-derived.next"
      derive_stdlib_imports "$tree/$rel" >> "$WORK/source-derived.next"
    done < "$WORK/source-derived.current"
    LC_ALL=C sort -u "$WORK/source-derived.next" > "$WORK/source-derived.sorted"
    if cmp "$WORK/source-derived.current" "$WORK/source-derived.sorted" >/dev/null; then break; fi
    cp "$WORK/source-derived.sorted" "$WORK/source-derived.current"
  done
  cp "$WORK/source-derived.current" "$output"
}

source_claim_matches_derived() {
  tree=$1 claimed=$2 source=$3
  derive_source_files "$tree" "$source" "$WORK/source-derived.actual"
  LC_ALL=C sort -u "$claimed" > "$WORK/source-claimed.sorted"
  cmp "$WORK/source-claimed.sorted" "$WORK/source-derived.actual" >/dev/null
}

internal_source_integrity_ok() {
  tree=$1 claimed=$2
  write_source_manifest "$tree" "$claimed" > "$WORK/source.actual"
  expected_internal_source_manifest > "$WORK/source.expected"
  cmp "$WORK/source.expected" "$WORK/source.actual" >/dev/null || return 1
  source_claim_matches_derived "$tree" "$claimed" pds/test/constant_time_signing_main.mdk || return 1
}

public_source_integrity_ok() {
  tree=$1 claimed=$2
  write_source_manifest "$tree" "$claimed" > "$WORK/public-source.actual"
  expected_public_source_manifest > "$WORK/public-source.expected"
  cmp "$WORK/public-source.expected" "$WORK/public-source.actual" >/dev/null || return 1
  source_claim_matches_derived "$tree" "$claimed" pds/test/constant_time_signing_public_main.mdk || return 1
}

internal_source_routes_ok() {
  tree=$1
  secp="$tree/pds/lib/secp256k1.mdk"
  scalar="$tree/pds/lib/scalar.mdk"
  guard="$tree/pds/lib/hmac_sha256.mdk"
  hmac="$tree/stdlib/crypto/hmac.mdk"
  sha="$tree/stdlib/crypto/sha256.mdk"
  grep -F -q 'let candidate1Bytes = hmacSha256FixedKey rejectionKey rejectionValue' "$secp" || return 1
  grep -F -q 'let signed0 = signCandidate secret digest candidate0' "$secp" || return 1
  grep -F -q 'let signed1 = signCandidate secret digest candidate1' "$secp" || return 1
  grep -F -q 'let safeNonce = scSelect (1 - nonceValidBit) nonce scOne' "$secp" || return 1
  grep -F -q 'let lowS = scSelect (scHighBit rawS) rawS (scNegateCt rawS)' "$secp" || return 1
  tr -s '[:space:]' ' ' < "$secp" | grep -F -q 'if scIsZero r || scIsZero s || scIsHigh s then False' || return 1
  grep -F -q 'let out = arrayMake 64 0' "$secp" || return 1
  grep -F -q 'let signed1 = signCandidate secret digest (injectedCandidate bytes1 valid1)' "$secp" || return 1
  grep -F -q 'let r = scFromFixedBytesReduce (feToBytes x)' "$secp" || return 1
  grep -F -q 'scFromFixedBytesReduce bs = reduceWide (wideOfRaw (limbsOfBytes bs))' "$scalar" || return 1
  # The signing side takes the UNCHECKED SHA-256 entry at every step of the
  # HMAC schedule: normalization, inner hash and outer hash. Each anchor is
  # pinned once so a stray `sha256` (the byte-domain-checking entry) in any of
  # the three positions reds this instead of quietly putting a secret-derived
  # early exit in the signing closure.
  [ "$(grep -F -c 'if arrayLength key > blockBytes then sha256FixedBytes key else key' "$hmac" || true)" -eq 1 ] || return 1
  [ "$(grep -F -c 'let inner = sha256FixedBytes (concat [|keyPad normalized 0x36, message|])' "$hmac" || true)" -eq 1 ] || return 1
  [ "$(grep -F -c 'sha256FixedBytes (concat [|keyPad normalized 0x5c, inner|])' "$hmac" || true)" -eq 1 ] || return 1
  # The 32-byte guard is the whole of pds/lib/hmac_sha256.mdk: it must still
  # reject every other length, and it must delegate to the unchecked entry.
  grep -F -q 'if arrayLength key /= keyBytes then' "$guard" || return 1
  [ "$(grep -F -c 'hmacSha256FixedBytes key message' "$guard" || true)" -eq 1 ] || return 1
  grep -F -q 'sha256FixedBytes msg = sha256AssumeByteDomain msg' "$sha" || return 1
  return 0
}

internal_source_closure_ok() {
  tree=$1 claimed=$2
  internal_source_integrity_ok "$tree" "$claimed" || return 1
  internal_source_routes_ok "$tree"
}

public_source_routes_ok() {
  tree=$1
  sign="$tree/pds/lib/sign.mdk"
  driver="$tree/pds/test/constant_time_signing_public_main.mdk"
  [ "$(grep -c '^import ' "$driver" || true)" -eq 1 ] || return 1
  grep -F -q 'import lib.sign.{' "$driver" || return 1
  if grep -E -q '^import lib\.(scalar|secp256k1)' "$driver"; then return 1; fi
  if grep -F -q 'ForTest' "$driver"; then return 1; fi
  for wrapper in \
    secretKeyFromBytes publicKeyFromCompressed publicKeyCompressed publicKeyForSecret \
    signatureFromCompact signatureCompact signDigest verifyDigest
  do
    grep -F -q "$wrapper" "$driver" || return 1
  done
  grep -F -q 'publicKeyForSecret key = PublicKey (publicPointForSecret (secretScalar key))' "$sign" || return 1
  grep -F -q 'let (validBit, signature) = ecdsaSignDigest scalar digest' "$sign" || return 1
  if grep -F -q 'ecdsaSignDigestForTest' "$sign"; then return 1; fi
  return 0
}

public_source_closure_ok() {
  tree=$1 claimed=$2
  public_source_integrity_ok "$tree" "$claimed" || return 1
  public_source_routes_ok "$tree"
}

restore_source_tree() {
  for rel in \
    pds/lib/field.mdk \
    pds/lib/scalar.mdk \
    stdlib/crypto/sha256.mdk \
    stdlib/crypto/hmac.mdk \
    stdlib/u32.mdk \
    pds/lib/hmac_sha256.mdk \
    pds/lib/secp256k1.mdk \
    pds/test/constant_time_signing_main.mdk
  do
    cp "$ROOT/$rel" "$WORK/$rel"
    cmp "$ROOT/$rel" "$WORK/$rel" >/dev/null
  done
  internal_source_closure_ok "$WORK" "$WORK/internal-source.claimed" || fail 'restored signing source tree matches its exact manifest and derived closure'
}

restore_public_source_tree() {
  cp "$ROOT/pds/lib/sign.mdk" "$WORK/pds/lib/sign.mdk"
  cp "$ROOT/pds/test/constant_time_signing_public_main.mdk" "$WORK/pds/test/constant_time_signing_public_main.mdk"
  cmp "$ROOT/pds/lib/sign.mdk" "$WORK/pds/lib/sign.mdk" >/dev/null
  cmp "$ROOT/pds/test/constant_time_signing_public_main.mdk" "$WORK/pds/test/constant_time_signing_public_main.mdk" >/dev/null
  public_source_closure_ok "$WORK" "$WORK/public-source.claimed" || fail 'restored public signing source tree matches its exact manifest, routes, and derived closure'
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
  if internal_source_routes_ok "$WORK"; then fail "$id unexpectedly green"; fi
  pass "$id is rejected by its route-specific source anchor"
  restore_source_tree
}

expect_public_route_red() {
  id=$1
  if public_source_routes_ok "$WORK"; then fail "$id unexpectedly green"; fi
  pass "$id is rejected directly by the public-route audit"
  restore_public_source_tree
}

expect_corpus_red() {
  id=$1
  if python3 "$WORK/pds/tools/signing_corpus_check.py" "$WORK" > "$WORK/corpus-mutation.out" 2>&1; then
    fail "$id unexpectedly green"
  fi
  pass "$id is rejected by the existing signing authority gate"
}

expect_corpus_green() {
  id=$1
  if ! python3 "$WORK/pds/tools/signing_corpus_check.py" "$WORK" > "$WORK/corpus-mutation.out" 2>&1; then
    cat "$WORK/corpus-mutation.out" >&2
    fail "$id unexpectedly red"
  fi
  pass "$id leaves the bound cargo authority intact"
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
    sets=$(grep -F -c 'call i64 @mdk_array__setInPlace(' "$WORK/function.ll" || true)
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
# Three of the claimed signing sources live in stdlib/, and the scratch tree
# is what every source-shape control runs against, so it needs them too.
mkdir -p "$WORK/stdlib/crypto"
cp "$ROOT/stdlib/crypto/sha256.mdk" "$ROOT/stdlib/crypto/hmac.mdk" "$WORK/stdlib/crypto/"
cp "$ROOT/stdlib/u32.mdk" "$WORK/stdlib/"
write_internal_claimed_source_files > "$WORK/internal-source.claimed"
write_public_claimed_source_files > "$WORK/public-source.claimed"
internal_source_closure_ok "$ROOT" "$WORK/internal-source.claimed" || fail 'baseline internal signing source matches the exact manifest and independently derived closure'
public_source_closure_ok "$ROOT" "$WORK/public-source.claimed" || fail 'baseline public signing source matches the exact manifest, public-only route, and independently derived closure'
pass 'dual source claims separate internal injected evidence from the public field/scalar, SHA/HMAC, signing, key, and carrier closure'

printf '\n-- integrity-only comment drift\n' >> "$WORK/pds/lib/secp256k1.mdk"
if internal_source_integrity_ok "$WORK" "$WORK/internal-source.claimed"; then fail 'comment-only source drift unexpectedly preserves integrity'; fi
internal_source_routes_ok "$WORK" || fail 'comment-only source drift changed a semantic route anchor'
pass 'comment-only checksum drift is integrity evidence, not route-mutation evidence'
restore_source_tree

# Public-route controls are compile-coherent mutations of the deployment-shaped
# graph. Each must turn the direct public audit red and restore byte-exactly.
apply_mutation P01 "$WORK/pds/lib/sign.mdk" \
  'let (validBit, signature) = ecdsaSignDigest scalar digest' \
  's/let \(validBit, signature\) = ecdsaSignDigest scalar digest/let signature = match ecdsaSignatureFromCompact (arrayMake 64 1)\n        Ok fixed => fixed\n        Err message => panic message\n      let validBit = 1/'
expect_public_route_red 'P01 public signDigest replaced by fixed compact parsing'

apply_mutation P02 "$WORK/pds/lib/sign.mdk" \
  'publicKeyForSecret key = PublicKey (publicPointForSecret (secretScalar key))' \
  's/publicKeyForSecret key = PublicKey \(publicPointForSecret \(secretScalar key\)\)/publicKeyForSecret _ = match pointFromCompressed (arrayMake 33 0)\n  Ok point => PublicKey point\n  Err message => panic message/'
expect_public_route_red 'P02 public publicKeyForSecret replaced by fixed public-key parsing'

apply_mutation P03 "$WORK/pds/test/constant_time_signing_public_main.mdk" \
  'import lib.sign.{' \
  's/import lib\.sign\.\{/import lib.secp256k1.{pointFromUncompressedForTest}\nimport lib.sign.{/; s/main =/main =\n  let _ = pointFromUncompressedForTest generatorCompressed/'
expect_public_route_red 'P03 ForTest import/use injected into the public driver'

apply_mutation P04 "$WORK/pds/lib/sign.mdk" \
  '  ecdsaSignDigest,' \
  's/  ecdsaSignDigest,/  ecdsaSignDigestForTest,/; s/let \(validBit, signature\) = ecdsaSignDigest scalar digest/let (validBit, _, _, _, _, compact) = ecdsaSignDigestForTest scalar digest\n      let signature = match ecdsaSignatureFromCompact compact\n        Ok parsed => parsed\n        Err message => panic message/'
expect_public_route_red 'P04 production signing delegated through ecdsaSignDigestForTest'

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
  'else if scIsZero r || scIsZero s || scIsHigh s then' \
  's/else if scIsZero r \|\| scIsZero s \|\| scIsHigh s then/else if scIsZero r || scIsZero s then/'
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
apply_mutation M13-cargo-shim "$WORK/pds/tools/gen_signing_corpus.sh" \
  '# ORACLE_MODE_SETUP_COMPLETE' \
  's|# ORACLE_MODE_SETUP_COMPLETE|cat > "\$WORK/cargo" <<"EOF"\n#!/bin/sh\necho cargo-shim-executed >&2\nfor final_arg do :; done\nexec "\$ORACLE_WORK/libsecp-sign" "\$final_arg"\nEOF\nchmod +x "\$WORK/cargo"\nPATH="\$WORK:\$PATH"\nexport PATH\n# ORACLE_MODE_SETUP_COMPLETE|'
expect_corpus_green 'M13-cargo-shim task-local delegating cargo PATH shim'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-cargo-invocation-alias "$WORK/pds/tools/gen_signing_corpus.sh" \
  '# ORACLE_MODE_SETUP_COMPLETE' \
  's|# ORACLE_MODE_SETUP_COMPLETE|ln -s "\$WORK/control-cargo" "\$WORK/control-cargo-alias"\nCARGO_EXECUTABLE="\$WORK/control-cargo-alias"\n# ORACLE_MODE_SETUP_COMPLETE|'
expect_corpus_red 'M13-cargo-invocation-alias selected cargo path changed to a same-target symlink after setup'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-delegate "$WORK/pds/tools/gen_signing_corpus.sh" \
  '# ORACLE_MODE_SETUP_COMPLETE' \
  's|# ORACLE_MODE_SETUP_COMPLETE|cat > "\$WORK/k256-runner" <<"EOF"\n#!/bin/sh\nexec "\$ORACLE_WORK/libsecp-sign" "\$1"\nEOF\n# ORACLE_MODE_SETUP_COMPLETE|'
expect_corpus_red 'M13-delegate bound k256 wrapper rewritten after setup to delegate to libsecp'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-expected-omit "$WORK/pds/tools/gen_signing_corpus.sh" \
  'K256_WRAPPER_EXPECTED_SHA=d6688538deb92f1818904a6cc1b937a8fb167ecd80623263f029b7613e5b3554' \
  's/K256_WRAPPER_EXPECTED_SHA=d6688538deb92f1818904a6cc1b937a8fb167ecd80623263f029b7613e5b3554/K256_WRAPPER_EXPECTED_SHA= # omit expected implementation digest/'
expect_corpus_red 'M13-expected-omit fixed k256 implementation digest omitted'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-expected-forge "$WORK/pds/tools/gen_signing_corpus.sh" \
  'K256_WRAPPER_EXPECTED_SHA=d6688538deb92f1818904a6cc1b937a8fb167ecd80623263f029b7613e5b3554' \
  's/K256_WRAPPER_EXPECTED_SHA=d6688538deb92f1818904a6cc1b937a8fb167ecd80623263f029b7613e5b3554/K256_WRAPPER_EXPECTED_SHA=6708ecba7c620de643c573e90ff5cf2e6502342ffd118cc7553d5ea42a38d6dc/; s|# ORACLE_MODE_SETUP_COMPLETE|cat > "\$WORK/k256-runner" <<"EOF"\n#!/bin/sh\nexec "\$ORACLE_WORK/libsecp-sign" "\$1"\nEOF\n# ORACLE_MODE_SETUP_COMPLETE|'
expect_corpus_red 'M13-expected-forge delegating wrapper paired with a forged expected digest'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-alias "$WORK/pds/tools/gen_signing_corpus.sh" \
  'K256_RUNNER="$WORK/k256-runner"' \
  's|K256_RUNNER="\$WORK/k256-runner"|K256_RUNNER="\$WORK/k256-runner"\n  K256_RUNNER="\$WORK/libsecp-sign" # alias the prepared k256 slot to libsecp|'
expect_corpus_red 'M13-alias real k256 runner directly rebound to libsecp with cargo anchor retained'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-copy "$WORK/pds/tools/gen_signing_corpus.sh" \
  'chmod +x "$WORK/libsecp-control-runner" "$WORK/k256-control-runner" "$WORK/control-cargo"' \
  's|chmod \+x "\$WORK/libsecp-control-runner" "\$WORK/k256-control-runner" "\$WORK/control-cargo"|chmod +x "\$WORK/libsecp-control-runner" "\$WORK/k256-control-runner" "\$WORK/control-cargo"\n  cp "\$WORK/libsecp-control-runner" "\$WORK/k256-control-runner" # same bytes, distinct path|'
expect_corpus_red 'M13-copy second runner replaced by a same-content copy at a distinct path'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-identity-omit "$WORK/pds/tools/gen_signing_corpus.sh" \
  '"$cargo_expected_content_sha" "$receipt"' \
  's|"\$cargo_expected_content_sha" "\$receipt"|"\$cargo_expected_content_sha" "\$receipt"\n  : > "\$receipt" # omit runtime runner identity receipt|'
expect_corpus_red 'M13-identity-omit runtime runner identity receipt omitted'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-identity-forge "$WORK/pds/tools/gen_signing_corpus.sh" \
  '"$LIBSECP_RUNNER_EXPECTED_SHA" "$LIBSECP_RUNNER_CONTENT_SHA" >> "$receipt"' \
  's|"\$LIBSECP_RUNNER_EXPECTED_SHA" "\$LIBSECP_RUNNER_CONTENT_SHA" >> "\$receipt"|"forged-\$LIBSECP_RUNNER_EXPECTED_SHA" "\$LIBSECP_RUNNER_CONTENT_SHA" >> "\$receipt"|'
expect_corpus_red 'M13-identity-forge runtime runner identity receipt forged'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-libsecp "$WORK/pds/tools/gen_signing_corpus.sh" \
  'ORACLE_WORK="$WORK" "$libsecp_runner" "$input" > "$libsecp_output"' \
  's/ORACLE_WORK="\$WORK" "\$libsecp_runner" "\$input" > "\$libsecp_output"/: > "\$libsecp_output" # disable common-path libsecp runner/'
expect_corpus_red 'M13-libsecp common-path first signing oracle disabled'
cp "$WORK/generator.baseline" "$WORK/pds/tools/gen_signing_corpus.sh"
apply_mutation M13-k256 "$WORK/pds/tools/gen_signing_corpus.sh" \
  'ORACLE_CARGO="$CARGO_EXECUTABLE" ORACLE_WORK="$WORK" "$k256_runner" "$input" > "$k256_output"' \
  's/ORACLE_CARGO="\$CARGO_EXECUTABLE" ORACLE_WORK="\$WORK" "\$k256_runner" "\$input" > "\$k256_output"/: > "\$k256_output" # disable common-path k256 runner/'
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

cp "$WORK/internal-source.claimed" "$WORK/manifest.baseline"
sed '/pds\/lib\/hmac_sha256.mdk/d' "$WORK/manifest.baseline" > "$WORK/manifest.mutated"
if source_claim_matches_derived "$ROOT" "$WORK/manifest.mutated" pds/test/constant_time_signing_main.mdk; then fail 'M14 closure omission unexpectedly green'; fi
pass 'M14 claimed HMAC wrapper omission is rejected by independently derived source closure'
cmp "$WORK/manifest.baseline" "$WORK/internal-source.claimed" >/dev/null || fail 'M14 claimed source manifest restores byte-exactly'

# M15: the same control for the stdlib half of the claim. Without the crypto.*
# arm in derive_source_files the derived closure would stop at pds/lib, so
# dropping stdlib/crypto/sha256.mdk from the claim would go UNNOTICED -- which is the
# state this gate was in the moment SHA-256 moved out of pds/lib. Proving the
# omission reds is what makes the new arm load-bearing rather than decorative.
sed '/stdlib\/crypto\/sha256.mdk/d' "$WORK/manifest.baseline" > "$WORK/manifest.mutated"
if source_claim_matches_derived "$ROOT" "$WORK/manifest.mutated" pds/test/constant_time_signing_main.mdk; then fail 'M15 stdlib closure omission unexpectedly green'; fi
sed '/stdlib\/crypto\/hmac.mdk/d' "$WORK/manifest.baseline" > "$WORK/manifest.mutated"
if source_claim_matches_derived "$ROOT" "$WORK/manifest.mutated" pds/test/constant_time_signing_main.mdk; then fail 'M15 stdlib HMAC omission unexpectedly green'; fi
sed '/stdlib\/u32.mdk/d' "$WORK/manifest.baseline" > "$WORK/manifest.mutated"
if source_claim_matches_derived "$ROOT" "$WORK/manifest.mutated" pds/test/constant_time_signing_main.mdk; then fail 'M15 stdlib U32 omission unexpectedly green'; fi
pass 'M15 claimed stdlib SHA-256/HMAC/U32 omission is rejected by independently derived source closure'
cmp "$WORK/manifest.baseline" "$WORK/internal-source.claimed" >/dev/null || fail 'M15 claimed source manifest restores byte-exactly'

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

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$INTERNAL_SOURCE" -o "$WORK/signing-internal" --keep-ir > "$WORK/internal-build.log" 2>&1 || {
  cat "$WORK/internal-build.log" >&2
  fail 'native internal signing evidence probe builds'
}
BIN="$WORK/signing-internal"
IR="$WORK/signing-internal.ll"
"$BIN" > "$WORK/run.out" 2>&1 || { cat "$WORK/run.out" >&2; fail 'native signing closure carrier runs'; }
[ "$(tail -1 "$WORK/run.out")" = 'PASS signing-value-carrier' ] || fail 'native signing closure carrier returns expected signature and witnesses'
pass 'native internal carrier retains the exact signature plus candidate-1/exhaustion and raw rejection witnesses'

collect_full_closure mdk_lib_secp256k1__ecdsaSignDigestForTest
closure_grade=$(cksum "$WORK/full-closure.lst" | awk '{print $1 " " $2}')
# Re-derived when `sha256AssumeByteDomain` was parameterized into
# `sha256AssumeByteDomainFrom` (State/prior-byte-count) plus its zero-offset
# caller (S-hmac-midstate). Measured against the previous closure, symbol by
# symbol: `mdk_crypto_sha256__buildTail` is gone (folded into
# `mdk_crypto_sha256__buildTailWithTotal`, now called directly), and
# `mdk_crypto_sha256__sha256AssumeByteDomainFrom` is new; every other symbol,
# including `mdk_crypto_sha256__sha256AssumeByteDomain` itself, is unchanged.
# `mdk_crypto_sha256__sha256FoldKeyBlock` is NOT in this closure — the direct-call
# `hmacSha256FixedBytes` path this carrier reaches never calls it, only
# `hmacSha256Key`/`hmacSha256WithKey` do, and neither is on this route. 172
# definitions after, 171 before.
# Re-derived when SHA-256's words moved from masked `Int` to `U32`, measured
# symbol by symbol against the previous closure: `mdk_crypto_sha256__mask32`,
# `mdk_crypto_sha256__rotr32` and the `mdk_force_crypto_sha256__{h0Init,k}`
# thunks are gone; eleven `mdk_u32__` helpers entered (`bitAnd`, `bitOr`,
# `bitXor`, `bitNot`, `shiftLeft`, `shiftRight`, `rotateLeft`, `rotateRight`,
# `rotateAmount`, `truncate`, `toInt`), plus `mdk_impl_Int_display`, which only
# the shift helpers' negative-amount panic message calls. 180 definitions.
[ "$closure_grade" = '280489640 5172' ] || fail "emitted transitive closure drifted ($closure_grade)"
# Two of the modules live in stdlib/crypto/, which mangles as `crypto_` rather
# than `lib_`, and one is stdlib/u32.mdk, so the prefixes are spelled out
# rather than built from a module name.
for prefix in mdk_lib_field__ mdk_lib_scalar__ mdk_crypto_sha256__ mdk_crypto_hmac__ \
  mdk_u32__ mdk_lib_hmac_sha256__ mdk_lib_secp256k1__
do
  grep -F -q "$prefix" "$WORK/full-closure.lst" || fail "emitted closure reaches $prefix"
done
if grep -F -q 'mdk_crypto_sha256__byteDomainOk' "$WORK/full-closure.lst"; then
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
# Same closure change as above (S-hmac-midstate). Measured row-wise: the
# `mdk_crypto_sha256__buildTail` row is gone, `mdk_crypto_sha256__sha256AssumeByteDomainFrom`
# gains a row identical in shape to the one `mdk_crypto_sha256__sha256AssumeByteDomain`
# already carried (a straight-line fold, no branch), and every other row is
# unchanged; no branch anywhere in the closure tests a byte.
# Re-derived for the same `U32` move as the closure grade above, row by row.
# The SHA-256 rows keep their branch counts (compressRounds 2, compressBlock 1,
# extendSchedule 1, the rest 0) and lose calls, since `+` on a `U32` is inline;
# digestWord gains the one `toInt` call. The new rows' branches all test the
# shift or rotate amount, never the word: shiftLeft and shiftRight 3 each
# (amount below 0, amount 32 or more, the guard chain's closing `otherwise`),
# rotateAmount 2 (the constant 32 divisor's zero checks), rotateLeft 1
# (amount 0). Every SHA-256 call site passes a literal amount. The bit helpers,
# truncate and toInt have no branch, and Int_display has none either.
[ "$control_grade" = '3001358583 7705' ] || fail "emitted control/index/allocation manifest drifted ($control_grade)"
pass 'emitted helper bodies retain the audited branch/index/allocation shape; only fixed public controls remain'

for symbol in \
  mdk_lib_secp256k1__ecdsaSignDigestForTest \
  mdk_lib_secp256k1__ecdsaSignFixed \
  mdk_lib_secp256k1__signCandidate \
  mdk_lib_secp256k1__selectSigningCandidates \
  mdk_lib_secp256k1__rfc6979NonceSchedule \
  mdk_lib_hmac_sha256__hmacSha256FixedKey \
  mdk_crypto_sha256__sha256FixedBytes \
  mdk_crypto_sha256__sha256AssumeByteDomain \
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
# hmac_sha256.mdk's guard is a two-call delegation (length test, then the
# stdlib schedule) and clang inlines it away, so the leaf pinned here is the
# schedule itself, mdk_crypto_hmac__hmacSha256FixedBytes. The guard is still pinned
# by source text above and by the IR closure manifests, which read definitions
# rather than surviving link-time symbols.
#
# mdk_crypto_sha256__compressRounds and mdk_lib_scalar__scNegateCt stood in this list
# until `medaka build` linked the runtime through ThinLTO (#3374). That link
# inlines both into their callers, so neither survives as a symbol. What is
# lost is only the claim that each is a distinct function in the linked binary.
# Their constant-time shape is still caught where their definitions always
# exist: scNegateCt by the low-S route pin in internal_source_routes_ok (red
# under M09) and by the emitted closure manifest above; compressRounds by the
# exact control grade over the emitted closure, which counts its branches,
# comparisons and indexing. Its caller mdk_crypto_hmac__hmacSha256FixedBytes still
# survives below, so the HMAC/SHA schedule is still in the link.
for symbol in \
  mdk_lib_secp256k1__signCandidate \
  mdk_lib_secp256k1__rfc6979NonceSchedule \
  mdk_crypto_hmac__hmacSha256FixedBytes \
  mdk_lib_secp256k1__scalarLadder \
  mdk_lib_secp256k1__pointAddComplete \
  mdk_lib_secp256k1__pointDoubleComplete \
  mdk_lib_scalar__scInverse \
  mdk_lib_scalar__scSelect
do require_native_symbol "$symbol"; done
pass 'linked native code retains the audited HMAC/SHA, two-signature, point, inverse, and arithmetic-selection topology'

disassemble mdk_lib_secp256k1__signCandidate "$WORK/signCandidate.asm"
if grep -E -q 'mdk_lib_scalar__(scFromBytesReduce|byteArrayOk|byteRangeGo)' "$WORK/signCandidate.asm"; then
  fail 'linked signCandidate path calls the public branch-bearing scalar reducer'
fi
pass 'linked signCandidate path excludes scFromBytesReduce/byteArrayOk/byteRangeGo'

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

check_bit_witness 'bitXor (bitAnd a b) (bitOr (shiftRight a (bitAnd b 7)) (shiftLeft (bitNot b) 5))' \
  mdk_bit_and mdk_bit_or mdk_bit_xor mdk_bit_not mdk_shift_left mdk_shift_right

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$PUBLIC_SOURCE" -o "$WORK/signing-public" --keep-ir > "$WORK/public-build.log" 2>&1 || {
  cat "$WORK/public-build.log" >&2
  fail 'native public signing consumer builds'
}
BIN="$WORK/signing-public"
IR="$WORK/signing-public.ll"
"$BIN" > "$WORK/public-run.out" 2>&1 || { cat "$WORK/public-run.out" >&2; fail 'native public signing consumer runs'; }
[ "$(tail -1 "$WORK/public-run.out")" = 'PASS public-signing-consumer' ] || fail 'public signing consumer returns its distinct PASS'
pass 'public-only carrier exercises all eight APIs at compressed G, the RFC 6979 compact bytes, and self-verification'

for symbol in \
  mdk_lib_sign__secretKeyFromBytes \
  mdk_lib_sign__publicKeyFromCompressed \
  mdk_lib_sign__publicKeyCompressed \
  mdk_lib_sign__publicKeyForSecret \
  mdk_lib_sign__signatureFromCompact \
  mdk_lib_sign__signatureCompact \
  mdk_lib_sign__signDigest \
  mdk_lib_sign__verifyDigest
do
  grep -F -q "define i64 @$symbol(" "$IR" || fail "public driver IR defines wrapper $symbol"
done
pass 'public driver IR defines all eight consumer wrappers'

collect_full_closure mdk_lib_sign__signDigest
cp "$WORK/full-closure.lst" "$WORK/public-signing-closure.lst"
collect_full_closure mdk_lib_sign__publicKeyForSecret
cp "$WORK/full-closure.lst" "$WORK/public-key-closure.lst"
LC_ALL=C sort -u "$WORK/public-signing-closure.lst" "$WORK/public-key-closure.lst" > "$WORK/public-union-closure.lst"
cp "$WORK/public-union-closure.lst" "$WORK/full-closure.lst"

grep -F -x -q 'mdk_lib_sign__signDigest' "$WORK/full-closure.lst" || fail 'public union contains signDigest root'
grep -F -x -q 'mdk_lib_sign__publicKeyForSecret' "$WORK/full-closure.lst" || fail 'public union contains publicKeyForSecret root'
if grep -F -q 'ForTest' "$WORK/full-closure.lst"; then
  fail 'public consumer closure reaches a ForTest symbol'
fi
for prefix in mdk_lib_field__ mdk_lib_scalar__ mdk_crypto_sha256__ mdk_crypto_hmac__ \
  mdk_u32__ mdk_lib_hmac_sha256__ mdk_lib_secp256k1__ mdk_lib_sign__
do
  grep -F -q "$prefix" "$WORK/full-closure.lst" || fail "public union reaches $prefix"
done
for symbol in \
  mdk_lib_secp256k1__ecdsaSignFixed \
  mdk_lib_secp256k1__signCandidate \
  mdk_lib_secp256k1__selectSigningCandidates \
  mdk_lib_secp256k1__rfc6979NonceSchedule \
  mdk_lib_hmac_sha256__hmacSha256FixedKey \
  mdk_crypto_sha256__sha256FixedBytes \
  mdk_crypto_sha256__sha256AssumeByteDomain \
  mdk_lib_secp256k1__scalarLadder \
  mdk_lib_secp256k1__pointAddComplete \
  mdk_lib_secp256k1__pointDoubleComplete \
  mdk_lib_scalar__scInverse \
  mdk_lib_scalar__scSelect \
  mdk_lib_scalar__scHighBit \
  mdk_lib_scalar__scNegateCt
do
  grep -F -q "$symbol" "$WORK/full-closure.lst" || fail "public union manifest contains $symbol"
done
write_control_manifest > "$WORK/public-control.manifest"
public_closure_grade=$(cksum "$WORK/full-closure.lst" | awk '{print $1 " " $2}')
public_control_grade=$(cksum "$WORK/public-control.manifest" | awk '{print $1 " " $2}')
# Re-derived for SecretKey's at-rest Bytes representation, measured row by row
# against the previous 189-row union. Two definitions entered (189 -> 191):
# sign.secretScalar (1 branch, the public SecretKey tag; 2 calls, toArray and
# scFromFixedBytesReduce) and bytes.toArray (1 branch, the public Bytes tag;
# 1 call, the runtime byte-block copy). publicKeyForSecret went from 1 to 0
# branches and 1 to 2 calls, and signDigest from 5 to 4 branches and 5 to 6
# calls: each lost its SecretKey pattern's tag branch and gained the
# secretScalar call. No other row moved in any column.
# Re-derived again for the byteAt/wordAt indexing change (S-sha256-rounds),
# same shape as the internal-carrier grades above: `mdk_crypto_sha256__byteAt`'s row
# is gone (191 -> 190, inlined), `mdk_crypto_sha256__wordAt` moved to
# `0 0 1 0 0 0 1`, everything else unchanged.
# Re-derived again for the same `sha256AssumeByteDomain` parameterization as
# the internal-carrier grades above (S-hmac-midstate): `mdk_crypto_sha256__buildTail`'s
# row is gone, `mdk_crypto_sha256__sha256AssumeByteDomainFrom` gains a row shaped
# like `mdk_crypto_sha256__sha256AssumeByteDomain`'s own (straight-line, no branch),
# 190 -> 191. `mdk_crypto_sha256__sha256FoldKeyBlock` does not appear — this route
# never reaches `hmacSha256Key`/`hmacSha256WithKey`, only `hmacSha256FixedBytes`.
# Re-derived again for SHA-256's move to `U32`, the same row changes as the
# internal-carrier grades above and no others: four SHA-256 definitions leave,
# the eleven `mdk_u32__` helpers and `mdk_impl_Int_display` enter (191 -> 199),
# and every new branch tests a public shift or rotate amount.
if [ "$public_closure_grade" != '809436099 5707' ] || [ "$public_control_grade" != '3931792192 8508' ]; then
  fail "public union exact grades drifted (closure=$public_closure_grade control=$public_control_grade)"
fi
pass "public-root LLVM union excludes ForTest and retains the audited signing/key topology ($(wc -l < "$WORK/full-closure.lst") definitions)"

# Same inlined-guard reasoning as the internal native-symbol list above.
# The ThinLTO link (#3374) inlines compressRounds, scNegateCt and, in this
# consumer only, rfc6979NonceSchedule, so they left this list as they left the
# internal one. What is lost is only the claim that each is a distinct function
# in this linked binary. All three stay in the public union above, whose exact
# control grade pins their branches, comparisons and indexing; scNegateCt's
# low-S route is pinned in source (red under M09); and rfc6979NonceSchedule is
# still required as a linked symbol of the internal carrier.
for symbol in \
  mdk_lib_secp256k1__signCandidate \
  mdk_crypto_hmac__hmacSha256FixedBytes \
  mdk_lib_secp256k1__scalarLadder \
  mdk_lib_secp256k1__pointAddComplete \
  mdk_lib_secp256k1__pointDoubleComplete \
  mdk_lib_scalar__scInverse \
  mdk_lib_scalar__scSelect
do require_native_symbol "$symbol"; done
pass 'linked public consumer retains the audited HMAC/SHA, signing, point, inverse, and arithmetic-selection leaves'

# ── Memcheck taint over the linked -O2 binary (#3361) ─────────────────────
#
# The audits above read source, IR and disassembly. This arm runs the linked
# binary: a probe-only C shim marks the 32 key bytes undefined with a memcheck
# client request, hands them to Medaka through user FFI externs, and memcheck
# reports every conditional jump, and every address or syscall argument, that
# depends on them. The signing path must produce no such report at all.
#
# The probe drives the internal entry points (scSecretCandidate,
# publicPointForSecret/pointCompressed, ecdsaSignDigest,
# ecdsaSignatureCompact), not lib.sign. The two aggregate validity bits are
# declassified results, and the only branches on them are in lib.sign, which is
# pure and so cannot call a declassification hook. The probe takes those two
# branches itself, each on a ctDeclassify'd copy, and declassifies the public
# key and signature bytes before printing them. Those ctDeclassify calls are
# the whole of the licensed set: no PC inside the -O2 signing code is exempt.
#
# Scope: the collector is held off (GC_DONT_GC=1, asserted by the probe's own
# collection count), so this covers the Medaka code and the runtime helpers it
# calls, not Boehm's conservative marking. With collections running, marking
# branches on key-derived heap words. That is exaggerated under valgrind,
# whose collector heap sits near 2^26-2^27 where small key-derived integers
# can pass for pointers, against about 2^47 natively. It is still not
# eliminated, and is disclosed rather than measured here (#3361).
#
# The mutant control points the scalar reduction back at the checked carry
# pass (carryGo), whose top-limb panic guard is a branch on the secret carry.
# It must be reported, at a conditional jump that survived -O2 inside carryGo.
# The unmutated run must not mention either carry pass.

TAINT_PROBE="$WORK/pds/test/constant_time_taint_probe_main.mdk"
TAINT_KEYS='0 8 9'

taint_toolchain_ok() {
  command -v valgrind >/dev/null 2>&1 || return 1
  printf '#include <valgrind/memcheck.h>\n' > "$WORK/memcheck-header.c"
  clang -E "$WORK/memcheck-header.c" -o /dev/null > /dev/null 2>&1
}

if ! taint_toolchain_ok; then
  if [ -n "${CI:-}" ]; then fail 'valgrind and valgrind/memcheck.h are installed for the memcheck taint arm'; fi
  printf 'skip: valgrind (with valgrind/memcheck.h) not on PATH; the memcheck taint arm needs it\n' >&2
  exit 2
fi

write_taint_probe() {
  cat > "$TAINT_PROBE" <<'EOF'
import hex.{encode}
import lib.scalar.{scSecretCandidate}
import lib.secp256k1.{
  ecdsaSignDigest,
  ecdsaSignatureCompact,
  pointCompressed,
  publicPointForSecret,
}

extern ctTaintLoad : Int -> <FFI> Int
extern ctSecretByte : Int -> <FFI> Int
extern ctDeclassify : Int -> <FFI> Int
extern ctVbits : Int -> <FFI> Int
extern ctGcCount : Int -> <FFI> Int
extern ctLoadAddress : Int -> <FFI> Int

digestBytes : Array Int
digestBytes = arrayMake 32 0

declassifyAll : Array Int -> <FFI> Array Int
declassifyAll bytes =
  arrayMakeWith (arrayLength bytes) (i => ctDeclassify bytes[i])

probeKey : Int -> <IO, FFI> Unit
probeKey k =
  let _ = ctTaintLoad k
  let secretBytes = arrayMakeWith 32 ctSecretByte
  let (secretValid, scalar) = scSecretCandidate secretBytes
  if ctDeclassify secretValid /= 1 then
    println "key \{k} rejected"
  else
    let pub = pointCompressed (publicPointForSecret scalar)
    let pubPublic = declassifyAll pub
    let (validBit, signature) = ecdsaSignDigest scalar digestBytes
    let validVbits = ctVbits validBit
    if ctDeclassify validBit == 1 then
      let compact = ecdsaSignatureCompact signature
      let sigPublic = declassifyAll compact
      println
        "key \{k} vbits \{validVbits} \{ctVbits pub[5]} \{ctVbits compact[0]} pub \{encode pubPublic} sig \{encode sigPublic}"
    else
      println "key \{k} exhausted"

tagProbe : Unit -> <IO, FFI> Unit
tagProbe () =
  let _ = ctTaintLoad 1
  let heapBytes = arrayMakeWith 32 ctSecretByte
  println
    "tag \{ctVbits heapBytes[31]} \{ctVbits heapBytes[0]} \{ctVbits (heapBytes[30] + heapBytes[31])}"

main : <IO, FFI> Unit
main =
  let gc0 = ctGcCount 0
  let () = println "load \{ctLoadAddress 0}"
  let () = tagProbe ()
  let () = probeKey 0
  let () = probeKey 1
  let () = probeKey 2
  println "gc \{ctGcCount 0 - gc0}"
EOF
}

# The key rows come from the signing corpus inputs, in file order.
write_taint_shim() {
  awk -v wanted=" $TAINT_KEYS " '$1 == "key" && index(wanted, " " $2 " ") {
    printf "  {"
    for (i = 0; i < 32; i++) printf "%s0x%s", (i ? ", " : ""), substr($3, 2 * i + 1, 2)
    printf "},\n"
  }' "$ROOT/pds/tools/signing_inputs.txt" > "$WORK/taint-keys.rows"
  [ "$(wc -l < "$WORK/taint-keys.rows")" -eq 3 ] || fail 'taint probe keys 0, 8 and 9 come from pds/tools/signing_inputs.txt'
  {
    cat <<'EOF'
#include <stdint.h>
#include <string.h>
#include <valgrind/memcheck.h>

extern unsigned long GC_get_gc_no(void);

static const uint8_t ct_keys[3][32] = {
EOF
    cat "$WORK/taint-keys.rows"
    cat <<'EOF'
};

static uint8_t secret[32];

/* Loads one key and marks all 32 bytes undefined: memcheck then tracks
   every value computed from them. A no-op outside valgrind. */
int64_t ctTaintLoad(int64_t k) {
  memcpy(secret, ct_keys[k], 32);
  VALGRIND_MAKE_MEM_UNDEFINED(secret, 32);
  return 0;
}

int64_t ctSecretByte(int64_t i) { return secret[i]; }

/* Returns a copy of v that memcheck treats as defined. */
int64_t ctDeclassify(int64_t v) {
  volatile int64_t t = v;
  VALGRIND_MAKE_MEM_DEFINED((void *)&t, sizeof t);
  return t;
}

/* The undefined-bit mask of v (1 bits undefined), read without branching
   on v. */
int64_t ctVbits(int64_t v) {
  int64_t word = v;
  uint64_t vbits = 0;
  VALGRIND_GET_VBITS(&word, &vbits, sizeof word);
  return (int64_t)vbits;
}

int64_t ctGcCount(int64_t unused) { (void)unused; return (int64_t)GC_get_gc_no(); }

/* The run-time address of ctTaintLoad; minus its link-time address, the
   load bias that maps a reported PC back into the objdump listing. */
int64_t ctLoadAddress(int64_t unused) { (void)unused; return (int64_t)(intptr_t)&ctTaintLoad; }
EOF
  } > "$WORK/taint-shim.c"
}

build_taint_probe() {
  output=$1
  MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 MEDAKA_CLANG_OPT=-O2 MEDAKA_NO_LTO=1 MEDAKA_RT_OBJ="$WORK/taint-rt-shim.o" \
    "$MEDAKA" build "$TAINT_PROBE" -o "$output" > "$output.build.log" 2>&1 || {
    cat "$output.build.log" >&2
    fail "memcheck taint probe builds at -O2 ($output)"
  }
}

run_memcheck() {
  bin=$1
  GC_DONT_GC=1 valgrind --tool=memcheck --error-limit=no --num-callers=30 --track-origins=yes \
    "$bin" > "$bin.out" 2> "$bin.memcheck" || {
    tail -40 "$bin.memcheck" >&2
    fail "memcheck taint probe runs to completion ($bin)"
  }
}

# One row per uninitialised-value report: top-frame PC, top-frame function,
# origin (client = the key taint, other = a stack or heap allocation, none =
# memcheck recorded no origin).
memcheck_uninit_reports() {
  awk '
    function emit() {
      if (kind != "") printf "%s\t%s\t%s\n", pc, fn, origin
      kind = ""
    }
    { sub(/^==[0-9]+== ?/, "") }
    /^(Conditional jump or move depends on uninitialised|Use of uninitialised value|Syscall param .* uninitialised)/ {
      emit(); kind = $0; pc = "-"; fn = "-"; origin = "none"; next
    }
    kind != "" && pc == "-" && /^ +(at|by) 0x/ { pc = $2; sub(/:$/, "", pc); fn = $3; next }
    kind != "" && /Uninitialised value was created by a client request/ { origin = "client"; next }
    kind != "" && /Uninitialised value was created by/ { origin = "other"; next }
    kind != "" && /^$/ { emit() }
    END { emit() }
  ' "$1"
}

# The probe must see real taint, or a clean report proves nothing: the key
# bytes survive the tagged heap round trip with exactly their eight bits
# undefined, and the validity bit, public key and signature all carry taint
# before they are declassified.
taint_run_is_live() {
  bin=$1
  [ "$(grep -c '^key ' "$bin.out")" -eq 3 ] || return 1
  grep -x -q 'tag 255 255 511' "$bin.out" || return 1
  grep -x -q 'gc 0' "$bin.out" || return 1
  if awk '$1 == "key" && ($4 == 0 || $5 == 0 || $6 == 0 || $3 != "vbits")' "$bin.out" | grep -q .; then return 1; fi
  return 0
}

is_conditional_jump() {
  case $(uname -m) in
    x86_64|amd64) grep -E -q '[[:space:]]j(a|ae|b|be|c|e|g|ge|l|le|na|nae|nb|nbe|nc|ne|ng|nge|nl|nle|no|np|ns|nz|o|p|pe|po|s|z)[[:space:]]' ;;
    arm64|aarch64) grep -E -q '[[:space:]](b\.[a-z]+|cbz|cbnz|tbz|tbnz)[[:space:]]' ;;
    *) return 2 ;;
  esac
}

write_taint_probe
write_taint_shim
# The shim is merged into the runtime with `ld -r`, which needs a native
# object, so this probe and its builds take the plain link (MEDAKA_NO_LTO)
# rather than the ThinLTO link `medaka build` ships.
MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 MEDAKA_CLANG_OPT=-O2 MEDAKA_NO_LTO=1 "$MEDAKA" build --emit-rt-obj "$WORK/taint-rt.o" > "$WORK/taint-rt.log" 2>&1 || {
  cat "$WORK/taint-rt.log" >&2
  fail 'runtime object for the memcheck taint probe builds'
}
clang -O2 -c "$WORK/taint-shim.c" -o "$WORK/taint-shim.o" || fail 'memcheck taint shim compiles'
ld -r "$WORK/taint-rt.o" "$WORK/taint-shim.o" -o "$WORK/taint-rt-shim.o" || fail 'memcheck taint shim links into the runtime object'

apply_mutation M-carry-guard "$WORK/pds/lib/scalar.mdk" \
  'carryAllUnchecked w = carryGoUnchecked w 0 0' \
  's/carryAllUnchecked w = carryGoUnchecked w 0 0/carryAllUnchecked w = carryGo w 0 0/'
build_taint_probe "$WORK/taint-mutant"
cp "$ROOT/pds/lib/scalar.mdk" "$WORK/pds/lib/scalar.mdk"
cmp "$ROOT/pds/lib/scalar.mdk" "$WORK/pds/lib/scalar.mdk" >/dev/null || fail 'M-carry-guard restores scalar.mdk byte-exactly'
run_memcheck "$WORK/taint-mutant"
taint_run_is_live "$WORK/taint-mutant" || { cat "$WORK/taint-mutant.out" >&2; fail 'M-carry-guard probe carries live taint with no collection'; }
memcheck_uninit_reports "$WORK/taint-mutant.memcheck" > "$WORK/taint-mutant.reports"
awk -F '\t' '$3 == "client"' "$WORK/taint-mutant.reports" > "$WORK/taint-mutant.tainted"
[ -s "$WORK/taint-mutant.tainted" ] || fail 'M-carry-guard secret carry branch unexpectedly unreported by memcheck'
if awk -F '\t' '$2 != "mdk_lib_scalar__carryGo"' "$WORK/taint-mutant.tainted" | grep -q .; then
  cat "$WORK/taint-mutant.tainted" >&2
  fail 'M-carry-guard reports land only in mdk_lib_scalar__carryGo'
fi
load_runtime=$(awk '$1 == "load" { print $2 }' "$WORK/taint-mutant.out")
load_link=$(nm "$WORK/taint-mutant" | awk '{ name = $3; sub(/^_/, "", name); if (name == "ctTaintLoad") print $1 }')
[ -n "$load_runtime" ] && [ -n "$load_link" ] || fail 'M-carry-guard load bias is derivable from the probe and its symbol table'
load_bias=$((load_runtime - 0x$load_link))
cut -f1 "$WORK/taint-mutant.tainted" | LC_ALL=C sort -u > "$WORK/taint-mutant.pcs"
while IFS= read -r pc; do
  offset=$(printf '%x' $((pc - load_bias)))
  objdump -d --start-address="0x$offset" --stop-address=$((0x$offset + 16)) "$WORK/taint-mutant" > "$WORK/taint-mutant.pc.asm"
  grep -F -q '<mdk_lib_scalar__carryGo+' "$WORK/taint-mutant.pc.asm" || fail "M-carry-guard PC $pc (0x$offset) lies inside mdk_lib_scalar__carryGo"
  grep -E "^ *$offset:" "$WORK/taint-mutant.pc.asm" > "$WORK/taint-mutant.pc.insn" || fail "M-carry-guard PC $pc (0x$offset) is an instruction boundary"
  is_conditional_jump < "$WORK/taint-mutant.pc.insn" || fail "M-carry-guard PC $pc is a conditional jump ($(cat "$WORK/taint-mutant.pc.insn"))"
  printf 'receipt: M-carry-guard reported at 0x%s:%s\n' "$offset" "$(cut -f3- "$WORK/taint-mutant.pc.insn")"
done < "$WORK/taint-mutant.pcs"
pass "M-carry-guard checked carry pass is caught by memcheck at an -O2 conditional jump in carryGo ($(wc -l < "$WORK/taint-mutant.tainted") reports)"

for rel in pds/lib/field.mdk pds/lib/scalar.mdk pds/lib/hmac_sha256.mdk pds/lib/secp256k1.mdk; do
  cmp "$ROOT/$rel" "$WORK/$rel" >/dev/null || fail "memcheck taint probe builds against the unmutated $rel"
done
build_taint_probe "$WORK/taint-clean"
run_memcheck "$WORK/taint-clean"
taint_run_is_live "$WORK/taint-clean" || { cat "$WORK/taint-clean.out" >&2; fail 'memcheck taint probe carries live taint with no collection'; }
corpus_row=$(awk '$1 == "sign" && $2 == 0 { print "pub " $5 " sig " $10 }' "$ROOT/pds/test/vectors/prehashed_signing_corpus.txt")
[ "$(awk '$1 == "key" && $2 == 0 { print $7, $8, $9, $10 }' "$WORK/taint-clean.out")" = "$corpus_row" ] ||
  fail 'memcheck taint probe key 0 reproduces the corpus public key and RFC 6979 signature'
memcheck_uninit_reports "$WORK/taint-clean.memcheck" > "$WORK/taint-clean.reports"
if awk -F '\t' '$3 == "client" || $3 == "none"' "$WORK/taint-clean.reports" | grep -q .; then
  cat "$WORK/taint-clean.reports" >&2
  fail 'signing path has no memcheck report tainted by the key'
fi
if grep -E -q 'mdk_lib_scalar__carry(Go|All)' "$WORK/taint-clean.memcheck"; then
  fail 'memcheck run mentions no carry pass (carryGo, carryGoUnchecked, carryAll, carryAllUnchecked)'
fi
pass "linked -O2 signing path for keys $TAINT_KEYS has zero key-tainted memcheck reports, none in either carry pass"
printf 'receipt: %s\n' "$(valgrind --version)"
printf 'receipt: memcheck %s\n' "$(grep 'ERROR SUMMARY' "$WORK/taint-clean.memcheck" | sed 's/^==[0-9]*== //')"

printf 'receipt: target=%s %s\n' "$(uname -s)" "$(uname -m)"
printf 'receipt: compiler=%s\n' "$(clang --version | sed -n '1p')"
[ "$checked" -ge 25 ] || fail "assertion floor (expected at least 25, got $checked)"
printf 'PASS: native signing constant-time closure — %s assertions\n' "$checked"
