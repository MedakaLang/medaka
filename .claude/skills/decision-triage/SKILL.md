---
name: decision-triage
description: Before bringing any decision, open question or option set to Val (a design doc's "decisions for Val", an epic's checkboxes, a sprint's "owed to Val" list, a surface or placement call), run it through three questions and adopt the answer yourself when one of them settles it with reasonable confidence. Load whenever you are about to write "Val decides", "ruling needed" or "options for Val", and when presenting the decisions that survive.
---

# Decision triage: decide it yourself, or bring it properly

Val's rule (2026-11-02): most decisions agents bring her have an answer a careful
engineer would reach alone. Bringing them costs her attention and stalls the sprint.
A decision reaches her only when the three questions below leave it genuinely unclear,
and then it arrives in one fixed shape, one at a time.

## 1. First, is it a decision at all?

Not a decision, do not bring it:

- **Already ruled.** Check the decisions index in memory
  (`project_decisions_index`), `compiler/ARCHITECTURE.md` §5 "Settled, and not
  reopened here", the design doc's own rulings, and the epic. A settled ruling is not
  re-asked. A case it does not cover, or one that conflicts with it, is a new question
  that names the ruling it would amend.
- **A measurement.** "Cache or not", "which engine for `test`", "is it fast enough":
  take the measurement first; the number decides. Bring it only if the number is
  ambiguous and the stakes are high.
- **Someone else's.** A policy question owned by another epic or issue (an exec gate,
  a stdlib surface under review) stays there; link it, do not re-raise it.
- **Reversible and internal.** An encoding, a module name, an opcode set, a probe
  shape: choose, record the reason in the module header or the PR body, move on.

## 2. The three questions

Ask them in order, in writing, before any decision goes to Val. If any one of them
points to a particular answer with reasonable confidence, **adopt that answer** and
record it (§3). Bring the decision only if all three leave it unclear.

1. **Is there a principled fix without a major blocker?** A principled fix follows
   from an existing law, contract or spec (`compiler/ARCHITECTURE.md`'s laws, the
   playbook, `docs/spec/`) rather than from convenience. A major blocker is a standing
   ruling it would overturn, a measured cost it cannot pay, or a dependency that does
   not exist. "It is more work" is not a blocker.
2. **Does a mature language or implementation handle this successfully in a way we
   should emulate?** Name it: OCaml, GHC, rustc, Swift, Scheme, Deno, Go, CPython, Lua.
   The repo's standing method is precedent-derived (`feedback_phase4_six_principles`,
   principle 2; "follow Rust unless a good reason", `decided_r35_follow_rust_20261018`).
   Probe the claim before relying on it; a wrong premise gives a wrong decision.
3. **What is best for the long-term maturity of the language?** Prefer the answer that
   leaves one mechanism rather than two, keeps every engine on one rule, makes a
   divergence loud rather than silent, and will still look right in a mature compiler.

"Reasonable confidence" means you would defend the choice in review without hedging.
If two questions disagree (precedent says one thing, long-term maturity another), that
is exactly the unclear case: bring it.

## 3. Recording an adopted decision

An adopted decision is still a decision; it is written down where the next agent will
look, not only in the PR that applied it.

- On the epic or issue that listed it: tick the box and append
  `Adopted under decision-triage: <answer>. Settled by Q<n>: <one sentence>.`
- In the design doc that proposed it: the status line of the decision changes from
  "for Val" to "adopted (decision-triage, <date>)" with the same sentence.
- If it amends or narrows a standing ruling, say so by name and add the new ruling to
  the memory decisions index.
- Val can overturn an adopted decision at any time; make that cheap by keeping the
  reasoning one sentence and the alternative named.

## 4. Bringing a decision that survives

One decision per message. Settle it before the next; queue the rest and say how many
remain. The shape, every time:

```text
Decision: <one line naming the choice>
Why it survived triage: <which of the three questions is unclear, in one sentence each>

Options
  A. <option>   pros: … cons: …
  B. <option>   pros: … cons: …
  (C. fine as it is / do nothing, when that is real)

Recommendation: <A|B|C>, because <one or two sentences>.
What the answer changes: <issue numbers, modules, the next step that waits on it>
```

- Options are concrete and mutually exclusive; two is usually right, four is the cap.
- Pros and cons are facts you checked, not adjectives. Cite a path, a number or a
  precedent for each.
- The recommendation is first in your own mind and last on the page; never omit it.
- Ask on a real instance where one exists (a file, a fixture, a measured number),
  as the `style-rule` skill already requires for style rulings.
- Do not pad: no history, no restating the design doc, no "on the other hand" prose.

## 5. Worked example (the interpreter epic, #4811, 2026-11-02)

Thirteen decisions were listed for Val. Under triage:

- D2 dictionaries as method tables: Q2 (GHC dictionary records, Swift witness tables,
  rustc vtables) and Q3 (one dispatch mechanism) settle it. Adopted.
- D10 strict top-level initialisation: Q1 found a major blocker, the standing ruling
  that top-level nullary bindings are lazy (`lazy-toplevel-nullary-canonical`,
  2026-06-10), and Q2 found GHC's CAF model matching the current design. Adopted the
  opposite of the proposal: keep lazy, the VM implements the forcer; the issue that
  proposed the change was closed with that sentence.
- D11 guaranteed tail calls: Q2 (OCaml, GHC, Scheme) and Q3 (no silent engine
  divergence) settle the goal; whether the native backend can pay for it is a spike,
  not a decision. Adopted, spike first; the spike's result returns as a decision only
  if it finds a blocker.
- D7 the exec posture: owned by #4414 in the policy epic. Not re-raised.

None survived. That outcome is normal and is reported as a short table of adoptions,
each with its settling question, so Val can overturn any of them in one line.

## 6. What this skill does not change

- Stdlib surfaces still need Val's proposal review before implementation
  (`feedback_stdlib_additions_need_a_proposal_review_first`): that is a review, not a
  decision, and triage does not skip it.
- Style rulings go through `style-rule`, one question at a time on a before/after
  pair; the one-at-a-time rule here is the same rule.
- Destructive or outward-facing actions still need confirmation; a decision about
  *what to build* is not permission to delete, publish or merge.
