# atproto PDS native signing and public-key contract

**Status:** accepted implementation contract for #1700, prerequisite #1877. No
crypto implementation lands in this document.

This contract is subordinate to P4, P8, and P15 in
[`ATPROTO-PDS-DESIGN.md`](ATPROTO-PDS-DESIGN.md). It begins where the completed
[`ATPROTO-PDS-CONSTANT-TIME.md`](ATPROTO-PDS-CONSTANT-TIME.md) contract stops:
field/scalar reduction is fixed-control, but no point, public-key, RFC 6979, or
signing path is certified merely because those reducers are.

## 1. Boundary and engine claim

The deployment claim is narrow and testable:

- on native Linux/macOS, every admitted private-key and nonce path has an
  input-independent count of arithmetic operations, loop iterations, recursion
  exits, array indices, and allocations, and no secret-derived conditional
  branch from private-key ingress through compressed-public-key or signature
  output;
- message length, wire lengths, parse success, public-key validity, signature
  validity, and verification inputs are public;
- eval and Wasm must produce identical values, but are not constant-time
  evidence. Ordinary Wasm `Int` remains value-dependently boxed. This contract
  adds no Wasm entropy import or uniform crypto carrier;
- key generation and private-key persistence are out of scope. A later
  key-generation contract must use `osEntropyBytes` on native/eval and keep the
  explicit Wasm gap. This document does not settle design §7 Q6.

One result is deliberately declassified: after both RFC 6979 candidates and
both complete signing computations have run, their aggregate `validBit` may be
converted once to the public API result “signature” or “retry bound exhausted.”
The candidate chosen, the reason a candidate was invalid, and every value used
to reach that aggregate remain secret. P15 therefore promises fixed control
and allocation through production of that aggregate, not indistinguishability
between the externally observable success and exhaustion outcomes. This narrow
exception was accepted in #1877; it is not precedent for another secret-derived
branch.

The admitted secret key is exactly a canonical scalar `d` with `1 <= d < n`.
Invalid length is public. For an input of length 32, zero and `>= n` are tested
by the fixed parser in §3.1; only its final aggregate accepted/rejected bit is a
declassified validation result. Once admitted, the key's value must not affect
control or allocation. The signing input is a 32-byte SHA-256 digest, not an
arbitrary message; hashing variable-length application data occurs before this
boundary.

## 2. Modules and public API

Implementation adds:

- `pds/lib/secp256k1.mdk`: opaque affine/Jacobian points, complete group
  operations, fixed-schedule scalar multiplication, compressed codec, and
  ECDSA/RFC-6979 internals;
- `pds/lib/sign.mdk`: the only consumer-facing key/signature interface;
- the planned module named `hmac_sha256.mdk` in the PDS library directory:
  fixed-shape HMAC-SHA-256 over byte arrays, private to the signing layer.

`sign.mdk` exports opaque `SecretKey`, `PublicKey`, and `Signature` values and
the following semantic surface (exact constructor names are private):

```text
secretKeyFromBytes       : Array Int -> Result String SecretKey
publicKeyFromCompressed  : Array Int -> Result String PublicKey
publicKeyCompressed      : PublicKey -> Array Int
publicKeyForSecret       : SecretKey -> PublicKey
signatureFromCompact     : Array Int -> Result String Signature
signatureCompact         : Signature -> Array Int
signDigest               : SecretKey -> Array Int -> Result String Signature
verifyDigest             : PublicKey -> Array Int -> Signature -> Bool
```

Every PDS consumer imports `sign.mdk`, never `secp256k1.mdk`. `signDigest`
rejects a digest whose length is not 32. Compact signatures are exactly 64
bytes, big-endian `r || s`, never DER. Parsing rejects `r = 0`, `s = 0`,
`r >= n`, `s >= n`, and high-S; verification also returns `False` for them.
Compressed public keys are exactly 33 bytes, prefix `0x02` or `0x03`, followed
by canonical big-endian `x`; decoding rejects `x >= p`, nonsquare curve RHS,
and infinity.

`publicKeyForSecret` is secret-bearing even though its output is public. Its
presence is the accepted producer #1701 may consume; #1701 must not duplicate
point arithmetic or import the internal module.

## 3. Point representation and complete operations

The implementation retains the design's Jacobian coordinates:

```text
JPoint = (X, Y, Z), representing (X/Z^2, Y/Z^3)
infinity = (0, 1, 0)
```

Affine points are `(x, y)` and never represent infinity. Constructors remain
private. The SEC 2 secp256k1 parameters and generator are literals checked by
the vector gate.

### 3.1 Fixed-control field helpers

The signing slice adds private fixed-control helpers beside, rather than
silently reinterpreting, the current Bool-returning helpers:

- `feZeroBit` and `feEqualBit` return an arithmetic `0`/`1`. They OR/XOR all
  ten limbs and use a fixed-width subtract-one borrow chain; no early exit or
  Bool conversion is permitted.
- `feSelect bit a b` visits all ten limbs and computes
  `a + bit * (b - a)` per limb, with `bit` constrained to `0`/`1`.
- `feNegateCt` performs the complete modulus subtraction and arithmetic-selects
  zero when the input is zero; it never calls the current branch-bearing
  `feNegate`.

Equivalent scalar helpers are `scZeroBit`, `scEqualBit`, `scSelect`, and
`scNegateCt`. `scHighBit` subtracts `floor(n/2)+1` with the existing
non-negative borrow formula and returns `1 - borrow`; it does not call
Bool-returning `scIsHigh`.

`secretKeyFromBytes` first checks the public length, then scans all 32
big-endian bytes into a fixed-width scalar carrier. It unconditionally computes
both (a) the borrow from subtracting `n`, which proves `< n`, and (b) the borrow
from subtracting one, which proves nonzero. It combines those arithmetic bits
into one `validBit`. Construction of `SecretKey` or `Err` may branch only once
on that declassified aggregate after the scan; there is no per-byte, zero, or
range early return. The native closure includes this parser and its helpers.

All loops use only public fixed limb indices. These helpers join the existing
constant-time source/IR/final-code closure gate; a wrapper is not accepted
unless its entire transitive native callee graph is scanned.

### 3.2 Complete Jacobian addition by compute-and-select

No incomplete formula receives a secret-dependent exceptional branch. Each
`pointAddComplete(P,Q)` invocation unconditionally computes the following
generic-add candidate:

```text
Z1Z1 = Z1^2; Z2Z2 = Z2^2
U1 = X1*Z2Z2; U2 = X2*Z1Z1
S1 = Y1*Z2*Z2Z2; S2 = Y2*Z1*Z1Z1
H = U2-U1; I = (2*H)^2; J = H*I
r = 2*(S2-S1); V = U1*I
X3 = r^2-J-2*V
Y3 = r*(V-X3)-2*S1*J
Z3 = ((Z1+Z2)^2-Z1Z1-Z2Z2)*H
```

It also unconditionally computes this doubling candidate for `P`:

```text
A = X1^2; B = Y1^2; C = B^2
D = 2*((X1+B)^2-A-C)
E = 3*A; F = E^2
X3 = F-2*D
Y3 = E*(D-X3)-8*C
Z3 = 2*Y1*Z1
```

It then computes:

1. the canonical infinity candidate;
2. `pInf=feZeroBit(Z1)`, `qInf=feZeroBit(Z2)`,
   `sameX=feZeroBit(H)`, and `sameY=feZeroBit(r)`;
3. `equal=sameX*sameY` and `opposite=sameX*(1-sameY)`;
4. an arithmetic selection chain, on all three coordinates, starting with
   generic add and selecting double for `equal`, infinity for `opposite`, `P`
   for `qInf`, then `Q` for `pInf`.

All candidates and flags are computed for every call. The selections implement
the truth table:

| Condition | Result |
|---|---|
| `P` infinity | `Q` |
| `Q` infinity | `P` |
| same affine x and y | double `P` |
| same affine x and opposite y | infinity |
| otherwise | generic add |

The final two selections give the infinity rows priority; if both inputs are
infinity, selecting `Q` still produces infinity. `pointSelect` uses `feSelect`
for every coordinate. Every result with `Z=0` is arithmetically canonicalized
to `(0,1,0)`. Point doubling is the
same fixed operation for `Y = 0` and infinity; its formula naturally produces
`Z = 0`, then the result is canonicalized to `(0,1,0)` with arithmetic
selection. This compute-and-select construction, not a claim about an
incomplete formula being unreachable, is the completeness mechanism.

Renes–Costello–Batina 2015/1060 is retained as the independent completeness
review authority, but its projective-coordinate formulas are not copied into a
Jacobian implementation. A future switch to those formulas changes this
contract and requires re-review.

### 3.3 Fixed 256-bit scalar multiplication

Secret scalar multiplication uses exactly 256 iterations, most-significant bit
first. It starts with `R0 = infinity`, `R1 = P`. Each iteration unconditionally
computes:

```text
A  = pointAddComplete R0 R1
D0 = pointDoubleComplete R0
D1 = pointDoubleComplete R1
R0 = pointSelect bit D0 A
R1 = pointSelect bit A D1
```

`bit` is extracted arithmetically from a fixed byte/limb index. There is no
secret-index table and no branch/swap on the bit. The schedule therefore runs
256 complete additions and 512 complete doublings for every scalar, including
leading zero bits. The scalar carrier is exactly 32 big-endian bytes and the
public loop index selects byte `i / 8` and bit `7 - (i % 8)`. This is
deliberately slower than a window table and requires no performance exception:
PDS signing volume is low and correctness/security dominate.

Public verification may reuse this schedule. A future variable-time public
verification accelerator is a separate optimization and cannot be reachable
from `publicKeyForSecret` or `signDigest`.

### 3.4 Affine and compressed codecs

Affine conversion always computes one `feInverse Z`, `Z^-2`, and `Z^-3`.
Secret-bearing callers admit non-infinity outputs, proven by `1 <= d < n` and
the prime-order generator; no secret `Z == 0` branch exists. Public codec entry
points may reject infinity before entering the secret boundary.

Compressed encoding writes prefix `2 + parity(y)` arithmetically and always
serializes all 32 x bytes. Decoding is public-input code: compute
`rhs = x^3 + 7`, obtain `y = rhs^((p+1)/4)` with a fixed public exponent,
verify `y^2 == rhs`, and arithmetically select `y` or `p-y` to match the prefix.
Parse rejection may branch because the complete input and result are public.

## 4. RFC 6979 and signing schedule

HMAC follows RFC 2104 with SHA-256's 64-byte block size. The signing interface
already receives a fixed 32-byte digest; secret-key and digest processing,
HMAC block counts, array lengths, and allocation counts are therefore fixed.

RFC 6979 follows sections 2.3 and 3.2 with `qlen = 256`, `holen = 32`,
`rolen = 32`, `int2octets(x)` as 32-byte big-endian, and `bits2octets(h1)` as
the SHA-256 digest reduced modulo `n`. No extra entropy or personalization is
added.

The mathematically unbounded retry loop is made an explicit fixed-domain API:

1. initialize `K,V` exactly once;
2. derive candidate 0;
3. unconditionally execute RFC 6979's rejection-state update;
4. derive candidate 1;
5. compute **both** complete ECDSA signature candidates, including scalar
   multiplication, `r`, inverse, `s`, and low-S normalization;
6. arithmetic-select the first candidate for which `1 <= k < n`, `r != 0`,
   and `s != 0`;
7. return an internal fixed-shape `{ validBit, compact }` value with the same
   allocation shape whether zero, one, or two candidates were valid;
8. only `signDigest` converts the declassified aggregate `validBit` once to
   `Ok Signature` or `Err "RFC 6979 retry bound exhausted"`.

Thus every admitted call performs two candidate generations and two signing
computations. Candidate 0 is the ordinary RFC 6979 result; candidate 1 is
exactly the next result RFC 6979 prescribes after rejecting candidate 0. The
bounded failure is explicit rather than a hidden variable-time loop. Since
`2^256-n < 2^129`, candidate-range rejection is below `2^-127` per draw, and
`r=0`/`s=0` are each approximately `2^-256`; two failures are below the
project’s operational threat floor while remaining a real, tested `Result`
case. This probability argument does not turn the error into success or permit
removing its test.

The gate-only probe has an injectable candidate seam: it substitutes the two
32-byte candidate values and their range-valid bits after the normal fixed
HMAC schedule, while leaving both complete signature computations and the
final aggregate selection intact. Production has no injection parameter. This
seam must demonstrate candidate-1 selection and two-candidate exhaustion; the
exhaustion witness must reach exactly the single declassified branch above.

Candidate validity uses fixed borrow/zero bits. `k^-1` is never computed as a
meaningful candidate from zero: the arithmetic still runs on a safe selected
nonzero placeholder, and the candidate-valid bit remains zero. This fulfills
the #1700 direct-limb/no-sentinel obligation without a secret early exit.

For each candidate:

```text
R = k*G
r = x(R) mod n
s = k^-1 * (z + r*d) mod n
sLow = scSelect (scHighBit s) s (scNegateCt s)
```

All operations run before selection. Low-S is arithmetic; `scIsHigh`, ordinary
`scNegate`, scalar/field Bool equality, and sentinel comparisons are forbidden
in the secret closure.

## 5. Verification

ECDSA verification handles only public inputs and may return early on malformed
or invalid data. It computes `w=s^-1`, `u1=z*w`, `u2=r*w`, and
`u1*G + u2*Q`, rejecting infinity and accepting only when the affine x reduced
modulo `n` equals `r`. High-S is rejected at signature parsing and again at the
verification boundary so a future alternate constructor cannot bypass it.

Public-input status does not weaken value acceptance. The pinned Wycheproof
file has 242 rows: 163 marked `valid` and 79 marked `invalid`. Of the 163 valid
rows, the project predicate `s > floor(n/2)` identifies 69 high-S and 94 low-S
rows. The corpus preserves the upstream result and flags verbatim, and adds a
separate project expectation: accept exactly the 94 upstream-valid low-S rows;
reject the other 148. The generator asserts all four counts and recomputes the
high-S predicate. It never rewrites an upstream `valid` result into `invalid`.
An upstream `acceptable` row would reject unless a later accepted policy names
its flag and reason; this pinned artifact has none.

## 6. External authorities and corpus production

Every committed corpus receives a `VECTOR-PROVENANCE.txt` row. Downloaded
bytes are checked before extraction; generators refuse on tag/commit or digest
drift.

| Purpose | Authority and immutable artifact | SHA-256 |
|---|---|---|
| curve parameters and generator | SECG, SEC 2 v2, `https://www.secg.org/sec2-v2.pdf` | `87b8f3703364ed5b21ba8582e411cc0cbf477bcaa3f4f45e0d6580d1c00d9952` |
| deterministic nonce algorithm | IETF RFC 6979 text, `https://www.rfc-editor.org/rfc/rfc6979.txt` | `456e8f17558fdbd206f968b96fc6f1b4a71ea331ab30ad17f711ab3adaa7d701` |
| completeness review | IACR ePrint 2015/1060 PDF | `b836c9cf41f7826f2c5a6e252487b5013a4da6dc9838da11397c4022a1567326` |
| point/sign oracle A | bitcoin-core/libsecp256k1 tag `v0.8.0`, peeled commit `6e2c8bc4ecdc6e71dbe7a368f360d8d453ce435d`, commit archive | `3fe9fd705f4fdf2fe90d6e04b6c1fedd7e8f244a119315886f6468f52c2dfc33` |
| nonce/sign oracle B | RustCrypto `k256` tag `k256/v0.13.4`, commit `5ac8f5d77f11399ff48d87b0554935f6eddda342`, commit archive; locked `rfc6979` 0.4.0 crates.io checksum `f8dd2a808d456c4a54e300a23e9f5a67e122c3024119acbfd73e3bf664491cb2` | `2413c10980e3a2648118953a6468699670d7f03674fe4dcbffa5d3ecc835ec5f` |
| verification negatives | Google Wycheproof tag `google-wycheproof/v0.9`, commit `cff6adf42662469a1871e57303a0ad1d758ed8c0`, `testvectors_v1/ecdsa_secp256k1_sha256_p1363_test.json` | `6508e9cc99c169c7d59a6891d939387f115491c479088ddcdcec4d137be69f34` |
| PDS behavior | official image digest `ghcr.io/bluesky-social/pds@sha256:d95725b24dbe53af9d91dc69750556931ebed6c396f2cfa42b221434db642f12`, revision `374cf1d4ba782d4391bbb73e4e2d3f320d4846d6` | OCI digest is the artifact identity |

The signing corpus input manifest is committed source, not runtime randomness:

- private keys `1`, `2`, `3`, `n/2`, `n/2+1`, `n-2`, `n-1`, plus eight
  literal 32-byte values derived once as SHA-256 of the ASCII labels
  `medaka-pds-signing-key-0` through `-7` and reduced only by rejection;
- digests `00..00`, `00..01`, `ff..ff`, SEC 2 generator x, and twelve literal
  SHA-256 digests of `medaka-pds-signing-message-0` through `-11`;
- the 16 matching-index pairs plus a fixed 8x8 cross-product of the first eight
  keys and digests: 80 rows.

The generator obtains compressed public key, RFC-6979 `k`, raw `r`, raw `s`,
low-S `s`, and compact signature from both independent implementations. It
emits a row only if all fields agree byte-for-byte. The committed libsecp256k1
driver records `k` from `nonce_function_rfc6979_impl` and captures raw `s` in
`secp256k1_ecdsa_sig_sign` immediately before its `high =
secp256k1_scalar_is_high(sigs)` normalization. It includes the pinned tree's
internal source/headers and builds with `cc -O2
-DUSE_FORCE_WIDEMUL_INT64=1 -I<clone>`.

The committed Rust driver and lockfile call locked `rfc6979` 0.4.0 to record
`k`, then call `ecdsa_core::hazmat::sign_prehashed` directly to capture raw `s`
before k256's `SignPrimitive` wrapper calls `normalize_s`; the driver performs
and records normalization separately. The generator takes no runtime choice
of revision, algorithm, or capture point: only its output path is variable.

For the 16 matching-index message rows, the PDS comparison runs the pinned
image with `docker run --rm --entrypoint node ... --input-type=module -e ...`.
The script imports the absolute installed
`@atproto/crypto/dist/secp256k1/keypair.js`, parses lower-case key/message hex,
calls `Secp256k1Keypair.import(key, {exportable:false})`,
`publicKeyBytes()`, and `sign(message)`, and emits lower-case hex JSON. This
intentionally exercises the PDS API's SHA-256 hashing and low-S compact
signature behavior; it does not pass the already-hashed signing-corpus digest.
PDS output never supplies the expected file by itself.

Point rows include infinity identities internally, `G`, `2G`, `3G`, the
small-scalar set above, `nG = infinity`, and compressed round trips. No located
published artifact supplies all requested small multiples. The accepted #1877
authority recut therefore anchors `G` in SEC 2 and requires byte-identical
agreement between the pinned libsecp256k1 and RustCrypto k256 implementations
for every derived multiple. Medaka self-agreement or Medaka-captured output is
never an answer key.

Wycheproof ingestion keeps `tcId`, public key, message, 64-byte signature,
result, and flags. The gate asserts the source says `numberOfTests: 242` and
that the committed normalized corpus has 242 unique IDs; deletion or result
rewriting is a failure.

## 7. Fail-capable verification apparatus

The implementation lands one registered PDS gate family with a nonzero floor
and transactional mutations. It must prove red for:

1. 256 scalar rounds changed to 255;
2. arithmetic scalar-bit selection replaced by `if`;
3. a secret-index lookup introduced;
4. one complete-add exceptional selection removed;
5. `feZeroBit`/`scZeroBit` replaced by sentinel or Bool equality;
6. affine conversion given a secret early infinity return;
7. two RFC candidates changed to one;
8. candidate-zero/retry handling changed to an early return;
9. arithmetic low-S selection replaced by `if scIsHigh`;
10. verifier high-S rejection disabled;
11. compact output changed from 64-byte P1363 to DER or variable length;
12. one Wycheproof negative row removed or flipped;
13. the dual-oracle signing agreement check disabled;
14. a transitive secret-bearing wrapper omitted from the closure manifest;
15. private-key range or zero parsing changed to an early return;
16. the gate-only candidate seam no longer reaches candidate 1 or exhaustion.

The native structural gate starts at `publicKeyForSecret` and `signDigest`,
closes every local/transitive callee, and checks source, emitted LLVM helper
bodies, final linked reducer/point/HMAC/signing topology, and runtime bit-helper
disassembly. It rejects secret-derived conditional jumps, early exits,
value-derived indices, and value-dependent allocation sites. Public fixed
counters and fixed array bounds are allowed.

Value gates run the point/signing corpus and all 242 Wycheproof rows on native.
Sampled eval plus full Wasm corpora provide value parity; neither is timing
evidence. Last-round/candidate-1 witnesses run on all three engines.

## 8. Landing order and acceptance

The smallest safe implementation order is:

1. fixed-control field/scalar selection/zero/negation/high helpers and their
   transitive source/native controls;
2. complete points, fixed scalar multiplication, affine/compressed codec, and
   public-key corpus. Only after this lands may #1701 implement `did:key`;
3. HMAC/RFC6979, dual-oracle signing corpus, sign/verify, compact encoding, and
   Wycheproof ingestion;
4. `sign.mdk` consumer seam and whole-graph P15 audit.

Steps may be separate PRs only while no earlier PR claims the final P15 signing
property. Step 2 may expose `publicKeyForSecret` only when its own exact-head
native closure is certified; it cannot rely on the later signing audit. Step 4
is the only point at which #1700 may close.

Each behavior landing requires a fail-capable old-head or explicit mutation
control, exact corpus counts/digests, focused PDS gates, proportional repository
checks, independent exact-head review, final-head CI log proof, merge-group
success, and fresh-main ancestry. No implementation may widen this contract at
review time; a new secret producer, formula, retry count, API, corpus authority,
Wasm claim, entropy path, or key-storage decision returns to design authority.
