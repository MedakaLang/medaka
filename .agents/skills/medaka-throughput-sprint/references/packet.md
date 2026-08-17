# Writer packet

Dispatch only when every required field is concrete.

## Identity

- Slice ID and stage acceptance criterion.
- Exact base/head, branch, dispatch mode, and conductor tree. Absolute writer tree appears only in `FRONT-SEAT` packets; harness chooses a fresh path per dispatch.
- `HARNESS`: writer derives tree first with `git rev-parse --show-toplevel` and proves it differs from conductor tree. `FRONT-SEAT`: conductor creates named tree; every agent tool call sets its absolute `workdir`, then writer validates toplevel equals brief path. `HARNESS+REBASE`: same as HARNESS plus exact licensed SHA-pinned rebase. All modes prove dispatch head descends from named sprint head.
- Classification: `parity` → `sprint-implementer`; `behavior-changing`, spike, or unstable DAG → `sprint-heavy-implementer`.
- Authorized files and named regions/symbols.
- Active-writer collision matrix and abort condition.
- Git-index boundary: assume isolated writer index writes may fail. Writer owes a
  coherent diff and check receipts; conductor owns application, commit, and
  exact-head integration verification.

## Contract

- Objective and explicit non-goals.
- Separate binding `property` from advisory `mechanism`; pair code-changing directives with fail-capable `acceptance`.
- Established semantic/architecture authority.
- Transformation over named sites.
- Callers, producers, consumers, fallbacks, and executable mirrors.
- Per-field route/read matrix: exact reader reached on each shipping/probe route;
  evidence classified as data-correctness, ownership-only, or vacuous.
- Invariants and performance constraints.
- Rejected approaches and known traps.
- Shared symbols/artifacts and deterministic integration order.
- Disjointness evidence when another writer is active.

## Acceptance

- Compile-coherent completion boundary.
- Direct reproducer or cheapest fail-capable minimum check.
- Nearest program/route not covered and expected behavior.
- Deferred local, CI, and repair-round obligations.
- `could move`: plausible acceptance/diagnostic/output changes.
- Overlap-review gate: shared carrier/harness/artifact regions whose prior slice
  must receive lightweight review before this packet becomes dispatchable.
- Expected generated/golden moves. Unlisted moves are findings, never blessing authority.

## Operational contract

- Packet is immutable after dispatch. Only `fact:` advisory evidence and `stop:` abort messages are valid mid-flight. Decline and record amendments.
- Push by explicit ref when authorized: `git push origin HEAD:refs/heads/<branch>`; never switch a branch held by another worktree.
- Stop on missed same-question site, changed owned region, invalid premise, semantic choice, or overlap. Do not silently widen scope.
- Return six sections: `Verdict`, `Evidence`, `Decisions surfaced`, `Deviations from packet`, `Not covered`, `Friction`. `NONE` is valid; missing section invalid.
- Evidence opens with externally observed time and includes derived worktree, exact head/base proof, commands, outputs, and artifact paths.
- Dispatch names report path. Agent returns literal `time:` plus all six sections; conductor persists response verbatim and validates it.

## Spike form

Spike produces knowledge, never landing code: attempt → observe → revert every tracked/untracked change it created → prove byte-identical named files and clean status. Return leaf DAG, discovered sites/premises/checks, and `SPIKE-DONE (stability: STABLE|UNSTABLE)`. Stable DAG may become parity family only when behavior remains provably unchanged; unstable DAG routes whole coupled slice to heavy implementer.

After implementation and harness freeze, use one exact-row packet per applicable
semantic-field/mutation-class pair:

```text
row_id:
semantic_field:
mutation_class: reviewed class; ambient examples include reader-runtime,
  fresh-context-u-absence, and renamed-authority
route:
claim:
exact_head:
target_file:
unique_anchor:
mutation_before:
mutation_after:
mutation_command:
prepare_command:
check_command:
expected_failure_id_or_set:
restore_check_command:
baseline_sha256:
receipt_path: unique caller-owned `--receipt-dir` retaining commands and logs
```

Generic carrier or legacy-family rows cannot substitute for reader/runtime,
fresh-context U-absence, or renamed ambient-authority rows. Unexpected green is
`BLOCKED_WRONG_TARGET` pending reviewer adjudication. The transaction helper
owns byte restoration; `restore_check_command` rebuilds restored derived
artifacts. Conductor runs the fixed matrix only after integration in its clean
worktree. Caller retains helper evidence at `receipt_path` and independently
records final blob, porcelain, and process checks.

Implementer records dispatch, first-edit, coherent-diff, and completion timestamps
from externally visible clock output; estimates are not receipts. Then it reads root
and nested `AGENTS.md`, named code, and direct callers. Discovery outside packet is
premise feedback, not silent scope growth. Return summary, diff, minimum check, owed
verification, premise conflicts, timestamps, blocked/rework time, and avoidable cost.
