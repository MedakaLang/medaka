# CI-ARCHITECTURE.md — target architecture for Medaka's CI

**Status:** PARTLY BUILT — adopted 2026-08-28 (Val), epic #2182 (sub-issues
#2176–#2181). This doc is the design authority for the epic; the sub-issue bodies are
scope ledgers that point back here. Companion:
[GATE-REGISTRY-DESIGN.md](GATE-REGISTRY-DESIGN.md) (the registry format).

Per-section status — derive the authoritative version from the issues
(`gh issue view 2182`), never from this table alone:

| § | Sub-issue | State |
|---|---|---|
| 3.1 registry + `medaka gate` | #2176 | BUILT |
| 3.2 generated `ci.yml` | #2177 | BUILT (`ci-gen-drift` is a required context) |
| 3.3 identity ⊥ scheduling | #2178 | BUILT — derived assignment, area-reported failures, and the neutral executor names |
| 3.4 graph-scoped project suites | #2179 | NOT STARTED |
| 3.5 cost ratchet | #2180 | BUILT. ⚠️ Its `gate-budget` job is NOT in the required-check set (derived from ruleset 18885875, 2026-08-30) — a red budget does not block a merge. `ci-gen-drift` IS required, and it runs `medaka gate balance --check`, so a hand-edited assignment is blocked; an over-budget one is not. |
| 3.6 tier-3 charter | #2181 | NOT STARTED |

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
   [W-THIRD-CONSUMER] bookkeeping. **Two of the three are closed as of #2177:** the
   ci.yml matrix is generated from `test/gates.toml` (S-2) and drift-gated (S-3), and
   the coverage gate reads the registry's `shard` field instead of re-parsing that
   matrix (S-4, `docs/ops/GATE-REGISTRY-DESIGN.md` §8). `test/preflight.sh`'s path map
   is the remaining hand-maintained copy.

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

S-4 (#2177) sharpened that reachability question rather than answering it with a new
field: an `other-job` entry must now be named by a real `run:` step **or** be on
`test/CI-COVERAGE-EXCEPTIONS.txt`, and one that is neither reds. The registry still
does not record *which* job — that stays a workflow fact, scanned, not declared. See
`docs/ops/GATE-REGISTRY-DESIGN.md` §8 for the full division of labour.

**Byte-determinism** follows `test/gen_docs_index.sh`: every list is a fold over file
order — no sort, no locale-sensitive comparison, nothing read from the environment —
and `make gen-ci` pins `LC_ALL=C` anyway so the two generators keep one story.
Regeneration is idempotent and writes only on a real change.

**Drift gate — AS LANDED (S-3, #2177), REWORKED (F-1).** The drift check is
`LC_ALL=C medaka gate ci --check`: it computes the generated text and compares it
IN MEMORY to the file on disk, writing nothing and shelling to no `git`.

S-3 originally shipped the `docs/README.md` shape — regenerate, then
`git diff --exit-code -- .github/workflows/ci.yml` — and the end-of-sprint review
found that shape has two defects sharing one root cause. It **heals what it checks**:
an uncommitted hand-edit inside the region is overwritten by the write step before the
diff runs, so the gate passes having silently destroyed the edit (S0). And it
**misattributes**: `git diff` on the whole file also fires on an uncommitted edit
entirely OUTSIDE the generated region, then blames the region. `--check` has neither
property, and its scoping is by construction rather than by convention: `ciNewText`
copies every line before the BEGIN marker and every line from the END marker onward
verbatim, so an edit outside the region appears identically on both sides of the
compare and can never make the check fire.

The contract's §3.2 named two ways to resolve the tension
between "cheap/always-running/required" and "the generator is in-binary": (a) a CI job
that downloads the already-built binary artifact (`setup-medaka`, `binary: artifact`,
same as `gates`/`compiler-soundness`/`wasm`), or (b) a text-only reimplementation
outside the binary. **This slice takes (a)** — (b) would be a second TOML/generator
implementation to keep in sync with the one in `compiler/tools/gate_cmd.mdk`, which
contract §4.4/§4.6 rule out. **At this slice, S-3**, the job (`ci-gen-drift` in `ci.yml`)
was ADVISORY ONLY: it was not in the required-status-checks ruleset, because adding a
required context is a `gh api` ruleset edit that is not atomic with a commit
([W-GH-WRITE-VERIFY]). ⚠️ **`ci-gen-drift` is now one of the 14 required status-check
contexts** — Val performed the ruleset edit; derive the current list rather than trust
this paragraph (AGENTS.md [W-REQUIRED-CHECKS]).

**Required-tier backstop (F-1), still live even though the promotion landed.** Because
that job was advisory at F-1 time, the review found a hand-edit dropping gates from a
matrix row passed every REQUIRED check: after S-4's repoint, `test/diff_compiler_ci_shard_coverage.sh`
reads shard membership from the registry and no longer looks at ci.yml's matrix at all.
That gate — which IS required — makes the same `medaka gate ci --check` assertion itself,
as a plain shell step before its `python3` block, so matrix-vs-registry agreement is
proven at the required tier independently of `ci-gen-drift`'s own tier. One mechanism, two
callers, now both required.

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
  names go neutral so no name can lie about contents. **AS BUILT the spelling is
  `gates_1`…`gates_8`, with an underscore**, not the `gates-N` this section first
  proposed: `medaka gate verify`'s name-safety class allows only letters, digits, `_`,
  `.` and `/` in a registry name, and bending the name to the existing rule was
  preferred over widening a safety check for a cosmetic gain (Val, 2026-08-30).
- Assignments are **committed** (generated), not computed per-run — a rebalance is a
  reviewable diff. ⚠️ **AS BUILT, the hysteresis band annotates rather than decides**
  (S-4-S-derived-assignment, #2178): the emitted assignment is always the balancer's
  target, a pure function of (rows, costs, toolchains). A band that KEEPS a committed
  assignment differing from the target by less than its margin makes "the derived
  assignment" a set rather than a value, and a drift check can only police a value —
  measured, a one-gate hand edit moved the pole by 0s and `--check` called it balanced.
  The cost of dropping it is that a cost re-ingest whose noise moves a gate now moves
  that gate in `test/gates.toml` too; the repair is two mechanical commands.
- The required-context rename is a 3-step ruleset migration (add new contexts → swap →
  delete old); a ruleset edit is not atomic with a commit — plan it as its own PR
  pair. **AS EXECUTED** (2026-08-30): PR A renamed the matrix rows AND added eight
  `gates_alias_*` jobs whose display names are the eight retired `gates (<theme>)`
  contexts, each gating on `needs.gates.result` — the roll-up of all eight rows, so an
  alias is green only when EVERY row is, which is strictly stronger than the per-row
  context it stands in for. That makes the window between PR A and the ruleset swap
  safe in both directions: the old required contexts keep reporting, and nothing the
  old set would have caught can slip through. The ruleset then swaps to the eight
  `gates_N` contexts, and PR B deletes the aliases. **All three steps COMPLETED
  2026-08-30**: PR #2260, the ruleset swap (`18885875`, verified by read-back — 14
  required contexts, the eight `gates (…)` gone), PR #2274. The required set is now
  `gates_1`…`gates_8`. ⚠️ The rename blanks
  `gate balance`'s calibration column (it keys the recorded run rows by shard name, and
  no run has reported under the new names yet) — fail-open by construction, self-heals
  on the first post-rename cost ingest. Oracle-cache keys keep the derive-from-pattern property or re-key
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

**AS LANDED (S-5, epic #2182, `docs/ops/GATE-REGISTRY-DESIGN.md` §14):**
`medaka gate budget`, run by `test/diff_compiler_gate_budget.sh` as its own `gate-budget:`
job (`shard = "other-job"`, same "cannot certify a number it can move" reason as
`gate-balance`). The override is a `Gate-Budget-Override: <token>` trailer on an AUTHORED
commit message in the change under test — the one thing a `merge_group` run can always see,
since it has no PR body. Not yet in the required-checks ruleset, the same state
`gate-cost`/`gate-balance` are still in — a separate, non-atomic `gh api` edit.

⚠️ **The trailer is NOT read with `git log -1` on HEAD** (that was S-5's bug; review finding
S1-2, fixed by FR-2). `actions/checkout@v4` with no `ref:` checks out a SYNTHETIC merge
commit on `pull_request` and on `merge_group` — GitHub-authored boilerplate, never the
author's text — so the `gate-budget:` job resolves the authored range from the event
payload's own base/head SHAs, exports it as `GATE_BUDGET_COMMIT_MSG`, and the `.sh` wrapper
prefers that whenever it is set (`gate_cmd.mdk` still touches no git state). Mechanism and
the measured evidence: `docs/ops/GATE-REGISTRY-DESIGN.md` §14.

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
- **Balancer churn**: committed assignments; a rebalance is a reviewed diff, not
  ambient motion. ⚠️ Hysteresis was NOT the mitigation that survived — see §3.3: it
  is the churn damper that a hand-edit check cannot coexist with. What bounds churn
  instead is that the cost baseline is a committed file re-ingested deliberately, so
  a reshuffle only ever arrives inside a commit someone chose to make.
- **Ruleset migrations** (neutral names, any new required context): never atomic with
  a commit; always add → swap → delete, and read the ruleset back after every edit
  ([W-GH-WRITE-VERIFY]).
- **Scoped-out project breakage reaching main**: accepted by design, bounded by the
  nightly full run + auto-filed known-red + revert norm — the same trade Go and LLVM
  make on their heavy tiers.
