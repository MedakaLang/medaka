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
2. **Pre-dispatch freshness check — yours, not the implementer's, EVERY
   dispatch, fix-round packets included.** `git fetch origin main
   sprint/<stage>`. If `origin/main` has moved past your last resync point,
   resync NOW, before dispatching: real merge-base, diff merge-base..
   origin/main against this stage's touched files to confirm no overlap (it
   almost never overlaps — main moves fast on unrelated files far more often
   than it touches your slice's own surface), merge `origin/main` into the
   sprint branch on a disposable branch, push, update the packet's base to
   the new head. This is a git command, not agent judgment — a dispatched
   implementer hitting `BLOCKED` on stale-main is a wasted round-trip
   (worktree mint + a refusal write-up for zero code), confirmed costly
   across a full sprint (5 of 9 dispatches in one sprint were exactly this,
   every resulting merge conflict-free and file-disjoint). Do this check
   every time you're about to dispatch, not only after a BLOCKED report.
   ⚠️ **This applies identically to a fix-round dispatch** — `predicate-
   slots` re-broke on exactly this gap: the resync habit had only ever been
   exercised on slice dispatch, so a fix packet's first dispatch blocked on
   a base that had gone stale while the review round ran. Run the same
   fetch-and-resync before EVERY `sprint-implementer` dispatch in the fix
   round too, not just in the per-slice loop.
3. **Dispatch** one `sprint-implementer` with `isolation: "worktree"` and the
   contract's model tier for the slice. The brief is one line: the packet
   path. (The harness mints the worktree from `main`'s tip; the packet's §2
   sync commands handle that — never ask the agent to derive or refuse over
   its cwd.)
4. **On return, read the report file** (never just the return line) and branch
   on the Verdict:
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

1. **Review round.** All slices landed (or dropped): dispatch ONE
   `sprint-reviewer` (opus) with the sprint branch head SHA, the merge-base
   with main, the contract path, and NOTES.md. If the contract's §7 named
   domain property classes, name them in the brief. It reviews the WHOLE
   sprint diff at once — adversarial programs plus spec conformance — and
   reports ranked findings. For a large sprint, two reviewers with different
   lenses (breakage vs conformance) are licensed; more is not.
2. **Triage the findings yourself**, with NOTES.md's rows folded in. Three
   bins: *fix-now* (wrongness introduced or exposed by this sprint —
   [W-QUIETER] applies: a path that returned nothing and now returns
   something is untested by construction), *file* (real but out of scope —
   draft the issue, file it, verify by readback since `gh` writes lie),
   *dismiss* (with one NOTES.md line saying why). Anything you'd argue with
   Val about goes to Val.
3. **Fix round.** Dispatch fix packets (same implementer contract, small
   packets) serially until the fix-now bin is empty. Run the SAME
   pre-dispatch freshness check as the per-slice loop's step 2 before each
   one — the review round can take long enough for `main` to move under you,
   and a fix-round dispatch is not exempt from the resync just because it's
   small. A fix that moves a golden gets the same by-name bless discipline.
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
