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

The admitted secret key is exactly a canonical scalar `d` with `1 <= d < n`.
Invalid length, zero, and `>= n` rejection are API outcomes outside the
constant-time domain. Once admitted, the key's value must not affect control or
allocation. The signing input is a 32-byte SHA-256 digest, not an arbitrary
message; hashing variable-length application data occurs before this boundary.

## 2. Modules and public API

Implementation adds:

- `pds/lib/secp256k1.mdk`: opaque affine/Jacobian points, complete group
  operations, fixed-schedule scalar multiplication, compressed codec, and
  ECDSA/RFC-6979 internals;
- `pds/lib/sign.mdk`: the only consumer-facing key/signature interface;
- `pds/lib/hmac_sha256.mdk`: fixed-shape HMAC-SHA-256 over byte arrays, private
  to the signing layer.

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

All loops use only public fixed limb indices. These helpers join the existing
constant-time source/IR/final-code closure gate; a wrapper is not accepted
unless its entire transitive native callee graph is scanned.

### 3.2 Complete Jacobian addition by compute-and-select

No incomplete formula receives a secret-dependent exceptional branch. Each
`pointAddComplete(P,Q)` invocation unconditionally computes:

1. the standard secp256k1 Jacobian generic-add candidate;
2. the standard Jacobian double candidate for `P`;
3. the canonical infinity candidate;
4. fixed-control flags `pInf`, `qInf`, `sameX`, and `sameY` from `Z`, `U1/U2`,
   and `S1/S2` with the arithmetic helpers above;
5. an arithmetic selection chain choosing generic add, double, infinity, `P`,
   or `Q` for all exceptional cases.

All candidates and flags are computed for every call. The selections implement
the truth table:

| Condition | Result |
|---|---|
| `P` infinity | `Q` |
| `Q` infinity | `P` |
| same affine x and y | double `P` |
| same affine x and opposite y | infinity |
| otherwise | generic add |

The selection order gives the infinity rows priority. Point doubling is the
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
D0 = pointAddComplete R0 R0
D1 = pointAddComplete R1 R1
R0 = pointSelect bit D0 A
R1 = pointSelect bit A D1
```

`bit` is extracted arithmetically from a fixed byte/limb index. There is no
secret-index table and no branch/swap on the bit. The schedule therefore runs
768 complete additions for every scalar, including leading zero bits. This is
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
7. return `Err "RFC 6979 retry bound exhausted"` only if neither candidate is
   valid.

Thus every admitted call performs two candidate generations and two signing
computations. Candidate 0 is the ordinary RFC 6979 result; candidate 1 is
exactly the next result RFC 6979 prescribes after rejecting candidate 0. The
bounded failure is explicit rather than a hidden variable-time loop. Since
`2^256-n < 2^129`, candidate-range rejection is below `2^-127` per draw, and
`r=0`/`s=0` are each approximately `2^-256`; two failures are below the
project's operational threat floor while remaining a real, tested `Result`
case. This probability argument does not turn the error into success or permit
removing its test.

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

Public-input status does not weaken value acceptance: all Wycheproof invalid
rows must reject, and every supported valid row must accept. “Acceptable” rows
are treated as invalid unless the committed normalization policy explicitly
names the flag and reason; the initial policy names none.

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
| nonce/sign oracle B | RustCrypto `k256` tag `k256/v0.13.4`, commit `5ac8f5d77f11399ff48d87b0554935f6eddda342`, commit archive | `2413c10980e3a2648118953a6468699670d7f03674fe4dcbffa5d3ecc835ec5f` |
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
emits a row only if all fields agree byte-for-byte. libsecp256k1's nonce
callback is instrumented to record the candidate; RustCrypto's `rfc6979`
dependency is called at the pinned lockfile revision to record it independently.
The PDS oracle must agree on the compact signature for at least the 16
matching-index rows; PDS output never supplies the expected file by itself.

Point rows include infinity identities internally, `G`, `2G`, `3G`, the
small-scalar set above, `nG = infinity`, and compressed round trips. SEC 2
anchors `G`; both pinned implementations must agree on every derived multiple.
Self-agreement or Medaka-captured output is never an answer key.

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
14. a transitive secret-bearing wrapper omitted from the closure manifest.

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
