---
name: style-review
description: The end-of-sprint style and idiom pass over a sprint diff — a checklist where every section points at a single source (duplication, comment register, test vehicle, placement, diagnostics rubric, doc register, CLI conformance) plus a DECLINED register of demands a reviewer must NOT make. Run once per sprint in the END round, at the same pinned SHA as sprint-reviewer, on a cheap model. Not per-PR, not a CI check. Load when reviewing a diff for craft/idiom, or when deciding whether a style finding is legitimate.
---

# Style review — the pointer checklist

`sprint-reviewer` attacks **correctness**: it builds the binary and tries to
break it. This pass is the other half — **craft**: duplication, comment
register, test vehicle, placement, diagnostics, docs, CLI shape. It never
builds anything and never fixes anything; it reports findings.

**Every section below is a POINTER.** If you find yourself explaining a rule
here instead of citing where it lives, the rule has been forked and this skill
has become the fifth copy of something with four consumers — the drift this
repo has already paid for twice. Cite the source; let the reader open it.

## Scope — read this before the first finding

- **Diff-scoped only.** You review the sprint diff at the pinned SHA. A defect
  in code the diff did not touch is at most **one line in the report** as a
  neighbour observation, never a finding the sprint must fix. Reviewing the
  whole tree through a diff's keyhole is how a style pass becomes a stop-work.
- **Cheap and once.** One dispatch in the sprint's END round, alongside
  `sprint-reviewer`, at the same pinned SHA. Not per-slice, not per-PR, not a
  required CI check — v8's cost discipline is a design constraint, not an
  aspiration.
- **Findings are ranked.** A reviewer who lists twenty equals has ranked
  nothing. Lead with the ones that would still be wrong in six months.

## The checklist — each section, its single source

### 1. Duplication — did this diff rewrite something that exists?

Source: the generated stdlib reference **`docs/stdlib/index.md`** (name-by-name,
regenerated from source — the answer to "does the stdlib have X"),
`compiler/support/` for compiler-private helpers, and the lint rule
**`rule-stdlib-reimpl`** in `compiler/tools/lint.mdk`. Epic #2246; #2248
(closed) records the two classes the rule structurally misses — stdlib
consumers behind a blanket path skip, and *renamed* reimplementations, since
the match is name-exact. **So the lint rule is a floor, not the check**: a
helper renamed away from its stdlib twin is exactly what the rule cannot see
and you can.

The author was asked to name what they looked for (the `sprint-packet` report
self-check). If a new helper arrived with "none needed", that answer is the
thing to test.

### 2. Comment register — does each comment state a constraint the code cannot show?

Source: **`[T-COMMENT-REGISTER]`** in `AGENTS.md` (the norms) and
**`make comment-census`** (`test/comment_register_census.sh`, #2281) for the
current derived per-class counts. Provenance and litigation belong on the
issue or in `.claude/dossier/`, linked; a comment that narrates the PR
(`earlier cut`, `this PR`, `refuted`, `ratified`) rots the moment the PR
merges. No emoji shouts in source comments.

⚠️ The census reports **line classifications, not disjoint defects** — do not
add its class counts together, and do not quote a count into your report as a
standing fact. Cite the command.

### 3. Test vehicle — is this tested by the right mechanism?

Source: the **`gates`** skill (`.claude/skills/gates/SKILL.md`) — which gate
proves what, fixture/golden authoring, and the dash-not-bash shell half. Also
`[WT-GOLDEN-ENSHRINES]` and `[T-SHARED-CORPUS]` in `AGENTS.md`, both of whose
failure mode is silent.

For the vehicle dispatch itself (doctest vs. property vs. `test "…"` sibling
vs. differential gate) source the **`write-tests`** skill
(`.claude/skills/write-tests/SKILL.md`) — its dispatch table and negative
space, not an improvised one here.

### 4. Placement — does this code live where it belongs?

Source: the **`architecture`** skill (`.claude/skills/architecture/SKILL.md`):
what each `compiler/` directory is for, the placement rules (driver dispatches
and never implements; entries stay thin; a new subsystem is a new file; past a
size threshold, extending instead of extracting needs a **stated reason**),
and the standing DECLINED register. `make arch-census` for the current
largest-files table.

The sprint contract was obliged to state placement before the code existed
(`sprint-plan` step 3). If the diff's placement differs from the contract's,
that mismatch is the finding — not your own preferred filing.

### 5. Diagnostics — does a new error message meet the rubric?

Source: **`compiler/ERROR-QUALITY.md`** (the rubric — read before writing a
diagnostic) and **`compiler/DIAGNOSTIC-CODES-DESIGN.md`** (the code taxonomy
and the `Diag` JSON contract).

*Pending:* #2302 builds `make diag-census`, the rubric-conformance census
ranked by first-hour reachability; it is already reserved as a
`make slop-census` row. When it lands, run it and cite it here instead of
reading messages by eye.

### 6. Doc register — is new prose live-and-gated, or is it new rot?

For a `stdlib/*.mdk` doc comment the source is **`stdlib/README.md` §
"Writing documentation"**: a marked `{- | -}` block whose first sentence
stands alone, no history/issue numbers/implementation notes/maintainer
warnings inside the block, no em-dashes, one or two examples. A finding
against a stdlib doc comment cites that section or it is not a finding.

For every other markdown file the source today is: **`make docs-links`** (every cited path must exist),
**`make agent-doc-symbols`** (every backticked symbol must resolve), and
**`make docs-index`** (`docs/README.md` is GENERATED — never hand-edited).
A number hand-typed into prose that the repo can derive is the failure mode
these exist to kill: `make fmt-clean-census` (#1794), `make arch-census`
(#2289), `make cli-conformance-census`.

*Pending:* #2300 is the doc census and disposition — every markdown file
live-and-gated, archived-with-a-date, or deleted. Reserved as a
`make slop-census` row, expected MISSING until it lands.

### 7. CLI conformance — does a new verb or flag match the ratified shape?

Source: **`docs/ops/CLI-CONFORMANCE.md`**, the single normative source for
unknown-flag rejection, exit codes, stream discipline, and `--json`;
re-derivable with **`make cli-conformance-census`**. Flag vocabulary is a
VALUE, not two hand-synced lists — `docs/design/ARGS-DESIGN.md`.

## DECLINED — demands this review must NOT make

A reviewer who makes one of these has generated churn, not craft. Each is
settled; do not reopen it inside a sprint.

| Declined demand | Why |
|---|---|
| **Pipe-density / idiom quotas** — "use `\|>` here", "this should be a section", "convert this to a fold" | `[DG-IDIOMS]` licenses idioms *where they genuinely improve readability*, verified on the binary. A density target is not readability, and it is unfalsifiable. |
| **Mass-conversion sweeps** — "convert every `X` in this file / this subsystem" | Out of diff scope by construction, and `lint --fix` reprints WHOLE declarations and bails on comment-bearing ones, so a sweep silently corrupts unrelated syntax in the same decl. If a sweep is genuinely owed, it is a filed issue with its own PR. |
| **Findings about untouched code** | Diff-scoped only (see Scope). At most one neighbour line. |
| **"Remove this suppression"** where the suppression carries a rationale | A `-- lint-disable-next-line <rule>` with a stated reason is the **correct** outcome, not debt. A suppression with no rationale is the finding; the suppression itself is not. |
| **"Add a lint rule for this"** | Not this reviewer's to implement — see the shrink rule below. It lands through its own filed issue and PR, gated either by the max ratchet (`GATED_LINT_RULES`, a rule the tree is already clean of) or, when it is not, by the per-(file, rule) count baseline (`BASELINED_LINT_RULES` + `test/lint_baseline.toml`, #2619 (lint count baseline)). |
| **Reopening a standing architecture decision** | The `architecture` skill's DECLINED register — hard size ratchets, the `typecheck.mdk` split's sequencing (#2586 (typecheck refactor), which superseded the closed #2284), the `driver`/`tools` de-grab-bag's ownership (#2282), skill-tree mirroring (#2313). |
| **A comment-length or comment-count ratchet** | Declined on record (#2281): a length ratchet teaches agents to write short bad comments. |

## The shrink rule — this checklist must get SHORTER

**Any finding you have now made twice, that is syntactically detectable, stops
being a review item and becomes a lint-rule issue.**

File it — with the two instances as evidence, the proposed rule, and an
honest note that the max-ratchet model needs it tuned to ≈zero findings or
left ungated. **Do not implement it**: crusade #2276 declines new lint rules
until the baseline question is settled, so an implemented rule would red the
tree or sit unenrolled. Filing is the deliverable.

A checklist section that has produced no finding across several sprints is a
candidate for deletion, not for more prose. The bias is toward removal.

## Reporting

Same three-section shape every sprint agent uses (`sprint-packet` § "The
report"): **Verdict / Evidence / Notes**, verdict on the first line, graded by
`sh scripts/sprint-report-check.sh <report>`. Findings go in Evidence, ranked,
each with the file:line it is about and the source it is measured against.
Findings you declined to make — and why — go in Notes; that is how the
DECLINED register gets tested.
