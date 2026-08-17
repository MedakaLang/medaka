# Sprint token-cost hypotheses — measured ledger

**Status:** Live ledger. Owner: Val. Instrument: `scripts/sprint-cost-report.py`
(post-hoc aggregation of `~/.claude/projects/*` transcripts — per model, per
agent type, per session, per individual dispatch; dedupes resumed sessions by
`message.id`). Run at sprint wrap-up (`sprint-orchestrator` end-of-sprint step)
into the record dir as `COSTS.md`; `sprint-retro` grades this ledger against it.
Verdicts here are updated ONLY from measured reports, never from derivation.

## Baseline measurement — 2026-08-16/17 window

Covers the v2 wrap-up (xmod-identity) + two v3 sprints (ctor-identity,
pds-phase0-substrate) + design sessions. **Total ≈ $1,851 est** (13,099 API
requests; list prices, Sonnet intro pricing not applied).

**Cost decomposition: cache READS $1,126 (61%) · cache WRITES $521 (28%) ·
output $204 (11%).** The dominant cost of the whole architecture is
`turn count × context length` re-read at 0.1× every request. Any lever that
shortens long-lived contexts or cuts turn count acts on the 61% pool; model-tier
changes act mostly on the same pool via the per-token price.

Per agent type (est, window total): main sessions $524 · sprint-implementer
$461 · sprint-brain $281 · sprint-planner $220 · sprint-rear $151 ·
slice-breaker $122 · spec-conformance $38 · bug-reproducer $28 · verifier $4.69
· scout $0.41. Implementers (the product) are ~25%; orchestration machinery
(seats + brain + planner) ~63%.

## Hypotheses

| ID | Claim | Verdict @ 2026-08-17 | Evidence / decision rule |
|---|---|---|---|
| H1 | Per-slice Opus `slice-breaker` on parity slices is redundant with the heavy round; tier it by packet §1 | **WEAKENED as a top lever** — breakers+conformance = $159 ≈ 9% of window. Keep only if it costs nothing in safety; do NOT trade S0 coverage for 9%. | Re-grade after any change: breaker $/slice and catch attribution (a mechanism that caught an S0 is untouchable) |
| H2 | A persistent planner amortizes per-packet spawn cost | **SUPERSEDED by H9** — the fold-discovery-into-implementer redesign removes the recon the persistence would have amortized. | — |
| H3 | Persistent daughters (brain, rear) pay repeated full-context cache-writes; reset-respawn at phase boundaries / context ceiling fixes it | **CONFIRMED → ADOPTED (trial) 2026-08-17.** Brain: 80% hit rate, $193 of its $281 is 5m-TTL cache-writes; rear: $72 of $151. Mechanism: subagent cache TTL is **hardcoded 5m** (verified — no config), while consult/poke gaps exceed it, so ~every wake rewrites the whole grown context at 1.25×. Adopted as the "Daughter rotation" protocol in `sprint-orchestrator` (serial successor at phase boundaries; ledgers are the state). | Brain+rear cache-write $ should drop ≥60%; watch for successor re-derivation cost and any forked-judgment incident (would revert) |
| H4 | Rear seat can run on Haiku 4.5 (it is judgment-free by design) | **PLAUSIBLE, modest** — $150 → ~$50/window. Compose with H3. | Trial with v2's log-and-audit protocol; revert on any misroute |
| H5 | Adaptive heartbeat (stretch ticks when only long-running work is live) cuts front-seat cost | **CONFIRMED direction** — main sessions $524, 99% cache-hit, i.e. almost pure re-read cost linear in tick/turn count. Main sessions get 1h-TTL cache so ticks are read-priced; fewer ticks = linear savings. | Compare front-seat reqs/hour across sprints |
| H6 | REPAIR fixes should go to the still-warm originating implementer (SendMessage) instead of a fresh fixer | **UNMEASURED** — fixer dispatches visible ($17–23 each) but warm-continuation arm never run. | Needs one sprint running both arms |
| H7 | Per-spawn preamble (AGENTS.md ≈ 26k tok) is a major cost | **REJECTED on the write channel** (~$5/sprint) — but **REVISED**: as a cache-READ tax it is re-read every request: ≈ 35k × 13k reqs × 0.1× ≈ $150–200/window (~10%). Trimming always-in-context text pays proportionally to turn count, not spawn count. | Token-count AGENTS.md before/after any diet; multiply by measured reqs |
| H8 | Poke cadence interacts with the 5m subagent cache TTL | **CONFIRMED mechanism** — a wake within 5 min costs 0.1× (read); after expiry it costs 1.25× (write) of the full context. The ~10-min heartbeat guarantees the expensive path for both daughters. Sub-5-min pokes are ~5× cheaper *per wake* than 10-min pokes for a large context — but the honest fix is small contexts (H3), not faster polling. | If cadence is changed: daughter write-vs-read $ ratio |

| H9 | Fold discovery into the implementer: packets become ~250-line CONTRACTS (boundary, site list, one-question check, classification, acceptance); §4 curates existing proofs instead of fresh planner recon; per-site transformation detail is implementer discovery; REPAIR fixes carry NO packet (fixer executes from the brain's ruling + repro bundle); planner drops to Sonnet 5 | **ADOPTED (trial) 2026-08-17** (Val, this conversation). Rationale: packets measured 53–89KB with the largest being a *fix* packet; packet prose re-read at 0.1× by every consumer turn ($10–20/slice downstream); refusals overturned packet site-detail 5 of 6 times; design-ahead had ~75% rework. The refusal license SURVIVES (boundary + acceptance are refusable claims); classification and disjointness stay pre-dispatch. Predicted: planner pool $220 → ~$40–60 + downstream read savings. | Grade on: (1) did any scoping error reach a merge that a refusal previously caught — one instance → escalate to Val; (2) planner $/packet and packet bytes; (3) implementer $/slice (discovery cost shifting there is expected and acceptable up to ~half the planner saving); (4) refusal rate/quality vs baseline |
| H10 | Front-seat auto-compact at ~300k (`CLAUDE_CODE_AUTO_COMPACT_WINDOW=300k` at session launch) cuts the largest read pool | **ADOPTED (trial) 2026-08-17.** Front-seat contexts measured ~487k avg/request; main sessions $524/window at 99% hit = almost pure re-read cost. Threshold is global-per-launch (no per-agent knob; model cannot self-trigger `/compact` — verified). Safe: heartbeat derives state from ledgers by design. | Front-seat avg context/request (reads ÷ reqs) should drop toward ~300k; watch for post-compaction state-loss incidents (ledger discipline should make these zero) |
| H11 | Per-agent `effort` frontmatter for mechanical seats (`maxTurns` as breaker attack budget deferred — binding unverified) | **ADOPTED (trial) 2026-08-17** after the binding probe PASSED: an `effort: low` agent spawned via the Agent tool from a `medium` parent recorded `low` on every request (headless probe, CLI v2.1.233, transcript-verified). The "effort is ignored" known issue is real but PATH-SPECIFIC — `claude -p --agent` persona path (#82259, #81677) and skill frontmatter (#69267), all open; the Agent-tool dispatch path (the only one the roster uses) binds. Assignments: verifier/scout/rear `low`; bug-reproducer/spec-conformance `medium`; writers/brain/breaker inherit. Second probe: on HAIKU agents the harness silently drops effort (records `None`, no error — the API rejects effort on Haiku 4.5), so the verifier/scout annotations are declarative no-ops today; the LIVE assignments are rear/reproducer/conformance. Re-probe after CLI updates — path-specific bugs move. | Grade: reqs-per-dispatch and $ for the low/medium seats vs baseline; revert any seat whose bounce rate rises |

| H12 | Sub-TTL keepalive pokes (~4.5 min) keep daughter caches warm: a wake within the 5m TTL reads at 0.1× vs the 1.25× rewrite after expiry — ~5× cheaper resume tax at rear-baseline context (~$0.09 vs ~$1.13/wake) even at doubled wake count | **PROPOSED (Val floated 2026-08-17), sequenced AFTER H3's first grading** — rotation shrinks the contexts and may leave too little residual tax to justify the added machinery. Requires a strict no-op `poke keepalive` input (reply `ack:` only — no CI sweep, or extra sweeps eat the saving) and an alternating ~270s front-seat tick. Brain keepalives only pay when consults cluster (~$1.70/hr wasted per quiet hour otherwise). | Adopt only if post-H3 COSTS.md still shows daughter cache-write $ ≥ ~2× their cache-read $ |

## Standing rules for editing this file

- A verdict changes only with a `COSTS.md` (or equivalent measured report)
  citation. Derivations go in the Evidence column as *predictions*, labeled.
- Cuts must not trade against the sprint principles (S0 coverage, refusal
  license, report contracts). H1's rule is the template: safety mechanisms are
  graded by catch attribution, not by cost alone.
- New hypotheses get the next H-number; rejected ones stay (a rejected
  hypothesis is a result, not clutter).
