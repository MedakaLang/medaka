#!/bin/sh
# Native structural closure and transactional contract controls for #1700
# step 4. This is a source/IR/link audit, not a timing benchmark or Wasm claim.
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
    stdlib/sha256.mdk \
    stdlib/hmac.mdk \
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
    stdlib/sha256.mdk \
    stdlib/hmac.mdk \
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
3840689225 26477  pds/lib/field.mdk
771369044 31975  pds/lib/scalar.mdk
619060746 11569  stdlib/sha256.mdk
4205512882 5228  stdlib/hmac.mdk
4177288074 1203  pds/lib/hmac_sha256.mdk
1691956410 24617  pds/lib/secp256k1.mdk
3267398383 4682  pds/test/constant_time_signing_main.mdk
EOF
}

expected_public_source_manifest() {
  cat <<'EOF'
3840689225 26477  pds/lib/field.mdk
771369044 31975  pds/lib/scalar.mdk
619060746 11569  stdlib/sha256.mdk
4205512882 5228  stdlib/hmac.mdk
4177288074 1203  pds/lib/hmac_sha256.mdk
1691956410 24617  pds/lib/secp256k1.mdk
3175129806 3842  pds/lib/sign.mdk
2846312137 3153  pds/test/constant_time_signing_public_main.mdk
EOF
}

# The signing closure's SHA-256 and HMAC live in stdlib/, reached by a bare
# `import sha256` / `import hmac` rather than `import lib.<mod>`. Following only
# the `lib.` form would silently shrink the audited closure to the pds half,
# which is the one failure this whole function exists to prevent, so the second
# arm below follows the bare form too. It is restricted to the stdlib modules
# the signing path actually carries: a blanket `^import <anything>` arm would
# drag in `array`, `string` and every transitive leaf, and the manifest is a
# hand-maintained claim about the SIGNING source, not about the stdlib.
SIGNING_STDLIB_MODULES='sha256 hmac'

derive_stdlib_imports() {
  file=$1
  for mod in $SIGNING_STDLIB_MODULES; do
    if grep -E -q "^import ${mod}(\.|\$| )" "$file"; then
      printf 'stdlib/%s.mdk\n' "$mod"
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
  hmac="$tree/stdlib/hmac.mdk"
  sha="$tree/stdlib/sha256.mdk"
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
  grep -F -q 'publicKeyForSecret (SecretKey scalar) = PublicKey (publicPointForSecret scalar)' "$sign" || return 1
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
    stdlib/sha256.mdk \
    stdlib/hmac.mdk \
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
# Two of the claimed signing sources now live in stdlib/, and the scratch tree
# is what every source-shape control runs against, so it needs them too.
mkdir -p "$WORK/stdlib"
cp "$ROOT/stdlib/sha256.mdk" "$ROOT/stdlib/hmac.mdk" "$WORK/stdlib/"
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
  'publicKeyForSecret (SecretKey scalar) = PublicKey (publicPointForSecret scalar)' \
  's/publicKeyForSecret \(SecretKey scalar\) = PublicKey \(publicPointForSecret scalar\)/publicKeyForSecret (SecretKey _) = match pointFromCompressed (arrayMake 33 0)\n  Ok point => PublicKey point\n  Err message => panic message/'
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

# M15: the same control for the stdlib half of the claim. Without the bare-import
# arm in derive_source_files the derived closure would stop at pds/lib, so
# dropping stdlib/sha256.mdk from the claim would go UNNOTICED -- which is the
# state this gate was in the moment SHA-256 moved out of pds/lib. Proving the
# omission reds is what makes the new arm load-bearing rather than decorative.
sed '/stdlib\/sha256.mdk/d' "$WORK/manifest.baseline" > "$WORK/manifest.mutated"
if source_claim_matches_derived "$ROOT" "$WORK/manifest.mutated" pds/test/constant_time_signing_main.mdk; then fail 'M15 stdlib closure omission unexpectedly green'; fi
sed '/stdlib\/hmac.mdk/d' "$WORK/manifest.baseline" > "$WORK/manifest.mutated"
if source_claim_matches_derived "$ROOT" "$WORK/manifest.mutated" pds/test/constant_time_signing_main.mdk; then fail 'M15 stdlib HMAC omission unexpectedly green'; fi
pass 'M15 claimed stdlib SHA-256/HMAC omission is rejected by independently derived source closure'
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
# Re-derived when SHA-256 and the HMAC schedule moved to stdlib/. Measured
# against the previous closure, symbol by symbol: 26 lines are a pure 1:1
# rename (mdk_lib_sha256__X -> mdk_sha256__X, 24 of them, plus the two forced
# constants h0Init and k); 6 lines left, all of them the old pds-side HMAC
# privates (copyBytes, fillKeyPad, joined, keyPad and the forced blockBytes and
# digestBytes); 8 entered -- mdk_hmac__{keyPad,fillKeyPad,hmacSha256FixedBytes},
# the forced mdk_force_hmac__blockBytes, and array.concat's four definitions,
# which replace the hand-rolled element-at-a-time joined/copyBytes with a
# length-summing pass and a bulk arrayBlit. 170 -> 172 definitions. Nothing
# else entered or left, and no SHA-256 helper dropped out.
[ "$closure_grade" = '4136339374 4796' ] || fail "emitted transitive closure drifted ($closure_grade)"
# Two of the five modules now live in stdlib/, which mangles without the `lib_`
# segment, so the prefixes are spelled out rather than built from a module name.
for prefix in mdk_lib_field__ mdk_lib_scalar__ mdk_sha256__ mdk_hmac__ \
  mdk_lib_hmac_sha256__ mdk_lib_secp256k1__
do
  grep -F -q "$prefix" "$WORK/full-closure.lst" || fail "emitted closure reaches $prefix"
done
if grep -F -q 'mdk_sha256__byteDomainOk' "$WORK/full-closure.lst"; then
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
# Re-derived across two independent changes landing on top of each other: the
# stdlib hmac/sha256 migration (170 -> 172 shared symbols, same set/order as
# before) and the emitter's direct-discriminant optimization (deletes the
# discimm/discbox/disccont triple per constructor match). Measured column-wise
# against the migration-only manifest over all 172 rows, same set, same order:
# comparisons, indices, writes, makes, copies and the call total did not move
# in a single row. The branch column fell by exactly 1 in the same 14 rows the
# discriminant optimization affects elsewhere in the tree (mdk_core__not,
# rawFe, rawSc, the four point/select helpers, secretAffine,
# selectSigningCandidates, signCandidate, and three sha256 internals) and rose
# in none. No function outside those 14 changed at all; no branch anywhere in
# the closure tests a byte.
[ "$control_grade" = '2431464021 7220' ] || fail "emitted control/index/allocation manifest drifted ($control_grade)"
pass 'emitted helper bodies retain the audited branch/index/allocation shape; only fixed public controls remain'

for symbol in \
  mdk_lib_secp256k1__ecdsaSignDigestForTest \
  mdk_lib_secp256k1__ecdsaSignFixed \
  mdk_lib_secp256k1__signCandidate \
  mdk_lib_secp256k1__selectSigningCandidates \
  mdk_lib_secp256k1__rfc6979NonceSchedule \
  mdk_lib_hmac_sha256__hmacSha256FixedKey \
  mdk_sha256__sha256FixedBytes \
  mdk_sha256__sha256AssumeByteDomain \
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
# schedule itself, mdk_hmac__hmacSha256FixedBytes. The guard is still pinned
# by source text above and by the IR closure manifests, which read definitions
# rather than surviving link-time symbols.
for symbol in \
  mdk_lib_secp256k1__signCandidate \
  mdk_lib_secp256k1__rfc6979NonceSchedule \
  mdk_hmac__hmacSha256FixedBytes \
  mdk_sha256__compressRounds \
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
for prefix in mdk_lib_field__ mdk_lib_scalar__ mdk_sha256__ mdk_hmac__ \
  mdk_lib_hmac_sha256__ mdk_lib_secp256k1__ mdk_lib_sign__
do
  grep -F -q "$prefix" "$WORK/full-closure.lst" || fail "public union reaches $prefix"
done
for symbol in \
  mdk_lib_secp256k1__ecdsaSignFixed \
  mdk_lib_secp256k1__signCandidate \
  mdk_lib_secp256k1__selectSigningCandidates \
  mdk_lib_secp256k1__rfc6979NonceSchedule \
  mdk_lib_hmac_sha256__hmacSha256FixedKey \
  mdk_sha256__sha256FixedBytes \
  mdk_sha256__sha256AssumeByteDomain \
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
# Same two changes as the secret-side grade above. The closure grade did not
# move -- the public union reaches the same 176 symbols it did after the
# migration alone. Only the control grade shifted, and by the same mechanism:
# measured column-wise over all 176 rows, same set, same order, nothing rose
# in any column. Branches fell by exactly 1 in 16 rows -- the 14 shared with
# the secret-side manifest, plus publicKeyForSecret (2->1) and signDigest
# (5->4), the two public wrappers outside the secret closure that the
# discriminant optimization also reaches.
if [ "$public_closure_grade" != '824690028 4915' ] || [ "$public_control_grade" != '3601723552 7395' ]; then
  fail "public union exact grades drifted (closure=$public_closure_grade control=$public_control_grade)"
fi
pass "public-root LLVM union excludes ForTest and retains the audited signing/key topology ($(wc -l < "$WORK/full-closure.lst") definitions)"

# Same inlined-guard reasoning as the internal native-symbol list above.
for symbol in \
  mdk_lib_secp256k1__signCandidate \
  mdk_lib_secp256k1__rfc6979NonceSchedule \
  mdk_hmac__hmacSha256FixedBytes \
  mdk_sha256__compressRounds \
  mdk_lib_secp256k1__scalarLadder \
  mdk_lib_secp256k1__pointAddComplete \
  mdk_lib_secp256k1__pointDoubleComplete \
  mdk_lib_scalar__scInverse \
  mdk_lib_scalar__scSelect \
  mdk_lib_scalar__scNegateCt
do require_native_symbol "$symbol"; done
pass 'linked public consumer retains the audited HMAC/SHA, signing, point, inverse, and arithmetic-selection leaves'

printf 'receipt: target=%s %s\n' "$(uname -s)" "$(uname -m)"
printf 'receipt: compiler=%s\n' "$(clang --version | sed -n '1p')"
[ "$checked" -ge 25 ] || fail "assertion floor (expected at least 25, got $checked)"
printf 'PASS: native signing constant-time closure — %s assertions\n' "$checked"
