# A self-hosted atproto PDS in Medaka

**Status:** ACTIVE (2026-09-01) — Phases 0–2 are complete in the current tree,
and so is the PURE half of Phase 4 (#1697): the nine atproto record/sync/identity
endpoints and the two well-known paths, all as pure `Store -> Response`
functions. Phase 3 is next, but remains gated on the Async v2 runtime arc (#500)
and the graded-interface implementation work (#823/#824); everything left in
Phase 4 is the part that needs it.

A Personal Data Server for the AT Protocol, written in Medaka, hosted on the
dev box behind Caddy. This is simultaneously the most demanding Medaka program
yet attempted — it stresses effects, the async runtime, `byteparser`/`bytebuilder`,
and numeric code in ways self-hosting the compiler does not — and a system holding
a real social identity, so the correctness bar is higher than the compiler's.

---

## 0. Locked decisions

| # | Decision | Rationale |
|---|---|---|
| **P1** | **Own top-level project `pds/`**, with its own `medaka.toml`, mirroring `sqlite/` and `gzip/`. Not stdlib. | Those two are the precedent for a substantial Medaka subproject that consumes stdlib without joining it. Keeps the prelude blast radius at zero: a change to a stdlib module **that the compiler imports** and **that perturbs emitted IR** forces a seed re-mint plus fixpoint re-validation — both conditions required — while a `pds/` change forces neither. Graduation of individual modules to `stdlib/` is a later question — see P11. |
| **P2** | **`did:web` first; `did:plc` migration deferred to Phase 6.** | `did:web` is a static JSON document at `/.well-known/did.json` — no PLC directory, no genesis operation, no rotation-key management. It cuts an entire crypto+protocol subsystem out of the critical path. A DID is immutable, so the existing `did:plc:…` identifier can never *become* a `did:web` one: standing up a did:web account and moving the handle across is possible, but it abandons the original DID and with it the social graph. Phase 6 therefore remains genuinely necessary to reach the real handle *with its history intact*; it is deferred, not cancelled. |
| **P3** | **Standalone repo first; firehose (`com.atproto.sync.subscribeRepos`) deferred to Phase 5.** | Full network participation is a strict superset of a correct repo, and it is additive: WebSocket framing and event emission bolt onto a repo layer that already produces correct CIDs. Sequencing it second means the highest-risk work (MST, DAG-CBOR determinism) gets validated against an oracle before anything depends on it being right. |
| **P4** | **Crypto is pure Medaka — SHA-256 and secp256k1 both.** Field arithmetic on 10 × 26-bit limbs (P10). | Chosen for the dogfooding, not merely accepted despite the cost: this is the most numerically demanding code anyone would have written in Medaka, and it arrives with an external oracle that says immediately when the *compiler* is wrong (§4.1). Made tractable by one property: **atproto requires deterministic signing behaviour and low-S normalization, and RFC 6979 makes ECDSA output byte-reproducible** — so signing is gradeable by *golden diff against published vectors*, not by a probabilistic property test. That converts the scariest part of this project into precisely the kind of differential gate this repo is built around. See §4. |
| **P5** | **TLS is never implemented in Medaka. Caddy terminates.** | Caddy obtains and renews the Let's Encrypt certificate automatically and reverse-proxies plaintext HTTP to the Medaka process on localhost — which is what the official self-hosting guidance recommends regardless of implementation language. Cost to us: approximately zero. Writing TLS would be a larger and far more dangerous project than the entire rest of this document. |
| **P6** | **Do NOT build a bespoke event loop. The PDS is a *consumer* of the #500 arc, not a fork of it.** | `docs/design/ASYNC-RUNTIME-DESIGN.md` already specifies the reactor, and its A2 extern set (`ioPoll` over `poll(2)`, `netSetNonblock`, `netTry{Accept,Recv,Send}`) is exactly and only what a server needs. Duplicating it inside `pds/` would produce a second scheduler with none of the guarantees G1–G9 that design carries, and would make the PDS the reason the real one can never land. |
| **P7** | **Block store is flat sharded files on disk**, CID → bytes, not `sqlite/`. | A block store is a pure key/value map with content-addressed immutable keys — the one workload where a filesystem is already the right database. Pressing the in-tree SQLite engine into service would add a large dependency, a write-path risk, and a schema, in exchange for nothing. |
| **P8** | **Pinned official atproto/PDS code is the oracle; library reproduction and live-service evidence are distinct.** Every CID, CAR byte, and signature is diffed against exact official repo/crypto libraries. | Phase 1 pins the complete npm graph and independently reproduces the corpora with libraries installed in the digest-pinned official image. That applies the repo's differential methodology without starting a service. A live XRPC transcript is a separate manual tier: account creation stays disabled unless an isolated PLC endpoint is chosen, because the public default makes an irreversible identity write (§5). |
| **P9** | **The running server is native-only**; the pure core stays all-engine **by design, not by luck**. | The interpreter implements zero net externs (the T7 family in `test/CAPABILITY-EXCEPTIONS.txt`) and wasm rejects net as PERMANENT. ⚠️ **The same is true of every file extern** — `stdlib/fs.mdk` says so in its own header: *"Scope: NATIVE/LLVM … not the tree-walking interpreter."* So effectful storage code is native-bound exactly like sockets, and a core that *performed* its own I/O would not be portable or doctestable at all. P14 is the structural response; without it, this row's "costs less than it sounds" would be unsupported. |
| **P14** | **The pure core performs NO I/O. State transitions are explicit immutable values.** Phase 2's opaque `Store` wraps the verified immutable `BlockStore`; a configured `Server` owns the XRPC registry and injected pure handler. | This is what makes P9's claim true rather than aspirational. Both file and net externs are native-only, so any core module that touches storage directly is native-bound and undoctestable. The seam is `handle : Server -> Store -> Request -> (Store, Response)`, or `Store -> Request -> (Store, Response)` after configuring the server, with **no effect row at all**. Reads and protocol failures return the input store; successful writes return a successor. Phase 3 owns persistence adapters; Phase 4 owns multi-repository and blob-storage policy. |
| **P10** | **Field arithmetic uses `libsecp256k1`'s 32-bit field layout: 10 limbs in base 2^26, limbs 0–8 holding 26 bits and limb 9 holding 22.** | Resolved from §7 Q2. Decided on *cross-checkability against an audited implementation of the same representation*, not on speed. ⚠️ Note the limit of that: the reference's **overflow proof does not transfer** — `fe_mul_inner` assumes magnitude ≤ 8 and its accumulator reaches a full 64 bits, which does not fit Medaka's 62-bit non-negative range. Eager normalization (§4) is what makes it fit, and the magnitude-1 bounds must be derived by us. What the reference buys is a diffable oracle for element-level outputs and the shape of the reduction — not a transplantable safety argument. ~2.5× fewer partial products than a 16-bit layout, ~6 bits of headroom under 2^62. |
| **P11** | **The crypto modules graduate to `stdlib/` once proven, not before.** | Val's call. SHA-256 and base58 are plainly general-purpose. The reason to wait is **API churn against a compatibility promise**, not seed re-mints: placing a module in `stdlib/` does not by itself make the compiler import it, and only a change to a module the compiler *does* import, *and* which perturbs emitted IR, forces a re-mint (see P1). Graduation criteria, so "proven" is not a vibe: the full G1 vector suites pass, the API has been stable across a release, and a deliberate decision has been taken about which of `field`/`scalar` stay private to `pds/`. |
| **P12** | **Firehose events are persisted to a bounded append-only log, initially sized to the ~72-hour window relays currently default to** (Phase 5). | Resolved from §7 Q3 by looking at what the ecosystem does rather than deciding a priori — but the number is softer than it looks: 72 hours is the **configurable default of the relay generation introduced in January 2026**, not a spec requirement and not a historical invariant (`atproto.com/specs/sync` states no retention window at all). Operators tune it down. The design is deliberately robust to it moving: the log is bounded and `getRepo` covers full resynchronization independently. On-disk rather than in-memory specifically so a process restart does not invalidate a connected relay's cursor. Re-derive the number at Phase 5. |
| **P13** | **Phase 4.5 ships a read-only web view of the repo**, served from the same process. | Val's call. Cheap on top of Phase 2 (the router and the repo reader already exist; it adds templates and no new protocol), and it makes the system inspectable in a browser during the long stretch when Phase 5 is unbuilt and no Bluesky client can see it. Also the natural place to surface health and the block-store state. |
| **P15** | **The native `field`/`scalar`/signing arithmetic path deployed by the PDS must be constant-time with respect to secret inputs** — private keys and ECDSA nonces. A native signing implementation that is not constant-time does not ship. Eval and Wasm retain value parity; a Wasm constant-time claim requires its own uniform integer/crypto carrier because ordinary Wasm `Int` boxing is value-dependent. | The landed reducer mechanism is specified in [`ATPROTO-PDS-CONSTANT-TIME.md`](ATPROTO-PDS-CONSTANT-TIME.md) and tracked by closed #1724. That closure does not certify future code. The complete successor public-key/signing call graph, fixed algorithms, corpus authorities, and native emitted-control acceptance are specified in [`ATPROTO-PDS-SIGNING-CONTRACT.md`](ATPROTO-PDS-SIGNING-CONTRACT.md), tracked by #1877 and parent #1700. That successor contract explicitly declassifies only the final aggregate success/exhaustion result after two complete RFC 6979 attempts; candidate identity and rejection reasons remain secret. |

---

## 1. What the tree already provides

Better than a from-scratch estimate would suggest. Nothing below needs to be written:

| Need | Have |
|---|---|
| TCP sockets — listen/accept/send/recv/timeouts | `stdlib/net.mdk` over 10 externs in `stdlib/runtime.mdk` |
| Binary decode / encode combinators | `stdlib/byteparser.mdk` + `stdlib/bytebuilder.mdk` — a symmetric pair, exactly the shape DAG-CBOR and CAR want |
| Multi-precision arithmetic *pattern* | `stdlib/bits64.mdk` — limbs over the wrapping 63-bit fixnum, with the overflow-headroom argument stated explicitly in its own header. `compiler/eval/eval.mdk` hand-rolled this representation first and now imports the module instead (#223), which is what makes it battle-tested. The **method** carries over; the 256-bit field uses its own layout (P10), not this module, and its bound must be re-derived — `bits64`'s is computed for a 4-limb column |
| JSON | `stdlib/json.mdk` |
| base64, hex, deflate | `stdlib/base64.mdk`, `stdlib/hex.mdk`, `gzip/lib/deflate.mdk` |
| Time, ISO-8601, epoch, monotonic | `stdlib/time.mdk` |
| Byte-clean file I/O, paths | `readFileBytes`/`writeFileBytes` in `stdlib/runtime.mdk`, `stdlib/fs.mdk`, `stdlib/path.mdk` |
| Cooperative concurrency type + laws + `do` DX | `stdlib/async.mdk` (v1) |

Genuinely missing, and specified below: SHA-256, secp256k1, base58btc, unsigned-LEB128
varints, DAG-CBOR, CIDs, the MST, CAR, HTTP/1.1, and the readiness externs (#497).

---

## 2. The two dependencies, and why only one of them blocks what people assume

**#500 (Async runtime v2) is the capability dependency.** Every I/O extern blocks
today, so `concurrent [a, b]` interleaves *semantically* with zero wall-clock overlap
and a server cannot service two connections at once. That is a hard blocker for a
server shell and for nothing else.

**#823/#824 (graded interfaces) is the surface dependency, and it is the expensive
one to get wrong.** Every request handler is a `do` block over `Async`. #824 decides
how `do` routes over graded binds; #823 migrates `stdlib/async.mdk` itself and retires
the #817 W3 carve-out. Writing the server's I/O layer against plain `Thenable Async`
and migrating afterward is a rewrite of every handler — which is the precise reason to
sequence around it rather than through it.

**But the majority of this project is not concurrency-shaped at all.** SHA-256,
secp256k1, DAG-CBOR, CIDs, the MST, CAR, the commit/repo layer, and the HTTP/1.1
*parser* are pure, synchronous, bytes-in/bytes-out code with no `Async` in any
signature. That is most of the line count **and all of the correctness risk**. It is
blocked on neither arc, it runs on all three engines, and it is doctestable today.

The phase order below follows directly from that split.

---

## 3. Architecture: a pure core with a thin native shell

The organising principle, and the reason P9 costs little:

```
                    ┌─────────────────────────────────────────┐
   native-only,     │  socket shell — accept, read, write     │  Phase 3
   thin, ~400 loc   │  over #500's async net surface          │  GATED
                    └──────────────────┬──────────────────────┘
                     Array Int ⇄ Array Int │ Store (injected)
                    ┌──────────────────┴──────────────────────┐
                    │  handle : Server -> Store -> Request    │
                    │           -> (Store, Response)           │
   pure, portable,  │  XRPC routing · repo · MST · DAG-CBOR   │  Phases 0-2
   all-engine,      │  CID · CAR · SHA-256 · secp256k1        │  COMPLETE
   doctestable      │  HTTP/1.1 parse + serialize             │
                    └─────────────────────────────────────────┘
```

The HTTP layer is a **function from bytes to bytes**, not a server. `parseRequest :
Array Int -> Result String Request` remains the diagnostic-facing parser;
`parseRequestClassified` adds a typed malformed/resource-excess split for the
composition layer, and `serializeResponse : Response -> Array Int` is deterministic.
The router and configured server beneath them are pure too.

**Storage is threaded, not performed** (P14). Phase 2's opaque immutable `Store`
delegates `empty`/`get`/`put`/`size` to the verified `BlockStore`. A configured
`Server` holds a registry and injected handler; applying it yields the seam
`Store -> Request -> (Store, Response)`. The Phase 3 shell will own persistence
of successor values. Requests needing a clock take the timestamp as an argument
for the same reason.

This is not stylistic. **Every file extern is native-only, exactly like every net
extern** (`stdlib/fs.mdk`: *"Scope: NATIVE/LLVM … not the tree-walking interpreter"*),
so a handler that called storage directly would be as unportable as the socket shell,
and the phrase "pure core" would be decoration. Injection is what makes the box above
true.

What it buys: the correctness-critical code is gradeable by golden diff with no sockets
and no filesystem; it runs under `medaka run` and wasm, so doctests reach it; and Phase
3 shrinks to wiring — an accept loop, a request lifecycle, and persistence of the
explicit successor `Store`.

The dedicated `pds/test/protocol_all_engines.sh` gate grades fixed query routing,
chunked state update, malformed framing, unknown routing, and resource rejection on
eval, native, and real Wasm. Its expected cells are hand-authored rather than captured
from an engine, and its native mutation control proves the state-update assertion can
fail.

---

## 4. Pure-Medaka crypto (Phase 0)

The schedule and correctness risk of the whole project, so it goes first, fully
gated, before anything depends on it.

**Substrate.** `Int` is a signed 63-bit fixnum that wraps, so the usable non-negative
ceiling is **2^62**, and every intermediate must be kept provably under it by
construction. `stdlib/bits64.mdk` establishes the pattern and the style of argument
for 64 bits — four 16-bit limbs, least-significant first, with the headroom stated
explicitly in its header: a limb < 2^16, a 16×16 partial product < 2^32, a column sum
of *four* such plus carry < 2^35. The style transfers; that particular bound does not,
because it is computed for a 4-limb column.

**Field representation: 10 limbs in base 2^26 — limbs 0–8 hold 26 bits and limb 9
holds 22** (9×26 + 22 = 256, non-redundant). This is the layout `libsecp256k1` uses in
its 32-bit field implementation, and the asymmetric top limb is part of it: normalized,
`n[0..8] <= 2^26 - 1` and `n[9] <= 2^22 - 1`. **A uniform 10 × 26 would be a 260-bit
redundant representation with a different reduction** — a distinct design, not a
rounding of this one. See §7 Q2 for the alternatives weighed.

**What the reference does and does not buy us.** It gives the layout, the structure of
the reduction modulo `p = 2^256 - 2^32 - 977`, and — most valuably — an audited
implementation of the *same* representation whose element-level outputs we can diff
against. It does **not** give us a transplantable overflow proof, and assuming it does
is the trap this paragraph exists to prevent:

`secp256k1_fe_mul_inner` is written for inputs of **magnitude up to 8**, and under that
precondition its own accumulator genuinely reaches a full 64 bits — several of its
`VERIFY_BITS(c, 64)` assertions are commented out precisely because at 64 bits the
check is vacuous. **Medaka has 62 bits of non-negative range, so that chain does not
fit, and a literal transcription of it wraps silently.** That is S0 crypto wrongness of
exactly the kind §5 says neither self-consistency nor engine agreement can see.

**Therefore eager normalization is load-bearing, not a simplification.** Holding every
field element at magnitude 1 is what makes the arithmetic fit at all. The bounds that
follow are ours to derive and to state, and they are not in the reference:

- a limb < 2^26, so a partial product < 2^52;
- the largest column of a 10×10 schoolbook multiply takes exactly 10 partial products,
  so the column sum < 2^55.32;
- the reduction terms are small at magnitude 1 (`u_i * R0` with `R0 = 0x3D10 ≈ 2^13.9`,
  so ≈ 2^40) and do not disturb that bound;
- with carry propagation the worst case is ≈ 2^56, leaving **~6 bits under 2^62**.

**State this argument in the module header**, in `stdlib/bits64.mdk`'s style, and derive
it against the implementation rather than copying it from here.

**Modules.**

- `pds/lib/field.mdk` — arithmetic modulo the secp256k1 prime `p`: add/sub/mul/square/
  inverse/negate over the 10 × 26-bit representation, with fast reduction exploiting
  the binary structure of `p`. The hot module; essentially all of the cost lives here.
- `pds/lib/scalar.mdk` — arithmetic modulo the group order `n`. Separate from `field`
  on purpose: it runs a few times per signature rather than thousands, so it takes the
  simpler, slower representation and shares no code.
- `pds/lib/sha256.mdk` — straightforward 32-bit-word FIPS 180-4. The easiest module
  in this document and the one with the best-published vectors.
- `pds/lib/secp256k1.mdk` — field arithmetic, point add/double in Jacobian
  coordinates, scalar multiplication, **RFC 6979 deterministic `k`**, low-S
  normalization, 33-byte compressed *public-key* point encoding, and — stated because
  the spec pages do not have a signature-encoding section and its absence is an easy
  gap to fall into — the **64-byte compact `r || s` signature encoding, not DER**, which
  is what atproto's `sig` field carries. Confirm against the reference implementation's
  output before building on it; this is the one wire-format detail here whose primary
  source is weakest.
- `pds/lib/base58.mdk` — base58btc, needed only for `did:key`.
- `pds/lib/multiformats.mdk` — unsigned LEB128 varints and the multicodec prefixes.
  Note this is *not* `sqlite/lib/varint.mdk`'s encoding, which is SQLite's own
  big-endian scheme; they are different formats and must not be shared.

**Why this is gradeable rather than hoped-at.** ECDSA with a random nonce produces a
different signature every run and can only be property-tested. **RFC 6979 derives the
nonce deterministically from the key and message**, so a correct implementation emits
*specific bytes* for a given input — and atproto requires low-S normalization, which
removes the last degree of freedom. Signing therefore becomes a golden-diff gate rather
than a probabilistic one.

⚠️ **But RFC 6979 publishes no secp256k1 vectors.** Its Appendix A.2 covers DSA-1024/2048
and the NIST curves (P-192 through P-521, K-*, B-*) — **not k256**, which is the curve
Phase 0 targets. The *algorithm* is curve-generic, so the determinism property holds
and the golden-diff approach is sound; what does not exist is the specific answer key
the phrase "RFC 6979's own worked examples" implies. Choosing and justifying a
cross-implementation-agreed k256 corpus is therefore real, unwritten work, and it is
the weakest provenance link in the whole crypto phase. G1 names what is required.

**Volume context.** Generic double-and-add over 256 bits in Jacobian coordinates is
roughly 256 doublings plus ~128 additions, so a signature costs on the order of
**4,000–4,500 field multiplications** — call it 400k partial products at this layout.
(An earlier draft said 2,000; that was an estimate presented as if measured, and it was
low by about 2×.) A personal PDS signs once per record write, tens of times a day, so
even a slow implementation is irrelevant here — which is why §7 Q2 resolves on
cross-checkability rather than speed. Do not tune without measuring, and note that **no
existing gate would observe it**: `diff_compiler_perf_scaling` grades a growth ratio,
is structurally blind to constant factors, and does not run over `pds/` in any case.

**The seam.** Every consumer depends on `pds/lib/sign.mdk`'s interface, never on
`secp256k1.mdk` directly. Ordinary layering, kept because a stable API boundary is
right regardless — not as a hedge against the choice in P4.

### 4.1 What the dogfooding actually buys

This is a first-class goal of the project, not a consolation for the schedule.

Self-hosting the compiler is an *allocation- and control-flow*-heavy workload: lists,
maps, pattern matching, deep recursion. It barely touches arithmetic. Nothing in
`compiler/` runs a tight numeric inner loop millions of times, mutates an `Array Int`
in anger, or leans on `bitAnd`/`bitXor`/`shiftLeft` and wrapping-fixnum semantics for
its correctness. Field arithmetic does all four, continuously.

That makes Phase 0 an unusually sharp instrument for finding *compiler* bugs, for a
reason specific to it: **it is self-checking against an external answer key.** Most
performance or codegen defects in this tree surface as a slow stage or a plausible
wrong answer nobody notices. Here, a miscompiled shift or a wrongly-wrapped multiply
produces a signature that does not match RFC 6979's published bytes — a loud,
immediate, unambiguous failure pointing at a specific operation. The workload the
compiler has never been exercised on is exactly the workload that reports its own
defects most precisely.

Concrete things it is likely to surface, based on what this substrate has not yet
been asked to do: the cost of `Array Int` bounds-checked access in a hot loop; whether
tuple-returning limb helpers allocate per call or get unboxed; whether TRMC fires on
the accumulator loops; and the constant-factor gap between `medaka build -O2` and the
interpreter on numeric code, which nothing currently measures. Any of these becoming
a filed `ws:perf` or `ws:emitter` issue is a return on the phase independent of the
PDS ever shipping.

### 4.2 Password hashing (PBKDF2-HMAC-SHA-256)

Account bootstrap and `createSession` (Phase 4's "still owed" list) need to turn a
user password into a storable credential without keeping the password itself. Chosen
algorithm: **PBKDF2-HMAC-SHA-256** (`pds/lib/pbkdf2.mdk`), not scrypt/argon2/bcrypt —
this server signs and serves one account, so there is no attacker-throughput budget
that a memory-hard KDF is defending against, and PBKDF2-HMAC-SHA-256 reuses the
already-audited `pds/lib/sha256.mdk` rather than adding a new primitive family. It is
also RFC-vectored (RFC 7914 §11), keeping it inside G1's cross-implementation-agreed
corpus discipline rather than resting on a self-captured golden (G5).

The salt is always caller-supplied — `pbkdf2HmacSha256` draws no entropy and does no
I/O itself; salt generation is the shell layer's job, in the slice that wires up
account bootstrap.

**Iteration count: 1,500.** Measured on this box (`medaka build -O2`, 32-byte `dkLen`):
600,000 iterations — the current OWASP-recommended floor for PBKDF2-HMAC-SHA256 —
takes **~70 s** here, because this is a pure-Medaka implementation with no hardware
SHA extensions or vectorization, not a count anyone should read as a security
recommendation for a tuned native implementation elsewhere. 20,000 iterations took
~1.9 s (≈8,600–10,400 iterations/s, roughly linear); 1,500 iterations took
~200–240 ms across three runs, the largest sample under the ~250 ms budget with
headroom (S-kdf acceptance check 4). This number is revisited once the emitter's
numeric/allocation performance on this workload (§4.1) is itself improved, or if a
future slice moves the hot loop to a native `extern`.

### 4.3 Session tokens (JWT, HS256)

`createSession` hands the client a bearer token that `refreshSession` and every
authenticated XRPC route then has to check. Chosen format: **JWT (RFC 7519) in the JWS
Compact Serialization, signed with HS256** (`pds/lib/jwt.mdk`). JWT because the atproto
client ecosystem already expects a compact bearer string here; HS256 because this
server both mints and verifies its own tokens and nothing off-box ever verifies them,
so a symmetric MAC is the whole requirement and an asymmetric signature would buy
nothing. It is RFC-vectored (RFC 7520 §4.4's HS256 worked example), keeping it inside
G1's cross-implementation-agreed corpus discipline rather than resting on a
self-captured golden (G5). RFC 7515 A.1's HS256 example is not usable: its symmetric
key is 64 bytes and `pds/lib/hmac_sha256.mdk` accepts only 32.

**The key is a dedicated server secret, never the account's secp256k1 signing key.**
That key authenticates commits to every other implementation on the network; its
compromise is unrecoverable in a way a session-token compromise is not. Minting tokens
with it would put it on a second, far more frequently exercised code path — every
login, every refresh — for no interop gain, since no peer verifies our session tokens.
The secret is generated as exactly 32 bytes at account bootstrap (the shell layer's
job, a later slice) and lives beside the account record, not in the repo.

**Claims: `sub`, `aud`, `jti`, `iat`, `nbf`, `exp`** — `sub` the account DID, `aud`
the audience the token is good for, `jti` the token's own identifier, and the three
RFC 7519 §4.1 NumericDate fields in seconds since the Unix epoch. `nbf` equals `iat`;
this server mints no post-dated token. `nbf` is inclusive and `exp` exclusive.

`jti` and the audience split both arrived with the session slice, and both are
load-bearing rather than decorative. Without `jti`, two tokens minted for the same
subject in the same second are the same string, and a server that identifies sessions
by their tokens cannot then tell two sessions apart — a login while another login is
in flight would silently join the first one's session, and rotating one refresh token
would revoke the other's. `jti` is the request's own entropy, rendered as hex, so two
tokens are distinct because they were minted by two requests and for no other reason.
The audience differs between the two halves of a pair — the access token's audience is
the PDS hostname, the refresh token's is `<hostname>#refresh` — so neither can be
presented as the other: `verifyToken` grades the audience the ROUTE demands, and an
access token on `refreshSession` is refused by exactly the check that refuses a token
minted for a different server entirely.

**Verification pins the algorithm rather than reading it.** A token's `alg` header is
attacker-controlled input, so `verifyToken` always computes HS256 and then rejects any
header claiming anything else — `"alg": "none"` is one instance of that family, not a
separate case. The MAC is compared byte-wise with an XOR accumulator over the full
length, no early return. `verifyToken` takes the current instant as a parameter and
reads no clock, which is what lets `pds/test/jwt_test.mdk` place itself on either side
of every window boundary; it lives in `pds/lib/`, so it declares no effect row.

### 4.4 Sessions: what a bearer token is a credential FOR

A verified signature inside its window is not on its own a credential here. The store
holds an allow-list of open sessions — a fingerprint (SHA-256) of each of the pair's
two tokens, and the refresh token's expiry — and `lib.server_core`'s seam requires the
presented token's session to be OPEN as well as its signature to verify. That is what
makes `deleteSession` a revocation rather than a promise of one: after a logout, an
access token whose window has hours left is refused from the next request on, and a
purely stateless check could not do that at all.

Refreshing ROTATES: `refreshSession` removes the record its refresh token named and
opens a new one on a fresh pair. The consumed token is removed rather than marked, so
presenting it again finds no session and is refused — reuse detection with no extra
state. The rotation replaces the whole record, access half included, so a client that
refreshes is expected to use the access token it was just issued.

**Sessions live only in memory, and a restart closes all of them.** They are not
persisted: after a restart every previously issued token is refused and every client
logs in again. That is a fail-CLOSED behavior and it is deliberate — the alternative,
persisting session records, is a second on-disk file of security-relevant state with
its own staleness and mode problems, for the benefit of not asking a client to log in
after a server restart. The credential record IS persisted, because a server that
forgot the account password on restart could not accept a login at all.

**File modes are a real gap, stated plainly.** Medaka has no primitive that sets a
file mode: `writeFile` is `fopen(path, "wb")`, and there is no `chmod`, no `umask`,
and no mode argument anywhere in the runtime or the stdlib. So the generated session
secret and the stored credential record land at 0644 — world-readable — and
`pds/serve.mdk` says so loudly on stderr, naming the path and the mode, whenever it
creates one. It never names the contents: a warning that quoted the secret would be a
far larger disclosure than the mode it warns about. On a shared machine an operator
should pre-create the file under their own umask and hand it in with `--token-secret`.
This is a gap to close with a mode-taking write primitive, not a residual risk that
has been accepted; the two available workarounds are both worse than saying so
(shelling out to `chmod` leaves a real world-readable window between the create and
the chmod and grants the server an `<Exec>` capability to protect one file).

**The password never appears in an argument.** `--password-file PATH` is the only way
one reaches the server: an argument value is visible in `ps` output to every user on
the box. There is no interactive prompt, because no termios, tty, or echo-suppression
primitive exists in the runtime or the stdlib and a prompt that echoed the password to
the terminal would be worse than the file. A server with neither a stored credential
nor `--password-file` refuses to start rather than starting and refusing every login,
which would be indistinguishable from a working server until somebody tried to use it.

**Every secret this server generates comes from `osEntropyBytes`** — the session
secret, the credential salt, and the per-request nonce that identifies minted tokens.
`randomInt` is a SplitMix64 generator seeded deterministically; a session secret drawn
from it would be the same secret on every deployment, and forgeable from a public
constant. `pds/test/lib_boundary.sh` also grades a source-shape property in the same
region: no password, secret, salt, digest or credential may be interpolated into a
string anywhere in `pds/lib`, `pds/shell` or `pds/serve.mdk`, with one ledgered
exemption for the line in `lib.jwt` that assembles a token, where building that string
is the entire job.

---

## 5. The failure mode that matters, and the apparatus against it

A wrong MST layer computation or a non-deterministic CBOR encoder produces a repo
whose CIDs do not match what every other implementation computes. Nothing crashes.
Records save. The server returns 200. Relays simply decline to accept the repo — or
worse, accept it and fail to verify it later. **This is silent wrongness in a system
holding a real identity**, which puts it at the top of this repo's own severity ladder.

Neither self-consistency nor engine agreement can see it: our encoder and our decoder
agreeing proves only that they are inverse, and eval/native/wasm agreeing proves only
that they are the same code. Both are exactly the "all three engines equally wrong"
shape AGENTS.md warns about.

So the checks for Phases 0–1 are, without exception, against **external** answer keys.
G1–G5 below are **disciplines, not mechanisms** — see the note after G5, which matters
more than any single item in the list.

- **G1** — No module is depended upon before it passes published vectors.
  - *SHA-256*: FIPS 180-4 worked examples plus a NIST length corpus.
  - *ECDSA signing*: ⚠️ **RFC 6979 publishes no secp256k1 vectors** (§4) — its Appendix
    A.2 is DSA and the NIST curves. The k256 corpus must be chosen and justified:
    require agreement across at least two independent implementations, and record each
    vector file's provenance URL beside it.
  - *ECDSA verification*: Project Wycheproof's `ecdsa_secp256k1_sha256` suite. ⚠️ Two
    constraints the obvious reading misses — it is a **verification** suite, so it
    cannot grade signing, `k` derivation, or low-S normalization at all; and the default
    file is **DER/ASN.1** while atproto's `sig` is raw. Use the **`_p1363_` variant**,
    which is `r || s`, or a DER parser becomes a dependency this project otherwise
    never needs.
- **G2** — DAG-CBOR gated on the official atproto interop test files, plus a
  round-trip property over generated values. Determinism is the property under test,
  not merely correctness: canonical ordering, shortest-form integers, no indefinite-length
  encodings.
- **G3** — MST gated by building an identical record set in the official PDS and
  requiring **byte-identical root CIDs**, over a corpus deliberately chosen to exercise
  the layer boundaries (keys whose SHA-256 has 0, 2, 4, 6 leading zero bits — depth is
  leading zero *bits* divided by two, giving fanout 4) and prefix-compression edges.
- **G4** — CAR export byte-compared against the oracle's `getRepo` for the same repo.
- **G5** — **No golden is ever captured from our own implementation** in Phases 0–1.
  Capturing a golden records what the engine did, not what is correct; on a protocol
  where correctness is defined by other people's implementations, a self-captured
  golden is not weak evidence but *anti*-evidence, since it converts a bug into the
  defended expected output.

> G5 is now mechanically represented by `pds/test/VECTOR-PROVENANCE.txt` and
> its offline gate: every corpus has an attributed row and a checked local
> digest. Phase 1 adds two stronger but distinct reproduction routes. The exact
> lockfile-v3 makes `npm ci` verify the complete registry dependency graph used
> by the generators; the digest-pinned PDS image check runs those generators
> against its installed official repo/crypto libraries and byte-compares all
> MST/CAR/repo corpora. Neither route starts the PDS service or performs XRPC.
>
> That distinction is load-bearing. The live-service harness intentionally
> refuses an unset or empty PLC endpoint: account creation would otherwise hit
> the public PLC directory and perform an irreversible `did:plc` write. Phase 1
> therefore claims pinned package and image-library reproduction, not a live
> account transcript. A future live-service check needs an explicitly isolated
> PLC service and separate authority.

---

## 6. Phases

**Phase 0 — crypto core.** `field`, `scalar`, `sha256`, `secp256k1`, `base58`,
`multiformats`, signing, and secp256k1 `did:key`. Gated by G1. *Complete in
the current tree. All-engine.*

**Phase 1 — data model.** `dagcbor` (deterministic encode/decode over
`byteparser`/`bytebuilder`), `cid` (CIDv1: multibase, multicodec, SHA-256 multihash),
`mst` (depth from leading zero bits of the key hash ÷ 2, fanout 4; nodes serialized as
`l` plus an `e` array of entries of `p`/`k`/`v`/`t`), `car` (v1 read/write),
`blockstore` (a **pure `CID -> Bytes` map** under P14 — the flat sharded-file adapter
that backs it lives in the Phase 3 shell, not here), `repo` (commit objects — `did`,
`version: 3`, `data`, `rev` as TID, `prev`, `sig`; TID generation and monotonicity;
note `prev` is required-but-virtually-always-null in version 3, present in the CBOR
rather than omitted). Gated by G2–G5. *Complete in the current tree.* The
required CI route runs DAG-CBOR/CID, MST, and CAR fully on eval/native/Wasm.
The repo gate runs a pinned initialization+first-CREATE signed transition and
semantic boundaries on eval, with the complete five-operation transcript on
native/Wasm, keeping the pure core all-engine while bounding required-CI time.

**Phase 2 — protocol logic, still pure.** HTTP/1.1 request parse and response
serialize (request line, headers, chunked transfer, keep-alive semantics as data,
strict query decoding, and wildcard raw MIME bodies for `uploadBlob`); the XRPC
router preserves ordered query parameters on queries and procedures and treats
NSID authority identity case-insensitively without folding method-name case;
an opaque immutable `Store`; and configured
`handle : Server -> Store -> Request -> (Store, Response)` / `handleBytes` seams
with no effect row (P14). Whole requests are buffered with independent caps:
64 KiB combined header section, 150 KiB JSON, 100 KiB text, and 5 MiB raw/blob
body, plus bounded line, field, trailer, and chunk counts. *Complete in the
current tree. All-engine and doctestable with no sockets or files.*

**Phase 3 — the socket shell.** *Complete in the current tree.* `pds/shell/server.mdk`
is an accept loop over the async net surface (`stdlib/net_async`) around the pure
Phase 2 core: request framing via `scanRequestBoundary`, `idleTimeout`/`requestTimeout`/
`writeTimeout`, keep-alive and pipelined-request reuse, a `maxConcurrentConnections`
ceiling, and the shared `Ref Store` publish/persist sequence
(`pds/shell/server.mdk`'s `applyRequest`) that keeps two concurrent connections from
losing each other's write. `pds/shell/persist.mdk` and `pds/shell/blockfile.mdk`
persist the account repository to disk (design row P7) and `pds/serve.mdk` is the
entry point that admits configuration, rehydrates or initializes the repository, and
binds the loopback listener. `pds/test/serve_e2e.sh` (#2481, #2525) drives a built
server over a real loopback socket with a plain synchronous client and grades query,
pipelined, and keep-alive requests; a chunked-transfer write; each of the nine XRPC
NSIDs and both well-knowns, every one driven over the socket rather than read off the
registry; a malformed request and an over-cap body, both rejected rather than hung;
the idle-connection timeout; and restart-and-resume across a process boundary against
the same `--data` directory. `pds/test/lib_boundary.sh` closes out #2481 itself:
`pds/lib/` never imports `pds/shell/`, every `pds/lib/*.mdk` export carries an
explicit type signature, and none of those signatures declares an effect row, so the
pure core stays reachable from every engine Phase 3 does not run on. The signature
half is load-bearing rather than stylistic: an export with no signature gets an
inferred effect row, which a check that reads declared rows cannot see.

**Loopback-only is deliberate, not an oversight.** `bindLoopback` takes a port and
nothing else — no configuration path can move this server off `127.0.0.1`. §4.2-4.4
below describe the auth seam this server now has: the three record writes and
`getSession` require a valid access token, `refreshSession`/`deleteSession` require a
valid refresh token, `createSession` is the public login that issues both, and the
six reads, `resolveHandle`, and the two well-knowns stay public. Loopback-only is the
separate gate that remains: authentication makes the endpoints safe to answer, but
nothing here hardens the socket for exposure past loopback (TLS, a non-loopback
bind), which is not a Phase 3 or Phase 4 gap to work around but out of scope until a
later phase takes it up.

**Phase 4 — a standalone PDS.** *Pure half COMPLETE in the current tree
(#1697); the rest is Phase-3-gated.*

Shipped, all in `pds/lib/handlers.mdk` as pure functions over the Phase-2 seam:
record CRUD `createRecord`/`putRecord`/`deleteRecord`/`getRecord`/`listRecords`
(with `limit`/`reverse`/`cursor`), `describeRepo`,
`com.atproto.sync.getRepo`/`getLatestCommit`,
`com.atproto.identity.resolveHandle`, the `did:web` identity document at
`/.well-known/did.json`, and `/.well-known/atproto-did`. The two well-knowns are
their own explicitly-typed route class in `pds/lib/xrpc.mdk`, not synthesized
NSIDs, and reach the handler through the same `routeRequest`/`handle` seam as
every XRPC method. `sync.getRepo` returns `repoExportCar`'s bytes verbatim,
graded byte-for-byte against the provenance-pinned corpus.

Deliberately NOT shipped in the pure half, and each refused rather than faked:
authentication of any kind (there is none — the pure core is not safe to expose
as it stands), lexicon record validation (`validate: true` is refused),
`describeRepo`'s `didDoc` (no DID resolver, so any document would be invented),
`sync.getRepo`'s `since` (no incremental sync), and `validationStatus`.

Still owed, now that Phase 3's shell exists to carry them: account bootstrap,
`createSession`/`refreshSession` and JWT signing (reusing Phase 0),
`applyWrites`, blob upload/retrieval and `com.atproto.sync.listBlobs`,
multi-repository and blob-storage policy, and deployment behind Caddy under
systemd. **That is the first point with a running, useful artifact.**

**Phase 4.5 — read-only web view** (P13). Repo, collections, and individual records
rendered as HTML from the same process and router. No new protocol surface; makes the
system inspectable in a browser during the stretch before any client can see it.

**Phase 5 — network participation.** RFC 6455 WebSocket framing,
`com.atproto.sync.subscribeRepos` over the bounded on-disk event log (P12), and
outbound HTTP for appview proxying. ⚠️ **Scope this phase against `atproto.com/specs/sync`,
not against Phase 1's commit object.** The firehose `#commit` event carries fields the
repo commit does not — notably **`prevData`**, the previous MST root, marked optional
but effectively required for the MST inversion relays perform. Phase 1's field list is
correct for the *commit*; it is not the event schema, and treating them as the same
thing is how this phase fails to interoperate. (Note also that `prev` on the commit is
required-but-virtually-always-null in version 3 — present in the CBOR, not omitted.)
The outbound half is appview proxying (the app sends
reads through the PDS via the `atproto-proxy` header, which is an outbound HTTPS call —
so either `runCommand` to `curl` or a local egress proxy, since P5 means no TLS of our
own). At the end of this phase relays index the repo and posts reach the network.

**Phase 6 — `did:plc` migration.** PLC genesis and signed `updateOperation`, rotation
keys, and the account-migration sequence, to move the real handle onto this server.
Deliberately last: it is the only irreversible step in the project, and by this point
every primitive it depends on has been validated against an external oracle for five
phases.

**Phase 7 — OAuth.** DPoP, PAR, JWKS, authorization-server metadata. App passwords and
`createSession` remain functional throughout; OAuth is required for *third-party*
clients in production, which is a Phase 7 concern by construction.

---

## 7. Questions, resolved and open

**Q1 — Does the crypto graduate to `stdlib/`? RESOLVED → P11.** Yes, eventually,
gated on the criteria in that row rather than on a feeling that it looks finished.

**Q2 — What limb width? RESOLVED → P10: 10 × 26 bits.** Val delegated this one, so
the reasoning is recorded in full.

Against a non-negative ceiling of 2^62, where the largest column of an N-limb
schoolbook multiply takes exactly N partial products and the whole multiply takes N²:

| Layout | Partial products | Largest column | Headroom |
|---|---|---|---|
| 16 limbs × 16 bits | 256 | 2^36 | 26 bits |
| 10 limbs × 26 bits | 100 | 2^55.32 | **~6.7 bits** |
| 10 limbs × 28 bits | 100 | 2^59.32 | ~2.7 bits — too thin once reduction adds terms |
| 9 limbs × 29 bits | 81 | 2^61.2 | under 1 bit — excluded |

So 26 and 28 use the *same* number of limbs and the same 100 products; 26 simply keeps
usable headroom. (An earlier draft called 28 "the fewest limbs that fit," which is
false — 9 × 29 fits in fewer, and is excluded on headroom, not on limb count.)

The tiebreaker is not arithmetic, though. This is the representation `libsecp256k1`
uses on 32-bit platforms, so the subtlest code in the project can be **cross-checked
element-by-element against a widely-audited implementation of the identical layout**
instead of being written and hoped at. On a project whose whole risk profile is silent
numerical wrongness, having something to diff against outranks both provenance with
`bits64.mdk` and a 2.5× constant factor §4 shows this workload never notices.

⚠️ **What that does *not* buy is the reference's overflow proof** — it assumes magnitude
≤ 8 and a full 64-bit accumulator we do not have. §4 sets out why eager normalization is
therefore load-bearing and why the magnitude-1 bounds are ours to derive. An earlier
draft of this section claimed the magnitude analysis could simply be followed; that was
wrong, and it was the most dangerous sentence in the document.

The instinct toward fewer partial products was right; it just isn't what settles it.

**Q3 — Durable firehose event storage? RESOLVED → P12** by observation rather than
decision: the ecosystem's relay backfill window is ~72 hours and `getRepo` handles full
resync independently, so a bounded on-disk log is both sufficient and small. Revisit at
Phase 5 against a real relay — this is empirical, and the number could move.

**Q4 — A read-only web view? RESOLVED → P13.** In, at Phase 4.5.

**Q5 — Streaming request bodies? RESOLVED → bounded buffering.** Phase 2 keeps
whole requests buffered so the pure synchronous seam stays all-engine. It caps
the combined header section at 64 KiB, JSON bodies at 150 KiB, text at 100 KiB,
and raw/blob bodies at 5 MiB; the outer request ceiling additionally bounds
framing overhead. `uploadBlob` is raw MIME input, not multipart. Revisit
streaming only from measured deployment pressure, at the Phase 3 socket boundary.

### Still open

- **Q6 — Where does the signing key live at rest?** Encrypted with a passphrase
  supplied at startup, or plaintext on a locked-down filesystem? The first needs a KDF
  and a symmetric cipher — more pure-Medaka crypto, none of which has a protocol-level
  answer key the way §5's gates do, which makes it a materially different risk from
  everything in Phase 0. Deferred to Phase 4, flagged now because it is the one piece
  of crypto in this document that G1 cannot grade.

---

## 8. Relationship to other work

This project is a **consumer** of the #500 and #820 arcs and must not fork either.
It is, however, an unusually good forcing function for both: a real server is the
first program that will exercise the async runtime's parking and readiness paths
under load, and a few thousand lines of `do`-over-`Async` is the largest test the
graded `do` routing (#824) will get. If sequencing allows, Phase 3 starting shortly
after #500 lands would surface runtime gaps while that context is still warm.

Beyond the async arcs it moves no compiler source and no goldens: `pds/` imports stdlib
and exports nothing back.

⚠️ **It is not, however, free of repo infrastructure.** `test/diff_compiler_ci_shard_coverage.sh`
enumerates **every tracked `.sh` in the repo**, so the first `pds/test/*.sh` gate reds a
`gates_N` executor row unless the gate is enrolled. ⚠️ **As written this paragraph describes
the PRE-#2176 wiring**: `ci.yml` no longer carries hand-written shard patterns at all. A gate
is enrolled by a `[[gate]]` entry in `test/gates.toml`; its `shard` is then a derived output of
measured cost and the matrix is regenerated by `make gen-ci`. Since G1–G5 are all oracle-diff
gates, **Phase 0's first PR needs that `ci.yml` edit**, or a
`test/CI-COVERAGE-EXCEPTIONS.txt` row with a reason. Budget it into the first slice
rather than discovering it in the merge queue.
