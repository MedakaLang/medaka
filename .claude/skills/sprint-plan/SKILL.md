---
name: sprint-plan
description: Cut a sprint — choose a coherent set of 3–5 implementation slices and write a short sprint contract. Run ONCE per sprint, before the orchestrator session starts; judgment-heavy, so run on Opus 5 minimum. The contract it produces is what sprint-orchestrator executes.
---

# Sprint planning — cutting the slice set

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

## Step 2 — choose the SET: 3–5 coherent slices

Write the sprint's one question down first ("retire the method-keyed
selector"). A slice belongs iff it advances that question, shares context
(subsystem/spec/file neighborhood) with the others, and its dependencies are
inside the sprint or already landed. Sites that answer one decision move in one
slice — never split "to balance sizes". Fewer than 3 slices: skip the sprint,
land them as ordinary PRs. More than ~5: it's two sprints — the ceiling is
what one end-of-sprint review round can genuinely attack in one pass.

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
4. **Acceptance shape** — how we'll know it worked ("gate family X", "a new
   fixture class Y", "IR byte-identical"), not exact commands.
5. **Model** — `sonnet` (default) or `opus` with a one-line why. Opus is the
   right call for genuinely tricky slices: cross-cutting semantics, coupled
   sites, anything where a wrong-but-plausible transform is easy. When
   unsure, start sonnet; the orchestrator upgrades on a refusal.
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
