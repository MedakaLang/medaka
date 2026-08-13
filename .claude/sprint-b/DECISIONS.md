# Stage B sprint — DECISIONS.md

**Append-only.** Architecture companions and the run orchestrator write; **everyone reads this
before asking**. Every entry carries **its derivation**, not just its conclusion — an entry
stating a fact without a derivation gets bounced by the referee.

Contract: `.claude/STAGE-B-SPRINT.md`. Debt ledger: `.claude/sprint-b/DEBT.md`.
Phase 0 raw deliverables: `.claude/sprint-b/phase0/*.md` (one file per agent, merged here).

**Branch:** `arch/stage-b-sprint` · **Trunk worktree:**
`/root/medaka/.claude/worktrees/giggly-tinkering-rainbow` · **BASE:** `2b9dc798`

---

## RUN-B-000 — run opened, tree state derived 2026-08-13

**Derivation, command by command:**

- `git rev-parse HEAD` → `2b9dc798fd7459e5cd0f3298bcb645a658a177fe`. **Pinned as `BASE`.**
  Every worktree shares one `.git`, so `origin/main` moves with no signal — all diffs and
  checkouts in this run reference `$BASE`, never a moving ref.
- `git status --porcelain` → empty. Clean start.
- Branch `arch/stage-b-sprint` created off `BASE`.
- **Trunk binary cold-bootstrapped** (`make -C <trunk> medaka`, exit 0). This worktree had **no**
  `./medaka` and no `./medaka_emitter` at open — per `AGENTS.md` a worktree-isolated tree
  cold-bootstraps from `compiler/seed/emitter.ll.gz` rather than borrowing a sibling's emitter.
  Artifacts: `medaka` (4141112 B), `medaka_emitter` (2063608 B).
- **Freshness verified, not assumed:** `MEDAKA_STRICT=1 ./medaka --version` → `medaka
  0.1.0-preview`, **exit 0**. Strict mode promotes a stale-source fingerprint to a hard `exit 1`,
  so exit 0 is affirmative evidence the binary matches `compiler/*.mdk` on disk.
- **Baseline self-typecheck:** `make -C <trunk> check-self` →
  `PASS: medaka_cli.mdk closure is type-clean`. This is the in-band signal §5 requires after
  ~every 3 bites; it is **green at BASE**, so any later failure is attributable to this run.

**Stage A's known-red set is EMPTY.** `.claude/HANDOFF.md` records the Stage A goldens re-cut once
from the final binary in terminal commit `46c551c0`: `diff_compiler_selfproc` 16 ok / 0 failing,
`diff_compiler_snapshot_frontend` 201/201, `must_fail` 98 REPRO / 1 DRAINED. So this run starts
from a genuinely clean signal and **does not inherit a red to hide behind.**

⚠️ **One pre-existing red is NOT ours and must not be attributed to this run:**
`check_cli_modules`' `1112-A34/later-invisible` leg, which fails by **ACCEPTING**. No diff that
only adds a reject can have caused it.

---

## RUN-B-001 — sole occupancy confirmed (§7)

§7 widens sole occupancy beyond Stage A's single file: B-2 also owns
`compiler/backend/llvm_emit.mdk`, `compiler/backend/wasm_emit.mdk`,
`compiler/ir/core_ir_lower.mdk` and `compiler/eval/eval.mdk` alongside
`compiler/types/typecheck.mdk`.

**Derivation:** `git worktree list` shows one other repo worktree,
`.claude/worktrees/agent-a03a28eda256bd47d` @ `7aae8b83` (behind BASE). `ListAgents` reports no
live agent in it — only two Remote Control peer sessions, one offline and one idle, neither
holding this tree. mtimes on that worktree's copies of the sole-occupancy set:
`typecheck.mdk` 2026-08-12T22:55, `llvm_emit.mdk` and `eval.mdk` 2026-08-12T22:41, against a
current clock of 2026-08-13T00:44 — **idle ~2h, no writes in flight.**

⚠️ **Honest limitation, recorded rather than glossed:** this session is worktree-isolated, so
`git -C <sibling> status` is **refused** by the isolation classifier. Occupancy is therefore
established from `ListAgents` + mtimes, **not** from a porcelain status. That is weaker evidence.
It is sufficient because the sibling is behind BASE and idle, but if a sibling agent wakes and
edits the occupancy set, this ruling lapses and must be re-derived.

---

## RUN-B-002 — Stage A's split verdict, and what this run does differently

Read from `.claude/ORCHESTRATING.md` §"The deferred-verification sprint (Stage A, 2026-08-12/13)"
(line 2247) — quoted, not paraphrased from the sprint doc's summary of it:

- ✅ **KEEP** deferred verification *with* a mandatory per-bite `could move:` field. Cost
  "essentially nothing"; it "found 2 S0 regressions, an architectural contradiction, and a
  pre-existing S0."
- ❌ **DROP** concurrent implementers. "**Four contaminated measurements in one run, all from
  agents holding uncommitted edits; zero from late gates.**" Worst case: a must-fail run
  reporting **5 phantom DRAINS** where a quiescent tree had zero — and since the next action on a
  drain is to *close the issue*, trusting it would have put five wrongly-closed bugs in the
  tracker. Plus ~4 bites of rework from a region collision and one function built twice.
- Five concurrent adversarial **reviewers** interfered with **zero**, because they do not edit.

**Ruling for this run: PARALLELIZE READERS, SERIALIZE WRITERS.** Throughput comes from read-only
fan-out and batched builds, not concurrent writers. **One implementer live at a time.**

**Applied at Phase 0:** six agents dispatched concurrently — five strictly read-only (P0-A/B/C/D,
P0-FABLE), each writing exactly one disjoint file under `phase0/`; one narrow writer (P0-P)
confined to `test/must_fail_fixtures/`, which no other agent touches. Zero compiler-source
writers live. Every brief states the true concurrency, because Stage A's orchestrator opened a
brief with *"you are the ONLY agent live"* and dispatched two more minutes later; that agent
checked instead of trusting it, and only for that reason did its measurements survive.

**Every brief carries the refusal clause.** The highest-value agent behaviour in Stage A was
refusal — a bite refused for an unreachable site, a brief instruction refused because its "loud"
form was a false reject, two agents stopping rather than adapting, a reviewer retracting its own
finding, a read-only agent auditing the orchestrator's ledger and being right twice. None was
asked for. So it is asked for now, explicitly, in every brief.

---

## RUN-B-003 — the drain list is OPEN by policy; baseline states derived

`gh issue view` on each, 2026-08-13. **All confirmed OPEN**, with labels:

| Issue | Sev | Labels | In this run |
|---|---|---|---|
| #1113 | — | ws:soundness, ws:typecheck, ws:emitter | **B-2, the spine** |
| #991 | S3 | ws:typecheck | B-3 |
| #994 | S3 | ws:typecheck | B-3 |
| #1114 | — | ws:typecheck | Phase 0 desk item: verify-and-close |
| #1317 | S0 | ws:soundness, arc:plan-gap | retires at B-2.1 **by deletion** |
| #1564 | S1 | verified, ws:typecheck | drain |
| #1599 | S0 | verified, ws:typecheck | drain |
| #1560 | S0 | verified, ws:soundness | drain |
| #1072 | S0 | verified, ws:emitter | drain |
| #1071 | S0 | verified, ws:emitter | drain — **was unpinned** |
| #1062 | S0 | verified, ws:soundness | drain (eval-only) |
| #1182 | S0 | verified, ws:soundness | drain |
| #1068 | S1 | verified, ws:wasm, ws:emitter | drain — **was unpinned**, lands with B-2.4 |
| #993 | S3 | ws:typecheck | **OUT** — B-1 |
| #1046 | S0 | verified, ws:emitter | **OUT** — F-1 (local lambda) |
| #1075 | S1 | verified | **OUT** — F-1 residual, **was unpinned** |
| #1265 | S0 | verified, ws:soundness, ws:typecheck | Phase 0 adjudicates |
| #1597 | S1 | verified, ws:typecheck | Phase 0 adjudicates; presumption OUT |

**Policy (contract §1): the run implements S0/S1-draining work. It does NOT close it.** Pins
flipping red as fixes land is a **deliverable** and is the repair round's attack list. Closure
requires the adversarial review gate every soundness fix here gets, which happens after.

⚠️ **A drain reading is only valid on a quiescent tree, and every drain claim is run TWICE.**
Two runs disagreeing means the tree is moving. See the phantom-DRAIN history in RUN-B-002.

---

## RUN-B-004 — the three unpinned drains: falsifiability hole, being closed now

**#1071, #1068 and #1075 have no must-fail pin.** A drain claim against an unpinned issue is
**unfalsifiable**, and three of this run's own drain targets were in that state. Dispatched to
P0-P with the bar: **witnessed RED first-hand on the current binary, before any fix exists**, and
the row confirmed to read **REPRO** — because a **malformed pin reports DRAINED or phantom-skip**,
which is indistinguishable from a fixed bug and reads as a *benign* verdict. That has happened
three times in this repo.

#1075 is pinned but labelled **out-of-scope for Stage B** (F-1, local lambda), so a later agent
does not read its still-RED pin as a Stage B failure.

*(Rulings from P0-A/B/C/D/P and the Fable consult are appended below as they land.)*
