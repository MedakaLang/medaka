---
name: sprint-orchestrator
description: Run a Medaka implementation sprint (v8) — a series of implementers executed serially (parallel only with proven disjointness), minimal per-slice verification, one thorough review round at the end, a fix round, then the merge queue. Single-session front seat; no persistent daughters. Invoke at sprint start in a dedicated session.
---

# Sprint orchestrator (v8)

You run the whole sprint from this one session. The goals, in Val's order:
**(1) high throughput of implemented code, (2) low token cost, (3) correctness
before merge to main.** The design that serves them: implementers run one
after another with minimal per-slice verification; correctness is bought once,
at the end, by a thorough review round plus a fix round plus the merge queue —
not by per-slice ceremony. Your job is to keep an implementer working at all
times and to stay out of the way.

There are no persistent daughter seats (v8 retired the brain, planner, rear,
and verifier roles). You author packets, make routine judgment calls yourself,
and take genuinely contested calls to Val. Roles you dispatch:
`sprint-implementer` (per slice, and for fixes), `sprint-reviewer` (end of
sprint), `sprint-retro` (wrap-up, lightweight).

## State on disk — two files, nothing else

In `/var/tmp/medaka-sprints/<stage>/` beside `CONTRACT.md` and `packets/`:

- **STATUS.md** — the slice table: one row per slice, `state`
  (`queued|running|landed|refused|dropped`), landed SHA, report path. Update
  it at every state change; it plus git history IS the resumable sprint
  record.
- **NOTES.md** — append-only, one line per entry: findings ("possible S1:
  `<repro>` prints 7, expected 55 — triage at review"), decisions ("upgraded
  S-foo to opus after refusal"), contract edits, declined scope. Do not
  adjudicate, reproduce, or file anything mid-sprint — the review round
  triages NOTES.md. The one exception: a finding that blocks a LATER slice
  gets fixed now (a small fix packet) or taken to Val.

No DECISIONS/OBLIGATIONS/FINDINGS/QUEUE/DEBT ledgers, no ruling files, no
friction log. If you feel the urge to build one, write one line in NOTES.md
instead.

## Start of sprint

1. Read `CONTRACT.md`. Create the sprint branch from `main`'s tip and push it:
   `git push origin <main-tip-sha>:refs/heads/sprint/<stage>`. Open the draft
   PR early (`scripts/pr.sh` helpers; body = the contract's §1/§3) so CI's
   narrowed `pull_request` run gives ambient signal on every push.
2. Copy the contract's expected-red block (if any) to `EXPECTED-RED.md`.
   Before ever diagnosing a red gate: `gh issue list --label known-red` — it
   is usually not your break.
3. Write STATUS.md from the contract's slice table. Author packet #1 (load
   `sprint-packet`).

## The loop — per slice

1. **Author the packet** from the contract (one page; the `sprint-packet`
   contract). Base = current sprint-branch head. While an implementer runs,
   author the NEXT slice's packet — that is your idle work, not extra
   verification.
2. **Pre-dispatch freshness CHECK — a look, not a merge.** `git fetch origin
   main sprint/<stage>`, then read what landed on `main` since the sprint
   was cut: `git log --oneline <sprint-base>..origin/main` and
   `git diff --stat <sprint-base>..origin/main`. You are looking for one of
   the four merge triggers below — **not** for divergence.** A `main` that
   simply moved is not a trigger: packet §2 checks out the sprint base
   directly and never merges `main`, and [W-MERGE-QUEUE] means branch
   currency is never required. `prelude-shadow-build-agreement` measured the
   elective case — a pre-fix-round resync that cost a rebuild and a re-bless
   and prevented nothing, since the branch was `CONFLICTING` at land anyway.
   The check is still worth its two commands: it is what let
   `comment-register` discover mid-sprint that a sibling sprint had shipped
   the same census tool, and drop a doomed slice before the review round.

   **Merge `origin/main` into the sprint branch NOW only if the check shows
   one of these** (then push, and update the packet's base):
   - **A formatter, linter, or accepted-syntax change landed.** Otherwise
     every later slice is authored in the old format and the rebuilt binary's
     pre-commit hook reflows it at land — one sprint ate "stale-binary fmt
     drift across ~480 files" from the tree-wide reformat.
   - **A slice needs something that just landed** — new code, a renamed gate
     or shard a packet must cite by name.
   - **`main` touched a shared record or table this sprint is also
     extending** (`DriverState`, `DeclEnvs`, a `CrossRun` bundle). Divergence
     here grows the [T-LEGA-REBASE] hazard of a clean-but-non-compiling
     auto-merge; a small early merge keeps the break attributable.
   - **Land time, or `mergeable` says `CONFLICTING`.**

   Whichever the trigger, resync with `sh scripts/sprint-resync.sh
   <sprint-branch>` — never by hand. Three orchestrator git slips came from
   hand-running that sequence: a bare merge pushed without its blessed
   goldens, a `git checkout <stale-sha> --` over an already-verified bless
   (costing a full rebuild+rebless+preflight redo), and a merge into the
   wrong branch.
3. **Dispatch** one `sprint-implementer` with `isolation: "worktree"` and the
   contract's model tier for the slice. The brief is one line: the packet
   path. (The harness mints the worktree from `main`'s tip; the packet's §2
   sync commands handle that — never ask the agent to derive or refuse over
   its cwd.)
4. **On return, read the report file** (never just the return line) and branch
   on the Verdict. `sh scripts/sprint-report-check.sh <report>` grades its
   SHAPE mechanically (first line is the verdict; Evidence and Notes present)
   so intake needs no judgment — it is a convenience, not a gate, and it does
   not read the content. The content you read yourself, including the five
   author self-check answers at the end of Notes (`sprint-packet`).
   - `LANDED @sha` — merge that SHA into the sprint branch
     (`git merge --no-ff <sha>` on your sprint checkout; resolve nothing by
     hand — a conflict means the base was stale, so re-sync and re-dispatch),
     push, update STATUS.md. Do not wait for CI; mid-sprint breakage is
     tolerated and fixed forward.
   - `REFUSED` — read the evidence. Usually the packet was wrong: fix the
     packet yourself (edit contract if the premise was the contract's, one
     line in NOTES.md) and re-dispatch, upgrading sonnet→opus if the refusal
     shows the slice is trickier than classified. If the refusal overturns
     the slice's premise entirely, mark it `dropped` and tell Val in your
     next status message.
   - `BLOCKED` — should now be rare (step 2 catches ordinary stale-main
     BLOCKED before dispatch); treat one as a real dispatch/environment
     defect, not routine staleness. Fix it, re-dispatch. Twice blocked the
     same way = stop and report to Val.
   - `SPIKE-DONE` — fold the findings into the packet and dispatch the real
     slice.
5. Next slice.

**Parallel writers** — only for a pair the contract marks `parallel-ok` with
disjointness evidence, re-verified at dispatch time against the CURRENT head:
`scripts/sprint-disjoint.sh` over the two packets' site lists (redirect to a
file and read `$?` — it does not survive a pipe; its `head=` stamp must equal
your sprint head or the result is stale). Merge their results serially. When
in doubt, serial — selector-identity's throughput was killed by process, not
by serialization.

## End of sprint — review, fix, merge

1. **Resync once, then start the full CI run, then review.** All slices
   landed (or dropped), in this order:

   a. **The sprint's one scheduled resync** — `sh scripts/sprint-resync.sh
      <sprint-branch>`, here rather than at land, so the reviewer sees the
      tree that will actually merge and the golden re-derivation happens once
      with a reviewer downstream of it.

   b. **Trigger the unnarrowed CI run** on the resynced head:
      `gh workflow run ci.yml --ref sprint/<stage>`. PR runs are narrowed;
      this is the only pre-queue execution of the whole suite, and in
      particular the only pre-queue run of `registry_keying_ratchet.sh`
      (inside `compiler-soundness`, invisible to `make preflight`). It costs
      ~40 min of wall-clock **in parallel with** the review round, so it is
      off the critical path, and runner-minutes are free on this repo. Its
      concurrency group is keyed on `github.ref`, so it will not cancel the
      PR's own runs — but a second dispatch on the same branch cancels the
      first, so trigger it once.
      ⚠️ **Read it, and fold its reds into step 2's triage.** An unread red
      run is the failure this replaces, not a lesser version of it — one
      sprint dispatched three slices over a standing red nobody read for ~3h.
      Two limits worth knowing when you read it: CI **warns** on a C3a
      fixpoint failure where the local script hard-fails, and a break it
      finds must be attributed by `git log`/bisect rather than by the slice
      that owned it.

   c. **Dispatch ONE `sprint-reviewer`** (opus) with the resynced head SHA,
      the merge-base with main, the contract path, and NOTES.md. If the
      contract's §7 named domain property classes, name them in the brief. It reviews the WHOLE
   sprint diff at once — adversarial programs plus spec conformance — and
   reports ranked findings. For a large sprint, two reviewers with different
   lenses (breakage vs conformance) are licensed; more is not.
   **Alongside it, dispatch ONE cheap (sonnet) style pass loading the
   `style-review` skill** (`.claude/skills/style-review/SKILL.md`) at the SAME
   pinned SHA — craft, not correctness: duplication, comment register, test
   vehicle, placement, diagnostics, docs, CLI shape, each pointing at its own
   single source. It builds nothing and fixes nothing. It is **once per
   sprint, in this round only** — not per-slice, not per-PR, and never a
   required CI check. Its DECLINED register is what stops it demanding churn;
   if it returns a finding that register forbids, dismiss it with one NOTES.md
   line rather than dispatching a fix.
   Placement findings are measured against what the contract's Surface row
   STATED (`sprint-plan` step 3) and the **`architecture`** skill
   (`.claude/skills/architecture/SKILL.md`), not against a reviewer's
   preference.
2. **Triage the findings yourself**, with NOTES.md's rows folded in. Three
   bins: *fix-now* (wrongness introduced or exposed by this sprint —
   [W-QUIETER] applies: a path that returned nothing and now returns
   something is untested by construction), *file* (real but out of scope —
   draft the issue, file it, verify by readback since `gh` writes lie),
   *dismiss* (with one NOTES.md line saying why). Anything you'd argue with
   Val about goes to Val.
3. **Fix round.** Dispatch fix packets (same implementer contract, small
   packets) serially until the fix-now bin is empty, running the per-slice
   loop's step 2 freshness CHECK before each. A fix that moves a golden gets
   the same by-name bless discipline.

   ⚠️ **A one-line fix a previous fixer already located does NOT get its own
   dispatch.** Fold it into the packet still in flight, or make it yourself —
   a dispatch is a worktree mint, a cold build, a gate run and a report,
   measured at 18–36 min against ~10 min for an orchestrator-direct fix. This
   is the fix round's most-repeated waste: nine sprints spun a full cycle for
   a change the prior packet's own report had already named and located (a
   missing `-c user.name=`, an identical one-line grep pattern in a fourth
   script, a golden re-bless, a one-line mirror), and one such chain burned
   1h10 for a ~10-minute packet. Dispatch a fix when it needs a build and a
   judgment call; do it yourself when it needs neither.
4. **Land.** `medaka fmt --write` + `medaka lint` clean on touched files;
   `make preflight` if the diff touches blast-radius paths, else let CI
   answer. Mark the PR ready, `gh pr merge --auto --merge`. The merge queue
   runs the full gate suite — it is the correctness authority, not your
   local runs. Verify by state, never exit code: poll
   `isInMergeQueue`/`state` until `MERGED` — auto-merge arming can lapse
   silently, so recheck until terminal.
5. **Wrap.** Close/update the tracking issue (what landed, what was filed,
   SHAs). Dispatch `sprint-retro` (lightweight — half a page, deletion bias).
   Update STATUS.md to terminal states. Reap worktrees and background
   processes.

## Standing rules — each one paid for in an incident

- **Merge by the reported SHA**, never by branch name; verify a "landed on
  main" claim with `git merge-base --is-ancestor <sha> origin/main`.
- **Every `gh` write is verified by readback**, never exit code — bodies,
  labels, merges, issue filings all have silently no-opped.
- **Pin your refs**: `BASE=$(git rev-parse …)` at task start; the shared
  `.git` means `origin/main` and FETCH_HEAD move under you mid-task.
- **Never edit compiler source while a build is in flight**; never
  background a build you then abandon; `MEDAKA_STRICT=1` on any probe whose
  answer matters.
- **After any merge/rebase, rebuild oracles before capturing or blessing any
  golden** — capture has no staleness guard and a stale oracle blesses wrong
  goldens permanently.
- **Issue filing and PR writes are yours alone** — no dispatched agent
  touches `gh` write operations; they draft, you file.
- **Status to Val**: short, outcome-first, at phase boundaries or when
  blocked — the slice table state, not narration. Number any decision you
  need from her and record her answer in NOTES.md.
