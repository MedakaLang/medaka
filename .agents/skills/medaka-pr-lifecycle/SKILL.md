---
name: medaka-pr-lifecycle
description: Runs Medaka's verified PR, CI, merge-queue, tracker-handoff, and cleanup sequence. Use when opening, watching, enqueueing, or completing a Medaka PR.
---

# Medaka PR Lifecycle

Use this phase skill after adequate local signal. It centralizes state-readback
rules so conductor and child prompts do not need to repeat GitHub mechanics.
Repository instructions and the user's requested lifecycle remain authoritative:
before acting, record which phases and mutations the user or governing workflow
explicitly authorizes. Execute only those phases. Readbacks are always safe;
commit, push, PR create/edit/enqueue, issue comment/edit/close, and local
worktree/branch/scratch deletion each require authorization. A governing
compiler workflow's mandatory tracker handoff or cleanup rule counts as explicit
authorization for that named action, not for unrelated mutations.

## 1. Preflight the exact head

Record the topic worktree, branch, full head SHA, pinned base, clean status,
review state, locally graded checks, and deferred checks. Inspect `git diff`,
`git status`, and recent log before committing; stage named paths only. Do not
open or update a PR while a semantic decision or blocking finding remains.

## 2. Write and verify the PR

Use a body file so backticks, quotes, issue references, and blank lines survive.
Avoid accidental issue-closing keywords in explanatory prose. After creation or
any body edit, use the repository helper to write and byte-verify the body:

```sh
sh scripts/pr.sh body --number N --file /absolute/body.md
```

Read back title, body, state, head branch, and `headRefOid`. The body should
separate exact-revision local receipts from checks deferred to CI and must not
present captured output as semantic authority.

The body write and its readback are dependent operations. Never run them in
parallel: a concurrent read can return the previous body while the verified
helper is still writing, manufacturing a false no-op or stale-state report.
Finish the helper call first, then perform any additional GitHub readback.

## 3. Watch PR CI without duplicating it

Run independent review and narrowed PR CI concurrently. Use:

```sh
sh scripts/pr.sh watch --number N --interval 15 --timeout 1200
```

PR CI is a filter: a green narrowed shard may have executed no gate. When the
PR body claims a specific gate ran, inspect that job's steps rather than citing
the checkmark. On a red job, read `.claude/HANDOFF.md` and the failed log before
retrying; repair deterministic failures and push once rather than blind-rerun.
After every push, verify the PR's `headRefOid` and treat prior CI as stale.

## 4. Review and receipt deltas

Give the fresh reviewer exact verifier receipts for the reviewed SHA. For an
implementation-conforming repair, resume the same reviewer with only the new
delta and delta-specific checks. Carry an older receipt forward only under the
revision-inheritance rule in `medaka-verification-scope`; otherwise reverify the
affected property.

When receipts carry across a final non-executable delta, make the inheritance
explicit in both the review brief and PR body: name the fully verified SHA, the
final head SHA, enumerate every intervening path, state why none can affect the
graded property, and list the delta-specific checks. Never label the older SHA
as the final exact-head verification or silently imply that all commands reran.

## 5. Enqueue and prove completion

Only after the latest head is PR-CI green, the independent compiler-reviewer
verdict is clean, and no blocking findings remain, use the verified helper
rather than interpreting `gh` exit codes:

```sh
sh scripts/pr.sh enqueue --number N --interval 10 --timeout 300
sh scripts/pr.sh complete --number N --sha HEAD_SHA --interval 15 --timeout 1800
```

Then read back the merged PR and the matching `merge_group` run. Require the
intended head to be an ancestor of `main` and every required merge-group job to
have actually completed successfully. The pull-request run is not landing
authority.

## 6. Tracker and cleanup

Perform this section only when tracker writes are authorized. Read every
referenced issue before writing. Close only an issue whose reported
behavior and acceptance criteria are satisfied. Otherwise leave a verified
handoff comment containing PR/commit, evidence, remaining scope, deferred work,
and next action; read the comment and issue state back.

Perform destructive cleanup only when authorized. Reap only task-owned daughter
and topic worktrees after their evidence is integrated. Remove disposable local
branches and task scratch files, but leave
unattributed sibling worktrees and processes untouched. Report any retained
path and reason.

Choose slice-ref disposition at sprint admission. Prefer integrating exact
slice commits so task branches become ancestors of topic. Before deleting any
branch, prove its tip reachable from `origin/main`; if not, preserve it or
create an explicitly authorized archival ref. Never force-delete unique commits
merely because equivalent changes landed. Treat an already-absent remote topic
as successful cleanup after readback, regardless of delete-command exit code.

## Compact receipt

Return only: PR URL/head, PR-CI result, review verdict, merge-group result when
authorized, tracker writes with readback, cleanup state, and residual risks.
