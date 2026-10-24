# Docs index

<!-- GENERATED — do not edit by hand; run `make docs-index`
     (test/gen_docs_index.sh). Regenerating after a doc move/add/rename is a
     no-op if nothing changed: same input -> byte-identical output. -->

Fast lookup for an agent (or human) trying to find the right doc. Each row
leads with the doc, then a one-line summary and its current status (pulled
straight from the doc's own `**Status:**` banner — this table cannot drift
from what the doc says about itself). **PARTIAL/OPEN work is live; a doc
under `archive/` is IMPLEMENTED/SUPERSEDED and kept for provenance, not
current guidance.**

Root entry points (not indexed below — always here): [`README.md`](../README.md)
(build/test/CLI), [`AGENTS.md`](../AGENTS.md) (agent orientation, router),
[`PLAN.md`](../PLAN.md) (open roadmap). Session-handoff state lives in GitHub
issues (`known-red` label for expected-red gates), not in a doc.

### docs/ — top level

Docs that sit directly in `docs/`, above the subject folders below.

| Doc | What it is | Status |
|-----|------------|--------|
| [`KNOWN-GAPS.md`](KNOWN-GAPS.md) | Known gaps — accepted-vs-rejected boundary | living, seeded |

### spec — language ground truth

What parses, what it means, formal semantics. Read here first for "does X exist / what does X mean".

| Doc | What it is | Status |
|-----|------------|--------|
| [`DICT-SEMANTICS.md`](spec/DICT-SEMANTICS.md) | Dictionary-Passing Semantics for Medaka Interfaces | specification |
| [`EFFECTS-SEMANTICS.md`](spec/EFFECTS-SEMANTICS.md) | Effect-and-Capability Semantics for Medaka | specification |
| [`EMITTER-SEMANTICS.md`](spec/EMITTER-SEMANTICS.md) | Native-Emitter Semantics: the Refinement Contract | specification |
| [`HM-CORE-SEMANTICS.md`](spec/HM-CORE-SEMANTICS.md) | Hindley–Milner Core Semantics (unqualified fragment) | DRAFT |
| [`LAYOUT-SEMANTICS.md`](spec/LAYOUT-SEMANTICS.md) | LAYOUT-SEMANTICS.md — Medaka's layout rule, formalized | OPEN |
| [`SHADOW-SEMANTICS.md`](spec/SHADOW-SEMANTICS.md) | Declaration-Shadowing Semantics (standalone fn ⇄ interface method) | ENFORCED |
| [`STYLE.md`](spec/STYLE.md) | Medaka style guide | — |
| [`SYNTAX.md`](spec/SYNTAX.md) | SYNTAX.md — Medaka construct cheat-sheet | — |
| [`WASM-SEMANTICS.md`](spec/WASM-SEMANTICS.md) | WasmGC Backend Semantics: the physical-encoding + host-boundary supplement | specification |
| [`language-design.md`](spec/language-design.md) | Medaka Language Design Document | PARTIAL |

### guide — learning path

Tutorial-style onboarding, not a spec. Not yet cross-linked into this index's status convention (no banners) — this is prose-in-progress, read for teaching order, not ground truth.

| Doc | What it is | Status |
|-----|------------|--------|
| [`00-introduction.md`](guide/00-introduction.md) | Introduction | — |
| [`01-quick-start.md`](guide/01-quick-start.md) | Quick Start | — |
| [`02-expressions.md`](guide/02-expressions.md) | Values, Bindings & Types | — |
| [`03-functions.md`](guide/03-functions.md) | Functions | — |
| [`04-data-modeling.md`](guide/04-data-modeling.md) | Data Modeling | — |
| [`05-interfaces.md`](guide/05-interfaces.md) | Interfaces | — |
| [`06-working-with-data.md`](guide/06-working-with-data.md) | Working with Data | — |
| [`07-effects-and-io.md`](guide/07-effects-and-io.md) | Effects & IO | — |
| [`08-do-and-thenables.md`](guide/08-do-and-thenables.md) | `do` and Thenables | — |
| [`09-modules-and-projects.md`](guide/09-modules-and-projects.md) | Modules & Projects | — |
| [`10-tooling-and-workflow.md`](guide/10-tooling-and-workflow.md) | Tooling & Workflow | — |
| [`OUTLINE.md`](guide/OUTLINE.md) | Medaka Guide — Outline | — |
| [`haskell-ocaml-delta.md`](guide/haskell-ocaml-delta.md) | For Haskell and OCaml Readers | — |

### advanced — one topic at a time, in depth

The guide's sequel: each topic (effects first) is a run of chapters that starts from what the guide taught. Executable docs like the guide — every example is compiled by `check_syntax_examples`, and run where it declares its output.

| Doc | What it is | Status |
|-----|------------|--------|
| [`00-about.md`](advanced/00-about.md) | Advanced Topics | — |
| [`effects-1-rows.md`](advanced/effects-1-rows.md) | Effects I: What the Row Says | — |
| [`effects-2-polymorphism.md`](advanced/effects-2-polymorphism.md) | Effects II: Effect Polymorphism | — |
| [`effects-3-labels.md`](advanced/effects-3-labels.md) | Effects III: Labels, Manifests, and the Host | — |
| [`effects-4-authority.md`](advanced/effects-4-authority.md) | Effects IV: Parameters and Authority | — |
| [`effects-5-data.md`](advanced/effects-5-data.md) | Effects V: Authority in Data | — |
| [`effects-6-indexed.md`](advanced/effects-6-indexed.md) | Effects VI: Effect-Indexed Types | — |
| [`effects-7-reference.md`](advanced/effects-7-reference.md) | Effects VII: Reference and Open Edges | — |
| [`playground-animation.md`](advanced/playground-animation.md) | Canvas Animation in the Playground | — |

### design — open/partial work

Live design docs: **OPEN** = not started, **PARTIAL** = in progress. Read before touching the area; update the doc when you close it (then it moves to `archive/design/`).

| Doc | What it is | Status |
|-----|------------|--------|
| [`ARGS-DESIGN.md`](design/ARGS-DESIGN.md) | ARGS-DESIGN.md — one argument parser for sixteen verbs | DECIDED |
| [`ASYNC-RUNTIME-DESIGN.md`](design/ASYNC-RUNTIME-DESIGN.md) | Async runtime v2 — the ASYNC-DESIGN §5 swap | IMPLEMENTED 2026-09-02 |
| [`AT-IMPL-PORT-DESIGN.md`](design/AT-IMPL-PORT-DESIGN.md) | `@Impl` Named-Instance-Selection Hint — Native Port Design | SUPERSEDED |
| [`ATPROTO-PDS-CONSTANT-TIME.md`](design/ATPROTO-PDS-CONSTANT-TIME.md) | atproto PDS field/scalar constant-time reduction contract | implemented and landed for #1724 |
| [`ATPROTO-PDS-DESIGN.md`](design/ATPROTO-PDS-DESIGN.md) | A self-hosted atproto PDS in Medaka | ACTIVE |
| [`ATPROTO-PDS-SIGNING-CONTRACT.md`](design/ATPROTO-PDS-SIGNING-CONTRACT.md) | atproto PDS native signing and public-key contract | accepted implementation contract for #1700, prerequisite #1877 |
| [`ATPROTO-PDS-VIDEO-DESIGN.md`](design/ATPROTO-PDS-VIDEO-DESIGN.md) | atproto PDS: accepting video uploads | implemented for slices 1, 2 and 4 of sprint `pds-video-upload` |
| [`BYTES-DESIGN.md`](design/BYTES-DESIGN.md) | Bytes — a packed byte string for Medaka | B1, B2 and B3 have all shipped |
| [`CAPABILITY-EFFECTS.md`](design/CAPABILITY-EFFECTS.md) | Capability-safe effects — Medaka's headline direction | PARTIAL |
| [`CAPABILITY-PLATFORM.md`](design/CAPABILITY-PLATFORM.md) | The capability platform — runtime/product architecture | OPEN |
| [`D3-DEFAULTING-DESIGN.md`](design/D3-DEFAULTING-DESIGN.md) | Numeric defaulting at a multi-parameter goal — the D3 rule, determination, and the settle sequence | design pass, 2026-10-03/04 |
| [`EFFECTS-CONFORMANCE-ROADMAP.md`](design/EFFECTS-CONFORMANCE-ROADMAP.md) | Effect-and-Capability Conformance Roadmap | PARTIAL |
| [`EFFECTS-ISSUE-ARCHITECTURE-REVIEW.md`](design/EFFECTS-ISSUE-ARCHITECTURE-REVIEW.md) | Effects issues against the architecture | REVIEWED |
| [`EQ-DISPATCH-DESIGN.md`](design/EQ-DISPATCH-DESIGN.md) | `==`/`/=` → `Eq` Dispatch (Option A) — Design + Blast-Radius Census | OPEN |
| [`GAP3-SLICE7-DESIGN.md`](design/GAP3-SLICE7-DESIGN.md) | Gap 3 — slice-7 arg-tag dispatch on a generic prelude free function | OPEN |
| [`GZIP-DESIGN.md`](design/GZIP-DESIGN.md) | DEFLATE / gzip — a compression codec in pure Medaka | PARTIAL |
| [`INTEGER-TYPES-DESIGN.md`](design/INTEGER-TYPES-DESIGN.md) | The integer stack | — |
| [`INTERFACE-CANDIDATES.md`](design/INTERFACE-CANDIDATES.md) | INTERFACE-CANDIDATES.md — which built-in constructs could generalize behind an interface | PARTIAL |
| [`LANGUAGE-SURFACE-AUDIT.md`](design/LANGUAGE-SURFACE-AUDIT.md) | LANGUAGE-SURFACE-AUDIT.md | OPEN |
| [`MESSAGE-AUDIT.md`](design/MESSAGE-AUDIT.md) | MESSAGE-AUDIT.md | PARTIAL |
| [`MUT-SCOPING-DESIGN.md`](design/MUT-SCOPING-DESIGN.md) | `<Mut>` scoping — effect masking for allocate→fill→freeze | CLOSED |
| [`PERF-CI-COVERAGE.md`](design/PERF-CI-COVERAGE.md) | PERF-CI-COVERAGE.md — a comprehensive design for catching quadratics in CI | DESIGN |
| [`REFERENCES-RENAME-DESIGN.md`](design/REFERENCES-RENAME-DESIGN.md) | Cross-file `references` + `rename` (#254) — Design / Scoping | DESIGN |
| [`REGEX-DESIGN.md`](design/REGEX-DESIGN.md) | Regular expressions in the stdlib | — |
| [`REVIEW-WORKFLOW-DESIGN.md`](design/REVIEW-WORKFLOW-DESIGN.md) | Review workflow: a cheap reviewer and the benchmark that measures it | — |
| [`RUNTIME-TRAP-UNIFY-DESIGN.md`](design/RUNTIME-TRAP-UNIFY-DESIGN.md) | Runtime-trap-format unification — design | OPEN, but the `Array.set`/`Vector.set` OOB row is discharged: `setInPlace` |
| [`SOURCE-POSITION-DESIGN.md`](design/SOURCE-POSITION-DESIGN.md) | SOURCE-POSITION-DESIGN.md — principled, unified line:column (source-span) tracking; #331 as increment 1 | DESIGN |
| [`STYLE-RUBRIC.md`](design/STYLE-RUBRIC.md) | Style rubric | — |
| [`STYLE-RULINGS.md`](design/STYLE-RULINGS.md) | Style rulings | — |
| [`TARGETS-DESIGN.md`](design/TARGETS-DESIGN.md) | Targets and host profiles | ratified 2026-10-01; the host-binding half |
| [`TEST-SIBLING-ACCESS-DESIGN.md`](design/TEST-SIBLING-ACCESS-DESIGN.md) | Test siblings see their subject's private names | DECIDED 2026-10-18 |
| [`TYPE-AWARE-LINT-DESIGN.md`](design/TYPE-AWARE-LINT-DESIGN.md) | Type-Aware Lint Tier — Design | PARTLY SHIPPED and RE-COSTED; TIER 1 UNBLOCKED, TIER 2 STILL BLOCKED |
| [`WASM-ASYNC-DESIGN.md`](design/WASM-ASYNC-DESIGN.md) | Async on the WasmGC target | PARTIAL |

### ops — release, testing, distribution

Cross-cutting process docs: how the test suite is organized, how a build ships, what's left before 0.1.0.

| Doc | What it is | Status |
|-----|------------|--------|
| [`CI-ARCHITECTURE.md`](ops/CI-ARCHITECTURE.md) | CI-ARCHITECTURE.md — target architecture for Medaka's CI | PARTLY BUILT |
| [`CLI-CONFORMANCE.md`](ops/CLI-CONFORMANCE.md) | CLI-CONFORMANCE.md — the ratified `medaka` command-line contract | RATIFIED |
| [`COMPILER-PROPERTY-TESTING.md`](ops/COMPILER-PROPERTY-TESTING.md) | Compiler property testing | — |
| [`DISTRIBUTION-DESIGN.md`](ops/DISTRIBUTION-DESIGN.md) | DISTRIBUTION-DESIGN.md — shipping a native `medaka` binary to strangers | PARTIAL |
| [`EDGE-DEPLOY.md`](ops/EDGE-DEPLOY.md) | Deploying a Medaka program to Cloudflare Workers | — |
| [`EFFECTS-REARCHITECTURE-HANDOFF.md`](ops/EFFECTS-REARCHITECTURE-HANDOFF.md) | Effects rearchitecture session handoff | The arrow half |
| [`GATE-REGISTRY-DESIGN.md`](ops/GATE-REGISTRY-DESIGN.md) | GATE-REGISTRY-DESIGN.md — the gate registry format and `medaka gate` driver | LANDED |
| [`MCP.md`](ops/MCP.md) | MCP.md — `medaka mcp`, the LSP-for-agents | IMPLEMENTED |
| [`PDS-B14-ATTACK-LIST.md`](ops/PDS-B14-ATTACK-LIST.md) | PDS B14 running-instance attack list | — |
| [`PDS-CONFORMANCE-WALKTHROUGH.md`](ops/PDS-CONFORMANCE-WALKTHROUGH.md) | PDS-CONFORMANCE-WALKTHROUGH.md — criterion A8, run by hand from the official app | written ahead of the first G-QUIET deploy |
| [`PDS-CRYPTO-CLAIMS.md`](ops/PDS-CRYPTO-CLAIMS.md) | PDS-CRYPTO-CLAIMS.md — what the PDS cryptography claims, and what it does not | written for G-ANNOUNCE |
| [`PDS-DEPLOY.md`](ops/PDS-DEPLOY.md) | PDS-DEPLOY.md — deploying `pds serve` behind Caddy under systemd | IMPLEMENTED and DEPLOYED |
| [`PDS-LAUNCH-PLAN.md`](ops/PDS-LAUNCH-PLAN.md) | PDS-LAUNCH-PLAN.md — the road to "this account runs on a PDS written in Medaka" | OPEN |
| [`PDS-ORACLE.md`](ops/PDS-ORACLE.md) | PDS-ORACLE.md — running the official Bluesky PDS locally as the Phase 0/1 oracle | IMPLEMENTED |
| [`PDS-RUNBOOK.md`](ops/PDS-RUNBOOK.md) | PDS-RUNBOOK.md — the release ritual for a PDS deploy | written ahead of the first G-QUIET deploy |
| [`PR-HELPER.md`](ops/PR-HELPER.md) | PR-HELPER.md — `scripts/pr.sh`, the verified PR lifecycle helper | IMPLEMENTED |
| [`RELEASE-0.1.0-PLAN.md`](ops/RELEASE-0.1.0-PLAN.md) | RELEASE-0.1.0-PLAN.md — the road to a public 0.1.0 preview | OPEN |
| [`TESTING-ARCHITECTURE.md`](ops/TESTING-ARCHITECTURE.md) | TESTING-ARCHITECTURE.md — the target testing architecture, and the migration to it | PROPOSED 2026-09-03, from a two-round survey at `5397afc9c` |
| [`TESTING-DESIGN.md`](ops/TESTING-DESIGN.md) | TESTING-DESIGN.md — a coherent testing architecture for Medaka | SUPERSEDED as a plan, 2026-09-03 |
| [`TESTING-INVENTORY.md`](ops/TESTING-INVENTORY.md) | TESTING-INVENTORY.md — which gates can be native today, and what blocks the rest | — |
| [`TOOLING-REFERENCE.md`](ops/TOOLING-REFERENCE.md) | TOOLING-REFERENCE.md — build cache, lint cache, editors, and the source layout | REFERENCE |

### stdlib — library plan

What's in the standard library, what's planned, module-by-module status.

| Doc | What it is | Status |
|-----|------------|--------|
| [`FP-STDLIB-DESIGN.md`](stdlib/FP-STDLIB-DESIGN.md) | FP Standard Library — Typeclasses, Combinators & Error Handling | IMPLEMENTED |
| [`P1-STDLIB-DESIGN.md`](stdlib/P1-STDLIB-DESIGN.md) | P1 Standard Library — Design & Prioritization | PARTIAL |
| [`STDLIB.md`](stdlib/STDLIB.md) | Medaka Standard Library — Design Notes & Roadmap | — |
| [`args.md`](stdlib/args.md) | args | — |
| [`array.md`](stdlib/array.md) | array | — |
| [`async.md`](stdlib/async.md) | async | — |
| [`base32.md`](stdlib/base32.md) | base32 | — |
| [`base64.md`](stdlib/base64.md) | base64 | — |
| [`bytebuilder.md`](stdlib/bytebuilder.md) | bytebuilder | — |
| [`byteparser.md`](stdlib/byteparser.md) | byteparser | — |
| [`bytes.md`](stdlib/bytes.md) | bytes | — |
| [`core.md`](stdlib/core.md) | core | — |
| [`crypto.hmac.md`](stdlib/crypto.hmac.md) | crypto.hmac | — |
| [`crypto.sha256.md`](stdlib/crypto.sha256.md) | crypto.sha256 | — |
| [`crypto.sha256_fast.md`](stdlib/crypto.sha256_fast.md) | crypto.sha256_fast | — |
| [`fs.md`](stdlib/fs.md) | fs | — |
| [`hash_map.md`](stdlib/hash_map.md) | hash_map | — |
| [`hash_set.md`](stdlib/hash_set.md) | hash_set | — |
| [`hex.md`](stdlib/hex.md) | hex | — |
| [`http.md`](stdlib/http.md) | http | — |
| [`i32.md`](stdlib/i32.md) | i32 | — |
| [`i64.md`](stdlib/i64.md) | i64 | — |
| [`index.md`](stdlib/index.md) | Library Index | — |
| [`io.md`](stdlib/io.md) | io | — |
| [`json.md`](stdlib/json.md) | json | — |
| [`list.md`](stdlib/list.md) | list | — |
| [`map.md`](stdlib/map.md) | map | — |
| [`math.md`](stdlib/math.md) | math | — |
| [`mut_bytes.md`](stdlib/mut_bytes.md) | mut_bytes | — |
| [`net.md`](stdlib/net.md) | net | — |
| [`net_async.md`](stdlib/net_async.md) | net_async | — |
| [`nonempty.md`](stdlib/nonempty.md) | nonempty | — |
| [`path.md`](stdlib/path.md) | path | — |
| [`regex.md`](stdlib/regex.md) | regex | — |
| [`runtime.md`](stdlib/runtime.md) | runtime | — |
| [`set.md`](stdlib/set.md) | set | — |
| [`string.md`](stdlib/string.md) | string | — |
| [`test.md`](stdlib/test.md) | test | — |
| [`test_process.md`](stdlib/test_process.md) | test_process | — |
| [`time.md`](stdlib/time.md) | time | — |
| [`toml.md`](stdlib/toml.md) | toml | — |
| [`u16.md`](stdlib/u16.md) | u16 | — |
| [`u32.md`](stdlib/u32.md) | u32 | — |
| [`u64.md`](stdlib/u64.md) | u64 | — |
| [`u8.md`](stdlib/u8.md) | u8 | — |
| [`validation.md`](stdlib/validation.md) | validation | — |
| [`vector.md`](stdlib/vector.md) | vector | — |

### compiler internals — stay in compiler/, indexed here for findability

21 docs live next to the code they describe (compiler/*.md). Listed here so they're still one search away.

| Doc | What it is | Status |
|-----|------------|--------|
| [`AGENTS.md`](../compiler/AGENTS.md) | compiler/AGENTS.md — how not to make the compiler slow | LIVE |
| [`ARCHITECTURE-PLAYBOOK.md`](../compiler/ARCHITECTURE-PLAYBOOK.md) | From here to there: the architecture playbook | ADOPTED 2026-10-15 as the plan of record; Val ratified |
| [`ARCHITECTURE.md`](../compiler/ARCHITECTURE.md) | The compiler's target architecture | ADOPTED 2026-10-15 |
| [`BOOTSTRAP.md`](../compiler/BOOTSTRAP.md) | BOOTSTRAP.md — Native self-compile slices | IMPLEMENTED |
| [`CONSTRUCT-COVERAGE.md`](../compiler/CONSTRUCT-COVERAGE.md) | CONSTRUCT-COVERAGE.md — `medaka build` native coverage matrix | PARTIAL |
| [`DIAGNOSTIC-CODES-DESIGN.md`](../compiler/DIAGNOSTIC-CODES-DESIGN.md) | DIAGNOSTIC-CODES-DESIGN.md | IMPLEMENTED |
| [`EFFECTS-ARCHITECTURE.md`](../compiler/EFFECTS-ARCHITECTURE.md) | Effects within the typechecker | PARTIAL |
| [`EMITTER-ARCH-BUG-FIT.md`](../compiler/EMITTER-ARCH-BUG-FIT.md) | Emitter target architecture - per-bug fit ledger | RE-DERIVED 2026-09-03 |
| [`EMITTER-ARCHITECTURE.md`](../compiler/EMITTER-ARCHITECTURE.md) | Emitter Architecture - the derived current map | CURRENT - source-derived LLVM/WasmGC emitter map, re-derived 2026-09-03 at `7132909b7` |
| [`EMITTER-GAPS.md`](../compiler/EMITTER-GAPS.md) | EMITTER-GAPS.md | PARTIAL |
| [`EMITTER-TARGET-ARCHITECTURE.md`](../compiler/EMITTER-TARGET-ARCHITECTURE.md) | Emitter Target Architecture - one semantic plan, two physical lowerings | REVISED 2026-09-03 |
| [`ERROR-QUALITY.md`](../compiler/ERROR-QUALITY.md) | ERROR-QUALITY.md | IMPLEMENTED |
| [`FFI-ABI.md`](../compiler/FFI-ABI.md) | FFI ABI contract | DECISION, and now LOWERED |
| [`PERF-BASELINE.md`](../compiler/PERF-BASELINE.md) | PERF-BASELINE.md — absolute CLI-verb latency baseline | the `## Table` section is GENERATED |
| [`PERF-RESULTS.md`](../compiler/PERF-RESULTS.md) | PERF-RESULTS.md — native-backend performance log | PARTIAL |
| [`README.md`](../compiler/README.md) | compiler — the Medaka-in-Medaka compiler | CURRENT |
| [`RUNTIME-DESIGN.md`](../compiler/RUNTIME-DESIGN.md) | Runtime & extern strategy for the native (Stage 2.4) backend | IMPLEMENTED, with 2 items still deferred |
| [`TYPECHECK-ARCH-BUG-FIT.md`](../compiler/TYPECHECK-ARCH-BUG-FIT.md) | Typechecker target architecture — per-bug fit ledger | CURRENT |
| [`TYPECHECK-ARCHITECTURE.md`](../compiler/TYPECHECK-ARCHITECTURE.md) | Typechecker Architecture — the derived map | CURRENT |
| [`TYPECHECK-CONTRACTS.md`](../compiler/TYPECHECK-CONTRACTS.md) | Typechecker destination contracts | target architecture, implementation incomplete |
| [`TYPECHECK-TARGET-ARCHITECTURE.md`](../compiler/TYPECHECK-TARGET-ARCHITECTURE.md) | Typechecker Target Architecture — the ground-up design | PROPOSAL |

### archive — closed / historical

IMPLEMENTED or SUPERSEDED work, kept for provenance. Links inside these docs are NOT rewritten when they narrate a past tree (flat files below + `PLAN-ARCHIVE.md`); `design/` and `findings/` are current archived docs whose links ARE kept live. See [`archive/README.md`](../archive/README.md) for the layout explanation.

### archive/design — shipped design docs

| Doc | What it is | Status |
|-----|------------|--------|
| [`ARCH-REVIEW.md`](../archive/design/ARCH-REVIEW.md) | Medaka Architecture Review | PARTIAL |
| [`ARGSTAMP-UNIFY-PLAN.md`](../archive/design/ARGSTAMP-UNIFY-PLAN.md) | ARGSTAMP-UNIFY-PLAN.md — retire the `emitArgStampPasses` eval-vs-emit dispatch fork | IMPLEMENTED |
| [`ASYNC-DESIGN.md`](../archive/design/ASYNC-DESIGN.md) | ASYNC-DESIGN.md | IMPLEMENTED |
| [`BROWSER-STACK-DIAGNOSIS.md`](../archive/design/BROWSER-STACK-DIAGNOSIS.md) | BROWSER-STACK-DIAGNOSIS.md — the playground `Maximum call stack size exceeded` overflow | IMPLEMENTED |
| [`CAPABILITY-EFFECTS-RESEARCH.md`](../archive/design/CAPABILITY-EFFECTS-RESEARCH.md) | Capability-effects research findings | IMPLEMENTED |
| [`CAPABILITY-EFFECTS-V2-DESIGN.md`](../archive/design/CAPABILITY-EFFECTS-V2-DESIGN.md) | Capability-Effects v2 — design doc (parameterized effects + IO decomposition) | IMPLEMENTED |
| [`COMPILER-PORT-LOG.md`](../archive/design/COMPILER-PORT-LOG.md) | compiler — the Medaka-in-Medaka compiler | IMPLEMENTED / SUPERSEDED-FRAMING |
| [`COMPOSITE-MAIN-AUTOPRINT-DESIGN.md`](../archive/design/COMPOSITE-MAIN-AUTOPRINT-DESIGN.md) | Composite-`main` Auto-Print — Design (Option A: uniform auto-print) | IMPLEMENTED on every verb |
| [`D2-REKEY-DESIGN.md`](../archive/design/D2-REKEY-DESIGN.md) | D2 cross-module dict-identity — design (reproduced + root-caused) | IMPLEMENTED |
| [`DIAGNOSTICS-SURFACING-PLAN.md`](../archive/design/DIAGNOSTICS-SURFACING-PLAN.md) | DIAGNOSTICS-SURFACING-PLAN.md — native `check` error positions + messages (WS-4 / F6) | IMPLEMENTED |
| [`DISPATCH-GAPS-SCOPE.md`](../archive/design/DISPATCH-GAPS-SCOPE.md) | DISPATCH-GAPS-SCOPE.md | IMPLEMENTED |
| [`DISPATCH-INVENTORY.md`](../archive/design/DISPATCH-INVENTORY.md) | DISPATCH-INVENTORY.md | PARTIAL |
| [`DRIVER-COLLAPSE-PLAN.md`](../archive/design/DRIVER-COLLAPSE-PLAN.md) | DRIVER-COLLAPSE-PLAN.md — collapse the dual single-file / multi-module drivers | PARTIALLY IMPLEMENTED |
| [`EAGER-INIT-DESIGN.md`](../archive/design/EAGER-INIT-DESIGN.md) | EAGER-INIT-DESIGN — closing the shared eager-global init-order hole (#553, S0) | COMPLETE |
| [`F1B-MODULE-IDENTITY-DESIGN.md`](../archive/design/F1B-MODULE-IDENTITY-DESIGN.md) | F1b Loader Module-Identity — Decision-Ready Design | IMPLEMENTED |
| [`FMT-COMMENT-INTERLEAVING-DESIGN.md`](../archive/design/FMT-COMMENT-INTERLEAVING-DESIGN.md) | FMT comment placement — design | the design below replaced the 2026-07-01 line-index splice |
| [`HELPER-CENSUS.md`](../archive/design/HELPER-CENSUS.md) | compiler/ generic-helper census | PARTIAL |
| [`INDEX-16-PLAN.md`](../archive/design/INDEX-16-PLAN.md) | INDEX-16-PLAN.md — concrete staged implementation plan for the Index arc, Phase #16 | IMPLEMENTED |
| [`INDEX-DESIGN.md`](../archive/design/INDEX-DESIGN.md) | INDEX-DESIGN.md — Indexing (`a[i]` / `a[i] := v`) design pass | IMPLEMENTED |
| [`JEV-DESIGN.md`](../archive/design/JEV-DESIGN.md) | Jev judgment tools: calibrated judgments between lint and LLM review | SUPERSEDED, 2026-10-18 |
| [`JEV-LEDGER.md`](../archive/design/JEV-LEDGER.md) | Jev: the experiment ledger | SUPERSEDED, 2026-10-18 |
| [`LAYOUT-BRACKETS-DESIGN.md`](../archive/design/LAYOUT-BRACKETS-DESIGN.md) | LAYOUT-BRACKETS-DESIGN — block expressions inside brackets | IMPLEMENTED |
| [`LIB-REMOVAL-DESIGN.md`](../archive/design/LIB-REMOVAL-DESIGN.md) | LIB-REMOVAL-DESIGN — retiring the OCaml reference compiler (`lib/`+`bin/`+`gen/`) | IMPLEMENTED |
| [`MAP-SET-AMBIGUITY-DESIGN.md`](../archive/design/MAP-SET-AMBIGUITY-DESIGN.md) | MAP-SET-AMBIGUITY-DESIGN.md — ambiguous unqualified-import occurrence (use-time / approach A) | IMPLEMENTED |
| [`MULTICLAUSE-EXHAUST-DESIGN.md`](../archive/design/MULTICLAUSE-EXHAUST-DESIGN.md) | Multi-Clause Function Exhaustiveness — Design | IMPLEMENTED |
| [`NET-DESIGN.md`](../archive/design/NET-DESIGN.md) | NET-DESIGN.md — Medaka networking (decision-ready) | IMPLEMENTED |
| [`NUMLIT-DESIGN.md`](../archive/design/NUMLIT-DESIGN.md) | Design: Num-polymorphic numeric literals (PLAN.md #11) | IMPLEMENTED |
| [`PARSE-ERROR-LOCATION-DESIGN.md`](../archive/design/PARSE-ERROR-LOCATION-DESIGN.md) | PARSE-ERROR-LOCATION-DESIGN | PARTIAL/IMPLEMENTED |
| [`PERF-NOTES.md`](../archive/design/PERF-NOTES.md) | Self-host performance notes & log | SUPERSEDED BY `compiler/PERF-RESULTS.md` / `archive/design/PERF-SCOPE.md` |
| [`PERF-RUNTIME.md`](../archive/design/PERF-RUNTIME.md) | PERF-RUNTIME.md — general compiled-program performance | IMPLEMENTED |
| [`PERF-SCOPE.md`](../archive/design/PERF-SCOPE.md) | PERF-SCOPE.md — Stage-3 bar-item-4 performance scoping | IMPLEMENTED |
| [`PLAYGROUND-ANIMATION-DESIGN.md`](../archive/design/PLAYGROUND-ANIMATION-DESIGN.md) | Playground canvas and animation | IMPLEMENTED |
| [`PLAYGROUND-ANIMATION-PLAN.md`](../archive/design/PLAYGROUND-ANIMATION-PLAN.md) | Playground animation implementation plan | COMPLETE |
| [`PLAYGROUND-DESIGN.md`](../archive/design/PLAYGROUND-DESIGN.md) | PLAYGROUND-DESIGN.md — in-browser Medaka playground | IMPLEMENTED |
| [`PLAYGROUND-EDITOR-DESIGN.md`](../archive/design/PLAYGROUND-EDITOR-DESIGN.md) | PLAYGROUND-EDITOR-DESIGN.md — Tier 3 in-browser editor | IMPLEMENTED |
| [`PRE-FLIP-GAPS.md`](../archive/design/PRE-FLIP-GAPS.md) | PRE-FLIP-GAPS.md — outstanding native-compiler items to close before the canonicalization milestone flip | IMPLEMENTED |
| [`PRELUDE-OBJ-DESIGN.md`](../archive/design/PRELUDE-OBJ-DESIGN.md) | PRELUDE-OBJ-DESIGN.md — precompiling the prelude to a shared object | SHIPPED |
| [`REEXPORT-METHOD-SCHEME-DESIGN.md`](../archive/design/REEXPORT-METHOD-SCHEME-DESIGN.md) | Re-export does not thread schemes into the importer's typecheck seed | IMPLEMENTED |
| [`REROOT-PLAN.md`](../archive/design/REROOT-PLAN.md) | REROOT-PLAN — taking the gate suite OFF the OCaml oracle | IMPLEMENTED |
| [`RESOLVER-DIAG-LOCATION-DESIGN.md`](../archive/design/RESOLVER-DIAG-LOCATION-DESIGN.md) | Real source locations for the 3 `{0,0}`-range resolver diagnostics (F3) | IMPLEMENTED |
| [`RETPOS-DISPATCH-DESIGN.md`](../archive/design/RETPOS-DISPATCH-DESIGN.md) | RETPOS-DISPATCH-DESIGN — return-position-only method mis-dispatch (run≠build) | IMPLEMENTED |
| [`RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN.md`](../archive/design/RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN.md) | RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN | IMPLEMENTED |
| [`S1-CONSTRAINED-SHADOW-DESIGN.md`](../archive/design/S1-CONSTRAINED-SHADOW-DESIGN.md) | S-1 — a CONSTRAINED definer-shadow standalone is miscompiled | IMPLEMENTED |
| [`SHADOW-INVERSION-DESIGN.md`](../archive/design/SHADOW-INVERSION-DESIGN.md) | SHADOW-INVERSION-DESIGN — invert S2: a top-level standalone WINS over a same-named interface method | SHIPPED 2026-07-14 |
| [`SHARED-FLOAT-RESIDUAL-DESIGN.md`](../archive/design/SHARED-FLOAT-RESIDUAL-DESIGN.md) | SHARED-FLOAT-RESIDUAL-DESIGN — the signature-free type-lost-Float residual | IMPLEMENTED |
| [`SQLITE-DESIGN.md`](../archive/design/SQLITE-DESIGN.md) | SQLite Read-Path Library — Design | design document |
| [`SQLITE-MUTATION-DESIGN.md`](../archive/design/SQLITE-MUTATION-DESIGN.md) | SQLite Mutation (UPDATE / DELETE) — Design & Feasibility | IMPLEMENTED |
| [`SQLITE-WASM-DESIGN.md`](../archive/design/SQLITE-WASM-DESIGN.md) | SQLITE-WASM-DESIGN.md — scoping the WasmGC port of the Medaka SQLite library | IMPLEMENTED |
| [`SQLITE-WRITE-DESIGN.md`](../archive/design/SQLITE-WRITE-DESIGN.md) | SQLite WRITE path — design (v1) | IMPLEMENTED |
| [`STAGE2-DESIGN.md`](../archive/design/STAGE2-DESIGN.md) | Stage 2 backend architecture — bytecode VM first, or straight to LLVM? | IMPLEMENTED |
| [`TRAVERSABLE-DEFAULT-METHOD-DESIGN.md`](../archive/design/TRAVERSABLE-DEFAULT-METHOD-DESIGN.md) | Making `sequence` a default method of `Traversable t` | IMPLEMENTED |
| [`TRMC-DESIGN.md`](../archive/design/TRMC-DESIGN.md) | TRMC-DESIGN.md — tail-recursion-modulo-cons for the native LLVM backend | IMPLEMENTED |
| [`TUPLE-TYPE-CONSTRUCTOR-DESIGN.md`](../archive/design/TUPLE-TYPE-CONSTRUCTOR-DESIGN.md) | Tuple as a real type constructor — design doc | IMPLEMENTED |
| [`TYPE-ALIAS-EXPANSION-DESIGN.md`](../archive/design/TYPE-ALIAS-EXPANSION-DESIGN.md) | Type-Alias Expansion — Design | IMPLEMENTED |
| [`TYPE-ERROR-SPAN-DESIGN.md`](../archive/design/TYPE-ERROR-SPAN-DESIGN.md) | Type-error span precision — design | IMPLEMENTED |
| [`TYPECHECK-AUDIT.md`](../archive/design/TYPECHECK-AUDIT.md) | Selfhost Typechecker Audit — 2026-06-09 | IMPLEMENTED |
| [`TYPECHECK-ERROR-FRAMING-DESIGN.md`](../archive/design/TYPECHECK-ERROR-FRAMING-DESIGN.md) | TYPECHECK ERROR FRAMING — Design (Tier-3 "typecheck mis-framing" reservoir) | IMPLEMENTED |
| [`TYPECHECK-SIGNATURE-CONSTRAINT-DESIGN.md`](../archive/design/TYPECHECK-SIGNATURE-CONSTRAINT-DESIGN.md) | Signature Constraint Soundness — Design + Blast-Radius Census | IMPLEMENTED |
| [`VALUE-RESTRICTION-DESIGN.md`](../archive/design/VALUE-RESTRICTION-DESIGN.md) | Generalizing constructor / record applications of values (value-restriction relaxation) | IMPLEMENTED, then AMENDED |
| [`WASM-FLOAT-TYPING-DESIGN.md`](../archive/design/WASM-FLOAT-TYPING-DESIGN.md) | WASM-FLOAT-TYPING-DESIGN — the principled fix for W-SQLITE-4 | IMPLEMENTED |
| [`WASM-POLY-NUM-DESIGN.md`](../archive/design/WASM-POLY-NUM-DESIGN.md) | WASM-POLY-NUM-DESIGN — closing the wasm polymorphic-`Num` arithmetic gap | IMPLEMENTED |
| [`WASM-SELFHOST-GAPS.md`](../archive/design/WASM-SELFHOST-GAPS.md) | WasmGC self-host gap census | IMPLEMENTED |
| [`WASM-SELFHOST-ROADMAP.md`](../archive/design/WASM-SELFHOST-ROADMAP.md) | WASM-SELFHOST-ROADMAP.md — driving the WasmGC backend to compile the compiler | IMPLEMENTED |
| [`WASM-TMC-GAP-DESIGN.md`](../archive/design/WASM-TMC-GAP-DESIGN.md) | WASM-TMC-GAP-DESIGN.md — TMC does not fire on constrained (dict-passed) builders | FIXED |
| [`WASMGC-DESIGN.md`](../archive/design/WASMGC-DESIGN.md) | WASMGC-DESIGN.md — WasmGC backend implementation plan | IMPLEMENTED |
| [`WASMGC-TRMC-DESIGN.md`](../archive/design/WASMGC-TRMC-DESIGN.md) | WASMGC-TRMC-DESIGN.md — scoping the general fix for the WasmGC runtime stack overflow (layer-5) | IMPLEMENTED |
| [`WS-4-DESIGN.md`](../archive/design/WS-4-DESIGN.md) | WS-4 Design — `Product` refinement domain (structure-aware `Net = Host(Prefix) × Method(Set)`) | IMPLEMENTED |
| [`WS2-REKEY-DIAGNOSIS.md`](../archive/design/WS2-REKEY-DIAGNOSIS.md) | WS-2 full re-key — diagnosis & deferral (module-qualified dict-arity identity) | PARTIAL |

### archive/findings — point-in-time QA/investigation sweeps

| Doc | What it is | Status |
|-----|------------|--------|
| [`FINDINGS.md`](../archive/findings/architecture-evaluation-2026-10-15/FINDINGS.md) | Medaka compiler architecture: evaluation against OCaml, GHC and rustc | CLOSED RECORD |
| [`census-medaka.md`](../archive/findings/architecture-evaluation-2026-10-15/census-medaka.md) | Medaka compiler structural census | CLOSED RECORD |
| [`report-ghc.md`](../archive/findings/architecture-evaluation-2026-10-15/report-ghc.md) | GHC architecture vs Medaka: a sourced comparison | CLOSED RECORD |
| [`report-ocaml.md`](../archive/findings/architecture-evaluation-2026-10-15/report-ocaml.md) | The OCaml compiler as an architectural reference for Medaka | CLOSED RECORD |
| [`report-rustc.md`](../archive/findings/architecture-evaluation-2026-10-15/report-rustc.md) | rustc architecture vs Medaka: a sourced comparison | CLOSED RECORD |
| [`FINDINGS.md`](../archive/findings/qa-beta-2026-07-07/FINDINGS.md) | Beta-hardening QA findings — 2026-07-07 | CLOSED RECORD |
| [`FIXTURES.md`](../archive/findings/qa-beta-2026-07-07/FIXTURES.md) | Regression fixtures to add — beta hardening, 2026-07-07 | CLOSED RECORD |
| [`P0-18-BUILD-PATH-DESIGN.md`](../archive/findings/qa-beta-2026-07-07/P0-18-BUILD-PATH-DESIGN.md) | P0-18 build-path soundness hole — design & scoping | CLOSED RECORD |
| [`P0-18-STANDALONE-DISPATCH-DESIGN.md`](../archive/findings/qa-beta-2026-07-07/P0-18-STANDALONE-DISPATCH-DESIGN.md) | P0-18 standalone-fn-shadows-interface-method — dispatch miscompile | CLOSED RECORD |
| [`P0-5-MUTABILITY-DESIGN.md`](../archive/findings/qa-beta-2026-07-07/P0-5-MUTABILITY-DESIGN.md) | P0-5 — Beta Mutability Model: enforce immutability + make `let mut` work | CLOSED RECORD |
| [`beginner-syntax.md`](../archive/findings/qa-beta-2026-07-07/reports/beginner-syntax.md) | Beginner-syntax findings (first-hour human-user simulation) | CLOSED RECORD |
| [`bindings-mutability.md`](../archive/findings/qa-beta-2026-07-07/reports/bindings-mutability.md) | Findings: bindings-mutability | CLOSED RECORD |
| [`numerics-strings-data.md`](../archive/findings/qa-beta-2026-07-07/reports/numerics-strings-data.md) | Findings: numerics-strings-data | CLOSED RECORD |
| [`patterns-control-flow.md`](../archive/findings/qa-beta-2026-07-07/reports/patterns-control-flow.md) | Findings: patterns-control-flow | CLOSED RECORD |
| [`playground-wasm.md`](../archive/findings/qa-beta-2026-07-07/reports/playground-wasm.md) | Findings: playground-wasm | CLOSED RECORD |
| [`test-gap-analysis.md`](../archive/findings/qa-beta-2026-07-07/reports/test-gap-analysis.md) | Test-gap analysis (area: test-gap-analysis) | CLOSED RECORD |
| [`tooling-cli.md`](../archive/findings/qa-beta-2026-07-07/reports/tooling-cli.md) | QA findings — tooling-cli | CLOSED RECORD |
| [`type-system.md`](../archive/findings/qa-beta-2026-07-07/reports/type-system.md) | Type-system findings (adversarial QA, 2026-07-07) | CLOSED RECORD |

### archive/ (flat) — closed conformance audits/roadmaps + the Phase archive

| Doc | What it is | Status |
|-----|------------|--------|
| [`DICT-CONFORMANCE-AUDIT.md`](../archive/DICT-CONFORMANCE-AUDIT.md) | Dictionary-Passing Conformance Audit | audit |
| [`DICT-CONFORMANCE-ROADMAP.md`](../archive/DICT-CONFORMANCE-ROADMAP.md) | Dictionary-Passing Conformance Roadmap | — |
| [`EFFECTS-CONFORMANCE-AUDIT.md`](../archive/EFFECTS-CONFORMANCE-AUDIT.md) | Effect-and-Capability Conformance Audit | audit |
| [`LAYOUT-CONFORMANCE-AUDIT.md`](../archive/LAYOUT-CONFORMANCE-AUDIT.md) | LAYOUT-CONFORMANCE-AUDIT.md | — |
| [`LAYOUT-CONFORMANCE-ROADMAP.md`](../archive/LAYOUT-CONFORMANCE-ROADMAP.md) | LAYOUT-CONFORMANCE-ROADMAP.md | — |
| [`PLAN-ARCHIVE.md`](../archive/PLAN-ARCHIVE.md) | Medaka — Plan Archive (Phases 1–145) | — |

