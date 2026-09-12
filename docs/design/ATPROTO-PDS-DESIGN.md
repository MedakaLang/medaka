# A self-hosted atproto PDS in Medaka

**Status:** ACTIVE (2026-09-09) — Phases 0–3 are complete in the current tree.
Phase 4 (#1697) has landed record CRUD, `applyWrites` as one signed commit,
session authentication, and the blob half (`uploadBlob`/`getBlob`/`listBlobs`
with on-disk persistence across restarts) — the Async v2 runtime arc (#500)
and the graded-interface work (#823/#824) that Phase 3 depended on are both
landed, so nothing in Phase 4 remains gated on them either. The bind is now
configuration (`--bind`, default `127.0.0.1`) rather than a literal, a
non-loopback bind is refused unless `--trusted-proxy` is also set (`#2757`,
accepted-risk plus this refusal — a peer-address extern was proposed and
declined), and `pds/Caddyfile` + `pds/pds.service` + `docs/ops/PDS-DEPLOY.md`
carry the deploy procedure — but no live deploy has happened: pointing a real
domain at a real key is a manual, deliberate act still to be taken. Backup and
restore are now rehearsed rather than merely described (`#2613`): §3.1 below
states the procedure's consistency rule and `docs/ops/PDS-DEPLOY.md`
§ "Backup and restore" carries the steps, with case 33 of
`pds/test/serve_e2e.sh` restoring a backup into a separate `--data` directory
and grading the server that starts on it. Still open, tracked separately rather
than blocking that act: `#2572` (the block store never collects unreferenced
blocks, and a stray non-directory file under the store directory hard-fails
startup), `#2773`/`#2774` (perf), `#2608` (firehose, Phase 5), and
`#1962` (the signing-parity oracle is nightly-only — confirm it green
immediately before a deploy). Multi-repository support stays out of scope
through 0.1.0 by design (§0, P14).

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
| **P12** | **Firehose events are persisted to a bounded append-only log, sized to a 259200s (72h) default sweep window** (landed, sprint `pds-a-relay-can-read-us`, `pds/lib/event_log_record.mdk` + `pds/shell/eventlog.mdk`). | Resolved from §7 Q3 by looking at what the ecosystem does rather than deciding a priori — the number stayed soft on purpose: 259200s (72h) is the **configurable default of the relay generation introduced in January 2026**, not a spec requirement and not a historical invariant (`atproto.com/specs/sync` states no retention window at all). The retention window is a parameter to the sweep, not baked into the record format or cursor arithmetic — demonstrated with an arbitrary 5000s bound in the slice's own acceptance run, independent of the shipped 259200s default. `getRepo` still covers full resynchronization independently of the log's retention. On-disk rather than in-memory specifically so a process restart does not invalidate a connected relay's cursor; startup recovery (`eventLogRecover`) closes the crash window between staging and promoting an entry. Operators can tune the default down (or up) with no code change. |
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
   thin, ~400 loc   │  over #500's async net surface          │  COMPLETE
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

### 3.1 Backup, restore, and the torn-copy hazard

**A file-level backup of `--data` must be taken with the server stopped (or from
an atomic filesystem or volume snapshot); the online alternative is to snapshot
the repository through the server's own request path
(`com.atproto.sync.getRepo`), which is serialized with writes and therefore
cannot observe a torn state** — because `applyRequest`'s indivisibility
(`pds/shell/server.mdk`) comes from routing every write through a single
`liftIO` in a cooperatively scheduled process, which is not a lock an external
`cp` can take.

The repository's CAR export is portable and consistent, and it is also *not a
complete backup*: blobs live beside the signed block graph rather than inside
it, and the three secrets (`--key`, `--token-secret`, `<data>/credential`) are
not in it either. So the procedure `docs/ops/PDS-DEPLOY.md` § "Backup and
restore" documents is the stopped-server file copy, with the CAR export as the
consistent online snapshot of the repository half and as the format a restore
into a different implementation would use. Case 33 of `pds/test/serve_e2e.sh`
rehearses the documented procedure end to end: a backup, a restore into a
SEPARATE `--data` directory, and a server started on the restored copy whose
`getRepo` export byte-matches the original's, serves both blobs under their
declared media types, and accepts a new signed write.

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
- `stdlib/sha256.mdk` — straightforward 32-bit-word FIPS 180-4. The easiest module
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

Account bootstrap and `createSession` (both landed, §6 Phase 4) need to turn a
user password into a storable credential without keeping the password itself. Chosen
algorithm: **PBKDF2-HMAC-SHA-256** (`stdlib/pbkdf2.mdk`), not scrypt/argon2/bcrypt —
this server signs and serves one account, so there is no attacker-throughput budget
that a memory-hard KDF is defending against, and PBKDF2-HMAC-SHA-256 reuses the
already-audited `stdlib/sha256.mdk` rather than adding a new primitive family. It is
also RFC-vectored (RFC 7914 §11), keeping it inside G1's cross-implementation-agreed
corpus discipline rather than resting on a self-captured golden (G5).

The salt is always caller-supplied — `pbkdf2HmacSha256` draws no entropy and does no
I/O itself; salt generation is the shell layer's job, in the slice that wires up
account bootstrap.

**Iteration count: 3,000, against a 500 ms login-latency budget. The OWASP floor is
not reached, and the residual gap is 200x.**

*Measurement (2026-09-09, this box: Debian 13, 12-core/32GB; `medaka build`, 32-byte
`dkLen`, one process per sample, three samples per count).* Wall time for a single
`pbkdf2HmacSha256` over a 28-character password and a 16-byte salt:

| iterations | samples (ms) | median ms/iteration |
|---|---|---|
| 1,000 | 246.3 / 222.8 / 209.4 | 0.223 |
| 2,000 | 469.4 / 514.9 / 317.4 | 0.235 |
| 4,000 | 560.5 / 601.6 / 859.1 | 0.150 |
| 8,000 | 1556.8 / 1371.5 / 1352.8 | 0.171 |
| 16,000 | 2809.6 / 2360.7 / 2166.3 | 0.148 |

Subtracting the 4,000 median from the 16,000 median removes the fixed per-process
cost and gives the marginal figure this count is chosen from: **0.147 ms per
iteration**, ≈6,800 iterations/s. (The small counts read *higher* per iteration
because process start and heap growth are amortized over fewer iterations, not
because the loop is superlinear.)

*The budget.* 500 ms per derivation, chosen as a **login-latency** budget rather than
the bootstrap budget the previous count was set against. The derivation now runs
inside `applyRequest`'s single indivisible sequence (`pds/shell/server.mdk`), so it is
also the time one `com.atproto.server.createSession` attempt — including a WRONG one —
blocks every other connection for. `maxCreateSessionPerWindow` is 30 per 60 s per
identity (`pds/lib/resource_limits.mdk`), so at the 500 ms budget one identity can
hold the server for **15 s of each minute**, and at the chosen count's measured
~440 ms for **~13 s**. Two things sharpen that further, and both are load-bearing:
the derivation is inside an indivisible sequence, so those seconds are the whole
single-threaded server, not one connection's share of it; and **without
`--trusted-proxy` every caller shares the one `"direct"` identity bucket** (see
"The identity a request is charged against", below), so the 30 are 30 logins *in
total* — wrong passwords
included — and any client can spend them. The budget is set where that stays a
fraction rather than a majority of the window; it does not make it a small one.

*The chosen count.* 0.147 ms × 3,000 = **~440 ms**, the largest round count inside the
budget. `defaultIterations = 3000` (`pds/lib/credential.mdk`), pinned by a cell in
`pds/test/credential_test.mdk`.

*The residual gap.* OWASP's floor for PBKDF2-HMAC-SHA-256 is 600,000 iterations, which
at 0.147 ms/iteration is **~88 s per login** here — 200x the chosen count, and about
176x the whole login budget. **The floor is unreachable by tuning and the gap is not
closed by this change.** What closes it is a native SHA-256 (an `extern`, or an
emitter that vectorizes the compression function): the gap is entirely the cost of a
pure-Medaka block function, not of PBKDF2's structure. Until then this count is what
the implementation can afford, and is not a security recommendation. Anyone deploying
this behind a public origin should read it as: an attacker who steals
`<data>/credential` recovers a weak password 200x faster than against a
floor-compliant server.

*Migration.* A record carries the count it was derived at, so raising the constant
locks nobody out. A stored record derived at any other count is re-derived onto the
current one by **one successful login** (`credentialUpgrade`, `pds/lib/credential.mdk`;
called from `applyCreateSession` and persisted by `persistCredentialHalf`). A FAILED
login never rewrites the record: `credentialUpgrade` grades the password itself and
returns nothing without it, so the property holds at the function rather than at its
call site.

### 4.2.1 Secrets at rest, through 0.1.0

**Ruling (Q6): the signing key and the session-token secret are stored in PLAINTEXT,
protected by filesystem permissions alone.** Every secret file this server writes is
mode `0600`, and every secret file it reads at any wider mode is refused before the
listener binds.

Passphrase encryption at rest is **deferred past 0.1.0**, deliberately. It needs a KDF
and a symmetric cipher written in pure Medaka with no protocol-level answer key to
grade either against — the opposite of the corpus discipline every other primitive
here rests on (G5) — and it defends a threat model a single-operator server behind
Caddy does not face: an attacker who can read `<data>/key.hex` as its owner is already
the operator, and one who cannot read it gains nothing from its being encrypted at
rest by a passphrase that would have to live on the same box to start unattended.

*Rotating the signing key.* Rotating it changes the account's `did:key`, so it is an
identity change, not a maintenance operation — the DID document must be updated and
every other implementation on the network re-resolves it. The procedure:

1. `pds keygen --key <data>/key.hex.new` — writes a new scalar at `0600` and prints
   the compressed public key and the `did:key` it will be known by.
2. Update the account's DID document to name that `did:key`, and wait for it to
   propagate.
3. Stop the server, `mv <data>/key.hex.new <data>/key.hex`, restart.

`keygen` refuses to write over an existing file, so step 1 cannot destroy the running
key by a typo.

*Rotating the session-token secret.* This is a maintenance operation and costs only
the open sessions: every token this server has issued is verified against it, so
replacing it logs everybody out and nothing else.

1. `pds keygen --token-secret <data>/session-secret.new`.
2. Stop the server, `mv <data>/session-secret.new <data>/session-secret`, restart.

*Rotating the account password.* `serve` refuses `--password-file` against a data
directory that already holds a credential rather than rotating in place: remove
`<data>/credential` and start once with `--password-file`.

*What is graded, and what is not.* A supplied `--token-secret` is refused when it
carries fewer than 8 distinct byte values across its 32 (`admitSessionSecret`,
`pds/serve.mdk`) — 32 random bytes carry ~28, and fewer than 8 with probability far
below 1 in 2^60, so this refuses a placeholder without ever refusing a real secret. It
is a non-entropy detector, not an entropy estimator: it cannot tell a low-entropy
passphrase hex-encoded to 32 bytes from a generated one.

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

**Secrets at rest are owner-only, and a wider one is refused rather than warned
about.** The generated session secret and the stored credential record are written
through `io.writeFilePrivate` over the `writeFileMode` primitive, which sets the mode
on the open descriptor before the first byte is written — so the contents never exist
at a wider mode, and neither the process umask nor a pre-existing file's own mode can
widen them. In the other direction, `pds/serve.mdk` grades every hex secret file it
READS (`--key` and `--token-secret`) with `fileMode` and refuses to start when any
account but the owner can read one: a signing key the rest of the box can read has
already been exposed, and serving anyway would hide that. The refusal names the path
and the mode and never the contents. Encryption at rest is a separate question and is
deferred past 0.1.0: these are plaintext files under restrictive permissions.

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
Phase 2 core: request framing via `scanRequestBoundary`, `headerTimeout`/
`bodyProgressTimeout`/`requestTimeout`/
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

**Loopback by default, and a non-loopback bind is a deliberate act.** `--bind`
(`pds/serve.mdk`) defaults to `127.0.0.1`; a bind to anything else is refused
before any secret is read or generated and before the listener binds, unless
`--trusted-proxy` is also given (`requireTrustedBind`, `#2757`) — see the
paragraph below for why that flag is the enforcement rather than a peer-address
check this process could make instead. §4.2-4.4 below describe the auth seam
this server now has: the three record writes and `getSession` require a valid
access token, `refreshSession`/`deleteSession` require a valid refresh token,
`createSession` is the public login that issues both, and the six reads,
`resolveHandle`, and the two well-knowns stay public. TLS is never
implemented here (P5) — Caddy terminates it and reverse-proxies to the
loopback port, which is the deployment `docs/ops/PDS-DEPLOY.md` describes.

**Phase 4 — a standalone PDS.** *Landed in the current tree (#1697), including
the configurable bind, the refusal, and the deployment artifacts
(`pds/Caddyfile`, `pds/pds.service`, `docs/ops/PDS-DEPLOY.md`) — except the
live deploy itself, which is a manual act still to be taken.*

Shipped, all in `pds/lib/handlers.mdk` as pure functions over the Phase-2 seam,
composed under the Phase-3 shell's auth seam (§ above): record CRUD
`createRecord`/`putRecord`/`deleteRecord`/`getRecord`/`listRecords` (with
`limit`/`reverse`/`cursor`), `applyWrites` (batches the three single-record
writes into one signed commit — see P14 below), `describeRepo`,
`com.atproto.sync.getRepo`/`getLatestCommit`,
`com.atproto.identity.resolveHandle`, the `did:web` identity document at
`/.well-known/did.json`, `/.well-known/atproto-did`, session auth
(`createSession`/`refreshSession`/`deleteSession`/`getSession`, #2604), and the
blob half: `uploadBlob`/`getBlob`/`com.atproto.sync.listBlobs`, admitted by
`pds/lib/blob.mdk`'s `admitBlob` and persisted to disk by
`pds/shell/blobfile.mdk` (§ P14 below) across restarts. The two well-knowns
are their own explicitly-typed route class in `pds/lib/xrpc.mdk`, not
synthesized NSIDs, and reach the handler through the same `routeRequest`/
`handle` seam as every XRPC method. `sync.getRepo` returns `repoExportCar`'s
bytes verbatim, graded byte-for-byte against the provenance-pinned corpus.

Deliberately NOT shipped, and each refused rather than faked: lexicon record
validation (`validate: true` is refused), `describeRepo`'s `didDoc` (no DID
resolver, so any document would be invented), `sync.getRepo`'s `since` (no
incremental sync), and `validationStatus`.

**Read-path cost bounds (#2478).** Every read route above is a `PublicRoute` —
unauthenticated by the atproto spec, not by omission — so the cost of serving
one is a cost a stranger chooses. Three of them once did work proportional to
the whole account per response. `listRecords` selects on the MST's paths and
reads a record's block only for the entries it actually returns; `describeRepo`
answers `collections` from paths alone; and `listBlobs` lists CIDs through a
byte-free blob-half view instead of copying every blob. The paths themselves are
still walked, because `lib.mst` holds its entries as a flat sorted list with no
range query, so a page still costs one cheap pass over the account's keys — a
smaller residual, tracked separately, not the byte-proportional cost #2478 named.

`com.atproto.sync.getRepo` is the exception, and deliberately so: **a full CAR
export is inherently proportional to the repository, and the only bound
available is how often it may be called.** The endpoint's contract is the whole
repository as one CAR, so no per-request bound short of refusing the route can
make it sublinear; and the P14 seam is
`handle : Server -> Store -> Request -> (Store, Response)`, which returns a
`Response` **value**, so streaming the CAR is not expressible in the pure core
at all — it would require the response to become a stream the shell pulls from,
i.e. abandoning the seam that makes the core all-engine and doctestable. What
bounds `getRepo` is therefore rate limiting alone: the per-identity request
allowance #2612 installs, with `maxCarBytes` (64 MiB,
`pds/lib/resource_limits.mdk`) capping any single export. A deployment that
exposes this server past loopback must have that limiter in place; `getRepo`
without it is an unauthenticated request for the entire account, repeatable.

**Rate limiting: what Caddy does and what this process does (#2612).** Caddy
(P5) terminates TLS and reverse-proxies plaintext HTTP to the Medaka process
on localhost; it never sees an atproto identity, an NSID, or a session — only
connections and bytes. That is exactly the layer a blunt, protocol-blind
ceiling belongs at (a global connection/rate cap, independent of who is
asking or what they are asking for), and it is Caddy's job, not this
process's: nothing in `pds/` reimplements it. What this process owns is the
opposite half — a limit that KNOWS the caller's identity and the request's
class, which no reverse proxy in front of it can. `pds/shell/server.mdk`
charges every request against a `RateLimitState` (`pds/lib/ratelimit.mdk`)
kept in one fixed window (`rateLimitWindowSeconds`, `pds/lib/
resource_limits.mdk`) per five independent classes: a `ConnectionsClass`
charge on a connection's first framed request, a `RequestsClass`
charge on every framed request, and three narrower classes layered
on top of `RequestsClass` rather
than replacing it — `WritesClass` for the write NSIDs (`createRecord`,
`putRecord`, `deleteRecord`, `applyWrites`, `uploadBlob`),
`CreateSessionClass` for `createSession` alone, since login attempts are a
credential-guessing surface every other route is not, and `RepoExportClass`
for `sync.getRepo` alone, whose single response is a whole-repository CAR
bounded only by `maxCarBytes` — a count of requests cannot bound what that
route emits, so `maxRepoExportsPerWindow` names the egress ceiling
separately. A refusal answers 429
with `error: "RateLimitExceeded"` and the IETF `RateLimit-*` response
headers (`ratelimit-limit`, `ratelimit-remaining`, `ratelimit-reset`) naming
the exceeded class's own ceiling, not a blended figure.

"Framed" is the load-bearing qualifier in that paragraph, and it is where
this half of the limiter stops: a charge is taken the moment a request
boundary is reached, whether or not the bytes inside it parse. What a charge
cannot always have is a per-identity bucket to go in, since an identity comes
from a header and a header only exists once a request parsed. So a request
that fails to frame or parse is answered 400 and, having produced no identity
to charge, is attributed to the shared `"direct"` bucket rather than to its
sender; that bounds the channel globally without pretending to know who used
it, which is defensible for malformed traffic precisely because malformed
traffic is not the shape a legitimate client has. One shape falls outside
every class entirely: a connection that never completes a request is
accepted, occupies a slot against `maxConcurrentConnections`, and is charged
nothing — enough of them deny service to every other caller (#2772), which
is why a read deadline, not a counter, is what closes that shape.

**The availability target the connection ceilings answer to (#2816).** Under a
flood from one unidentifiable source, **64 concurrent legitimate callers must
still be answered within 15 seconds**. That sentence is the design intent both
ceilings are derived from, and it is what to re-derive them from: raising the
caller count or lowering the time bound is a change to these two numbers and to
no other constant here. `headerTimeout` (5 s) and `bodyProgressTimeout` (5 s)
are the turnover half of it — a slot an attacker holds is released within one
of them, whichever phase it is stalling in, both inside the target's 15 s even
when a legitimate caller has to wait out one turnover.

**The target is NOT currently met, and `maxUnframedConnections` is why.**
`maxUnframedConnections` (64) is not a carved-out share of
`maxConcurrentConnections` (256): it is an independent ADMISSION GATE ahead of
it. `acceptStep` (`pds/shell/server.mdk`) charges every accepted connection to
the un-framed census before it has been read from, and refuses admission when
EITHER ceiling is full — the two are disjoined, not summed. So once 64
connections sit in the un-framed state, the 65th connection is closed without a
read no matter how much of the 256 is free, and it makes no difference whether
that 65th caller is legitimate. An un-framed connection carries no identity, so
it reaches no rate-limit class and the attacker pays nothing to hold the gate;
because the released slot is immediately re-takeable, a single source that
reconnects as its connections time out can hold the gate shut indefinitely.
Measured: ~70 header-stalled sockets from one source (just over the 64 cap) cut
a legitimate prober to 1 answered request against 229 connection resets; at 280
stalled sockets, none succeeded. The cheaper cap is therefore the denial, which
is #2816's own open scope — the remaining work there is a ceiling that
distinguishes sources (e.g. a per-source cap on un-framed connections) so that
one source cannot spend the whole census.

The body-phase half of this IS fixed: a connection that terminates its headers
and then stalls over a body that never arrives is closed by
`bodyProgressTimeout`, so a mixed or pure body-stall flood does not hold
capacity. That fix does not close #2816, because the admission gate is reached
before any of it runs.

One fixed window per identity also bounds the AVERAGE rate over a window,
not the instantaneous one: because the window index is derived from the
absolute epoch, an identity can spend a full allowance just before a
boundary and a second full allowance just after it, so the worst-case burst
is twice the nominal ceiling in an arbitrarily short interval (#2775).
Capacity planning should read the ceilings here as "per window, and up to
twice that across a boundary." A token bucket removes the boundary; the
fixed window is kept for now because its per-identity state is a counter and
a window index, which is what makes it cheap to reason about and to test.

The identity a request is charged against comes from the last hop of
`X-Forwarded-For` — but ONLY when the operator passes `--trusted-proxy`,
asserting that this process's peer IS the configured reverse proxy (Caddy,
in the deployment this document describes). There is no way for this
process to verify that assertion itself (no `getpeername`-equivalent in
this runtime); without the flag, every request is charged against one
shared `"direct"` identity bucket regardless of its source address. That
default is chosen because the alternative is worse, not because it is
without cost: a forwarded-for header trusted by default would let any client
claim any identity's budget for itself, or spend a stranger's. The cost it
does carry should be stated plainly, because it inverts the property this
half of the limiter exists for — with one bucket for every caller, all five
ceilings are process-wide rather than per-client, so the first caller to
reach one refuses every other caller until the window turns. A per-identity
limiter that cannot distinguish identities is a global limiter. Nothing in
this runtime can close that gap from here: identifying an unproxied caller
needs its peer address, which this runtime cannot obtain — there is no
`getpeername`-equivalent extern, and adding one is not the fix, since under
Caddy on the same box a socket peer address reads `127.0.0.1` regardless of
who is really asking, so the last `X-Forwarded-For` hop is already the
better identity available. `#2757` closes as accepted-risk on that basis,
plus the refusal `requireTrustedBind` (`pds/serve.mdk`) now enforces: **a
direct, unproxied non-loopback bind is unsupported** — `configure` refuses to
start one at all, so the "whole world sharing one bucket" state described
above can only be reached by a deployment that has itself already asserted
`--trusted-proxy` while lacking a real proxy, which the flag's own name
argues against. `pds/README.md` documents the operator-facing half of this:
when to pass the flag and what happens without it.

**Blob-storage policy (P14).** One blob per file under `<data>/blobs`, a
sibling of (never inside) the repository's `<data>/blocks`, sharded on the
first byte of the CID's multihash digest exactly like the block store —
`<shard>/<cid hex>` for the bytes, `<shard>/<cid hex>.mime` for a sidecar
recording the declared MIME type, since content addressing verifies bytes,
not the type declared for them. Both files stage under `.staging` and are
promoted by `rename`, MIME sidecar first, bytes last, so a reader — which
keys on the bytes file — never observes a blob whose declared type is
missing; a crash between the two leaves an orphan sidecar, treated as
residue, not corruption. Caps are enforced once, at admission
(`admitBlob`): `maxBlobBytes` (5 MiB, deliberately equal to the framing
layer's raw-body cap) per blob, `maxAccountBlobBytes` (100 MiB, a first
policy choice pending real storage-cost numbers) per account. Nothing
collects an unreferenced blob — a blob no record references survives every
restart until removed by hand; GC is a protocol question (which references
count, and when an expected-but-not-yet-existing reference stops being
expected), not a filesystem one, and is tracked separately (#2572, GC still
open; the stray-file-naming half of that issue is discharged for blob code
but not yet for the original block store). Full account: `pds/shell/blobfile.mdk`'s
module doc.

**Multi-repository (P14).** This server hosts exactly one account
(`makeAccount`, `storeFromRepo`, and the `Server` seam are single-account by
construction) and stays that shape through 0.1.0 — no slice implemented
multi-repository either way, and no note since has overturned it.

Still owed: deployment behind Caddy under systemd. **That is the first point
with a running, useful, externally reachable artifact.**

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

**Q3 — Durable firehose event storage? RESOLVED → P12**, landed in sprint
`pds-a-relay-can-read-us`, by observation rather than decision: the ecosystem's relay
backfill window is 259200s (72h) and `getRepo` handles full resync independently, so a
bounded on-disk log is both sufficient and small. The 259200s figure ships as a default,
not a constant — the retention comparison is a parameter to the sweep, exercised at a
different bound (5000s) in the slice's own acceptance evidence, so moving it at any
future Phase needs no code change, only a config value.

**Q4 — A read-only web view? RESOLVED → P13.** In, at Phase 4.5.

**Q5 — Streaming request bodies? RESOLVED → bounded buffering.** Phase 2 keeps
whole requests buffered so the pure synchronous seam stays all-engine. It caps
the combined header section at 64 KiB, JSON bodies at 150 KiB, text at 100 KiB,
and raw/blob bodies at 5 MiB; the outer request ceiling additionally bounds
framing overhead. `uploadBlob` is raw MIME input, not multipart. Revisit
streaming only from measured deployment pressure, at the Phase 3 socket boundary.

**Q6 — Where does the signing key live at rest? RESOLVED → plaintext at `0600`,
through 0.1.0.** Passphrase encryption needs a KDF and a symmetric cipher with no
protocol-level answer key to grade either against, for a threat model a
single-operator server behind Caddy does not face. The ruling, what it does and does
not protect, and the rotation procedure for each of the three secrets: §4.2.1.

### Still open

None. Q6 was the last, and §4.2.1 rules it.

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
