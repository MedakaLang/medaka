# Writer packet

Dispatch only when every required field is concrete.

## Identity

- Slice ID and stage acceptance criterion.
- Exact base/head, branch, absolute isolated worktree.
- Authorized files and named regions/symbols.
- Active-writer collision matrix and abort condition.
- Git-index boundary: assume isolated writer index writes may fail. Writer owes a
  coherent diff and check receipts; conductor owns application, commit, and
  exact-head integration verification.

## Contract

- Objective and explicit non-goals.
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
