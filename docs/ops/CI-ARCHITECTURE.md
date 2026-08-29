# CI-ARCHITECTURE.md — target architecture for Medaka's CI

**Status:** DESIGN — adopted 2026-08-28 (Val), epic #2182 (sub-issues #2176–#2181).
Nothing here is built yet except the `gates (pds)` required-check fix (done directly on
ruleset 18885875, 2026-08-28). This doc is the design authority for the epic; the
sub-issue bodies are scope ledgers that point back here. Companion:
[GATE-REGISTRY-DESIGN.md](GATE-REGISTRY-DESIGN.md) (the registry format).

---

## 0. One-paragraph version

Gates become **data**: a registry declares every gate's semantic identity (area, owning
project), tier, cost class, oracle/fixture dependencies, and invocation, and a native
`medaka gate` driver runs them. Everything else is a *derivation* from that registry:
the ci.yml matrix is generated (drift-red), shard membership is load-balanced from
measured per-gate timings under neutral executor names, library-project suites are
scoped in the merge queue by a dependency graph the compiler itself emits, a cost
ratchet reds un-budgeted growth at authoring time, and an explicit tier-3 (nightly)
charter absorbs the heavy tail with a revert-to-green norm. The merge queue's compiler
half never narrows. Every selection mechanism fails open to the full suite.

## 1. The problems this solves (2026-08-28)

Stated by Val; measured in the audit that preceded this doc (research session
2026-08-28, building on epic #1926's audit of 2026-08-24):

1. **Wall-clock balloons with no governor.** Placement discipline is convention
   (matrix-row provenance comments) plus a nightly issue-filer. The pole shard
   re-formed at 933s three days after #1929 split the previous pole. The only hard
   ceiling is the 40-minute job timeout. Re-derive, never cite:
   `sh scripts/ci_shard_cost.sh --runs 5`.
2. **Shard names lie about contents — by design.** "Shards are scheduled by cost, not
   by theme" (2026-07-14, `.claude/dossier/ci.md`) was the right call given
   hand-placement, but it conflates two things: what a gate *means* and where it
   *executes*. End state at adoption: ~14 compiler gates outside their thematic shard,
   ~41 project gates scattered across five compiler-named shards, and a
   `gates (sqlite)` shard containing zero sqlite gates.
3. **Every merge-queue entry runs every project's suite.** Six library projects
   (derive: `git ls-files '*medaka.toml'`, minus `compiler/` and fixtures). Their ~50
   gates run on every queue entry regardless of what changed. Eventual goal is
   per-project repo ejection after stable releases; project CI should become
   self-contained and scoped now, which is also the ejection prep.
4. **~271 shell scripts / ~60k lines** (derive: `git ls-files '*.sh' | wc -l`) carry
   the test surface, with the same "which gates exist and who runs them" fact
   hand-maintained in three consumers (ci.yml patterns, test/preflight.sh's path map,
   test/diff_compiler_ci_shard_coverage.sh + test/CI-COVERAGE-EXCEPTIONS.txt) — the
   [W-THIRD-CONSUMER] bookkeeping.

## 2. Patterns adopted from other language projects

The survey (Rust, Go, LLVM, Zig, GHC, OCaml, Gleam) converged on five patterns; each
maps to a leg of this design:

| Pattern | Exemplars | Leg here |
|---|---|---|
| Single in-repo orchestrator in the project's own language; shell demoted to bootstrap wrappers | Rust `x.py`/compiletest/citool, Go `cmd/dist`, Zig `zig build test`, LLVM lit, GHC Hadrian, OCaml ocamltest | `medaka gate` (#2176) |
| CI config generated from typed data, drift-linted | GHC `gen_ci.hs`; Rust citool (moved off an untyped script that "could bypass testing") | generated ci.yml (#2177) |
| Sharding derived from measured per-test times, continuously | Go `cmd/dist` load-balanced shards | derived scheduling (#2178) |
| Graph-derived, fail-open test selection with explicit reverse edges | LLVM `compute_projects.py`; Pants/`gta` dep inference from the language's own imports | project scoping (#2179) |
| Auto-advancing baselines + structured override annotations in the commit | GHC perf git-notes / `Metric Increase 'reason'` | cost ratchet (#2180) |
| Three tiers; heavy tier post-merge with revert-to-green culture | Rust crater, Go port matrix, LLVM buildbots, GHC nightly | tier-3 charter (#2181) |

## 3. Target architecture

### 3.1 The gate registry (#2176) — the keystone

A manifest under `test/` (format: [GATE-REGISTRY-DESIGN.md](GATE-REGISTRY-DESIGN.md))
declaring, per gate: name, **semantic area**, **owning project**, **tier**, **cost
class**, oracle deps, fixture corpora, and invocation. A `medaka gate` subcommand
(sibling of compiler/tools/test_cmd.mdk) lists, selects, runs, and reports. Migration
is incremental: every existing gate enrolls first as a wrapped shell exec
(behavior-neutral), a drift gate makes registry↔tree divergence red, and in-language
rewrites happen opportunistically — starting where both arms are `./medaka` itself.
Oracle-binary differentials, clang/sqlite3-CLI/git/cachegrind gates stay exec wrappers
indefinitely; the registry, not the rewrite, is the point.

What this retires: the three-consumer bookkeeping becomes three *readers of one
artifact*; "a gate exists but nothing runs it" becomes impossible by construction
rather than caught after the fact.

### 3.2 Generated ci.yml (#2177) — AS LANDED

**Generated:** the `gates` job's eight-row `matrix.include:` block, and only that.
`medaka gate ci` (`make gen-ci`) reads `test/gates.toml` in-process — the same
`parseRegistry`/`parseShards` path `medaka gate list` answers from, never a re-parse
of `--json` through a shell pipe — and rewrites everything between one marker pair in
`.github/workflows/ci.yml`:

```yaml
          # GENERATED:BEGIN gates-matrix — `make gen-ci` (medaka gate ci) from test/gates.toml. DO NOT EDIT BY HAND.
          ...
          # GENERATED:END gates-matrix
```

Both markers are whole YAML comment lines at the block's own indent, and the generator
refuses a file that does not carry exactly one of each in order. Per row: the order and
`name` come from `[[shard]]`'s file order; `full_cores:`/`wasm_arm:` are emitted **only
when true** (ci.yml's key-omitted-when-false convention is the generator's encoding of
`false`, which is why the registry insists the boolean is *present*); the comment block
is the row's `rationale` file (`test/gate_shards/<row>.txt`) verbatim, one `# ` prefix
per line, a bare `#` for a blank one; and `pattern:` names every `[[gate]]` whose
`shard` is that row.

**`pattern:` is a literal name list, not the hand-written globs it replaced.** The
registry records one `shard` per gate and no globs, so the resolved gate-name list is
the only thing derivable from it; byte-identity with the old strings is unreachable and
was not attempted. What is preserved — and what `run_gates.sh` actually consumes — is
the SET each row resolves to under the two-glob rule (`test/<pat>.sh` and `<pat>.sh`
from the repo root). Verified at landing for all eight rows, no sampling: identical
sets, 201 gates, empty diff. Token order inside a row is registry declaration order.

**Hand-written, and deliberately so:** everything else in ci.yml — triggers, `detect`,
build-once, caching, the per-shard steps, and **all named-gate steps** in
`soundness`/`compiler-soundness`/`wasm`. The named-gate steps are not generated because
the registry cannot say which job runs which: `shard = "other-job"` is one sentinel
covering seven jobs, and no other field discriminates them.
`check_fingerprint_parity` and `check_keyword_sync` carry identical values in every
scheduling field (`area = "types"`, `shard = "other-job"`, `project = "compiler"`,
`tier = "merge"`, `cost = "cheap"`, `kind = "exec"`), yet the first is a step of
`compiler-soundness` under that job's `needs.detect` guard and the second is a step of
`soundness`, which ci.yml documents as deliberately *unguarded*. Generating them would
mean hard-coding a job→gate-name table in the generator — moving the authority out of
ci.yml without moving it into the registry. Their coverage is a reachability question
(`diff_compiler_ci_shard_coverage.sh` counts a literal name in a step as covering that
gate) and belongs to #2191's gate-registry verification, not here. Modelling job
placement per entry would be a registry schema change, not a generator change.

**Byte-determinism** follows `test/gen_docs_index.sh`: every list is a fold over file
order — no sort, no locale-sensitive comparison, nothing read from the environment —
and `make gen-ci` pins `LC_ALL=C` anyway so the two generators keep one story.
Regeneration is idempotent and writes only on a real change, so
`make gen-ci && git diff --exit-code` is the drift check.

**Drift gate — AS LANDED (S-3, #2177).** `test/diff_compiler_ci_gen_drift.sh` wraps
exactly that: `LC_ALL=C medaka gate ci` then `git diff --exit-code -- .github/workflows/ci.yml`,
mirroring the pre-existing "Docs index must be regenerated, not hand-edited" step
byte-for-byte in shape. The contract's §3.2 named two ways to resolve the tension
between "cheap/always-running/required" and "the generator is in-binary": (a) a CI job
that downloads the already-built binary artifact (`setup-medaka`, `binary: artifact`,
same as `gates`/`compiler-soundness`/`wasm`), or (b) a text-only reimplementation
outside the binary. **This slice takes (a)** — (b) would be a second TOML/generator
implementation to keep in sync with the one in `compiler/tools/gate_cmd.mdk`, which
contract §4.4/§4.6 rule out. The job (`ci-gen-drift` in `ci.yml`) is **ADVISORY ONLY**:
it is not in the required-status-checks ruleset, because adding a required context is a
`gh api` ruleset edit that is not atomic with a commit ([W-GH-WRITE-VERIFY]) — see this
slice's report for the exact command to promote it once Val is ready.

Enrolled as `diff_compiler_ci_gen_drift` in `test/gates.toml` (`shard = "other-job"`,
its own job, not a `gates` matrix row) and in `test/preflight.sh` (the `test/gates.toml)`
and `compiler/tools/gate_cmd.mdk)` arms, plus a new `test/gate_shards/*)` arm — not
`.github/workflows/ci.yml` itself, which stays unmatched (falls through to the FULL
suite) to avoid narrowing an unrelated ci.yml hand-edit's coverage.

### 3.3 Semantic identity ⊥ scheduling (#2178) — decision: option B

- The registry's semantic area is what **failure reporting** surfaces — job summaries
  and annotations say "backend: diff_compiler_ir_size failed", never "gates-3 failed".
- **Shard assignment is a derived output**: a balancer packs gates into N executors
  from per-gate timings recorded by the driver on green merge_group runs. Executor
  names go neutral (`gates-1`…`gates-N`) so no name can lie about contents.
- Assignments are **committed** (generated), not computed per-run — a rebalance is a
  reviewable diff; the balancer has hysteresis so timing noise doesn't churn it.
- The required-context rename is a 3-step ruleset migration (add new contexts → swap →
  delete old); a ruleset edit is not atomic with a commit — plan it as its own PR
  pair. Oracle-cache keys keep the derive-from-pattern property or re-key
  deliberately (see `.claude/dossier/ci.md` § oracle cache keying).

### 3.4 Dependency graph + project scoping in the queue (#2179)

**Queue posture (decision, Val 2026-08-28):** the merge queue **never narrows the
compiler suite** — full compiler gates + soundness + compiler-soundness + wasm +
seed-health on every entry, exactly as today. The July 2026 silent-merge incidents
(two independently-green branches merging into a broken tree) that earned the
"queue runs everything" policy were all compiler-infra collisions; that half stays
load-bearing, and queue-narrowing the compiler suite is explicitly **out of scope**
(a separate future decision, if ever). What narrows is the **library-project
suites**: an entry runs a project's gates only when the graph says the diff can reach
that project.

Mechanism:

- The compiler already computes the module dependency graph
  (compiler/driver/loader.mdk); a CLI surface (extend `medaka manifest`) emits it for
  all project roots. The graph is derived from the language's own import data, so it
  cannot rot relative to the code (the Pants/`gta` property).
- Selection = changed files → reverse closure over that graph → affected projects,
  **plus declared reverse edges imports cannot see**: project files used as
  compiler-gate corpora. Known at adoption: sqlite and gzip sources feed
  test/wasm/diff_sqlite.sh and test/wasm/diff_gzip.sh in the required `wasm` job.
  These live in the registry's fixture-corpus field — derived, never hand-listed.
- Never workflow-level `paths:` filters on required checks (deadlocks required
  contexts; `paths:` does not work with `merge_group`). Selection is an
  always-running detect-style job gating *steps* — the T-4b shape ci.yml already
  uses.
- **Fail-open, enumerated**: selector error → full; graph emission failure → full;
  changed path unmapped by graph and prose-allowlist alike → full. Backstops: the
  nightly full run and the revert-to-green norm (§3.6).
- **Eject-readiness test**: a project whose CI is registry-scoped, graph-selected,
  and self-contained under `<project>/test/` extracts to its own repo trivially.
  "Could this project's CI leave the monorepo tomorrow?" is a standing design test.

### 3.5 The cost ratchet (#2180)

GHC's perf-notes model applied to CI cost:

- **Baseline**: per-gate wall time from the queue's own green runs; auto-advancing;
  no human ever types a cost number into the tree.
- **Budget gate** (required, text-only, cheap): red when a registry entry lacks a
  cost declaration, when measured cost exceeds the declared class beyond a tolerance
  window, or when the projected pole exceeds budget.
- **Structured override**: the failing gate prints the exact acknowledgment string to
  paste into the commit/PR body; with it, the change passes and the acceptance is a
  greppable artifact in history. The remedy menu (declare / split / demote to
  nightly / override) is taught inline in the failure message, because the author is
  usually an agent mid-task.
- Budget is per-gate cost + projected pole — never raw shard wall, so "gate got
  slower" is distinguishable from "gate got rebalanced onto a busier shard".

### 3.6 Tiers (#2181)

| Tier | Runs | Contents | Failure protocol |
|---|---|---|---|
| 1 — smoke | `pull_request` | preflight-narrowed shard subsets (unchanged) | fix before merge |
| 2 — merge | `merge_group` | full compiler suite always; project suites graph-scoped | queue bounces the PR |
| 3 — heavy | nightly / post-merge | deep perf arms, fuzz, e2e, external-tool gates, breadth suites | auto-filed `known-red` issue naming the commit range; **revert-to-green over fix-forward** |

The tier-3 charter states what qualifies (cost above threshold, breadth beyond queue
needs, external tool deps) and what never demotes (soundness-class gates — anything
whose failure means a wrong answer shipped — stay tier 2 regardless of cost). Every
nightly job cites its qualifying clause; every tracked test/census script has an
explicit home (queue-tier, nightly-tier, or listed on-demand tool).

## 4. What deliberately does NOT change

- The merge queue is the authority; preflight and PR CI are filters
  ([L-PREFLIGHT-IS-FILTER]).
- Fail-open bias everywhere: a wrongly-included gate costs minutes (free on a public
  repo); a wrongly-excluded gate is a bug that reaches the queue.
- Zero-approval, checks-are-the-gate merging; agents self-merge on green.
- The soundness job's role (typecheck + fixpoint + must-fail) and seed-health's
  trust-anchor role.
- Oracle staleness and coverage guarantees ([G-STALE-ORACLE], project enrolment)
  carry over into registry form — subsumed, never dropped.

## 5. Sequencing

#2176 (registry) → #2177 (generated ci.yml) → {#2178 scheduling, #2180 ratchet};
#2179 (graph scoping) and #2181 (tier charter) can start immediately in parallel.
Each sub-issue is sprint-sized or splits into sprints via the normal sprint-plan
machinery. The registry wraps before it rewrites: no behavior change lands in the
same slice as an enrolment change.

## 6. Known risks

- **Registry as single point of failure**: a bug in the driver/selection is a bug in
  everything. Mitigation: the drift + enrolment gates are independent text-only
  checks; fail-open is enumerated per mechanism, and fault-injection tests (a
  deliberately broken selector must produce a FULL run) are acceptance criteria.
- **Balancer churn**: committed assignments + hysteresis; a rebalance is a reviewed
  diff, not ambient motion.
- **Ruleset migrations** (neutral names, any new required context): never atomic with
  a commit; always add → swap → delete, and read the ruleset back after every edit
  ([W-GH-WRITE-VERIFY]).
- **Scoped-out project breakage reaching main**: accepted by design, bounded by the
  nightly full run + auto-filed known-red + revert norm — the same trade Go and LLVM
  make on their heavy tiers.
