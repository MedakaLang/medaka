# PDS-CRYPTO-CLAIMS.md — what the PDS cryptography claims, and what it does not

**Status:** written for G-ANNOUNCE. Re-read against the tree on announcement day
([#3364](https://github.com/MedakaLang/medaka/issues/3364)).

Every cryptographic primitive the PDS uses is written in Medaka. We did that to
dogfood the language. Calling libsecp256k1 through FFI would have been the safer
choice, and we say so here first.

This page puts each claim next to the gate or corpus that checks it, then lists
what we do not claim. Every gate name below is a row of `./medaka gate list`.
From a checkout with a built `./medaka`, run one with
`./medaka gate run <name>`. Some rows need clang, valgrind, node or wasm-tools;
`./medaka gate list --json` names each row's toolchain. Every corpus file below
has a stanza in `pds/test/VECTOR-PROVENANCE.txt` giving its source, the
source's SHA-256 and the committed file's SHA-256.

## 1. Scope

**Written in Medaka:**

- SHA-256: `stdlib/crypto/sha256.mdk`.
- HMAC-SHA-256: `stdlib/crypto/hmac.mdk`. The fixed 32-byte-key form in
  `pds/lib/hmac_sha256.mdk` signs session tokens (JWT HS256) and drives RFC 6979.
- PBKDF2-HMAC-SHA-256: `pds/lib/pbkdf2.mdk`. The password credential that uses
  it is `pds/lib/credential.mdk`.
- secp256k1: field and scalar arithmetic, points, RFC 6979 deterministic
  nonces, low-S signing and 64-byte compact verification, in
  `pds/lib/field.mdk`, `pds/lib/scalar.mdk`, `pds/lib/secp256k1.mdk` and
  `pds/lib/sign.mdk`.
- SHA-1, for the WebSocket handshake's `Sec-WebSocket-Accept` value only:
  `pds/lib/sha1.mdk`. RFC 6455 makes it a protocol constant. It authenticates
  nothing and keeps no secret, and nothing else in the server hashes with it.

**Not written in Medaka:** TLS, which Caddy terminates; the language runtime
(`runtime/medaka_rt.c`, C with the Boehm garbage collector); the operating
system's entropy source; and the compilers that build all of it (`medaka` and
clang).

**Not present at all:** symmetric encryption, authenticated encryption and key
exchange. Nothing is encrypted at rest.

## 2. Claims and the gates behind them

### 2.1 Values: the arithmetic gives the published answers

The expected values come from outside this project. A reference
implementation, or a published test file, supplies every one. Medaka's own
output is never the answer key.

| Claim | Gate | Answer key and scope |
|---|---|---|
| SHA-256 matches NIST CAVS. | `pds/test/sha256_vectors` | `pds/test/vectors/SHA256ShortMsg.rsp` (65), `SHA256LongMsg.rsp` (64), `SHA256Monte.rsp` (100 Monte Carlo rounds), and 3 FIPS 180-2 worked examples in `sha256_worked_examples.txt`. Native runs all 232 records. Eval runs only the records of 64 bytes or less. |
| HMAC-SHA-256 matches Wycheproof, including truncated tags. | `pds/test/hmac_vectors` | `pds/test/vectors/wycheproof_hmac_sha256.txt`: 174 rows. The 87 rows with a truncated tag are graded by truncating the computed tag and comparing through `ctEq`. |
| HS256 session tokens match RFC 7520. | `pds/test/inlang_test_oracle` (runs `pds/test/jwt_test.mdk`) | `pds/test/vectors/rfc7520_jws_hs256.txt`. |
| PBKDF2-HMAC-SHA-256 matches RFC 7914 and Wycheproof. | `pds/test/pbkdf2` | `pds/test/vectors/rfc7914_pbkdf2_hmac_sha256.txt` (the two RFC 7914 §11 vectors) and `wycheproof_pbkdf2_hmac_sha256.txt` (60 rows). Every Wycheproof row there is a valid one; that file has no adversarial rows. |
| secp256k1 field arithmetic matches libsecp256k1. | `pds/test/field_vectors` | `pds/test/vectors/field_reference_corpus.txt`: 944 rows from libsecp256k1 v0.8.0, built with the same 10×26-bit limb layout. Native and Wasm run every row; eval runs every seventh. |
| Scalar arithmetic matches libsecp256k1. | `pds/test/scalar_vectors` | `pds/test/vectors/scalar_reference_corpus.txt`: 1028 rows from libsecp256k1 v0.8.0. |
| Public keys and point operations match libsecp256k1 **and** RustCrypto k256. | `pds/test/secp256k1_point_vectors`, `pds/test/secp256k1_public_key` | `pds/test/vectors/point_public_key_corpus.txt`: 25 rows (17 multiplications, 6 additions, 2 doublings). The generator writes a row only when both implementations agree on it byte for byte. The generator `G` comes from SEC 2 (`secp256k1_parameters.txt`). |
| RFC 6979 signing with low-S matches libsecp256k1 **and** RustCrypto k256. | `pds/test/ecdsa_vectors`, `pds/test/rfc6979_vectors`, `pds/test/signing_corpus` | `pds/test/vectors/prehashed_signing_corpus.txt`: 80 rows. The generator requires both implementations to agree byte for byte on the public key, the nonce `k`, `r`, the raw and low-S `s`, and the compact signature. Medaka reproduces all 80 through the public `signDigest`. `rfc6979_vectors` also checks one row's second RFC 6979 candidate, the one drawn after a rejection, against an independent Python HMAC. `signing_corpus` re-checks the corpus's shape and its two-oracle attribution offline. |
| Verification accepts and rejects what Wycheproof says, under atproto's low-S rule. | `pds/test/ecdsa_vectors` | `pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt`: 242 rows. 163 are upstream-valid; the 94 low-S ones are accepted. The other 148 are rejected: 79 upstream-invalid rows and 69 valid high-S rows that atproto's low-S rule refuses. `wycheproof_secp256k1_sha256_bitcoin.txt` adds the strict-DER file's rows that are not an exact (r, s) duplicate of a P1363 row. Of its 463 rows, 181 decode as strict, in-range DER, and 74 of those are new: 68 accepts and 6 rejects. 69 of them are the low-S mirror of a P1363 high-S signature, which P1363 itself never gets past the low-S rule to verify. |
| The official Bluesky PDS agrees. | `pds/test/did_key_all_engines`, `pds/test/secp256k1_public_key`, `pds/test/signing_corpus` | `pds/test/vectors/pds_did_key_corpus.txt`: 16 `did:key` values produced by the official image's `@atproto/crypto`, which Medaka reproduces on eval, native and Wasm. `pds/test/vectors/pds_message_signing_corpus.txt`: 16 raw-message signatures from the same image. When that corpus was generated, the image's output had to match libsecp256k1 and k256. No gate signs those 16 messages with Medaka directly. Medaka's signing is graded on the 80-row corpus above. |
| eval, native and Wasm compute identical values. | `pds/test/signing_parity`, `pds/test/constant_time_parity`, and the Wasm arms of `field_vectors` and `scalar_vectors` | These gates check values only, not timing. `signing_parity` compares native and Wasm on a sample and runs the full corpus natively on every merge. Its eval arm, and its full-corpus Wasm arm, run nightly (`SIGNING_DEEP=1`). |
| The corpora are the ones their sources published. | `pds/test/vector_provenance` | `pds/test/VECTOR-PROVENANCE.txt` pins every committed corpus file's SHA-256, so an edited or deleted row fails. The two-implementation agreement is checked once, when a corpus is generated, by `pds/tools/gen_field_corpus.sh`, `gen_scalar_corpus.sh`, `gen_point_corpus.sh` and `gen_signing_corpus.sh`. These are network tools, not gates. CI grades Medaka against the committed result. |

### 2.2 Constant time, on native only

This is a structural claim about the native build. On native, key and nonce
handling uses a fixed number of operations, loop iterations and allocations,
and no branch or memory index depends on a secret. The contracts are
[ATPROTO-PDS-CONSTANT-TIME.md](../design/ATPROTO-PDS-CONSTANT-TIME.md) and
[ATPROTO-PDS-SIGNING-CONTRACT.md](../design/ATPROTO-PDS-SIGNING-CONTRACT.md) §1.

| Claim | Gate | How it is checked |
|---|---|---|
| Field and scalar reductions use a fixed schedule (three rounds for the field, four for the scalar), then an unconditional subtract-and-select. | `pds/test/constant_time_reductions` | Source shape and emitted LLVM IR, with mutants that must fail: a round removed, and a selection replaced by `if`. |
| Public-key derivation is a fixed 256-round ladder with complete addition, bit selection done in arithmetic, and no secret-indexed lookup or secret early return. | `pds/test/constant_time_public_key` | Source, emitted IR and a closed source manifest. Mutants M01–M06, M14 and M15 of the signing contract's §7 list must fail. |
| Signing always computes both RFC 6979 candidates, selects low-S in arithmetic, emits a fixed-width signature, and adds no unaudited function to the closure from `publicKeyForSecret` or `signDigest`. | `pds/test/constant_time_signing` | Exact per-function control grades over the closure's emitted IR. Mutants M07–M13, M16 and P01–P04 must fail. |
| For the probed keys and entry points, the linked `-O2` signing binary has no branch, memory address or system-call argument that depends on the key. | `pds/test/constant_time_signing` (the memcheck arm, assertions 46–47) | Valgrind memcheck runs the linked `-O2` probe with the key bytes marked undefined. The probe drives key admission, public-key derivation, RFC 6979 nonce derivation and signing for three keys (0, 8 and 9 of `pds/tools/signing_inputs.txt`) on one digest, calling the internal entry points directly rather than through `publicKeyForSecret`/`signDigest`. The result is zero reports. A mutant that restores a secret-dependent carry check is caught at a conditional jump in the `-O2` binary. Receipt: Linux x86_64, Debian clang 19.1.7, valgrind-3.24.0. The collector is held off inside the probe, and the gate asserts that no collection ran; section 3.3 covers what that leaves out. |
| Signing checks its own output: `signDigest` verifies each signature before returning it. | `pds/test/constant_time_signing` (the verify call is in the pinned signing closure), `pds/test/ecdsa_vectors` (80/80 rows pass through it) | The failure branch has no test, because no fault-injection seam reaches it. This roughly doubles the cost of every sign, measured on this box at ~34ms without the check and ~83ms with it; it runs on every repo commit and every JWT issued. Not yet optimized. |
| Secret comparisons (password digest, JWT signature, session fingerprints) go only through `hmac.ctEq`. | `pds/test/constant_time_reductions` (`secret_comparisons_ok`) | A census over the source text of `pds/lib/credential.mdk`, `pds/lib/jwt.mdk` and `pds/lib/store.mdk`. It fixes each comparing function's number of `ctEq` calls. It rejects `==`, `/=` or `compare` on a named secret, a hand-rolled or wrapper comparator, an equality built from `arrayToList`, a dot-qualified `ctEq`, and a `ctEq` whose two arguments are the same text, however that text is spaced, parenthesized or split over lines, and whether the arguments are applied directly, through `|>`, or to a partial application such as `(ctEq a)`. Mutants must fail. Section 3.3 gives what this census cannot see. |

### 2.3 Keys, entropy and the process

| Claim | Gate | Scope |
|---|---|---|
| Key material comes from `getentropy(3)`, with no fallback to a seeded generator. If the OS source fails, the process panics. | `diff_compiler_os_entropy` | `osEntropyBytes` in `runtime/medaka_rt.c`. The gate checks independence across processes, and checks that the C helper never reaches the runtime's seeded generator. It supplies the signing key, the session secret, the credential salt and per-request nonces. Wasm has no entropy import, so `keygen` is native only. |
| `pds keygen` writes the key at mode `0600` and refuses to overwrite an existing file. `serve` refuses a secret file readable by anyone but its owner. | `pds/test/serve_e2e` (cases 25, 25a, 25b and 28) | Filesystem permissions are the only protection. See section 3.4. |
| A crash does not write a core file. | `pds/test/deploy_config_lint` | `pds/pds.service` sets `LimitCORE=0`. On the deploy box, systemd's default soft limit is already 0, and a crash measured with no `LimitCORE` wrote no core. The directive also zeroes the hard limit, so the process cannot raise its own soft limit again. [PDS-RUNBOOK.md](PDS-RUNBOOK.md) §6b. |

## 3. What is not claimed

### 3.1 No one outside the project has reviewed this

No external reviewer has read the arithmetic or the constant-time arguments,
and we are not seeking one. What the arithmetic has been checked against is
listed in section 2.1:

- libsecp256k1, byte for byte, for field, scalar, point and signing values;
- RustCrypto k256 as well, for point and signing values, where a row is
  written only when the two agree;
- the official Bluesky PDS image, for `did:key` values and the 16 raw-message
  signatures;
- Wycheproof (ECDSA P1363 and Bitcoin, HMAC-SHA-256, PBKDF2-HMAC-SHA-256), NIST
  CAVS for SHA-256, and RFCs 7520 and 7914.

All of these are fixed corpora. Nothing yet generates new inputs. A nightly
differential fuzz against libsecp256k1, biased toward edge values, is planned
and filed as [#3378](https://github.com/MedakaLang/medaka/issues/3378). It does
not run today.

A corpus can check values but not reasoning. The overflow headroom arguments
and the complete-addition argument have not been reviewed by anyone outside
the project. [#3379](https://github.com/MedakaLang/medaka/issues/3379) is a
standing invitation, with a reading list, for anyone who wants to. If someone
reviews part of it, this section will record what they read and when, and
claim nothing beyond that.

### 3.2 Constant time outside the native build

- **No constant-time claim on Wasm or eval.** Both must compute the same values
  as native, and the parity gates check that. Neither is timing evidence.
  Wasm's integer representation is chosen by value, so it branches and
  allocates below any PDS code.
- **No timing measurement.** The evidence is structural: source, emitted IR,
  and memcheck's data flow over one binary. No statistical timing test runs.
  The IR and memcheck evidence holds for the compiler and target it was taken
  on, not for all hardware.
- **Success and exhaustion are observable.** Signing reveals one secret-derived
  bit: whether it produced a signature or exhausted its RFC 6979 retries (the
  signing contract's §1 exception). Everything that led to that bit stays
  secret.

### 3.3 Gaps in the constant-time evidence

- **The garbage collector.** The memcheck run covers all scalar and field
  arithmetic, nonce derivation and signing, and finds no branch, address or
  system-call argument that depends on the key. It does not cover the
  collector's conservative scanning. The signing key is now stored in a
  pointer-free block (`Bytes`, allocated by `mdk_alloc_atomic`), which the
  collector does not scan between calls. So the process-lifetime exposure
  first disclosed on [#3361](https://github.com/MedakaLang/medaka/issues/3361)
  is closed. Each signing or key-derivation call still unpacks a scratch copy
  of the key into an ordinary `Array Int`, and a collection that runs during
  that call can read and branch on key-derived words. Under Valgrind the heap
  sits far below its native address range, so this narrower window was measured
  there and not in a native run. It is disclosed, not eliminated:
  [#3361](https://github.com/MedakaLang/medaka/issues/3361) and
  [#3389](https://github.com/MedakaLang/medaka/issues/3389). No gate checks
  which allocator holds the key. That was checked once, by reading the emitted
  IR.
- **The public wrappers are outside the memcheck run.** The probe calls the
  internal signing entry points, not `publicKeyForSecret` and `signDigest` in
  `pds/lib/sign.mdk`. So the key unpacking those wrappers do is checked at the
  source and IR level only. The run covers three keys and one digest.
- **Token and password comparisons have no binary-level check.** Nothing taints
  the session secret or the credential digest through `credentialVerify` and
  `jwt.verifySegments`. That extension was proposed in #3361's "Stretch, same
  harness" section and not attempted; tracked separately as
  [#3392](https://github.com/MedakaLang/medaka/issues/3392). Those `ctEq`
  sites are checked at source level only.
- **The comparison census reads source text.** It cannot tell that two
  textually different expressions evaluate to the same value. For example, two
  calls into a helper that always returns the same secret. Such a `ctEq`
  compares a value with itself and passes the census, and another comparator in
  the same function or file can then do the real comparison, not in constant
  time. The paragraph above `secret_comparisons_ok` in
  `pds/test/constant_time_reductions.sh` states this scope. Closing it needs a
  check at the IR level, tracked as
  [#2838](https://github.com/MedakaLang/medaka/issues/2838).

### 3.4 Keys and passwords

- **The PBKDF2 iteration count is 60,000.** `defaultIterations`
  (`pds/lib/credential.mdk`) is 60,000. OWASP's floor for PBKDF2-HMAC-SHA-256 is
  600,000, 10 times more. Someone who steals `<data>/credential` can therefore
  guess a weak password 10 times faster than against a server that meets the
  floor. [ATPROTO-PDS-DESIGN.md](../design/ATPROTO-PDS-DESIGN.md) §4.2 ("The
  chosen count", "The residual gap") gives the measurement (2026-09-24, a login
  at this count takes 0.26–0.52 s on the reference box) and the budget.
  A record derived at an earlier count moves onto this one at its owner's next
  successful login. Ruling R3 in [PDS-LAUNCH-PLAN.md](PDS-LAUNCH-PLAN.md) §5
  (Val, 2026-09-12, recorded on
  [#2659](https://github.com/MedakaLang/medaka/issues/2659); launch criterion
  B12) accepted the previous count of 3,000 for a single-owner server whose
  password never leaves its owner: whoever can read the credential file can
  also read the signing key. **Ruling R6** (Val, 2026-09-24, comment on
  [#3373](https://github.com/MedakaLang/medaka/issues/3373)) re-rules for the
  raised count: 60,000 is ACCEPTED for a single-owner server, on the same
  reasoning as R3 — the 10x residual gap to OWASP's floor is a known
  limitation, not a defect, until a cheaper primitive
  ([#3367](https://github.com/MedakaLang/medaka/issues/3367)) narrows it
  further.
- **Keys at rest are plaintext.** The signing key and the session secret are
  stored unencrypted at mode `0600`. Filesystem permissions are the only
  protection ([ATPROTO-PDS-DESIGN.md](../design/ATPROTO-PDS-DESIGN.md) §4.2.1).
- **Secrets are not wiped or locked in memory.** Nothing zeroes a secret after
  use, and nothing locks one into RAM. The session secret and the stored
  credential digest are ordinary `Array Int` values that the collector scans
  for the life of the process. Only the signing key moved to pointer-free
  storage.

### 3.5 The trusted base

The `medaka` compiler, clang, the C runtime and the Boehm collector are all
trusted. A miscompile that shows up only on inputs outside the fixed corpora
would not be caught. The constant-time evidence holds for the binary the gates
built, with the compiler that built it.
[PDS-RUNBOOK.md](PDS-RUNBOOK.md) §7 re-runs the three-engine signing parity
check before a `pdsd` rebuilt with a newer compiler is deployed.

## 4. Reporting a problem

There is no private reporting channel yet. GitHub private vulnerability
reporting is not enabled on this repository. If you think you have found
something sensitive, open an ordinary public issue on
[MedakaLang/medaka](https://github.com/MedakaLang/medaka/issues) with minimal
detail, and say that it is sensitive. Leave out the reproduction. We will
contact you for the rest privately.

## 5. A closing caution

We have tested and hardened these primitives as far as we can, and we believe
they are well constructed. They have had no outside review. Please do not use
them for anything truly sensitive.
