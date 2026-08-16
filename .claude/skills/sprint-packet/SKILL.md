---
name: sprint-packet
description: The writer-packet contract for Medaka sprints — the fixed format every slice handoff must follow, the standing refusal license, and the report format every agent returns. Load when writing a packet (sprint-planner), enforcing one (orchestrator), or executing one (any dispatched agent whose brief cites a packet).
---

# The packet contract

A packet is the complete handoff for one slice. The receiving agent should need
NOTHING outside the packet plus the repo — no conversation history, no "as
discussed", no unstated context. Packets are files in
`/var/tmp/medaka-sprints/<stage>/packets/<slice-id>.md`, and the dispatch brief is one line:
"Execute packet <path> under the sprint-packet contract."

**A slice is a transformation over named sites.** If it cannot be stated as "apply
this transformation to these N named sites," it is not a slice yet — it is design
work, and it goes back to the planner or the brain.

**Every section below is mandatory.** `NONE` (with one line of why) is a valid
section body; an absent section is not. The orchestrator bounces an incomplete
packet back to the planner exactly as it bounces an incomplete report — nobody
downstream fills a gap by inference.

## Slice forms — how work gets decomposed, and why this way

**The rationale, so nobody re-litigates it mid-sprint:** a correct decomposition of
nontrivial compiler work cannot be derived by analysis — only discovered by contact
with the source. Measured here: design-ahead had a ~75% rework rate, and one
sprint's design doc was wrong about 4 of 6 bites, every error caught by the agent
handed it. So this workflow buys its decompositions empirically (the Mikado
Method's attempt→observe→revert loop) instead of trusting static planning, and it
splits "atomic-looking" changes with parallel change (expand–migrate–contract)
instead of partial motion. Three slice forms result:

1. **Standard slice** — the default; everything in this contract as written.
2. **Discovery spike** — dispatched when the planner cannot name the sites with
   confidence. Opus 5, timeboxed, **throwaway-diff licensed**: attempt the naive
   change, note what breaks, REVERT, record the broken thing as a prerequisite,
   recurse. The deliverable is knowledge, never code: a leaf DAG (below) with each
   leaf classified parity/behavior-changing, plus a **stability verdict** — did
   the DAG hold still during discovery, or keep collapsing? The spike's tree must
   end byte-identical to its base (`git diff` empty); a spike that ships code has
   failed its charter.
3. **Family** — a DAG of small leaves discovered by a spike (or confidently named
   by the planner for genuinely mechanical fan-out). Shared preamble (§1–§4,
   §7–§8 once), then one **leaf stanza** (§5+§6, scoped to that leaf) per node.
   Executed in dependency order, in ONE worktree, by ONE implementer continued
   leaf-by-leaf — its context accumulates, so mid-family discoveries carry
   forward instead of dying between dispatches. Every leaf ends at a
   compile-coherent, committed boundary.

**Form selection is mechanical, off the spike's stability verdict:** clean stable
DAG → family on Sonnet 5. Unstable DAG (leaves kept coupling during discovery) →
ONE Opus 5 implementer for the whole slice, no decomposition theater — stretching
a smaller model across genuinely coupled work is the failure mode this workflow
exists to avoid.

**When a leaf collapses mid-family** (the implementer hits a wall or refuses): the
leaf is REVERTED, not muscled through — committed-green boundaries make the revert
cheap, and the finding routes refusal → brain → planner, who revises only the
REMAINING leaves of the DAG. A collapsed leaf is the machinery working: it is the
Mikado discovery loop running one level deeper, not a planning failure to hide.

**Expand–migrate–contract is the ONLY licensed way to split a one-question site
set** (see §5's one-question check). An *expand* leaf adds the new substrate
alongside the old with nothing reading it; *migrate* leaves move readers one at a
time; a *contract* leaf performs the cutover and deletes the old substrate. Every
intermediate state is coherent because coexistence is deliberate and the cutover
is a named leaf — unlike partial motion, which leaves two organs silently
answering one question from different substrates (the recorded S0 shape). The
brain signs off on any expand/contract plan before its family is cut.

## §0 Identifiers carry names — the sprint-wide convention

**A bare identifier never travels alone.** Issue numbers, slice IDs, finding
IDs, and ruling IDs are unreadable to anyone (Val explicitly, but also every
agent joining mid-sprint) without a handle. Everywhere an identifier appears —
packets, reports, ledgers, consults, PR bodies, status messages — it carries a
short descriptive handle:

- Issues: `#1362 (check --json silent-accept)` — mint the handle from the
  issue's mechanism, not its symptom, and reuse it verbatim thereafter.
- Slices/leaves: IDs ARE descriptive slugs — `S-selector-rekey`,
  `L2-migrate-eval-reader` — never bare letters like `E4`/`F7`.
- Findings: `F3 (wasm arm missing)` — the row's one-line claim supplies it.
- Rulings: `RUN-<stage>-007 (defer-engine-hedges)`.

The handle is MINTED ONCE, at first use, and then stable — two handles for one
identifier is worse than none, and renaming mid-sprint breaks every grep. Docs
may drop the number but never the handle. The orchestrator bounces ledger
entries and consults that carry naked identifiers, same as missing report
sections.

## §0b Terse mode — inter-agent text is for machines that bill by the token

**Every artifact whose reader is another agent — reports, packets, consults,
rulings, ledger rows, drafts — is written TERSE: telegraphic, no filler, no
restating the question, no politeness, fragments fine.** Only the
orchestrator's communication with Val is normal prose.

Terseness compresses the PROSE, never the CONTENT. Keep, always, at full
fidelity: exact commands and outputs, paths, handles, numbers with their
producing commands, epistemic labels (DERIVED/RELAYED/UNVERIFIED), scope and
depth qualifiers ("first-level only"), negative results, and every caveat.
Those are precisely what summarization historically dropped — a terse report
that loses a caveat has sacrificed meaning, which is the one trade this rule
forbids. Rule of thumb: cut every word whose deletion changes nothing; keep
every word whose deletion changes anything.

## §1 Identity

- **Slice ID** and issue refs (`#NNN`).
- **Pinned base:** the exact sprint-branch SHA this packet was derived against —
  never a moving ref; shared `.git` means refs advance under you mid-task.
  **The sprint branch moves between packet-writing and dispatch** (v3 single-PR
  model), so the dispatch brief carries TWO SHAs: the packet's pinned SHA and
  the worktree's actual head. The implementer's step-0 check is: `git diff
  <pinned>..HEAD -- <every §5-named file>` is EMPTY. Non-empty → the region
  changed under the packet → STOP and report per the abort condition; empty →
  proceed on the newer head.
- **Branch name** and **absolute worktree path**. State explicitly: "Ignore any
  CLAUDE.md-header path — your tree is the path above; run everything with
  absolute paths."
- **Form:** `standard` | `spike` | `family` (see Slice forms).
- **Classification:** `parity` (behavior provably unchanged — diffs/gates are the
  oracle) or `behavior-changing` (anything else; all soundness work). This drives
  the model tier at dispatch: parity → Sonnet 5; behavior-changing → Opus 5.
  **Spikes and unstable-DAG slices are always classified `behavior-changing`**
  (always Opus 5), so the dispatch decision reads off these two fields alone.
- **Collision matrix:** every other live or queued writer, the file-set
  intersection with this slice (**including goldens and snapshots** — disjoint
  source files have collided on one golden), and the `git merge-tree` evidence.
  **Abort condition:** if your region has changed under you, STOP and report — do
  not adapt, do not merge, do not re-derive the packet.

## §2 Concurrency, stated honestly

Who else is live, in which trees, doing what — as it WILL be during this slice, not
as it is at packet-writing time. A packet that says "you are the only writer" while
two reviewers get dispatched mid-slice teaches the agent to distrust packets. If
measurements are part of acceptance, state whether the tree will be quiescent and
when.

## §3 Mission

What this slice builds and why, in the sprint's terms. Cite the ruling IDs
(`RUN-<stage>-NNN`) it implements. **Where this packet deviates from any design
doc, say so explicitly and cite the ruling that overturned the doc** — an
implementer who discovers the discrepancy themselves will (correctly) stop.

## §4 Already settled — do NOT re-derive

Numbered facts the implementer may rely on without checking, **each with the
command or derivation that proved it** (a bare assertion is not settled, it is
relayed). Implementers name this section as the thing that keeps a slice short.
Rules for the planner writing it:

- **Grep-prove every symbol and path** against `.mdk`/`.c`/`.sh` source at the
  exact cited line — docs under `compiler/` make fabricated symbols appear to
  resolve.
- **An enumeration claim states its depth.** "I enumerated the call sites" and "I
  followed each to its leaves" are different claims; the shallow one shipped a
  false property twice.
- **No relayed mechanism claims.** If it came from a report or a doc, open the file
  before it enters this section.

## §5 The transformation

- **Named sites:** file + symbol (line numbers rot; symbols survive), for every
  site the transform touches.
- **The transform itself**, stated once, precisely.
- **Callers and mirrors:** parallel structures that must move in lockstep (e.g.
  `eval/eval.mdk` vs `ir/core_ir_eval.mdk` module drivers) and every `_ =>`
  wildcard arm that could silently swallow a new constructor — audit the arm SET.
- **The one-question check:** state which question these sites collectively answer
  ("does an impl exist", "which impl wins"). If any site answering the same
  question is out of scope, the packet must say why THAT IS SAFE with a property
  the deferred site HAS — a deferral justified by awkwardness is the recorded S0
  shape, and the brain must have signed off on it. If the set is too large for one
  slice, the split goes through expand–migrate–contract (see Slice forms), never
  partial motion.
- **Rejected approaches**, with one line each on why — so the implementer doesn't
  independently rediscover and adopt one.

## §6 Acceptance — the MINIMAL set; CI verifies, the implementer generates

**Deferred-verification doctrine (v3): the implementer's verification budget is
deliberately tiny.** Local checks exist to confirm the slice isn't seriously
broken and does what it primarily claims — everything else is CI's job on the
sprint PR and the merge queue's clock. The full ceiling for a standard slice:

1. `medaka fmt --write` + `medaka lint` on touched files (the pre-commit hook
   forces these anyway; fighting it costs more than running it).
2. `make medaka` — the build itself.
3. `make check-self` (~20 s) — the cheap typecheck stand-in; the bootstrap path
   builds green on an ill-typed compiler, so this is not optional.
4. **The primary-claim probe(s):** per §5 claim, the cheapest FAIL-CAPABLE check
   — a check that cannot fail verifies nothing. Name the command and expected
   output, including expected reds.
5. **Bless what your own diff moved** — expected golden/snapshot moves listed
   here by path; re-cutting them is code-adjacent output, not verification, and
   a missed golden is a guaranteed CI red round-trip. An UNLISTED golden move is
   a finding to report, never a thing to bless.

**Named NOT-run, so nobody "helpfully" adds them:** no `make preflight`, no
`run_gates.sh` patterns, no oracle builds, no engines differential, no fixpoint,
no full or partial suites. A packet that lists a gate here needs a brain-ruled
reason recorded in §6. The two standing exceptions, both brain-gated:
- `local-fixpoint: yes` — only for slices touching `compiler/backend/*`, where a
  fixpoint break first seen in CI is too expensive to fix forward blind.
- **Golden-capture freeze:** if any §5 site sits in an area FINDINGS.md marks
  known-broken, golden/fixture CAPTURE there is deferred to after the fix — a
  golden captured against broken behavior enshrines the bug.
- **The nearest program this slice does NOT cover** — the adjacent shape a
  reviewer should probe first. Asking this question found two S0s.
- **`could move:`** what observable behavior could plausibly shift — feeds the
  DEBT.md row and gives the repair round its attack list. "Nothing, and here is
  why" is valid; silence is not.
- **The DEBT.md row** the executing agent appends has exactly five fields, none
  blank: `sites:` (the named sites actually touched), `transform:` (one line),
  `could move:` (from above), `nearest miss:` (the nearest uncovered program,
  from above), `unchecked:` (claims taken on trust / checks skipped). This is
  the row every checker checks; "nothing, and here is why" is valid in any
  field, silence is not.

## §7 Refusal license — verbatim in every packet

> Disagreements are deliverables. If contact with the source contradicts this
> packet — a premise is false, a site is missing, the transform is wrong at a leaf
> — STOP and report the finding. Do not resolve it silently, do not adapt around
> it, and do not push a diff that implements what you believe over what is
> written. A written refusal is worth more than a green gate: refusals were right
> 5 of 6 times on record and caught two S0s.
>
> You have probe budget for this: spend up to ~15 minutes converting a
> disagreement from an opinion into a measurement (a discriminating probe, a
> 5-line repro, the cells of the table). Bring the measurement, not the verdict.

## §8 Operational boilerplate — verbatim in every packet

> - Run every command in the FOREGROUND and stay in your turn until you have
>   pushed. A build is well inside the tool ceiling. Never background a build,
>   never background inside another background wrapper (the wrapper's exit code is
>   not the build's), never end your turn with anything still running.
> - Verify the binary you probe is the one you built: `MEDAKA_STRICT=1` on every
>   probe.
> - Push and report. The rear seat watches CI, not you. Do not poll CI, do not
>   send per-shard updates.
> - **Never file, edit, comment on, or close a GitHub issue.** Issue writes are
>   seat-only (the sprint-rear seat executes them, with readback). A bug you
>   find goes in your report's findings; a body you want filed goes in your
>   report as a draft. "I filed #N" in a report is a deviation-from-packet.
> - Do not spawn subagents. Do the work yourself, sequentially.
> - Stage commits BY PATH — never `git add -A`. Run `medaka fmt --write` and
>   `medaka lint` on touched files before building.
> - The pre-commit hook also runs a SNAPSHOT check on any staged `.mdk`: bless
>   only the golden/snapshot moves §6 lists (via the gate's own `--bless`),
>   `git add` the blessed files in the same commit, and run `make
>   snapshot-check` first. If §6 defers a golden re-cut to a later commit,
>   `PRECOMMIT_SNAPSHOT_DEFER=1` opts that one commit out — but a blessed
>   snapshot sitting UNSTAGED on disk still fails any later `.mdk`-staging
>   commit, so bless-and-stage LAST, after every `.mdk` commit is in.
> - Work only in your worktree at the absolute path in §1. Do not read another
>   agent's worktree.
> - If this packet authorizes any `gh` interaction: prefer `scripts/pr.sh`
>   wherever it covers the operation (it verifies resulting state; raw `gh`
>   exit codes carry no signal and write paths silently no-op). For anything
>   it does not cover, read back what you wrote and compare.
> - Write your report to the path in §9 INCREMENTALLY as you finish each part —
>   never buffer everything for a final write.

## §9 The report — same six sections for every agent, no exceptions

The packet names the report path:
`/var/tmp/medaka-sprints/<stage>/reports/<slice-id>-<role>.md`. The return message is one
verdict line + the path — the FILE is the deliverable. Required sections:

```
## Verdict
One line, then one paragraph. Packet-executing agents: LANDED | REFUSED |
BLOCKED — a family leaf writes `LANDED leaf <leaf-id> (<k>/<n>)` and the last
one `LANDED family-final`; a spike writes `SPIKE-DONE (stability: STABLE |
UNSTABLE)`. Reviewers: FINDINGS | CLEAR. Other roles use the verdict set their
own definition fixes. The orchestrator branches on this line mechanically, so
the vocabulary is closed per role — invent no values.

## Evidence
Commands run and their key output, verbatim. Every claim above traceable to a
line here. State which binary (SHA + freshness check) produced each measurement.

## Decisions surfaced
Anything you resolved, noticed, or worked around that involved a judgment call —
scope questions, spec ambiguities, surprising semantics, a design doc that seems
wrong. NONE is valid; absence is not. When in doubt, list it — the brain reading
one non-issue is cheap; a buried decision is how S0s shipped.

## Deviations from packet
Every place the executed work differs from the packet as written, however small,
including "the packet said X sites, I found X+1". For an agent dispatched on a
checklist or question rather than a packet, this section reads as deviations
from the DISPATCH BRIEF — same duty, same format. NONE is valid; absence is not.

## Not covered
What this work does NOT establish: shapes not probed, programs not run, claims
taken on trust, checks skipped and why. This section is what the repair round
reads first. NONE is almost never true.

## Friction
Anything that slowed you down, confused you, or made you unsure — a misleading
doc, a flaky command, a tool that lied, a packet section you had to read three
times, a missing helper you hand-rolled. LOG, DON'T JUDGE: you are not asked
to triage it, size it, or propose the fix — one line per item is enough, and
logging liberally is correct (a dedicated triage agent processes the sprint's
whole friction ledger at wrap-up; your job is only not to lose the data). The
ONE exception needs no judgment either: friction that BLOCKS you from
completing the packet is not friction — it is a BLOCKED verdict or a refusal,
and you act on it now through that path. NONE is valid; absence is not.
```

An agent that ends its turn without the report file on disk has not finished,
whatever its return message says.
