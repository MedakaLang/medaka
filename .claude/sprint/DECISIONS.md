# Stage A sprint — DECISIONS ledger

**Append-only.** Architecture companions and the Phase 0 fan-out write here; every agent reads
here **before** asking anyone anything.

**Every entry carries its derivation, not just its conclusion.** An entry that states a fact
without showing how it was derived (a command run, a file:line read, a probe executed) gets
bounced by the referee. This tree has a long history of ledger prose that was ungated and wrong.

Entry format:

```
## <id> — <unit> — <one-line ruling>
question:   <what was asked>
ruling:     <the decision>
derivation: <the command(s) run / file:line read / probe executed that establish it>
scope:      <what this ruling does and does not cover>
```

---

## RUN-000 — sprint setup — scope re-derived from the tracker, 2026-08-12

question:   Is §1's in-scope table still accurate? The doc says issue state moves — re-derive.
ruling:     Every in-scope node is still live. Scope stands as written, no amendment.
derivation: `gh issue list --state all --limit 200 --json number,state,title` plus individual
            `gh issue view` for #991/#1111/#1112. Observed states:
            OPEN — #1512, #1593, #1557, #1558, #1559, #1354, #1276, #1351, #1319, #991,
                   #1111, #1112.
            CLOSED — #1446 (A-2 tail atom), consistent with §1's "A-2's spine is already done".
            #1110 did not appear in the 200-issue window; #1111/#1112 confirmed OPEN as shells.
scope:      Confirms node liveness only. Does NOT confirm #991's *content* is still live work
            (§1 flags it as "bundled with #1446, which closed without it") — that is a Phase 0
            deliverable, not established here.

## RUN-001 — sprint setup — sole occupancy confirmed

question:   Is any other session or scheduled agent pointed at this tree?
ruling:     No. Sole occupancy holds; §7's precondition for Phase 0 is met.
derivation: `git worktree list` → exactly 2 (main checkout + this trunk, both at 7aae8b83).
            `ListAgents` → 2 peer sessions, both Remote Control, one offline one idle, neither
            in this repo. `ps -eo pid,etime,args` → one `claude -w`, no `make`/`medaka`/gate
            processes.
scope:      Point-in-time. Re-check before any later phase that assumes exclusive access to
            `compiler/types/typecheck.mdk`.

## RUN-002 — sprint setup — trunk identity

question:   What is the trunk, and what base does everything diff against?
ruling:     Worktree `/root/medaka/.claude/worktrees/wiggly-giggling-nygaard`, branch
            `arch/stage-a-sprint`, BASE pinned at `7aae8b83e8b2f7aeef1132b7af0c8b4db784f3f1`.
derivation: `git checkout -b arch/stage-a-sprint`; `git rev-parse HEAD`. Base is pinned as a
            SHA, not as `origin/main` — all worktrees share one `.git`, so a sibling's fetch
            moves `origin/main` under us with no signal.
scope:      All implementers edit in this worktree with absolute paths. No per-implementer
            worktrees exist; none will be created (§4 region discipline).

## RUN-003 — sprint-wide — 🚨 THE TRACKER LAGS THE TREE; Phase 0 re-shaped around it

question:   §1 says "derive from the tracker, not from the epic's table." Is the tracker itself
            a sound basis for the scope table?
ruling:     **No.** The merged tree has moved substantially past issue state, in this arc, within
            the last 48 hours. Every Phase 0 brief was amended to make "derive your unit's ACTUAL
            residue FROM THE TREE" step 1, with "already done" declared a first-class finding.
            `test/registry_keying_ratchet.sh` is designated the primary tree-side ledger.
derivation: `gh pr list --state merged --limit 25 --json number,title,mergedAt`. Merged
            2026-08-11/12, all in this arc:
              #1553 "A-3.2b: retire the overlay pool onto stage K — the first cross_allowed
                     shrink (issue 1512, part of issue 1319 unit 4)"
              #1567 "#1112 A-3.4 PR2: the IE reader flip — cross_allowed 31 → 28"
              #1588 "retire universeAliasTable onto stage K (#1512 A-3.2b residual 1/3)"
              #1590 "A-3.2b slices 2+3 — retire universeDataParamKinds + universeFieldOwners (#1512)"
              #1592 "A-3.5c — CE-only decl-time checks relocated, retires universeIfaceParamKinds
                     (#1557)"
            Decisive instance: **#1592 landed work for #1557 while #1557 is still OPEN** — so
            issue state cannot distinguish "owed" from "landed" here. Corroborated by
            `test/registry_keying_ratchet.sh`'s `declEnvsRef` row, which states in the tree
            itself: *"A-3.5a (universeIfaceRequiredRef) and A-3.5b remain owed"* and
            *"LIVE SINCE A-3.4 PR2"* — neither fact is recoverable from the issues.
scope:      Changes HOW scope is derived, not (yet) what the scope IS. Concrete re-scoping is a
            Phase 0 deliverable, pending the fan-out. Two candidate collapses are flagged to
            agents as questions, NOT asserted here: (a) #1512's remaining work may now live
            entirely in #1593; (b) A-3.4 may be complete via #1510 + #1567.
            ⚠️ This ruling does NOT license trusting the ratchet either — see RUN-004.

## RUN-004 — sprint-wide — the tree-side ledger is UNGATED PROSE and has already lied

question:   If the ratchet is the primary ledger, how far can it be trusted?
ruling:     Cite it, never trust it. **Every symbol named from it must be grepped before use.**
            This instruction is in all seven Phase 0 briefs; it carries into every implementer
            brief for the rest of the run.
derivation: The `declEnvsRef` row of `test/registry_keying_ratchet.sh` contains a block addressed
            to "A-3.6 IMPLEMENTER" stating that an earlier draft of that same row named
            `declEnvSeedRows` and an own-row test `m.demOrd == cur`, and that **both were
            fabrications** — neither exists in the tree. The row also derives WHY nothing caught
            it: `check_agent_doc_symbols.sh` scans `AGENTS.md`, `.claude/**` and `docs/spec/*.md`
            but **not `test/*.sh`**, so the file this arc hands off through is exactly the one its
            symbol police cannot see. Filed as #1574; do not re-file.
scope:      P0-F is tasked with grepping every symbol the `declEnvsRef` and `deImpls` rows name
            and reporting the non-existent ones, as a direct contribution to #1574.
            P0-C (A-3.6) was warned explicitly that its unit is where the fabrications occurred.

## RUN-005 — Phase 0 / Fable consult — C4/I2 survives this cut: **YES-BUT**, and A-3.6 carries it alone

question:   Does this sprint's cut still deliver A-3's headline claim — C4/I2 BY CONSTRUCTION?
            (The epic states that claim rides entirely on A-3b.)
ruling:     **YES-BUT.** The cut delivers C4/I2 by construction, Module-path-scoped as the epic
            itself scopes it — but only under a precise statement, and **A-3.6 is load-bearing
            for the entire claim.** Full argument: `.claude/sprint/phase0/P0-FABLE-c4i2.md`.
derivation: RELAYED from the Fable consult, which labels its own claims DERIVED and cites:
            - C4 = *"Single instance environment. `IE`/`CE` are GLOBAL after import resolution…
              Two modules resolving the same predicate must consult the same instance set and
              produce the same evidence"* — `DICT-SEMANTICS.md:1312`.
            - I2 = *"…assembled across the whole import graph before entailment runs… Import
              scoping affects VISIBILITY of names, not the IDENTITY of the evidence"* — `:1881`.
            - The ordinal filter is **alive today**: `declEnvVisibleAt cur entryOrd = entryOrd <= cur`
              (`compiler/types/typecheck.mdk:2835`), applied to IE by `ieSnapAt` (`:4080-4084`).
            ⚠️ These file:line citations are RELAYED and NOT independently re-derived by the
            orchestrator. P0-C and P0-F are deriving the same predicate's reader set
            independently; treat a disagreement between them as a finding, per RUN-004.
ruling detail:
            1. **After A-3.4 the tree has global STORAGE with PREFIX-PROJECTED reads.** C4/I2 is
               therefore *not yet true*. It becomes true at exactly the deletion of
               `declEnvVisibleAt`'s body — with publicity separably migrating to R per §3 L7,
               which **is** I2's visibility clause, not a leak in it.
            2. **A-3.5c's cycle-walk re-key is diagnostic-only** — it cannot reach candidacy, so
               it does not compromise the claim. (This retires the worry that a landed acceptance
               delta had already eroded it.)
            3. **The bare compatibility leg is the crux but does NOT defeat C4/I2.** The bare
               bucket is still one global, site-uniform environment, and uniform wrongness
               satisfies C4's sentence. What it violates is **identity — I4/P1's clause** —
               pinned by #1438 (fixture 1514), drained by #1482/#1507, not by this run.
scope:      🚨 **REPORTING CONSTRAINT, binding on the sprint's final report and on any PR body:**
            the delivered claim must read *"C4/I2 by construction, modulo the inherited #1438
            collapse on the bare leg."* Stating "IE is identity-keyed" unqualified **over-claims**,
            and doing so would repeat the #1354 partial-identity mistake the epic's own honesty
            clause names — a claim that reads as DONE from any single table.
            If A-3.6 slips out of the cut, **nothing else restores the claim**: A-3.4 + A-3.5 alone
            is machinery without guarantee.

## RUN-006 — verification posture — A-3.6 gets an IN-RUN checkpoint, amending §5

question:   §5 defers all gate-level verification to the testing round. Does that hold for A-3.6?
ruling:     **Amended — one narrow exception, adopted.** At the END of A-3.6, run
            `test/must_fail_fixtures/1072-overlap-xmod-bare-head-arm-order` as an in-run
            checkpoint. Additionally, A-3.6's bite list **must author** the R2
            "could-not-pass-before" fixture, even if it is only executed in the testing round.
derivation: Recommended by the Fable consult on the following argument, which the orchestrator
            adopts: the pin is the **cheapest falsifier of the run's headline claim** — after
            A-3.6, `main.mdk` must flip to `specific` (with the control staying `specific`); if it
            does not, the "site's module didn't see the other impl" state is still expressible and
            the claim is false. There is an even cheaper structural pre-check:
            `grep 'entryOrd <= cur'` still matching means the filter survived.
            §8 I5 records that classes (1)/(2)/(4) are unpinned in either direction, and class (3)
            is **exactly the silent-answer-change the deferred-verification posture is blind to**.
scope:      This does NOT reopen §5 generally, and it **blesses nothing** — it is one `sh` run over
            an existing fixture, and a `grep`. Goldens remain frozen for the whole run (§5 stands).
            The exception is justified because the deferred posture is structurally blind to
            precisely this failure, and because a false claim discovered in the testing round costs
            the entire A-3b chain rather than one unit.
            ⚠️ Note the direction: this pin flipping is a **PASS signal for A-3.6**, distinct from
            the pins in RUN/HANDOFF's expected-red table, which flip red as S0s drain. Do not
            conflate the two when reading a red must-fail run.

## RUN-007 — orchestrator — RUN-005/006's load-bearing facts independently DERIVED, not relayed

question:   RUN-005 rests on citations the orchestrator had only RELAYED. Do they hold?
ruling:     **All four hold, now DERIVED first-hand.** RUN-005/006 may be relied on.
derivation: Run by the orchestrator in the trunk, `git rev-parse HEAD` = `3a7cc7b7`:
            - `grep -n 'entryOrd <= cur' compiler/types/typecheck.mdk`
              → `2835:declEnvVisibleAt cur entryOrd = entryOrd <= cur`. The ordinal filter is
              LIVE, at the cited line. ✅
            - `2910-2911: declEnvVisibleTo cur entryOrd entryIsPublic = declEnvVisibleAt cur entryOrd`
              `&& (entryOrd == cur || entryIsPublic)` — confirms the TWO SEPARABLE CONJUNCTS the
              ratchet asserts, and that A-3.6 must take only the first. ✅
            - `4083: | declEnvVisibleAt cur o = ieSnapAt cur rest u` — the filter is applied to IE
              at the cited site. ✅
            - `ls -d test/must_fail_fixtures/1072*` → `1072-overlap-xmod-bare-head-arm-order`
              exists, so RUN-006's checkpoint is runnable as specified. ✅
scope:      ⚠️ **One divergence from the ratchet's prose surfaced while deriving this, and it runs
            in the direction that costs A-3.6 work, not saves it.** The ratchet says
            `declEnvVisibleAt` has THREE production readers. `grep -n declEnvVisibleAt` returns
            ~30 hits, and while most are commentary, the apparent CODE sites are at least FIVE:
            `2874` (`declEnvsUpToGo`), `2910` (`declEnvVisibleTo`), `4083` (`ieSnapAt`),
            `4461`, `4482`. **DO NOT treat five as the answer either** — the orchestrator did not
            separate code from comment rigorously, and P0-C and P0-F are each deriving this set
            independently. This entry records only that **three is too low**, which is the finding
            that matters: A-3.6 is specified as "delete one body and fix up its readers," so an
            undercounted reader set is an undercounted unit.
            📌 Secondary, and useful to every later agent: **`compiler/types/typecheck.mdk` itself
            carries far richer A-3.6 commentary than the ratchet does** (e.g. `:2678` — the
            deletion is *"`declEnvVisibleAt`, and nothing else"*; `:2891`, `:2987`, `:3496`,
            `:4049`, `:4457`). The source is IN the symbol-gated corpus; the ratchet is not
            (RUN-004). **Prefer the source as the ledger of record for this arc.**

## RUN-008 — A-3.6 — 🚨 ESCALATED TO OWNER: "delete one predicate body" is FIVE semantics changes

question:   The arc states in ~8 places that A-3.6 is the deletion of `declEnvVisibleAt`'s body,
            *"and nothing else"* (`typecheck.mdk:2678`). Is that a single change?
ruling:     **NO — escalated, NOT ruled by the orchestrator.** One body deletion applies an
            **instance-candidacy licence to four NAME-scoping tables**, and one of the five
            resulting deltas is an acceptance **NARROWING** that the tree's own rules say cannot
            be licensed. This is an arc-design question with an owner, not a bite.
derivation: RELAYED from P0-C (`.claude/sprint/phase0/P0-C-A36.md`), with both load-bearing
            citations **independently re-derived by the orchestrator** at HEAD `3a7cc7b7`:
            1. `docs/spec/DICT-SEMANTICS.md:2025-2033` — verified verbatim. I5's price is bounded
               to instances by an explicit 🚨 boundary clause: *"I5 does NOT extend that price to
               NAMES… This paragraph has been read as licence for any graph-global name-set
               predicate, WHICH IT IS NOT: I5's subject is `match(IE, C τ̄)`."* The spec
               anticipates and forbids the exact reading a naive A-3.6 would take.
            2. `compiler/types/typecheck.mdk:2902-2908` — verified verbatim, and it is **MEASURED
               on this tree, not argued**: an unfiltered whole-graph field-owner population
               *"turns a program that compiles into `T-AMBIGUOUS-FIELD`, because a PRIVATE record
               in an unrelated module starts voting"*. It concludes: *"That is a silent acceptance
               NARROWING… and §5 R2's two enumerated exceptions are both WIDENINGS carried by a
               could-not-pass-before fixture. **A narrowing cannot meet that bar.**"*
            P0-C's five-reader set is likewise DERIVED by grep and **contradicts the ratchet's
            "three"** — consistent with RUN-007's independent finding that three is too low.
            Two independent derivations now agree on five; `declEnvsUpToGo` (`:2874`) is reported
            dead (`declEnvsVisible` has zero tree-wide callers) and is therefore retireable.
the five deltas, per reader (RELAYED from P0-C, not re-derived here):
            - `ieSnapAt` (IE) ...... SAFE — this is the licensed instance axis; it IS the C4/I2 flip.
            - ctor overlay pool .... provably MONOTONE (first-wins + early exit ⇒ MISS→HIT only).
            - `CE` ................. duplicated cycle reports + a new `T-IMPL-KIND-MISMATCH`.
            - alias table .......... WIDENS bare type-name resolution.
            - field-owner multimap . **NARROWS** acceptance — the case rule 2 above forbids.
scope:      **Blocks P0-C's bites C-2 and C-3 only.** C-0 (retire the dead accessors) and C-1
            (assert the own-row exclusion as fail-capable doctests) are ruling-INDEPENDENT and may
            proceed — and C-1 should land BEFORE anything can break the exclusion, not after.
            Phases 1 and 3 are entirely unaffected.

## RUN-009 — A-3.6 — a SECOND live defect in the ratchet's instruction row (after #1574)

question:   The ratchet instructs A-3.6 to *"hand every row the FINAL accumulator"* in
            `declEnvSeedChain`. Is that instruction safe?
ruling:     **No — reported as a live regression if followed literally.** ESCALATED with RUN-008;
            not ruled here.
derivation: RELAYED from P0-C, whose chain is specific enough to be checkable and which the
            testing round must verify: the final accumulator includes the reader's OWN row, so
            `registerAllData … prog0` then re-registers the same `cname` key
            (`registerNamedFieldVariants:12786` → `registerRecordInfoKeyed:12495` → `addFieldOwners`,
            no dedupe), and `mangledHeadCandidates:9344` reads that multimap RAW — turning its
            singleton gate into the give-up arm. **Unlike the already-documented
            `appendDataUniverse` doubling, which the source calls inert, this one is live DURING
            inference.** ⚠️ NOT re-derived by the orchestrator; labelled RELAYED deliberately.
scope:      This is the **second** defect found in the same ratchet row after #1574's two
            fabricated symbols. It corroborates RUN-004 and RUN-007's conclusion: **the ratchet is
            not a safe instruction source for this unit.** Prefer `typecheck.mdk`'s own comments.
            Do not re-file #1574; report against it.

## RUN-010 — A-3.6 — ⚖️ OWNER RULING: SPLIT THE PREDICATE (resolves RUN-008)

question:   RUN-008's escalation: delete one body (5 deltas) vs split the predicate vs defer A-3.6.
ruling:     **SPLIT THE PREDICATE.** Ruled by the owner (Val), 2026-08-12, on the orchestrator's
            escalation. A-3.6 deletes the ordinal filter on the **INSTANCE axis only** — a
            dedicated candidacy predicate for IE — while the four NAME-scoping readers keep
            theirs. The two alternatives were declined: "delete the body as ratified" would have
            required an owner licence for an acceptance NARROWING that `typecheck.mdk:2902-2908`
            says R2's exceptions cannot carry, and "defer A-3.6" would have shipped the machinery
            without the C4/I2 guarantee (RUN-005).
derivation: Owner decision, taken on the two independently re-derived citations in RUN-008
            (`DICT-SEMANTICS.md:2025-2033`, `typecheck.mdk:2902-2908`) and P0-C's grep-derived
            five-reader set. This is an ARC-DESIGN change, which is why it was escalated rather
            than absorbed into a bite — see the standing rule that architecture divergence is a
            decision point, not an implementation detail.
consequences, all owed by A-3.6's bite list:
            1. **~8 in-source comments must be re-cut**, not silently left: `typecheck.mdk:2678`
               (*"`declEnvVisibleAt`, and nothing else"*), `:1828`, `:2891`, `:2987`, `:3496`,
               `:4049`, `:4187`, `:4457`, `:19548`, and the ratchet's own rows. A comment left
               saying "A-3.6 deletes this" beside a predicate A-3.6 no longer deletes is exactly
               the ungated-prose failure this run has already hit three times (#1574, RUN-008,
               RUN-009). **The re-cut is part of the unit, not cleanup after it.**
            2. The C4/I2 report remains as RUN-005 states it — the split does not weaken the
               claim, because C4/I2 is an INSTANCE-level property and the instance axis is
               exactly what still gets flipped.
            3. RUN-006's checkpoint is unchanged and becomes MORE discriminating: the 1072 pin
               must still flip at the end of A-3.6, since it tests instance candidacy.
scope:      Unblocks P0-C's C-2 and C-3, which must now be re-cut against the split design before
            dispatch. C-0 and C-1 were never blocked.

## RUN-011 — Phase 1 — 📉 DISSOLVED: #1512 is COMPLETE and #1593 is DEFERRED OUT

question:   What remains of Phase 1 (#1512's slices, then #1593)?
ruling:     **Phase 1 no longer exists as scoped.** #1512 is complete in the tree and must not be
            scheduled. #1593 is **deferred out of the sprint** — it is not statable as bites.
            Phase 1 is replaced by ONE small ledger-repair commit (P0A-D1…D4 + ruling P0A-R1),
            landed **before Phase 2 opens**. **Phase 2 may start immediately.**
derivation: #1512 complete — RELAYED from P0-A and **independently re-derived by the orchestrator**
            at HEAD `3a7cc7b7`:
            `grep -rn -E 'universeAliasTable|universeDataParamKinds|universeFieldOwners|universeDataDecls' --include=*.mdk compiler/`
            → 22 hits, **every one a comment or a tombstone; ZERO declaration sites**. The four
            tombstones are visible at `typecheck.mdk:5538` (`universeFieldOwners`), `:5545`
            (`universeDataParamKinds`), `:5561` (`universeAliasTable`), `:5571`
            (`universeDataDecls`), each naming #1512 as the retiring unit. The rows are DELETED
            from `CrossRun`, not merely unread. ✅
            #1593 deferred — RELAYED from P0-A, on an argument the orchestrator accepts: its
            central question needs a **measurement**, not a decomposition, and its own bar
            (`perf_scaling` + hand-derived goldens + both engines + adversarial review) is
            precisely what §5 defers and §5 forbids blessing. A unit that cannot be stated as
            "apply this transformation to these N named sites" is **by §4's own test not a bite**,
            and §1's premise requires pre-cut mechanical bites.
scope:      ⚠️ Two OWNER RULINGS now owed on #1593, carried out of this sprint with it, so they do
            not evaporate: (a) **`universeCtorIdentsRef` is claimed by BOTH #1593 and #1288
            (OPEN)** with no adjudication on record; (b) #1593's title says 3 rows but P0-A reports
            **6** — `universeRecordIdentsRef`, `universeRecordCollidedRef`,
            `universeCtorCollidedRef` carry the same elaborated payload. Both RELAYED, not
            re-derived. Also RELAYED and owed to whoever takes #1593: a **third visibility
            projection** (`publicDataDecl:25190` has no `DNewtype` arm while K's fold does — reading
            K flat would leak newtype ctors cross-module, an accept where #1311/#1305 measured an
            exit 1), and the dedupe divergence going LIVE because retiring an accumulator is a
            producer change.

## RUN-012 — ledger repair — a FALSIFIED claim in the source is steering the next implementer

question:   `typecheck.mdk:3253` states elaboration mints tyvar ids *"from a global monotonic
            counter"*, and `:4254` routes every implementer to that block. Is it true?
ruling:     **False.** The counter is PER-MODULE. This is P0-A's bite D2 and it is the
            highest-value item in the ledger-repair commit, because the claim is currently the
            recorded reason a future implementer would abandon the correct approach.
derivation: **Independently re-derived by the orchestrator**, not relayed:
            `grep -n 'tyvarCounter' compiler/types/typecheck.mdk` →
            `6346:    tyvarCounter : Ref Int,` — a **`PerRun` field**, not a global;
            `6441:  tyvarCounter = Ref 0,` — re-initialised in `freshPerRun`;
            and `resetState` mints a fresh `PerRun` per module (P0-A, `:6528`, RELAYED).
            **The file contradicts itself**: `:8447` refers in passing to *"per-module
            tyvarCounter reset"* — so one comment states the truth while the block every
            implementer is routed to states its negation. Schemes already cross module
            boundaries across counter epochs.
scope:      P0-A reports the real obstacle is **diagnostics**, not perf or counters:
            `fromAstTypeE` pushes `T-ALIAS-ARITY` (`:7532`) and `T-ROW-KIND-MISMATCH` (`:7563`)
            through `pushTypeErrorOnce`, whose `Once` dedupe scope is `perRun` and therefore
            re-minted per module — so preamble elaboration would merge that scope graph-wide and
            relocate the push outside any module's harvest window: **strictly fewer diagnostics,
            loud → silent.** That is a severity INCREASE and it is on neither issue. RELAYED, not
            re-derived; it is the first thing #1593's eventual implementer should check, and it is
            cheaper to check than the perf measurement currently on record.

## RUN-013 — census — arc ground truth: `cross_allowed` = 24; the two reader derivations RECONCILE

question:   What is the live arc state, and do P0-C and P0-F's independent derivations of
            `declEnvVisibleAt`'s reader set agree? (RUN-004 designated a disagreement a finding.)
ruling:     `cross_allowed` = **24**, DERIVED. The two reader derivations **do NOT conflict** —
            they are the same fact at two granularities, and both exceed the ratchet's number.
derivation: Orchestrator ran `sh test/registry_keying_ratchet.sh` → PASS, printing
            *"ok: 24 crossRun.value.* write target(s), 22 driverState.value.*"*. ✅
            Shrink history, RELAYED from P0-F: 32→31 (#1553) → 28 (#1567) → 27 (#1588) →
            26 (#1592) → 24 (#1590).
            Reader set: P0-C reports **5 direct call sites**; P0-F reports **8 production leaf
            read paths** plus 1 dead path and 9 doctest-only readers, and supplies the
            reconciliation itself — call sites vs intermediaries vs leaf paths are three
            different counts of one structure. **The ratchet's "three" is wrong on every
            granularity**, which is the operative finding (RUN-007 predicted this).
            Both agree `declEnvsVisible`/`declEnvsUpToGo` is **DEAD** — zero tree-wide callers.
scope:      ⭐ **Under RUN-010's split ruling, only ONE of the 8 paths flips**:
            `ieSnapAt` → `checkBodyImpl:19584`, the instance axis. The other seven — `ceLookupAt`
            (×2), `ceRowsVisibleAt`, `declEnvRowVisible` (×2), `declEnvRowKindEntries`,
            `aliasVisibleTo` — **keep their ordinal filter**. This makes A-3.6 substantially
            smaller and safer than either the ratchet's description or P0-C's pre-ruling analysis,
            and it removes the field-owner NARROWING (RUN-008) entirely rather than licensing it.
            The 8-path enumeration remains load-bearing as the **checklist proving each of the
            seven was left alone** — a per-reader argument is still owed, it is just now an
            argument that nothing changed.

## RUN-014 — census — the load/store divergence check CLEARS

question:   RUN-004's suspicion: `loadDataUniverse`/`storeDataUniverse` were edited by three units
            in two days, and the ratchet warns a set-or-order disagreement is a SILENT divergence.
            Do they still agree?
ruling:     **They agree. No divergence.** This check is discharged; the testing round need not
            repeat it unless a later bite edits either function.
derivation: RELAYED from P0-F, which read both bodies: `loadDataUniverse:24891-24896` /
            `storeDataUniverse:24901-24903`. The cross-run half is exactly **one cell** on each
            side (`universeRecordByName` ↔ `recordByNameRef`) — same set, same order, one tail
            expression each, no dangling `let _ =`. The alias line is a load-only stage-K
            projection with **no inverse by construction**, which is intended, not a missing store.
scope:      Consistent with RUN-011: four of the five original cells are retired, so "the ladder"
            is now a one-cell pair. Minor ledger defect noted for the repair commit: `:24874`
            says *"three tables on this side"* when two of the three are seeded at a different
            call site (`:19780`).

## RUN-015 — ledger repair — a count error in a GATED doc, and a third stale citation

question:   Are the arc's *gated* docs (unlike the ratchet) reliable?
ruling:     **No — one is wrong by one, in the gated corpus.** Added to the ledger-repair commit.
derivation: `compiler/TYPECHECK-TARGET-ARCHITECTURE.md` (line ~1803) states A-3.5c took
            *"`cross_allowed` 28 → 27"* — **orchestrator-verified present in the file**. P0-F
            measured the actual transition as **27 → 26** (28 → 27 was #1588, the prior unit).
            ⚠️ The orchestrator verified the doc's CLAIM, not P0-F's replacement value; the
            repair bite owes a per-commit re-derivation before editing.
            Third stale citation, RELAYED from P0-F: the ratchet's `declEnvsRef` row describes
            `ieShadowCompare` in the **present tense** as a live instrument, but A-3.4 PR2 deleted
            it. Orchestrator confirmed `grep -rn ieShadowCompare --include=*.mdk compiler/` returns
            only past-tense comments (`typecheck.mdk:3831`, `:3952`, `:4056`) — so the SOURCE is
            correct and the RATCHET is stale, corroborating RUN-007's ruling to prefer the source.
scope:      Running tally of defects in `test/registry_keying_ratchet.sh`'s two hand-off rows:
            2 fabricated symbols (#1574), 1 live-regression instruction (RUN-009), 1 present-tense
            reference to a deleted symbol, 1 undercounted reader set. **Five.** This is no longer
            an anecdote about one bad row — it is the predictable result of an ungated file being
            an arc's primary hand-off channel, which is #1574's actual thesis.

## RUN-016 — census — 🚨 UNOWNED WORK FOUND: the field-owner list re-key has no stage owner

question:   §8's exit criterion is per-node. Is there A-3 work that no in-scope node owns?
ruling:     **Yes — one orphaned cluster, containing an S0 and an S1.** ESCALATED to owner; the
            orchestrator does not file issues on an agent's sweep without confirmation.
derivation: RELAYED from P0-F, which swept **all 30 open `ARCH` issues** and **all 22 open issues
            whose titles mention owner/reachability/field/slot** and found none claiming it.
            The deferral is recorded in the tree but assigned to nobody: the ratchet defers #1216
            (S0), #1383 (S1) and `deFieldOwnerIdents`' missing reader to *"a later unit"* / *"the
            unit that re-keys the owner list"*. P0-F checked the three plausible claimants and
            ruled each out: **#1319** covers ctor identity + `universeRecordByName`, not the owner
            multimap; **#1288** covers re-export merge + ctor consolidation; **#1593** covers the
            elaborated trio.
            Orphaned set: **#1216 (S0), #1383 (S1), #1586, #1468, #1456**, plus `deFieldOwnerIdents`
            — a table that is built, doctested and ratchet-allowlisted with **ZERO readers**.
            ⚠️ NOT re-derived by the orchestrator. The negative claim ("no issue owns this") is the
            expensive half and rests on P0-F's sweep alone.
scope:      P0-F notes the repo already has the right idiom — #1136/#1137 are titled *"has no stage
            owner"* — and recommends filing before the sprint exits, *"or it ships as prose inside
            a gate script's comment."* Note this is **adjacent to** RUN-010: the split ruling means
            A-3.6 no longer touches the field-owner table at all, so this orphan is now the ONLY
            thing standing between the arc and that S0/S1 pair.
            Secondary orphan: `declEnvsVisible` — exported, zero callers since A-3.1; three units
            have since built their own visibility paths and none used it. Retired by P0-C's bite
            C-0, which is ruling-independent.

## RUN-017 — A-3.4 — COMPLETE and closeable; nothing for Phase 2

question:   Is A-3.4 (the IE registry) done, and does Phase 2 owe it any work?
ruling:     **Complete. Phase 2 owes it nothing.** Recommend recording it done on #1112.
derivation: RELAYED from P0-B, which checked all four of #1112's decomposition-table deliverables
            against the source: `ImplRow`/`ImplEnv`/`deImpls` + `buildImplEnv` present; the three
            `obUniv*` accumulators **gone from `CrossRun`** (the only non-comment `obUniv` hits are
            the local `let obUniv = moduleImplUniv` at `:19945` and its two uses); one read
            accessor `ieUniverseAt` → `ieSnapAt`; `InstRef` minted; ratchet CHECK 4 live at `:570`;
            E1 tripwire live at `diff_compiler_check_cli_modules.sh:1690-1788`.
            Corroborated independently by P0-F's census (A-3.4 PR1 + PR2 both LANDED) and by the
            orchestrator's own reading of the ratchet's `deImpls` row (*"LIVE SINCE A-3.4 PR2"*).
scope:      Two known gaps are **deliberate and correctly assigned elsewhere**, not A-3.4 debt:
            `ieMethods` has no reader (→ A-3.5a, and see RUN-018), and `ieUnivSnaps` staleness
            (→ a later mutator). Do not let an implementer "finish" A-3.4 by closing these.

## RUN-018 — A-3.5a — ⚖️ RULED: do NOT implement it by reading IE (the ratchet is wrong again)

question:   The ratchet says A-3.5a and A-3.5b *"both read IE"*. P0-B reports A-3.5a does not, and
            that implementing it against IE would be actively worse. Which is right?
ruling:     **A-3.5a is implemented against CE, NOT IE.** Ruled by the orchestrator — this is a
            severity question with a settled answer in this repo, not an open architectural choice.
            The taxonomy question P0-B raises (is A-3.5a therefore an A-3**a** unit?) is **noted as
            owed but explicitly NON-BLOCKING** — see scope.
derivation: RELAYED from P0-B: iterating `IE.ieRows` would lose **every `T-INCOMPLETE-IMPL` source
            location**, because `ImplRow` carries no `Loc` — deliberately, `typecheck.mdk:3847-3854`
            — and it buys nothing, since `ieMethods` is by construction the same list the decl
            already yields. Degrading a diagnostic for zero gain is a severity increase; this tree's
            ladder makes loud → quiet a regression even when the destination is not silent.
            ⚠️ This is the **sixth** defect found in the ratchet's two hand-off rows (RUN-015's
            tally of five, plus this). The pattern is now the finding.
scope:      Non-blocking because **A-3.3 and A-3.4 have BOTH landed** (RUN-013, RUN-017), so
            A-3.5a and A-3.5b are unblocked under either taxonomy — the ratified edge
            `{3.2,3.3,3.4} → 3.5` is satisfied either way. The label would matter for the C4/I2
            claim, but RUN-005 places that entirely on A-3.6, so A-3.5a's lane cannot move it.
            Recorded so the eventual #1112 bookkeeping is not silently wrong.
            **Sizing** (RELAYED from P0-B): A-3.5a = 5 bites + 1 conditional, shrinks
            `cross_allowed` 24 → 23 (retires `universeIfaceRequiredRef`). A-3.5b = 4 bites,
            **shrinks nothing** — so A-3.5b's grading criterion is NOT the ratchet's progress
            signal, and an implementer must not be told to expect a shrink.
            Two hazards to carry into both briefs: (a) the primary failure mode is
            **identity miss → `None => [] ` → silent accept**, and P0-B measured four baselines
            that must not move; (b) A-3.5b's naive cut **re-creates A-3.4 PR2's measured
            quadratic** — `ieRowsVisibleAt` must be bound once per call, never folded per read.

## RUN-019 — Phase 2 — the lane plan, replacing §2's single serial chain

question:   §2 orders A-3.4 → A-3.5 → A-3.6 → A-3.7 strictly serially. What is actually forced?
ruling:     **Two concurrent lanes, then a serial tail.** Adopted by the orchestrator on region
            disjointness, which is §4's own safety argument — not on phase ordering.
              0. **Ledger-repair commit** (single commit, before any lane opens): P0-A's D1–D4,
                 RUN-015's gated-doc count fix, and P0-C's C-0 (retire the dead `declEnvsVisible`
                 /`declEnvsUpToGo` path). ⚠️ P0-A warns D1/D2 sit near lines A-3.6 edits
                 (`declEnvVisibleAt:2834`, `declEnvSeedChain:3054`) — hence one commit, landed
                 before the lanes, never concurrent with them.
              1. **Lane A — A-3.5a** (5 bites + 1 conditional, CE-side, retires
                 `universeIfaceRequiredRef`).
              2. **Lane B — A-3.5b** (4 bites, IE-side).
              3. **Then A-3.6** (split-predicate per RUN-010; C-1's own-row-exclusion doctests may
                 land in the repair commit or at the head of this unit — earlier is better, since
                 they are what makes a later break loud).
              4. **Then A-3.7.**
derivation: A-3.4 is complete (RUN-017) and A-3.3 landed (RUN-013), so the ratified edge
            `{3.2,3.3,3.4} → 3.5` is fully satisfied and nothing forces A-3.5a and A-3.5b to be
            serial with respect to each other: P0-B's bite lists touch different tables (CE
            required-methods vs IE rows). A-3.6 stays AFTER A-3.5b because both work the IE
            neighbourhood — `ieRowsVisibleAt` (A-3.5b) and `ieSnapAt` (A-3.6) are the same
            structure, and §4's region discipline is the only thing keeping concurrent
            implementers safe.
scope:      ⚠️ This ruling rests on a **claim of region disjointness that the sub-orchestrator must
            confirm against the actual bite sites before dispatching both lanes.** If Lane A and
            Lane B overlap on any named region, they serialize — the fallback is cheap and the
            failure mode of getting it wrong is not (§4: an implementer whose region changed under
            it **STOPS and reports**; it does not adapt).

## RUN-020 — ⚖️ CONFLICT RESOLVED: P0-A "#1512 complete" vs P0-E "#1319 unit 4 not done"

question:   RUN-011 ruled Phase 1 dissolved on P0-A's "#1512 is complete". P0-E independently
            reports **#1319 unit 4 is NOT done** — `importedCtorTypeDecls` still live. Which holds?
ruling:     **Both are factually right; they disagree only on the completion LABEL — and under
            RUN-010 the disagreement is MOOT. RUN-011 stands: no Phase 1 work.**
derivation: Orchestrator re-derived the disputed symbol directly:
            `grep -n importedCtorTypeDecls compiler/types/typecheck.mdk` → **live**, defined at
            `:26234`, called at `:19782` and `:26732`. P0-E is correct that it exists. ✅
            But its signature is `List Decl -> Int -> List DeclEnvModule -> List Decl` and the call
            sites pass `envs.deModules` / `declEnvsHere.deModules` — i.e. **it already reads stage
            K**. That is exactly what PR #1553 did ("retire the overlay POOL onto stage K"), and it
            is consistent with RUN-011's verified fact that `universeDataDecls` has zero
            declaration sites. So: the **pool** is retired (done); the **overlay function** remains,
            re-sourced from K.
            The two agents therefore agree on every fact and differ on whether "unit 4 complete"
            means the pool or the function.
resolution: **The function is not this sprint's to remove.** `importedCtorTypeDecls` reaches
            `declEnvVisibleAt` through `declEnvRowVisible`/`overlayScanRows:26323` — it is one of
            RUN-013's eight reader paths, and it is a **NAME-scoping** reader. Under RUN-010's
            owner ruling it **keeps its ordinal filter and therefore keeps existing.** Removing it
            would be precisely the unlicensed name-widening the split ruling was taken to prevent.
scope:      📌 Method note, worth more than the result: two agents returned contradictory verdicts
            from correct observations because they applied different completion criteria to the
            same code. The disagreement was only visible because the derivation was demanded
            alongside the conclusion. Neither report was wrong; **the label was underdetermined**,
            and a label is what would have been carried forward.

## RUN-021 — A-3.7 — scoped: an input relocation + one key comparison; and it shrinks NOTHING

question:   What does "coherence over IE" concretely resolve to, and does the #1438 bare leg defeat it?
ruling:     **A-3.7 = 2 input adapters + 2 entry points + one key-comparison change. 10 bites.**
            The bare leg is **acceptable and makes coherence strictly MORE correct** — under one
            discipline: **read `ieRows`, never the buckets.**
derivation: RELAYED from P0-D (probes executed on the trunk binary):
            - A-3.7 is NOT landed: `checkCoherence : List Decl`, `CohImpl` still bare-`String`
              keyed, compared `if1 == if2` at `typecheck.mdk:15295`.
            - The 33 `coh*` judgment functions are **untouched**; no diagnostic wording moves.
            - `ieInsertRow:4033` applies `oblIfaceKeys` **only to the three index buckets**; the
              `ieRows` update takes no key. So a sweep over `ieRows` sees each impl once and
              consults no bucket. ⚠️ **The trap is the obvious optimization**: grouping by
              `ieConcrete`/`ieHeadless` sees every row twice and, in the bare bucket, compares two
              *different* interfaces sharing a spelling — rebuilding today's bug in the new
              substrate. The IE doctest asserts that collapse is live (`:4169`, bare bucket = 2).
            - Comparison predicate must be `sameTyConHead`, **never** `ifaceIdMatches` (the
              inversion documented at `:9189-9195`) — coherence is an ACCEPTANCE question, so
              absence must make no claim.
            - **A live FALSE REJECT measured, on `check` AND `run`, exit 1**: two unrelated modules
              each declaring their own `Same`, each `impl Same Int` → *"Conflicting `impl Same`"*.
              Positive control (rename one to `Other`) → exit 0. This is a real bug A-3.7 fixes.
scope:      🚩 **A-3.7 shrinks `driver_allowed` by ZERO rows** — `coherenceUserDecls` does NOT
            retire, because it *is* the Flat arm's prelude carve-out (there is no ordinal-0 prelude
            row on Flat). **Do not grade A-3.7 on the ratchet progress signal.**
            🚩 `ieMethods` gets **no** reader from A-3.7 (coherence compares (iface, head) only);
            `implDeclFacts:3959-3966` names **A-3.5** as its consumer — the ratchet row pairing it
            with A-3.7 is wrong. **Seventh ratchet defect.**
            🚩 `ieLoc` is **not owed** — `firstTyLocList` (`ast.mdk:678`) recovers the span from
            `ImplRow`'s raw head, contra `TYPECHECK-TARGET-ARCHITECTURE.md:1641`.
            🚨 **`test/must_fail_fixtures/1438-*` DOES NOT EXIST** — orchestrator-verified by `ls`.
            A-3.7's widening drains #1438's coherence reach and **nothing pins it**, so the drain
            would be invisible in both directions. Authoring that pin belongs in A-3.7's bite list.
            Serialization (RELAYED): bites 1/2/3 parallel; **3.7-4 (the widening) lands ALONE**;
            3.7-7 and 3.7-8 must not be bundled; 3.7-9/10 last. Diagnostic-only hazard at 3.7-5:
            `cohSoftInScope "" ""` silently drops every intra-module `W-INCOMPARABLE-IMPLS` once
            rows carry real mids — invisible to value goldens, must be re-cut sweep-scoped.

## RUN-022 — Phase 3 — #1351's blocker is GONE; M-1 is implementable; M-2 should DEFER

question:   §1 says #1354 and #1319 need a unit split before implementation. What is it?
ruling:     **#1354 splits M-1 = #1351, M-2 = #1276 + #1265 + #1386.** M-1 is **fully implementable
            this sprint (6 bites)**. **M-2 is recommended for deferral** — escalated, see RUN-023.
            **#1319's Phase-3 residue = 3 bites** on the field-owner predicate.
derivation: RELAYED from P0-E, with both S0s **reproduced first-hand on the trunk binary under
            `MEDAKA_STRICT=1`** (#1351: check 0 / run 7 / control 99 / swapped exit 1; #1276:
            check 0 / run 2 / control 1). Orchestrator confirmed both pins exist:
            `test/must_fail_fixtures/1351-methoddispatchidx-import-order-collision` and
            `1276-alias-method-provenance-erased`. ✅
            🚨 **The scope-changing finding: #1351's recorded blocker no longer exists, and nobody
            recorded that.** Both adopted scoping passes say M-1 cannot be graded because the spec
            does not derive the answer, and that a successor issue "was being filed." **It was
            never filed — the ruling landed in the SPEC instead**: `docs/spec/SHADOW-SEMANTICS.md:971-1052`,
            marked *🔒 S2-DECL, RULED 2026-08-09 (#1351)*, five sub-clauses. It also discharges
            M-1's "Step 0, blocking" item and specifies the target value (**99 at every ordering**),
            which P0-E re-derived independently from `main.mdk`'s import lines.
            M-2 root cause, re-derived first-hand by P0-E: `renameAliasedMethods` has one caller in
            `elaborateModules:27014`, which sets `implInferEnabled := True` (`:13743`), and the
            impl-obligation check runs only under `not implInferEnabled` (`:19946-19951`). The
            adopted fix is an **AST occurrence carrier** — `add-language-feature` scale, not a bite
            list, and therefore failing §4's own test exactly as #1593 did (RUN-011).
scope:      #1354 bookkeeping is stale: **#1353 is CLOSED** (unit A / PR #1419) while #1354's body
            still says it owns three. Partial identity checked as the SET, per the standing rule:
            of 7 method-namespace refs, **2 identity-keyed, 1 bare-with-a-scoped-read, 2 bare, and
            2 (`methodDispatchIdxRef`, `argDispatchIdxRef`) that the `universe*` grep cannot see
            at all** — the last pair is why a single-table check reads as done.
            ⭐ P0-E **corrected its own earlier inference** mid-report: it had `nameableIfaceShadows`
            failing closed; `:25067` fails **OPEN**, deliberately (the S4/#410 SIGSEGV class) — so
            M1-e's new reject could fire on single-file programs unless gated. Recorded because a
            self-correction that survives into the ledger is worth more than a clean-looking report.
            #991 (RELAYED, three asks / three answers): ask 1 **DRAINED** (`implObls : Windowed
            UObligation` `:6365`, `implOblToU` gone); ask 2 **DRAINED** (`:5203` "every arm is now
            LIVE", all four producers grepped); ask 3 **STILL LIVE** (`numlitRefs:6366` has no
            comment). ⇒ **#991 is now a one-line S3 doc residual, not a storage port** — its title
            and body are stale. Folded into the ledger-repair commit (RUN-019 step 0).
            Shells: **neither #1111 nor #1112 is clean.** #1111's closure ruling names **#1317**,
            which is OPEN *and* a dissolved historical pointer — unowned bookkeeping. **#1112 holds
            two unowned items**: A-3.4 has no issue at all (RUN-017's landed work has no ticket),
            and the per-namespace A-3 precondition analysis is owed to nobody.
            Eighth ratchet-class defect, in a *doc* this time: `methodIfaceTableRef` /
            `methodIfaceIndexRef`, cited at `emit_support.mdk:449-464` in **#1112's body**, in
            `TYPECHECK-TARGET-ARCHITECTURE.md:1806`, and in #1354's scoping pass, **do not exist** —
            that file has zero `methodIface` hits. The claim they support is true; the citation is
            fabricated. Same class as #1574, in a doc the symbol gate cannot see.

## RUN-023 — ⚖️ OWNER RULING: the field-owner re-key ENTERS SCOPE as Unit F (resolves RUN-016)

question:   RUN-016's orphan — file it, scope it, or note it?
ruling:     **Scoped in, as a fourth unit ("Unit F").** Ruled by the owner (Val), 2026-08-12,
            declining both "file a tracking issue" and "note in handoff". The sprint will **drain**
            #1216 (S0) and #1383 (S1) rather than record them.
derivation: Owner decision on RUN-016's escalation.
scope:      ⚠️ **Unit F is UNDESIGNED — no bites exist for it**, so it cannot be dispatched under
            §1's premise (pre-cut mechanical bites). A dedicated Opus architecture pass is
            launched for it immediately, running CONCURRENTLY with the ledger-repair commit and
            Lane A/B rather than serialized ahead of them.
            Known hazards it inherits, from the ratchet and RUN-008: the owner list is **bare-keyed**
            and its candidate set is **every PUBLIC record in the visible prefix**, so a record the
            importer has no import path to still votes. The predicate that fixes it is a **type
            REACHABILITY** test, which every prior unit deferred. ⚠️ RUN-008 measured that the
            naive whole-graph population NARROWS acceptance (`T-AMBIGUOUS-FIELD` on programs that
            compile) — so Unit F is the one unit in this sprint whose characteristic failure is a
            **false reject**, not a silent accept. Its bites must be graded accordingly.
            `deFieldOwnerIdents` (built, doctested, ratchet-allowlisted, ZERO readers) is the
            table Unit F is expected to give its first reader.

## RUN-024 — ⚖️ OWNER RULING: M-2 DEFERRED out of the sprint; M-1 proceeds

question:   RUN-022's escalation: attempt M-2 (#1276 + #1265 + #1386) or defer it?
ruling:     **M-2 is deferred out of the sprint.** M-1 (#1351) proceeds — 6 bites. Ruled by the
            owner, 2026-08-12.
derivation: Owner decision, on P0-E's first-hand root-cause derivation (RUN-022): the adopted fix
            is an **AST occurrence carrier**, `add-language-feature` scale, which fails §4's bite
            test the same way #1593 did (RUN-011). Consistent with this run's premise.
scope:      **#1276 stays OPEN and its must-fail pin stays RED — unchanged by this ruling**, since
            §1's closure policy never permitted closing it anyway. Do not let the deferral be
            reported as a regression or as a drain. The root-cause chain P0-E derived
            (`renameAliasedMethods` → `elaborateModules:27014` → `implInferEnabled := True` `:13743`
            → obligation check gated off at `:19946-19951`) is preserved in
            `.claude/sprint/phase0/P0-E-namespace.md` for whoever takes it — that derivation is the
            expensive part and must not be re-paid.

## RUN-025 — ⚖️ OWNER RULING: A-3.7 authors the missing #1438 pin, inside the unit

question:   `test/must_fail_fixtures/1438-*` does not exist (orchestrator-verified). Where does it
            get authored?
ruling:     **Inside A-3.7's bite list, BEFORE the widening bite (3.7-4) lands.** Ruled by the
            owner, 2026-08-12; "pin it now" and "leave it to the testing round" both declined.
derivation: Owner decision on RUN-021's finding. The standing rules it satisfies: a probe must be
            **able to fail**, and a discriminating probe must **succeed pre-fix** — P0-D already
            holds the reproducing program (two unrelated modules each declaring their own `Same`,
            each `impl Same Int` → *"Conflicting `impl Same`"*, exit 1 on both `check` and `run`)
            **and its positive control** (rename one to `Other` → exit 0).
scope:      ⚠️ The ordering is the whole ruling: the pin must be authored and observed RED **before**
            3.7-4 flips it, or it is a probe shaped to fit its own fix. A-3.7's sub-orchestrator
            owns enforcing that ordering, and it is the one place in this sprint where §5's
            "run no gates" posture is explicitly overridden for a single fixture.
            Do **not** close #1438 when the pin flips — RUN-021 records that A-3.7 drains only its
            *coherence reach*; the identity collapse itself belongs to #1482/#1507.

## RUN-026 — ledger-repair — LANDED; and the LEG A golden will move as a **DELETION**

question:   Did RUN-019 step 0 land clean, and does it leave the testing round anything unusual?
ruling:     **Landed and verified.** One unusual item, recorded here so the testing round does not
            reject it as a rule violation: **bite C-0 moves the selfproc LEG A golden as a
            DELETION** — three top-level bindings removed — which is NOT the additive-only shape
            the standing re-cut rule expects.
derivation: Orchestrator-verified before committing, not taken on report:
            - `git diff --stat` → 5 files, +350/−44; the only compiler-source file touched is
              `compiler/types/typecheck.mdk`. Scope matches the brief. ✅
            - `grep -rn 'declEnvsVisible|declEnvsUpTo' --include=*.mdk .` → **6 hits, ALL comment
              lines** (a `🪦 RETIRED` tombstone at `:2871-2876` plus back-references). Zero
              definitions, zero call sites: the dead path is genuinely gone. ✅
            - `make check-self` → **PASS**: *"medaka_cli.mdk closure is type-clean"*. ✅
            The implementer's own re-derivations, which the orchestrator accepts:
            C-0's dead-code check independently confirmed (whole-worktree grep incl. doctest text);
            RUN-015's count independently re-derived per-commit as **27 → 26**, *agreeing with
            P0-F* — `0240af59` 28 → `257d7e79` (#1588) 27 → `6775679a` (#1592) 26 → `dc3e8bd5`
            (#1590) 24, HEAD 24 matching the live ratchet. The gated doc had mis-attributed
            **#1588's** transition to A-3.5c. No disagreement to adjudicate.
scope:      🚨 **For the testing round's golden re-cut:** the standing rule is that a LEG A re-cut
            must be **additive-only** — *"no EXISTING binding's inferred type may change; if one
            did, the fix changed types."* C-0 legitimately violates the letter of that rule by
            **removing** three bindings (`declEnvsVisible`, `declEnvsUpTo`, `declEnvsUpToGo`). That
            is the intended effect of a deliberate dead-code retirement, not evidence of a type
            change. **Expected LEG A delta: exactly three deletions, zero modifications.** If any
            *surviving* binding's scheme moved, that is a real finding and this entry does not
            excuse it.
            ⭐ Implementer self-correction, recorded because it is the behaviour the ledgers exist
            to reward: a first draft of the RUN-014 comment claimed the seed runs *before*
            `loadDataUniverse` in `checkBodyImpl`'s Module arm. The implementer checked instead of
            shipping it — **false**, `loadDataUniverse cur` is at `:19733` and the seed at `:19780`
            — and removed the claim rather than repairing it into something defensible.
            Ninth stale reference logged, not acted on (out of scope by brief):
            `test/registry_keying_ratchet.sh` still names `declEnvsVisible` in prose.
            #991 **DRAINS** with this commit (ask 3 was the last live one).

## RUN-027 — Unit F — designed, and it SPLITS: 3 bites ship, 2 need their own gated round

question:   RUN-023 scoped Unit F in undesigned. What is it, and is it feasible under §5?
ruling:     **Feasibility: SPLIT.** F-0/F-3/F-4 are sprint-safe and **drain #1383 (S1) and #1586
            (S0)** — Val's stated intent in scoping it in. **F-1/F-2 are NOT sprint-safe** and are
            recommended out, as a new ARCH node with F-0's fixture already red and the predicate
            pre-derived. Orchestrator adopts the split; the residue is escalated in the report.
derivation: RELAYED from P0-G (`.claude/sprint/phase0/P0-G-unitF-fieldowners.md`).
            The reachability predicate, DERIVED: for reader `m` at ordinal `cur`, record `d` in
            module `k` at ordinal `o` is a candidate iff `(o == cur)` — own row, unchanged — or
            `(o < cur ∧ publicDataDecl d ∧ k ∈ depClosure(m))`, where `depClosure` is the transitive
            closure of `m`'s own `DUse` module ids (`usePathModuleId`) plus the prelude. It must be
            **module** reachability, not name-visibility: a module can hold a value of a type it
            never imports by name, and dropping it yields `[]` → `T-UNKNOWN-FIELD` or a silent
            singleton. **On a closure miss, fall back to today's prefix — never to `[]`**
            (`typecheck.mdk:3095-3099`: the owner half fails closed and loud). Not an invention —
            `:25356` already does import-scoped per-module seeding for schemes; the field-owner
            seed is the only one still on a topological prefix.
            Why F-1/F-2 cannot ship under §5, three independent reasons: the failure is
            **diagnostic-only** and invisible to every deferred gate; the one gate that *can* see
            F-2's risk is `perf_scaling`, which §5 defers and **which already caught this exact
            function's first cut**; and the safety argument ("a module cannot hold a value of an
            unreachable type") is adversarial-review material, not fixture material.
scope:      🚩 **#1216 IS NOT UNIT F'S — recommend re-assigning it to `ws:emitter`.** P0-G ran three
            discriminating probes: typecheck resolves it **correctly** (`probe : String`) while the
            same build is wrong; a 3-field rival moves the read to slot 2; single-file and
            one-module-on-the-Module-path controls are both correct. The loss is `fieldIdxByName`'s
            silent fall-through to `findFieldIdx` on a key-space miss
            (`compiler/backend/llvm_emit.mdk:10023`). ⚠️ This means **RUN-016's orphan cluster was
            mis-scoped when the owner ruled on it** — see the escalation.
            🚩 **A NEW, UNFILED, MEASURED false reject is the actual Unit F bug**: `bmod.mdk`
            imports *nothing*, yet `amod`'s `Zed` votes in it purely because `amod` is
            topologically earlier — exit 1 on a legal program. Two positive controls clean, and
            `v1` (rival genuinely imported) correctly stays red, so the fix is discriminating.
            F-0 pins it. **Not filed** — the orchestrator does not file on an agent's report
            without owner confirmation.
            🚩 **`deFieldOwnerIdents` is NOT fit and Unit F must not read it** — contradicting the
            widespread expectation that it is what Unit F finally reads. Ordinal-free and
            `DAttrib`-unwrapping (as the ratchet says), **plus a third reason nobody wrote down: it
            is FLAT**, so a reader filters the whole table per read — the exact quadratic CI already
            caught on this function (`:3054`). Unit F needs none of it.
            🚩 **The orphan splits THREE ways; only one third is the re-key.** #1468 is a missing
            per-constructor totality check; #1456 is `fieldOwnerNames`' per-access `sortUniqS`
            (`:8992`), a perf item. RUN-016 treated the cluster as one unit of work.
            ⚠️ **F-4 is GATED on #1216's assignment**: it changes the selected `RecordInfo` while
            the stamp stays bare-keyed, and #1383's own body says that converts the S1 into #1382's
            S0. Do not dispatch F-4 until #1216 is re-assigned or ruled on.
            **Pin contradiction RESOLVED** (RUN-016 vs P0-G): the ratchet row
            (`registry_keying_ratchet.sh:236`) is a **neutrality claim about A-3.2b slice 3** — *"so
            they reproduce unchanged, and the predicate is owed to a later unit."* The census
            dropped the "so" and the deferral, turning a unit-scoped statement into a permanent
            tripwire. **Classification is UNIT-RELATIVE**: `1383-*` and `1586-*` are FLIP-EXPECTED
            for Unit F only; `1216-*` stays non-flip, for the different reason that Unit F does not
            reach it.
            **Order**: after the ledger-repair commit (FORCED — D2 sits on `declEnvSeedChain:3054`,
            which is F-2's site), concurrent with Lanes A/B, **before A-3.6** (whose owed comment
            re-cut at `:2891`/`:2987` is inside Unit F's region).

## RUN-028 — operations — a concurrent implementer INVALIDATED a read-only agent's probes

question:   Is it safe to run read-only design agents concurrently with implementers?
ruling:     **Only with the base pinned.** P0-G reported that `MEDAKA_STRICT=1` **stopped passing
            mid-session** because the ledger-repair implementer edited `typecheck.mdk` underneath
            it; its probe results are valid against `176feb50`'s source, not against HEAD.
derivation: RELAYED from P0-G, which disclosed it unprompted and stated which commit its results
            hold against — the honest handling, and the reason the results are still usable.
scope:      The staleness guard did its job: it converted a silent wrong-binary hazard into a loud
            failure, exactly as designed. But the orchestrator's Phase-0-concurrent-with-Phase-1
            scheduling (RUN-023) is what created the race. **Standing rule for the rest of the run:
            any agent running probes concurrently with a live lane must (a) pin and report the
            commit its results hold against, and (b) treat a `MEDAKA_STRICT` failure as a signal to
            re-derive, never to drop the guard.** Do not "fix" this by unsetting `MEDAKA_STRICT` —
            that trades a loud failure for a silently wrong answer, which is the trade this whole
            sprint's posture is least able to absorb.

## RUN-029 — ⚖️ OWNER RULINGS EXECUTED: #1597 filed; #1216 needed no re-label

question:   Execute RUN-027's two escalations — re-assign #1216, and file F-1/F-2 as an ARCH node.
ruling:     **F-1/F-2 filed as #1597.** **#1216 required NO re-label — the recommendation rested on
            a false premise, caught before the write.** A corroborating comment was posted instead.
derivation: Orchestrator, before writing anything:
            - `gh issue view 1216 --json labels,title` → **already** labelled `S0: silent wrongness,
              verified, ws:emitter`, with a title that already reads *"makes the native emitter read
              the WRONG SLOT — run != build"*. P0-G's *"recommend re-assigning it out"* and the
              owner ruling taken on it were both premised on a mis-assignment **that does not exist
              in the tracker**. The mis-attribution is in `test/registry_keying_ratchet.sh`'s prose,
              which files the bug under the typecheck-side field-owner re-key. A relabel would have
              been a **no-op write dressed as a fix**. ✅ Comment posted instead
              (`#1216#issuecomment-5270713229`), carrying the three discriminating probes and the
              routing correction.
            - **The #1597 repro was re-run FIRST-HAND before filing**, per the standing
              reproduce-before-you-file rule, and the first attempt **FAILED**:
              a signatured receiver (`readTag : Wye -> Int`) checks at **exit 0**, because the
              annotation pins the receiver and the ambiguity test never runs. Only the
              **unsignatured** form reproduces. ⚠️ **That negative is now recorded in #1597's body**,
              because a probe "clarified" with a type signature silently stops testing the bug —
              the same shape as a probe that cannot fail.
              Confirmed repro at `f37b2562`: `main.mdk` (imports amod + bmod) → **exit 1**,
              *"Ambiguous field access: '.tag' is declared by Wye, Zed"*; positive control
              `bmod.mdk` **alone** → **exit 0**, `readTag : Wye -> Int`. `bmod` imports nothing.
            - Write verified by readback, not by exit code: `gh issue view 1597` returns the
              expected title and all three labels, and 6 distinctive body markers all resolve
              (`UNSIGNATURED`, `depClosure`, `fails closed and loud`, `PRODUCER-side`,
              `llvm_emit.mdk:10023`, `P0-G-unitF`). A 31-byte length delta vs the local file is
              newline normalisation, not content loss.
scope:      📌 **Method note.** Two escalations were taken to the owner as a pair; one of them was
            built on a premise nobody had checked, including me — I relayed P0-G's recommendation
            into an owner question without verifying the tracker state it asserted. The owner ruled
            correctly on the information given, and the information was wrong. **Checking took one
            `gh issue view`.** The rule this violates is the one this run has invoked most often:
            a precise claim is not a verified one, and an orchestrator's brief is not a relay.
            Unit F's remaining sprint scope is unchanged: **F-0, F-3, F-4** (F-4 still gated on
            #1216, which is now simply "not ours" rather than "awaiting re-assignment").

## RUN-030 — Unit F — **F-4 DROPPED**: a downstream consequence of the #1216 ruling

question:   RUN-029 left F-4 "gated on #1216, which is now not ours." Does F-4 still ship?
ruling:     **No. F-4 is dropped from the sprint.** Unit F ships **F-0 + F-3 only**. It therefore
            drains **#1586 (S0)** but **NOT #1383 (S1)**.
derivation: P0-G's ordering constraint, stated as a constraint and not a note: F-4 changes the
            selected `RecordInfo` while `inferFieldAccess` still stamps a **bare** key, and #1383's
            own body says that conversion turns the S1 into **#1382's S0**. P0-G: *"F-4 must not
            land before the stamp [fix]."* The stamp fix is #1216, ruled out of scope (RUN-029).
            ⇒ Landing F-4 alone would trade a **loud S1 for a silent S0** — a severity INCREASE,
            and precisely the loud→quiet regression this repo's ladder forbids.
scope:      ⚠️ **This is a chained consequence, not a new judgement**: the owner ruled only on
            #1216's assignment, and F-4's fate followed from it two steps later. Recorded because
            an unrecorded chained consequence is how scope silently shrinks — the sprint would
            otherwise report "Unit F landed" while the S1 it was scoped to drain stayed live.
            **Revised Unit F outcome: #1586 drains, #1383 does not.** #1383 now needs the same
            treatment as F-1/F-2 — it is blocked on an emitter fix, and nothing in the typecheck
            lane can unblock it. Its pin stays non-flip for this sprint.
            📌 The dependency is worth stating plainly for the handoff: **#1383's typecheck half
            cannot land until #1216's emitter half does.** That coupling is not recorded on either
            issue.

## RUN-031 — Unit F — **F-3 REFUSED: the briefed site is unreachable dead code.** Unit F drains NOTHING

question:   Did F-3 land, and does Unit F deliver the S0/S1 drain RUN-027 promised?
ruling:     **F-3 did NOT land, correctly.** The implementer refused it and proved the briefed
            transformation is a no-op. **Unit F ships F-0 (a pin) ONLY, and drains NEITHER #1586
            NOR #1383.** RUN-027's *"F-0/F-3/F-4 drain #1383 and #1586"* **is not achievable as
            scoped** and is hereby superseded.
derivation: RELAYED from the Unit F implementer as a **closed chain of grepped readings**, which is
            why it is accepted rather than re-litigated:
            `declEnvDeclFieldOwners` has ONE production caller — `declEnvSeedChain:3061` — which
            passes `declEnvRowVisible (m.demOrd + 1) m`; at that `cur`, `declEnvRowVisible:2927-2931`
            + `declEnvVisibleTo:2911-2913` **always** take the `m.demPubDecls` arm;
            `declEnvModule:2819` sets `demPubDecls = publicDataDecls decls`; and
            `publicDataDecl:25234-25239` has **no `DAttrib` arm** (`_ = False`).
            ⇒ **A `DAttrib` can never reach the briefed function.** Adding an arm there is
            unreachable code.
            ⭐ The tree already said so, and three passes over this territory missed it:
            `test/check_module_fixtures/attributed_record_no_field_vote/entry.mdk` calls that arm
            *"the `publicDataDecls` memo, `DAttrib`-blind by construction."*
            **#1586 is LIVE**, re-measured with a discriminating control: single-file repro → exit 0,
            silent `g : A -> Int`; positive control (only the `@deprecated "old"` line removed) →
            exit 1, `T-AMBIGUOUS-FIELD`. Its real sites are `registerData:12504-12523` (the
            Flat/own-row half, where the headline S0 lives — `declEnvDeclFieldOwners` is **not on the
            Flat path at all**), `resolve.mdk`'s `fieldOwnersOf`, and for the cross-module arm
            **`publicDataDecl` itself** — which is neither small nor pre-licensed:
            `typecheck.mdk:3398-3405` calls letting an attributed decl through it *"an acceptance
            WIDENING, incoherent besides."*
scope:      **Revised Unit F outcome: one pin, zero drains.** Everything the owner scoped Unit F in
            to achieve (RUN-023: *"drain the S0/S1 rather than record them"*) has now been shown
            unreachable within this sprint's posture — #1216 is an emitter bug, #1383 is blocked
            behind it, #1597 was deferred, and #1586's real fix is an explicitly-unlicensed widening.
            ⇒ **#1586 needs the same treatment as F-1/F-2**: a re-scope with its true sites named.
            Escalated to the owner rather than absorbed.
            📌 **The pattern, now three-for-three:** every Unit F bite failed for the same reason —
            *the design named a plausible site that the code cannot reach*. F-3's site is
            `DAttrib`-blind by construction; F-4's precondition lives in another subsystem; F-1/F-2's
            gate is deferred. A bite list is only as good as its **reachability** claims, and
            "grep-verified the symbol exists" does not establish that the symbol is *on the path*.
            That distinction is the cheapest lesson available from this unit.

## RUN-032 — Unit F — F-0 landed, and it MOVED HARNESS on measured evidence

question:   P0-G specified F-0 as a `check_module_fixtures` cell. Was that right?
ruling:     **No — moved to `test/must_fail_fixtures/1597-unimported-record-votes-in-field-owners/`,
            on MEASURED evidence.** Accepted.
derivation: RELAYED. The implementer **built the `check_module_fixtures` cell first**, then measured
            it blind: `diff_compiler_check_modules.sh` diffs only the **entry** module's sorted
            scheme dump, and `check_modules_main … entry.mdk <root>` over the exact #1597 graph
            prints `main : Unit` at **exit 0** — because the rejection lives in `bmod.mdk`, whose
            schemes that dump never contains, and stderr is discarded. **Positive control on its own
            invocation**: the same command on `attributed_record_no_field_vote/` reproduced that
            cell's committed `oracle.tcmod` byte-for-byte — so the harness was working and the
            corpus genuinely cannot see this bug.
            It is also inexpressible there in principle: the reader must import **nothing** while the
            rival is in the graph, and the entry must import **everything**.
            Pin as landed: `check-json main.mdk` / `exit: 1` / `diag-code: T-AMBIGUOUS-FIELD
            15:12-15:13`; control is `bmod.mdk` **as its own entry, byte-for-byte** — only graph
            membership varies (exit 0, zero diagnostics). That is the right control: it varies the
            single thing under test and nothing else.
            Shared-corpus check done properly (word-bound, per the standing trap): the real iterator
            of `check_module_fixtures/` is **`diff_compiler_check_modules.sh` ONLY** —
            `diff_compiler_check_cli_modules.sh` has no `FIXDIR` and references it in prose only.
            Moot in the end, since that corpus was left untouched.
scope:      ⚠️ **One reading in that report is CONTAMINATED and must not be carried forward.** The
            implementer ran `diff_compiler_must_fail.sh` → *"93 still reproduce, 5 DRAINED"* and
            reports the 5 drains as pre-existing. **Lane A was editing `typecheck.mdk` concurrently
            and uncommitted throughout that run**, so that measurement was taken against a tree
            nobody has a clean name for. **The 5 drains are OWED a re-derivation on a quiescent
            tree** before anyone acts on them — if genuine, they are five already-fixed bugs whose
            issues are still open, which is a real finding, but not one that can be claimed from a
            contaminated run. Same root cause as RUN-028.

## RUN-033 — checkpoint — the quarantined "5 DRAINED" was a PHANTOM. Quiescence is not optional

question:   RUN-032 quarantined a mid-flight reading of *"93 still reproduce, 5 DRAINED"* pending a
            clean re-derivation. What is the truth?
ruling:     **There were ZERO drains.** The 5 were entirely an artifact of measuring against Lane A's
            uncommitted, half-applied edits. The quarantine was correct and the reading is discarded.
derivation: Orchestrator ran `sh test/diff_compiler_must_fail.sh` on the quiescent tree at
            `433bcffe`, with no agent live and nothing uncommitted:
            **`checked 98 fixtures: 98 still reproduce, 0 DRAINED, 0 control-broke, 0 malformed`**.
            Corroborating detail: `1597-*` REPRO (the new pin works) and `1586-*` REPRO (still live,
            consistent with RUN-031's refusal of F-3). Fixture count reconciles: the contaminated run
            saw 93 + 5 = 98.
scope:      🚨 **This is the sprint's sharpest operational lesson and it generalises past this run.**
            Mid-edit, the compiler passed through a state in which **five separate pinned bugs
            appeared FIXED**. Had that reading been trusted, the sprint would have reported five
            spurious drains — and the natural next action on a drain is to CLOSE the issue, so the
            failure would have propagated straight into the tracker as five wrongly-closed bugs, in
            a run whose closure policy exists precisely to prevent that.
            **A must-fail run is only meaningful on a quiescent tree.** It is not a cheap check that
            can be slipped in beside live work; the drain/repro verdict is exactly the thing that
            a half-applied edit perturbs.
            📌 Standing rule for the rest of the run, and the reason the §2 checkpoint is run
            SERIALLY rather than beside a lane: **no gate is measured while any implementer holds
            uncommitted edits.** The cost is idle wall-clock; the alternative is a confidently wrong
            answer, which this sprint's deferred-verification posture has no second chance to catch.
            This is now the THIRD contaminated measurement traceable to orchestrator-scheduled
            concurrency (RUN-028 stale binary, RUN-032 quarantined drains, and this one's
            resolution). The pattern is mine, not the agents'.

## RUN-034 — CHECKPOINT 1 (after A-3.5a + F-0) — PASSED. Red is entirely the designed debt

question:   §2's integration checkpoint after the first units. Is the tree sound?
ruling:     **PASSED.** `sh test/preflight.sh` exits 1, and **both failures are the designed red**
            already in `.claude/HANDOFF.md`'s table. No unexpected gate moved.
derivation: Orchestrator, on the quiescent tree at `433bcffe`, nothing uncommitted, no agent live:
            - `FAIL diff_compiler_snapshot_frontend` — **201 fixtures, 200 compared, exactly 1
              failed**: `compiler/types/typecheck.mdk` (sections SOURCE, DESUGAR, MARK). The only
              file this run has edited. Every other corpus (parse, positions, comment, stdlib,
              diff_fixtures) is 100% green.
            - `FAIL diff_compiler_selfproc` — **15 ok, 1 failing**: only `types.typecheck`. All
              twelve sibling LEG A modules match reference, and **LEG B / C / D all pass** — the
              self-hosted eval, the typed Parser-monad stage and the typed TYPECHECKER stage all
              execute correctly. That last one matters: the engine still runs its own typechecker.
            - `sh test/diff_compiler_must_fail.sh` → **98/98 reproduce, 0 drained** (RUN-033).
            - `sh test/registry_keying_ratchet.sh` → PASS, **23** CrossRun fields.
            - `make check-self` → PASS.
scope:      Blast radius is exactly the file we edited. Preflight's own footer records what it did
            NOT run (`diff_compiler_engines`, `selfcompile_fixpoint`, and 153 other gates) — it is a
            filter, not an authority, and this entry claims only what it measured.

## RUN-035 — CHECKPOINT 1 — the LEG A delta VERIFIED line by line: zero unexplained scheme moves

question:   RUN-026 promised that the moved LEG A golden would be checked, not waved at: does any
            SURVIVING binding's inferred type change?
ruling:     **No. Every one of the 8 changed lines is attributable to a named bite, and nothing
            else in 1758 lines moved.** The strongest verification this sprint's posture permits.
derivation: Orchestrator reproduced the gate's own comparison **read-only, blessing nothing** —
            ran `test/bin/check_all_main` over the same closure, extracted the `types.typecheck`
            section with the gate's own `awk` marker logic, `LC_ALL=C sort`ed both sides, and
            diffed against the committed golden (script: `/var/tmp/uf/legadiff.sh`).
            Golden 1758 lines → now 1753. Complete delta:
            **ADDED (2)** — `ceRequiredAt : RegKey -> Int -> ClassEnv -> Option (List String)`
            (A5a-2); `ceRowRequired : CeRow -> List String` (A5a-1).
            **DELETED (6)** — `declEnvsUpTo`, `declEnvsUpToGo`, `declEnvsVisible` (C-0, exactly the
            three RUN-026 predicted); `ifaceRequiredMethods` (A5a-4); `insertIfaceRequired` (A5a-5);
            `checkImplCompleteness` + `implCompletenessMsgsOf` (A5a-4's unification of the two
            checkers).
            **RE-TYPED (2)** — `checkImplCompletenessMap : Registry (List String) -> List Decl -> Unit`
            → `ClassEnv -> Int -> List Decl -> Unit`; `implCompletenessMsgsOfMap` likewise. Both are
            A5a-3's specified transform verbatim (*"takes `ClassEnv -> Int` in place of
            `Registry (List String)`"*).
scope:      **Zero unattributed hunks.** RUN-026's "expected LEG A delta" is discharged and extended:
            the predicted three deletions are present, and the five further changes are each owned by
            a bite. The standing additive-only rule is deliberately violated in the retirement
            direction, as ruled — but the property that rule protects (*no existing binding's
            inferred type silently changed*) **holds**, since both re-typings were specified in
            advance rather than discovered in the golden.
            📌 Method note: this check cost one 12-line script and no build. It is the cheap,
            available discriminator between "the golden moved because we changed things" and "the
            golden moved because something moved that we did not intend" — the two are
            indistinguishable from a red gate alone, which is exactly why a red gate is not
            evidence either way.
