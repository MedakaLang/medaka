# MCP agent service: architecture and execution plan

**Status:** PLANNED — 2026-11-02. Implementation has not started. GitHub is the
backlog of record; issue and milestone links below are the execution map.

## 1. Outcome and evidence

An agent in a fresh worktree can connect immediately, discover useful code,
identify the compiler answering it, and pick up a local build without reconnecting.
The service must make language work more accurate and cheaper to complete.
Increasing tool-call counts alone is not success.

Inspected base: `053ea4f71a1db44b19f1dfd2f2f52dc088924713`.
The current [wrapper](../../scripts/medaka-mcp-wrapper.sh) exits when the local
binary is absent. The [server](../../compiler/tools/mcp.mdk) retains its compiler
and prelude for the session, processes requests serially, exposes eight tools,
and limits definition lookup to one file. It already has syntax caching and
recoverable symbol outlines: these are retained, not reimplemented.

The main checkout's local call log contained 279 calls from July 17 to November 2:
101 check, 81 format, 37 symbols, 32 references, 28 lint; no hover, definition or
test calls. This is one log, may include probes, and excludes startup failures.
It establishes neither fleet adoption nor task success. Live symbol and source
check calls worked during the survey. Open issues were audited through GitHub;
bug reports remain reports until reproduced on the implementation base.

## 2. Architecture

```text
MCP client / structured CLI
             |
 independently installed supervisor
   | workspace registry, worker lifecycle, jobs, response limits
   | local versioned docs and installation status
   +-- workspace A + toolchain fingerprint -> compiler query worker
   +-- workspace B + toolchain fingerprint -> compiler query worker
   +-- isolated execution jobs (tests / explicit build preparation)
```

The supervisor starts without compiling the checkout. Distribution includes a
baseline toolchain and documentation, or installs them in the same explicit
installation operation. Normal startup requires neither network access nor a
package-manager download. Offline startup with an absent optional toolchain
still offers status and bundled documentation.

The supervisor owns transport, process management, workspace selection, output
budgets and jobs. Medaka owns lexing, parsing, resolution, inference, diagnostics,
formatting and semantic edits. MCP, CLI and LSP consume shared semantic services;
the supervisor must not acquire an independent parser or resolver.

M0 prototypes packaging and chooses the supervisor language and process adapter.
Compare an installed Medaka supervisor with a small external-runtime supervisor;
measure startup, install size/dependencies, restart behavior and operational
complexity. Self-hosting is permitted but must not reintroduce a checkout-build
dependency. An SDK-backed implementation is permitted but must not create a
second semantic implementation. Record the decision before M1 implementation.

### Workspace and toolchain identity

Every request has an explicit workspace identifier or an absolute file path that
unambiguously selects one. Source-only requests require workspace context for
semantic operations. Registered roots are canonicalized; ambiguous roots are
errors. No process-global mutable active workspace is shared between callers.
Nested projects retain their own manifest and target profile.

Application mode uses the installed, pinned release toolchain. Compiler-development
mode requires a toolchain matching the target checkout's compiler and stdlib
fingerprints for authoritative validation. An explicit baseline query may use
the installed release, but its result says `baseline`; it cannot satisfy a
matching-build check. Missing or mismatched builds return actionable status.
An unbuilt compiler edit cannot produce authoritative new semantics.

Worker identity includes canonical root, compiler artifact/build fingerprint,
stdlib/interface fingerprint, target profile and protocol version. Source snapshots
include relevant file contents, manifests and dependency/index scope. Cache keys
must distinguish these inputs, including unsaved overlays where supported.
Workers may serialize semantic requests internally while the supervisor remains
responsive; separate workspaces never share mutable compiler state.

After a completed rebuild, the supervisor selects a fresh worker. It must not
launch a half-written binary or reuse a worker merely because the path is unchanged.
Build preparation is an explicit job, outside the handshake, deduplicated per
worktree and coordinated with existing builds. Initial implementation may observe
externally run `make medaka`; automatic preparation is not required for M1.
In-flight results retain their original snapshot identity and are marked obsolete
if inputs change. A failed worker returns an error without killing the connection;
reads may be retried once only against the same snapshot, writes are never replayed.
Worker count, idle lifetime and memory are bounded; cancellation terminates the
owned job/process group and cleans its scratch directory without killing another
caller or a shared build it does not own.

### Results and addressing

Use MCP `structuredContent` with a concise text summary and negotiated compatibility
for older clients. Do not simply emit an unrecognized raw JSON content block.
All semantic results identify workspace, toolchain, snapshot, target/engine where
applicable, completeness, and whether they are current or baseline results.
Large results use deterministic ordering, limits and continuation tokens bound to
the snapshot; truncation and partial coverage must be explicit.

Search returns opaque symbol handles scoped to workspace and snapshot. Inspect,
definition, references and implementations accept these handles. Existing file /
zero-based UTF-16 position addressing remains available. Name queries return
ambiguity rather than choosing a same-named binder. Token-based addressing excludes
comments and string contents. Stale handles fail with a refresh action.

Project references keep their current project scope; stdlib discovery/definition
may inspect the selected toolchain's sources but does not silently turn reference
queries into whole-stdlib scans. Definition sites and implementation sites remain
distinct, including multi-clause functions and interface methods.

## 3. Functionality and boundaries

| Capability | Contract | Delivery |
|---|---|---|
| Status and prepare | Workspace, toolchain, missing prerequisites, worker state; explicit preparation job | M1 |
| Search / inspect | Workspace and selected stdlib names, signatures, docs, locations; body opt-in | M2 |
| Definition / references / implementations | Cross-file binder identity, snapshot handles, exact ranges and partial-coverage metadata | M2 |
| Check / lint | Selected files or changed scope, stable diagnostic codes and fixes; explicit coverage | Existing tools, consolidated in M4 |
| Documentation | Search versioned syntax, stdlib examples and diagnostic explanations with source citations | M3 |
| Explain | First: selected interface implementation at a call site and why; later constraint origins/effects/lowering only when measured useful | M3 |
| Edit preview / format patch | In-memory overlay, before/after diagnostics and patch with content preconditions | M4 |
| Rename | Conservative capture refusal, complete project coverage, edits returned with preconditions | M4 |
| Tests | Select tests, start/status/cancel jobs, engine/seed/count/skip/failure details | M4 |
| Call hierarchy / impact | Candidate dependents, scope and limitations; never claim every candidate will break | Deferred, #851 |

The small default tool surface exposes discovery, inspection, checks and status.
Deep compiler explanations and jobs are discoverable on demand. Operations have
one schema shared by MCP and a structured CLI adapter, rather than independent
implementations. Precise public names are fixed during the M0 protocol spike.
Transport-specific resources/prompts may supplement tools but are not required
for a client's basic workflow.

Preview and rename initially return edits; existing formatter calls stay read-only.
An optional apply operation must explicitly request writing, validate every original
content digest, refuse partial coverage/capture, and never silently overwrite changed
files. Multi-file application is deferred until a recoverable all-or-refuse protocol
is demonstrated. Diagnostic deltas use the same workspace/toolchain/profile for
both snapshots. Broken syntax can produce partial read results but cannot license
a supposedly safe rename. The existing [rename design](REFERENCES-RENAME-DESIGN.md)
remains the semantic baseline unless a later decision explicitly changes it.

Test jobs execute code and are annotated accordingly. Engine, seed, tests selected,
executed, skipped and failed are always available; zero executed is not a pass.
Runtime failures cannot be converted to successful empty results. Long jobs cannot
block status or navigation. Generic shell execution, policy-checked agent scripts
(#4423), a remote hosted service, and a general-purpose agent are outside this epic.
Editor-attached overlays are a future adapter; disk snapshots and explicit preview
overlays are the initial scope.

## 4. Module ownership and boundary shapes

These are proposed modules, not claims that files already exist. M0 must confirm
the worker boundary and names against its fresh base before implementation packets.

| Proposed owner | Responsibility and boundary API | Forbidden responsibility |
|---|---|---|
| New top-level `agent-service/` package | `openWorkspace(config) -> WorkspaceId`; `status(id) -> Status`; `request(context, operation) -> Result`; `startJob/statusJob/cancelJob` | Compiler semantics; implicit active-workspace state |
| New `tools/agent_query.mdk` under the compiler | `query(QueryContext, Query) -> QueryResult`; shared semantic-query facade | MCP framing, process supervision, independent resolution rules |
| New `tools/agent_symbols.mdk` under the compiler | `search(snapshot, filter) -> SymbolPage`; `inspect/definition/references/implementations(snapshot, handle) -> Result` | Re-parsing independently of shared entries or merging identities by spelling |
| New `tools/agent_explain.mdk` under the compiler | `explain(checkedSnapshot, site, kind) -> Explanation` | Re-solving inference or synthesizing explanations from textual guesses |
| New `tools/agent_edits.mdk` under the compiler | `preview(context, edits) -> Preview`; `rename(snapshot, handle, name) -> EditPlan` | Unchecked source writes or accepting stale handles |
| Existing MCP/LSP adapters, new structured CLI adapter | Decode/validate arguments, call shared services, encode results | Owning semantic algorithms |

`QueryContext` carries workspace, immutable snapshot, toolchain and profile;
`QueryResult` carries provenance, completeness, payload and diagnostic data.
Placement follows [compiler architecture](../../compiler/ARCHITECTURE.md): tools
may consume lower layers, lower layers do not import tools; driver dispatch stays
thin; inference does not depend on a transport. Reuse refindex, SyntaxSource and
memoized compiler entries. If explanation needs new compiler facts, the owning
lower-layer producer publishes data and the tools layer renders it. No growth in
the typechecker entry is planned. New package/gate enrollment is part of delivery.

## 5. Milestones and execution

Epic: [#4768](https://github.com/MedakaLang/medaka/issues/4768).

| Milestone | Tracking issues | Exit |
|---|---|---|
| [MCP M0: measured baseline and packaging decision](https://github.com/MedakaLang/medaka/milestone/59) | [#4769](https://github.com/MedakaLang/medaka/issues/4769), [#4770](https://github.com/MedakaLang/medaka/issues/4770) | Baseline tasks/budgets and packaging/worker decision recorded. |
| [MCP M1: available and correct in every worktree](https://github.com/MedakaLang/medaka/milestone/60) | [#4771](https://github.com/MedakaLang/medaka/issues/4771), [#846](https://github.com/MedakaLang/medaka/issues/846), [#848](https://github.com/MedakaLang/medaka/issues/848) | Offline fresh-worktree startup; correct routing/provenance; rebuild without reconnect. |
| [MCP M2: discover and navigate code](https://github.com/MedakaLang/medaka/milestone/61) | [#850](https://github.com/MedakaLang/medaka/issues/850), [#4772](https://github.com/MedakaLang/medaka/issues/4772) | Search/inspect and cross-file navigation with snapshot handles. |
| [MCP M3: versioned knowledge and compiler explanations](https://github.com/MedakaLang/medaka/milestone/62) | [#4773](https://github.com/MedakaLang/medaka/issues/4773), [#4774](https://github.com/MedakaLang/medaka/issues/4774) | Versioned docs and compiler-evidence dispatch explanation. |
| [MCP M4: edit-test loop and measured rollout](https://github.com/MedakaLang/medaka/milestone/63) | [#4775](https://github.com/MedakaLang/medaka/issues/4775), [#852](https://github.com/MedakaLang/medaka/issues/852), [#254](https://github.com/MedakaLang/medaka/issues/254), [#4776](https://github.com/MedakaLang/medaka/issues/4776), [#4777](https://github.com/MedakaLang/medaka/issues/4777) | Safe edit/test loop, compatibility migration and measured task outcomes. |

### Existing-issue disposition

| Existing issue | Disposition / owner |
|---|---|
| #246, #642 | Superseded planning umbrellas; closed as not planned with links to this epic. This is not a claim their unfinished features shipped. |
| #846, #848, #850 | Retained, narrowed/updated and assigned M1/M2; see milestone table. |
| #254, #852 | Retained in M4: rename and preview safety criteria preserved. |
| #851 | Deferred follow-on: call hierarchy/impact; no M0–M4 closure claim. |
| #3834 | Retained S1; reproduce and discharge server-crash behavior under #4771/#4776. |
| #1056, #4294 | Retained; navigation/rename correctness dependencies of #4772/#254. #4294 has a separate native-probe obligation too. |
| #4051, #4254 | Retained cross-verb target-profile/diagnostic obligations; #4775 verifies MCP integration. Do not close on an MCP-only fix. |
| #4148, #4149 | Retained under run-once epic #4141; coordinate shared parse/index work with M2. Current source already has syntax cache and buildRefIndexProjectWithParsed/processParsed, so remeasure residual scope rather than implement the old narrative verbatim. |
| #4355, #962, #4169 | Retained performance work; #4769 captures budgets and #4777 checks outcomes. |
| #2885, #2884, #4674 | Retained serializer/channel-parity/code-action work; coordinate #848/#4775, preserve non-MCP acceptance. |
| #327, #2367 | Retained regression/help-conformance debt; include in compatibility audit #4777. |
| #1223, #1445, #2785 | Retained test/check semantic limitations; #4776/#4775 must report limitations honestly. |
| #4423 / #4412 | Separate policy-checked agent-script host; no duplicate ownership or closure. |
| Other broad-search hits | #4420, #4664, #1309, #1421, #3697, #74, #435, #2240, #4543, #2794, #2705, #2276, #1985, #1122, #2439 remain unchanged in their owning workstreams. |

Audit: open GitHub broad MCP search (44 results), title search, S0 query (no hits),
and mcp.mdk debt query on 2026-11-02. Shared defects keep their owning milestones.
Reproduction is required before any bug closure; this audit closes only the two
superseded planning umbrellas.

M0 settles packaging/protocol and records baseline tasks. M1 delivers availability
and worktree trust. M2 delivers navigation. M3 adds versioned knowledge and one
measured compiler explanation. M4 closes the edit/test loop and evaluates adoption.
These are outcomes, not one giant implementation sprint. Cut bounded sprint
contracts just in time using the sprint-plan skill; default serial implementation,
one end review, and the repository PR workflow. Terra/high is the default executor;
an unresolved semantic decision gets an explicitly justified Sol/high spike.
No expected-red gate is licensed by this plan.

## 6. Verification and release criteria

M0 records shell/current-MCP baselines for at least these tasks: locate an imported
definition; references under shadowing; stdlib API discovery; diagnostic repair;
dispatch explanation; compiler-edit validation in another worktree. Pin checkout,
toolchain, agent/model configuration and expected answers. Include normal and
broken source. Measure task correctness, time, context bytes/tokens, unnecessary
file reads, startup failures, peak memory and stale/wrong-workspace incidents.
Log completion/error/cancel, latency, payload size and fallback category locally;
source text and full arguments are opt-in. Separate test probes from normal use.

Hard correctness floor: no silently wrong workspace/toolchain, stale edit acceptance,
or false success on zero tests in the adversarial acceptance corpus. Proposed M1
startup target: initialize and tools/list within two seconds on documented reference
hosts with assets installed and network disabled. M0 records achievable query
latency, memory and context budgets before accepting optimizations; no invented
performance improvement is treated as evidence.

Acceptance includes fresh clone with no binary, missing/offline assets, two worktrees
with different compiler edits, rebuild during a request, corrupt/failed worker,
cancellation, target-profile changes, identical basenames in different modules,
aliases/reexports, strings/comments, Unicode positions, incomplete files, changed
dependency contents and bounded output continuation. Release smoke runs on Linux
x86-64 and macOS arm64, initially matching existing distribution targets.

Compiler contracts use sibling native tests and registered native gate-tests.
Supervisor transport/install tests use its selected runtime's harness and an
independent subprocess integration harness that does not require the checkout
compiler to exist. A shell trust-anchor gate requires its specific shell-because
justification and registry/cost enrollment. Extend the existing MCP transcript gate
for legacy compatibility. Cache/performance changes measure allocations, work and
retained memory; do not infer speed from cache presence. Bugs close only after their
reproducer and controls pass on the final implementation head.

M4 evaluates the same pinned tasks against shell and current-MCP baselines, reports
failures as well as wins, and revises the default tool set from measured results.
Migration updates MCP.md, wrapper/configuration, skills and install instructions;
old tools remain compatible until a documented migration path exists. Keep compiler
bug fixes and any deferred capability open with their own owner and acceptance.

## 7. Survey and decisions

- [gopls](https://go.dev/gopls/features/mcp): installed tooling, attached/detached
  sessions and shared language services motivate independent distribution.
- [Dart/Flutter](https://docs.flutter.dev/ai/tools): SDK diagnostics, symbol resolution,
  testing and skills motivate pairing operations with short task workflows.
- [Serena](https://oraios.github.io/serena/01-about/035_tools.html): global symbol lookup,
  implementation queries and programmable result filtering motivate symbol handles
  and bounded responses. A general REPL is not needed for this first surface.
- [Tidewave](https://tidewave.hexdocs.pm/mcp.html): its worktree proxy routes by port;
  explicit workspace routing here addresses the same inherited-connection problem.
- [Lean LSP MCP](https://github.com/oOo0oOo/lean-lsp-mcp): goals and term information
  motivate exposing compiler facts that text search cannot reconstruct.

Survey accessed 2026-11-02. These are design precedents, not comparative productivity
evidence. The explicit changes from earlier MCP policy are independent installation,
supervisor-owned worktree routing and an explicit baseline-toolchain mode. Local
matching semantics remain required for compiler-edit validation. Optional source
application is deferred behind a safe protocol; historical read-only tools do not
silently become writers.
