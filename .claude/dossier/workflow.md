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

## [W-MODULE-BLIND] A call-site-free module is invisible to every gate

`compiler/types/registry.mdk` (Stage A-2 unit A-2.0, #1111) landed with zero call sites —
by design, since it is the substrate a *later* unit re-keys onto — and that had a hazard
nobody had priced: a module outside every entry's import closure is invisible to `make
medaka`, to `make check-self`, and to `test/typecheck_compiler_source.sh` (pass 1 walks
`compiler/driver/medaka_cli.mdk`, pass 2 covers `compiler/entries/*.mdk`; a substrate
module sitting in neither is in NO GATE). The original header answered the composite-key
hazard with doctests, and NOTHING RAN THEM.

MEASURED 2026-08-03: with `regSize (Registry m) = "not an int"` injected into the file,
`./medaka check compiler/driver/medaka_cli.mdk` exited 0 and `make check-self` printed
PASS — a wrong answer, in a file with ~90 doctest assertions, caught by zero required
checks. The fix: the Makefile's `test:` target now names the module explicitly, since
`medaka test <file>` typechecks the file before running its doctests, putting both the
types and the assertions inside the required `inlang` check (`make test`). Every later
A-2 unit inherits this hazard — a unit that lands a call-site-free module and forgets its
Makefile line has shipped unverified code with every gate green.

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

## [W-CODEX-WAITS]

On 2026-09-19, transcript accounting for Codex sprints #3178 and #3183 found
that responses issuing agent waits, process polls, or outer-tool waits carried
48% and 37% of their input tokens. Most input was cached; these are activity
shares, not subscription-charge measurements or promised savings. A single
agent wait does not itself consume repeated model responses while suspended.

Bounded nested-agent experiments on Codex CLI 0.155.0, using fresh Terra/high
contexts, separated three mechanisms:

- An orchestrator launched an implementer running `sleep 125` and issued one
  180,000 ms `wait_agent`. Child completion woke it before timeout, with no
  intermediate orchestrator inference. This establishes tool capability;
  it does not override a host instruction limiting waits to 60,000 ms.
- A second orchestrator launched the same task, then ended its turn. Its
  child completed, but no new orchestrator turn appeared during the observed
  interval (at least 46 seconds after child completion). Ending a turn is
  not an established suspend/resume protocol.
- Each worker made two 60,000 ms process polls inside `functions.exec`.
  The outer calls yielded after their default 30,000 ms, adding two
  `functions.wait` calls. A process handle and a running-cell handle represent
  different pending operations; waiting on the latter must finish before
  polling the former again.

A matched 95-second experiment printed `PROGRESS` after 20 seconds and exited
7 after another 75. Both workers used an initial 1,000 ms exec yield and
55,000 ms process polls. The control left the outer yield at its default;
the treatment used a 60,000 ms outer yield. Both preserved the output and
exit 7, with two process polls each; the control needed one extra cell wait,
the treatment none. Their orchestrator handled one normal timeout, two
nonterminal progress wakes and two final wakes without mistaking progress
for completion. Total worker responses were nevertheless seven in each arm:
the treatment sent a redundant final message before its final reply, spending
the saved response. This is why the adapter also avoids duplicate hand-backs.

A silent 70-second repeat exposed a correctness trap in the control. Its
outer cell returned `Script completed`, but the enclosed result still carried
process session 35348 and no `exit_code`. The worker nevertheless reported
exit 0 and ended its turn before the sleep finished. That arm is invalid as a
cost comparison. The aligned arm observed exit 0 explicitly and used no cell
wait. Require the process's terminal result, not the wrapper's completion
banner. The process subsequently ended naturally; it was not left running.

A fresh orchestrator/worker pair then read the proposed adapter rather than
receiving its numeric recipe in the prompt. For `sleep 95`, the worker used
the 30,000 ms initial yield, two process polls, and zero cell waits. The
orchestrator used two 60,000 ms waits (one timeout, one completion).

An independent fresh Astra session verified the configurable part: a
per-invocation `developer_instructions` override allowing 180-second idle
waits and exempting idle heartbeat updates was received, and a nested
`sleep 75` probe used one 180,000 ms orchestrator wait that returned on child
completion. This is an instruction override, not a timeout configuration key;
it changes neither sandbox policy nor permission requirements. The saved
user-config version was then checked separately, preserving all prior values.
With that saved configuration (no per-invocation instruction override), a fresh
Astra orchestrator and one fresh implementer read the adapter and ran
`sleep 105`. The orchestrator used one 180,000 ms wait; the worker used a
30,000 ms initial yield and one process poll inside an explicitly extended
outer call, with zero cell waits and an observed process exit 0. One terminal
report reached the orchestrator. This verifies the saved setting in a new
session, not retroactive changes to an already-running session's instructions.

To repeat the mechanism check after a harness upgrade, start a fresh
orchestrator that launches two fresh implementers. Run the same harmless
timed command in both arms with the same process-poll duration; vary only the
outer execution yield (default versus longer than the inner wait). Preserve
the structured results. Count increasing `token_count` cumulative totals
once per thread, not every repeated usage event; cached input and reasoning
are subsets of input and output. Compare outer cell waits, actual terminal
status, and final-report delivery as well as token totals. Do not add status
pings or duplicate final messages to either arm. Separately test progress and
failure so a cheaper wait cannot silently lose either.

The operating instructions are in [.codex/SPRINT.md](../../.codex/SPRINT.md).
These probes do not establish savings for a full sprint, cross-model behavior,
or process cancellation. Keep the next real sprint's transcript as the
workload-level check; do not turn timing-sensitive model calls into a compiler
CI gate.

The same instruction revision makes Codex implementation tiers depend on
remaining reasoning, not severity or file count. A fresh read-only model-choice
probe selected Terra for a settled six-consumer S0 remedy, an existing-pattern
CLI flag, and a representation change whose design was already settled; Sol
for an unresolved coherence rule. It rejected upgrading for a permissions
failure and retained the Sol end reviewer. This checks instruction uptake,
not Terra's implementation quality on those hypothetical packets.
