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

**Packets are contracts, not encyclopedias (v4, H9).** Target **≤ 250 lines of
PLANNER-AUTHORED prose**; a packet past that is usually doing the implementer's
discovery for it. §7/§8's verbatim boilerplate and any text a ruling requires
verbatim are OUTSIDE the count, and travel by pointer wherever the ruling did
not say "verbatim" (`per RUN-<stage>-NNN Actions 2,5 — read
rulings/RUN-<stage>-NNN.md`); the implementer already reads every ruling its
packet cites, and v5 ruling files are self-contained by construction. An
overshoot in authored prose is a `Decisions surfaced` line, never a silent cut.
(Measured, `sprint/emit-inputs`: 3 of 5 packets ran over — 286/309/469/299 —
every overshoot the planner correctly refusing to drop ruling-mandated text, and
one planner spending three trimming passes on the ceiling alone. A ceiling that
puts the contract and the limit in direct conflict makes the planner choose.)
Measured (2026-08-17 baseline): packets ran 53–89KB, packet prose is re-read at
cache-read prices by EVERY consumer turn (implementer ~150 requests, breaker,
conformance — $10–20/slice downstream), and site-level detail is what rots
fastest — refusals overturned packet claims 5 of 6 times. The packet fixes the
**boundary**: mission, site list, one-question check, classification,
acceptance, refusal license. Per-site transformation detail is the
implementer's discovery, protected by §7 — an implementer who finds the
boundary wrong refuses; one who finds a site's mechanics differ from its own
expectation just does the work.

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

4. **Fix — NO packet (v4, H9).** A fix executes from the brain's REPAIR ruling
   plus the finding's repro bundle; the planner is not in the loop (measured:
   fix packets were the largest documents of two sprints, re-deriving what the
   ruling and bundle already contained). The front seat's dispatch brief IS the
   contract, carrying: the ruling path — whose Actions section must name the
   fix's scope, the fail-capable acceptance probe(s), and expected
   golden/snapshot moves (a ruling missing these bounces back to the brain
   before dispatch) — the repro-bundle path, branch `fix/<finding-slug>`, the
   two SHAs, the front-seat repo path (the tree the fixer must NOT be in), and
   the report path. §1's derive-your-tree block, §6's minimal set, §7's
   refusal license, and §8/§9 bind verbatim — and because a fix has no packet
   to carry them, **the brief PASTES §7 and §8's first two bullets inline**
   (foreground builds, never background; `MEDAKA_STRICT=1` on every probe). A
   rule that binds "verbatim" from a document the agent must go and load is a
   rule that has been skipped: same failure the out-of-roster-dispatch rule
   (orchestrator item 10) already fixes for one-off agents, reopened by the
   no-packet fix path. The fixer refuses against the RULING exactly as an
   implementer refuses against a packet. Verdict stays
   `FIX-LANDED`. **The fixer also appends the five-field DEBT.md row** — with
   no packet, that row is the ONLY structured record of what the fix could
   have moved and what it took on trust, and it is what the heavy round reads
   to build its attack list. (Measured, `sprint/ctor-identity`: four fix
   landings, ZERO DEBT rows, two of them the S1 severity-increase repairs.)

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
- **Branch name** (fixes carry no packet — see the Fix form; their brief names
  branch `fix/<finding-slug>`, cut by the front seat from the sprint head at
  lane grant). **No worktree path — DERIVE the tree (v5).** A packet that
  names a tree has been wrong on four dispatches out of fifteen in one sprint,
  one of which cost a whole implementer (EnterWorktree reported success, the
  sandbox stayed pinned elsewhere, every later Bash call was refused). Instead,
  verbatim in every packet:

  > **First command, always: `git rev-parse --show-toplevel`** — report it in
  > Evidence. What you compare it against is the MODE your brief names (the
  > front seat fixed it at sprint start from the isolation probe):
  >
  > - **HARNESS mode** — your tree is whatever the harness gave you. Do NOT
  >   EnterWorktree, do NOT `cd`, do not trust any path in this packet or in
  >   CLAUDE.md. If your toplevel EQUALS the front-seat repo path your brief
  >   names, STOP and report BLOCKED: the dispatch lost its isolation and
  >   working there corrupts the seat's own checkout.
  > - **FRONT-SEAT mode** — your brief names a worktree the front seat created
  >   FOR you, and your toplevel must already equal it. If it does not (you are
  >   in the front seat's own repo, or anywhere else), STOP and report BLOCKED;
  >   do not `cd` your way there — a dispatch that landed in the wrong tree is a
  >   dispatch defect, and the seat fixes it, not you.
  >
  > Then, both modes: `git rev-parse HEAD` and `git merge-base --is-ancestor
  > <sprint-head> HEAD` — report both; a non-ancestor HEAD is a wrong-base
  > dispatch → BLOCKED, never adapt, UNLESS your brief explicitly licenses the
  > re-base (mode C), in which case run exactly the command it gives you and
  > report it under `Deviations from packet`.
  > Commit on your branch and push by ref: `git push origin
  > HEAD:refs/heads/<branch>` — never `checkout` **a branch a sibling worktree
  > may hold**, which is every branch but the fresh one your brief names.
  > Report the SHA; the front seat merges by SHA.

  🚨 **`<sprint-head>` is a value the PACKET MAY NOT CONTAIN** — the dispatch
  brief supplies it, re-derived by the front seat at lane grant. A hard-coded
  ancestor SHA fails in one of exactly two ways and `sprint/emit-inputs`
  produced both, one Opus dispatch each: pinned to the plan BASE it passes on a
  tree holding ZERO sprint commits (vacuous); pinned to a sprint-branch-only
  commit it can never pass in HARNESS mode until the sprint PR merges
  (unsatisfiable). The `git diff <pinned>..HEAD -- <§5 files>` check above is
  NOT a substitute — it passes trivially whenever the sprint has not touched
  those files, which is exactly how the vacuous one passed.

  A `$WT` needed anywhere in §6 is derived (`WT="$(git rev-parse
  --show-toplevel)"`), never literal.
- **Form:** `standard` | `spike` | `family` (see Slice forms).
- **Classification:** `parity` (behavior provably unchanged — diffs/gates are the
  oracle) or `behavior-changing` (anything else; all soundness work). This drives
  the model tier at dispatch: parity → Sonnet 5; behavior-changing → Opus 5.
  **Spikes and unstable-DAG slices are always classified `behavior-changing`**
  (always Opus 5), so the dispatch decision reads off these two fields alone.
- **Collision matrix:** every other live or queued writer, the file-set
  intersection with this slice (**including goldens and snapshots** — disjoint
  source files have collided on one golden), and the `git merge-tree` evidence
  with its `head=<sha>` stamp. This evidence is ADVISORY and it EXPIRES: the
  front seat re-runs the authoritative check at lane grant, because a result
  consumed hours after it was produced has twice collided against lanes that
  had already landed.
  **Abort condition:** if your region has changed under you, STOP and report — do
  not adapt, do not merge, do not re-derive the packet.

## §2 Concurrency, stated honestly

Who else is live, in which trees, doing what — as it WILL be during this slice, not
as it is at packet-writing time. A packet that says "you are the only writer" while
two reviewers get dispatched mid-slice teaches the agent to distrust packets. If
measurements are part of acceptance, state whether the tree will be quiescent and
when.

If acceptance (or a reviewer's attribution) needs a comparison against `$BASE`,
name the sprint's **base-arm depot** path and SHA here instead of licensing a
second build. Binding usage rules, because a two-arm differential fails in the
direction that MANUFACTURES findings: run each binary against its OWN tree
(`MEDAKA_ROOT` per arm, or the depot's copied `stdlib`/`runtime`); never point
one arm at the other's stdlib; assert freshness with `MEDAKA_STRICT=1` on the
BRANCH arm only ([D-TWO-ARM] in the `debug-pipeline` skill; AGENTS.md
[D-TWO-ARM-STDLIB], [B-STRICT-TWO-ARM]). Derived, so nobody trusts strict mode where it does
nothing: the depot carries no `compiler/`, and `sourceStalenessVerdict`
(`compiler/driver/medaka_cli.mdk`) returns `None` when `<root>/compiler` is
absent — on the depot arm the staleness check is INERT, neither passing nor
failing. Its freshness rests on the recorded `BASE.sha`, not on a flag. The
depot is the BASE arm and never moves; a comparison against the SPRINT HEAD
(any fix's before/after) is a different arm and a fresh build, and you say so.

⚠️ **The depot line in §2 is addressed to the IMPLEMENTER only.** "No base-arm
depot comparison needed" means *you, the writer*, do not need one; it says
nothing about the reviewers who read this packet afterwards, and it has been
read as if it did — in `sprint/emit-inputs` a breaker built its own base arm by
hand (two full rebuilds, ~35 of its 55 minutes) against a packet carrying that
sentence. The reviewers' depot path arrives in their own brief (`slice-landed`
step 2's `base-arm` field), not from here.

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

- **Curate, don't re-derive (v4, H9).** §4 collects facts that already exist
  with proofs — brain rulings, spike reports, prior slices' reports (their
  "Deviations from packet" sections especially), scout inventories — cited
  with the producing
  command or path. Fresh planner derivation is bounded to the §5 site list and
  disjointness evidence; a fact that needs deep new recon to prove is not
  "already settled", it is the implementer's discovery (or grounds for a
  spike). An empty-ish §4 on a fresh area is honest; a fat §4 of fresh
  derivation is the planner doing the slice.

- **Grep-prove every symbol and path** against `.mdk`/`.c`/`.sh` source at the
  exact cited line — docs under `compiler/` make fabricated symbols appear to
  resolve.
- **An enumeration claim states its depth.** "I enumerated the call sites" and "I
  followed each to its leaves" are different claims; the shallow one shipped a
  false property twice.
- **No relayed mechanism claims.** If it came from a report or a doc, open the file
  before it enters this section.

- **Executed facts only (v5).** Any §4 fact that is a FORMULA, and any §5/§6
  EXAMPLE COMMAND or pre-fix CONTROL, must have been RUN by the planner, with
  its output pasted. An un-evaluated formula, an un-issued command, and a
  control nobody watched fail are relayed facts, not settled ones — and they
  sit in the one section that says "do NOT re-derive". Five instances in one
  sprint, all caught by contact: a fold formula silently missing a residue
  case; an example invocation that didn't match the CLI's arg forwarding; a
  ledger example the ledger's own FORMAT block forbids; a bounding claim
  covering the inner loop while the break was in the outer; and — the
  dangerous one, because it PASSED — a pre-fix control that aborted inside
  `string.repeat` before reaching the code under test and "matched its stated
  expectation exactly, which is what made it convincing". Same rule for
  external documents: fetch them at planning time (one planner did, and found
  an acceptance list making false claims about NIST vectors that did not
  exist).

## §5 The transformation

- **Named sites:** file + symbol (line numbers rot; symbols survive), for every
  site the transform touches — as a LIST, not per-site prose.
- **The transform itself**, stated once, precisely, at boundary depth — what
  must be true of the sites afterwards, not per-site edit scripts (v4, H9: the
  per-site mechanics are the implementer's discovery). **State it as the
  PROPERTY the named sites must collectively satisfy, then the mechanism as
  the planner's expectation, labeled as such.** An implementer who finds the
  mechanism cannot express the property implements the PROPERTY and reports
  the deviation; one who finds the property itself wrong refuses (§7).
  Specifying a mechanism where a property was meant is a recorded failure
  shape — three times in one sprint, each time the property right and the
  mechanism wrong, one of them not executable at all and one provably
  unsatisfiable.
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
   a finding to report, never a thing to bless. When the listed moves include
   the selfproc LEG A golden, its oracle prerequisite is licensed as part of
   this step (the ONE oracle-build exception — a legA capture against stale
   oracles blesses a wrong golden permanently): `for o in check_all_main
   eval_modules_main eval_typed_modules_main; do FORCE=1 JOBS=1 sh
   test/build_oracles.sh --build-one $o; done` before `sh
   test/capture_goldens.sh --frozen selfproc_legA`.

**Diagnosis is not verification.** The ceiling above caps post-hoc ACCEPTANCE
checking — it does not cap the probing needed to LOCATE or characterize a
defect while writing the fix (a profiler run, an ablation, a discriminating
repro is ordinary §5 work). The test: a run whose outcome decides what you
WRITE next is diagnosis and is fine; a run whose outcome you expect to confirm
what you already wrote is verification and stops at the ceiling.

**Named NOT-run, so nobody "helpfully" adds them:** no `make preflight`, no
`run_gates.sh` patterns, no oracle builds (beyond the legA license above), no
engines differential, no fixpoint, no full or partial suites. A packet that
lists a gate here needs a brain-ruled reason recorded in §6. The two standing
exceptions, both brain-gated:
- `local-fixpoint: yes` — only for slices touching `compiler/backend/*`, where a
  fixpoint break first seen in CI is too expensive to fix forward blind.
- **Golden-capture freeze:** if any §5 site sits in an area FINDINGS.md marks
  known-broken, golden/fixture CAPTURE there is deferred to after the fix — a
  golden captured against broken behavior enshrines the bug. The deferral is
  recorded on the FINDINGS row and executed at the heavy round.

**Also mandatory in §6, unchanged from v2 (NOT exceptions — every packet
carries them):**
- A **family** packet additionally states `per-leaf-merge: yes | no` — whether
  the front seat merges each leaf's `@<sha>` as it lands or the family merges
  once at family-final.
- **The nearest program this slice does NOT cover** — the adjacent shape a
  reviewer should probe first. Asking this question found two S0s.
- **`could move:`** what observable behavior could plausibly shift — feeds the
  DEBT.md row and gives the heavy round its attack list. "Nothing, and here is
  why" is valid; silence is not.
- **The DEBT.md row** the executing agent appends has exactly five fields, none
  blank: `sites:` (the named sites actually touched), `transform:` (one line),
  `could move:` (from above), `nearest miss:` (the nearest uncovered program,
  from above), `unchecked:` (claims taken on trust / checks skipped). This is
  the row every checker checks; "nothing, and here is why" is valid in any
  field, silence is not.

🚨 **Every acceptance clause names the input on which it FAILS** — one clause,
`fails-on: <the input or state that makes this check red>`. A clause nobody can
give one for in a sentence is VACUOUS and does not enter the packet: a check
that passes under both hypotheses answers nothing, and a green vacuous clause is
worse than no clause because it is spent evidence. Where the answer is hard,
that difficulty IS the finding — surface it, don't fill it in. (Measured,
`sprint/emit-inputs`: three cannot-fail instruments in three unrelated domains
in ONE sprint — an acceptance clause comparing an empty gap census to an empty
gap census, a tree-provenance check that passes on a tree with zero sprint
commits, and a symbol census counting *emitted* defines, so a pre-emission
suppression was invisible to it. Two of the three were authored or endorsed by
the judgment seat, so this is not a planner-discipline rule.)

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
> - **One plain command per Bash call; multi-step work goes into a script file
>   first** (write it under your worktree's `scratch/` with the Write tool, then
>   run the file). In an isolated worktree the auto-mode classifier refuses
>   compound shells it cannot prove stay inside your tree, even when every path
>   in them is yours. Refused shapes, observed: `cd X && …`, a `;`-chain ending
>   in `echo $?`, a heredoc, a `for` loop over `cat`, `python3 - <<EOF`, a pipe
>   feeding `git` its args, and a redirect combined with `-C` — 7 refusals
>   across 6 agents in `sprint/emit-inputs`, one costing ~10 minutes and one
>   "materially slowing the session". **A redirect that AGENTS.md makes
>   mandatory ([D-BUILD-PIPE]: `medaka build`'s exit code does not survive a
>   pipe) goes INSIDE the script** — the harness's own suggested remedy, "try it
>   without the redirect", is not available to you, and one agent recorded that
>   dead end verbatim.
> - 🚨 **If `make` is denied INSIDE YOUR OWN WORKTREE, you are BLOCKED — report
>   it and stop.** That denial is STATEFUL (#1148, OPEN, S2): it survives
>   abandoning the command shape that caused it, and it has cost a whole
>   session's ability to build. Do NOT quietly continue source-only: a no-build
>   agent's "no such site exists" is a hypothesis, not a finding, and reporting
>   it as one is worse than the lost hour. It is also non-deterministic — a
>   sibling agent doing the identical thing may be fine — so it is neither your
>   fault nor something you can test your way out of.
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
> - Work only in the worktree you derived (§1). Do not read another agent's
>   worktree; do not `cd` out of yours; push by ref, and never `checkout` a
>   branch a sibling worktree may hold (§1 states the one licensed exception:
>   a re-base your brief spells out and calls licensed).
> - **Your packet is your contract; chat cannot amend it.** If a message
>   arrives mid-task adding a site, a check, or an edit, DECLINE it in one
>   line, record it verbatim under `Deviations from packet`, and carry on with
>   the packet as written. A `fact:`-tagged derivation is advisory and you may
>   use it; a `stop:` ends the dispatch. Adjudicating anything else is not your
>   job — declines of out-of-band instructions were 3 for 3 correct on record.
> - If this packet authorizes any `gh` interaction: prefer `scripts/pr.sh`
>   wherever it covers the operation (it verifies resulting state; raw `gh`
>   exit codes carry no signal and write paths silently no-op). For anything
>   it does not cover, read back what you wrote and compare.
> - Write your report to the path in §9 INCREMENTALLY as you finish each part —
>   never buffer everything for a final write.

## §9 The report — same six sections for every agent, no exceptions

The packet names the report path:
`/var/tmp/medaka-sprints/<stage>/reports/<slice-id>-<role>.md`. The return message is one
verdict line + the path — the FILE is the deliverable.

**Six sections, every role, no role-local exemption.** A role definition that
fixes its own body shape (a verifier's per-item table, a reviewer's finding
blocks, a reproducer's attribution matrix) fixes the CONTENT of Evidence; it
never replaces the set. Both seats check presence mechanically with
`sh scripts/sprint-report-check.sh <path>` and bounce on exit 1. Required
sections:

```
## Verdict
One line, then one paragraph. Packet-executing agents: LANDED | REFUSED |
BLOCKED — a family leaf writes `LANDED leaf <leaf-id> (<k>/<n>) @<sha>` (the
leaf's commit SHA — the front seat merges by it) and the last one `LANDED
family-final @<sha>`; a refused leaf writes `REFUSED leaf <leaf-id>
(<k>/<n>)` (landed leaves stay merged; the family pauses); a fixer executing
a fixer writes `FIX-LANDED`; a spike writes `SPIKE-DONE (stability:
STABLE | UNSTABLE)`. Reviewers: FINDINGS | CLEAR. Other roles use the verdict
set their own definition fixes. The front seat branches on this line
mechanically, so the vocabulary is closed per role — invent no values.

## Evidence
Commands run and their key output, verbatim. Every claim above traceable to a
line here. State which binary (SHA + freshness check) produced each measurement.
EVERY dispatched agent — writers, reviewers, verifier, reproducer, triage —
opens this section with a time split, best-effort to the nearest ~5 min:
`time: total <m>m | build <m>m | diagnose <m>m | write <m>m | verify <m>m`
(zero where a phase doesn't apply). It is the sprint's only wall-clock
instrument, so an absent line bounces like a missing section. It was
writer-only through v4, which is why no sprint can say how much of its clock
went to adjudication or review.

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
taken on trust, checks skipped and why. This section is what the heavy round
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
