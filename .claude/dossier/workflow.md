## [W-PR-FLOW] Every change goes through a PR

No further narrative beyond the rule itself — kept in full in AGENTS.md.

## [W-PR-HELPER] Prefer `scripts/pr.sh`

Hand-rolled `gh` writes and `gh pr merge` exit codes carry no signal for the shapes #1212/#1213
record. The raw commands remain documented in AGENTS.md because the failure explanation still
matters; the helper just makes the verified-correct sequence one command instead of a
hand-rebuilt ritual.

## [W-REQUIRED-CHECKS] Deriving required checks

The `…/branches/main/protection…` endpoint 404s with `"Branch not protected"`, which reads
exactly like "nothing is required here" — it does NOT mean that; required checks live in a
repo RULESET instead. That single 404 is also the reason `git push origin main` fails with a
*rules* message (`GH013`) rather than a permissions one — the two facts share one root cause
(rulesets vs classic branch protection).

This section used to claim "Ten" required checks while `wasm` was already required (#597) —
wrong count, silently stale. The 404 above misled `ci.yml` (x2) and this file into treating
`wasm` as advisory for two days while it was actually required, and it misrouted #597's whole
design.

`diff_compiler_ci_shard_coverage.sh`'s input is the whole TREE, not `test/` — a `.sh` added
anywhere (even under `.claude/`, as a repro harness once was) trips the "matches no shard"
check, per the measured 2026-08-14 incident where exactly that reddened `gates (tools)`.

## [W-SHARD-COST] Three generations of wrong shard-cost rankings

Shards are scheduled by cost, not theme. This paragraph's cost ranking has been wrong **three
times**, each time in a way that misrouted real work:

1. `~5.8 min` for `engines` rotted when that shard was given the whole runner (`full_cores`,
   `ci.yml`) and misrouted #597's design.
2. The replacement claim — *"`gates (types)` was the pole and `engines` the cheapest heavy
   shard"*, sourced from three July 2026 runs — was measurably false by 2026-08-13. A Stage B
   orchestrator repeated it out of this file into an implementer's brief instead of running the
   derivation command.
3. Measured on two consecutive green `merge_group` runs (`31655422530`, `31653614351`):
   **`engines` is the POLE (373s/364s) and `eval` the CHEAPEST (149s/151s)**; `types` 322/324 ·
   `frontend` 289/291 · `tools` 202/213 · `sqlite` 185/191 · `backend` 165/160.

Those numbers are recorded here to show the ranking INVERTED across generations, not for reuse
anywhere — a ranking is an encoded fact with no derivation and no expiry. AGENTS.md keeps only
the derivation command, never a number.

## [W-SOUNDNESS] Why `soundness` exists

A compiler with unbound constructors once shipped to `main` with every gate green, because
`make medaka` does not gate on type errors and no gate shard catches an ill-typed compiler.
`soundness` (`typecheck_compiler_source.sh` + the self-compile fixpoint + doc gates) is the only
required check that would have caught it.

## [W-MERGE-QUEUE] The merge-queue crash incident

Live since 2026-07-13. Two green branches merged cleanly into a **crashing** tree: git
auto-merged a break it could not see — one branch had added a caller into machinery the other
was re-signing, on different lines, so no conflict marker ever appeared. This is why the queue
(which tests the PR merged onto current `main` plus everything queued ahead of it) is the real
authority on gate coverage, not the `pull_request` run in isolation.

"Strict" mode is OFF and `update-branch` kicks are obsolete — the queue handles staleness. If a
doc tells you to babysit a `BEHIND` branch, that doc is stale.

## [W-MERGE-EXIT-CODE] Opposite exit codes, both successes

`gh pr merge --auto --merge` prints `! The merge strategy for main is set by the merge queue` on
success — but its exit code carries no signal either way. Observed on two separate successful
calls: one exited **1** (an orchestrator read that as a failed action, re-ran the command, and
got back "already queued to merge" for the PR it had just declared failed); another exited **0**
(auto-merge armed, PR not yet queue-eligible because required checks were still running). Same
warning both times, opposite exit codes, both successes.

`autoMergeRequest` reads `null` while queued, indistinguishable from "never armed" — that field
is not the signal to check either; `isInMergeQueue` via GraphQL is.

This repo has hit both directions in one session: a tool reporting *success* while nothing
happened (a silently no-op'd `gh` write, a blanked message body), and here a tool reporting
*failure* while the action happened. The fix for both is the same: verify the resulting state,
not the return code.

## [W-BACKLOG] Backlog queries

No further narrative beyond the four `gh issue list` commands — kept in full in AGENTS.md.

## [W-SEVERITY] Severity ladder

No further narrative — the four-rung ladder (`S0`→`S1`→`S2`→`S3`) is a map, kept in full in
AGENTS.md.

## [W-QUIETER] Three quieter-is-worse case studies

Three instances in one session (2026-07-24/25), each caught by a reviewer noticing rather than
by any gate:

- **#1072** — a fix replaced an `unreachable` crash with a **wrong answer at exit 0**. Strictly
  worse: it removed the only loud signal that shape ever produced.
- **PR #1007** (fixing #1002) — an index fix turned *"returns nothing, so the rename driver
  refuses"* into *"returns a confidently wrong edit set the driver applies."*
- **PR #996** — the same transition, one PR earlier, in the same subsystem.

Applying the reviewer's question ("does this fix turn a path that returned NOTHING into one that
returns SOMETHING?") to a green PR caught a language regression before it merged.

## [W-VERIFIED-VS-REPRO] Six already-fixed entries

When the backlog was re-derived against the binary on 2026-07-14, six entries were already
fixed — including two "silent build miscompiles", a duplicate-definition segfault, and a
`newtype` bug billed as "the best value-to-risk item on the board".
