---
name: sprint-plan
description: Cut a sprint — choose a coherent, well-bounded set of slices (~5+ is the sweet spot) and write the sprint contract, at boundary depth only. Run ONCE per sprint, before the orchestrator session starts; judgment-heavy, so run on Opus 5 minimum, Fable 5 when the sprint spans a spec or moves formal semantics. The contract it produces is what sprint-orchestrator executes and sprint-planner deepens just-in-time.
---

# Sprint planning — cutting the slice set

This skill produces ONE artifact: the sprint contract at
`.claude/sprint-<stage>/CONTRACT.md`. Its whole craft is two calibrations:
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

**Size the set: at least ~5 slices is the sweet spot, scaled by slice weight.**
Fewer than that and the sprint machinery (contract, ledgers, repair round) costs
more than it amortizes — land 2 slices as ordinary PRs instead. The ceiling is
what the repair round can genuinely attack in one pass: if the projected total
diff is too large to adversarially review, the sprint is two sprints. Each slice
should be roughly one writer-session of work; a slice that is obviously several
becomes a family candidate (flag it — the spike decides), and a slice that is an
afternoon's triviality gets merged into a neighbor or dropped to the ordinary
PR flow.

## Step 3 — specify each slice at BOUNDARY depth, deliberately no deeper

Per slice, the contract records exactly five things:

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
5. **Depends-on** — other slices by ID, forming the landing order.

**The orderings will rot faster than the facts** — plans' orderings are the
first casualty of contact. Mark the landing order as provisional; the
orchestrator re-derives it from the DAG state at each dispatch, and a refusal
re-cut reorders without ceremony.

## Step 4 — write the contract

`.claude/sprint-<stage>/CONTRACT.md` (record-dir naming rule: never a bare
`sprint/`), with these sections:

- **§1 The question** — the one-sentence purpose of the sprint.
- **§2 In / Out** — scope both ways, each Out with its reason stated so it can
  be overturned deliberately rather than rediscovered.
- **§3 The slice table** — the five fields above, one row per slice. **Slice
  IDs are descriptive slugs** (`S-selector-rekey`, `S-freeze-admissibility`),
  never opaque letters (`E4`, `F7`) — the packet contract's §0 identifier
  convention starts here, because every later document inherits these names.
- **§4 Already settled — do NOT re-derive** — sprint-wide facts with their
  proving commands (same discipline as a packet's §4; this seeds every packet).
- **§5 Issue-closure policy** — which issues this sprint may close, and that
  every close checks the PIN, not the narrative.
- **§6 Expected-red block** — the known-red gate set for the duration (copied
  into HANDOFF.md at sprint start by the orchestrator).
- **§7 Exit criteria** — including the repair round (non-optional) and
  desk-closes.

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
