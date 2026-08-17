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
| H2 | A persistent planner amortizes per-packet spawn cost | **REVISED** — spawn preamble is negligible on the write channel (<$1/spawn); planner's $220 is recon reads ($127) + output. Persistence pays only if it avoids re-reading the same material across packets. | Measure planner cache-read per packet with vs without continuation |
| H3 | Persistent daughters (brain, rear) pay repeated full-context cache-writes; reset-respawn at phase boundaries / context ceiling fixes it | **CONFIRMED — biggest verified inefficiency (~$270/window).** Brain: 80% hit rate, $193 of its $281 is 5m-TTL cache-writes; rear: $72 of $151. Mechanism: subagent requests cache at **5m TTL** while consult/poke gaps exceed 5 min, so ~every wake rewrites the whole grown context at 1.25×. | After adopting reset-respawn (or consult batching): brain+rear cache-write $ should drop ≥60% |
| H4 | Rear seat can run on Haiku 4.5 (it is judgment-free by design) | **PLAUSIBLE, modest** — $150 → ~$50/window. Compose with H3. | Trial with v2's log-and-audit protocol; revert on any misroute |
| H5 | Adaptive heartbeat (stretch ticks when only long-running work is live) cuts front-seat cost | **CONFIRMED direction** — main sessions $524, 99% cache-hit, i.e. almost pure re-read cost linear in tick/turn count. Main sessions get 1h-TTL cache so ticks are read-priced; fewer ticks = linear savings. | Compare front-seat reqs/hour across sprints |
| H6 | REPAIR fixes should go to the still-warm originating implementer (SendMessage) instead of a fresh fixer | **UNMEASURED** — fixer dispatches visible ($17–23 each) but warm-continuation arm never run. | Needs one sprint running both arms |
| H7 | Per-spawn preamble (AGENTS.md ≈ 26k tok) is a major cost | **REJECTED on the write channel** (~$5/sprint) — but **REVISED**: as a cache-READ tax it is re-read every request: ≈ 35k × 13k reqs × 0.1× ≈ $150–200/window (~10%). Trimming always-in-context text pays proportionally to turn count, not spawn count. | Token-count AGENTS.md before/after any diet; multiply by measured reqs |
| H8 | Poke cadence interacts with the 5m subagent cache TTL | **CONFIRMED mechanism** — a wake within 5 min costs 0.1× (read); after expiry it costs 1.25× (write) of the full context. The ~10-min heartbeat guarantees the expensive path for both daughters. Sub-5-min pokes are ~5× cheaper *per wake* than 10-min pokes for a large context — but the honest fix is small contexts (H3), not faster polling. | If cadence is changed: daughter write-vs-read $ ratio |

## Standing rules for editing this file

- A verdict changes only with a `COSTS.md` (or equivalent measured report)
  citation. Derivations go in the Evidence column as *predictions*, labeled.
- Cuts must not trade against the sprint principles (S0 coverage, refusal
  license, report contracts). H1's rule is the template: safety mechanisms are
  graded by catch attribution, not by cost alone.
- New hypotheses get the next H-number; rejected ones stay (a rejected
  hypothesis is a result, not clutter).
