#!/bin/sh
# DICT-SEMANTICS conformance gate (docs/spec/DICT-SEMANTICS.md).
#
# Until this existed, `docs/spec/DICT-SEMANTICS.md` had NO EXECUTING GATE (#616).
# The conformance reviewer was the sole enforcement mechanism, and reviewers are
# per-PR, human-scale, and only look at the diff in front of them. That document
# accumulated FOUR independent divergences in a single day (#607/#609/#610/#614),
# three of them found by reading the spec against the source rather than by any
# test, while every gate stayed green -- because THE COMPILER'S OWN SOURCE
# CONTAINS ZERO MULTI-ARG CONSTRAINTS, so the self-hosting corpus is
# constitutionally blind to the entire class. `typecheck_compiler_source.sh` and
# the self-compile fixpoint cannot see any of it.
#
# Modelled directly on test/diff_compiler_shadow_semantics.sh, whose design
# decisions transfer wholesale (#616 item 2): the check/run/build agreement
# harness, the pin-current-behaviour discipline, the coverage self-audit, and the
# KNOWN-BAD-row-as-ledger idea are all its.
#
# ###################################################################
# # WHAT THIS GATE PINS, AND WHY THAT IS NOT THE SAME AS "CORRECT"  #
# ###################################################################
# ⚠️ THIS GATE PINS WHAT THE BINARY ACTUALLY DOES ON CURRENT MAIN, NOT WHAT THE
# SPEC SAYS SHOULD HAPPEN. A gate that asserted the spec would just be red, and a
# red gate teaches people to ignore it. Divergences are pinned WITH AN ANNOTATION
# NAMING THE ISSUE, so the gate doubles as the conformance ledger and
# SELF-DRAINS: the day a fix lands the row goes RED and whoever fixed it must
# come here and re-pin the cell.
#
# ⚠️ AND THE CONVERSE, WHICH IS THE MORE DANGEROUS HALF: A CAPTURED GOLDEN
# RECORDS WHAT THE ENGINE DID, NOT WHAT IS CORRECT. Every value in the TABLE
# below was HAND-DERIVED FROM THE SPEC FIRST, in the fixture's own header
# comment, and only then compared against the binary. Where they agree the row is
# CONFORMANT; where they disagree the row says so in its label and names the
# issue. THREE ENGINES AGREEING DOES NOT PROVE CORRECTNESS -- several known S0s
# have every engine equally wrong, which is exactly why `diff_compiler_engines`
# cannot see them. s3-min-fully-general-sibling WAS such a cell (both engines
# printing the same WRONG number at exit 0) until #1128 was fixed on 2026-08-01;
# s6-1-4-supers-per-construction-goal was one on the build arm alone until #1127
# drained on 2026-08-23. Both rows are kept, re-pinned to their hand-derived spec
# answers -- a drained row is the cheapest regression test the corpus has.
#
# ###################################################################
# # FOUR ASSERTION SECTIONS, BECAUSE VERDICTS ARE NOT ENOUGH        #
# ###################################################################
#   1. VERDICT + VALUE. `check`/`run`/`build` each ACCEPT or REJECT as the row
#      specifies; where run and build both accept, their stdouts must be
#      byte-identical to each other AND to the pinned value. §7's single-evaluator
#      law is a claim about VALUES ("two evaluators ... must agree, value-for-
#      value, on every elaborated core program"), and an exit-code-only gate is
#      blind to "build exits 0 printing a WRONG number" -- which is precisely
#      #607's build-path symptom. REJECT rows additionally pin the DIAGNOSTIC
#      CODE from `check --json`, so a row cannot pass by being rejected for an
#      unrelated reason (a typo in a fixture would otherwise grade green).
#   2. SCHEME. The exact `medaka check` scheme line for the binding under test.
#      #607's and #610's discriminating probe was the scheme, not the value:
#      both printed the RIGHT number while having SILENTLY DROPPED the
#      constraint from the type. A verdict+value row cannot see that.
#   3. EMITTED IR. `medaka build --keep-ir` and a pinned pattern over the `.ll`.
#      This is the only section that can see a DEAD DICT SLOT (#607) or an
#      arity skew (§8 I1) -- both invisible from behaviour alone -- and it is
#      what turned "I think the wrong impl is selected" into
#      `call @mdk_impl_Box_tag` on the screen for the S0 below.
#   4. DECLARATION-ORDER PERMUTATION. Sections 1-3 all pin ONE declaration
#      order per fixture and pass BY CONSTRUCTION for an ACCEPTANCE WIDENING --
#      every golden covers the order it was captured at. For any fixture with
#      >=2 `impl` blocks of one interface, reversing exactly those blocks must
#      not change `check`'s verdict, `run`'s stdout, or `build`'s stdout. This
#      needs no ground truth (DICT §3: selection is never "a function of search
#      order, declaration order, or resolution position"), which is what makes
#      it the one section that can catch "the winner is decided by order"
#      without knowing the right answer -- #1154's exact shape.
#
# ⚠️ #616 item 4 asks for the TYPED, DICT-PASSED CORE IR
# (`compiler/entries/core_ir_typed_modules_dump_main.mdk`). Section 3 uses
# `build --keep-ir` INSTEAD, deliberately: it observes the same facts (dict-param
# arity, which impl a site resolved to, which dicts were passed) on the path that
# actually SHIPS, and it needs no oracle -- so this gate has no `test/bin/*`
# staleness coupling and no `build_oracles.sh` registration. The Core-IR dump
# route is listed under NOT YET COVERED below; it would add route-kind
# (`RKey`/`RLocal`) visibility that LLVM IR flattens.
#
# ###################################################################
# # THE LEDGER -- rows pinned to a KNOWN divergence, newest first    #
# ###################################################################
# * s-instantiated-reselect-declared / -inferred / -general-sibling /
#   -unsatisfiable-rejected -- #1909 (S0, a structured single-subject `=>` context
#   committing to ONE impl at abstraction time and reusing it for every
#   instantiation) FIXED by sprint/structured-predicate-carry. Four rows because
#   the fix has two writers and two directions: the DECLARED channel
#   (`registerMember`), the INFERRED channel (`registerInferredFor`) which OD6(a)
#   binds to the same answer, the general-sibling row that catches an
#   OVER-NARROWING fix, and the reject tripwire that catches a fix which bought
#   its acceptance by loosening admission. #1909 had NO must_fail pin, so these
#   are the only guard it has ever had. Each measured at base `bffced42` and at
#   the slice head; the per-row values are in the TABLE labels and each fixture`s
#   own header.
#   ⚠️ THE BASE ARM FOR THESE ROWS NEEDS BOTH BASE BINARIES. `medaka build` shells
#   out to `<exeDir>/medaka_emitter` (`defaultMedakaEmitter`,
#   compiler/driver/build_cmd.mdk), which a head `make medaka` OVERWRITES -- so a
#   base `./medaka` alone reports the HEAD emitter`s answer in its build column
#   and every one of these rows reads FIXED at base. Measured that way first, and
#   it manufactured a false engines-disagree finding. Set MEDAKA_EMITTER to a
#   saved base emitter, or give the base arm its own tree.
# * s4-2-mixed-vector-no-impl-rejected / s4-2-inferred-ground-arg-predicate-
#   checked / s4-2-dedup-collision-check-not-skipped / s3-ground-requires-chain-
#   depth-34 -- FOUR S0s (#1578, #1905, #1330, #1576) FIXED by
#   sprint/entailment-verdict, arriving here as REPLACEMENT GUARDS rather than as
#   drains of an existing row. Recorded together because the reason they exist is
#   one reason, and it is a process failure worth not repeating: that sprint
#   deleted three self-draining `must_fail` pins per [G-PIN-DRAIN] and added
#   NOTHING in their place, and the fourth (#1905) never had a pin at all. The
#   whole sprint diff contained no fixture, no gate case and no doctest, so all
#   12 CI checks were green at its head while the four S0s had zero regression
#   coverage between them. A pin asserts a bug STILL REPRODUCES; a fix therefore
#   DELETES it, and the guard leaves with it unless someone writes the positive
#   row. These are those rows. Each was verified RED at the pre-sprint arm
#   `264eb95d` (built by checking that commit's compiler/types/typecheck.mdk --
#   the only compiler source file the sprint touched -- over this tree and cold-
#   rebuilding) and GREEN at the sprint head; the per-row measurements are in the
#   TABLE labels and in each fixture's own header.
#   ⚠️ THREE OF THE FOUR PRE-SPRINT FAILURES WERE SILENT ON THE VERBS THAT SHIP:
#   #1905 ran to completion in the built binary printing 222 with every verb at
#   exit 0; #1330 and #1576 exited 0 from `check` AND `build` and SEGFAULTED at
#   139 when the binary was executed. Only #1578 had a loud verb. This is why the
#   §4.2 punch-list entry below insists a fixture family for that subsection has
#   to assert REJECTION of specific shapes.
#   ⚠️ NOT CARRIED, AND SAY SO RATHER THAN QUIETLY OMIT: the ACCEPT-direction
#   controls that shipped inside the deleted pins (#1330's `Color` WITH a Display
#   impl, #1576's 33-deep twin) are green at BOTH arms, so they cannot regress-
#   test these fixes and are not regression rows. They would be over-rejection
#   guards -- a different job, and a real gap. Their sources are in the git
#   history of test/must_fail_fixtures/.
# * 1386-alias-qualified-obligation-checked / 1276-alias-run-arm-obligation-
#   checked / 1386-alias-reproB-standalone-collision-rejected -- #1386 and
#   #1276 are FIXED (S-alias-supply, sprint/alias-provenance) and BOTH rows
#   arrive here as DRAINS, re-pointed from `test/must_fail_fixtures/1386-…`
#   and `…/1276-…` per [G-PIN-DRAIN]: a pin asserts a bug STILL REPRODUCES,
#   so draining it removes the guard unless a positive row replaces it. Fix:
#   `compiler/types/typecheck.mdk` now supplies an `A.<method>` ->
#   declaring-`Ident` entry for every method an aliased module exports
#   (`aliasQualifiedMethodEntries`/`aliasMethodKeysFor`/`aliasMethodKeyRows`,
#   wired into `checkBodyImpl`'s Module arm), so `recordImplObligation` now
#   sees an alias-qualified occurrence and checks it against the interface
#   the alias actually names, instead of never recording an obligation (or,
#   for #1276, falling through to a bare-name collision table that lost the
#   alias's provenance). Both now REJECT with `No impl of IA for Blob; write
#   an 'impl IA Blob'.` on check/run/build alike, where base silently
#   accepted (#1386) or silently ran the wrong impl's body (#1276, printing
#   `2` instead of rejecting). The third row is Repro B (#1386's own
#   why-note (1) candidate, constructed fresh -- no committed must_fail
#   fixture existed for it): an alias occurrence colliding with an UNRELATED
#   standalone of the same bare spelling in a third module. It discriminates
#   the SUPPLY fix actually landed (rejects here too) from a de-alias-rewrite
#   fix (which would have left this cell silently running the standalone's
#   body). See test/must_fail_fixtures/ commit history for the pins' own
#   claim.txt (mechanism, MEASURED pre-fix behaviour, hand-derived answers).
# * 1182-alias-dispatch-half-known-bad -- 🚨 A DIFFERENT, PRE-EXISTING gap
#   (#1182/#1265 class, OPEN) -- NOT drained by S-alias-supply and NOT
#   touched by its fix. That fix repairs the CHECKED half (does an impl
#   obligation exist); this pins the DISPATCH half (which impl's body
#   actually RUNS) still disagreeing with it for an alias-qualified
#   occurrence. `Blob` implements both `IA` and `IB`; `A.mth Blob` and
#   `B.mth Blob` name two DIFFERENT interfaces and must print 1 then 2.
#   OBSERVED (still, on this binary): 1 then 1 -- `renameAliasedMethods`
#   erases the alias to a bare `mth` before dispatch is decided, so both
#   calls collapse onto the same (first-declared) impl. Confirmed identical
#   at both the pre-sprint merge-base `9824e65b` and the sprint head
#   (F-fix-alias-collision's report, Note N1) -- neither this sprint's fix
#   nor the alias-collision fix caused it. KEPT AS A KNOWN-BAD LEDGER ROW,
#   pinning the CURRENT (wrong) value rather than a REJECT: this program is
#   accepted and runs to completion on every verb, so there is no exit code
#   to assert against. A value change here is the signal to re-pin, not a
#   regression in this gate.
# * s3-fn-typed-impl-heads-discriminated / s3-effect-carrying-impl-head-routes --
#   #1617 (S0) and #1618 (S1) are FIXED and BOTH rows arrive here as DRAINS, from
#   `test/must_fail_fixtures/1617-…` and `…/1618-…`. Recorded together because they
#   are two members of ONE arm set -- `headTyconTy`'s `_ => None` wildcard in
#   compiler/types/typecheck.mdk -- and the set is NOT finished, which is the whole
#   reason they were re-pointed here rather than deleted:
#     - #1617 (TyFun heads): every stage AGREED on None, so two function-typed heads
#       shared one `noneHeadTag` bucket and DECLARATION ORDER decided the value at
#       exit 0 with `check --json` clean. Fix: give `TyFun` a head tag.
#     - #1618 (TyEffect head): the two projections DISAGREED -- typecheck answered
#       None, eval and `core_ir_lower` STRIPPED the effect to the inner head -- so
#       `check` and `run` were correct and only `build` died, on a program with one
#       impl and nothing to be ambiguous about. Fix: reconcile the projections.
#     - #1180 (bare `TyVar`) is the arm where None is the DOCUMENTED INTENT; that
#       program must be REJECTED and neither fix repairs it.
#     - #1630 (FIXED; was OPEN when the two rows above landed) is the SAME arm set
#       at a headed `TyConstrained` body. Fix: one more arm on the same node walk,
#       `headTyNode (TyConstrained _ t) = headTyNode t`. It has THREE rows below,
#       and they grade three different channels:
#         `s3-constrained-impl-head-routes` -- ONE impl, `Eq a => Int`. Pre-fix
#           `check=0 run=0 build=1`, byte-identically to #1618. Load-bearing cell:
#           build.
#         `s3-constrained-effect-impl-head-routes` -- `Eq a => <Stdout> Int`. Exists
#           because a fix special-casing the reported shape `TyConstrained cs
#           (TyCon …)` would green the first row and RED this one.
#         `s3-constrained-headed-impl-vs-plain-sibling` -- TWO impls. The SILENT-
#           WRONGNESS channel neither of the others can see, and the reason
#           `check=0 run=0 build=1` must NOT be read as a statement about the class:
#           that cell triple is a property of ONE IMPL. Measured on a base arm built
#           from the fix branch with the peel deleted, `impl Sz (Eq a => Box Int)`
#           beside `impl Sz (Box Bool)` printed 26 in one declaration order and 28
#           in the reverse, at exit 0 with `check` clean. Spec answer 27. So the
#           class reaches S0 and #1630's S1 grades its REPORTED shape, not the
#           class. Section 4 permutes this row; the other two have one impl each.
#       🚨 THIS ENTRY IS ALSO THE ARM SET'S OWN WARNING AGAINST BOUNDING A CLASS
#       FROM ONE EXAMPLE. PR #1629's commit `e051788b` -- in its commit body and in
#       the `eval.headTycon` comment it landed -- declared `TyConstrained` "measured
#       benign … peeling it yields a headless body", and this file recorded the
#       class as "NOT finished" on that basis. (#1617/#1618 are ISSUES and have no
#       commit bodies; cite the PR's commits.) Both true of `Eq a => a` and false of
#       `Eq a => Int`. The wrapper never decided headedness; the body did. So read
#       "the set is not finished" as still live: it is what has been enumerated, and
#       the enumeration has now been wrong once in each direction.
#   ⚠️ THE TWO ROWS DISCRIMINATE ON DIFFERENT CELLS, and reading either as a plain
#   value pin makes it vacuous. #1617's value cell passes BY CONSTRUCTION on the one
#   declaration order it was captured at -- its real assertion is Section 4, which
#   derives this file automatically because it is a FLAT `.mdk` with two `impl Sz`
#   blocks. #1618's `check` and `run` cells were ALREADY CORRECT while the bug was
#   live -- its real assertion is the `build` cell that `ALL_EXACT` forces to agree.
# * s6-1-4-supers-per-construction-goal -- #1127, DRAINED 2026-08-23 by
#   S-predicate-representation (#1177's fix). What follows is the HISTORY the row
#   pinned; the row itself is now `ALL_EXACT 77\n77`, per its fixture header's own
#   drain instruction, and its Section 4 KNOWN-BAD permutation entry is GONE (the
#   two build values converged, which is what that entry existed to detect).
#   WAS: SILENT WRONGNESS ON THE BUILD PATH. A §3 `super` projection out of a general `C`-instance
#   constructed at a GROUND goal reaches the GENERAL `D`-dict, not the
#   most-specific one: `check` exits 0, `run` prints the correct 77/77, and the
#   SHIPPED NATIVE BINARY prints 20/77. §6 C2 names this exact break ("a
#   super-projection that reaches a general `D`-dict while an independent
#   top-level goal `D τ̄` resolves to a specific one"), and §6.1.4 names the
#   mechanism ("pre-resolving a polymorphic instance's supers once, against its
#   general head, at declaration"). Both arms are in ONE program, so they
#   disagree inside one binary. Control: s6-1-4-direct-constraint-control
#   declares `D a` DIRECTLY (so `assum` reaches the dict instead of `super`) and
#   native is correct -- localising the defect to the superclass arm. DISTINCT
#   from #412 (CLOSED, S0), which was the impl-`requires` arm of the same §6.1.4
#   family; #412's own repro was re-run on this binary and is correct.
#   ⚠️ This is the row the whole gate justifies: `run` and `build` share the
#   entire front end, so their DISAGREEMENT is a real observation about codegen,
#   and no existing gate drives this shape.
#   🔗 Section 4 (declaration-order permutation) finds a SECOND symptom of this
#   same mechanism: reversing the fixture's three `D` impl blocks flips the
#   BUILD arm from the wrong 20 to the right 77 while `run` stays 77/77 either
#   way -- i.e. #1127 is ALSO order-sensitive on the path Section 4 grades.
#   Pinned there as a KNOWN-BAD permutation row rather than silently excluded.
# * s3-min-fully-general-sibling -- #1128 (S0 `verified`) is FIXED and this row
#   HAS DRAINED (F-3b, 2026-08-01). Kept in the ledger as the worked example of a
#   self-drain, because the shape of the fix is the useful part:
#     WAS: a fully general `impl Tag a` beside `impl Tag (Box Int)` made EVERY
#     `Box`-headed goal call the `Box Int` impl -- `tag (Box "s")` printed 99
#     where 10 is correct, on check (exit 0, no diagnostic), on run, and on the
#     shipped binary.
#     MECHANISM: a bare-type-variable head has no head tycon, so `keyEntryOf`
#     emitted NO `KeyEntry` for it. The general impl was never COLLECTED into the
#     registry the goal searches -- it could not be out-ranked, only missed.
#     FIX: register it under `noneHeadTag`, union that bucket into every goal-head
#     lookup (merged on declaration index, not concatenated), and let `keyForSite`
#     return the winner's own head tag instead of `None`, which was throwing the
#     correctly-selected candidate away one line later.
#   ⚠️ The first two thirds of that fix, WITHOUT the third, are INERT -- two
#   independent agents built them and this row never moved. If you are re-deriving
#   this area, that is the trap: a headless winner is selectable long before it is
#   routable.
#   🔗 #1113 (ARCH B-2) still owns the deeper form -- §11's arg-tag row names the
#   same bare-head-tycon granularity one layer down, in eval's
#   `runtimeTypeTag`/`filterByTag` RUNTIME fallback, where this fixture's site is a
#   DIRECT call decided at elaboration. F-3b did NOT retire the head-tag hedge in
#   `keyForSite`; it only stopped it lying about the selected instance.
# * s3-nested-obligation-two-levels -- #323 (OPEN, S3). At nesting depth >= 2
#   under overlap the RUN path E-PANICs `unknown op '+'` while `check` and the
#   NATIVE binary are both correct (119). A §7 single-evaluator-law violation.
#   Its no-overlap control (s3-nested-no-overlap-control) proves eval handles
#   depth-3 recursive context discharge fine, so the trigger is the overlap.
#   ⚠️ #323's filed BUILD-side symptom ("silent garbage") does NOT reproduce.
# * s6-1c-per-goal-unique-min-accepted -- #614 (S2) / #311 (S3) are FIXED and this
#   row HAS DRAINED (F-3d, 2026-08-01). Kept in the ledger as the worked example of
#   an ACCEPTANCE WIDENING, because that direction has its own trap:
#     WAS: the declaration-time coherence sweep enforced §6.1 condition (a) (global
#     pairwise comparability) where the spec commits to (c) (per-goal unique
#     minimum), so the §6.1 separating case -- `C (Pair Int a)`, `C (Pair a Int)`,
#     `C (Pair Int Int)` -- was rejected at the SECOND `impl`. Sound, but an
#     over-rejection: the third impl is the unique ⊑-minimum at the goal.
#     FIX: classify the pairwise sweep instead of deleting it. A ⊑-INCOMPARABLE pair
#     becomes a `W-INCOMPARABLE-IMPLS` warning (the "MAY additionally warn at
#     declaration time … but acceptance is per-goal" §6.1 licenses); acceptance moves
#     to the goal-site min⊑ reject F-3c installed.
#   ⚠️ THE TRAP, and it is the mirror image of #1128's: **every existing golden
#   covers the old, NARROWER behaviour, so all of them pass by construction on an
#   over-widening.** Section 1 cannot see a program that newly compiles unless
#   someone writes the row. The two checks that CAN: the ACCEPT rows' `!`-negated
#   codes (a positive-only pin cannot tell "(a) was demoted" from "(a) was deleted"),
#   and Section 4, which needs no ground truth at all.
#   ⚠️ WHAT DID **NOT** WIDEN: two MUTUALLY-⊑ (α-equal) heads still hard-reject.
#   They SATISFY (a) -- §6.1.2's ⚠️ records that the ladder breaks exactly there,
#   **(a) ⇏ (c)** -- so they were never (a)'s to demote, and `entryCovers` makes
#   equal heads cover each other, so the goal-site reject cannot see them either.
#   s6-c1-duplicate-heads-rejected is that control.
#   s6-1c-incomparable-no-minimum-control remains the discriminating control, with
#   its argument INVERTED: it used to show that adding the ⊑-minimum changes nothing;
#   it now shows that adding it flips the sibling to ACCEPT.
# * s6-2-t4-open-goal-deferred -- #1183 (OPEN, S1 `verified`). The residue F-3d made
#   user-reachable: at a NON-CLOSED goal the min⊑ arm still COMMITS to the head of
#   the candidate list, so declaration order decides the value at exit 0 (1 vs 2)
#   under a warning rather than in silence. §6.2 T4 says defer to quiescence; there
#   is no quiescence pass (§11's T3/T4 row). Pinned as a KNOWN-BAD row in BOTH
#   Section 4 ledgers (run and build) -- and the run-arm ledger was ADDED for it,
#   since `RUN-DIFF` previously had no known-bad branch at all.
# * s4-gen-rec-inferred-asymmetric -- #1133 (OPEN, S1 `verified`). LOUD BREAKAGE.
#   An INFERRED
#   mutually-recursive group in which only ONE body dispatches on the class:
#   `check` accepts AND reports both schemes correctly as `Sz a =>`, then NEITHER
#   engine will execute it -- `run` E-PANICs `unbound identifier:
#   $dict_evenSz_0`, `build` dies `unbound dict witness '$dict_…__evenSz_0' in
#   emit env (dict not threaded to this site)`. So the type level agrees with §4
#   `gen-rec` (the group shares one dict prefix) and the elaboration does not
#   thread it -- §4's own named failure mode, caught one step before it could be a
#   wrong value. Two controls in the corpus isolate the trigger to INFERRED +
#   MUTUAL + ASYMMETRIC: the ascribed twin runs, and the symmetric inferred row
#   runs. Mirror-checked (swapping which body dispatches fails symmetrically).
#   FOUND BY FIXING AN INERT ASSERTION -- the symmetric row used to claim it
#   discriminated group from per-binding sourcing, which it could not; making the
#   discriminator real is what exposed this.
# * s5-phantom-determined-use-rejected -- #1134 (OPEN, S3 `verified`).
#   OVER-REJECTION. Inside
#   `useBoth : Mk a => a -> Int` the `Mk a` dict is in scope over a RIGID `a`, so
#   §3 `assum` discharges the goal and §5 `(method)` projects: the spec ACCEPTS
#   and prints 7. The checker rejects at the interface/impl DECLARATION and never
#   looks at the use site. Paired with s5-phantom-ambiguous-use-rejected (which
#   BOTH spec and impl reject) this shows the implementation rejects a strict
#   SUPERSET of what the spec does -- the pair is what makes the finding land.
#   ⚠️ PINNED TO #1134 (BEHAVIOUR), NOT #1107 (d) (SPEC), and that distinction is
#   worth keeping because an earlier revision got it wrong: #1107 is "ARCH S-2:
#   write the owed spec paragraphs" and its paragraph (d) is this finding
#   verbatim -- but it is SPEC-ONLY WITH NO BEHAVIOUR CHANGE, so a REJECT row
#   pinned to it would stay green through its entire lifetime and then go stale
#   silently. A self-draining pin that cannot drain is worse than no pin.
#   ⚠️ #1107 (d)'s TWO RESOLUTIONS MOVE IN OPPOSITE DIRECTIONS: narrowing the
#   checker closes #1134 as a FIX and reds this row (automatic, re-pin to ACCEPT
#   7); forbidding phantom methods in §5 closes #1134 as WORKING-AS-INTENDED,
#   reds nothing, and needs this row plus its sibling relabelled BY HAND. The
#   second case cannot be automated and is recorded on #1134 itself.
#
# ###################################################################
# # NOT YET COVERED -- an honest punch-list, not a silent gap        #
# ###################################################################
# The corpus covers §1, §2 (method-level `Q_m`), §3 (selection/`assum`/`super`/W1/
# W3-type-axis incl. the DEFAULT-body half), §4 (`gen`/`gen-rec`/`gen-sig`), §5
# (result + phantom + arg-tag), §6/§6.1 (C1/C2/choice-points 2,3,4), §8 (I1 incl.
# dict-param ORDER, I2, I3), §9 (signature authority, vector-valued entailment)
# and, as of Section 4, §3's DECLARATION-ORDER-FREEDOM clause for every
# single-file fixture with >=2 impls of one interface (#1154/#1155). It does
# NOT yet cover:
#   * 🚨 Section 4 permutes `impl` BLOCKS. It does NOT permute the PREDICATE ORDER
#     IN A SIGNATURE, and nothing else in the tree does either -- so that axis of
#     DICT §3's order-freedom clause is untested by construction, and no fixture
#     added to this corpus can reach it. That is not hypothetical: #1177 (S0,
#     verified) is exactly this shape -- `(Dbg a, Ix a Char) => ...` prints 116
#     where `(Ix a Char, Dbg a) => ...` prints 227, same program, both engines,
#     check clean -- and it survived a PR (#1176) whose entire subject was
#     order-freedom, because this section could not see it. Pinned meanwhile at
#     test/must_fail_fixtures/1177-sig-predicate-order-decides/. Closing #1177
#     should either add a second permutation strategy here (reverse the predicates
#     of a `=>` context the same way the block permuter reverses impls) or record
#     why not. ⚠️ A permutation differential is only order-free along the axis it
#     actually permutes -- do not read section 4's green as "order does not decide".
#   * 🚨 §4.2 (OBLIGATION DEFERRAL, OD1-OD6) IS NO LONGER ENTIRELY UNCOVERED, BUT
#     IT IS STILL MOSTLY UNCOVERED. Six normative clauses landed in this spec
#     (#1114) and for a long time this gate did not move at all. That gap is
#     STRUCTURAL, not an oversight of one PR: this file's self-audit fails for an
#     unwired FIXTURE, never for an unfixtured CLAUSE, so a whole subsection can be
#     added to DICT-SEMANTICS.md and nothing here goes red.
#     WHAT EXISTS NOW -- three `s4-2-*` rows, added 2026-08-25 by
#     FIX-3-regression-fixtures (sprint/entailment-verdict) as the replacement
#     guards for three S0s whose `must_fail` pins that sprint DELETED per
#     [G-PIN-DRAIN] without replacing them:
#       - OD5/OD6 dedup: s4-2-dedup-collision-check-not-skipped.mdk (#1330, now
#         FIXED). Deduplication may suppress the REPORT of a duplicate obligation,
#         never the CHECK. Was: five prelude-only lines, `check` 0, `build` 0,
#         binary SEGFAULTS at 139.
#       - deferral of a MIXED argument vector:
#         s4-2-mixed-vector-no-impl-rejected.mdk (#1578, now FIXED).
#       - deferral of an inferred binding's GROUND predicate argument:
#         s4-2-inferred-ground-arg-predicate-checked.mdk (#1905, now FIXED).
#     WHAT IS STILL UNCOVERED: OD1-OD4 have no fixture of their own, and the three
#     rows above grade the REJECT direction only -- each one's ACCEPT-direction
#     control (the same shape WITH a satisfying impl) is green on both arms and so
#     was deliberately not carried, which leaves an over-rejecting tightening of
#     this channel ungraded here. OD6's other residual, #1326 and its `run`-only
#     face, is untouched; see the §11 OD6 row.
#     OD1's own history is the argument for covering this section rather than
#     trusting it: its first implementation passed every gate in the tree while
#     dropping a decidable predicate, because a DROPPED obligation produces SILENCE
#     and silence is what a golden already records for an accepted program. A
#     §4.2 fixture family therefore has to assert REJECTION of specific shapes; a
#     corpus of accepted programs cannot see this class at all. That is exactly the
#     form the three rows above take.
#   * Section 4 tests exactly ONE reordering per qualifying fixture -- a full
#     reversal of the qualifying blocks -- not all N! declaration orders. For
#     N=2 that IS the only nontrivial permutation; for N=3 (the corpus's max
#     today) it swaps the first and last block and leaves the middle fixed, so
#     an order-sensitivity that depended on adjacent-pair position rather than
#     first/last would not be caught. Adding a genuine 3-cycle would need a
#     second permutation strategy, not just a bigger corpus.
#   * Section 4 is scoped to files directly in `test/dict_fixtures/*.mdk` --
#     directory-based multi-file fixtures (`s8-i1-samename-independent-dict-arity/`
#     and siblings) are excluded; none of them currently has >=2 impls of one
#     interface in a single file, so nothing is silently skipped today, but a
#     future multi-file fixture with that shape would need its own handling
#     (which file's impl blocks to reorder is not derivable the same way).
#     Directories don't match the `*.mdk` glob at all, so they are excluded by
#     construction rather than by an exclusion list.
#   * §2 -- the dictionary RECORD SHAPE itself (a `supers` field vs a flat
#     impl-key). Only its observable consequences are pinned; asserting the
#     representation needs the Core-IR dump probe. ⚠️ This exclusion is about the
#     `{methods, supers}` LAYOUT only -- §2's method-level-constraint exception is
#     behaviourally observable and IS covered, by
#     s2-method-level-constraint-abstract.
#   * §3 W2 -- instance-resolution termination (the Paterson/coverage-style
#     condition). No fixture drives a diverging instance context. ⚠️ Per §11's own
#     W2 row there is no static check to gate anyway -- what exists is a dynamic
#     depth-32 cutoff -- so a fixture here would pin the cutoff, not the clause.
#   * §3 W3 EFFECT axis, and the whole graded-interface (`Deferred*`) paragraph
#     including its two verified S0s (#1094, #1095). That is
#     EFFECTS-SEMANTICS' §6 to gate; only the TYPE axis is pinned here -- but note
#     BOTH of its sites now are (impl body AND interface default body).
#   * §6.1 choice-point 1 -- specificity compares heads only, not contexts. No
#     fixture declares two α-equal heads with different contexts.
#   * §6.1 condition (b) -- per-goal TOTAL order, the middle of the three. Only
#     (a)-vs-(c) is separated.
#   * §6.2 T3/T4's NON-CLOSED half is COVERED as of the s6-2-t3/s6-2-t4 pair, and
#     as of F-3d that pair decides a VERDICT: the closed half rejects, the open half
#     ACCEPTS AND RUNS. F-3c's goal-site T-AMBIGUOUS-INSTANCE is gated on the goal
#     being CLOSED, because T4 defers a goal carrying an unbound metavariable rather
#     than deciding it; the negative code assertion on the open half is retained
#     because verdict alone cannot attribute the sibling's reject to the min⊑ arm.
#     ⚠️ AN EARLIER REVISION OF THIS BULLET SAID THE GATE WAS "UNTESTABLE" on the
#     grounds that a ⊑-incomparable user pair is rejected at the declaration. That
#     was true and it was not a reason: errors ACCUMULATE, a declaration-time reject
#     is not an early exit, and both impls still reach the selector. The refutation
#     was already in this file's own corpus (conflicting_impl_overlap carries both
#     codes). ⚠️ A SECOND PREDICTION IN THIS BULLET WAS ALSO WRONG: F-3d does NOT
#     "remove the coherence reject" -- it DEMOTES condition (a) to a warning and
#     leaves the α-equal class a hard error, per the 2026-08-01 owner decision.
#     What is NOT covered is the residue that widening exposes: at the open goal the
#     arm still COMMITS by declaration order (#1183), pinned as a KNOWN-BAD row in
#     Section 4 rather than asserted correct.
#   * 🚨 Section 4 permutes `impl` BLOCKS WITHIN ONE FILE, so it is STRUCTURALLY
#     BLIND to the user-vs-PRELUDE overlap class -- exactly the class F-3c exists
#     to catch. Each `s6-c1-rigid-goal-*` fixture has ONE user impl, because its
#     competitor is `stdlib/core.mdk`'s; there is no second block to permute and
#     the prelude's declaration index cannot be moved from a fixture at all. So
#     section 4 reporting order-freedom says nothing about whether a PRELUDE impl's
#     position decides the answer -- which is the shape #1162 and this stage's own
#     flagship fixture are about. Covered here only by the verdict rows.
#   * §7 -- the WASM engine. Every row drives check/run/build; wasm is a third
#     refinement the single-evaluator law also binds.
#   * §4 `gen` for a LOCAL (`let`/`where`) constrained binding, as opposed to a
#     top-level one. See #1052 (the local-dict pin is itself unsound).
#   * The typed dict-passed Core-IR route kinds (`RKey`/`RLocal`, `CDict`), per
#     the note above.
#   * `run`'s STDERR on any row. The harness grades `check`'s diagnostic code (from
#     `check --json`) and every engine's stdout and exit code, but has no way to
#     assert a RUNTIME panic's signature -- so a row whose pinned failure is a
#     `run`-time E-PANIC pins the exit code and the stdout reached, never the
#     reason. Filed as #1130; s3-nested-obligation-two-levels is the row that
#     currently pays for it and says so in its own header.
# Adding any of these is mechanical: drop a fixture in test/dict_fixtures/ and
# wire a row. The coverage self-audit below FAILS until you do, by design.
#
# Usage:  sh test/diff_compiler_dict_semantics.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/dict_fixtures"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir: $FIXDIR"; exit 2; }

# Every invocation is bounded: DICT-SEMANTICS W1/W2 are DECIDABILITY conditions,
# so a regression to a looping `super`-search or a diverging instance context
# must surface as a row FAILURE, not as a hung CI job.
bound() { perl -e 'alarm 60; exec @ARGV' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/v0"; : >"$TMP/v1"; : >"$TMP/v2"; : >"$TMP/v3"; : >"$TMP/v4"; : >"$TMP/v5"

# ── Section 1 table ───────────────────────────────────────────────────────────
# entry (relative to FIXDIR) | label | exp_check | exp_run | exp_build | mode | value | code
#   exp_* in {ACCEPT, REJECT} -- ACCEPT means exit 0, REJECT means nonzero exit.
#   mode in:
#     NONE        -- no stdout assertion (nothing ran to completion)
#     ALL_EXACT   -- run and build both ACCEPT: their stdouts AND the pinned
#                    `value` must all be byte-identical (§7 value agreement +
#                    ground-truth pin)
#     BUILD_EXACT -- build's stdout is asserted against `value` (used where run is
#                    expected to REJECT but build to ACCEPT with a specific value
#                    -- a check/build-agree-run-diverges split). `value` MAY be
#                    written `<run-stdout>%%<build-stdout>`, in which case the
#                    stdout `run` emitted before dying is ALSO asserted, pinning
#                    how far execution got. ⚠️ Reach point, not reason: `run`'s
#                    stderr cannot be graded (#1130).
#     SPLIT_EXACT -- KNOWN-BAD ledger for a §7 single-evaluator-law violation
#                    where BOTH engines accept and DISAGREE. `value` holds two
#                    expectations separated by `%%`: run's stdout, then build's.
#                    Both are asserted exactly, AND they are required to DIFFER
#                    -- so the row goes RED the day the engines converge (which
#                    is the drain) instead of silently absorbing the fix. This
#                    mode exists because the shadow gate has no cell for it: its
#                    ALL_EXACT assumes agreement, and a NONE row here would
#                    report `ACCEPT ACCEPT ACCEPT` over a shipped wrong value.
#   value uses literal backslash-n for embedded newlines (expanded via printf %b).
#   code = the diagnostic code(s) `check --json` must report -- a COMMA-SEPARATED
#     list, each entry optionally prefixed `!` to assert the code is ABSENT --
#     or empty for no code assertion. A REJECT row WITHOUT a code cannot tell
#     "rejected for the specified reason" from "rejected because the fixture has a
#     typo". The `!` form exists because two fixtures can share a verdict, an exit
#     code and a stdout and differ ONLY in a diagnostic one of them must not emit
#     (the #1155 closedness pair); without it that pair is inert.
TABLE='s1-nary-predicate-enforced.mdk|§1/§4 an n-ary predicate is ONE joint obligation: an unsatisfiable `Ix String Bool` is a located reject (#607 regression pin -- was exit 0 + a run-time panic)|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s1-nary-predicate-scheme-kept.mdk|§1/§4 the positive half: a satisfied 2-ary constraint dispatches (scheme asserted in section 2)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3|
s3-min-subsumes.mdk|§3 `inst` selects min⊑(match(IE,π)): `impl Default Int` beats `impl Default a` DESPITE being declared second (#609 regression pin -- first-match would print 0)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|1|
s3-nary-requires-goal-vector.mdk|§1/§3 `match(IE,C τ̄)` is ONE φ against the WHOLE vector: a nested `requires Ix a Char` at `Sh (Box Int)` has the SINGLETON matching set {`Ix Int Char`}, so `Ix Int Bool` never reaches the selector at all (#1154 regression pin -- the arg-0-only fallback made both match, they were incomparable, and DECLARATION ORDER printed 111 at exit 0 on both engines). Section 4 permutes it too. ⚠️ SINGLE-entry `requires`, the arity at which route order and dict-slot order cannot disagree -- the multi-entry row below raises it. ⚠️ Pins the `requires` leg ONLY; the `=>`-constrained-signature leg of the same defect is #1161, whose ROUTING half F-3a-ii fixed and whose row is s3-nary-sig-constraint-goal-vector below|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|222|
s3-nary-requires-multi-entry.mdk|§1/§3 the same judgement at a TWO-ENTRY `requires Dbg2 a, Ix a Char`: the second obligation grounds to `Ix Int Char` and its matching set is again the singleton, so 222+5=227 (pre-fix this printed 116). ⚠️ THE MULTI-PARAMETER PREDICATE IS LAST HERE, WHICH IS WHY THIS ROW WAS GREEN WHILE ITS SIBLING WAS NOT -- an impl-`requires` body read whichever slot was registered LAST, so the last entry came out right by accident. Keep the clause as written; the OTHER ordering is now graded beside it|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|227|
s3-nary-requires-multi-entry-swapped.mdk|§1/§3 THE SAME TWO-ENTRY `requires` WITH THE ENTRIES SWAPPED (`requires Ix a Char, Dbg2 a`) -- the #1154 RESIDUAL, DRAINED 2026-08-23 by S-obligation-nary-payload and re-pointed here from test/must_fail_fixtures/1154-multi-entry-requires-decl-order-decides per [G-PIN-DRAIN]. Reordering the entries changes no program meaning, so this row and the one above must agree: 227 both ways. It printed 116 for exactly as long as the two files disagreed. ⚠️ NOT a goal-vector or routing defect -- the routes were already correct at every position; the loss was WHICH DICT SLOT THE BODY READ (`activeDictVars` keyed on the tyvar id, which both entries share, first-match = LAST registered). Fixed by `implReqDictVarOf`, the impl-`requires` twin of #1177`s predicate-keyed resolution. Section 4 permutes the two `impl Ix` blocks too|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|227|
s3-nested-obligation-most-specific.mdk|§2 uniformity + §3 `inst`/`assum`: the nested `requires` obligation of the general instance resolves MOST-SPECIFICALLY at the construction goal (the #203 shape from §3`s own worked example)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99\n109|
s3-nested-obligation-two-levels.mdk|§2/§7 LEDGER #323 (OPEN): at nesting depth >=2 under overlap `run` E-PANICs `unknown op ‘+’` while check and the NATIVE binary are correct (7 then 119). build`s value is pinned because it is RIGHT; run`s pinned stdout is the `7` SENTINEL it emits before dying, which pins that it reached the failing line rather than falling over earlier. ⚠️ REACH POINT, NOT REASON -- run`s stderr is ungradeable (#1130), so a different fault on the same line would still pass. The row drains when run stops panicking|ACCEPT|REJECT|ACCEPT|BUILD_EXACT|7%%7\n119|
s3-nested-no-overlap-control.mdk|CONTROL for #323: identical depth, overlapping impl REMOVED -- eval handles depth-3 recursive context discharge fine (31), so #323`s trigger is the OVERLAP, not the depth|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|31|
s3-min-fully-general-sibling.mdk|§3 `inst` = min⊑(match) WITH A FULLY-GENERAL SIBLING -- the #1128 DRAIN (F-3b). `impl Tag a` beside `impl Tag (Box Int)`: goal `Tag (Box Int)` matches BOTH and min⊑ takes the concrete one (99); goals `Tag (Box String)` / `Tag (Box Bool)` match the general one ALONE, because no substitution makes `Box Int` into `Box String` (10, 10). This row pinned the WRONG 99/99/99 until 2026-08-01; the value below is the SPEC answer the fixture`s own header hand-derived before the fix existed, not a recapture of what the engine started doing|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99\n10\n10|
s3-fn-typed-impl-heads-discriminated.mdk|§3 `inst` DISCRIMINATES TWO FUNCTION-TYPED IMPL HEADS -- the #1617 DRAIN, and the third member of the `noneHeadTag` family after #1128 above and #1154 below. `impl Sz (Int -> Int)` beside `impl Sz (Bool -> Bool)`: `headTyconTy`s `_ => None` arm swallowed `TyFun`, both heads shared the ONE `noneHeadTag` bucket, and the value was decided by DECLARATION ORDER at exit 0 with `check --json` clean -- this ordering printed `(5, 5)`, the reversed one `(9, 9)`, and `build` exited 1 with `arg-tag dispatch on impl type that owns no constructors`. `(5, 9)` is the SPEC answer the fixtures own header hand-derived from the two signatures, not a recapture. ⚠️ THE VALUE CELL IS ONLY HALF THIS ROW: the defects signature was ORDER-DEPENDENCE, which a single-order value pin passes by construction, so the discriminating half is Section 4 -- this file is a FLAT `.mdk` with 2 impls of one interface precisely so the permuter derives it|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|(5, 9)|
s3-effect-carrying-impl-head-routes.mdk|§3 head projection + §7 single-evaluator law at an EFFECT-CARRYING impl head -- the #1618 DRAIN. ONE interface, ONE `impl Sz (<Stdout> Int)`, ONE call: `typecheck.headTyconTy` answered None for the `TyEffect` head while eval`s and `core_ir_lower`s `headTycon` STRIPPED the effect to `Int`, so the front end resolved a call the EMITTER then could not find -- `check` 0 and `run` 2 were both already CORRECT and `build` exited 1 with `no impl of method ‘sz’ for type ‘__none__’`. ⚠️ THE LOAD-BEARING CELL IS **build**, not the value: check and run pass on a compiler that still has this bug, and it is `ALL_EXACT`s requirement that build ACCEPT with stdout byte-identical to run`s and to the pinned 2 that makes the row discriminate. ⚠️ ONE impl block, so Section 4 derives no pair here -- correctly, there is no declaration order to be free of; its sibling drain above carries that axis|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|2|
s3-constrained-impl-head-routes.mdk|§3 head projection + §7 single-evaluator law at a CONSTRAINED impl head with a HEADED body -- the #1630 fix, third member of the arm set above. ONE interface, ONE `impl Sz (Eq a => Int)`, ONE call: `eval.headTycon` peeled `TyConstrained` and filed the impl under `Int` while `typecheck.headTyNode` peeled only `TyApp`/`TyEffect`, so the caller side stamped `__none__` -- `check` 0 and `run` 2 were both already CORRECT and `build` exited 1 with `no impl of method ‘sz’ for type ‘__none__’`. ⚠️ THE LOAD-BEARING CELL IS **build**, not the value, exactly as for #1618 above: `ALL_EXACT` requires build to ACCEPT with stdout byte-identical to run`s and to the pinned 2. ⚠️ THE HEADED BODY IS THE POINT: `Eq a => a` is a different program, correctly still headless, and was never broken -- do not simplify the head|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|2|
s3-constrained-headed-impl-vs-plain-sibling.mdk|§3 head projection at a CONSTRAINED headed impl BESIDE A PLAIN SIBLING -- the #1630 row that grades the SILENT-WRONGNESS channel, and the reason the two one-impl rows must not be read as statements about the class. `impl Sz (Eq a => Box Int)` beside `impl Sz (Box Bool)`: pre-fix the constrained impl left the `Box` bucket on the typecheck side only, the two impls stopped being discriminable, and DECLARATION ORDER decided the value at exit 0 with `check` clean -- measured on a base arm built from this branch with the one-line peel deleted, this order printed 26 (13+13) and the reverse 28 (14+14), `build` exited 1 with `no impl of method ‘sz’ for type ‘__none__’`. 27 is the SPEC answer hand-derived from the two impl bodies, not a recapture. ⚠️ SO #1630`s S1 GRADES ITS REPORTED SHAPE, NOT THE CLASS: at ONE impl `check` and `run` were already correct, which is a property of one impl. ⚠️ TWO impl blocks of one interface, so Section 4 DOES derive a permutation pair here -- unlike its two siblings, and deliberately: order-dependence was the pre-fix signature|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|27|
s3-constrained-effect-impl-head-routes.mdk|§3 head projection with TWO STACKED WRAPPERS over one headed body -- the #1630 COMPOSITION row. `impl Sz (Eq a => <Stdout> Int)` puts the `TyConstrained` peel on top of #1618`s `TyEffect` peel; pre-fix it failed byte-identically to its sibling (check 0, run 6, build 1 with `no impl of method ‘sz’ for type ‘__none__’`), which is the measurement showing the #1618 peel alone did NOT reach a head an outer wrapper hides. ⚠️ NOT A DUPLICATE: a fix special-casing the reported shape `TyConstrained cs (TyCon …)` greens the sibling row and REDS this one -- that is this row`s whole job. ⚠️ Load-bearing cell is **build**|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|6|
s3-w1-cyclic-superinterface-rejected.mdk|§3 W1 the superclass relation must be ACYCLIC (else `super`-search loops) -- statically rejected, not hung|REJECT|REJECT|REJECT|NONE||T-CYCLIC-SUPERINTERFACE
s3-w3-method-scheme-rigidity-constraint.mdk|§3 W3 method-scheme fidelity, CONSTRAINT axis: an impl body may not need a class the method scheme does not license (#814 vein)|REJECT|REJECT|REJECT|NONE||T-IMPL-TOO-SPECIFIC
s3-w3-method-scheme-rigidity-pinned-type.mdk|§3 W3 method-scheme fidelity, PINNED-TYPE axis: an impl body may not fix a caller-owned method variable even with no constraint involved|REJECT|REJECT|REJECT|NONE||T-IMPL-TOO-SPECIFIC
s3-w3-default-method-rigidity.mdk|§3 W3 DEFAULT-BODY half: W3 also governs "the class`s default, which is checked by this same rule". A different site (`checkDefaultMethodRigidity`) from the two impl-body rows, and the corpus previously had NO fixture declaring a default body inside an `interface` at all|REJECT|REJECT|REJECT|NONE||T-IMPL-TOO-SPECIFIC
s2-method-level-constraint-abstract.mdk|§2 EXCEPTION: a method whose OWN signature adds a constraint over a fresh variable not fixed by the instance keeps that dict ABSTRACT -- projection yields a value still awaiting it. The two lines apply the SAME slot at TWO different `b`, which a construction-time-baked dict could not do|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|1/2\n1/True|
s3-min-fully-general-control.mdk|THE ONE-TOKEN CONTROL for #1128: byte-identical to it except the general impl`s head reads `(Box a)` not `a`. Answers 99/10/10 CORRECTLY, which is what makes #1128`s trigger claim (a BARE TYPE-VARIABLE head, not the tycon) an observation rather than an inference|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99\n10\n10|
s8-i1-dict-param-order.mdk|§8 I1 / §4 `gen` ORDER half: a TWO-predicate signature, with the two impls at the same type but different bodies so only POSITION distinguishes the dicts. Every other ACCEPTED fixture abstracts at most one dict, so order was previously never elaborated at all|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|503|
s4-gen-sig-declared-context-kept.mdk|§4 `gen-sig` (#619): a declared predicate the body NEVER DISPATCHES ON is still abstracted and still displayed (#610 regression pin -- the value 9 is identical either way, so only the section-2 scheme assertion can see this)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|9|
s4-gen-sig-violating-caller-rejected.mdk|§4 `var`: the declared context RESTRICTS CALLERS even when the body contains no method occurrence (#610 regression pin -- was exit 0)|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s4-gen-sig-body-needs-more-rejected.mdk|§4 `gen-sig` side condition `Q_sig ⊩ P`ᵢ` with `Q_sig` EMPTY: a signature is a contract the body must satisfy, not a floor it can raise -- rejected, never silently widened|REJECT|REJECT|REJECT|NONE||T-MISSING-CONSTRAINT
s4-gen-sig-superclass-redundant-dropped.mdk|§4 `gen-sig` + §3 `super` + §6 C2 diamond: `B a` inferred by the body is entailed by the declared `C a` via requires-closure, so it is DROPPED from the scheme (not merged); `super` is projection, and both diamond arms agree|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|23|
s4-gen-residual-inferred-context.mdk|§4 `gen` + §4.2 OD2 -- THE ISSUE 1549 DRAIN, LEGAL CELL. The predicate a body poses is `Tag (Wrap t)`; §3 `inst` reduces it through `impl Tag (Wrap a) requires Tag a` and the RESIDUAL `Tag t` is over a generalizable var, so it is `P` and `gen` abstracts a dict for it. Pre-fix the residual was DROPPED: check printed `nest : a -> String` at exit 0, run printed this same `wrap(int)` for the wrong reason, and the BUILT BINARY SEGFAULTED (139) because the missing predicate was also the missing dict param. ⚠️ THE VALUE ROW ALONE IS INERT HERE -- run printed it before and after; the discriminating assertions are the section-2 scheme and the section-3 dict arity|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|wrap(int)|
s4-gen-residual-unwitnessed-caller-rejected.mdk|§4 `var` over the SAME residual: once `Tag a` is in the scheme a caller must discharge it, and `Tag NoTag` has no instance. Pre-fix all three verbs exited 0 and run printed `wrap(int)` -- `NoTag` dispatched through `impl Tag Int` by declaration order (adding `impl Tag Bool` above it printed `wrap(bool)`, measured). This is the half a scheme-display assertion cannot reach: displaying the context without POSING the goal keeps the sibling green and still accepts this file|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s4-gen-residual-no-requires-control.mdk|THE ONE-TOKEN CONTROL + FALSE-REJECT CANARY for the two rows above: identical except the `Wrap` impl drops its `requires`. With no residual, `P` is EMPTY, `nest : a -> String` is the CORRECT principal scheme and `nest NoTag` is LEGAL. A reducer that deferred the goals own free vars instead of the matched instances residual would invent `Tag a` here; the section-2 row asserts the context stays empty, which the value cannot see|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|wrap|
s4-gen-sig-residual-uncovered-rejected.mdk|§4 `gen-sig` side condition with `Q_sig` EMPTY and the inferred predicate arriving as a `requires` RESIDUAL -- the SIGNATURED cell of issue 1549. Pre-fix accepted at exit 0 with a segfaulting binary, because the coverage check reads the same inferred-obligation projection that dropped it. ⚠️ Distinct from s4-gen-sig-body-needs-more-rejected: that predicate is inferred DIRECTLY, so a checker testing the RECORDED `Tag (Wrap a)` finds no bare-tyvar argument at all and stays silent here|REJECT|REJECT|REJECT|NONE||T-MISSING-CONSTRAINT
s4-gen-residual-xmod/main.mdk|§4 `gen` + §4.2 OD6(a) ACROSS A MODULE BOUNDARY -- the MULTI-MODULE cell of issue 1549, and the only fixture here that can see a scheme context or a dict arity failing to CROSS one. The residual is produced in wrapimpl.mdk, deferred into a scheme in nest.mdk, and discharged by `var` in main.mdk. Pre-fix: check 0, run `wrap(int)`, build 0, BINARY 139 -- the single-file cells reached through the module path. ⚠️ No section-2 row is possible: bare `check` filters the scheme dump to the ENTRY`s own bindings and `nest` is not one, so the section-3 dict-arity row carries the discrimination|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|wrap(int)|
s4-gen-sig-residual-covered-control.mdk|THE ACCEPT-SIDE CONTROL for the row above -- without it that reject cannot be told from "gen-sig rejects EVERY residual under a signature". Three legitimate coverings in one file: the residual IS the declared predicate; the residual `Eq a` is entailed by the declared `Ord a` through `interface Ord a requires Eq a` and is DROPPED not merged (section 2 asserts the scheme stays `Ord a =>`); and a CONCRETE argument whose reduction bottoms out ground, leaving no residual at all|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|wrap(int)\nTrue\nwrap(int)|
s4-gen-residual-mixed-vector-rejected.mdk|§4 `gen`/§4.2 OD2 -- ISSUE 1560, the cell this change DRAINS. A residual whose argument vector MIXES a concrete-headed argument with a bare tyvar (`Conv (Wrap t) u`) is now REDUCED per-argument instead of bailing on `allConcreteHeads`, so `Conv a b` reaches `f`s context and §4 `var` POSES it at the call: `f NoConv True` has no witness and is rejected. Pre-fix the predicate was dropped, all three verbs exited 0 and the binary segfaulted. ⚠️ The LEGAL half of 1560 (`f 5 True`) still faults, on a SEPARATE pre-existing class -- at a multi-parameter interface the conditional impls `requires` routes to a NULL element dict, measured identically with the context written out BY HAND on a base binary (issue 1318 / #1161, a dict slot is a PREDICATE). 1560s must-fail pin is retained for it|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s4-gen-residual-mixed-vector-accepted.mdk|ISSUE 1560 accept half, at the residual arity the routing machinery can honour: the vector is MIXED (`Conv (Wrap t) u`) and the residual is the 1-ary `Tag t`, so `f` abstracts one dict and prints `w:int`. ⚠️ THE VALUE ROW IS INERT -- base printed `w:int` too (arg-tag fallback landed on `impl Tag Int`); the DISCRIMINATION is the section-3 dict-arity row, arity 2 pre-fix vs 3 post|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|start\nw:int|
s4-gen-residual-mixed-no-requires-control.mdk|THE ONE-TOKEN CONTROL + FALSE-REJECT CANARY for the two mixed-vector rows: the same shape with the `requires` removed, so there is no residual and the context must stay EMPTY (section 2 asserts that -- the value cannot). A reducer deferring the GOALs free vars instead of the matched instances residual would invent `Conv a b` here and reject a legal program|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|start\nw|
s4-requires-depth-exceeded-rejected.mdk|§3 `inst` -- ISSUE 1562, the DRAIN. `requires`-nesting 33 deep crosses the reducers depth bound, which used to be SILENT: it returned the same `[]` as "no matching impl", the predicate was dropped from both the scheme and the `λ d̄.` prefix, and the program landed back in 1549s S0 (check 0 on `deep : a -> String`, build 0, BINARY 139). It is now a located reject. Its SPAN is pinned in section 6|REJECT|REJECT|REJECT|NONE||T-REQUIRES-DEPTH
s4-requires-depth-at-limit-control.mdk|THE AT-LIMIT CONTROL for the row above and the false-reject canary for making exhaustion loud: ONE fewer `Wrap` (depth 32, exactly the bound). Built and EXECUTED, so it distinguishes "the bound is now loud" from "the bound moved" -- a change to `residualReduceFuel` in EITHER direction reds one of these two files. Pre-fix this depth was ALSO silently dropped and its binary segfaulted|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwint|
s4-gen-rec-shared-dict-params.mdk|§4 `gen-rec` (#44 vein): a mutually-recursive group shares ONE `λ d̄.` prefix; recursive occurrences reuse the group`s dict params instead of re-entering entailment|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|True\nTrue|
s4-gen-rec-inferred-context.mdk|§4 `gen-rec` with the context INFERRED rather than ascribed -- the `gen` sourcing, a different code path from its `gen-sig` twin per #610`s mechanism note. ⚠️ BOTH bodies dispatch, so this row does NOT discriminate group sourcing from per-binding sourcing (an earlier revision wrongly claimed it did); it is a regression guard on the schemes and values. The discriminating form is the asymmetric row below|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|True\nTrue|
s4-gen-rec-inferred-asymmetric.mdk|§4 `gen-rec` DISCRIMINATOR -- LEDGER #1133 (OPEN, S1 LOUD BREAKAGE): an INFERRED mutually-recursive group in which only ONE body dispatches. check ACCEPTS and reports BOTH schemes as `Sz a =>` (the group-wide `P` attribution is right), then NEITHER engine will execute it -- run E-PANICs `unbound identifier: $dict_evenSz_0`, build dies `unbound dict witness ... in emit env (dict not threaded to this site)`. §4`s named failure mode, caught before it can become a wrong value. Controls: the ascribed twin and the symmetric row both run fine; mirroring which body dispatches fails symmetrically|ACCEPT|REJECT|REJECT|NONE||
s5-return-position-dispatch.mdk|§5 RESULT position: `mk : Int -> a` has no argument whose runtime tag reveals the instance, so dispatch can only come from the statically-determined dictionary. Both calls pass an identical Int literal|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|1\n2|
s5-phantom-ambiguous-use-rejected.mdk|§5 PHANTOM position, AMBIGUOUS use: §4 `var` cannot discharge `Mk ?a` with nothing fixing `?a`, so the SPEC rejects it too (§5 says only HOW a phantom dispatches, never that this program resolves). CONFORMANT ON THE VERDICT, with the caveat that spec and impl reject at different SITES -- spec the use, impl the declaration -- which the spec leaves unspecified|REJECT|REJECT|REJECT|NONE||T-PHANTOM-METHOD
s5-phantom-determined-use-rejected.mdk|§5 PHANTOM position, DETERMINED use -- LEDGER #1134 (OPEN, S3 OVER-REJECTION): inside `useBoth : Mk a => a -> Int` the dict is in scope over a RIGID `a`, so §3 `assum` discharges it and §5 `(method)` projects -- the spec ACCEPTS and prints 7. The checker rejects at the DECLARATION regardless. Paired with the ambiguous row this proves the impl rejects a strict SUPERSET of what the spec does. ⚠️ Drains on #1134 (BEHAVIOUR), never on #1107 (d), which is spec-only and changes no behaviour|REJECT|REJECT|REJECT|NONE||T-PHANTOM-METHOD
s5-argtag-unsound-under-overlap.mdk|§5 arg-tag dispatch is an OPTIMIZATION, not a semantics: two calls with the same runtime `List` head tag must answer 99 and 10, which no arg-tag selector can do. ALSO the one-token control for the s3-min-fully-general-sibling S0|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99\n10|
s6-c1-duplicate-heads-rejected.mdk|§6 C1 + §3: two α-equal heads are mutually ⊑, so there is no UNIQUE ⊑-minimum -- ambiguous overlap, rejected. Duplicate heads never tie-break. ⚠️ THE ROW F-3d DELIBERATELY DID NOT WIDEN: α-equal heads SATISFY condition (a) (they are ⊑-comparable), so this was never (a)`s to demote -- it is a C1 violation, and F-3d demotes (a) alone. It also has no second line of defence: `entryCovers` makes equal heads cover each other, so the goal-site min⊑ reject never sees this shape|REJECT|REJECT|REJECT|NONE||T-CONFLICTING-IMPL
s6-c1-xmod-same-spelled-ifaces-accepted/main.mdk|§6 C1 -- TWO SAME-SPELLED INTERFACES IN UNRELATED MODULES ARE TWO CLASSES, SO COHERENCE MUST ACCEPT. #1438s COHERENCE-channel repro, moved here from the drained must_fail pin `1438-same-spelled-interfaces-collapse-in-coherence`: a pin asserts a bug still reproduces, so a fix removes it and the S0 has NO guard unless a positive row replaces it. `amod` and `zmod` each declare their OWN `interface Same a` -- disjoint methods (`foo` vs `bar`), no import edge in either direction -- and each impls it at the SAME head `Int`; the entry uses one method from each, so neither import can be dead-code-argued away. SPEC ANSWER hand-derived from module-qualified interface identity, not read off a binary: an interface is identified by its DECLARATION, so `amod.Same` and `zmod.Same` are two classes whose impls occupy two different (class, head) cells -- there is no C1 pair to find, and reporting one is a FALSE REJECT on a legal program. ACCEPT, value 109 = 1*100 + (2+7), reachable only when BOTH impls are selected, one per class. 🚨 MEASURED AS A FALSE REJECT ON A PRE-A-3.7 BASE BINARY (cold-built at 7aae8b83, its own stdlib/runtime/emitter): check exit 1 emitting `T-CONFLICTING-IMPL` with the message ``Conflicting `impl Same`. Defined in amod and zmod`` and a null range, run 1, build 1 -- coherence keyed the interface half of an impl by SPELLING while the obligation channel already keyed it by IDENTITY, so the two checkers disagreed about whether these were one class. On this binary `CohImpl`s interface half is an `IfaceRef` compared through `cohSameIface`/`sameTyConHead` and all three verbs accept at 109. The `!T-CONFLICTING-IMPL` assertion is what makes the row FAIL-CAPABLE: re-key that half back to spelling and it reds. ⚠️ THE SHARED HEAD IS LOAD-BEARING -- coherences HEAD half is already identity-aware (`cohGoR`s `TCon` arm), so two module-local heads would mask the interface half entirely. ⚠️ #1438 STAYS OPEN: only its COHERENCE reach drained. The identity collapse survives in the obligation channels bare compatibility leg, pinned separately, and is #1482/#1507 territory|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|109|!T-CONFLICTING-IMPL
s6-c1-xmod-shared-iface-conflict-control/main.mdk|CONTROL for the row above, and the canary that keeps it honest: the SAME module topology (one entry, two impl modules, one head `Int`) with ONE thing varied -- `Same` is declared ONCE in `idef.mdk` and IMPORTED by both impl modules, so the two `impl Same Int` name the SAME class and this IS a C1 violation. REJECT, T-CONFLICTING-IMPL. Without it the accepting sibling cannot be told from `the cross-module coherence arm stopped checking`: deleting the sweep, or making `cohSameIface` answer False everywhere, accepts BOTH files, and an accept-only row would call that progress. ⚠️ Cross-module BY CONSTRUCTION -- the two impls live in modules neither of which imports the other, so no per-module sweep can see the pair, only the whole-graph one; the message comes from `cohCrossModuleMsg` through `cohPushHard`, which names both owning modules and carries a NULL span on purpose (#414: a span only helps a consumer that files against the spans own file). ⚠️ BEHAVES IDENTICALLY ON BOTH ARMS, deliberately -- MEASURED REJECT on the same pre-A-3.7 BASE binary. It is a false-accept canary, not an arm discriminator|REJECT|REJECT|REJECT|NONE||T-CONFLICTING-IMPL
s6-1c-multimodule-overlap/main.mdk|§6.1.2 "acceptance is per-goal" ACROSS MODULES, and the only in-tree coverage of the cross-module coherence-WARNING path (globalCoherenceConflict`s soft half / attachEntryWarnOpt / prependDiagOpt), which had none. TWO ⊑-incomparable pairs placed differently: `C` with both impls in lib.mdk (same-module -- seen by lib`s own sweep AND the whole-graph one, which is why `cohSoftInScope` exists) and `D` split across lib.mdk/other.mdk (no per-module sweep can see it). Both goals are `(Pair Int Bool)`, which matches ONLY the `Pair Int a` head of each pair -- a singleton matching set, trivially its own ⊑-minimum -- so the program is ACCEPTED and prints 1+10=11 while both declarations warn. Section 5 asserts each message appears EXACTLY ONCE on run|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|11|W-INCOMPARABLE-IMPLS
s6-1c-unrelated-warning-not-surfaced.mdk|SECTION-5 DISCRIMINATING CONTROL: a program whose only warning is an UNRELATED `W-NONEXHAUSTIVE`. `check` MUST report it (asserted here) and section 5 asserts `run`/`build` must NOT -- the same diagnostic, present on one verb and absent on the others, which is what makes the pair separable. The earlier EMPTY controls (s3-min-subsumes, s8-i2) carry no channel warning at all and were INERT against a widened filter, proven by experiment|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|1|W-NONEXHAUSTIVE,!W-INCOMPARABLE-IMPLS
s6-c1-hard-and-soft-in-one-file.mdk|§6 C1 + §6.1.2 -- THE ONLY ROW THAT EXERCISES `cohScan`s TWO-SLOT RETURN. One file carrying BOTH coherence classes, with the SOFT pair reached FIRST by the reverse-declaration-order scan: `Tag Bool` twice (mutually ⊑ -- a C1 violation, HARD) plus `Tag (Pair Int a)`/`Tag (Pair a Int)` (⊑-incomparable -- condition (a) alone, SOFT). ⚠️ THE DISCRIMINATOR: a ONE-slot classified scan would stop at the soft pair and ACCEPT this file at exit 0 with only a warning, so the row asserts the ERROR is present, not merely that some diagnostic is. Pre-F-3d the whole file reported ONE diagnostic and never the duplicate, because the scan returned the first conflict and stopped. ⚠️ `!T-AMBIGUOUS-INSTANCE`: `main`s goal `Tag Bool` matches BOTH duplicates, and the goal-site arm must NOT fire -- `entryCovers` `tyHeadEqV` makes equal heads cover each other -- which is exactly why that class cannot be demoted|REJECT|REJECT|REJECT|NONE||T-CONFLICTING-IMPL,W-INCOMPARABLE-IMPLS,!T-AMBIGUOUS-INSTANCE
s6-1c-per-goal-unique-min-accepted.mdk|§6.1 choice-point 2 -- THE #614/#311 DRAIN (F-3d): the §6.1 SEPARATING CASE, now conformant. `Pair Int Int` is ⊑ both `Pair Int a` and `Pair a Int` and is the unique ⊑-minimum at the goal, so §3 `inst` selects it and both engines print 3. The value is the SPEC answer the fixture`s own header hand-derived while the row was still pinned to a REJECT, not a recapture. The declaration-time (a) sweep still fires as the `W-INCOMPARABLE-IMPLS` WARNING §6.1 licenses -- asserted here, since a positive-only pin could not tell the demotion from (a) having been deleted|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3|W-INCOMPARABLE-IMPLS,!T-CONFLICTING-IMPL
s6-1c-incomparable-no-minimum-control.mdk|CONTROL for #614: the same program with the unique ⊑-minimum DELETED. Genuinely ambiguous, so (a) AND (c) both reject. Since #1155 (F-3c) the reject is the goal-site T-AMBIGUOUS-INSTANCE; since F-3d the declaration-time (a) finding beside it is a WARNING. ⚠️ The pair`s ARGUMENT INVERTED at F-3d and that is why both rows survive: it used to show adding the ⊑-minimum changes NOTHING (condition (a) by construction); it now shows adding it flips the sibling to ACCEPT-with-3, i.e. acceptance really is per-goal. A single accepting row could not establish that -- an implementation that simply stopped checking would accept both|REJECT|REJECT|REJECT|NONE||T-AMBIGUOUS-INSTANCE,W-INCOMPARABLE-IMPLS
s6-c1-rigid-goal-no-minimum.mdk|§6 C1 AT A RIGID-VARIABLE GOAL -- the #1155 (F-3c) drain, and the goal-site half of C1`s requantification off "ground" onto "the goals `inst` decides". A user `impl Index (List (List b)) k c` beside the prelude`s `impl Index (List b) Int b`: at the CLOSED-but-not-ground goal `Index (List (List a)) Int (List a)` both match under §3 and neither ⊑ the other, so there is no ⊑-minimum. PRE-#1155 this printed `[1, 2]` at exit 0 on BOTH engines -- the prelude won on declaration index, silently. Coherence structurally cannot see it (its input is user decls only, and there is one user impl), which is why this needed the SELECTOR-keyed reject and not the declaration-time one|REJECT|REJECT|REJECT|NONE||T-AMBIGUOUS-INSTANCE
s6-c1-rigid-goal-unique-min-control.mdk|CONTROL 1/3 for the row above: user impl made STRICTLY MORE SPECIFIC (`Index (List (List b)) Int (List b)`), so min⊑(match) is the singleton {user} and §3 `inst` selects it -- ACCEPT, printing the second row `[3]`, a value ONLY that impl can produce. This is what rules out the three duller readings of its sibling`s reject (goal discharged by `assum` and never reaching `inst`; user impl not registered at a prelude-occupied head; prelude always wins) -- every one of those predicts `[1, 2]` here|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[3]|
s6-c1-rigid-goal-no-user-impl-baseline.mdk|CONTROL 2/3: the same program with the user impl DELETED. The matching set is the SINGLETON {prelude}, trivially its own ⊑-minimum, so the rigid goal is well-formed and RESOLVES -- `[1, 2]`. Pins that the sibling`s reject is "this rigid goal has no ⊑-minimum", not "a rigid goal cannot be resolved". Also the exact value the buggy sibling printed, which is what made that S0 invisible|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[1, 2]|
s6-c1-rigid-goal-no-call-discriminator.mdk|CONTROL 3/3, and the one that makes "rigid" an ASSERTION rather than a label: identical to s6-c1-rigid-goal-no-minimum except `main` NEVER CALLS `firstRow`, so the ONLY `Index` goal the program poses is the DEFINITION-SITE rigid one and there is no ground goal anywhere. A reject keyed to groundness would ACCEPT this file. It rejects identically, which is #1155 acceptance item 2 stated as an experiment|REJECT|REJECT|REJECT|NONE||T-AMBIGUOUS-INSTANCE
s6-2-t3-closed-goal-reported.mdk|§6.2 T3 CLOSED half of the #1155 closedness pair. Two ⊑-incomparable USER impls; since F-3d coherence (a) only WARNS about them, so the GROUND goal `Sh (Q Int Bool (List Int))` reaching the min⊑ selector is the whole of this file`s reject. Carries the goal-site error AND the declaration-time warning|REJECT|REJECT|REJECT|NONE||T-AMBIGUOUS-INSTANCE,W-INCOMPARABLE-IMPLS
s6-2-t4-open-goal-deferred.mdk|§6.2 T4 OPEN half, and the ONLY in-tree test of the closedness gate. ONE TOKEN from its sibling (`[1]` -> `[]`), so `?e` is an unbound metavariable no scheme quantifies. SAME candidate set, SAME no-unique-minimum arm -- but T4 defers a non-closed goal rather than deciding it, so the goal-site reject MUST NOT fire. Since F-3d that makes the pair an ACCEPT-vs-REJECT discriminator as well. ⚠️ KEEP THE `!` ASSERTION: verdict alone cannot say the sibling`s reject came from the min⊑ arm rather than from anything else, so a positive-only row would be strictly weaker against the regression this exists for. ⚠️ The pinned value 1 is DECLARATION-ORDER-DECIDED, not correct -- see the §4 KNOWN-BAD row and #1183|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|1|W-INCOMPARABLE-IMPLS,!T-AMBIGUOUS-INSTANCE
s6-1-3-commit-at-elaboration-site.mdk|§6.1 choice-point 3: selection COMMITS AT THE ELABORATION SITE. A rigid-variable goal inside a signed binding takes the general instance (11) and is NOT retroactively re-resolved when the caller instantiates at Int, while the same ground predicate resolved directly gives 99. ⚠️ DO NOT "FIX" 11 TO 99|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|11\n99|
i4-xmod-method-level-slot-rejected/main.mdk|§8 I4 -- A METHOD-LEVEL `=>` SLOT NAMES ITS OWN CLASS. The FOURTH channel that discriminates under #1446 (`recordMethodLevelSlotObls` via `methodLevelConstraintSlots`/`constraintSlotVarIface`/`Constraint.constraintOrigin`), and the one that had NO coverage at all -- a different producer and a different carrier from the impl-`requires` pair below, so a change re-widening only this one would leave those green. SPEC ANSWER hand-derived from §3: `peek : Sizer b => h -> b -> Int` is declared in `zmod` where the only `Sizer` in scope is `zmod`s, so the Constraint denotes `zmod.Sizer`; `useCell n = peek Cell n` at `n : Int` instantiates the slot at `b := Int`, posing `zmod.Sizer Int`; `match(IE, …)` is EMPTY because the graph`s only `impl Sizer Int` is `amod.Sizer`s, a different declaration with a disjoint method set. REJECT, T-NO-IMPL. 🚨 THE HIGHEST-VALUE ROW OF THE SET -- BASE SHIPS A SEGFAULTING BINARY. MEASURED on a $BASE-built binary: check exit 0 (`main : Unit`), build exit 0, and ./out exit 139 `runtime error [E-FATAL-SIGNAL]: fatal memory fault (segmentation fault)`, because the slot was discharged against a dictionary shaped for `amod.Sizer` (`{weight}`) and projecting `bulk` reads a slot that is not there. `pl`/`po` return a wrong ANSWER; this one corrupts memory. ⚠️ The diagnostic lands in `zmod.mdk`, not in the entry|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
i4-xmod-method-level-slot-control/main.mdk|CONTROL for the row above. `zmod` gains its own `impl Sizer Int`, so `match(IE, zmod.Sizer Int)` is the singleton {zmod`s impl} and `peek Cell 3` = `bulk 3` = 3+7 = 10. `10` is a value ONLY `zmod`s impl can produce (`amod`s `weight n = n * 100` would give 300), so the pair separates `the reject was removed` from `the wrong impl was selected`. Rules out the duller readings of the sibling`s reject -- `a method-level => slot cannot be discharged across modules`, `any same-spelled interface poisons the goal`, `Holder`s impl cannot see Sizer` -- each of which predicts a reject here too. ⚠️ Two edits from the sibling, not one: `amod`s impl also moves to head `Bool`, because with both at `Int` BOTH ARMS reject T-CONFLICTING-IMPL (coherence still keys the interface half by SPELLING while the obligation channel keys it by identity -- recorded on #1482). ⚠️ Behaves identically on both arms, deliberately|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|10|
i4-xmod-requires-foreign-iface-rejected/main.mdk|§8 I4 -- A CONDITIONAL INSTANCE`s `requires` NAMES ITS OWN CLASS, NOT A SAME-SPELLED FOREIGN ONE. The #1438 collision shape reached through the `requires` channel, and THE arm-discriminating row for #1446: a 2704-file two-arm corpus differential over test/ came back EMPTY, so nothing already in the tree witnesses that change. SPEC ANSWER hand-derived from §3 before any binary was run: `zmod`s `requires Sizer a` is an OCCURRENCE resolved in `zmod`s scope, so it denotes `zmod.Sizer` (method `bulk`); at the goal `Debug (Wrap Int)` it discharges to `zmod.Sizer Int`; `match(IE, zmod.Sizer Int)` is EMPTY because the graph`s only `impl Sizer Int` belongs to `amod.Sizer`, a different declaration with a disjoint method set (`weight`). REJECT, T-NO-IMPL, no value to pin. 🚨 MEASURED ON A $BASE-BUILT BINARY, this exact program: check exit 0 (`main : Unit`, a SILENT ACCEPT), build exit 0, and THE BUILT BINARY EXITS 1 with `runtime error [E-NONEXHAUSTIVE-MATCH]` -- base ships a dying binary from a program check called clean, because `bulk` was discharged against a dictionary shaped for `amod.Sizer` (`{weight}`). If a later unit re-widens the `requires` channel to spelling, this row goes GREEN-BY-ACCEPTING and that S0 is back. ⚠️ The `requires` channel keeps identity because `requireOrigin` and `implOrigin` are BOTH occurrence-layer, filled by one `fillIfaceOccOrigin` walk in one scope. The METHOD-OCCURRENCE channel is deliberately NOT covered (it crosses to the decl layer) -- see `recordImplObligation` and #1482|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
i4-xmod-requires-own-iface-control/main.mdk|CONTROL for the row above, and the VALUE is what makes it one: `zmod` gains its own `impl Sizer Int`, so `match(IE, zmod.Sizer Int)` is the singleton {zmod`s impl} and `bulk 3` = 3+7 = 10, printing `W10`. `W10` is a value ONLY `zmod`s impl can produce (`amod`s `weight n = n * 100` would give `W300`), so the PAIR separates `the reject was removed` from `the wrong impl was selected` -- a verdict-only control could not. It rules out the duller readings of the sibling`s reject (`a conditional instance cannot discharge `requires` across modules`; `any same-spelled interface in the graph poisons the goal`), each of which predicts a reject here too. ⚠️ TWO EDITS FROM THE SIBLING, NOT ONE, AND THE SECOND IS FORCED: `amod`s impl also moves from head `Int` to head `Bool`, because with both at `Int` BOTH ARMS reject `T-CONFLICTING-IMPL` before the obligation channel is reached. #1446 gave the OBLIGATION channel an identity; COHERENCE still keys the interface half by SPELLING (the KeyBuckets side, kept spelling-scoped by #1317 T1), so the two checkers disagree about whether `amod.Sizer` and `zmod.Sizer` are one class. Pre-existing in direction, out of scope here, recorded on #1482. ⚠️ BEHAVES IDENTICALLY ON BOTH ARMS, deliberately -- a goal with one candidate is not a witness to an identity re-key|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|W10|
i4-xmod-sig-constraint-foreign-iface-rejected/main.mdk|S8 I4 -- A SIGNATURE `=>` CONSTRAINT NAMES ITS OWN CLASS, NOT A SAME-SPELLED FOREIGN ONE. This is #1438s OWN repro, moved here verbatim by U1b (#1482) when it DRAINED that issues `must_fail` pin: a pin asserts a bug still reproduces, so a fix removes it and the S0 has NO guard unless a positive row replaces it. SPEC ANSWER hand-derived from S3 + S8 I4, not read off a binary: `zmod` declares its own `interface Sizer a where bulk` AND `useBulk : Sizer b => b -> Int` in the same module and imports nothing, so the `=>` occurrence unambiguously denotes `zmod.Sizer`; `useBulk 3` instantiates `b := Int`, posing `zmod.Sizer Int`; `match(IE, zmod.Sizer Int)` is EMPTY because the graphs only `impl Sizer Int` belongs to `amod.Sizer`, a different declaration with a disjoint method set (`weight`, not `bulk`). REJECT, T-NO-IMPL, no value to pin. 🚨 MEASURED ON A main-BUILT BINARY AT 709db738, BEFORE U1b: check exit 0 (`main : Unit`, a SILENT ACCEPT), run E-PANIC `unbound identifier: bulk`, build exit 0 and the binary SEGFAULTS at 139 -- because `bulk` was projected out of a dictionary shaped for `amod.Sizer` (`{weight}`). ⚠️ DIFFERENT PRODUCER from the `requires` and method-level rows above: this one reaches the collision through a constrained bindings `=>` slot re-instantiated at a CROSS-MODULE call site (`funConstraintIfacesRef` + `schemeObligationsRef`, the two tables U1b widened), and before U1b exactly those rows rejected while this one did not. ⚠️ Topologically discriminating by construction: the goal is posed by `zmod`s signature and elaborated when `zmod` is processed, NOT in `main` -- `main` is always topologically last and would be a false null|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
i4-xmod-sig-constraint-own-iface-control/main.mdk|CONTROL for the row above, and the VALUE is what makes it one: `zmod` gains its own `impl Sizer Int` (`bulk n = n + 7`), so `match(IE, zmod.Sizer Int)` is the singleton {zmods impl} and `useBulk 3` = 10. `10` is a value ONLY `zmod`s impl can produce (`amod`s `weight n = n * 100` would give 300), so the PAIR separates `the reject was removed` from `the wrong impl was selected` -- a verdict-only control could not. It rules out the duller readings of the siblings reject (`a cross-module constrained callee cannot discharge its => at all`; `any same-spelled interface in the graph poisons the goal`), each of which predicts a reject here too. ⚠️ TWO EDITS FROM THE SIBLING, NOT ONE, AND THE SECOND IS FORCED: `amod`s impl also moves from head `Int` to head `Bool`, because with both at `Int` BOTH ARMS reject `T-CONFLICTING-IMPL` before the obligation channel is reached. U1b gave the OBLIGATION channel an identity; COHERENCE still keys the interface half by SPELLING (the KeyBuckets side, kept spelling-scoped by #1317 T1), so the two checkers still disagree about whether `amod.Sizer` and `zmod.Sizer` are one class. Pre-existing in direction, out of scope for U1b, recorded on #1482 -- the same note the `requires` control carries|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|10|
i4-xmod-method-occurrence-foreign-iface-rejected/main.mdk|§8 I4 -- A BARE METHOD OCCURRENCE NAMES ITS OWN CLASS, NOT A SAME-SPELLED FOREIGN ONE. U1c (#1507)s row, and the SURVIVING half of #1438: `zmod`s `useBulk` carries NO signature at all -- there is no `=>` slot for U1b (#1482) to have touched -- so the goal is posed purely by the bare method occurrence `bulk x`, `recordImplObligation`s producer. Moved here verbatim from the drained `must_fail` pin `1507-xmod-iface-name-collision-method-occurrence`: a pin asserts a bug still reproduces, so draining it removes the guard unless a positive row replaces it. SPEC ANSWER hand-derived from S8 I4, not read off a binary: `zmod` declares its own `interface Sizer a where bulk`, imports nothing, so `bulk` inside `useBulk`s own body unambiguously denotes `zmod.Sizer`; `useBulk 3` instantiates the occurrences dispatch type at `Int`, posing `zmod.Sizer Int`; `match(IE, zmod.Sizer Int)` is EMPTY because the graphs only `impl Sizer Int` belongs to `amod.Sizer`, a different declaration with a disjoint method set (`weight`, not `bulk`). REJECT, T-NO-IMPL, no value to pin. 🚨 MEASURED ON A main-BUILT BINARY BEFORE U1c: check exit 0 (`main : Unit`, SILENT ACCEPT), run E-PANIC `unbound identifier: bulk`, build exit 0 and the binary SEGFAULTS at 139 -- `bulk` projected out of a dictionary shaped for `amod.Sizer` (`{weight}`). ⚠️ DIFFERENT PRODUCER from `i4-xmod-sig-constraint-foreign-iface-rejected`: that rows `useBulk` IS signed (`Sizer b => b -> Int`), reaching the collision through `funConstraintIfacesRef`/`schemeObligationsRef`; this rows is unsigned, reaching it through `pushPendingObl` at the bare method occurrence -- the one channel U1b deliberately left untouched. ⚠️ MEASURED, not claimed by construction: the diagnostic lands at `main.mdk:48:16`, not in `zmod.mdk` -- `useBulk` is UNSIGNED, so its constraint is inferred/generalized into its own scheme and the obligation entails where that scheme is instantiated (the call in `main`), not at `zmod`s processing. An earlier revision of this row claimed the zmod-processing-time mechanism by analogy with the sig-constraint sibling above; that analogy does not hold for an unsigned forwarder. The rows DISCRIMINATION (base silent-accept+segfault, branch reject) is unaffected by this correction|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
i4-xmod-method-occurrence-own-iface-control/main.mdk|CONTROL for the row above, and the VALUE is what makes it one: `zmod` gains its own `impl Sizer Int` (`bulk n = n + 7`), still with NO signature on `useBulk`, so `match(IE, zmod.Sizer Int)` is the singleton {zmods impl} and `useBulk 3` = 10. `10` is a value ONLY `zmod`s impl can produce, so the PAIR separates `the reject was removed` from `the wrong impl was selected` -- a verdict-only control could not. Rules out the duller readings of the siblings reject (`a bare cross-module method occurrence cannot dispatch at all`; `any same-spelled interface in the graph poisons the goal`), each of which predicts a reject here too. ⚠️ TWO EDITS FROM THE SIBLING, NOT ONE, AND THE SECOND IS FORCED: `amod`s impl also moves from head `Int` to head `Bool`, because with both at `Int` BOTH ARMS reject `T-CONFLICTING-IMPL` before the obligation channel is reached -- COHERENCE still keys the interface half by SPELLING (kept spelling-scoped by #1317 T1), so the two checkers still disagree about whether `amod.Sizer` and `zmod.Sizer` are one class. Pre-existing in direction, out of scope for U1c, recorded on #1482 -- the same note the `requires` and `sig-constraint` controls carry. ⚠️ BEHAVES IDENTICALLY ON BOTH ARMS, deliberately -- a goal with one candidate is not a witness to an identity re-key|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|10|
i4-xmod-method-and-iface-different-modules-rejected/main.mdk|§8 I4 -- A NEW INSTANCE OF #1438s CLASS: the METHOD occurrence and the impls resolved INTERFACE-NAME arrive from TWO DIFFERENT modules, neither of which is the constrained call sites own module. `u.mdk` imports `pmth` (a value, FROM p.Same) and the TYPE `Same` FROM g.Same -- never p.Same the type -- so `impl Same P where gmth _ = 7` unambiguously resolves to g.Same (implOrigin = g), while `use1 x = pmth x` calls pmths OWN declaring interface, p.Same. SPEC ANSWER hand-derived from S8 I4: `use1 (P 3)` poses `p.Same P`; `match(IE, p.Same P)` is EMPTY because the graphs only `impl Same _` is g.Same P, a different declaration with disjoint methods (gmth vs pmth). REJECT, T-NO-IMPL. 🚨 MEASURED ON A main-BUILT BINARY BEFORE U1c: check exit 0 (SILENT ACCEPT, the bare goal matched g.Sames impl by SPELLING alone), build exit 0, binary SEGFAULTS at 139|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
i4-xmod-method-and-iface-different-modules-control/main.mdk|CONTROL for the row above, and the VALUE is what makes it one: `use1` now calls `gmth` (also imported from g) instead of `pmth`. gmths OWN declaring interface is g.Same, matching `impl Same P`s implOrigin = g exactly, so `match(IE, g.Same P)` is the singleton {this impl} and `use1 (P 3)` = 7. `7` is a value ONLY this impl can produce, so the PAIR separates `the reject was removed` from `the wrong impl was selected` -- a verdict-only control could not. Rules out the duller readings of the siblings reject (`a method imported from one module and an impl resolved via another can never discharge together`; `any same-spelled interface in the graph poisons the goal`), each of which predicts a reject here too. ONE-TOKEN diff from the sibling (`pmth x` -> `gmth x`). ⚠️ BEHAVES IDENTICALLY ON BOTH ARMS, deliberately -- a goal with one candidate is not a witness to an identity re-key|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|7|
i4-rule3-ambiguous-xmod-identity/main.mdk|§8 I4 + §3 `inst` -- THE RULE-3 AMBIGUITY REJECT WITH ORIGIN-CARRYING IMPLS (#1446 T2). `checkUndeterminedObligation``s RULE 3 is guarded on `implCountForIfaceU >= 2`, and it is the ONE consequence of a missed `ImplUniverse` lookup that goes QUIET rather than loud: a miss reads as the count 0 and `T-AMBIGUOUS-INSTANCE` simply stops emitting. The four existing ambiguity fixtures (test/typecheck_error_fixtures/ambiguous_*) are all SINGLE-FILE; this one is cross-module. 🚨 IT DOES NOT DISCRIMINATE THE #1446 RE-KEY AND AN EARLIER VERSION OF THIS ROW CLAIMED IT DID: the stated counterfactual (reader keys TkBare => count 0 => ACCEPT at exit 0) is UNREACHABLE, refuted by building that exact neutered compiler -- `insertUnivImplKeys` indexes every identity-carrying impl under its bare spelling too, so the bare bucket holds both head tags and the count is 2 either way. It also behaves identically on the BASE binary. KEPT as a §3 CONFORMANCE row (RULE 3 must reject a genuinely ambiguous cross-module goal), NOT as evidence for the re-key; the arm-discriminating coverage is i4-xmod-requires-foreign-iface-rejected. SPEC ANSWER hand-derived, not captured: `roundtrip : Mk a => Int -> Int` fixes `a` in neither argument nor result, so `match(IE, Mk ?a)` = {Widget, Gadget}, mutually ⊑-incomparable, no unique ⊑-minimum, genuinely ambiguous. ⚠️ The diagnostic lands at `lib.mdk``s own body, not at the entry`s call -- see the fixture header|REJECT|REJECT|REJECT|NONE||T-AMBIGUOUS-INSTANCE
i7-flatten-arm-fresh-universe.mdk|§8 I7 + §7.1 -- THE FLATTEN-ARM / MODULE-ARM PARTITION TRIPWIRE (#1446). The Module arm`s `ImplUniverse` is whole-graph and outlives `resetState` (#1112 A-3.4 PR2 retired the three `obUniv*` accumulator rows this named; the Module arm now projects stage K`s `IE` via `ieUniverseAt`), and the five prelude-FLATTENED internal passes have no prelude boundary, so an identity-keyed row written by a stamped pass and read by a flattened one would MISS. It does not reproduce, for a STRUCTURAL reason: there are exactly TWO `ImplUniverse` sources and they are ARM-GATED (the `Flat` arm builds a fresh `buildImplUniverse prog`; only `Module` reads the whole-graph one; all five flattened sites route to `Flat`). ⚠️ THAT SEPARATION IS NOW LOAD-BEARING AND E-1 (#1115) IS THE UNIT THAT BREAKS IT -- this row is what must go RED instead of silently missing. No imports, so `check` takes the Flat arm while `run`/`build` additionally drive the flattened discovery passes; every dispatch is a PRELUDE impl reached through a conditional instance, and all four I7 classes (Num/Eq/Ord/Semigroup) are exercised on one file. ⚠️ HONEST LIMIT: an end-to-end consequence pin, not a direct assertion about which universe object a pass read -- it cannot tell `the partition held` from `it broke and both universes agreed`. Treat RED as `read the arm partition again`, not as a diagnosis|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|6\n[Some 1, None]\n[1, 2, 3]\nTrue\nTrue|
i7-qual4-gate-num.mdk|§8 I7 qual. 4 -- THE GATE, class `Num` (#1539). The prelude is present, so the operator`s `Num Blob` predicate IS synthesized and `Blob` cannot discharge it. The gate is the ONLY thing between this file and exit 0: with `builtinClassPresent BNum` stubbed to False the row flips REJECT->ACCEPT, MEASURED on a stubbed build. Operands are signature-typed params, never literals -- `Blob 1 + Blob 2` reports a numlit-taint `Type mismatch` the unify raises whether or not the gate fired, and cannot discriminate it|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
i7-qual4-gate-eq.mdk|§8 I7 qual. 4 -- THE GATE, class `Eq` (#1539). Sibling of the `Num` row; `Blob` is deliberately not `deriving Eq`, since an impl would discharge the obligation and the row would pass whether or not the gate fired|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
i7-qual4-gate-ord.mdk|§8 I7 qual. 4 -- THE GATE, class `Ord` (#1539). Sibling of the `Num` row. `Ord a requires Eq a`, so the superclass is demanded too; the FIRST diagnostic is the `Ord` one, which section 6 pins by span|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
i7-qual4-gate-semigroup.mdk|§8 I7 qual. 4 -- THE GATE, class `Semigroup` (#1539). Sibling of the `Num` row, for the `++` seam|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
i7-qual4-user-class-same-spelling.mdk|§8 I7 qual. 2+4 -- THE U1 DISCRIMINATOR (#1539). ⚠️ THIS ROW PINS A PROTECTION, NOT A RULE, AND IS SUPPOSED TO GO RED. I7 qual. 2 says a user MAY declare an interface spelled `Num` and "it is never rejected for that"; the tree rejects it `R-DUPLICATE-DEF` because the prelude`s decls are FLATTENED into the user`s list, so the collision reads as a within-module duplicate. §7.1 U1 makes the prelude a node and this reject evaporates. WHOEVER LANDS U1 OWNS THIS ROW: do not re-bless to ACCEPT and move on -- re-pin it as the I7 conformance discriminator it becomes (program ACCEPTED, `frobnicate` resolves to the USER`s class, and `1 + 1` still demands the PRELUDE`s `Num` and prints 2). Until #1539 the gate asked `ifaceRegistered "Num"`, a table THIS declaration writes to; it now asks `builtinClassPresent BNum`, so the answer no longer depends on this file|REJECT|REJECT|REJECT|NONE||R-DUPLICATE-DEF
s6-1-4-supers-per-construction-goal.mdk|§6.1 choice-point 4 / §6 C2 / §3 `super` -- #1127 DRAINED (S-predicate-representation, #1177`s fix). The row is RE-PINNED to the SPEC ANSWER exactly as its fixture header instructed ("the row goes RED the day native starts printing 77 ... re-pin it to ALL_EXACT 77\n77 and close #1127"), never re-blessed to whatever the binary now says: 77/77 was hand-derived in that header BEFORE anything ran. The build arm reached the GENERAL `D`-dict because a use site was resolved by its constraint VAR`s id rather than by its PREDICATE (`enclDictVarOf`), which is the same defect #1177 pinned one channel over; both drained in one change. The control `s6-1-4-direct-constraint-control` (the `assum` arm, always correct) is what keeps this row honest -- the two must now agree|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|77\n77|
s6-1-4-direct-constraint-control.mdk|CONTROL for #1127: the SAME instance set, goal and call shape with `D a` declared DIRECTLY, so `dm` is reached by §3 `assum` instead of `super`. Native is CORRECT here (77/77), which localises the defect to the superclass-projection arm rather than to min⊑ selection|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|77\n77|
s8-i1-samename-independent-dict-arity/main.mdk|§8 I1: dict arity is keyed by BINDING IDENTITY, not bare name -- two modules` same-named `widget` abstract 1 and 0 dicts respectively (arity asserted structurally in section 3)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|101\n201|
s8-i1-samename-unconstrained-poly-callee/main.mdk|§8 I1, THE EVAL-PATH HALF ITS `s8-i1-samename-independent-dict-arity/` SIBLING CANNOT ASSERT (RUN-XMOD-049, #1425). That sibling`s two arity rows in section 3 read the EMIT path, where `runEmitWith` has already run `mangleUnits` and made the bare keys accidentally identity-bearing, so they are structurally incapable of failing on this defect class however broken the eval path is; and its value row cannot see it either, because its `pick` is MONOMORPHIC so define and call site agree on the phantom slot and the number is right by accident. Here the unconstrained same-named binding is POLYMORPHIC (`a -> a`), so a phantom leading dict parameter is VALUE-OBSERVABLE -- it returns the dictionary instead of its argument. Hand-derived, not captured: `C.pick (1 : Int)` = `sz 1 + 100` = 101, `U.use 1` = `pick 1 + 200` = 201. MEASURED KNOWN-BAD at a1086fbb: `run` printed 101 and then died `E-PANIC: unknown op `+`` (the phantom dict being added to 200) while `build`+execute printed the correct 101/201. ⚠️ THE ENTRY`S IMPORT ORDER IS LOAD-BEARING -- `umod` first; in the other order this fixture is GREEN AT BASE and asserts nothing, because #1425`s two sites mask each other. See main.mdk`s header|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|101\n201|
s8-i1-samename-wildcard-import-callee/main.mdk|§8 I1 UNDER THE WILDCARD IMPORT SPELLING (RUN-XMOD-054, #1425 F1). The two siblings above grade the ALIASED and same-module-local spellings; no fixture in this tree contained a wildcard import paired with a same-named constrained sibling, and `grep -rn "^import [a-z_]*\.\*" compiler/ stdlib/` returns ZERO files -- so fixpoint, selfproc and check-self are all structurally blind to this class, which is how the #1425 dict-arity fix repaired the aliased arm and broke this one with every gate green. A wildcard-imported name contributed no row to `currentImportDefinersRef`, so `declaredConstraintFor` fell through to the bare-name table and `cmod.pick``s constrained row answered for `umod.pick`. Hand-derived, not captured: `C.pick (1 : Int)` = 101, `pick 1 + 200` = 201. MEASURED KNOWN-BAD at fb7f3544 in BOTH import orders: `run` printed 101 then died `E-NOT-A-FUNCTION: applied non-function: <dict:>`, `check` exited 0, the built binary was correct. ⚠️ Order-INVARIANT, so `test/diff_compiler_import_order.sh` reports it "invariant" and PASSES on the broken compiler -- the value assertion here is the only thing that sees it|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|101\n201|
s8-i1-samename-wildcard-transitive-definer/main.mdk|§8 I1 wildcard spelling where the ENTRY NEVER NAMES the colliding module -- `cmod` is two hops away, reachable only through `smod`. RUN-XMOD-054`s reason for calling F1 a SEAM symptom rather than an arm symptom: the poisoning reach of a bare-name arity table is the whole LOADED module set, not the entry`s own import list. Distinguishes a definer resolution keyed on the graph from one re-narrowed to the entry`s own clauses -- that regression keeps the `-wildcard-import-callee/` sibling green and reds this. Hand-derived: `hop 1` = 101, `pick 1 + 200` = 201. MEASURED KNOWN-BAD at fb7f3544, both orders: `run` 101 then `E-NOT-A-FUNCTION: applied non-function: <dict:>`|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|101\n201|
1426-wildcard-samename-verb-agreement/main.mdk|#1426 (wildcard-import escape), RE-POINTED HERE when the RUN-XMOD-054 seam repair drained it out of `test/must_fail_fixtures/1426-wildcard-samename-check-passes-run-build-fail/` (modules byte-identical). Same mechanism as the two rows above in the #739/#1070/#1326 family: `ps.h : Display a => a -> String` vs the wildcard-imported unconstrained `qs.h : a -> a`. The pin graded ONE verb; all four cells are graded here. Spec answer, from the pin`s own claim.txt: the program is well-typed and prints `ok / 5` at exit 0 on every verb. MEASURED KNOWN-BAD at fb7f3544: `check` 0 but `run` and `build` BOTH exit 1 with a generic `error: type error in main.mdk` -- three verbs, two answers. ⚠️ The pin recorded it ORDER-INDEPENDENT, so `import_order` cannot grade it either|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|ok / 5|
s8-i1-samename-reexport-selective-through-wildcard/main.mdk|§8 I1 ACROSS A SELECTIVE RE-EXPORT REACHED BY A WILDCARD IMPORT (RUN-XMOD-062, #1425 F1 third relocation). The two `-wildcard-` rows above grade a name a wildcard-imported module DECLARES; `rmod` here declares NOTHING and only `export import umod.{pick}`. The RUN-XMOD-054 repair`s supply walk enumerated declared exports, so this name got no row in `currentImportDefinersRef`, `declaredConstraintFor` fell to the source-blind bare-name table, and `cmod.pick``s CONSTRAINED row answered for the unconstrained `umod.pick`. Hand-derived from the two declared signatures, not captured: `C.pick (1 : Int)` = `sz 1 + 100` = 101, `pick 1 + 200` = 201; a re-export changes neither binding`s identity. MEASURED KNOWN-BAD at b313d767 in BOTH import orders: `run` 101 then `E-NOT-A-FUNCTION: applied non-function: <dict:>`, `check` exit 0, built binary CORRECT -- three verbs, two answers. ⚠️ Order-INVARIANT, so `import_order` reports it "invariant" and PASSES on the broken compiler|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|101\n201|
s8-i1-samename-reexport-wildcard-through-wildcard/main.mdk|§8 I1 across a WILDCARD RE-EXPORT reached by a wildcard import (RUN-XMOD-062). Varies exactly ONE token against the row above -- `export import umod.*` instead of `export import umod.{pick}` -- which is the discrimination this row exists for: a supply side that resolves re-exports by ENUMERATING their forms can cover the selective spelling and miss this one, and from the sibling alone that failure is indistinguishable from "already fixed". Hand-derived: 101 / 201. MEASURED KNOWN-BAD at b313d767: `run` 101 then `E-NOT-A-FUNCTION: applied non-function: <dict:>`|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|101\n201|
s8-i1-samename-reexport-transitive-definer/main.mdk|§8 I1 across a re-export where THE ENTRY NAMES NEITHER MODULE (RUN-XMOD-062): `cmod` is two hops away behind `smod`, and `pick``s definer `umod` is reachable only through `rmod``s `export import`. Same reason its `-wildcard-transitive-definer/` sibling exists one relocation earlier -- the poisoning reach of a bare-name arity table is the whole LOADED module set, not the entry`s import list -- so a definer resolution re-narrowed to the entry`s own clauses keeps both rows above green and reds this. Hand-derived: `S.hop 1` = 101, `pick 1 + 200` = 201. MEASURED KNOWN-BAD at b313d767: `run` 101 then `E-NOT-A-FUNCTION: applied non-function: <dict:>`|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|101\n201|
s8-i1-samename-reexport-selective-import-control/main.mdk|CONTROL for the three `-reexport-` rows above and the DISCRIMINATOR proving the variable is the IMPORT FORM (RUN-XMOD-062): byte-identical to `-selective-through-wildcard/` except main.mdk`s first line, `import rmod.{pick}` here against `import rmod.*` there. MEASURED CORRECT at b313d767 while its wildcard twin panicked -- which is how the third relocation was identified as the same seam defect rather than a new one. Also the row that catches the repair`s widening of the NAMED forms: a named import`s row now carries the TRUE definer (`umod`) rather than the spelled module (`rmod`), so if that resolution ever stops working this cell moves while nothing else does. Hand-derived: 101 / 201|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|101\n201|
s8-i2-global-instance-env/main.mdk|§8 I2 / §6 C4: `IE` is assembled across the WHOLE import graph -- the sole `impl Sz Coin` is reached only transitively, and `main` never imports its module at all|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|42|
s8-i3-evidence-travels/main.mdk|§8 I3: a constrained binding does not re-resolve its own predicates -- the only impl is declared DOWNSTREAM of `twice`, so the dict provably came from the call site|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|42|
s3-nary-sig-constraint-goal-vector.mdk|§1/§3 `match(IE,C τ̄)` on the `=>`-CONSTRAINED-SIGNATURE leg: `useIx : Ix a Char => a -> Int` at `a := Int` gives the goal `Ix Int Char`, whose matching set is the SINGLETON {`Ix Int Char`} -- `Ix Int Bool` never reaches the selector. 222 (#1161 regression pin -- the signature`s predicate was SHATTERED into one dict slot per BARE-TYVAR argument, so `Char` was discarded at registration, the arg-0-only goal made both impls match, they are incomparable, and DECLARATION ORDER printed 111 at exit 0 on both engines). Section 4 permutes it. ⚠️ THIS ROW IS ALSO THE ACCEPT-DIRECTION GUARD FOR THE OBLIGATION-CHANNEL NARROWING that drained #1161 symptom 2: a GROUND predicate argument with a satisfying impl present must still be ACCEPTED, and routed to that impl rather than to the competing `Ix Int Bool`. An over-rejecting tightening of `declaredOblOne` reds this row before anything else. Symptom 2 itself (an UNSATISFIABLE `Ix a Bool =>` accepted at exit 0, context dropped from the scheme) DRAINED 2026-08-23 and is now graded at s3-sig-constraint-unsatisfiable-rejects.mdk below|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|222|
s3-nary-sig-constraint-structured-arg.mdk|§3 the same judgement with a STRUCTURED predicate argument, `Ix a (List b) =>`: the goal `Ix Int (List Char)` again matches a singleton, 222. THE ONLY DEFENCE against the substitution half of the #1161 fix -- the stored vector lives in the SIGNATURE`s instantiation vars, so a top-level-only substitution leaves the interior `b` of `List b` a stale signature var, `matchTyMonos` fails against BOTH ground heads, and an EMPTY candidate set degrades to first-declared (measured during scoping: 222 -> 111). ⚠️ F-3c (#1155) structurally CANNOT cover this class: `pickMostSpecificEntry []` returns None rather than taking the ambiguity arm, so an empty candidate set stays silently first-match even after that arm goes loud|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|222|
s3-sig-constraint-unsatisfiable-rejects.mdk|§3 THE REJECT DIRECTION of the same leg -- #1161 SYMPTOM 2, DRAINED 2026-08-23 by S-obligation-nary-payload and re-pointed here from test/must_fail_fixtures/1161-sig-constraint-unsatisfiable-accepted per [G-PIN-DRAIN]. `useIx : Ix a Bool => a -> Int` called at `a = Int` gives the goal `Ix Int Bool`; the program declares only `impl Ix Int Char`, so §3`s matching set is EMPTY and the goal is a missing-instance rejection. It was ACCEPTED at exit 0 printing 222 -- the body of an impl the goal matches on NEITHER argument -- because the obligation payload was IDS ONLY (`VecObl.voIds`), `constraintArgMonos` answered `None` for the ground argument `Bool`, and `declaredOblOne` discarded the whole predicate: nothing recorded, nothing checked, and `check` printed the scheme as `useIx : a -> Int` with the context silently gone. ⚠️ ONE impl, so Section 4 derives no permutation pair -- deliberately: the defect here was ACCEPTANCE, not order|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s9-vector-valued-entailment-rejected.mdk|§9 signature authority: the `Q_sig ⊩ P`ᵢ` side condition is VECTOR-VALUED -- `{Ix a b, Ix c d}` does not entail a joint `Ix a d` even though every ARGUMENT appears. The row that separates a real n-ary obligation from #607`s two single-param facts|REJECT|REJECT|REJECT|NONE||T-MISSING-CONSTRAINT
b1-xmod-default-inherited-tag/main.mdk|ARCH B-2 (B-2.2-b1): `keyForSite`s NO-ROW arm. A CROSS-MODULE method-less impl inherits the interface default -- `fillImplDefaults` is same-module only, so the impl has no method entry, the candidate scan cannot see it, and `fromOption tag` supplies the `<TAG>` of `@mdk_default_sz_Box`. Its SAME-MODULE twin in the same program takes the ordinary tagged route. ⚠️ THE VALUE CANNOT DISCRIMINATE (both arms answer 42 and both exit 0 even with a wrong symbol, until the link fails) -- section 3 carries it|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4242|
b1-xmod-default-absent-rejected/main.mdk|THE FAIL-CAPABLE HALF of the row above: the same program with the interface default DELETED, one dimension flipped. Must stay a LOUD reject naming the missing method. It also BOUNDS the no-row arms live population to the default-inheriting shape -- with no default there is nothing for `emitDefaultRKey` to lift and no engine ever runs it|REJECT|REJECT|REJECT|NONE||T-INCOMPLETE-IMPL
b1-p4-super-slot-unique-heads/main.mdk|ORGAN 4 (P4) TRIPWIRE, UNIQUE-HEAD half. `both` declares one predicate and `expandSupersPairs` APPENDS a `Base` super slot, so the definition takes 2 dicts for a 1-argument function. With ONE impl per interface the collision gate is False at BOTH slots, so both still carry the bare head tag and the SAME dict constant is passed twice -- `B-2.2-b1` deliberately does NOT move this program, and this row is what proves it did not widen identity unconditionally. Distinct bodies make a copied route observable (a super slot resolving to the subs row prints 202)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|201|
b1-p4-super-slot-colliding-heads/main.mdk|ORGAN 4 (P4) TRIPWIRE, COLLIDING-HEAD half -- where the word IS expected to move. Two impls of `Base` at head `Box` turn the collision gate True at the appended super slot only, so the two slots carry DIFFERENT words: section 3 pins that the site passes two DISTINCT dict constants here where the sibling passes one twice. ⚠️ 201 is also what a wrongly-routed super slot can print (203 is the `Box String` row), so the value is a floor and the symbols are the assertion|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|201|
b1-p4-super-slot-no-base-impl-rejected/main.mdk|NEGATIVE CONTROL (PC1) for both P4 rows: delete `impl Base T` and the superinterface obligation rejects at exit 1. Without it, a regression that made the appended super slot VANISH rather than mis-resolve would keep every other P4 assertion green while the tripwire stopped watching anything|REJECT|REJECT|REJECT|NONE||T-MISSING-SUPER-IMPL
b1-xmod-same-spelled-iface-impl-selection/main.mdk|§8 I4 + §3 `inst` -- THE ISSUE 1514 DRAIN, and the ONLY row in this corpus whose VALUE the module-qualified identity decides. Promoted from the drained must_fail pin `1514-xmod-same-spelled-iface-impl-selection`: a pin asserts a bug STILL REPRODUCES, so a fix deletes it and the S0 has NO guard unless a positive row replaces it. TWO UNRELATED modules (no import edge either way) each declare their OWN `Same`/`Blob`/`impl Same Blob`, and each computes its own value INSIDE ITS OWN MODULE, so neither goal has a second candidate. SPEC ANSWER hand-derived from §8 I4 (an interface is identified by its DECLARATION): aValue = 10+1 = 11, zValue = 10+100 = 110, bystanderValue = 5+1+1 = 7. 🚨 MEASURED PRE-BITE, in the drained pins own recorded cells: check exit 0, `run` printed 11 / 11 / 7 -- SILENT WRONGNESS, zValue taking amods `n + 1` -- while the BUILT BINARY printed the correct 11 / 110 / 7. The two engines actively DISAGREED, which is what makes the drain causal; ALL_EXACT requires them to agree with each other AND with the pinned value, so that state fails this row twice over. ⚠️ THE FIVE `b1-*` ROWS ABOVE DO NOT COVER THIS -- they pin the WIRE FORMAT, and the colliding-heads row separates its impls by TYPE ARGUMENT (`Box Int` vs `Box String`), which the pre-bite word already separated; the module prefix is decoration there. ⚠️ SCOPE BOUND (DEBT.md D-2): the DIRECT shape only. The WRAPPER shape -- dispatch reaching the collision through a function in a third module -- is measurably NOT drained and stays import-order-dependent on both arms. A drained fixture is not a drained class|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|11\n110\n7|
b1-xmod-distinct-spelled-iface-control/main.mdk|CONTROL for the row above, promoted from the same must_fail pins own `control.mdk`. ONE dimension varied: whether the two unrelated modules interface/type/method spellings COLLIDE. `amod.mdk` and `bystander.mdk` are BYTE-IDENTICAL to the siblings; `zmod2.mdk` keeps zmods shape and arithmetic byte-for-byte and spells them `Same2`/`Blob2`/`sizeOf2`. ⚠️ THE VALUE IS THE SAME AS THE SIBLINGS ON PURPOSE -- the answer must not depend on the collision -- so this pair is read by WHICH MEMBER REDS, not by their values differing: sibling red + control green localises a regression to the collision, both red says cross-module dispatch broke generally. That contrast is not hypothetical -- pre-bite the sibling`s `run` printed 11 / 11 / 7 while this file already printed 11 / 110 / 7 on the same binary, which is what made the defect attributable to the spelling collision rather than to the module boundary|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|11\n110\n7|
b1-xmod-same-spelled-iface-constrained-wrapper/main.mdk|§8 I4 + §3 -- THE SAME COLLISION REACHED THROUGH A CONSTRAINED WRAPPER, and the row that pins a DETERMINISTIC NATIVE SEGFAULT out of existence. The direct-dispatch sibling above with ONE structural variable added: each module routes its call through its own `Same a => a -> Int` wrapper, so the site is GENERIC and receives a dict CONSTANT as an argument. Heads are DISTINCT (`ABlob`/`ZBlob`); the interface SPELLING is all the two unrelated modules share. SPEC ANSWER hand-derived: each wrapper is declared in the module whose `Same` is the only one in its scope, so its predicate denotes that modules class and each goal has a singleton matching set -- 10+1 = 11 and 10+100 = 110, i.e. (11, 110). 🚨 MEASURED ON TWO PRE-BUILT ARMS: base built at exit 0 and the BINARY SEGFAULTED 3 runs of 3 (139, E-FATAL-SIGNAL) while `run` answered (11, 11); branch answers (11, 110) on both engines at exit 0. IR-read mechanism: base handed the SAME dict constant to both generic calls while the dispatcher tested one tag in BOTH arms, so no arm matched and control fell through to `unreachable`. ⚠️ NOT PRESENTED AS FIXING A FILED ISSUE -- it is an EMERGENT consequence of the route-word change and no issue we have identified covers it; the row exists so the repair cannot be silently lost. ⚠️ THE VALUE ALONE IS INSUFFICIENT and the section-3 rows are not decoration: base`s `run` answered (11, 11) while base`s BINARY died, so a run-only grade would see a wrong value and never the crash, and an exit-code-only grade would see 139-vs-0 without knowing why. ⚠️ THE WRAPPER IS THE VARIABLE -- without it the same two modules merely answer wrongly (that is the sibling); the dict-taking generic site is what turns a wrong selection into a memory fault|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|(11, 110)|
b4bii-xmod-same-spelled-iface-requires-decl-order/main.mdk|§8 I4 + §3 -- THE B-4b-ii SUPPLY DISCRIMINATOR, and the ONE row whose VERDICT the supply decides. Two unrelated modules each declare their own `interface Same a` (disjoint methods `bar`/`foo`, no import edge either way) and each impls it at the SAME SHARED head `Box a` from a third module; `amod`s impl carries `requires Eq a`, `zmod`s carries none. SPEC ANSWER hand-derived from §8 I4 BEFORE any binary was run: `foo (Box Opaque)` may only discharge against `zmod.Same`s impl, which has no context, so the `Eq`-less `Opaque` needs nothing -- 1; `bar (Box 1)` discharges `amod`s `requires Eq a` at `Eq Int`, which holds -- 2; total 3, ACCEPT. 🚨 MEASURED AS A FALSE REJECT ON THE B-4b-i BASE BINARY (this worktree, its own stdlib/runtime/emitter): check/run/build ALL exit 1 with ``No impl of Eq for Opaque`` pointed at `foo (Box Opaque)` -- a constraint the program never wrote, imposed by the OTHER modules class, because `findMatchingImplReqsU`s CONCRETE leg re-minted its query through `ifaceRefBare` and compared a bare SPELLING while its own HEADLESS sibling leg (`univHeadless` -> `oblIfaceKey`) was already identity-keyed. The `!T-NO-IMPL` assertion is what makes the row FAIL-CAPABLE: re-mint that query bare and it reds. ⚠️ THE SHARED HEAD IS LOAD-BEARING, exactly as `s6-c1-xmod-same-spelled-ifaces-accepted`s header records -- the selectors HEAD half is already identity-aware, so two module-local heads would mask the interface half entirely. ⚠️ AND THE `-swapped` SIBLING IS HALF THE ASSERTION: it is this program with the two module names exchanged and nothing else, and it ACCEPTED at 3 on that same base binary. Either fixture ALONE passes an order-decided compiler|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3|!T-NO-IMPL
b4bii-xmod-same-spelled-iface-requires-decl-order-swapped/main.mdk|CONTROL for the row above, and a control in the strict sense: it flips exactly ONE dimension -- which of the two same-spelled classes sorts first -- and the correct answer is UNCHANGED at 3, by the identical derivation. It ACCEPTED at 3 on the B-4b-i base binary while its sibling was rejected, and that asymmetry IS the finding: an answer decided by declaration order is invisible from whichever ordering happens to be lucky, so a compiler that selects by spelling passes THIS row. Do not merge the two, and do not rename the modules to match -- the sort order of the module ids is the variable|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3|!T-NO-IMPL
b4bii-xmod-foreign-empty-context-discharged/main.mdk|§8 I4 + §6 C2 -- THE SOUNDNESS HOLE B-4b-ii CLOSES, and the ONLY row in this corpus asserting the FALSE-ACCEPT direction of the same-spelled collision (the bites other rows all assert the false-REJECT direction, so without this one the win is unclaimed and ungraded). `viaA` is AMODs constrained standalone, so its `Same a` is `amod.Same` and the impl that must witness it at `Box Opaque` is AMODs `impl Same (Box a) requires Eq a`; that context grounds to `Eq Opaque`, which has NO instance anywhere in the program. SPEC ANSWER hand-derived before any binary was run: REJECT. 🚨 MEASURED AS A SILENT FALSE ACCEPT ON A BASE BINARY cold-built from origin/main @ 2c549fef with its own stdlib/runtime: check exit 0, run exit 0 PRINTING 1, build exit 0, executed binary 1 -- the checker reached ZMODs row by SPELLING and discharged ITS empty context in amods place, so a program whose selected impl declares an unsatisfiable constraint ran to completion with no diagnostic. ⚠️ THE VALUE 1 IS WHAT MAKES THIS SOUNDNESS RATHER THAN MERE ACCEPTANCE: 1 is ZMODs body, so the base binary did not just accept the program, it ran the OTHER classs method for it. The `T-NO-IMPL` assertion is what makes the row FAIL-CAPABLE: re-mint `findMatchingImplReqsU`s concrete query through `ifaceRefBare` and this row goes green-at-exit-0 and reds here|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
b4bii-xmod-req-route-leg-still-spelling/main.mdk|§6 C2 -- WHERE B-4b-iis DELIBERATE ASYMMETRY IS OBSERVED RATHER THAN ARGUED. The supply landed at ONE of the `*ByIface` familys three entry points (`findMatchingImplReqsU`, the CHECKER leg); the two ROUTE-WORD entry points (`entailInst`s `EKNestedTop` arm and `argImplRequiresRoutes`) still mint a bare query, because their upstream (`shadowStandaloneDictSlots` / `pushDictApp`) projects `csIface.irName` on purpose and that projection is the route-word design question, not an identity-supply omission. This program puts BOTH legs on the same goal: a CONSTRAINED STANDALONE `useIt : Same a => a -> Int` in `zmod` is called at `Box Opaque`, so the checker selects `zmod.Same` by IDENTITY while the router selects over the same two candidate rows by SPELLING. SPEC ANSWER hand-derived first: `useIt (Box Opaque)` = 11 via `zmod`s context-free impl, `bar (Box 1)` = 22 via `amod`s `requires Eq a` at `Eq Int`; total 33, ACCEPT. ⚠️ THE DICT IS THE ASSERTION, NOT THE NUMBER -- a router that reached `amod`s row would hand `useIt` a witness for the OTHER class, whose only slot is `bar`, and `foo x` would read that slot: a wrong value or a fault AT EXIT 0. Section 3s IR row is what a value-only assertion cannot see. ⚠️ MEASURED: this program was REJECTED at exit 1 on the B-4b-i base binary (the same false reject the `-decl-order` pair isolates), so the route leg had never been asked this question and this is a NEW cell, not a re-pin|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|33|!T-NO-IMPL
s8-xmod-reexport-alias-unconstrained/main.mdk|#1337 SCHEME-ENVIRONMENT IDENTITY -- THE ISSUE 1472 DRAIN. Promoted from the drained must_fail pin `1472-alias-reexport-null-dict-segfault`: a pin asserts a bug STILL REPRODUCES, so a fix deletes it and the S0 has NO guard unless a positive row replaces it. `export import` re-export + an ALIAS importer spelling: the key in the re-exporter`s public schemes is mangled for the DEFINER (`lib_plain__g`), so the alias arm`s spelled-mid-only prefix test answered False and re-bound it as `R.lib_plain__g` while private_mangle (which chases re-exports to the definer) had already rewritten the body`s reference to the bare `lib_plain__g`. SPEC ANSWER hand-derived from the declarations before any binary was run: `g : Int -> Int`, `g x = x + 1`, re-exported BY IDENTITY, so `R.g 1` = 2. 🚨 MEASURED PRE-FIX ON THIS WORKTREE`S OWN COLD-BUILT BASE BINARY: check 0, `run` printed the CORRECT `2`, build 0 -- EVERY BEHAVIOURAL SIGNAL GREEN -- and the EXECUTED BINARY died at 139 with EMPTY stdout (E-FATAL-SIGNAL, 3 runs of 3). ⚠️ THE VALUE ROW IS THEREFORE INERT ON ITS OWN: `run` printed `2` before and after the fix, and this gate`s ALL_EXACT compares run against build, both of which now agree. Section 3 carries this fixture -- it pins that `println`s LEADING DICT OPERAND is a real dict constant and NOT the null `i64 0` the emitter wrote pre-fix|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|2|
s8-xmod-reexport-selective-unconstrained-control/main.mdk|CONTROL for the row above, and the canary that keeps it honest: BYTE-IDENTICAL program but for the importer SPELLING (SELECTIVE `lib.rplain.{g}` / bare `g 1` instead of `as R` / `R.g 1`). Same definer, same re-exporter, same unconstrained `g`. SPEC ANSWER hand-derived identically: 2. ⚠️ THIS SPELLING WAS ALWAYS GREEN -- it resolves through `resolveMemberSchemes`, whose fallback is a `__<name>` SUFFIX test that is definer-agnostic BY CONSTRUCTION, so `"__g"` matches `lib_plain__g` no matter which module mangled it. That is what makes the PAIR the assertion rather than either file: sibling red + control green localises a regression to the alias arm; both red says the re-export hop itself broke. ⚠️ THE VALUE IS THE SAME ON BOTH ON PURPOSE (the answer must not depend on the spelling), which is exactly why the values cannot discriminate and section 3 carries both|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|2|
s8-xmod-reexport-alias-constrained/main.mdk|🚨 KNOWN-BAD (cites #1427, #1425): the `run` cell below pins a WRONG state on purpose -- the panic is a known-open dict-arity bug, not the correct answer -- and it is EXPECTED to go RED the day #1425 lands (re-point to ALL_EXACT/2 and close #1427 then, per RUN-XMOD-036). Read that RED as the expected repair, not a regression. #1337 SCHEME-ENVIRONMENT IDENTITY -- THE ISSUE 1427 BUILD-ARM DRAIN, and the one row in this group whose `run` cell is REJECT. Same conjunction as the unconstrained sibling (`export import` + ALIAS spelling) with ONE dimension flipped: the callee is CONSTRAINED (`Num a => a -> a`), so the SAME missed scheme-env lookup reaches `inferDictAt`s panic instead of silently corrupting a prelude dict. SPEC ANSWER hand-derived: `f x = x + 1` at `Int`, so `R.f 1` = 2. 🚨 MEASURED PRE-FIX on this worktree`s own cold-built base binary: `medaka build` FAILED OUTRIGHT -- exit 1, `error: emitter failed compiling main.mdk` / `E-PANIC: unbound constrained fn: lib_decl__f`, NO BINARY. Post-fix build exits 0 and the binary prints `2`. 🚨 THE `run` CELL IS PINNED AS MEASURED, NOT FORCED GREEN: `medaka run` still panics `E-PANIC: intToString: not an Int` (exit 1, 0 bytes stdout). That is a DIFFERENT MECHANISM on a DIFFERENT channel -- the #1369/#1425 DICT-ARITY seam -- and its own control below shows the IDENTICAL panic under the SELECTIVE spelling, which is what proves the residue is not the alias spelling and not this fix`s to close. #1427 STAYS OPEN until the dict-arity seam lands. ⚠️ PLAIN `BUILD_EXACT`, not the `<run>%%<build>` split: `run` emits ZERO bytes before dying and the split half is compared through `printf %b\n`, which turns an empty expectation into a 1-byte newline that can never match a 0-byte capture -- so there is no reach point to pin, and run`s stderr is ungradeable (#1130). When `run` flips to ACCEPT this row REDS: that is the drain -- re-point it to mode ALL_EXACT with value 2, and close #1427 then|ACCEPT|REJECT|ACCEPT|BUILD_EXACT|2|
s8-xmod-reexport-alias-wildcard-twoimpl/main.mdk|🚨 KNOWN-BAD (cites #1427; RUN-XMOD-070 F1): the `run` cell below pins the SAME known-open dict-arity panic as the row above, on purpose, and is expected to flip in lockstep with it the day #1425 lands. This row closes TWO gaps the sibling above does not: (1) it is the WILDCARD re-export spelling (`export import lib.decl.*`, this fixture`s `lib/rwild.mdk`) of the identical `aliasEntriesFor`-keyed-on-spelled-module disagreement -- the SELECTIVE spelling above was the only one graded, and the wildcard cell reproduces byte-identically and was ungraded anywhere in this tree; (2) `lib.decl`s interface `Sz` carries TWO impls (`Sz Int`, `Sz String`), so the build arms value discriminates a CORRECTLY-routed dict per call site from a single winning dict masquerading as correct -- the sibling rows single-impl program cannot tell those apart. SPEC ANSWER hand-derived from the declarations before any binary was run: `sz : a -> Int`, `impl Sz Int (sz n = n)`, `impl Sz String (sz s = 1000)`, `f x = sz x + 100`. `R.f 1` -> `Sz Int`, sz 1 = 1, f = 101. `R.f "abc"` -> `Sz String`, sz "abc" = 1000, f = 1100. 🚨 MEASURED on this worktree`s own cold-built binary: `check` exit 0; `run` exit 1, `E-PANIC: intToString: not an Int`, ZERO bytes on stdout (dies evaluating the very first `R.f 1`, same channel as the selective sibling); `build` exit 0, executed binary prints `101` then `1100` -- BOTH values correct, proving each call site routed to its OWN dict rather than one impl winning for both. Emitted IR (section 3 below) shows the two call sites passing DIFFERENT dict constants to the same definer symbol `@mdk_lib_decl__f`. PLAIN `BUILD_EXACT`, not the `<run>%%<build>` split, for the same reason as the sibling row: `run` emits zero stdout bytes before dying and the split cannot represent an empty expectation (#1130). #1427 STAYS OPEN until the dict-arity seam lands; when `run` repairs, re-point this row to ALL_EXACT/`101\n1100` alongside the sibling|ACCEPT|REJECT|ACCEPT|BUILD_EXACT|101\n1100|
s8-xmod-reexport-selective-constrained-control/main.mdk|CONTROL for the row above, doing TWO jobs. (1) It localises an alias-arm regression, as the unconstrained pair`s control does. (2) IT IS THE ATTRIBUTION FOR THE SIBLING`S REJECTING `run` CELL -- this spelling was ALWAYS green on `build` (it never had the scheme-env defect) yet its `run` panics identically. One spelling broken and one green on BUILD, BOTH broken identically on RUN, is what shows the run panic rides a different channel from the build failure. Without this row the sibling`s REJECT could be misread as "the alias fix was incomplete". SPEC ANSWER hand-derived identically: 2 on the build arm. ⚠️ ITS CELLS ARE IDENTICAL TO THE SIBLING`S BY CONSTRUCTION -- that identity IS the assertion, so if this row ever diverges from the sibling on `run`, the two channels have been conflated 🚨 RE-POINTED AT RUN-XMOD-062: this row`s `run` cell DRAINED. The repair derives a re-exported name`s definer through the one admission predicate, so `f``s qual entry is found under its TRUE definer `lib.decl` instead of being missed under the spelled `lib.rsel` and read as "genuinely unconstrained" -- the dict is no longer dropped and `run` prints 2 at exit 0, agreeing with `build`. The identity-with-the-alias-sibling that this row used to assert is GONE ON PURPOSE and its absence is now the assertion: the alias sibling still REJECTS on `run` because `aliasEntriesFor` keys its copied qual entries on the SPELLED module, a site this repair did not touch. ⇒ #1427`s residue is now ALIAS-SPECIFIC; if this row ever goes back to REJECT the named-form definer resolution has regressed|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|2|
s8-xmod-reexport-direct-import-constrained-control/main.mdk|NO-HOP CONTROL for the `export import` re-export family, RE-POINTED here from `test/must_fail_fixtures/1369-export-import-constrained-callee-no-dict/` when RUN-XMOD-062 drained that pin (#1369: a constrained callee reached through a re-export hop received NO dictionary; `check` 0, `run` panicked `E-PANIC: intToString: not an Int`, `build`+execute correct). The pin graded ONE verb on its main arm and carried this control UNGRADED beside it; the main arm is now the `s8-xmod-reexport-selective-constrained-control/` row four rows up, which grades all four cells, and this is the dimension that would otherwise have been lost. It is what isolates the defect to the RE-EXPORT HOP rather than to the constrained binding: byte-identical to that sibling but importing `lib.decl.{f}` DIRECTLY. Hand-derived from the declaration: `f x = x + 1` at `Int`, so `f 1` = 2. MEASURED CORRECT ON BOTH ARMS -- an unchanged cell on purpose; if it moves, the regression is in ordinary named-import dict routing, not in re-exports|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|2|
s8-xmod-reexport-alias-perm-ab/main.mdk|#1337 THE PERMUTATION ROW, ORDERING 1 of 2 (packet Amendment A condition 2): ONE import spelling (ALIAS), ALL orderings of the re-export declarations, asserting ONE signature. Section 4 permutes `impl` blocks and auto-derives its pair set from single-FILE fixtures, so it cannot reach a multi-file re-export hub -- this explicit `-ab`/`-ba` pair is how order-invariance-within-a-spelling stays graded for this shape (two declarations, so 2! = 2 orderings and the pair IS all of them). A re-export HUB over TWO DIFFERENT definers, so the hub`s public schemes carry keys mangled for two different modules (`lib_pa__ga`, `lib_pb__gb`). THIS IS THE ROW THAT TESTS THE WIDENING ITSELF: the fix replaced a single-module prefix test with a LOADED MODULE-ID SET membership test, and a set test must not care which member matched or in what order the set was built -- an order-sensitive widening would make the two orderings disagree. SPEC ANSWER hand-derived from the declarations: `ga x = x + 1`, `gb x = x * 10`, both `Int -> Int`, both re-exported by identity, so `combine x = H.ga x + H.gb x` is `Int -> Int` and `combine 3` = (3+1) + (3*10) = 34. ⚠️ THE TWO DEFINERS` ARITHMETIC DIFFERS ON PURPOSE -- had both used `+ 1`, swapping which definer a key resolved to would leave the value UNCHANGED and this pair would be inert|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|34|
s8-xmod-reexport-alias-perm-ba/main.mdk|THE PERMUTATION ROW, ORDERING 2 of 2: `lib/hub.mdk`s two `export import` lines EXCHANGED and nothing else varied (definers, spellings, arithmetic and call shape byte-identical to the `-ab` sibling). ⚠️ READ THE PAIR, NOT THE ROW: the value being the SAME as the sibling`s is the entire assertion -- an identical value here is order-invariance, and either fixture ALONE passes an order-decided compiler. Same hand-derived ground truth: 34|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|34|
s8-xmod-alias-name-collides-core-mangle/main.mdk|RUN-XMOD-039 F1 REGRESSION PIN, and one half of the FEATURE-LANDED-PLUS-UNRELATED-CODE-STILL-BEHAVES pair this corpus was missing. ⚠️ NOTHING HERE EXERCISES THE #1337 FEATURE: no `export import` anywhere, no re-export hop, one dependency, one alias import -- which is exactly the point, because AGENTS.md names this the single most expensive defect shape in the tree ("your feature works perfectly and something unrelated breaks") and every fixture that DOES exercise the feature passes straight through it. SPEC ANSWER hand-derived from the declarations: `core__foo : Int` = 7 in lib/other.mdk, bound as `O.core__foo` by the alias import, so 7. 🚨 MEASURED AS A REGRESSION INTRODUCED BY THIS SLICE`S FIRST VERSION, on this worktree`s own build: check AND run AND build all exit 1 with ``Unbound variable: O.core__foo`` (plus a cascaded `Ambiguous instance for Display`), no binary -- because the widened test seeded its module-id set with `"core"` and `mangledName "core" "" == "core__"`, so an ordinary user binding was misread as already-mangled. The base binary printed 7. ⚠️ THE IDENTIFIER IS THE FIXTURE -- rename `core__foo` to a normal name and this row still passes while testing nothing|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|7|
s8-xmod-alias-name-collides-sibling-mangle/main.mdk|RUN-XMOD-039 F2 REGRESSION PIN -- THE ROW THAT BOUNDS THE COLLISION SURFACE, and strictly the more important of the pair. F1`s trigger was one hardcoded constant and deleting it sufficed; THIS one is not a bad constant but a bad KIND OF TEST: with a spelling-keyed decision every module named `a.b` makes `a_b__x` a landmine, so the false-positive surface is UNBOUNDED AND GROWS WITH THE MODULE GRAPH. `lib.other` exports an ordinary binding literally spelled `lib_plain__g` while a DIFFERENT module `lib.plain` (sanitizing to `lib_plain`) is also loaded. SPEC ANSWER hand-derived: `lib_plain__g` = 42, `g x = x + 1` so `g 1` = 2, total 44. 🚨 MEASURED AS A REGRESSION on this worktree`s own build of the slice`s first version: check/run/build all exit 1, ``Unbound variable: O.lib_plain__g`` -- and the diagnostic gave NO hint of the real cause, naming a binding as unbound while it was declared and exported two lines away. Base printed 44. ⚠️ THE REMEDY WAS A CHANGE OF KIND, NOT A NARROWER PATTERN: the test now asks whether the key is a name some loaded module ACTUALLY EXPORTS under its own mangled form, so the golden-path `lib.plain` (which exports the bare `g`) does not match while an emit-path re-exported `lib_plain__g` does. A future agent who repairs a regression here by TIGHTENING THE PREFIX MATCH has reintroduced the class with a smaller surface, not removed it. ⚠️ BOTH IMPORTS ARE LOAD-BEARING -- `import lib.plain.{g}` is what puts `lib.plain` in the loaded set; drop it and the row is inert|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|44|
1386-alias-qualified-obligation-checked/main.mdk|§8 I4-adjacent -- THE ISSUE 1386 DRAIN, RE-POINTED from the drained must_fail pin test/must_fail_fixtures/1386-alias-qualified-method-no-obligation-check: a pin asserts a bug STILL REPRODUCES, so a fix deletes it and the S0 has NO guard unless a positive row replaces it. `A.mth` unambiguously names ifaceas `IA.mth` -- `A` is an alias of `ifacea`, which exports no standalone `mth`, only `IA.mth`; `Blob` implements only `IB` (method `mthb`, deliberately NOT `mth`, so there is no bare-name collision to fall through to). SPEC ANSWER hand-derived, matching the drained pins own claim.txt: reject, `No impl of IA for Blob`. 🚨 MEASURED PRE-FIX (recorded in the drained pins claim.txt): `medaka check` exited 0, `main : Unit`, no diagnostic at all -- the impl obligation for an alias-qualified method occurrence was never checked (`renameAliasedMethods` and `checkImplObligations` were gated on mutually exclusive settings of one flag). Fix: `compiler/types/typecheck.mdk` supplies an `A.<method>` -> declaring-Ident entry for every method the aliased module exports, so `recordImplObligation` now sees this occurrence|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
1386-alias-qualified-obligation-checked/control.mdk|CONTROL for the row above, carried over from the drained pins own control.mdk. Same alias-qualified call shape, same two-interface program, `Blob` genuinely implements `IA` this time -- the interface the occurrence actually names. A valid program that must ACCEPT and print 1. If it breaks, alias-qualified method resolution broke outright, not #1386s narrower obligation-never-checked defect|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|1|
1276-alias-run-arm-obligation-checked/main.mdk|§8 I4-adjacent -- THE ISSUE 1276 DRAIN, RE-POINTED from the drained must_fail pin test/must_fail_fixtures/1276-alias-method-provenance-erased: a pin asserts a bug STILL REPRODUCES, so a fix deletes it and the S0 has NO guard unless a positive row replaces it. Same fix as #1386 above; DIFFERENT symptom -- `A.mth` unambiguously names ifaceas `IA.mth`, `Blob` has no `IA` impl, only an `IB` one, and `IB` ALSO declares a method spelled `mth` (a bare-name collision, unlike #1386s fixture). SPEC ANSWER hand-derived, matching the drained pins own claim.txt: reject, `No impl of IA for Blob`. 🚨 MEASURED PRE-FIX (recorded in the drained pins claim.txt): `check` AND `run` were BOTH clean at exit 0 and `run` printed `2` -- IB`s impl body, selected by the pre-fix bare-name last-write-wins floor once the alias had been erased to a bare `mth` occurrence -- SILENT WRONGNESS at a wrong VALUE, not merely a missed reject. Fix supplies the same alias-provenance entry as #1386s row, closing the same root cause from its OTHER symptom|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
1276-alias-run-arm-obligation-checked/control.mdk|CONTROL for the row above, carried over from the drained pins own control.mdk. Same alias-qualified call shape, same two-module bare-name `mth` collision, `Blob` genuinely implements `IA`. A valid program that must print 1. If it breaks, alias imports or alias-qualified method calls broke outright, not #1276|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|1|
1386-alias-reproB-standalone-collision-rejected/main.mdk|#1386 REPRO B -- constructed fresh per S-alias-supplys report §6.3 (this shape had no committed must_fail fixture; it was only a scratch probe verifying the fix took the SUPPLY shape rather than a de-alias REWRITE, per #1386s own claim.txt why-note (1)). `A.mth` unambiguously names ifaceas `IA.mth`; `fmod` exports an UNRELATED standalone ALSO spelled `mth : Blob -> Int`, returning 42; `Blob` has no `IA` impl at all. SPEC ANSWER hand-derived: reject, `No impl of IA for Blob`. 🚨 DISCRIMINATES THE TWO CANDIDATE FIX SHAPES #1386s claim.txt considered: a de-alias REWRITE of the occurrence (which would leave this cell silently printing 42, fmods standalone body, because the rewritten bare `mth` would resolve to the co-imported standalone) versus the SUPPLY shape actually landed (an additive `A.mth` -> IA keying, which rejects here exactly like the bare-collision siblings above). MEASURED on this worktree`s own build: check/run/build all reject with `No impl of IA for Blob`, confirming the SUPPLY shape|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
1386-alias-reproB-standalone-collision-rejected/control.mdk|CONTROL for the row above: same alias-qualified call shape and the same standalone-name collision, `Blob` genuinely implements `IA`. A valid program that must ACCEPT and print 1 (IAs own impl, not fmods standalone 42). If it breaks, alias-qualified method resolution broke outright, not #1386s narrower defect|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|1|
1182-alias-dispatch-half-known-bad/main.mdk|🚨 KNOWN-BAD LEDGER ROW (#1182 / #1265 class, OPEN) -- a DIFFERENT, PRE-EXISTING coverage gap, NOT drained by S-alias-supply and NOT touched by its fix: that fix repairs the CHECKED half (does an impl obligation exist for an alias-qualified occurrence); this pins the DISPATCH half (which impls body actually RUNS) still disagreeing with it. `Blob` implements BOTH `IA` and `IB`; `A.mth Blob` and `B.mth Blob` are alias-qualified calls naming TWO DIFFERENT interfaces. SPEC ANSWER hand-derived: 1 then 2, each call dispatching to the impl its own alias names. 🚨 OBSERVED (slice 2, `cdca5045`, changed which impl the last-write-wins floor picks for the collided name `mth`): 2 then 2 -- this move is NOT value-neutral. `renameAliasedMethods` still erases the alias to a bare `mth` before dispatch is decided, but `admittedIfaceFor "mth"` now answers from the last-write-wins `registerMethodIfaceParamsMethods` table (`typecheck.mdk:26481-26486`), which resolves to `IB` (declared second) for BOTH calls -- both collapse onto the second-declared impl now, not the first. The OLD pinned behavior (1,1) had the FIRST call (`A.mth Blob`) correct and the SECOND wrong; the NEW behavior (2,2) has the SECOND call (`B.mth Blob`) correct and the FIRST now wrong -- still one-of-two wrong, but a different one. ⚠️ THIS ROW IS EXPECTED TO STAY GREEN (i.e. KEEP reproducing the wrong value) until #1182/#1265 land -- a value change here is the signal to re-pin it, not a regression in this gate. No diagnostic code to pin: this program is silently ACCEPTED on every verb, which is the whole finding|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|2\n2|
s-cardinality-same-iface2.mdk|S-cardinality-conformance (closes out #1871): the #1866 shape, RESTORED from the drained must_fail pin. ONE interface, TWO predicates sharing the SAME lead tyvar but DISTINCT argument vectors (`Ix a Char, Ix a Bool`) must dispatch BOTH obligations correctly: 222 (Ix Int Char) + 111 (Ix Int Bool) = 333. Section 3 (IRS) pins the arity this value alone cannot see -- 2 dict slots, not the pre-fix 1. Section 4 auto-permutes the two `impl Ix` blocks (order-independence)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|333|
s-cardinality-inferred.mdk|S-cardinality-conformance (closes out #1871): the #1869 shape, RESTORED from the drained must_fail pin. TWO unsignatured (inferred) bindings, each a single bare-tyvar 2-ary predicate, impls declared in mirrored-opposite orders across the two interfaces. Spec answer 2442 = 222 + 2220, order-independent -- see s-cardinality-inferred-swapped.mdk for the other declaration order and s-cardinality-signatured.mdk for the signatured oracle both must match|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|2442|
s-cardinality-inferred-swapped.mdk|S-cardinality-conformance (closes out #1871): sibling to s-cardinality-inferred.mdk with BOTH interfaces` impl orders flipped -- the other half of the #1869 order-independence claim, spelled out as its own file rather than relying on section 4`s single-interface block permuter. Same spec answer, 2442|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|2442|
s-cardinality-signatured.mdk|S-cardinality-conformance (closes out #1871): the SIGNATURED oracle for the inferred pair above -- #1869`s own `control.mdk`, RESTORED. Same impls, bodies and value (2442) as s-cardinality-inferred.mdk, with explicit `=>` signatures. Section 3 (IRS) pins that its slot count MATCHES the inferred twin`s, not merely its value|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|2442|
s-cardinality-xmod-reject/main.mdk|S-cardinality-conformance (closes out #1871): the #1868 shape, RESTORED from the drained must_fail pin (S-xmod-vector-supply`s own fixture). The importer instantiates `Ix a Bool` at `Int`, but the definer`s ONLY impl is `Ix Int Char` -- no impl satisfies the goal, so `match(IE, Ix Int Bool)` is empty and the program must be REJECTED (was: silent exit 0, printing 222, pre-fix). Paired with s-cardinality-xmod-accept/ as the reject/accept half of the cross-module cardinality row|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s-cardinality-xmod-accept/main.mdk|S-cardinality-conformance (closes out #1871): the ACCEPT half of the cross-module cardinality row, paired with s-cardinality-xmod-reject/. ONE exported bare-tyvar predicate `Ix a b`, ONE impl (no ambiguity), the importer supplying the vector `Int, Bool` across the module boundary. ⚠️ NOT a same-interface TWO-vector cross-module row (the #1866 shape) -- that shape is UNREACHABLE cross-module only when >= 2 IMPLS of an interface SHARE ARGUMENT 0 (the still-open #1867 residual, pinned at test/must_fail_fixtures/1867-xmod-run-build-still-reject/); NOT "any concrete-argument declared constraint" -- a single-impl cross-module constrained call accepts fine, called or uncalled (measured; see that fixture). Value 111; section 3 (IRS) pins the arity (1 dict + 2 values = 3 params) the widened cross-module vector table now recovers end to end|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|111|
s-shadow-standalone-vector-arity.mdk|FIX-shadow-arity-skew REGRESSION GUARD (review finding F8): the #1866 shape reached through the STANDALONE-SHADOW route instead of the ordinary constrained-call route -- `size` collides with `Sizeable`s method name, so its dicts come from `shadowStandaloneDictSlots`, which expanded through the vector-FREE `expandSupersPairs` and collapsed `(Ix a Char, Ix a Bool)` back to ONE slot against a TWO-slot definition. 🚨 MEASURED at sprint head `e19298f5`: check exit 0, `run` exit 1 E-PANIC `intToString: not an Int`, `build` exit 0 printing a DIFFERENT heap pointer every execution, wasm `instantiate failed: illegal cast` -- three engines, three answers, and s-cardinality-same-iface2.mdk (the same program WITHOUT the shadow) green throughout. Spec answer hand-derived: `size 5` = 222 + 111 = 333, `plain 5` = 222. ⚠️ `plain` is the FEATURE-PRESENT-PLUS-UNRELATED-CODE-STILL-BEHAVES half -- a non-shadow single-predicate standalone beside the widened one, asserting the scalar arm did not move. Section 3 (IRS) carries the two ARITIES, which neither value can see|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|333\n222|
s4-2-mixed-vector-no-impl-rejected.mdk|§3/§4.2 THE #1578 REGRESSION ROW (S0, fixed by sprint/entailment-verdict; its must_fail pin was DELETED by the fix per [G-PIN-DRAIN] and this row is the replacement guard). An inferred binding raises the goal `Conv (Wrap a) b` -- a MIXED argument vector, one STRUCTURED argument and one open tyvar -- against a program declaring only `impl Conv Int Bool`. §3 matching is ONE phi against the WHOLE vector and `Wrap a = Int` has no solution, so the matching set is EMPTY on argument 0 alone, and `main` forces the ground goal `Conv (Wrap Int) Bool`, which is equally unsatisfiable. REJECT, T-NO-IMPL, on all three verbs. MEASURED at the pre-sprint arm `264eb95d` on this tree: check 0 with an EMPTY --json diagnostics list, run 0 PRINTING `int-bool` (the body of an impl the goal matches on NEITHER argument), build 1 at the emitter -- silent wrongness on two of three verbs. ⚠️ VERDICT AND CODE ONLY, NO LOCATION, deliberately: on this binary the reject lands at the DEFINITION, which is the site #1939 (OPEN, this sprint`s own regression) falsely rejects a LEGAL binding at, and a located pin would enshrine that. #1939`s fix may move the reject to the call site; it must not be able to green this program. ⚠️ ONE impl block, so Section 4 derives no permutation pair -- correct, the defect was ACCEPTANCE, not order|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s4-2-inferred-ground-arg-predicate-checked.mdk|§4 `gen` + §4.2 THE #1905 REGRESSION ROW (S0, fixed by sprint/entailment-verdict; NO must_fail pin ever existed for it, so before this row the S0 had no guard anywhere in the tree). The inferred `useIx x = ix x <Char literal>` generalises over the residual predicate `Ix a Char` whose SECOND argument is GROUND, forced by that literal; `main` instantiates at `a := Char`, giving the goal `Ix Char Char`, and the program declares only `impl Ix Int Char`, so §3 matching set is EMPTY. REJECT, T-NO-IMPL, `No impl of Ix for Char Char`, on all three verbs. MEASURED at the pre-sprint arm `264eb95d` on this tree: check 0, run 0, build 0 AND THE SHIPPED BINARY RAN TO COMPLETION PRINTING 222 -- every verb green, every verb wrong, because the ground `Char` was dropped on the way into the deferred obligation and a one-argument goal matched a two-argument impl. ⚠️ ALL_EXACT is unavailable to a REJECT row, so the CODE cell is what separates rejected-for-the-spec-reason from rejected-because-the-fixture-has-a-typo. ⚠️ ONE impl block, so Section 4 derives no permutation pair|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s4-2-dedup-collision-check-not-skipped.mdk|§4.2 OD5/OD6 THE #1330 REGRESSION ROW, AND THE FIRST §4.2 FIXTURE THIS CORPUS HAS EVER HAD (S0, fixed by sprint/entailment-verdict; its must_fail pin was DELETED by the fix per [G-PIN-DRAIN] and this row is the replacement guard). Deduplicating two call obligations must suppress the REPORT of a duplicate, never the CHECK. Body is the drained pin`s main.mdk VERBATIM: two `println` calls of a 2-tuple both dispatch `Display` at the same tuple head, so their call-channel obligations share a dedup key, and `data Color = Red` has no Display impl. Spec answer: the `Display Color` matching set is EMPTY, so REJECT, T-NO-IMPL, with the located deriving-Display help. MEASURED at the pre-sprint arm `264eb95d` on this tree: check 0 with an EMPTY --json diagnostics list, build 0, AND THE SHIPPED BINARY DIED AT SIGNAL 139 with empty stdout; only `run` was loud (exit 1, E-PANIC `intToString: not an Int`), and `run` is the verb that does not ship. ⚠️ BOTH `println` LINES ARE LOAD-BEARING -- delete either, or reshape either tuple, and the collision is gone and the file is an ordinary missing-instance program the pre-sprint arm ALSO rejected. ⚠️ NO impl blocks, so Section 4 derives no permutation pair. The pin`s ACCEPT-direction control.mdk is deliberately not carried (green at both arms, so not a regression test); the fixture header says where to find it|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s3-ground-requires-chain-depth-34.mdk|§3 nested `requires` + W1/W2 decidability -- THE #1576 REGRESSION ROW (S0, fixed by sprint/entailment-verdict; its must_fail pin was DELETED by the fix per [G-PIN-DRAIN] and this row is the replacement guard). A GROUND instance-context chain must be discharged to its base case however long it is. `tagOf` at 34 nested `Wrap`s around `5 : Int` selects `impl Tag (Wrap a)` at each layer, discharges `requires Tag a` against the layer below, and bottoms out at `impl Tag Int`: the spec answer, hand-derived, is the sentinel `ALIVE` then 34 `w`s and `int`, ACCEPT on all three verbs with run`s stdout, the SHIPPED BINARY`s stdout and the pinned value byte-identical. MEASURED at the pre-sprint arm `264eb95d` on this tree: check 0 with an EMPTY --json diagnostics list, build 0, and the SHIPPED BINARY printed `ALIVE` then DIED AT SIGNAL 139; `run` reached the same point loudly with a nonsense diagnosis (E-PANIC naming `++ requires Semigroup`, an operator this goal never mentions). 🚨 34 IS LOAD-BEARING: per the drained pin`s claim.txt the cliff sat between 33 and 34 on two arms, so any depth <= 33 grades green on a compiler that still has this bug. ⚠️ THE ROW DOES NOT PROVE THE CLIFF WAS REMOVED RATHER THAN MOVED -- measured first-hand at depth 100 on this base binary (correct, exit 0), but no committed fixture grades above 34. ⚠️ TWO `impl Tag` blocks of one interface in a FLAT .mdk, so Section 4 DOES derive a permutation pair -- deliberately: reversing them puts the recursive impl first and the base case last|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|ALIVE\nwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwint|
s-structured-carry-declared-context-rejected.mdk|§1/§4 THE #1937 REGRESSION ROW (S0, fixed by sprint/structured-predicate-carry; #1937 had NO must_fail pin, so before this row the S0 had no guard anywhere in the tree). A DECLARED context whose predicate argument is STRUCTURED -- `Conv (Wrap a) b`, not a bare `Conv a b` -- must reach the call site as the WHOLE instantiated predicate. The Char call instantiates a := Char, b := Bool, so the goal is `Conv (Wrap Char) Bool` while the only impl in scope is `Conv (Wrap Int) Bool`: §3 matching is ONE phi against the whole vector and `Wrap Char = Wrap Int` has no solution, so the matching set is EMPTY on argument 0 alone. REJECT, T-NO-IMPL, on all three verbs. MEASURED at the pre-slice base `4b45e035` on this tree: check 0, run 0 AND build 0 with the SHIPPED BINARY PRINTING `wrap-int-bool` -- the body of an impl for a DIFFERENT type, on every verb, because the structured argument was inadmissible on all three obligation channels and the declared context was ERASED before the call site was ever consulted. ⚠️ Paired with s-structured-carry-declared-context-kept.mdk, the ACCEPT direction: a fix that rejected here by dropping structured declared contexts entirely would FALSE-REJECT that one, so neither file is meaningful alone. ⚠️ VERDICT AND CODE, NO LOCATION: the span is asserted nowhere so the reject may move between definition and call site without a false red. ⚠️ ONE impl block, so Section 4 derives no permutation pair -- correct, the defect was ACCEPTANCE, not order|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s-structured-carry-declared-context-kept.mdk|§1/§4 the ACCEPT direction of #1937`s widening -- THE FALSE-REJECT CANARY for the row above. The same structured declared context, called where the goal IS satisfiable (a := Int, b := Bool, giving `Conv (Wrap Int) Bool`, exactly the impl in scope), so all three verbs ACCEPT and both engines print `wrap-int-bool`. 🚨 THE VALUE CANNOT SEE THE FIX: base `4b45e035` printed `wrap-int-bool` at exit 0 here too, so this row alone grades green on both sides. What moved is the SCHEME, and Section 2 carries it -- base displayed `f : Wrap Int -> Bool -> String` with the context ERASED. That is #607`s and #610`s discriminating shape one scope over: the right value printed with the constraint silently dropped from the type. ⚠️ ONE impl block, so Section 4 derives no permutation pair|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|wrap-int-bool|
s-open-world-declared-context-uncalled-accepted.mdk|§4.2 OD2 THE #1939 REGRESSION ROW (S1, knowingly landed at #1907`s close-out, fixed by sprint/structured-predicate-carry; #1939 had NO must_fail pin, so before this row it had no guard anywhere in the tree). A goal is refutable only when NO instantiation of it can be satisfied, and `match(IE, pi)` is read against the LOADED module graph -- which never contains the module`s dependents. So a goal still carrying a type VARIABLE must DEFER (OD2), never refute, however empty the current graph looks. Neither `f1` nor `f2` is ever called, so no use site exists and nothing is adjudicated: ACCEPT on all three verbs printing `open-world`. 🚨 BOTH BINDINGS ARE LOAD-BEARING AND THEY TAKE DIFFERENT CHANNELS: `f1`s single-parameter `Tag (Wrap a)` is discharged by the CALL-obligation checker (`checkOneCallObligation`, whose `allConcreteHeads` gate reads `Wrap a` as concrete because it asks for a head TYCON and not for groundness), while `f2`s two-parameter `Conv (Wrap a) b` leaves the body as a RESIDUAL and is adjudicated by `residualRefutableNow`. MEASURED at the pre-slice base `7941e5fe` on this tree: exit 1 with TWO diagnostics, `No impl of Tag for Wrap a` at 44:7 AND `No impl of Conv for Wrap a b` at 47:9; and on an intermediate binary with `residualRefutableNow` alone fixed, `f1`s diagnostic SURVIVED alone. Either binding on its own grades green against half the fix. ⚠️ PAIRED WITH s-open-world-unsatisfiable-use-site-rejected.mdk -- [W-QUIETER] makes the ACCEPT direction half an assertion, because deleting the obligation check outright would also grade green here. ⚠️ NO impl blocks, so Section 4 derives no permutation pair|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|open-world|
s-open-world-unsatisfiable-use-site-rejected.mdk|§3 `inst` -- THE ILLEGAL TWIN of the row above and the NARROW half of #1939`s fix: deferral MOVES a verdict, it does not remove one. The same legal `f1 : Tag (Wrap a) => …` declaration, CALLED at `a := Int`, poses the GROUND goal `Tag (Wrap Int)`; a ground goal cannot instantiate further so the open-world argument does not reach it, and `match(IE, …)` is EMPTY and stays empty because the only `Tag` impl heads at `Int`. REJECT, T-NO-IMPL, on all three verbs. 🚨 `impl Tag Int` MUST NOT BE DELETED: it makes the interface non-empty so the reject cannot be reached by the trivial nothing-implements-Tag route the sibling exercises -- the goal has to be refuted for its ARGUMENT, at the site that grounds it. ⚠️ MEASURED REJECT ON ALL THREE VERBS AT BASE `7941e5fe` TOO -- the VERDICT is UNCHANGED across the slice BY DESIGN. What moved is the COUNT: base emitted TWO diagnostics, one at `f1`s DEFINITION and one at `main`s CALL, where head emits only the second. The false reject went, the true one stayed. This is a tripwire, not a demonstration: a fix that bought the sibling`s acceptance by DROPPING the obligation rather than deferring it turns this file green, and green here is the S0. ⚠️ VERDICT AND CODE, NO LOCATION -- which site owns a deferred goal`s verdict is exactly what this slice moves, so a span assertion would enshrine one arm`s answer as the spec. ⚠️ ONE impl block, so Section 4 derives no permutation pair|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s-open-world-library-dependent-impl/lib.mdk|§4.2 OD2 THE #1938 REGRESSION ROW (`medaka check <library module>` reading its import closure as a CLOSED world; #1938 had no pin either), AND THE ONLY ENTRY IN THIS CORPUS THAT IS NOT A PROJECT ROOT -- checking the library ALONE is the whole assertion and the main.mdk row below does not make it. `describe x = tag (Wrap x)` infers the residual `Tag (Wrap a)`: concrete head, open argument. The impl that satisfies it is in impls.mdk, which IMPORTS lib, so it is a DEPENDENT and is absent from lib`s own load graph. Refuting here decides a legal library module`s fate by what its consumers happened to be compiled alongside. ACCEPT on check. MEASURED at the pre-slice base `7941e5fe` on this tree: check exit 1, `No impl of Tag for Wrap a` at lib.mdk:18:20. ⚠️ THE CODE CELL IS THE NEGATIVE FORM `!T-NO-IMPL` AND THAT IS THE ASSERTION: an exit code alone cannot tell a fixed checker from one that stopped raising the goal at all, and the absent-code form pins the exact diagnostic that must not come back. ⚠️ run and build REJECT for a reason this row is not about -- lib.mdk has no `main` (E-NO-MAIN / the emitter`s no-main panic), identically at both arms. They are pinned so the row cannot go quietly green on a verb it never exercised|ACCEPT|REJECT|REJECT|NONE||!T-NO-IMPL
s-open-world-library-dependent-impl/main.mdk|§4.2 the PROJECT half of #1938, and NOT merely lib.mdk`s control: the whole graph loaded, `Tag (Wrap Int)` satisfied, ACCEPT on all three verbs printing `wrap-int`. 🚨 IT IS A REGRESSION ROW IN ITS OWN RIGHT AND IT REFUTES THE READING THAT #1938 COSTS ONLY A SPURIOUS DIAGNOSTIC ON AN UNUSUAL CLI INVOCATION. MEASURED at base `7941e5fe` on this tree: check, run AND build ALL exit 1 with `lib.mdk:18:20: No impl of Tag for Wrap a` -- the whole project failed to compile with the satisfying impl in a loaded sibling module, because the refutation is decided per-module against `buildImplUniverse` over that module`s OWN decls and loading the dependent does not rescue it. ⚠️ `main` DELIBERATELY DOES NOT CALL `describe`, which would be the obvious body: `describe`s residual is STRUCTURED (`Tag (Wrap a)`, not a bare `Tag a`) and `funConstraintsRef`s dict slots are shattered per tyvar, so no joint slot exists to route it across the module boundary. That is #1560 / #1937`s still-open half -- MEASURED byte-identically at base `7941e5fe`: with `main = println (describe 5)` BOTH arms give check exit 0 and run exit 1 with the #1812 unlocated elaboration error. Calling `tag` directly keeps this row about the open-world question and nothing else; when #1560 lands, `describe 5` is the strictly better body. ⚠️ ONE impl block, so Section 4 derives no permutation pair|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|wrap-int|
s-instantiated-reselect-declared.mdk|§3 THE #1909 REGRESSION ROW (S0, fixed by sprint/structured-predicate-carry; #1909 had NO must_fail pin, so before this row the S0 had no guard anywhere in the tree). A DECLARED context whose predicate argument is STRUCTURED -- `Tag (Wrap a)`, not the bare `Tag a` that every `=>` constraint in compiler + stdlib + sqlite happens to be -- must be RE-SELECTED PER INSTANTIATION, from the dict the CALLER supplied. `nest True` poses `Tag (Wrap Bool)` and `nest 1` poses `Tag (Wrap Int)`, each a SINGLETON matching set, so the two calls must select DIFFERENTLY: boolW/intW. MEASURED at the pre-slice base `bffced42` on this tree: `boolW/boolW` at exit 0 on check, run AND build alike -- ONE abstraction-time pick applied to both instantiations. 🚨 THE GENERAL IMPL IS DELIBERATELY ABSENT, so a mis-selection has no plausible impl to hide behind: any answer but `boolW/intW` names ONE ground impl twice for two calls at two different types. 🚨 THE DEFECT HAD TWO HALVES AND EITHER ONE ALONE REDS THIS ROW -- the CALL side (`vectorGoal` declined a 1-ary argument vector, so the site keyed its dict on the slot mono `Bool` instead of the predicate argument `Wrap Bool`) and the CONSUMPTION side (no `registerPredGiven` on the signature channel, so `entailAssum` could not answer a structured goal and `entail` fell to `entailInst`). ⚠️ CONSUMPTION-SIDE WITHOUT CALL-SIDE IS MEASURABLY WORSE THAN BASE: the body then reads a dict matching no dispatcher arm and falls into LLVM `unreachable` (#1958). If this row is ever re-derived, that is the order it must not be re-derived into. ⚠️ TWO `impl Tag` blocks, so Section 4 derives a permutation pair, and that is load-bearing rather than incidental: at base the two declaration orders printed `boolW/boolW` and `intW/intW`, i.e. FIRST-DECLARED-WINS, which DICT §3 forbids outright and which no value pin at a single declaration order can see|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|boolW/intW|
s-instantiated-reselect-inferred.mdk|§3/OD6(a) the INFERRED twin of the row above -- byte-for-byte that fixture with the SIGNATURE LINE DELETED, so OD6(a) (a declared context and the identical inferred one adjudicate the same way) forces the same answer: boolW/intW. 🚨 A SEPARATE ROW BECAUSE IT IS A SEPARATE WRITER: the declared context is registered by `registerMember`, the inferred one by `registerInferredFor`, and BOTH were ids-only -- patching one leaves the other statically committed at exit 0 with the pair silently disagreeing, the shape #1869 and #1161 both landed in. MEASURED at base `bffced42`: `boolW/boolW` on check, run and build, identical to its declared twin. ⚠️ THE OBVIOUS INFERRED PROBE IS MIS-SCOPED AND MUST NOT REPLACE THIS ONE: add a general `impl Tag (Wrap a)` (what #1909`s own inferred repro does) and the residual `Tag (Wrap t)` is DISCHARGED by residual reduction at generalization time -- the binding retains no predicate, gets no dict slot under ANY #1909 fix, and `check --types` prints `nest : a -> String` on the unmodified base binary. The general impl has to be ABSENT for the inferred binding to keep a predicate at all. ⚠️ TWO `impl Tag` blocks, so Section 4 derives a permutation pair; at base the two orders printed `boolW/boolW` and `intW/intW` here too|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|boolW/intW|
s-instantiated-reselect-general-sibling.mdk|§3 #1909`s OWN FILED REPRO, and the OVER-NARROWING guard its two-ground-impl siblings cannot be. A general `impl Tag (Wrap a)` beside a specific `impl Tag (Wrap Bool)` gives each call a TWO-member matching set, and §3 takes the min⊑: `nest True` selects the SPECIFIC impl, `nest 1` poses `Tag (Wrap Int)`, which the specific impl does not match at all, and selects the GENERAL one. specificW/genericW. MEASURED at base `bffced42`: `genericW/genericW` at exit 0 on check, run and build -- the abstraction-time pick against the rigid goal `Wrap a` IS the general impl, so base got the first call wrong and the second right by accident. 🚨 THIS IS THE ROW THAT REDS IF THE FIX OVER-NARROWS: its siblings assert a per-instantiation goal is REACHED, this one asserts that reaching it does not lose the general instance. ⚠️ ONE CALL IS NOT ENOUGH, which is why the fixture does not stop at `nest True`: a lone `genericW` -> `specificW` move is equally consistent with the wrong rule always pick the most specific impl in the program, and the `nest 1` arm is what discriminates them. ⚠️ TWO `impl Tag` blocks, so Section 4 derives a permutation pair -- DICT §3 forbids declaration order deciding a winner even when both candidates match|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|specificW/genericW|
s-instantiated-reselect-unsatisfiable-rejected.mdk|§3 `inst` -- the ADMISSION TRIPWIRE for the three rows above. Same declared structured context, same two ground impls, called at a THIRD type: `nest ‘c’` poses the GROUND goal `Tag (Wrap Char)`, whose matching set is EMPTY on argument 0 alone, and a ground goal cannot instantiate further so the open-world argument (OD2, #1939) does not reach it. REJECT, T-NO-IMPL, on all three verbs. ⚠️ MEASURED REJECT AT BASE `bffced42` TOO, with the same message and span (`No impl of Tag for Wrap Char` at 41:16) -- THE VERDICT IS UNCHANGED ACROSS THIS SLICE BY DESIGN and this row cannot go red-to-green across the fix. It is a TRIPWIRE, not a demonstration: #1909 WIDENS the goal the call site is keyed on, from the slot`s bare mono to the predicate`s own structured argument, and a widening that admitted the new goal by UNIFYING it against a non-matching impl head would turn this file green. Green here is the S0. ⚠️ VERDICT AND CODE, NO LOCATION -- which site owns a refuted structured goal`s diagnostic is adjacent to what the neighbouring open-world rows move, so a span assertion would enshrine one arm`s answer as the spec. ⚠️ TWO `impl Tag` blocks, so Section 4 derives a permutation pair, which is wanted: a reject must not depend on declaration order either|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s-multiparam-structured-declared-rejected.mdk|§3/§5/§14 OD6 THE S0-1 REGRESSION ROW (S0, introduced by this sprint`s slice 2, fixed by its fix round; the shape had NO row in either direction, which is the hole the end-of-sprint review named). A MULTI-PARAMETER interface with a STRUCTURED predicate argument (`Conv (Wrap a) Int =>`) is admitted and deferred by the declared channel, but the CONSUMPTION side cannot answer it: `registerPredGiven` matches a single-subject `[subject]` vector and returns `()` for anything longer, so `entailAssum` is unreachable by construction, `entail` falls to `entailInst`, and the body is statically committed to the ABSTRACTION-time pick while the caller`s dict goes unread. MEASURED at the pre-fix sprint head `aa36d555` on this tree, cold built: check 0, run 1 (E-PANIC `if condition is not a Bool`), build 0, SHIPPED BINARY PRINTING `T/T` where §3 requires `T/n=42` -- a silent wrong answer, a type-confused dict and an eval-vs-native divergence at once. STABLE at -O0/-O1/-O2 hand-linked from `--keep-ir`, so not #1958 UB. 🚨 AND ORDER-DECIDED: swapping the two `impl Conv` blocks changed the pre-fix answer to `intInt/intInt`, which §3 forbids outright -- Section 4`s permutation pair now grades that half automatically, since BOTH orders must reject. ⚠️ THE ACCEPT SIBLING IS s-open-world-declared-context-uncalled-accepted.mdk`s `f2`, a multi-parameter structured context that legitimately ACCEPTS (its second argument is a bare tyvar, so the goal stays a residual and never reaches the defer gate) -- a fix that refused multi-parameter structured contexts wholesale would false-reject it. ⚠️ VERDICT AND CODE, NO LOCATION|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s-multiparam-structured-inferred-rejected.mdk|§14 OD6(a) THE INFERRED TWIN of the row above, and NOT its control -- it takes a DIFFERENT channel and is refused by a DIFFERENT conjunct. The declared row is caught because the signature`s context is already REGISTERED when the body goal is checked, so the goal is CLAIMED and must match a given; here `inferredConstraintIds` rejects the compound `Wrap t`, `ids` is empty, `registerInferredFor` returns on its empty-ids guard, and the goal is UNCLAIMED. What refuses it is the ARITY half of `goalSlotStillOpen`: a 2-ary vector can never acquire a given on any channel. MEASURED during the fix round with the claimed-test alone in place: this file printed `boolInt/boolInt` at exit 0 while its declared sibling already rejected -- OD6(a)`s declared/inferred agreement holding only by disagreeing. At the pre-fix head `aa36d555`: check 0, run 0, build 0, all printing `boolInt/boolInt` where §3 requires `boolInt/intInt`. ⚠️ VERDICT AND CODE, NO LOCATION|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s-unentailed-structured-body-goal-rejected.mdk|§4.2/§5 THE S0-2 REGRESSION ROW (S0, introduced by this sprint`s slice 2, filed mid-sprint as #1959 with the disposition "pre-existing" -- true against slice 3`s base, FALSE against the sprint merge-base `0944ca9d`, where it is a located double reject). DEFER means forward the predicate outward to the binder that quantifies its variables; `g`s binder is a SIGNATURE and a signature is FIXED, so a body goal the declared context does not carry (`Tag (Box a)` where only `Tag (Wrap a)` is declared) can be forwarded nowhere and "defer" degrades to DROP. MEASURED at the pre-fix head `aa36d555`: check 0 with ZERO diagnostics, run 1 (E-PANIC `unknown op +`), build 0, SHIPPED BINARY PRINTING `wrapChar` then `boxInt=123` -- `impl Tag (Box Int)`s body evaluating `n + 1` over the Char `z` (ASCII 122). Stable at -O0/-O1/-O2, so not #1958 UB. 🚨 THE FIRST COMPONENT IS LOAD-BEARING: `tagOf (Wrap x)` IS the declared context and must keep deferring, so a gate that rejected both halves would false-reject s-structured-carry-declared-context-kept.mdk and s-instantiated-reselect-declared.mdk. Both goals are at the SAME interface on the SAME variable and only the structural shape tells them apart, which is why the discrimination is `monoSameGiven` on tyvar-cell IDENTITY and not an interface-name compare. ⚠️ VERDICT AND CODE, NO LOCATION|REJECT|REJECT|REJECT|NONE||T-NO-IMPL
s-nested-rigid-structured-goal-rejected.mdk|§8 I6.1 THE S2-5 REGRESSION ROW (S2, introduced by this sprint`s slice 2, fixed by its fix round). The STRUCTURED sibling of test/typecheck_error_fixtures/rigid_mono_head_key.mdk, whose golden is exactly this reject one level up. `zzz` in `data Bad = Bad zzz` is quantified by NOTHING, and §8 I6.1 calls handing such a variable out as a dispatch key a forgery; `monoHeadIsDecl` catches it at the TOP LEVEL of a goal, but nested one constructor down (`Q (Wrap zzz)`) the head is a real TCon and the conjunct is True either way, so the forgery leaked. A rigid that can never ground has nowhere to defer TO. 🚨 THE DISCRIMINATOR IS THE SECOND DIAGNOSTIC, NOT THE EXIT CODE: at the pre-fix head `aa36d555` this file emitted ONE error (T-TYPE-MISMATCH at the call); at the sprint merge-base `0944ca9d` it emitted TWO, that one AND `No impl of Q for Wrap zzz`. Both arms exit 1, so an exit-only row could not have seen the loss -- which is why BOTH codes are asserted here, and why the bare-rigid control (`qq v`, no `Wrap`, still rejecting on both arms) could not have caught it either. ⚠️ ONE impl block, so Section 4 derives no permutation pair -- correct, the defect was a LOST DIAGNOSTIC, not order|REJECT|REJECT|REJECT|NONE||T-TYPE-MISMATCH,T-NO-IMPL'

# ── Section 2 table: exact `medaka check` scheme lines ────────────────────────
# entry | label | expected scheme line (must appear VERBATIM in check's stdout)
#   Bare `medaka check` prints only the user's OWN top-level bindings, which is
#   why this is legible at all; `--types` would bury it under ~120 prelude lines.
SCHEMES='s1-nary-predicate-scheme-kept.mdk|§1 the 2-ary constraint SURVIVES into the scheme (#607: printed `a -> b -> Int`, constraint gone, at exit 0)|twoParam : Ix a b => a -> b -> Int
s4-gen-sig-declared-context-kept.mdk|§4 `gen-sig` the declared context is DISPLAYED even though the body never dispatches (#610: printed `sz2 : a -> Int`)|sz2 : Sz a => a -> Int
s4-gen-sig-superclass-redundant-dropped.mdk|§4 `gen-sig` the superclass-entailed `B a` is DROPPED, not merged (pre-#619 displayed `(B a, C a) =>` and propagated it to every caller)|viaC : C a => a -> Int
s4-gen-sig-superclass-redundant-dropped.mdk|§4 control: the binding that genuinely needs `B a` still shows it, so the row above is not "constraints are never displayed"|useB : B a => a -> Int
s4-gen-residual-inferred-context.mdk|§4 `gen` the RESIDUAL of a `requires` discharge IS the principal context (issue 1549: printed `nest : a -> String`, the `Tag a` gone, at exit 0)|nest : Tag a => a -> String
s4-gen-residual-no-requires-control.mdk|§4 `gen` control: with the `requires` gone there is no residual, so the context must stay EMPTY -- the false-reject canary for the row above|nest : a -> String
s4-gen-sig-residual-covered-control.mdk|§4 `gen-sig` + §3 `super`: the residual `Eq a` entailed by the declared `Ord a` is DROPPED, not merged -- the value is True either way, so only this row can see a residual reducer that widened the displayed context|sig2 : Ord a => a -> Bool
s4-gen-residual-mixed-no-requires-control.mdk|ISSUE 1560 control: with the `requires` gone the mixed vector leaves NO residual, so the context must stay EMPTY. The false-reject canary for the widened `anyConcreteHead` guard, and the only row that can see a reducer inventing a context|f : a -> b -> String
s4-gen-rec-inferred-context.mdk|§4 `gen-rec` P` is the GROUP`s, so BOTH bindings generalize over `Sz a` -- not only the one whose body mentions `sz` first|evenSz : Sz a => a -> Int -> Bool
s4-gen-rec-inferred-context.mdk|§4 `gen-rec` the other half of the group|oddSz : Sz a => a -> Int -> Bool
s8-xmod-reexport-alias-perm-ab/main.mdk|#1337 PERMUTATION, ORDERING 1 of 2 -- THE "ONE SIGNATURE" HALF (packet Amendment A condition 2). `combine` calls two bindings reached through an ALIAS import of a re-export hub over TWO DIFFERENT definers. Its scheme is the order-invariant this pair asserts: an alias arm that re-bound one definer`s key and not the other`s would leave `H.ga` or `H.gb` unbound and this line would not appear at all|combine : Int -> Int
s8-xmod-reexport-alias-perm-ba/main.mdk|#1337 PERMUTATION, ORDERING 2 of 2 -- THE SAME SIGNATURE from the EXCHANGED declaration order. ⚠️ The two rows are ONE assertion: identical schemes across all orderings of one spelling. Either row alone is satisfied by an order-decided compiler|combine : Int -> Int
s-structured-carry-declared-context-kept.mdk|#1937 the STRUCTURED declared context SURVIVES into the scheme -- THE ONLY OBSERVABLE THAT SEES THIS FIX ON AN ACCEPTING PROGRAM (base printed `f : Wrap Int -> Bool -> String`, the context gone, at exit 0 with the right value). ⚠️ The type is still MONOMORPHISED to `Wrap Int -> Bool` by single-impl improvement, a separate mechanism #1937 does not touch and this slice deliberately did not widen -- do NOT re-pin this to a polymorphic scheme. ⚠️ The predicate renders WITHOUT PARENTHESES (`Conv Wrap Int Bool` for `Conv (Wrap Int) Bool`), which reads as four arguments to a two-parameter interface and does not round-trip through the parser: a printer defect (#1952, `S2: misleading`) that is newly REACHABLE rather than newly broken, because until this fix the context was erased and never printed at all. This pin records what the binary prints today; when #1952 lands the row goes RED and must be re-pinned to the parenthesised form|f : Conv Wrap Int Bool => Wrap Int -> Bool -> String'

# ── Section 3 table: emitted-LLVM structural assertions ──────────────────────
# entry | label | HAS|LACKS|COUNT=<n> | extended-regex over the kept .ll
#   The IR is produced BEFORE clang runs, so no optimization level can change it
#   (AGENTS.md, "Parallelism"): these patterns are stable against -O0/-O2.
#
#   ⚠️ `COUNT=<n>` exists because HAS/LACKS CANNOT EXPRESS THE #1128 DRAIN. That
#   fix's discriminating observation is "the general impl is called at exactly the
#   TWO sites whose goal matches only it, and the concrete impl at exactly the ONE
#   site that does" -- and HAS is satisfied by a single call, so a regression routing
#   ALL THREE sites back through one symbol would keep both HAS rows green. The
#   pre-fix pin could use LACKS (zero is a count HAS/LACKS can state); the post-fix
#   pin cannot. A row that can only assert "at least one" is exactly the unasserted
#   label the adversarial-review F1 note below already caught once.
IRS='s4-gen-sig-declared-context-kept.mdk|§4 `gen` a declared-but-never-dispatched constraint STILL ABSTRACTS ITS DICT PARAM -- arity 2 (dict + value) for a 1-argument source function. Invisible from behaviour: the value is 9 with or without the slot|HAS|^define i64 @mdk_s4_gen_sig_declared_context_kept__sz2\(i64 %arg0, i64 %arg1\)
s4-gen-residual-inferred-context.mdk|ISSUE 1549 MECHANISM PIN 1/3: `gen` abstracts a dict for the RESIDUAL, so `nest` is arity 2 (1 dict + 1 value) for a 1-argument source function. THIS IS THE ROW THAT SEES THE SEGFAULT: pre-fix the definition was arity 1 while the impl it calls needs an element dict, and no behavioural assertion could tell the difference because run printed `wrap(int)` either way|HAS|^define i64 @mdk_s4_gen_residual_inferred_context__nest\(i64 %arg0, i64 %arg1\)
s4-gen-residual-inferred-context.mdk|ISSUE 1549 MECHANISM PIN 2/3: the abstracted dict is FORWARDED to the conditional impl as its element dict -- `%arg0`, the parameter, not a constant rebuilt at the site. An arity-2 definition that ignored its dict param would keep PIN 1/3 green|HAS|call i64 @mdk_impl_Wrap_tagOf\(i64 %arg0,
s4-gen-residual-inferred-context.mdk|ISSUE 1549 MECHANISM PIN 3/3: the CALL SITE supplies that dict (a `ptrtoint` of a dict constant). Pins the `var`/`gen` arity agreement §4 requires of producer and consumer -- a caller still applying one argument is the under-application that crashed|HAS|call i64 @mdk_s4_gen_residual_inferred_context__nest\(i64 ptrtoint
s4-gen-residual-xmod/main.mdk|ISSUE 1549 CROSS-MODULE MECHANISM PIN: the dict `gen` abstracts for the residual survives the module boundary -- `nest`, defined in nest.mdk, is emitted at arity 2 (dict + value). This is the row that would have caught a fix that worked single-file and dropped the context at an import, and it is the ONLY assertion available for this fixture`s scheme (see its TABLE row)|HAS|^define i64 @mdk_nest__nest\(i64 %arg0, i64 %arg1\)
s4-gen-residual-mixed-vector-accepted.mdk|ISSUE 1560 MECHANISM PIN 1/2: the MIXED-vector residual is abstracted, so `f` is arity 3 (1 dict + 2 values) for a 2-argument source function. Pre-fix it was arity 2 with no dict at all, and NO behavioural assertion could see it -- the value was `w:int` either way, because with no dict the impl bodys `tagOf x` fell through to arg-tag dispatch on an Int|HAS|^define i64 @mdk_s4_gen_residual_mixed_vector_accepted__f\(i64 %arg0, i64 %arg1, i64 %arg2\)
s4-gen-residual-mixed-vector-accepted.mdk|ISSUE 1560 MECHANISM PIN 2/2: the CALL SITE supplies that dict (a `ptrtoint` of a dict constant), so producer and consumer agree on the arity §4 `gen`/`var` requires. An arity-3 definition nobody passed a dict to is the under-application that crashes|HAS|call i64 @mdk_s4_gen_residual_mixed_vector_accepted__f\(i64 ptrtoint
s4-gen-residual-mixed-no-requires-control.mdk|ISSUE 1560 CONTROL, structural half: with no `requires` there is no residual and NO dict is abstracted -- `f` stays arity 2 (2 values). LACKS-style negative stated as the positive arity, so a spurious dict param is caught rather than merely "some definition exists"|HAS|^define i64 @mdk_s4_gen_residual_mixed_no_requires_control__f\(i64 %arg0, i64 %arg1\)
s8-i1-samename-independent-dict-arity/main.mdk|§8 I1 the CONSTRAINED same-named binding abstracts ONE dict: arity 2|HAS|^define i64 @mdk_lefty__widget\(i64 %arg0, i64 %arg1\)
s8-i1-samename-independent-dict-arity/main.mdk|§8 I1 the UNCONSTRAINED same-named binding abstracts NONE: arity 1. A bare-name arity table would force a phantom dict param here and the call site would over-apply|HAS|^define i64 @mdk_righty__widget\(i64 %arg0\)
s8-i1-samename-unconstrained-poly-callee/main.mdk|§8 I1 the POLYMORPHIC UNCONSTRAINED same-named binding abstracts NO dict: arity 1. Stated as the positive arity (not LACKS) so a spurious leading dict param is caught rather than merely "some definition exists". This is the emit-path twin of this fixture`s value row -- the value row is what reaches the EVAL path, and both are needed: the eval and emit paths disagreed on exactly this binding`s arity at a1086fbb|HAS|^define i64 @mdk_umod__pick\(i64 %arg0\)
s8-i1-samename-wildcard-import-callee/main.mdk|§8 I1 the WILDCARD-IMPORTED unconstrained binding abstracts NO dict: arity 1. Positive arity, not LACKS, so a spurious leading dict param is caught. The emit path was never wrong on this class (`runEmitWith` mangles first), so this row is the CONTROL for the value row above: if both ever go red together the regression is in the emitter, not in the definer-resolution seam|HAS|^define i64 @mdk_umod__pick\(i64 %arg0\)
s3-min-subsumes.mdk|§3 the ground goal resolves STATICALLY to the specific impl -- a direct call, no runtime arm-matching|HAS|call i64 @mdk_impl_Int_dflt\(
s3-min-fully-general-sibling.mdk|#1128 MECHANISM PIN 1/3: the general impl IS emitted -- so it was not DCE`d away, and (pre-F-3b) its absence from every call site was a selection decision rather than a missing definition. Retained post-drain: it is what makes PIN 2/3 an assertion about DISPATCH rather than about existence|HAS|define i64 @mdk_impl___none___tag\(
s3-min-fully-general-sibling.mdk|#1128 MECHANISM PIN 2/3, RE-PINNED BY THE F-3b DRAIN: the general impl is now called at EXACTLY THE TWO sites whose goal matches it alone. This row read `LACKS` (found 0) while #1128 was open. COUNT, not HAS, is load-bearing here: `HAS` would be satisfied by one call, so a regression collapsing all three sites onto the general impl -- the mirror image of the original bug -- would keep it green|COUNT=2|call i64 @mdk_impl___none___tag\(
s3-min-fully-general-sibling.mdk|#1128 MECHANISM PIN 3/3, RE-PINNED: exactly ONE site calls the `Box Int` impl -- the only goal it matches. Paired with PIN 2/3 this pins the whole 3-site partition (2 general + 1 concrete = 3 calls), which no behavioural assertion can see and which `HAS` left half-unstated (adversarial review F1: a change routing all three through some THIRD symbol kept the old row green under a false label)|COUNT=1|call i64 @mdk_impl_Box_tag\(
s8-i1-dict-param-order.mdk|§8 I1 ORDER, structural half: a TWO-predicate binding must abstract FOUR parameters (2 dicts + 2 values). The value 503 alone cannot see a count change that unification happens to absorb|HAS|^define i64 @mdk_s8_i1_dict_param_order__pair2\(i64 %arg0, i64 %arg1, i64 %arg2, i64 %arg3\)
s1-nary-predicate-scheme-kept.mdk|`S-dict-arity-contract` ARITY PIN: `twoParam : Ix a i => a -> i -> Int` has ONE predicate with two bare-tyvar arguments (`a` and `i`), which collapses to ONE dict slot, not two -- so `twoParam` abstracts THREE parameters (1 dict + 2 values), not four. No behavioural assertion can see this: the value 3 prints the same either way|HAS|^define i64 @mdk_s1_nary_predicate_scheme_kept__twoParam\(i64 %arg0, i64 %arg1, i64 %arg2\)
s3-nary-sig-constraint-goal-vector.mdk|#1161 ARITY-NEUTRALITY PIN. Recording the predicate`s ARGUMENT VECTOR must not move emitted dict arity -- that is the property the whole F-3a-ii design rests on (the vector table is SLOT-PARALLEL to funConstraintsRef, never inside it, so dictArityOf/dictPass/scopeArities are untouched). `Ix a Char => a -> Int` is one predicate, so post-`predicate-slots` (2026-08-23) it resolves to ONE dict slot exactly as it did pre-sprint for this single-predicate shape, so `useIx` abstracts 1 dict + 1 value = arity 2. NO behavioural assertion can see this: promoting the predicate to a joint dict slot would print the same 222|HAS|^define i64 @mdk_s3_nary_sig_constraint_goal_vector__useIx\(i64 %arg0, i64 %arg1\)
b1-xmod-default-inherited-tag/main.mdk|ARCH B-2 (B-2.2-b1) DISCRIMINATOR 1/2, and the ONLY assertion this fixture has: the CROSS-MODULE method-less impl routes through the lifted interface default, whose symbol is keyed on the head tag `fromOption tag` supplies at `keyForSite`s no-row arm. A `b1` that deleted that fallback -- which every design document before RUN-P3-013 said it would -- moves or loses this symbol|HAS|call i64 @mdk_default_sz_Box\(
b1-xmod-default-inherited-tag/main.mdk|ARCH B-2 (B-2.2-b1) DISCRIMINATOR 2/2: the SAME-MODULE twin, in the same program, takes the ordinary TAGGED route instead -- `fillImplDefaults` specialized a clause for it, so the candidate scan sees a row. The PAIR is the assertion: one source shape, two routes, and only both together show that this bite moved neither|HAS|call i64 @mdk_impl_Cup_sz\(
b1-p4-super-slot-unique-heads/main.mdk|P4 PC2: the appended super slot really is THREADED -- three params (2 dicts + 1 value) for a one-argument source function. Every other P4 assertion is vacuous without this one|HAS|^define i64 @mdk_main__both\(i64 %arg0, i64 %arg1, i64 %arg2\)
b1-p4-super-slot-unique-heads/main.mdk|P4 TRIPWIRE PROPER: the SAME dict constant is applied at BOTH slots. This is the sentence `typecheck.mdk` states as a premise ("the super slots route is identical to the subs") rendered as IR, and it is UNMOVED by B-2.2-b1 because the collision gate is False at both slots. When ARCH B-2 finally makes routes identity-bearing unconditionally, THIS is the row that must go red and be re-derived -- not silently re-blessed|HAS|call i64 @mdk_main__both\(i64 ptrtoint \(ptr @mdk_dc_0 to i64\), i64 ptrtoint \(ptr @mdk_dc_0 to i64\),
b1-p4-super-slot-unique-heads/main.mdk|P4 UNIQUE-HEAD CONTROL: at a head with ONE impl the emitted symbol is the BARE TAG -- `@mdk_impl_T_btag`, not an identity-qualified name. Stated as the positive so that an unconditional identity widening is caught here rather than in a seed re-mint|HAS|call i64 @mdk_impl_T_btag\(
b1-p4-super-slot-colliding-heads/main.mdk|B-2.2-b1 + B-2.2-e HEADLINE OBSERVABLE: with two impls of `Base` at head `Box` the route word is the canonical impl key, and that key still carries the DECLARING MODULEs interface identity -- the key reads `base::Base` followed by the pipe-delimited type args. ⚠️ AS OF THE injectiveIdent BITE THE SYMBOL IS NO LONGER THAT KEY SANITIZED: `private_mangle.injectiveIdent` writes it `zZ`-prefixed with every non-alphanumeric byte replaced by a self-delimiting `_<hex>_` escape (`_3a_` is a colon, `_7c_` a pipe, `_28_`/`_29_` the parens, `_20_` a space), so the symbol is injective rather than human-readable. THE ARCHITECTURAL CLAIM SURVIVES THE ESCAPE VERBATIM, which is why this row is still a mechanism pin and not just a spelling: alphanumeric runs pass through unescaped, so the declaring modules name `base` is still LITERALLY PRESENT in the pinned text -- declare `Base` in a DIFFERENT module and this row goes red, exactly as it did pre-escape. Pre-bite this symbol was `@mdk_impl_Base__Box_Int___btag`, with no module component; the LACKS row below is the negative half|HAS|@mdk_impl_zZbase_3a__3a_Base_7c__28_Box_20_Int_29__7c__btag\(
b1-p4-super-slot-colliding-heads/main.mdk|B-2.2-b1 + B-2.2-e NEGATIVE HALF: the pre-bite, identity-free spelling is GONE. A HAS row alone cannot see a change that ADDS the qualified symbol while leaving the bare one live somewhere, which is exactly the shape a half-applied seam (caller side moved, definition side not) produces. ⚠️ HISTORICAL NEGATIVE SINCE THE injectiveIdent BITE, AND DELIBERATELY LEFT AS ONE RATHER THAN QUIETLY RESPELLED: this literal is the SANITIZED spelling, and the sanitizer is no longer on this path at all, so no current compiler configuration emits it -- the row still catches a REVERT of the whole seam (sanitizer back, module component dropped) but no longer discriminates a half-applied one. The fail-capable negative under the CURRENT encoding is the module-free escaped key `@mdk_impl_zZBase_7c__28_Box_20_Int_29__7c__btag`; adding it is a row this pin does not yet have, reported rather than slipped in under a repin|LACKS|@mdk_impl_Base__Box_Int___btag\(
b1-p4-super-slot-colliding-heads/main.mdk|B-2.2-b1 SLOT-WORD SPLIT: the call site passes TWO DIFFERENT dict constants where the unique-head sibling passes `@mdk_dc_0` twice -- the declared `Deriv` slot carries the bare tag (its head is unique) and the appended `Base` slot the identity-bearing key. This is the one row in the corpus where the super slots word is DISTINGUISHABLE from the subs, which is the property #1113 needs and the premise P4 exists to falsify|HAS|call i64 @mdk_main__both\(i64 ptrtoint \(ptr @mdk_dc_0 to i64\), i64 ptrtoint \(ptr @mdk_dc_1 to i64\),
b1-xmod-same-spelled-iface-impl-selection/main.mdk|ISSUE 1514, THE ARM THAT WAS ALREADY RIGHT -- amods `impl Same Blob` occupies its OWN symbol, qualified by its DECLARING MODULE. ⚠️ READ THE PAIRING BEFORE READING THE ROW: on the BUILD arm the two same-spelled impls were ALREADY separated pre-bite, which is exactly why `build` printed the correct 11 / 110 / 7 while `run` printed 11 / 11 / 7 (the pins own measured cells). So this row and its `zmod` twin are NOT the discrimination for the drain -- section 1s value row is -- they pin that the separation the native arm always had is still there, so a future re-key cannot fix `run` by collapsing `build` down to meet it. That convergence-downwards is the one way section 1s ALL_EXACT could go green on a WORSE compiler. ⚠️ SPELLING, POST-injectiveIdent: the canonical key is `amod::Same` followed by the pipe-delimited type args, and `private_mangle.injectiveIdent` writes it `zZ`-prefixed with every non-alphanumeric byte replaced by a self-delimiting `_<hex>_` escape (`_3a_` is a colon, `_7c_` a pipe, `_28_`/`_29_` the parens, `_20_` a space), so the symbol is injective rather than human-readable -- the modules name `amod` survives the escape unescaped, so this row and its `zmod` twin are still DIFFERENT literals differing in exactly the module component, which is the whole assertion|HAS|^define i64 @mdk_impl_zZamod_3a__3a_Same_7c_Blob_7c__sizeOf\(
b1-xmod-same-spelled-iface-constrained-wrapper/main.mdk|THE SEGFAULT ASSERTION, HALF 1/3 -- amods generic call site is handed dict constant `@mdk_dc_2`. On the base arm BOTH wrapper calls were handed ONE constant, so the dispatcher (which tests the dict word, not the argument) fell through to `unreachable` and the binary faulted. This row and the next are the pair: two call sites, two DIFFERENT constants, which is a property no single row can state|HAS|call i64 @mdk_amod__aWrap\(i64 ptrtoint \(ptr @mdk_dc_2 to i64\),
b1-xmod-same-spelled-iface-constrained-wrapper/main.mdk|THE SEGFAULT ASSERTION, HALF 2/3 -- zmods generic call site is handed a DIFFERENT constant, `@mdk_dc_3`. Collapse the two modules same-spelled classes back onto one witness and this row is the one that reds, BEFORE the value row does, and it says which of the two constants went missing|HAS|call i64 @mdk_zmod__zWrap\(i64 ptrtoint \(ptr @mdk_dc_3 to i64\),
b1-xmod-same-spelled-iface-constrained-wrapper/main.mdk|THE SEGFAULT ASSERTION, 3/3 -- the shared dispatcher `@mdk_disp_sizeOf_0_1` has an arm reaching ZMODs impl. The two constants above are the CALLER side; this is the CALLEE side, and a half-applied seam moves exactly one of them. Deliberately NOT pinned by the literal tag words the arms compare (`icmp eq i64 %t1, <word>`), which are hashes of the route word and would re-red on any future re-mint without a behaviour change|HAS|call i64 @mdk_impl_ZBlob_sizeOf\(
b1-xmod-same-spelled-iface-impl-selection/main.mdk|ISSUE 1514 SEPARATION, second half: zmods `impl Same Blob` occupies a DIFFERENT symbol from amods. The PAIR is the assertion -- one symbol alone is satisfied by a compiler that emitted one definition and routed both readers to it, which is the collapsed state itself. ⚠️ Post-injectiveIdent both halves are `zZ`-escaped (see the amod row for the encoding); the two literals differ ONLY in the escaped module component (`zZamod_3a__3a_` vs `zZzmod_3a__3a_`), so the pair still states separation-by-declaring-module and not merely separation-by-something|HAS|^define i64 @mdk_impl_zZzmod_3a__3a_Same_7c_Blob_7c__sizeOf\(
b4bii-xmod-req-route-leg-still-spelling/main.mdk|B-4b-ii ROUTE-LEG OBSERVABLE: the constrained standalone reaches ZMODs method. `useIt`s body is a DIRECT call the checker resolved statically -- so the passed dict is NOT what decides this, and a row pinning the dict constant would pin a value nothing reads (the fixtures own header records that correction). The TARGET is the discrimination: a router that had selected AMODs same-spelled row would name `bar` here instead, at exit 0, with the value row still able to pass on an arithmetic coincidence|HAS|^  %t0 = call i64 @mdk_impl_Box_foo\(i64 %arg1\)$
b4bii-xmod-req-route-leg-still-spelling/main.mdk|B-4b-ii ROUTE-LEG ARITY: `useIt` abstracts 1 dict + 1 value. Paired with the row above so that a future bite which makes the route word identity-bearing cannot satisfy the target assertion by ALSO dropping the dict param -- that would be a silent arity move on a function whose caller still passes two|HAS|^define i64 @mdk_zmod__useIt\(i64 %arg0, i64 %arg1\)
s3-nary-sig-constraint-structured-arg.mdk|#1161 ARITY-NEUTRALITY PIN, structured half: `Ix a (List b) =>` is still ONE predicate/ONE slot -- `b` occurs only INSIDE `List b`, so it does not make this a "two bare-tyvar" predicate -- giving 1 dict + 2 values = arity 3. Guards the sibling mistake to the one above: a tyvar merely MENTIONED inside a structured argument must not be counted as its own bare-tyvar ARGUMENT when deciding whether the predicate has one|HAS|^define i64 @mdk_s3_nary_sig_constraint_structured_arg__useIx\(i64 %arg0, i64 %arg1, i64 %arg2\)
s8-xmod-reexport-alias-unconstrained/main.mdk|ISSUE 1472 MECHANISM PIN 1/2 -- THE ROW THIS FIXTURE EXISTS FOR, and the ONLY assertion in this corpus that can see the defect at all. The unrelated PRELUDE `println` (a CONSTRAINED method the user program never touches; `g` itself carries no constraint anywhere) must receive a REAL dict constant as its leading argument. Pre-fix the missed scheme-env lookup left that dict route resolving to nothing and the emitter wrote a NULL pointer, which is what faulted the binary. ⚠️ EVERY BEHAVIOURAL SIGNAL WAS GREEN pre-fix -- check 0, run printing the correct `2`, build 0 -- so section 1s value row cannot discriminate here and this row is not decoration|HAS|call i64 @mdk_core__println\(i64 ptrtoint \(ptr @mdk_dc_[0-9]+ to i64\),
s8-xmod-reexport-alias-unconstrained/main.mdk|ISSUE 1472 MECHANISM PIN 2/2 -- THE FAIL-CAPABLE NEGATIVE HALF, pinning the pre-fix operand OUT OF EXISTENCE by name. HAS alone is satisfiable by an emitter that wrote both a real dict somewhere and a null one at this site; LACKS states the exact byte sequence the segfaulting binary carried (`println(i64 0,`). The pair is what distinguishes "the dict is right" from "the crash moved"|LACKS|call i64 @mdk_core__println\(i64 0,
s8-xmod-reexport-alias-unconstrained/main.mdk|ISSUE 1472 IDENTITY PIN: the ALIAS importer`s `R.g` resolves to the DEFINER`s symbol `@mdk_lib_plain__g`, NOT to the re-exporter`s spelling. This is the cross-module value-identity claim itself, stated in the artifact that ships -- the scheme env and private_mangle must agree on WHICH module owns the binding, and this row is where that agreement is observable|HAS|call i64 @mdk_lib_plain__g\(
s8-xmod-reexport-selective-unconstrained-control/main.mdk|CONTROL FOR THE PAIR ABOVE: the SELECTIVE spelling emits the SAME definer symbol and the SAME real dict operand. ⚠️ Byte-identical expectations on purpose -- the emitted artifact must not depend on the importer spelling, so this row going red while its alias sibling stays green would mean the fix moved the CONTROL, which nothing in this slice should touch|HAS|call i64 @mdk_lib_plain__g\(
s8-xmod-reexport-alias-constrained/main.mdk|ISSUE 1427 MECHANISM PIN: the CONSTRAINED re-exported callee is emitted at arity 2 (1 dict + 1 value) under the DEFINER`s symbol, and the alias call site supplies a real dict constant. Pre-fix nothing was emitted at all -- the emitter panicked `unbound constrained fn: lib_decl__f` and produced no binary -- so this row is what tells a repaired build from a build that merely stopped crashing|HAS|call i64 @mdk_lib_decl__f\(i64 ptrtoint \(ptr @mdk_dc_[0-9]+ to i64\),
s8-xmod-reexport-alias-wildcard-twoimpl/main.mdk|RUN-XMOD-070 F1 MECHANISM PIN, HALF 1/2 -- the WILDCARD re-export`s `Sz Int` call site is handed dict constant `@mdk_dc_0` at the definer symbol `@mdk_lib_decl__f`. Same arity-2 (1 dict + 1 value) shape as the selective sibling`s single-impl row above, under the same WILDCARD-reached spelling|HAS|call i64 @mdk_lib_decl__f\(i64 ptrtoint \(ptr @mdk_dc_0 to i64\),
s8-xmod-reexport-alias-wildcard-twoimpl/main.mdk|RUN-XMOD-070 F1 MECHANISM PIN, HALF 2/2 -- the SAME call site`s `Sz String` invocation is handed a DIFFERENT dict constant, `@mdk_dc_2`, at the SAME definer symbol. Together the two halves are what a value-only assertion can only imply: two call sites of one re-exported constrained function, reached through a wildcard alias hop, routing to two DIFFERENT dicts rather than one dict winning for both -- the property the sibling row`s single-impl program cannot state at all|HAS|call i64 @mdk_lib_decl__f\(i64 ptrtoint \(ptr @mdk_dc_2 to i64\),
s8-xmod-reexport-alias-perm-ab/main.mdk|#1337 PERMUTATION MECHANISM PIN, ORDERING 1 of 2, HALF 1/2 -- definer A`s symbol is called from `combine` under ITS OWN definer`s mangled name. ⚠️ THE TWO HALVES ARE ONE ASSERTION and neither states it alone: the label used to claim "BOTH definers` symbols" while pinning only `pb__gb`, so a compiler that resolved `H.ga` to pb`s definer was caught only by the section-1 value, not by the row that claimed to state the property directly (RUN-XMOD-039 F4)|HAS|call i64 @mdk_lib_pa__ga\(
s8-xmod-reexport-alias-perm-ab/main.mdk|#1337 PERMUTATION MECHANISM PIN, ORDERING 1 of 2, HALF 2/2 -- definer B`s symbol, the other half of the two-distinct-definers property. Together with HALF 1/2 this row set states what the section-1 value (34 = 4 + 30) can only imply|HAS|call i64 @mdk_lib_pb__gb\(
s8-xmod-reexport-alias-perm-ba/main.mdk|#1337 PERMUTATION MECHANISM PIN, ORDERING 2 of 2, HALF 1/2 -- definer A`s symbol from the EXCHANGED declaration order. The emitted artifact must not depend on the order the hub re-exported them in|HAS|call i64 @mdk_lib_pa__ga\(
s8-xmod-reexport-alias-perm-ba/main.mdk|#1337 PERMUTATION MECHANISM PIN, ORDERING 2 of 2, HALF 2/2 -- definer B`s symbol from the EXCHANGED order. All four IR rows together are the order-invariance assertion at the artifact level, matching the section-1/section-2 pair at the value and signature levels|HAS|call i64 @mdk_lib_pb__gb\(
s-cardinality-same-iface2.mdk|S-cardinality-conformance (#1866 shape) ARITY PIN: `(Ix a Char, Ix a Bool) => a -> Int` must abstract TWO dict slots, not one -- `useIx` is arity 3 (2 dicts + 1 value). Pre-`cslotVecKey` this collapsed to arity 2 and the value alone could not see it (444 where the spec says 333, silently)|HAS|^define i64 @mdk_s_cardinality_same_iface2__useIx\(i64 %arg0, i64 %arg1, i64 %arg2\)
s-cardinality-inferred.mdk|S-cardinality-conformance (#1869 shape) ARITY PIN, `useIx`: an INFERRED bare-tyvar 2-ary predicate `Ix a b` is ONE dict slot -- arity 3 (1 dict + 2 values). Pre-`registerInferredFor` vector supply, inferred bindings recorded no vector at all, which never moved this COUNT (only the value), so this row exists to pin that the inferred path`s arity matches its signatured oracle below, not merely that a number changed|HAS|^define i64 @mdk_s_cardinality_inferred__useIx\(i64 %arg0, i64 %arg1, i64 %arg2\)
s-cardinality-inferred.mdk|S-cardinality-conformance (#1869 shape) ARITY PIN, `useJx`: same claim as the `useIx` row above, for the second inferred binding over the second interface -- arity 3 (1 dict + 2 values)|HAS|^define i64 @mdk_s_cardinality_inferred__useJx\(i64 %arg0, i64 %arg1, i64 %arg2\)
s-cardinality-inferred-swapped.mdk|S-cardinality-conformance (#1869 shape) ARITY PIN, order-independence half: the SAME arity (3 = 1 dict + 2 values) with both interfaces` impl orders flipped -- slot COUNT must not move with declaration order any more than the value does|HAS|^define i64 @mdk_s_cardinality_inferred_swapped__useIx\(i64 %arg0, i64 %arg1, i64 %arg2\)
s-cardinality-inferred-swapped.mdk|S-cardinality-conformance (#1869 shape) ARITY PIN, order-independence half, `useJx`|HAS|^define i64 @mdk_s_cardinality_inferred_swapped__useJx\(i64 %arg0, i64 %arg1, i64 %arg2\)
s-cardinality-signatured.mdk|S-cardinality-conformance (#1869 shape) ARITY PIN, the SIGNATURED oracle: `useIx` must abstract the SAME arity (3 = 1 dict + 2 values) as its inferred twin -- proving the inferred path`s COUNT now matches the declared path`s, not merely its value|HAS|^define i64 @mdk_s_cardinality_signatured__useIx\(i64 %arg0, i64 %arg1, i64 %arg2\)
s-cardinality-signatured.mdk|S-cardinality-conformance (#1869 shape) ARITY PIN, the SIGNATURED oracle`s `useJx`|HAS|^define i64 @mdk_s_cardinality_signatured__useJx\(i64 %arg0, i64 %arg1, i64 %arg2\)
s-cardinality-xmod-accept/main.mdk|S-cardinality-conformance (#1868 shape) CROSS-MODULE ARITY PIN: the definer`s exported `useIx : Ix a b => a -> b -> Int` abstracts arity 3 (1 dict + 2 values) under its OWN definer symbol, reached through the importer`s call -- the widened `crossModuleFunConstraintArgsQualRef` table correctly threads a single vector across the module boundary end to end|HAS|^define i64 @mdk_lib__useIx\(i64 %arg0, i64 %arg1, i64 %arg2\)
s-shadow-standalone-vector-arity.mdk|FIX-shadow-arity-skew ARITY PIN, the SHADOW half: a DEFINER-SHADOWED standalone with `(Ix a Char, Ix a Bool) =>` must abstract TWO dict slots -- arity 3 (2 dicts + 1 value). 🚨 THIS IS THE ROW THAT SEES THE DEFECT AT ITS SOURCE. The skew was between this DEFINITION arity (which `dictArityOf` already sized from the vector-widened table, so it read 3 even while broken) and the CALL side`s collapsed single slot; the fixture`s value row can only observe the consequence, and observes it differently on each engine. Pre-fix this symbol was already 3 params and the call passed 2 arguments|HAS|^define i64 @mdk_s_shadow_standalone_vector_arity__size\(i64 %arg0, i64 %arg1, i64 %arg2\)
s-shadow-standalone-vector-arity.mdk|FIX-shadow-arity-skew ARITY PIN, the UNRELATED half: `plain`, a NON-shadow standalone with a single 2-ary predicate `Ix a Char =>`, must still abstract exactly ONE dict slot -- arity 2 (1 dict + 1 value). The scalar arm is what `routesOfMonosTopV` falls back to term-for-term when a slot has no vector, and this row is the tripwire for a widening that over-counts slots on the code BESIDE the one under test|HAS|^define i64 @mdk_s_shadow_standalone_vector_arity__plain\(i64 %arg0, i64 %arg1\)'

# ── Coverage self-audit ──────────────────────────────────────────────────────
# Every top-level fixture unit (a .mdk file, or a directory) in FIXDIR must
# appear in TABLE, or this gate silently re-creates the orphan-corpus problem it
# exists to close (the shadow gate's audit finding, 2026-07-13).
listed="$(printf '%s\n' "$TABLE" | awk -F'|' 'NF>1{print $1}' | sed 's#/main\.mdk$##' | sort -u)"
actual="$(cd "$FIXDIR" && for e in *; do
            if [ -d "$e" ] || { [ -f "$e" ] && [ "${e%.mdk}" != "$e" ]; }; then
              echo "$e"
            fi
          done | sort -u)"

uncovered=0
for a in $actual; do
  hit=0
  for l in $listed; do
    [ "$a" = "$l" ] && hit=1 && break
  done
  if [ "$hit" -eq 0 ]; then
    uncovered=$((uncovered+1))
    echo "FAIL" >>"$TMP/v0"
    printf 'FAIL coverage: %s exists in %s but is NOT wired into this gate'"'"'s TABLE\n' "$a" "$FIXDIR"
  fi
done
if [ "$uncovered" -eq 0 ]; then
  echo "PASS" >>"$TMP/v0"
  printf 'ok   coverage: every fixture in %s is wired into this gate (%d units)\n' "$FIXDIR" "$(printf '%s\n' "$actual" | grep -c .)"
fi
echo

# ── Section 1: verdict + value + diagnostic code ─────────────────────────────
echo '=== 1. verdict (check/run/build) + pinned value + diagnostic code ==='
printf '%-52s %-6s %-6s %-6s %-11s %-22s %s\n' 'fixture' 'check' 'run' 'build' 'value' 'code' 'result'
printf '%-52s %-6s %-6s %-6s %-11s %-22s %s\n' '----------------------------------------------------' '------' '------' '------' '-----------' '----------------------' '------'

printf '%s\n' "$TABLE" | while IFS='|' read -r entry label exp_check exp_run exp_build mode value code; do
  [ -z "$entry" ] && continue
  entrypath="$FIXDIR/$entry"
  base="$(printf '%s' "$entry" | sed 's#/main\.mdk$##' | tr '/.' '__')"

  if [ ! -f "$entrypath" ]; then
    printf '%-52s %s\n' "$entry" 'FAIL MISSING FIXTURE FILE'
    echo "FAIL" >>"$TMP/v1"
    continue
  fi

  bound "$MEDAKA" check "$entrypath" >/dev/null 2>"$TMP/$base.chk.err"
  check_code=$?
  bound "$MEDAKA" run "$entrypath" >"$TMP/$base.run.out" 2>"$TMP/$base.run.err"
  run_code=$?
  bound "$MEDAKA" build "$entrypath" -o "$TMP/$base.bin" >"$TMP/$base.build.err" 2>&1
  build_code=$?

  if [ "$check_code" -eq 0 ]; then check_v='ACCEPT'; else check_v='REJECT'; fi
  if [ "$run_code" -eq 0 ]; then run_v='ACCEPT'; else run_v='REJECT'; fi
  if [ "$build_code" -eq 0 ] && [ -x "$TMP/$base.bin" ]; then
    build_v='ACCEPT'
    bound "$TMP/$base.bin" >"$TMP/$base.build.out" 2>"$TMP/$base.build.runerr"
  else
    build_v='REJECT'
    : >"$TMP/$base.build.out"
  fi

  row_ok=1
  [ "$check_v" = "$exp_check" ] || row_ok=0
  [ "$run_v" = "$exp_run" ] || row_ok=0
  [ "$build_v" = "$exp_build" ] || row_ok=0

  value_v='-'
  case "$mode" in
    NONE) ;;
    ALL_EXACT)
      if [ "$run_v" = 'ACCEPT' ] && [ "$build_v" = 'ACCEPT' ]; then
        printf '%b\n' "$value" >"$TMP/$base.expected"
        if cmp -s "$TMP/$base.run.out" "$TMP/$base.build.out" && cmp -s "$TMP/$base.run.out" "$TMP/$base.expected"; then
          value_v='ok'
        else
          value_v='DIFF'
          row_ok=0
        fi
      else
        value_v='n/a'
      fi
      ;;
    BUILD_EXACT)
      if [ "$build_v" = 'ACCEPT' ]; then
        # Optional `<run-stdout>%%<build-stdout>` split. Where `run` is expected
        # to REJECT, its exit code alone says only "something went wrong" -- a
        # startup failure or a panic on an unrelated line satisfies it equally.
        # Pinning the stdout `run` DID emit before dying pins HOW FAR IT GOT.
        # ⚠️ That is a reach point, not a reason: the harness cannot grade `run`'s
        # stderr (#1130), so the panic signature stays unpinnable and a different
        # fault at the same line would still pass. Rows using this must say so.
        case "$value" in
          *%%*)
            rwant="${value%%\%\%*}"
            bwant="${value#*\%\%}"
            printf '%b\n' "$rwant" >"$TMP/$base.expected.run"
            printf '%b\n' "$bwant" >"$TMP/$base.expected"
            if ! cmp -s "$TMP/$base.run.out" "$TMP/$base.expected.run"; then
              value_v='RUN-STDOUT-DIFF'
              row_ok=0
            elif cmp -s "$TMP/$base.build.out" "$TMP/$base.expected"; then
              value_v='ok(reach)'
            else
              value_v='WRONG'
              row_ok=0
            fi
            ;;
          *)
            printf '%b\n' "$value" >"$TMP/$base.expected"
            if cmp -s "$TMP/$base.build.out" "$TMP/$base.expected"; then
              value_v='ok'
            else
              value_v='WRONG'
              row_ok=0
            fi
            ;;
        esac
      else
        value_v='n/a'
      fi
      ;;
    SPLIT_EXACT)
      if [ "$run_v" = 'ACCEPT' ] && [ "$build_v" = 'ACCEPT' ]; then
        rwant="${value%%\%\%*}"
        bwant="${value#*\%\%}"
        printf '%b\n' "$rwant" >"$TMP/$base.expected.run"
        printf '%b\n' "$bwant" >"$TMP/$base.expected.build"
        if cmp -s "$TMP/$base.run.out" "$TMP/$base.build.out"; then
          # The drain fired: the two engines now AGREE. Re-pin this row.
          value_v='CONVERGED-FIXED'
          row_ok=0
        elif ! cmp -s "$TMP/$base.run.out" "$TMP/$base.expected.run"; then
          value_v='RUN-DIFF'
          row_ok=0
        elif ! cmp -s "$TMP/$base.build.out" "$TMP/$base.expected.build"; then
          value_v='BUILD-DIFF'
          row_ok=0
        else
          value_v='ok(split)'
        fi
      else
        value_v='n/a'
      fi
      ;;
    *)
      value_v="BADMODE:$mode"
      row_ok=0
      ;;
  esac

  # Diagnostic-code assertion. A REJECT row that does not pin its code cannot
  # distinguish "rejected for the reason the clause is about" from "rejected
  # because someone mistyped the fixture" -- and the second grades green.
  #
  # The field is a COMMA-SEPARATED list, and an entry may be prefixed `!` to assert
  # the code is ABSENT. Both halves are needed by the #1155 closedness pair: its two
  # files differ only in whether the goal is closed, and BOTH exit nonzero from the
  # same coherence reject -- so verdict and stdout are identical and the ONLY
  # observable difference is that the open one must NOT carry T-AMBIGUOUS-INSTANCE.
  # ⚠️ Without a negative assertion that pair is INERT: it would grade green with the
  # closedness gate deleted, which is the one thing it exists to detect.
  code_v='-'
  if [ -n "$code" ]; then
    bound "$MEDAKA" check --json "$entrypath" >"$TMP/$base.chk.json" 2>&1
    code_v=''
    for c in $(printf '%s' "$code" | tr ',' ' '); do
      case "$c" in
        !*)
          want="${c#!}"
          if grep -q "\"code\":\"$want\"" "$TMP/$base.chk.json"; then
            code_v="${code_v:+$code_v }PRESENT:$want"
            row_ok=0
          else
            code_v="${code_v:+$code_v }ok:!$want"
          fi
          ;;
        *)
          if grep -q "\"code\":\"$c\"" "$TMP/$base.chk.json"; then
            code_v="${code_v:+$code_v }ok:$c"
          else
            code_v="${code_v:+$code_v }MISSING:$c"
            row_ok=0
          fi
          ;;
      esac
    done
  fi

  if [ "$row_ok" -eq 1 ]; then
    result='PASS'
    echo "PASS" >>"$TMP/v1"
  else
    result='FAIL'
    echo "FAIL" >>"$TMP/v1"
    printf '     %s\n' "$label" >>"$TMP/failnotes"
  fi
  printf '%-52s %-6s %-6s %-6s %-11s %-22s %s\n' "$entry" "$check_v" "$run_v" "$build_v" "$value_v" "$code_v" "$result"
done

# ── Section 2: exact scheme lines ────────────────────────────────────────────
echo
echo '=== 2. `medaka check` scheme lines (#607/#610 printed the RIGHT value with the constraint SILENTLY DROPPED) ==='
printf '%s\n' "$SCHEMES" | while IFS='|' read -r entry label want; do
  [ -z "$entry" ] && continue
  entrypath="$FIXDIR/$entry"
  base="$(printf '%s' "$entry" | sed 's#/main\.mdk$##' | tr '/.' '__')"
  if [ ! -f "$entrypath" ]; then
    printf 'FAIL scheme %-44s MISSING FIXTURE FILE\n' "$entry"
    echo "FAIL" >>"$TMP/v2"
    continue
  fi
  bound "$MEDAKA" check "$entrypath" >"$TMP/$base.sch.out" 2>/dev/null
  if grep -qxF "$want" "$TMP/$base.sch.out"; then
    printf 'ok   scheme %-44s %s\n' "$entry" "$want"
    echo "PASS" >>"$TMP/v2"
  else
    printf 'FAIL scheme %-44s want exactly: %s\n' "$entry" "$want"
    printf '                 got:\n'
    sed 's/^/                   /' "$TMP/$base.sch.out"
    echo "FAIL" >>"$TMP/v2"
  fi
done

# ── Section 3: emitted-LLVM structural assertions ────────────────────────────
echo
echo '=== 3. emitted LLVM IR (dict-param arity + which impl a site actually resolved to) ==='
printf '%s\n' "$IRS" | while IFS='|' read -r entry label kind pat; do
  [ -z "$entry" ] && continue
  entrypath="$FIXDIR/$entry"
  base="$(printf '%s' "$entry" | sed 's#/main\.mdk$##' | tr '/.' '__')"
  if [ ! -f "$entrypath" ]; then
    printf 'FAIL ir     %-44s MISSING FIXTURE FILE\n' "$entry"
    echo "FAIL" >>"$TMP/v3"
    continue
  fi
  if [ ! -f "$TMP/$base.ir.ll" ]; then
    bound "$MEDAKA" build --keep-ir "$entrypath" -o "$TMP/$base.ir" >"$TMP/$base.ir.log" 2>&1
    if [ ! -f "$TMP/$base.ir.ll" ]; then
      printf 'FAIL ir     %-44s no IR emitted (build failed?); log tail:\n' "$entry"
      tail -4 "$TMP/$base.ir.log" | sed 's/^/                   /'
      echo "FAIL" >>"$TMP/v3"
      continue
    fi
  fi
  # ⚠️ GRADE grep's EXIT STATUS, NOT JUST ITS COUNT. `grep -c` exits 0 on match,
  # 1 on no-match, and >=2 on an ERROR (a malformed regex, an unreadable file).
  # On an error it prints nothing, so `hits` would fall back to 0 -- which `HAS`
  # reads as "not found" (a safe failure) but `LACKS` reads as "absent" (a
  # VACUOUS PASS). A single mistyped bracket in a LACKS pattern would then assert
  # nothing, forever, while the row printed `ok`. Anything above 1 is a broken
  # assertion and must FAIL the row, never satisfy it.
  #
  # ⚠️ AND THE PATTERNS ARE NOT PORTABLE BY DEFAULT: `grep` on the primary dev box
  # is **ugrep**, not GNU grep (it reports e.g. `ugrep: error: ... mismatched
  # [ ]`), while CI runs GNU grep on ubuntu-latest. A pattern that behaves one way
  # locally can behave differently there. Keep these patterns to plain POSIX ERE
  # -- literal symbol names with escaped `(` and an optional `^` anchor -- and do
  # not reach for PCRE-isms (`\d`, `\b`, lookaround, non-greedy) that only one of
  # the two implementations accepts.
  hits="$(grep -cE "$pat" "$TMP/$base.ir.ll" 2>"$TMP/$base.grep.err")"
  grep_rc=$?
  [ -n "$hits" ] || hits=0
  if [ "$grep_rc" -gt 1 ]; then
    printf 'FAIL ir     %-44s grep FAILED (exit %d) on pattern: %s\n' "$entry" "$grep_rc" "$pat"
    sed 's/^/                   /' "$TMP/$base.grep.err" 2>/dev/null | head -3
    printf '                 %s\n' "$label"
    echo "FAIL" >>"$TMP/v3"
    continue
  fi
  case "$kind" in
    HAS)
      if [ "$hits" -gt 0 ]; then
        printf 'ok   ir     %-44s HAS  %s (%d)\n' "$entry" "$pat" "$hits"
        echo "PASS" >>"$TMP/v3"
      else
        printf 'FAIL ir     %-44s HAS  %s -- NOT FOUND\n' "$entry" "$pat"
        printf '                 %s\n' "$label"
        echo "FAIL" >>"$TMP/v3"
      fi
      ;;
    LACKS)
      if [ "$hits" -eq 0 ]; then
        printf 'ok   ir     %-44s LACKS %s\n' "$entry" "$pat"
        echo "PASS" >>"$TMP/v3"
      else
        printf 'FAIL ir     %-44s LACKS %s -- FOUND %d\n' "$entry" "$pat" "$hits"
        printf '                 %s\n' "$label"
        echo "FAIL" >>"$TMP/v3"
      fi
      ;;
    COUNT=*)
      want="${kind#COUNT=}"
      if [ "$hits" -eq "$want" ]; then
        printf 'ok   ir     %-44s COUNT=%s %s\n' "$entry" "$want" "$pat"
        echo "PASS" >>"$TMP/v3"
      else
        printf 'FAIL ir     %-44s COUNT=%s %s -- FOUND %d\n' "$entry" "$want" "$pat" "$hits"
        printf '                 %s\n' "$label"
        echo "FAIL" >>"$TMP/v3"
      fi
      ;;
    *)
      printf 'FAIL ir     %-44s unknown kind %s\n' "$entry" "$kind"
      echo "FAIL" >>"$TMP/v3"
      ;;
  esac
done

# ── Section 4: declaration-order permutation differential ────────────────────
# DICT §3 makes selection ORDER-FREE ("never a function of search order,
# declaration order, or resolution position"). For any fixture with >=2 `impl`
# blocks of the SAME interface, this reverses the order of exactly those
# blocks -- nothing else in the source moves -- and asserts `check`'s verdict,
# `run`'s stdout and `build`'s stdout are all unchanged. #1154 (S0 verified,
# now FIXED) is the shape this exists to catch: swapping two disjoint
# `impl Ix Int _` blocks changed a program's answer from 111 to 222 with
# `check --json` clean on both engines.
#
# ⚠️ #1154's must-fail pin (test/must_fail_fixtures/1154-no-unique-min-decl-
# order-decides/) DRAINED when the fix landed and was deleted in that same
# commit, per its own header's instruction. The shape now lives in this gate
# instead, as `s3-nary-requires-goal-vector.mdk` -- graded on its VALUE by
# Section 1 and on its ORDER-FREEDOM here. That is not the double-count the
# deleted header warned about: a must-fail row asserts the bug STILL
# REPRODUCES and cannot coexist with a row asserting it is fixed.
#
# ⚠️ CORRECTED 2026-07-31 (F-3a-ii). This paragraph used to say #1161 -- the same
# defect on the top-level `=>`-constrained-call leg
# (`useIx : Ix a Char => a -> Int`) -- "has no goal vector to thread because the
# dict slots there are shattered one per tyvar", and was therefore unpinnable
# here. BOTH HALVES WERE WRONG, and the claim was load-bearing for anyone
# scoping the fix:
#   * There IS a goal vector. It is built from the SIGNATURE at registration
#     (`Ix a Char` at `a := Int` is `[Int, Char]`); what the old code did was
#     DISCARD every constraint argument that was not a bare type variable
#     before the dict slot was recorded, not fail to have one.
#   * Recording it does NOT require unshattering the dict slots. Storing the
#     vector in a table SLOT-PARALLEL to `funConstraintsRef` (rather than inside
#     it) widens only the GOAL each slot is selected with, leaving emitted dict
#     arity untouched -- so the shape is an ordinary dict-semantics row, graded
#     on its value, not a must-fail row.
# #1161's ROUTING half is now FIXED and lives here as
# `s3-nary-sig-constraint-goal-vector.mdk` (plus its structured sibling),
# graded on value by Section 1, on arity-neutrality by Section 3 and on
# order-freedom here. Its OBLIGATION half -- an unsatisfiable `Ix a Bool =>`
# accepted at exit 0, and the context dropped from the displayed scheme -- is a
# different channel (`declaredSchemeOblsFor` -> `declaredOblOne` ->
# `constraintArgMonos`, whose payload is ids-only) and is STILL OPEN, pinned at
# test/must_fail_fixtures/1161-sig-constraint-unsatisfiable-accepted/.
echo
echo '=== 4. declaration-order permutation (DICT §3 order-freedom; #1154/#1155) ==='

# The permuter operates on TOP-LEVEL CHUNKS: a chunk starts at any line with a
# non-whitespace character in column 0 (the offside rule puts every top-level
# declaration there) and runs until the next such line; a blank/indented line
# attaches to the chunk above it. Reversing the chunks tagged with the target
# interface swaps their CONTENTS across their original slots, so every other
# declaration -- `data`, `interface`, unrelated `impl`s, `main` -- stays at its
# original position. This is a source-level reordering, not a rewrite: if a
# permuted file fails to PARSE where the original did, that is a permuter bug,
# not a compiler finding (see AGENTS.md STOP guardrail for this gate).
PERMPL="$TMP/permute.pl"
cat >"$PERMPL" <<'PERLEOF'
use strict;
use warnings;
my ($in, $iface, $out) = @ARGV;
open(my $fh, "<", $in) or die "open $in: $!";
my @lines = <$fh>;
close $fh;
my @chunks;
my $cur;
for my $line (@lines) {
  if ($line =~ /^\S/) {
    push @chunks, $cur if $cur;
    my $ifacename;
    $ifacename = $1 if $line =~ /^(?:export\s+)?impl\s+(\w+)/;
    $cur = { iface => $ifacename, lines => [$line] };
  } else {
    $cur = { iface => undef, lines => [] } if !$cur;
    push @{$cur->{lines}}, $line;
  }
}
push @chunks, $cur if $cur;
my @idx;
for my $i (0..$#chunks) {
  push @idx, $i if defined $chunks[$i]{iface} && $chunks[$i]{iface} eq $iface;
}
die "need >=2 impl blocks of $iface, found " . scalar(@idx) . "\n" if scalar(@idx) < 2;
my @orig = map { $chunks[$_]{lines} } @idx;
for my $k (0..$#idx) {
  $chunks[$idx[$k]]{lines} = $orig[$#idx - $k];
}
open(my $ofh, ">", $out) or die "open $out: $!";
print $ofh @{$_->{lines}} for @chunks;
close $ofh;
PERLEOF

# The qualifying (fixture, interface) set is DERIVED every run, never hand-
# listed -- so a fixture added to the corpus tomorrow with >=2 impls of one
# interface is automatically exercised, with no second place to remember to
# wire it in. Scoped to files directly in FIXDIR (`*.mdk`, no recursion): a
# directory doesn't match that glob at all, which is how multi-file fixtures
# are excluded WITHOUT a name-prefix hazard (AGENTS.md's word-boundary trap
# does not apply here -- this is a glob over one directory's own entries, not
# a grep that could bleed into a sibling corpus).
PAIRS="$(cd "$FIXDIR" && for f in *.mdk; do
  [ -f "$f" ] || continue
  grep -oE '^(export )?impl [A-Za-z_][A-Za-z0-9_]*' "$f" 2>/dev/null | awk '{print $NF}' \
    | sort | uniq -c | awk -v f="$f" '$1>=2{print f"|"$2}'
done)"

# KNOWN-BAD LEDGER for this section, same convention as the top-of-file ledger:
# a pair already covered by an OPEN issue is pinned with BOTH observed values
# and asserted to DIFFER, so the row reds the day they converge (the drain)
# instead of silently passing or silently being skipped.
#   entry | iface | orig-build-value | perm-build-value | issue
KNOWNBAD_PERM='s6-2-t4-open-goal-deferred.mdk|Sh|1|2|#1183'

# THE SAME LEDGER FOR THE **RUN** ARM. ⚠️ It exists because the build-arm ledger
# above is NOT a general escape hatch: `RUN-DIFF` had no known-bad branch at all,
# so a pair whose divergence shows on BOTH engines could only be recorded by
# excluding it -- and an exclusion is a skip-list, which cannot notice when the
# thing it excuses is fixed. #1127 happens to diverge on `build` alone, which is
# why one arm sufficed until F-3d.
#   entry | iface | orig-run-value | perm-run-value | issue
KNOWNBAD_PERM_RUN='s6-2-t4-open-goal-deferred.mdk|Sh|1|2|#1183'

printf '%s\n' "$PAIRS" | while IFS='|' read -r entry iface; do
  [ -z "$entry" ] && continue
  entrypath="$FIXDIR/$entry"
  base="$(printf '%s' "$entry" | tr '/.' '__')__${iface}"
  permfile="$TMP/${base}_perm.mdk"

  if ! perl "$PERMPL" "$entrypath" "$iface" "$permfile" 2>"$TMP/$base.permerr"; then
    printf 'FAIL perm    %-40s [%-8s] PERMUTER ERROR: %s\n' "$entry" "$iface" "$(cat "$TMP/$base.permerr")"
    echo "FAIL" >>"$TMP/v4"
    continue
  fi

  bound "$MEDAKA" check --json "$entrypath" >"$TMP/$base.o.chk.json" 2>&1
  o_chk=$?
  o_code="$(grep -o '"code":"[^"]*"' "$TMP/$base.o.chk.json" | head -1)"
  bound "$MEDAKA" check --json "$permfile" >"$TMP/$base.p.chk.json" 2>&1
  p_chk=$?
  p_code="$(grep -o '"code":"[^"]*"' "$TMP/$base.p.chk.json" | head -1)"

  row_ok=1
  reason=''
  if [ "$o_chk" -eq 0 ] && [ "$p_chk" -eq 0 ]; then
    verdict='ACCEPT/ACCEPT'
  elif [ "$o_chk" -ne 0 ] && [ "$p_chk" -ne 0 ]; then
    verdict='REJECT/REJECT'
    if [ "$o_code" != "$p_code" ]; then
      row_ok=0
      reason="reject code changed under permutation: $o_code -> $p_code"
    fi
  else
    verdict="DIVERGED($o_chk/$p_chk)"
    row_ok=0
    reason='check verdict itself flipped under permutation'
  fi

  kb_line="$(printf '%s\n' "$KNOWNBAD_PERM" | awk -F'|' -v e="$entry" -v i="$iface" '$1==e && $2==i {print}')"
  kbr_line="$(printf '%s\n' "$KNOWNBAD_PERM_RUN" | awk -F'|' -v e="$entry" -v i="$iface" '$1==e && $2==i {print}')"
  runbuild='n/a'
  if [ "$o_chk" -eq 0 ] && [ "$p_chk" -eq 0 ]; then
    bound "$MEDAKA" run "$entrypath" >"$TMP/$base.o.run.out" 2>"$TMP/$base.o.run.err"
    o_run=$?
    bound "$MEDAKA" run "$permfile" >"$TMP/$base.p.run.out" 2>"$TMP/$base.p.run.err"
    p_run=$?
    # Three-way split, not a 0/0-vs-everything-else guard: an ASYMMETRIC pair
    # (one ordering runs, the other doesn't) is the LOUDEST form of the
    # property this section exists to catch -- declaration order deciding
    # whether the program runs at all -- and must FAIL the row, never read as
    # a benign skip. A SYMMETRIC failure (both orderings fail) still owes an
    # assertion: DICT §3 order-freedom binds there too, so the two orderings
    # must fail the SAME way. The level graded is the EXIT CODE, not stderr
    # TEXT: verified by hand that medaka's runtime panics are not uniformly
    # location-free (`E-DIV-ZERO` prints `file:L:C: runtime error [...]`,
    # while the `E-PANIC` this very corpus's s3-nested-obligation-two-levels.mdk
    # hits prints no location at all) -- and permutation deterministically
    # shifts every line number below the reordered blocks, so a byte-diff of
    # stderr would FAIL a program panicking for the IDENTICAL reason purely
    # because the panic's line moved: a false positive with nothing to do with
    # order-sensitivity. This mirrors why Section 1's REJECT rows compare
    # `check --json`'s diagnostic CODE, never message text -- `run` has no
    # such structured code (#1130), so exit code is the coarsest thing that is
    # both meaningful and immune to location drift.
    if [ "$o_run" -eq 0 ] && [ "$p_run" -eq 0 ]; then
      if [ -n "$kbr_line" ]; then
        # KNOWN-BAD run divergence: assert BOTH pinned values AND that they still
        # DIFFER, so the row reds on convergence (the drain) rather than absorbing
        # the fix.  Same shape as the build arm below.
        kbr_o="$(printf '%s' "$kbr_line" | cut -d'|' -f3)"
        kbr_p="$(printf '%s' "$kbr_line" | cut -d'|' -f4)"
        kbr_issue="$(printf '%s' "$kbr_line" | cut -d'|' -f5)"
        printf '%b\n' "$kbr_o" >"$TMP/$base.kbr.o.expected"
        printf '%b\n' "$kbr_p" >"$TMP/$base.kbr.p.expected"
        if cmp -s "$TMP/$base.o.run.out" "$TMP/$base.p.run.out"; then
          run_v='CONVERGED-FIXED'
          row_ok=0
          reason="${reason:+$reason; }KNOWN-BAD $kbr_issue run divergence has CONVERGED -- re-pin or drop this ledger row"
        elif cmp -s "$TMP/$base.o.run.out" "$TMP/$base.kbr.o.expected" && cmp -s "$TMP/$base.p.run.out" "$TMP/$base.kbr.p.expected"; then
          run_v="ok(known-bad $kbr_issue)"
        else
          run_v='WRONG-KNOWNBAD-VALUE'
          row_ok=0
          reason="${reason:+$reason; }KNOWN-BAD $kbr_issue row's pinned run values no longer match observed output"
        fi
      elif cmp -s "$TMP/$base.o.run.out" "$TMP/$base.p.run.out"; then
        run_v='ok'
      else
        run_v='RUN-DIFF'
        row_ok=0
        reason="${reason:+$reason; }run stdout differs under permutation"
      fi
    elif [ "$o_run" -ne 0 ] && [ "$p_run" -ne 0 ]; then
      if [ "$o_run" -eq "$p_run" ]; then
        run_v="ok(fails-both, exit $o_run)"
      else
        run_v="FAIL-DIFF-EXIT($o_run/$p_run)"
        row_ok=0
        reason="${reason:+$reason; }run fails on both orderings but with DIFFERENT exit codes: orig=$o_run perm=$p_run"
      fi
    else
      run_v="FAIL-ASYMMETRIC($o_run/$p_run)"
      row_ok=0
      reason="${reason:+$reason; }run exit code diverges under permutation: orig=$o_run perm=$p_run (order changed whether the program runs at all)"
    fi

    bound "$MEDAKA" build "$entrypath" -o "$TMP/$base.o.bin" >"$TMP/$base.o.build.log" 2>&1
    o_build=$?
    bound "$MEDAKA" build "$permfile" -o "$TMP/$base.p.bin" >"$TMP/$base.p.build.log" 2>&1
    p_build=$?
    # "Effective success" folds the -x check into the same 0/1 the run arm
    # grades on, so a build that exits 0 but somehow emits no executable is
    # treated as a failure rather than silently matching the success branch.
    o_build_ok=0; [ "$o_build" -eq 0 ] && [ -x "$TMP/$base.o.bin" ] && o_build_ok=1
    p_build_ok=0; [ "$p_build" -eq 0 ] && [ -x "$TMP/$base.p.bin" ] && p_build_ok=1
    if [ "$o_build_ok" -eq 1 ] && [ "$p_build_ok" -eq 1 ]; then
      bound "$TMP/$base.o.bin" >"$TMP/$base.o.exec.out" 2>"$TMP/$base.o.exec.err"
      bound "$TMP/$base.p.bin" >"$TMP/$base.p.exec.out" 2>"$TMP/$base.p.exec.err"
      if [ -n "$kb_line" ]; then
        kb_o="$(printf '%s' "$kb_line" | cut -d'|' -f3)"
        kb_p="$(printf '%s' "$kb_line" | cut -d'|' -f4)"
        kb_issue="$(printf '%s' "$kb_line" | cut -d'|' -f5)"
        printf '%b\n' "$kb_o" >"$TMP/$base.kb.o.expected"
        printf '%b\n' "$kb_p" >"$TMP/$base.kb.p.expected"
        if cmp -s "$TMP/$base.o.exec.out" "$TMP/$base.p.exec.out"; then
          build_v='CONVERGED-FIXED'
          row_ok=0
          reason="${reason:+$reason; }KNOWN-BAD $kb_issue build divergence has CONVERGED -- re-pin or drop this ledger row"
        elif cmp -s "$TMP/$base.o.exec.out" "$TMP/$base.kb.o.expected" && cmp -s "$TMP/$base.p.exec.out" "$TMP/$base.kb.p.expected"; then
          build_v="ok(known-bad $kb_issue)"
        else
          build_v='WRONG-KNOWNBAD-VALUE'
          row_ok=0
          reason="${reason:+$reason; }KNOWN-BAD $kb_issue row's pinned values no longer match observed output"
        fi
      else
        if cmp -s "$TMP/$base.o.exec.out" "$TMP/$base.p.exec.out"; then
          build_v='ok'
        else
          build_v='BUILD-DIFF'
          row_ok=0
          reason="${reason:+$reason; }build stdout differs under permutation"
        fi
      fi
    elif [ "$o_build_ok" -eq 0 ] && [ "$p_build_ok" -eq 0 ]; then
      # Same reasoning as the run arm's symmetric-failure branch: compare exit
      # codes, not build-log TEXT. `medaka build`'s own diagnostics can embed
      # the source path, which differs between entrypath and permfile by
      # construction (different filenames), so a textual diff would flag
      # cosmetic noise as a finding.
      if [ "$o_build" -eq "$p_build" ]; then
        build_v="ok(fails-both, exit $o_build)"
      else
        build_v="FAIL-DIFF-EXIT($o_build/$p_build)"
        row_ok=0
        reason="${reason:+$reason; }build fails on both orderings but with DIFFERENT exit codes: orig=$o_build perm=$p_build"
      fi
    else
      build_v="FAIL-ASYMMETRIC($o_build/$p_build)"
      row_ok=0
      reason="${reason:+$reason; }build exit code (or missing binary) diverges under permutation: orig=$o_build(ok=$o_build_ok) perm=$p_build(ok=$p_build_ok)"
    fi
    runbuild="run=$run_v build=$build_v"
  fi

  if [ "$row_ok" -eq 1 ]; then
    result='PASS'
    echo "PASS" >>"$TMP/v4"
  else
    result='FAIL'
    echo "FAIL" >>"$TMP/v4"
  fi
  printf '%-4s perm %-40s [%-8s] %-14s %-40s %s\n' "$result" "$entry" "$iface" "$verdict" "$runbuild" "$reason"
done

# ⚠️ N == 0 here means the DERIVATION found no qualifying fixture, not that
# permutation-sensitivity was checked and found absent -- see the empty-section
# check at the bottom of this file, which fails the whole gate on that.

# ── Section 5: the DEMOTED warning reaches every verb AND every module POSITION,
# ──            and NOTHING ELSE does ─────────────────────────────────────────────
# F-3d (#614/#311) turned a hard `T-CONFLICTING-IMPL` into the
# `W-INCOMPARABLE-IMPLS` warning. A warning that only `check` can see is a
# loud->silent transition on `run` and `build`, which is the one thing this stage
# was gated on not doing -- and NOTHING in the suite could see it: sections 1-4
# above grade stdout, exit codes and diagnostic CODES from `check --json` only;
# `diff_native_cli` discards stderr on every relevant subtest;
# `diff_compiler_run_check_agreement` greps run/build stderr for `E-PANIC` alone.
# The feature could have been reverted wholesale and the suite stayed green.
#
# ⚠️ THE `EMPTY` ROWS ARE HALF THE SECTION, and the more easily lost half. The
# first fix for the silence surfaced the WHOLE `matchWarnings` channel on
# run/build, which is ~96% false positives: that channel is populated over the
# module GRAPH, and `checkGuardExhaustivenessWith` takes its constructor oracle
# from the graph rather than from the scrutinee's own type, so an exhaustive
# `List` match is told to add a `Text _` case (issue 1185, PRE-EXISTING).
# Measured: `medaka build compiler/driver/medaka_cli.mdk` went 0 -> 4896 stderr
# lines. The `EMPTY` rows below pin that a program with no coherence overlap gets
# NOTHING on run/build stderr -- so re-widening the filter reds this section
# instead of shipping as a usability regression nobody graded.
#
#   entry | label | verb | assertion
#     verb in {check, run, build, run-json}  (`medaka build` has NO --json flag)
#     ⚠️ `check` grades STDERR ONLY here, like the others. The ENTRY module's warnings
#     go to `check`'s STDOUT (runCheckModules bundles them into the scheme dump), so a
#     stderr row is specifically about an IMPORTED module's -- which is the half that
#     was silent.
#     assertion in:
#       HAS:<ere>   stderr must match
#       NOT:<ere>   stderr must NOT match
#       EMPTY       stderr must be entirely empty
#       JSON:<code> stderr must PARSE as one JSON document (a real parser, not a
#                   regex -- the bug this catches is `{...}` preceded by caret art,
#                   which every substring check passes) AND carry that code
#       ONCE:<ere>  stderr must match EXACTLY ONCE. `HAS` cannot express this, and
#                   the difference is a real defect: a same-module overlap inside an
#                   IMPORTED module is seen by that module's own coherence sweep AND
#                   by the whole-graph one, so it printed TWICE on run/build where
#                   `check` printed it once (`cohSoftInScope`)
VERBS='s6-2-t4-open-goal-deferred.mdk|the demoted warning is VISIBLE on `run`, located, in human caret form|run|HAS:Overlapping impls of Sh
s6-2-t4-open-goal-deferred.mdk|...and human means human: `run` must NOT emit the JSON envelope|run|NOT:^\{"files"
s6-2-t4-open-goal-deferred.mdk|the demoted warning is VISIBLE on `build` too -- the verb that had NO warning surface at all before F-3d|build|HAS:Overlapping impls of Sh
s6-2-t4-open-goal-deferred.mdk|`run --json` stderr is a `Diag` JSON envelope (AGENTS.md) and must still PARSE -- human text there is worse than silence, and is what diff_compiler_eval_json caught|run-json|JSON:W-INCOMPARABLE-IMPLS
s6-c1-duplicate-heads-rejected.mdk|the HARD class still rejects LOUDLY on run (it was never demoted)|run|HAS:Overlapping impls of Tag
s6-1c-multimodule-overlap/main.mdk|🚨 THE REGRESSION `cohSoftInScope` TRADED FOR THE DE-DUPLICATION: human `check` reported the pair for the ENTRY and for the split-across-modules case but NOTHING AT ALL when it sat in an imported module -- 0 occurrences on either channel while --json/run/build all said 1. Measured across all seven graph positions a pair can occupy. `dropEntryTriple` closes it; this row is the only thing that grades `check` for a NON-ENTRY module|check|ONCE:lib.mdk:[0-9]+:[0-9]+: Overlapping impls of C
s6-1c-multimodule-overlap/main.mdk|...and ONLY the demoted code: lib.mdk also carries a deliberate W-NONEXHAUSTIVE, an IMPORTED module`s non-coherence warning, which `check` must NOT pull onto stderr. This is what makes the multi-module rows able to fail -- every other fixture in the corpus is clean, so an EMPTY row could not tell "one code" from "the whole channel"|check|NOT:non-exhaustive
s6-1c-multimodule-overlap/main.mdk|...nor may `run` surface that imported W-NONEXHAUSTIVE|run|NOT:non-exhaustive
s6-1c-multimodule-overlap/main.mdk|...nor `build`|build|NOT:non-exhaustive
s6-1c-multimodule-overlap/main.mdk|SAME-MODULE pair inside an IMPORTED module: seen by lib`s own sweep AND the whole-graph one, so it printed TWICE on run before `cohSoftInScope`. EXACTLY ONCE, with lib`s own span|run|ONCE:lib.mdk:[0-9]+:[0-9]+: Overlapping impls of C
s6-1c-multimodule-overlap/main.mdk|CROSS-MODULE pair: no per-module sweep can see it (one `D` impl each), so `globalCoherenceConflict` alone reports it, naming both owners. The ONLY in-tree coverage of that path -- it had none|run|ONCE:Overlapping impls of D .defined in lib and other.
s6-1c-multimodule-overlap/main.mdk|...and both reach `build` too|build|HAS:Overlapping impls of D .defined in lib and other.
s6-1c-unrelated-warning-not-surfaced.mdk|🚨 THE DISCRIMINATING NEGATIVE CONTROL: its `W-NONEXHAUSTIVE` IS reported by `check` (section 1 asserts that) and must NOT reach `run`. Widen the filter back to the whole matchWarnings channel and THIS row reds -- the two EMPTY rows below do not, because their programs carry no channel warning at all (verified by experiment)|run|EMPTY
s6-1c-unrelated-warning-not-surfaced.mdk|...and the same on `build`, the verb the spew measurement blew up on (0 -> 4896 lines)|build|EMPTY
s3-min-subsumes.mdk|NEGATIVE CONTROL, single-file: a ranked overlap warns about NOTHING on run. ⚠️ WEAK BY CONSTRUCTION -- this program has no channel warning to withhold, so it cannot detect a widened filter; kept only as a total-silence floor|run|EMPTY
s3-min-subsumes.mdk|NEGATIVE CONTROL, single-file: ...nor on build|build|EMPTY
s8-i2-global-instance-env/main.mdk|NEGATIVE CONTROL, MULTI-MODULE: a clean 3-module graph must produce NO run stderr. ⚠️ Same weakness as the row above -- it is a floor, not the discriminator|run|EMPTY
s8-i2-global-instance-env/main.mdk|NEGATIVE CONTROL, MULTI-MODULE: ...nor build stderr|build|EMPTY'

echo
echo '=== 5. the demoted warning on EVERY VERB (check / run / build / run --json) ==='
printf '%s\n' "$VERBS" | while IFS='|' read -r entry label verb assertion; do
  [ -z "$entry" ] && continue
  entrypath="$FIXDIR/$entry"
  base="$(printf '%s' "$entry" | sed 's#/main\.mdk$##' | tr '/.' '__')__$verb"
  if [ ! -f "$entrypath" ]; then
    printf 'FAIL verb   %-44s MISSING FIXTURE FILE\n' "$entry"
    echo "FAIL" >>"$TMP/v5"
    continue
  fi
  # STDERR ALONE, exactly as diff_compiler_eval_json captures it. stdout is the
  # program's own output and is graded by section 1.
  case "$verb" in
    check)    bound "$MEDAKA" check "$entrypath" >/dev/null 2>"$TMP/$base.err" ;;
    run)      bound "$MEDAKA" run "$entrypath" >/dev/null 2>"$TMP/$base.err" ;;
    run-json) bound "$MEDAKA" run --json "$entrypath" >/dev/null 2>"$TMP/$base.err" ;;
    build)    bound "$MEDAKA" build "$entrypath" -o "$TMP/$base.bin" >/dev/null 2>"$TMP/$base.err" ;;
    *)        printf 'FAIL verb   %-44s unknown verb %s\n' "$entry" "$verb"; echo "FAIL" >>"$TMP/v5"; continue ;;
  esac
  ok=1; detail=''
  case "$assertion" in
    EMPTY)
      if [ -s "$TMP/$base.err" ]; then
        ok=0; detail="stderr NOT empty ($(wc -l <"$TMP/$base.err") lines): $(head -1 "$TMP/$base.err")"
      fi
      ;;
    HAS:*)
      pat="${assertion#HAS:}"
      grep -qE "$pat" "$TMP/$base.err" || { ok=0; detail="stderr lacks /$pat/"; }
      ;;
    NOT:*)
      pat="${assertion#NOT:}"
      if grep -qE "$pat" "$TMP/$base.err"; then ok=0; detail="stderr matches /$pat/ but must not"; fi
      ;;
    ONCE:*)
      pat="${assertion#ONCE:}"
      # Grade grep's EXIT STATUS as well as its count, for the same reason section 3
      # does: >=2 means a BROKEN pattern, which prints nothing and would otherwise
      # read as "0 matches" -- a vacuous verdict either way.
      n="$(grep -cE "$pat" "$TMP/$base.err" 2>"$TMP/$base.greperr")"; grc=$?
      [ -n "$n" ] || n=0
      if [ "$grc" -gt 1 ]; then
        ok=0; detail="grep FAILED (exit $grc) on /$pat/: $(head -1 "$TMP/$base.greperr")"
      elif [ "$n" -ne 1 ]; then
        ok=0; detail="stderr matches /$pat/ $n time(s), want exactly 1"
      fi
      ;;
    JSON:*)
      code="${assertion#JSON:}"
      if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP/$base.err" 2>"$TMP/$base.jsonerr"; then
        grep -q "\"code\":\"$code\"" "$TMP/$base.err" || { ok=0; detail="parsed, but no \"code\":\"$code\""; }
      else
        ok=0; detail="stderr is NOT valid JSON: $(head -1 "$TMP/$base.jsonerr")"
      fi
      ;;
    *)
      ok=0; detail="unknown assertion $assertion"
      ;;
  esac
  rm -f "$TMP/$base.bin"
  if [ "$ok" -eq 1 ]; then
    printf 'ok   verb   %-44s [%-8s] %s\n' "$entry" "$verb" "$assertion"
    echo "PASS" >>"$TMP/v5"
  else
    printf 'FAIL verb   %-44s [%-8s] %s -- %s\n' "$entry" "$verb" "$assertion" "$detail"
    printf '     %s\n' "$label" >>"$TMP/failnotes"
    echo "FAIL" >>"$TMP/v5"
  fi
done

# ── Section 6: diagnostic SPANS ──────────────────────────────────────────────
# WHY THIS SECTION EXISTS, AND WHAT IT COST TO LEARN.
#
# Section 1 pins the diagnostic CODE; nothing pinned WHERE the caret lands. During
# adversarial review of issue 1549's fix (PR 1552) a reviewer found that two
# pre-existing fixtures below had silently changed output between the base and the fix:
# same verdict, same code, same message prose, caret moved from the `index` call onto
# the literal `0` -- `29:15` to `29:25`, and `46:15` to `46:25`. THIS GATE WAS GREEN
# THROUGH THE WHOLE MOVE, because a code is not a span.
#
# The mechanism is worth stating, because it says which fixtures belong here: the
# ambiguity reject reads `goalSiteLoc`, a `Ref` republished by whichever resolver drain
# ran last, and falls back to `currentLoc` when it is `None`. Any NEW site that poses a
# goal to the min-most-specific selector -- 1549's residual reducer became the second
# one, after `checkNestedReqs` -- inherits that fallback, and because the push dedups on
# the message, the FIRST, badly-located push wins over the well-located one. So a
# diagnostic's span is a property that a change nowhere near the diagnostic can move.
#
# ⚠️ PIN THE SPAN, NOT THE MESSAGE. The prose is free to change (DIAGNOSTIC-CODES-DESIGN
# and the must-fail suite both make the same split: code + range stable, prose not).
# The assertion is the literal `<line>:<col>:` prefix `medaka check` prints, matched
# against the FIRST diagnostic line for that entry.
#
# entry | label | expected `line:col`
SPANS='s6-c1-rigid-goal-no-call-discriminator.mdk|#1155 the rigid-goal ambiguity reject lands on the `index` CALL, not on its literal argument -- the PR-1552 regression pin (moved to 29:25 while every section above stayed green)|29:15
s6-c1-rigid-goal-no-minimum.mdk|the same span guarantee for the no-minimum sibling (moved to 46:25 in the same regression)|46:15
s4-gen-residual-unwitnessed-caller-rejected.mdk|issue 1549: a residual that reached the scheme is discharged AT THE CALL SITE, so the reject lands there -- not at the definition, and not on `main`|36:16
s4-gen-sig-residual-uncovered-rejected.mdk|issue 1549 gen-sig: the uncovered-residual reject lands at the DEFINITION (the body expression that needs it), which is the half a call-site span cannot distinguish|36:15
i7-qual4-gate-num.mdk|§8 I7 qual. 4 (#1539): the synthesized `Num` obligation is reported at the OPERATOR`s left operand, not at the definition or at `main`. ⚠️ These four fixture headers are comment-heavy and a fixture`s LINE COUNT is load-bearing -- a comment-only edit moves this span|36:10
i7-qual4-gate-eq.mdk|§8 I7 qual. 4 (#1539): same span guarantee for the `==` seam|13:11
i7-qual4-gate-ord.mdk|§8 I7 qual. 4 (#1539): same span guarantee for the `<` seam. The FIRST diagnostic must be the `Ord` one -- if the `Eq` superclass demand were reported first this row would catch it|13:11
i7-qual4-gate-semigroup.mdk|§8 I7 qual. 4 (#1539): same span guarantee for the `++` seam|11:10
s4-requires-depth-exceeded-rejected.mdk|issue 1562: the depth reject is attributed to the METHOD CALL that posed the goal (`tagOf …` in `deep`), through the `goalSiteLoc` the reducer republishes -- NOT to whatever `currentLoc` holds at the generalized groups close, which is the failure mode this whole section exists for|33:9
s4-gen-residual-mixed-vector-rejected.mdk|issue 1560: the mixed-vector residual is discharged AT THE CALL SITE (`f NoConv True`), like its 1549 sibling -- not at `f`s definition, which is legal on its own|45:16'

echo
echo '=== 6. diagnostic SPANS (a code is not a caret — PR 1552 moved two of these with every other section green) ==='
printf '%s\n' "$SPANS" | while IFS='|' read -r entry label want; do
  [ -z "$entry" ] && continue
  entrypath="$FIXDIR/$entry"
  base="$(printf '%s' "$entry" | sed 's#/main\.mdk$##' | tr '/.' '__')"
  if [ ! -f "$entrypath" ]; then
    printf 'FAIL span   %-44s MISSING FIXTURE FILE\n' "$entry"
    echo "FAIL" >>"$TMP/v6"
    continue
  fi
  bound "$MEDAKA" check "$entrypath" >"$TMP/$base.span.out" 2>&1
  # the first `<file>:<line>:<col>:` prefix check printed, reduced to line:col
  got="$(sed -n 's/^.*\.mdk:\([0-9][0-9]*:[0-9][0-9]*\):.*$/\1/p' "$TMP/$base.span.out" | head -1)"
  [ -n "$got" ] || got='(no located diagnostic)'
  if [ "$got" = "$want" ]; then
    printf 'ok   span   %-44s %s\n' "$entry" "$want"
    echo "PASS" >>"$TMP/v6"
  else
    printf 'FAIL span   %-44s want %s, got %s\n' "$entry" "$want" "$got"
    printf '                 %s\n' "$label"
    echo "FAIL" >>"$TMP/v6"
  fi
done

# ── Tally ────────────────────────────────────────────────────────────────────
# The `printf | while read` loops above run in a SUBSHELL under dash/ash (POSIX
# permits it and dash does fork the last pipeline stage), so shell variables
# mutated inside them do not survive. Every verdict is therefore appended to a
# FILE, which does, and the totals are derived from that -- never from a
# variable, and never from an exit code.
#
# The verdicts are kept in SEVEN files, one per section, because "did this gate
# run?" is a PER-SECTION question. A single global count cannot tell a gutted
# section-3 table from a gate that never had one, and would report `checked 36,
# 0 failed` over an IR section that made zero observations. Counting per section
# makes the emptiness REACHABLE and therefore testable.
cnt() { c="$(grep -c "^$2\$" "$TMP/$1" 2>/dev/null || true)"; [ -n "$c" ] || c=0; echo "$c"; }
p0="$(cnt v0 PASS)"; f0="$(cnt v0 FAIL)"
p1="$(cnt v1 PASS)"; f1="$(cnt v1 FAIL)"
p2="$(cnt v2 PASS)"; f2="$(cnt v2 FAIL)"
p3="$(cnt v3 PASS)"; f3="$(cnt v3 FAIL)"
p4="$(cnt v4 PASS)"; f4="$(cnt v4 FAIL)"
p5="$(cnt v5 PASS)"; f5="$(cnt v5 FAIL)"
p6="$(cnt v6 PASS)"; f6="$(cnt v6 FAIL)"
n0=$((p0+f0)); n1=$((p1+f1)); n2=$((p2+f2)); n3=$((p3+f3)); n4=$((p4+f4)); n5=$((p5+f5)); n6=$((p6+f6))
pass=$((p0+p1+p2+p3+p4+p5+p6))
fail=$((f0+f1+f2+f3+f4+f5+f6))
asserts=$((n0+n1+n2+n3+n4+n5+n6))

if [ -s "$TMP/failnotes" ]; then
  echo
  echo 'failing rows -- the clause each was pinning:'
  cat "$TMP/failnotes"
fi

echo
printf '%s: checked %d assertions -- %d passed, %d failed\n' "$(basename "$0")" "$asserts" "$pass" "$fail"
printf '  coverage-audit %d | verdict+value+code %d | schemes %d | emitted-IR %d | decl-order-perm %d | per-verb-warning %d | diag-spans %d\n' "$n0" "$n1" "$n2" "$n3" "$n4" "$n5" "$n6"

# ⚠️ AN EMPTY SECTION IS A FAILURE, NOT A PASS. Three gates in this tree once
# shelled out to a tool that was not installed, printed `skipping`, and exited 0
# -- so a required tandem gate had never once executed on that machine. "Green"
# is not "ran", and a gate that can silently no-op will. Deleting or commenting
# out a table here must RED the gate, not shrink it quietly. The same applies
# to Section 4's DERIVED set: if the derivation ever finds zero qualifying
# fixtures (e.g. a bad edit to the grep/awk pipeline, or every qualifying
# fixture being deleted), that is n4 == 0, and it fails the gate exactly like
# an emptied hand-written table would -- a self-no-op is not distinguishable
# from "nothing to check" and must not be treated as one.
empty=0
[ "$n0" -eq 0 ] && { echo "FAIL: the coverage self-audit made ZERO assertions." >&2; empty=1; }
[ "$n1" -eq 0 ] && { echo "FAIL: section 1 (verdict+value+code) made ZERO assertions -- it did not run." >&2; empty=1; }
[ "$n2" -eq 0 ] && { echo "FAIL: section 2 (schemes) made ZERO assertions -- it did not run." >&2; empty=1; }
[ "$n3" -eq 0 ] && { echo "FAIL: section 3 (emitted IR) made ZERO assertions -- it did not run." >&2; empty=1; }
[ "$n4" -eq 0 ] && { echo "FAIL: section 4 (decl-order-perm) made ZERO assertions -- the derived qualifying set was empty." >&2; empty=1; }
[ "$n5" -eq 0 ] && { echo "FAIL: section 5 (per-verb warning surface) made ZERO assertions -- it did not run." >&2; empty=1; }
[ "$n6" -eq 0 ] && { echo "FAIL: section 6 (diagnostic spans) made ZERO assertions -- it did not run." >&2; empty=1; }
[ "$empty" -eq 0 ] || exit 1

[ "$fail" -eq 0 ]
