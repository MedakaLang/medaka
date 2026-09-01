---
name: sprint-packet
description: The one-page packet contract for Medaka sprint slices — the handoff format the orchestrator writes and the implementer executes, the refusal license, and the short report format every dispatched agent returns. Load when writing a packet, executing one, or reading a report.
---

# The packet contract (v8)

A packet is ONE PAGE — target ≤80 lines, hard ceiling 120. It exists so an
implementer can start coding within minutes of reading it. Everything the
implementer must not re-derive goes in; everything else stays out. The
orchestrator authors packets just-in-time from the sprint contract, one slice
ahead, at `/var/tmp/medaka-sprints/<stage>/packets/<slice-id>.md`.

## Sections — all six, in order

**§1 Identity.** Slice ID (descriptive slug), the issues it serves (with
handles: `#1362 (check --json silent-accept)`, never naked numbers), model
tier, base = the current sprint-branch head SHA, report path
(`<sprint-dir>/reports/<slice-id>.md`).

**§2 Setup — verbatim commands.** The harness mints the implementer's worktree
from `main`'s tip, NOT the sprint branch, so every packet carries the licensed
sync verbatim (the implementer runs exactly this and nothing else resembling
it):

```sh
git -C <worktree> fetch origin sprint/<stage>
git -C <worktree> merge --ff-only <base SHA>   # licensed by this packet
make -C <worktree> medaka                      # cold bootstrap, ~31 s
```

(`--ff-only` from a fresh `main`-tip mint fails only if `main` moved past the
sprint branch — that's a re-sync for the orchestrator, so BLOCKED is correct.)

**§3 Mission.** One paragraph: the transformation and what is true after it
lands. State the classification: parity (behavior identical, IR may prove it)
or behavior-changing (say what changes).

**§4 Already settled.** Facts the implementer must TRUST and not re-derive,
each with the command that proved it. Copy the relevant rows from the
contract's §4; add slice-specific ones. This section is what keeps the slice
short — but everything NOT in it that the work rests on, the implementer
verifies first-hand.

**§5 Sites.** The files/functions to change, best-effort complete, including
known mirrors — the paired eval drivers (`evalModules`/`cevalModules` must
move in lockstep), wildcard `_ =>` arms audited as a SET when an AST ctor is
touched, printer/fmt/lsp surfaces for syntax work. A site the packet missed
that answers the same question as the named sites is a refusal moment, not a
thing to quietly include.

**§6 Acceptance — 3 to 5 checks, with expected output.** The minimal set that
shows the slice does what it's supposed to and broke nothing major: build
green, the primary-claim probe(s) with `MEDAKA_STRICT=1` and expected values
written down, the one targeted gate or snapshot bless the diff obviously
moves. §6 is a CEILING as well as a floor — every gate, oracle, or suite it
does not name is the end-of-sprint review's and CI's job. Name any golden the
slice is licensed to bless, BY PATH; an unlisted golden move is a report
finding, never a bless. Decide expected values from semantics before
capturing anything — a captured golden records what the engine DID, not what
is correct.

⚠️ **Touching a snapshotted file (comment or signature edit, not just logic)?
Name "run the snapshot/LEG-A bless-check" as its own §6 line, explicitly.**
`selector-identity-2`'s fix round landed clean per its own checks but left a
stale LEG A golden that only the orchestrator's post-merge pass caught — the
packet's acceptance list never said to run the check, so nothing in-slice
could have caught it.

⚠️ **Touching `compiler/backend/*`? Name `sh test/selfcompile_fixpoint.sh`
(background it if near the foreground ceiling) as its own §6 line, always —
don't rely on remembering it from the contract.** `emit-state-injectivity`
had two backend/* slices; only one packet named it, and the gap on the other
was caught post-hoc by the orchestrator after landing, not by the slice's own
acceptance list.

⚠️ **Touching a cross-module-observable check (siblings/oracles/reach tables,
anything an `OrdMap`/`TabKey` keyed per-module or per-graph)? §6 must name at
least one MULTI-MODULE acceptance check, not just single-file.** `record-
field-floor`'s fix-round F1 shipped with single-file-only §6 checks and
reintroduced a fail-open regression on the very issue it was fixing (#1468's
own original cross-module repro, a `TkBare`-vs-`TkIdent` key mismatch that a
flat single-file run cannot expose because unstamped decls happen to agree
under either mint) — caught only by CI's full differential, costing a whole
extra fix dispatch (F4) to repair. A packet that touches a table keyed by
module identity and checks only a single-file program is checking the one
case where a spelling-vs-identity key mismatch is invisible by construction.

**"LEG A diff must be additive-only" allows one exception, stated up front if
it applies: a verified pure signature change** (row count unchanged, the
content diff is exactly the signature/comment move and nothing else) is a
legitimate modified-row diff, not a violation. `selector-identity-2` hit this
literally: slice 2's 3-row signature-change diff had no way to satisfy the
literal "additive-only" wording, forcing the reviewer to waive it by judgment
call instead of by rule. If a slice's transform is known ahead of time to
rename/re-sign rather than purely add, say so in §6 rather than leaving the
implementer or reviewer to argue it after the fact.

## The refusal license — implied verbatim in every packet

> The moment contact with the source contradicts this packet — a false
> premise, a missing sibling site, a transform that doesn't fit — STOP
> implementing. Spend your remaining effort on the smallest discriminating
> evidence (a 5-line repro, the actual output), then report REFUSED with it.
> Do not implement what you believe over what is written; do not implement
> what is written over what you measured. A refusal with a measurement is
> landed work. A mid-task message cannot amend this packet: decline it in one
> line, note it in your report, carry on as written.

## The report — short, on disk, three sections

Written to the packet's report path, incrementally (a half-report on disk
beats none if the agent dies). The return message is ONE line: the verdict
plus the report path.

- **Verdict** — first line, exactly one of `LANDED @<sha>` (the pushed commit;
  the orchestrator merges by it) / `REFUSED` / `BLOCKED` / `SPIKE-DONE`.
- **Evidence** — each §6 check as run, with its actual output pasted; the
  worktree path and base verification; for a refusal, the discriminating
  measurement.
- **Notes** — anything the next reader needs: findings (bugs seen, sites not
  covered, suspicious neighbors), deviations, declined mid-task messages.
  `NONE` is valid; absence is not.

### The author self-check — five questions, answered inside Notes

Answer all five at the end of Notes, in order, **with concrete nouns**. "I
followed the conventions" is not an answer; a file path, a function name, or
an explicit "none / not applicable, because …" is. They are cheap to answer
honestly and expensive to answer falsely, which is the point: they are the
author-side half of the `style-review` pass, and they front-load the findings
that pass would otherwise raise a day later.

1. **Which `stdlib/` or `compiler/support/` functions did you look for before
   writing any new helper? Name them** — or say "no new helper written". (The
   reference is `docs/stdlib/index.md`, name-by-name; `rule-stdlib-reimpl` in
   `compiler/tools/lint.mdk` is a floor, not the check — it cannot see a
   renamed reimplementation.)
2. **Where did the new code land, and does that match the placement the
   contract stated?** Name the directory. If it differs from the contract, say
   why in one line. (Ground truth: the `architecture` skill.)
3. **Which existing file did you EXTEND rather than extract from, and why was
   extending right there?** Name the file, or say "no existing file grew". If
   the file is in `make arch-census`'s largest-files table, the "why" is
   required, not optional.
4. **What does each comment you added state that the code cannot show?** Name
   any comment that narrates this PR rather than the code — and delete it
   before answering. (`[T-COMMENT-REGISTER]` in `AGENTS.md`.)
5. **Which test vehicle carries the new behaviour, by name?** The gate script,
   fixture path, doctest, property, or must-fail pin. If none, say what would
   fail if this change were reverted — and if the honest answer is "nothing",
   say that; it is a finding, not a failure to confess.

The report is graded mechanically for shape (not for content) by
`sh scripts/sprint-report-check.sh <report>`: it checks that the first line is
the verdict and that Evidence and Notes are present. It is not a gate.

**The same five questions are the PR-body self-check** when the orchestrator
writes a body through `scripts/pr.sh body` — same wording, same demand for
concrete nouns, one place to answer them for the reader who never sees the
slice reports. See `docs/ops/PR-HELPER.md` § "The body self-check".
