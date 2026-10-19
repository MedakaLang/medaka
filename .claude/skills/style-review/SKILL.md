---
name: style-review
description: End-of-sprint style/idiom checklist over a sprint diff, with a DECLINED register of demands a reviewer must not make. Once per sprint, not per PR. Load when judging whether a style finding is legitimate.
---

# Style review — the pointer checklist

`sprint-reviewer` attacks **correctness**: it builds the binary and tries to
break it. This pass is the other half — **craft**: duplication, comment
register, test vehicle, placement, diagnostics, docs, CLI shape. It never
builds anything and never fixes anything; it reports findings.

**The rule source for a craft finding is `docs/design/STYLE-RUBRIC.md`.** Cite
its class (`data.sentinel`, `comment.provenance`, …); its controls are findings
you must not make. Every section below is a pointer: if you find yourself
explaining a rule here, it has been forked. Cite the source.

## Scope — read this before the first finding

- **Diff-scoped only.** You review the sprint diff at the pinned SHA. A defect
  in code the diff did not touch is at most **one line in the report** as a
  neighbour observation, never a finding the sprint must fix. Reviewing the
  whole tree through a diff's keyhole is how a style pass becomes a stop-work.
- **Tests are in scope.** `*_test.mdk`, test row labels and shell gates meet the
  same rules as source (rubric R27); only a fixture that deliberately exhibits
  a pattern (a must-fail pin, a lint rule's own fixture) is exempt.
- **Cheap and once.** One dispatch in the sprint's END round, alongside
  `sprint-reviewer`, at the same pinned SHA. Not per-slice, not per-PR, not a
  required CI check — v8's cost discipline is a design constraint, not an
  aspiration.
- **Findings are ranked.** A reviewer who lists twenty equals has ranked
  nothing. Lead with the ones that would still be wrong in six months.
- **Cheap first pass.** Run the `review-diff` skill over the sprint diff
  first (`--rev <merge-base>..<pinned SHA>`); verify each of its findings
  against the rubric before reporting it. End the report with a **review-diff
  ledger**: every finding it raised, marked kept or dismissed. Each dismissal
  names the rubric exception, the DECLINED row, or "misread". Dismissals are
  the reviewer's measured false positives. The `style-rule` skill turns them
  into fixture controls.

## The checklist — each section, its single source

### 1. Duplication — did this diff rewrite something that exists?

Source: the rubric's `dup.existing`; the generated stdlib reference
**`docs/stdlib/index.md`** (until #4269 lands it omits interface methods such
as `orElse` and `traverse`: check the module page, e.g. `docs/stdlib/core.md`);
`compiler/support/`; and the lint rule **`rule-stdlib-reimpl`**. The rule
matches names exactly, so it is a floor, not the check: a helper renamed away
from its stdlib twin is what it cannot see and you can.

The author was asked to name what they looked for (the `sprint-packet` report
self-check). If a new helper arrived with "none needed", that answer is the
thing to test.

### 2. Comment register — does each comment state a constraint the code cannot show?

Source: **`[T-COMMENT-REGISTER]`** in `AGENTS.md` (the norms) and
**`make comment-census`** (`test/comment_register_census.sh`, #2281) for the
current derived per-class counts; the rubric's "Comments and documentation"
table for the classes. An issue number is fine only when it points at a live
constraint or an open issue (`until #1115 lands`); a provenance tag recording
which work item introduced the code is a finding (R4).

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
space, not an improvised one here. The one question asked here is the nearest
gate, answered with pasted `medaka gate explain <path>` output; on a migration
PR, also ask for the parity-plus-red transcript.

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
and the `Diag` JSON contract). Cite **`make diag-census`** rather than reading
messages by eye.

### 6. Doc register — is new prose live-and-gated, or is it new rot?

For a `stdlib/*.mdk` doc comment the source is **`stdlib/README.md` §
"Writing documentation"**: a marked `{- | -}` block whose first sentence
stands alone, no history/issue numbers/implementation notes/maintainer
warnings inside the block, no em-dashes, one or two examples. A cost contract
a caller relies on ("O(1) average lookup") is allowed (rubric `doc.register`). A finding
against a stdlib doc comment cites that section or it is not a finding.

For every other markdown file the source today is: **`make docs-links`** (every cited path must exist),
**`make agent-doc-symbols`** (every backticked symbol must resolve), and
**`make docs-index`** (`docs/README.md` is GENERATED — never hand-edited).
A number hand-typed into prose that the repo can derive is the failure mode
these exist to kill: `make fmt-clean-census` (#1794), `make arch-census`
(#2289), `make cli-conformance-census`, and `make doc-census` for a doc's
disposition (#2300).

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
| **Idiom density quotas** — pipes per file, "this should be a section", "convert this to a fold" | A density target is not readability, and it is unfalsifiable. A concrete pipeline of 3+ stages written inside-out is a finding (`idiom.inside-out-pipeline`, R17). |
| **Mass-conversion sweeps** — "convert every `X` in this file / this subsystem" | Out of diff scope by construction, and `lint --fix` reprints WHOLE declarations and bails on comment-bearing ones, so a sweep silently corrupts unrelated syntax in the same decl. If a sweep is genuinely owed, it is a filed issue with its own PR. |
| **Findings about untouched code** | Diff-scoped only (see Scope). At most one neighbour line. |
| **"Remove this suppression"** where the reason is one of the four valid kinds: a semantic difference, an independence requirement, a measured cost, a verified language limitation | That suppression is the correct outcome. Any other reason (a norm cited without evidence, deferred work, bare "intentional") is the finding (`suppress.invalid-reason`, R19). |
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
