# Cutting a v8 sprint

Run this once before the orchestration session. The output is one compact
`/var/tmp/medaka-sprints/<stage>/CONTRACT.md`, shadowed by one tracker issue.

## Derive before cutting

- The backlog is GitHub Issues. Start with open S0s, then the chosen
  workstream. Confirm each candidate is still open and still owed against the
  pinned source revision; `needs-repro` work is a cheap repro slice or stays
  out.
- Search the source, merged history, design docs, and adjacent workstreams for
  the issue IDs. Inherited plans and one-directional citations are claims,
  not evidence.
- State the sprint's single question. Admit only 3–5 slices that advance it,
  share its context, and have their dependencies in the sprint or already
  landed. Put all sites answering one decision in one slice. Fewer than three
  is an ordinary PR; more than five is two sprints.

## Contract shape

The contract contains:

1. Question.
2. In/out scope, with a reason for every exclusion.
3. Slice table. Each row has a descriptive ID, short mission, approximate
   surface, acceptance shape, dependency order, and `parallel-ok` only with
   derived disjointness evidence.
4. Settled facts with the commands that proved them. These seed packets so
   writers do not repeat discovery.
5. Issue-close policy, including any fixture/pin checks.
6. Expected-red gates, if any.
7. Exit criteria, including domain property classes the whole-diff reviewer
   must cover when the stage enters crypto, protocol, hostile input,
   concurrency, or irreversible-effect territory.

Keep it at boundary depth. Packets name exact transforms and commands just in
time; speculative design-ahead is rework. An exit criterion that requests
deletion must also license a falsifiable alternative when no pre-fix fixture
can reach the dead path (for example, an N-way differential demonstrating the
path is unreachable by construction).

## Admission

Create the sprint branch and draft PR from the pinned revision. Post a short
issue update with §1–§3 and §7, then read it back. Do one adversarial contract
read: identify the slice most likely to refuse, relayed rather than derived
facts, accidental shared decisions, and non-failing acceptance. Correct those
now. The contract may change when evidence changes; record each change as one
line in `NOTES.md`.
