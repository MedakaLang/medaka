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
