---
name: medaka-emitter-sprint
description: Conducts batched design and rolling implementation sprints for Medaka emitter epic #1398. Use for X-N/X-W/X-L sprint intake, candidate synthesis, serial integration, and one-PR finalization.
---

# Medaka Emitter Sprint

Use this skill with `medaka-throughput-sprint` for a coherent stage-sized #1398
sprint. The generic skill owns continuous writer occupancy, prepared queues,
parallel verification/CI, metrics, GitHub durability, repair, and enqueue
approval. This skill supplies emitter-specific admission and verification. It supplements
`medaka-epic-intake`, `medaka-emitter-state-migration`,
`medaka-structural-migration-tests`, `medaka-continuation-receipt`,
`medaka-verification-scope`, and `medaka-pr-lifecycle`.

## 1. Admit the run

Fetch and pin `TASK_BASE`, create the detached intake worktree, and derive
readiness from tracker, merged history, and source. Create a unique disposable
run root only after the milestone is selected:

```text
/var/tmp/medaka-scratch/opencode/emitter-sprint-1398/<base12>-<utc>/
```

Record admission in `ADMISSION.md`: exact base, intake/topic paths, branch or
detached state, clean porcelain, owners, and the derivation of the selected
pre-fan-in lane. Never carry a residual count or issue status from a prior run.

The tracked sprint document is a durable protocol and scope proposal, not live
state. Runtime packets, command logs, captures, receipts, and reviews stay in
the disposable run root and are deleted at wrap-up.

## 2. Phase 0 is a read-only evidence DAG

Run bounded packets against one exact revision in this dependency order:

1. `P0-INTAKE`: tracker/history/source readiness and completed carriers;
2. `P0-CENSUS`: normalized raw authority set, then semantic-family grouping;
3. parallel `P0-APPARATUS-<family>` siblings for census-selected candidates:
   executable routes, P/U/read/observable matrix, route classification, and
   capture-hook feasibility;
4. parallel `P0-DESIGN-A` and `P0-DESIGN-B` after their required census and
   apparatus packets exist: smallest coherent candidate and nearest alternative;
5. `P0-SYNTHESIS`: conductor-adjudicated selection or explicit deferral;
6. `P0-REVIEW`: fresh independent audit of synthesis, fail-capability, sizing,
   mirrors, and residuals.

The census reports sets and evidence, not architecture. Candidate designers do
not select the sprint winner independently. The conductor verifies decisive
premises and owns synthesis. All packets name producer, phase, base/head,
evidence status (`OBSERVED`, `DERIVED`, `RELAYED`, `OWED`), artifact paths, and
invalidation conditions. A relayed premise must be independently re-derived
before implementation admission.

Phase 0 completes only when every packet agrees on its revision and source
population. Resolve disagreement from source/evidence; never average reports or
merge their prose.

`P0-REVIEW` must exist as a durable packet before implementation dispatch.
Conversation relay or checkpoint prose does not satisfy admission. Review names
exact revision, source population, selected family, rejected alternative, slice
count/cohesion, and mutation-plan completeness.

## 3. Admit one implementation slice at a time

A selected family must pass all of these gates:

Select the smallest candidate by an independently movable semantic fact, not by
shared syntax, file locality, or carrier convenience. Before admitting a
multi-field cohort, compare every isomorphic one-field residual and record why
none is independently movable. Prefer the one-field slice when its producer,
consumer, lifecycle, and fail-capable proof close without another field.

1. one bounded implementer turn reaches a compile-coherent boundary;
2. semantic inputs stay in immutable input/validated-plan carriers;
3. all relevant declarations, producers, consumers, fallbacks, callers, and
   public routes are named; an ambient-state family additionally names
   initializers, resets, writers, readers, drains, and dynamic scopes;
4. current ordering, first-match policy, save/set/read/restore extent, output,
   and diagnostic behavior are fixed by authority or observed controls;
5. the apparatus is executable and fail-capable before exact assertions are
   authored;
6. each semantic field has a mutation design naming class, route, claim,
   mutation shape, and earliest stable expected-red rule; bind exact head,
   target bytes/anchor, commands, hashes, and receipt path only after the final
   implementation and harness freeze; an ambient-state family additionally
   designs reader/runtime, fresh-context U-absence, and legal renamed-authority
   roundtrip mutants;
7. focused verification, snapshot, selfproc, fixpoint, and deferred-CI
   obligations are explicit;
8. the residual authority set will be re-derived after the slice.

Every synthesized packet also names and tests the nearest program or route the
slice does **not** cover. It must state why that boundary remains correct or an
explicit residual; P0-REVIEW rejects an untested boundary claim.

Default to **4–6 serial slices**: one shared apparatus slice when needed, then
semantic slices sharing one carrier, scanner, and proof vocabulary. Three or
fewer needs an explicit reason the apparatus cannot amortize another coherent
field; more than six needs an explicit reason review and mutation contracts
remain one bounded claim. Split when verification authority, touched carrier,
or acceptance vocabulary changes materially. Never enlarge scope to hit a
count.

For X-L.H, replace ambient-state lifecycle gates with its own architecture
contract: derive catalog rows and provenance from the semantic extern source;
prove completeness without creating a permanent LLVM-only authority; define a
missing-row expected-red control; enumerate each current target collision
domain; and define fail-closed collision expected-red controls. X-L.H never
acquires reset/drain or renamed-Ref obligations merely by sharing this sprint.

If execution is needed to discover generated IR/WAT or diagnostic text, split
capture-hook work from exact assertions. A promising census candidate is not an
implementation packet.

## 4. Parallelize readers; prove writer disjointness; serialize integration

Read-only, revision-insensitive census/design/review packets may run in
parallel. Write-capable or race-sensitive work always receives its own
worktree/branch. Keep one `sprint-implementer` active whenever an eligible
packet exists. Additional writers are allowed only when the generic sprint
skill's disjointness proof passes; emitter mirror pairs, shared carriers,
fixpoint/seed provenance, and generated artifacts count as collisions even
when paths differ.

Provisional analysis of the next family may overlap implementation or
verification of the current family, but it is invalidated by any intervening
source change that can affect its census, routes, apparatus, or acceptance
boundary. Re-admit it against the new exact head before dispatch.

Only the conductor integrates. An isolated writer may have a read-only shared
Git index: require a coherent working-tree diff plus check receipts, not a local
commit. The conductor applies/commits that diff and verifies its exact integrated
head. Never share a writer worktree, merge generated
goldens, or allow two branches to derive snapshots from different compiler
states. Compiler-source landings and their exact-head measurements are serial.
Run mutation matrices only after integration, from a clean conductor-owned
worktree; writer-local mutation evidence is exploratory and cannot satisfy the
final exact-head matrix.

## 5. Checkpoint every integrated family

Before another family is integrated, require:

- stateless source feedback on the coherent daughter diff;
- targeted format and lint;
- the focused executable ownership/control harness with no phantom skip;
- compiler-source typecheck;
- native self-compile fixpoint;
- relevant Wasm typed/module/product route when Wasm is touched;
- re-derived snapshot and selfproc obligations;
- normalized residual authority set and no duplicate authority;
- fresh review of code and any new/materially changed harness.

Stop the sprint on an unexpected behavior change, premise conflict, invalid
apparatus, unexplained residual, or regression. Reconcile premise-changing
evidence with `compiler-designer`; ask the user only when externally observable
semantics or durable architecture direction requires a choice.

## 6. Finalize one reviewed batch

After the last accepted family, derive snapshots/goldens once, finish harness
repairs, and **freeze the integration head**. Heavy review and mutation run only
against that frozen exact head; any source or harness delta invalidates affected
rows and requires a new review boundary. Run one final mutation matrix on the
reviewed exact-head harness. Then inspect every generated diff, rerun their
gates, and apply proportional local
verification. Open one PR for the coherent batch and follow
`medaka-pr-lifecycle`; merge-group CI remains landing authority.

The PR and tracker handoff name every family moved, completed carriers not
duplicated, exact local receipts, review and mutation verdicts, the newly
derived residual set, and the next bounded census question. Run
`orchestrator-wrapup`, retain no disposable sprint artifact, and report any
intentionally retained branch or worktree.

Stop at `AWAITING OWNER ENQUEUE APPROVAL`; never enqueue full sprint PR without
fresh user approval.

## Do not create

- a shared-trunk writer fleet;
- another compiler implementer or backend-writer path;
- permanent `DECISIONS.md`/`DEBT.md` append-only ledgers;
- tracked logs, captures, receipts, or probe outputs;
- a fixed remaining-state count in workflow instructions;
- an implementation-ready label for a family before apparatus and plan review;
- mid-sprint golden merges or hand-resolved generated artifacts.
