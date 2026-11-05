# Sprint skills — the incidents behind the rules

The sprint skills (`sprint-plan`, `sprint-orchestrator`, `sprint-packet`) keep each rule and at
most a clause of why. The incident that produced the rule lives here, under the skill and the
rule's opening words, so a reader who wants to know why a rule is shaped the way it is can find
out without every session paying for the story. A retro that adds a rule adds its story here
(`.claude/agents/sprint-retro.md`).

## sprint-orchestrator

**Pre-dispatch freshness check.** `prelude-shadow-build-agreement` measured the elective case: a
pre-fix-round resync that cost a rebuild and a re-bless and prevented nothing, since the branch
was `CONFLICTING` at land anyway. The check is still worth its two commands: it is what let
`comment-register` discover mid-sprint that a sibling sprint had shipped the same census tool,
and drop a doomed slice before the review round.

**Merge trigger: a formatter, linter or accepted-syntax change landed.** One sprint ate
"stale-binary fmt drift across ~480 files" from the tree-wide reformat.

**Resync with the script, never by hand.** Three orchestrator git slips came from hand-running
that sequence: a bare merge pushed without its blessed goldens, a `git checkout <stale-sha> --`
over an already-verified bless (costing a full rebuild+rebless+preflight redo), and a merge into
the wrong branch.

**Parallel writers, serial by default.** selector-identity's throughput was killed by process,
not by serialization.

**Read the unnarrowed CI run.** One sprint dispatched three slices over a standing red nobody
read for ~3h.

**Reviewer and style briefs: never `git checkout` elsewhere.** A style pass that checked a SHA
out in the orchestrator's worktree detached its HEAD and broke the fix-round build.

**The style pass declines "move X beside Y" demands.** The pass never builds and cannot see the
import cycle that sank two of six such refactors in Phase 1 sprint 7.

**A one-line fix a previous fixer already located does not get its own dispatch.** A dispatch is
a worktree mint, a cold build, a gate run and a report, measured at 18–36 min against ~10 min for
an orchestrator-direct fix. This was the fix round's most-repeated waste: nine sprints spun a full
cycle for a change the prior packet's own report had already named and located (a missing
`-c user.name=`, an identical one-line grep pattern in a fourth script, a golden re-bless, a
one-line mirror), and one such chain burned 1h10 for a ~10-minute packet.

## sprint-packet

**The slice branch name is unique per slice and per re-dispatch.** Worktrees share one `.git`,
and a fixed name like `slice-work` collides with any other session's worktree that holds it,
which BLOCKED the first dispatch of a sprint. The branch exists at all so the checkout does not
leave the implementer on a detached HEAD, where a later commit lands on a dangling line and
strands: `.claude/ORCHESTRATING.md` records two verified phases lost that way, recoverable only
via `git reflog`.

**The checkout moves to the sprint base; it does not merge `main`.** The former
`merge --ff-only <base>` form failed whenever `main` moved, regardless of whether anything
relevant had changed, and cost a dozen recorded dispatches (worktree mint plus a refusal
write-up) on docs-only, CI-only and stdlib-only landings.

**Waiting: no hand-rolled `pgrep -f` loop.** `pgrep -f` matches the loop's own wrapper shell, so
the loop never ends; three agents in param-clump-sweep left such loops running for 17 to 25
hours. Tool fix: #4881 (hook: deny self-matching pgrep -f wait loops).

**Bless the edited files' snapshots from `make snapshot-check`.** param-clump-sweep FIX-3
hand-listed five snapshots and missed the sixth, `medaka_cli`.

**Verdict identity, not text identity, for a rejected program.** Phase 1's sprint 8 lost a fix
round to a packet that demanded byte equality at `4:12` where the drive now reports at `4:0`.

**The two standing checks outside the ceiling.** `medaka test <touched compiler directory>`:
Phase 1 sprint 6 had two in-language test reds in `compiler/types` found only at the queue. The
gate-registry pair: sprint 7 had two ledger reds found only by the unnarrowed run.

**The two compiler gates preflight does not derive.** vis-test-split S-sinks-public items 5 and
18, and R35 migration's `lint_baseline` red. Tool fix: #4819 (preflight does not derive
diff_compiler_lint_baseline or typecheck_compiler_source).

**Do not enumerate the gates the diff might have moved.** That list does not converge: across the
sprint record the unnamed gate was a snapshot/LEG-A bless ten times, `registry_keying_ratchet.sh`
six, `selfcompile_fixpoint` three, `docs-index`/`docs-links` four, plus lextok, doctest goldens
and cross-backend parity, and the reminders that were added for the first three were still
omitted in five later sprints apiece.

**The LEG A pure-signature-change exception.** `selector-identity-2` hit this literally: slice
2's 3-row signature-change diff had no way to satisfy the literal "additive-only" wording,
forcing the reviewer to waive it by judgment call instead of by rule.

**A refusal that generalizes must carry a probe you ran.** One sprint refused all twelve sites on
a false premise about the language, and four minutes with an eight-line probe refuted it. The
identical model on the identical sites landed all twelve once the packet carried that
measurement, so the standing escalate-after-two-rounds rule would have been the wrong remedy: the
defect was not capability. `archive/design/JEV-LEDGER.md` section 1.1 rule 4; the episode is
`archive/design/JEV-DESIGN.md` section 8.3. It is a single episode, N = 1; what carries the rule
is the asymmetry (a wrong edit is caught by a gate, a refusal by nothing), not the count.

## sprint-plan

**Check each candidate's state before it enters the pool.** When a backlog was last re-derived,
SIX entries were already fixed, including two billed as top-value.

**Split a decision from its mechanics.** Phase 1's largest opus reports (22–26 KB) were mostly
the mechanical tail written up at opus prices; the decision each contained fit in a page.

**A relayed premise is not a fact; every invariant and Out row carries its proof.** Phase 1 lost
three opus rounds to relayed claims (a hover context that lived in a frozen file, "gate drive =
pair drive", "no program depends on it"); every one was refutable with one `grep` at cut time.
R35's F3 contract said "at most one sibling pair per drive" against the design and cost a full
opus redesign; vis-test-split scoped a probe section out on a relayed "`tc_module` reads them"
(the reader was `tc_module_test`), which is why #4767 exists.

**A deletion names its victim.** Every drive Phase 1 removed had been the only judge of something
(sprint 1 F1, sprint 7 F1, sprint 8 F1, an S0 miscompile that passed 2,761 differential cases and
an unnarrowed CI).

**A semantics-changing slice is gated by rule, not by an approved list.** Phase 2 stage 6e's
lexical-location slice was refused twice (102 rows, then 1) for list completeness alone, and the
188 rows were approved by class in the end anyway.
