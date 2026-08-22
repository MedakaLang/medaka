---
name: sprint-plan
description: Cut a sprint — choose a coherent, well-bounded set of slices (3–5 is the sweet spot; v7) and write the sprint contract, at boundary depth only. Run ONCE per sprint, before the orchestrator session starts; judgment-heavy, so run on Opus 5 minimum, Fable 5 when the sprint spans a spec or moves formal semantics. The contract it produces is what sprint-orchestrator executes and sprint-planner deepens just-in-time.
---

# Sprint planning — cutting the slice set

This skill produces ONE artifact: the sprint contract at
`/var/tmp/medaka-sprints/<stage>/CONTRACT.md`. Its whole craft is two calibrations:
**picking a set of slices that belong together**, and **specifying them shallowly
enough that reality can't invalidate the work**. Everything deeper than the
boundary is the run-time `sprint-planner`'s job, one packet ahead, informed by
what landed slices taught — design-ahead beyond that measured a ~75% rework rate,
and one sprint's design doc was wrong about 4 of its 6 bites.

## Step 1 — derive the candidate pool; trust nothing inherited

- **The backlog is GitHub Issues, not any doc.** Start from
  `gh issue list --label "S0: silent wrongness"` and the sprint's workstream
  label; severity orders candidates (S0 > S1 > S2 > S3; soundness outranks
  release).
- **Check each candidate's state before it enters the pool.** When the backlog
  was last re-derived against the binary, SIX entries were already fixed —
  including two billed as top-value items. A `needs-repro` item may not enter as
  an implementation slice: it enters as a cheap repro slice, or not at all.
- **Grep the OTHER arcs for your issue numbers, not just your docs for theirs.**
  A one-directional citation once scoped a sprint slice that was verbatim
  another arc's claimed work (B-2.4 = X-E.C). One `grep -rn '#<NNN>' docs/
  .claude/` per candidate is the whole cost.
- **Read the tree, not the roadmap** — arc trackers lag the merged tree; ledgers
  are ungated prose. Any "still open / still owed" claim that will justify a
  slice gets re-derived against the pinned base, with the command recorded.

## Step 2 — choose the SET: coherence is the criterion

A sprint is a unit, not a bucket. A slice belongs in this sprint iff:

- **It shares context with the others** — the same subsystem, spec, ruling set,
  or file neighborhood, so the reading cost (specs, rulings, prior reports) is
  amortized across slices instead of paid per slice. A great candidate with
  disjoint context is a great candidate for a DIFFERENT sprint, not filler for
  this one.
- **It advances the sprint's one question.** Write that question down first
  ("retire the method-keyed selector", "make dispatch identity module-
  qualified"). A slice you can't connect to the question in one sentence is
  scope creep at the planning stage — the cheapest place to catch it.
- **Its dependencies are inside the sprint or already landed.** A slice whose
  premise waits on an unresolved ruling either becomes slice 1 (the ruling IS
  the slice) or leaves the sprint. Two slices needing the same unresolved
  decision is the split-decision S0 shape at sprint scale — they merge, or the
  decision lands first.
- **One decision, one slice.** Sites that collectively answer one question move
  in one slice (or an explicit expand–migrate–contract family) — never spread
  across slices "to balance sizes".

**One slice in the set is the INDEPENDENT REFILL** (`refill: yes` in its §3
row). It depends on nothing in the sprint's main DAG — not a spike's outcome,
not another leaf's landing, not a shared golden — and the run-time planner cuts
its packet immediately after packet #1, parking it in QUEUE.md as the
designated lane refill. A *discovered* decomposition is usually a chain, and a
chain cannot satisfy the one-packet-ahead runway invariant: the
`sprint/ctor-identity` writer lane idled twice with the reason honestly
recorded ("no independent queued packet exists to refill the lane with"). If
the candidate set genuinely admits no independent slice, say so in §3 in one
line with why — the orchestrator then knows its idle branch is real rather than
a planning miss.

**Stated trade (principle 5 / the one-ahead rule):** this is the ONE licensed
exception to "plan exactly one slice ahead", and it is licensed on a specific
property — a slice with no DAG dependency is by construction not invalidated by
what the DAG discovers, which is what makes design-ahead rot elsewhere (~75%
rework). It buys a lane refill that a chain cannot supply. If the refill packet
DOES start rotting, that is evidence it was never independent, and it goes back
through the planner like any other falsified premise.

**Size the set: 3–5 slices (v7 — revised down from ~5+ on measurement).**
Fewer than 3 and the sprint machinery (contract, ledgers, heavy round) costs
more than it amortizes — land 2 slices as ordinary PRs instead. Above ~5 the
coordination cost grows FASTER than linearly, because every seat's per-turn
cost is proportional to its accumulated context and every packet inherits the
accumulated standing-carry set: `sprint/method-identity` (6-slice cut counting
the family) measured packet §0 carries growing to nine by the late leaves and
failing to propagate three times, packets growing 374→727 lines, an
obligations tracker at 339 rows, and a front-seat context averaging ~514k
tokens/request as the largest cost line on the board — while the machinery:
product ratio hit 83:17 against a ~63:25 baseline (COSTS.md; hypothesis H15).
The other ceiling still binds: what the heavy round can genuinely attack in
one pass — if the projected total
diff is too large to adversarially review, the sprint is two sprints, and this
binds HARDER under v3's deferred-verification model (the heavy round
is the first adversarial pass over deliberately under-verified work, and the
terminal merge-queue run is the first full-gate run, so a sprint too big for
its heavy round has no backstop at all). Each slice
should be roughly one writer-session of work; a slice that is obviously several
becomes a family candidate (flag it — the spike decides), and a slice that is an
afternoon's triviality gets merged into a neighbor or dropped to the ordinary
PR flow.

## Step 3 — specify each slice at BOUNDARY depth, deliberately no deeper

Per slice, the contract records exactly six things:

1. **Mission** — what is true after it lands that wasn't before, one paragraph,
   citing the issues/rulings it serves.
2. **First-approximation surface** — the files/subsystems it probably touches,
   honestly labeled as approximation, OR an explicit `SPIKE-FIRST` flag when the
   sites can't be named confidently. Do NOT enumerate exact sites or transforms
   here — that is the packet's job, done just-in-time with §4-grade proof.
3. **Acceptance shape** — how we'll know it worked, at the level of "which gate
   family / what new fixture class / what differential", not exact commands.
4. **Classification guess** — parity vs behavior-changing (drives the model
   tier; the packet may overturn it).
5. **Depends-on** — other slices by ID, forming the landing order. **A
   dependency EDGE between two slices that touch the same question or
   subsystem is a MEASURED claim, not an assertion (v7):** the row states the
   direction's evidence (a probe, a call-graph derivation, a prior sprint's
   measurement — with the command). If the direction is asserted rather than
   derived, the pair's first slice is a JOINT SPIKE over both — one timeboxed
   dispatch that grades the coupled surfaces together before either is cut.
   (Measured, `sprint/method-identity`: CONTRACT §3's one-way "impl-query
   depends on receiver-position" column was falsified mid-sprint — the legs
   are MUTUALLY dependent, the composed pair of wrong answers landed on the
   ruled-correct value by accident, and correcting either alone moved 3 cells
   from correct to wrong. RUN-METHID-115's own finding is exactly what a
   Leg-1×Leg-3 joint spike would have produced before either was cut, and its
   absence made the spine slice uncuttable mid-sprint — the single largest
   contributor to a ~17-hour adjudication tail. The orchestrator's SCOPE-RESET
   rule handles this when it happens anyway; this rule is the cheaper end.)
6. **`refill: yes|no`** — exactly one row in the table carries `yes` (the
   independent refill above), or §3 carries the one-line why-not.

**The orderings will rot faster than the facts** — plans' orderings are the
first casualty of contact. Mark the landing order as provisional; the
orchestrator re-derives it from the DAG state at each dispatch, and a refusal
re-cut reorders without ceremony.

## Step 4 — write the contract

The contract is a WORKING document, not a repo artifact — it lives in the
ephemeral sprint dir and is never committed (the repo is the "what" of the
language; the roadmap's "how" lives in GitHub issues). Its durable shadow is
the **sprint tracking issue**: after writing the contract, open one GitHub
issue titled with the sprint's question, body = §1–§3, §7 and §8 (the
question, scope, slice table, landing model, exit criteria), labeled by
workstream. This issue is where
the close-out and retro land at wrap-up, and it is what someone browsing the
tracker sees of the sprint. Verify the creation by readback; handles per the
identifier convention.

`/var/tmp/medaka-sprints/<stage>/CONTRACT.md` (record-dir naming rule: never a bare
`sprint/`), with these sections:

- **§1 The question** — the one-sentence purpose of the sprint.
- **§2 In / Out** — scope both ways, each Out with its reason stated so it can
  be overturned deliberately rather than rediscovered.
- **§3 The slice table** — the six fields above, one row per slice. **Slice
  IDs are descriptive slugs** (`S-selector-rekey`, `S-freeze-admissibility`),
  never opaque letters (`E4`, `F7`) — the packet contract's §0 identifier
  convention starts here, because every later document inherits these names.
- **§4 Already settled — do NOT re-derive** — sprint-wide facts with their
  proving commands (same discipline as a packet's §4; this seeds every packet).
- **§5 Issue-closure policy** — which issues this sprint may close, and that
  every close checks the PIN, not the narrative.
- **§6 Expected-red block** — the known-red gate set for the duration (the
  orchestrator copies it to the sprint dir's `EXPECTED-RED.md` and the tracking
  issue at sprint start; reds expected beyond the sprint get a `known-red`
  labeled issue each). Every row carries `masks:` (the checks that do NOT run
  behind it — DERIVED from the job's step list, command recorded; `NONE` is a
  common and valid value) and `unmask-by:` (the slice or fix that clears it,
  scheduled in the FIRST HALF of the sprint — `wrap-up` is not a valid value).
  A failing step skips its successors, and one licensed red kept a whole
  sprint's soundness signal dark.
- **§7 Landing model** — v3 default: ONE sprint branch (`sprint/<stage>`) and
  ONE running draft PR for the whole sprint; slices merge into the branch, the
  PR enqueues once, after the heavy round. Mid-sprint CI is the narrowed
  `pull_request` run only; mid-sprint breakage is tolerated and fixed forward.
  State here any deviation (e.g. a slice that MUST land to main mid-sprint) and
  why.
- **§8 Exit criteria** — including the heavy round (non-optional; it carries
  every S0-class finding's adversarial review and any deferred golden
  captures — both block the terminal enqueue) and desk-closes.
- **§8b Domain review** — when this sprint is the language's FIRST use in a new
  domain, name the property classes a `domain-adversary` pass will cover
  (constant-time/side-channel, hostile input at a trust boundary, protocol or
  crypto misuse, irreversible external effects, concurrency) and budget them;
  or state in ONE line why this domain has no failure class the slice
  acceptance cells can express. Silence does not qualify. (Scope, stated: this
  is generalized from one sprint in one new domain, where three out-of-contract
  reviews produced 33 items → 5 findings, including a LANGUAGE-level gap — no
  CSPRNG anywhere in the tree — that the contract could never have asked
  about.)

## Step 5 — adversarial read before handoff

Before the contract is handed to an orchestrator session, one pass asking:
which slice would an implementer refuse, and why? Which §4 fact is relayed
rather than derived? Which two slices secretly share a decision? If the sprint
is spec-scale, THIS is the Fable 5 moment — one review of the contract, not a
standing seat. Fixes go in the contract now; they are 10× cheaper here than as
mid-run refusals.

The contract is provisional by design: first contact revises it through the
normal machinery (refusal → brain → planner re-cut, recorded in DECISIONS.md).
A contract that survives its sprint unchanged is suspicious, not exemplary —
it usually means deviations went unrecorded.
