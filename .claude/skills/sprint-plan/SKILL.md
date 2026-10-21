---
name: sprint-plan
description: Cut a sprint — choose a coherent, reasonably sized set of slices (usually 3–5, more if small, fewer if large) and write the contract sprint-orchestrator executes, module shape and exports included. Run once per sprint, before orchestration, on Opus.
---

# Sprint planning — cutting the slice set

In Codex, first read [.codex/SPRINT.md](../../../.codex/SPRINT.md) for model
and harness mappings. In Pi, read `.pi/SPRINT.md` from the repository root
instead. The planning workflow below is shared by all three clients.

A sprint (v8) is a simple machine: **a series of implementers that run one after
another, each doing minimal verification, followed by one thorough review round
and one fix round, then the merge queue.** Its three goals, in order stated by
Val: (1) high throughput of implemented code, (2) low token cost, (3)
correctness before merge to main. Planning serves those goals by picking the
right work and writing it down SHORT — the contract plus all packets should be
readable in minutes, not hours.

This skill produces ONE artifact: `/var/tmp/medaka-sprints/<stage>/CONTRACT.md`
(never a bare `sprint/` dir name), shadowed by one GitHub tracking issue.

## Step 1 — derive the candidate pool; trust nothing inherited

- **The backlog is GitHub Issues, not any doc.** Start from
  `gh issue list --label "S0: silent wrongness"` and the sprint's workstream
  label; severity orders candidates (S0 > S1 > S2 > S3; soundness outranks
  release).
- **Check each candidate's state before it enters the pool** — re-derive
  "still open / still owed" against the tree at the pinned base, with the
  command recorded. When a backlog was last re-derived, SIX entries were
  already fixed, including two billed as top-value. A `needs-repro` item
  enters as a cheap repro slice or not at all.
- **Grep the other arcs/docs for your issue numbers** (`grep -rn '#<NNN>'
  docs/ .claude/`) — a one-directional citation once scoped a slice that was
  verbatim another arc's claimed work.

## Step 2 — choose the SET: coherent, and sized for one review

Write the sprint's one question down first ("retire the method-keyed
selector"). A slice belongs iff it advances that question, shares context
(subsystem/spec/file neighborhood) with the others, and its dependencies are
inside the sprint or already landed. Sites that answer one decision move in one
slice — never split "to balance sizes".

**The count is not the rule; the size is** (Val, 2026-10-18). A sprint is
bounded by what one end-of-sprint review round can genuinely attack in one
pass, and by coherence. Usually that is 3–5 slices. Go above 5 when many of
them are small (a pin, a move, a rename, a caller sweep, a doc row); go below
3 when the work only makes sense as large items. One large slice plus its
mechanical subslices is still one sprint. A sprint of two unrelated large
slices is two sprints.

**Split a decision from its mechanics.** Where a slice holds one opus-grade
decision (a semantic choice, coupled sites, a wrong-but-plausible transform)
and a tail of mechanical work (rewiring callers, pins and goldens, doc rows,
comment rewrites, a probe corpus), cut the tail as its own subslice on a
cheaper model, sequenced after the decision lands (or before it, when the
tail is preparatory and independent). Name the pair `S-foo` / `S-foo-mech`.
Evidence: Phase 1's largest opus reports (22–26 KB) were mostly the mechanical
tail written up at opus prices; the decision each contained fit in a page.

## Step 3 — the contract, at boundary depth

Per slice, six fields — and no more. Exact sites, transforms, and commands are
the packet's job, written just-in-time by the orchestrator; design-ahead
deeper than this measured ~75% rework.

1. **ID** — a descriptive slug (`S-selector-rekey`), never an opaque letter.
2. **Mission** — one paragraph: what is true after it lands, citing issues.
3. **Surface** — the files/subsystems it probably touches, honestly labeled
   an approximation. If the sites can't be named confidently, flag
   `SPIKE-FIRST`: the slice's first dispatch explores and reports instead of
   implementing.
   **A relayed premise is not a fact.** Any Surface or §4 claim that came from
   a review, a spike report, a prior contract or a NOTES row carries the
   `path:line` the planner opened at THIS sprint's base (`Checked-at:`); a row
   without one is `SPIKE-FIRST`, and splitting or re-modelling a slice resets
   the check. Phase 1 lost three opus rounds to relayed claims (a hover
   context that lived in a frozen file, "gate drive = pair drive", "no program
   depends on it"); every one was refutable with one `grep` at cut time.
   **A deletion names its victim.** A slice that deletes a check, a drive or a
   re-check names, in §4, one program that only the deleted check rejects,
   with base and head exit codes, or states that none could be built, which is
   itself a finding. "No fixture changed" and "IR identical" are not evidence
   that nothing judged: every drive Phase 1 removed had been the only judge of
   something (sprint 1 F1, sprint 7 F1, sprint 8 F1, an S0 miscompile that
   passed 2,761 differential cases and an unnarrowed CI).
   ⚠️ **A slice that adds a file, a subcommand, a subsystem, or a helper must
   STATE ITS PLACEMENT AND SHAPE here** — which directory owns the new code,
   and if it extends an existing file rather than adding one, why. **Shape is
   the plan's job, not the implementer's** (Val, 2026-10-18): for each module
   the slice creates or materially changes, the contract states its one-line
   responsibility, the exports it provides (names, and signatures at boundary
   depth: the types that cross the boundary, not bodies), and what it may not
   import (its closure golden, if it is a leaf). That is where the architecture
   is decided, on Opus, against the laws, before any code exists. The
   implementer may deviate on contact with evidence the plan lacked (a cycle,
   a cost, a missing fact), and records the deviation as a Notes row the
   review judges; an undeclared deviation is a finding. Bodies, helper names
   and exact sites stay out of the contract; they are the packet's and the
   implementer's. Ground truth is the
   **`architecture`** skill (`.claude/skills/architecture/SKILL.md`): what
   each `compiler/` directory is for, the placement rules, and the standing
   DECLINED register — read it before writing the row, and do not relitigate
   a decision the register already closed. The asymmetry is the reason this
   is an obligation and not a nicety: **placement decided before the code
   exists costs nothing; placement fixed afterwards costs a snapshot re-bless
   (`[T-SNAPSHOT-SELF]`) and usually a LEG A golden re-capture
   (`[T-LEGA-GOLDEN]`) on top of the move.** `make arch-census` gives the
   current largest-files table if the slice might grow one of them.
   The placement must also satisfy the laws in `compiler/ARCHITECTURE.md`
   (layers, output as a value, state lifetime, one fact one producer); a
   contract that conflicts with a law says why in the row. A slice that
   touches `compiler/types/typecheck.mdk` leaves it no larger than it found
   it or carries the `Arch-Growth-Override:` reason (D1, #4200), and that
   reason names the sibling module the lines will leave to (playbook §10).
   A module newly over 3,000 code lines needs an `Arch-Pin-Raise:` for
   `oversize.golden` and a header reason (law A8). Record
   `make arch-census` at cut; wrap-up diffs against it
   (`compiler/ARCHITECTURE-PLAYBOOK.md` §10).
4. **Acceptance shape** — how we'll know it worked ("a `test` case in
   `<module>_test.mdk`", "a `kind = "native"` gate-test row", "IR
   byte-identical"), not exact commands. Pick the vehicle with the
   `write-tests` skill; a shell gate needs its `shell-because:` reason.
   **A semantics-changing slice is gated by rule, not by an approved list**
   (Val, 2026-10-21, from the Phase 2 stage-6e retro): its acceptance is
   "every moved row is classified by a numbered rule (C1..Cn) and the packet
   lists the classes with counts", and the census that finds the moved rows
   runs once, over the WHOLE tree (every `test/**` program plus the inline test
   programs), in the survey slice. An approved list of rows is a measured set
   smaller than the affected set: 6e's lexical-location slice was refused
   twice (102 rows, then 1) for list completeness alone, and the 188 rows were
   approved by class in the end anyway.
   **A survey or decision slice that proposes a variant measures the
   variant's retention** (`ret.sh`-style heap rows) before the landing slice
   is cut, beside its instruction counts. 6e's landed variant then breached
   the +5% heap bound (+20.9%), which cost a whole carrier slice and a
   three-arm measurement the survey's own one-round number had foreshadowed.
5. **Model** — name the selected harness role, model/reasoning and a one-line
   tier justification. **Claude:** three tiers. `haiku` for a mechanical slice
   whose transform, sites and expected values are all written down (a rename
   or move, a pin or golden capture, a probe, a caller sweep a grep lists, a
   doc row); `sonnet` by default; `opus` for genuinely tricky slices
   (cross-cutting semantics, coupled sites, wrong-but-plausible
   transformations). A refusal with evidence of real difficulty moves the
   slice up one tier (haiku to sonnet to opus) with one NOTES.md line; a
   refusal because the packet was wrong is re-dispatched at the same tier on
   a corrected packet. No slice starts on opus that step 2's split rule could
   have made a sonnet decision plus a haiku tail.
   **Codex / Pi:** use `.codex/SPRINT.md` or `.pi/SPRINT.md`, respectively,
   instead of that Claude rubric. Terra/high is the default, including
   coupled-site work with a settled remedy. Sol/high must name the unresolved
   semantic or algorithmic decision, not merely severity, subsystem, file count
   or test volume. Pi contracts/packets name the actual project agent and its
   configured model, since dispatch has no per-call model override.
6. **Depends-on / parallel-ok** — landing order by ID. Slices are executed
   SERIALLY by default. A pair may be marked `parallel-ok` ONLY with
   disjointness evidence in the contract: the two surface lists, a
   `scripts/sprint-disjoint.sh` run over them (it also predicts golden and
   snapshot collisions — disjoint source files have collided on a single
   golden), and no shared fixture corpus. Asserted-not-derived disjointness
   is not disjointness.

Contract sections: **§1 the question · §2 in/out (each Out with its reason) ·
§3 the slice table · §4 already-settled facts with their proving commands
(seeds every packet; implementers trust these and re-derive nothing in them) ·
§5 issue-closure policy (every close checks the PIN, not the narrative) ·
§6 expected-red gates for the duration, if any · §7 exit criteria.**

⚠️ **A §7 criterion demanding dead-code deletion ("delete X, with a fixture
that can fail") can be unfalsifiable as written** — if the dead path is
already unreachable everywhere the tree can drive it, no fixture can go red
before the fix, and no fixture can prove the deletion safe. `predicate-slots`
paid for this: 3 full rebuilds + 298 assertions to demonstrate the literal
form was unmeetable, then a mid-sprint stop for Val to accept the only
evidence that existed. **Pre-license a second discharge form in the
criterion itself**: an N-way build differential (the code path forced live /
forced dead / as-is, compared) showing the path is unreachable by
construction is an equally valid close, stated as such up front — not
improvised and escalated mid-sprint when the literal form turns out
unmeetable.

If the sprint dogfoods the language in a new domain (crypto, protocols,
concurrency, irreversible external effects), name the property classes the
end-of-sprint review must cover in §7 — or state in one line why none apply.

## Step 4 — the tracking issue, then one adversarial read

Open one GitHub issue titled with the sprint's question, body = §1–§3 and §7,
labeled by workstream; verify by readback. Then one pass over the contract
asking: which slice would an implementer refuse, and why? Which §4 fact is
relayed rather than derived? Which two slices secretly share a decision?
Fixes are 10× cheaper here than as mid-run refusals.

The contract is provisional: contact revises it (the orchestrator edits it and
logs one line in NOTES.md). A contract that survives unchanged is suspicious.
