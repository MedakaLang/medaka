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
# RECORDS WHAT THE ENGINE DID, NOT WHAT IS CORRECT. Every value pinned by this
# gate and by its native half was HAND-DERIVED FROM THE SPEC FIRST, in the
# fixture's own header
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
#   1. VERDICT + VALUE, and the coverage self-audit that reads its table, now
#      live in `test/diff_compiler_dict_semantics_test.mdk`, which holds the
#      registry name and the cost key this script used to carry. The numbering
#      below is kept so that every reference to "section 3" or "section 4" in
#      this tree still points at the section it named.
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
# * s3-nested-obligation-two-levels -- #323's eval divergence is drained by
#   canonical implementation-route dictionary counts. Both engines must print
#   7 then 119; the no-overlap control prints 31. Removing the canonical count
#   alias restores eval's panic while the no-overlap control remains correct.
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
# * s4-gen-rec-inferred-asymmetric -- #1133 DRAINED. An INFERRED mutually-recursive
#   group in which only ONE body dispatches used to typecheck with both correct
#   `Sz a =>` schemes, then fail on both engines with an unbound `$dict_evenSz_0`.
#   The operator route erased its enclosing evidence owner before recursively
#   routing the selected impl's requirements. Preserving that owner through
#   `entailInst` / `stampOpRouteVal` makes the group share its one dict prefix as §4
#   requires; check, eval and native now agree on `True` / `True`. The ascribed and
#   symmetric controls remain, and the asymmetric row is re-pinned to ALL_EXACT.
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
: >"$TMP/v2"; : >"$TMP/v3"; : >"$TMP/v4"; : >"$TMP/v5"

# ── Section 2 table: exact `medaka check` scheme lines ────────────────────────
# entry | label | expected scheme line (must appear VERBATIM in check's stdout)
#   Bare `medaka check` prints only the user's OWN top-level bindings, which is
#   why this is legible at all; `--types` would bury it under ~120 prelude lines.
SCHEMES='s1-nary-predicate-scheme-kept.mdk|§1 the 2-ary constraint SURVIVES into the scheme (#607: printed `a -> b -> Int`, constraint gone, at exit 0)|twoParam : Ix a b => a -> b -> Int
s4-joint-residual-rdict-native.mdk|#1560 TYPED SHAPE: reducing the conditional impl leaves exactly one joint two-argument predicate in `f`s principal context|f : Conv c d => a -> b -> String
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
s-structured-carry-declared-context-kept.mdk|#1937 the STRUCTURED declared context SURVIVES into the scheme -- THE ONLY OBSERVABLE THAT SEES THIS FIX ON AN ACCEPTING PROGRAM (base printed `f : Wrap Int -> Bool -> String`, the context gone, at exit 0 with the right value). ⚠️ The type is still MONOMORPHISED to `Wrap Int -> Bool` by single-impl improvement, a separate mechanism #1937 does not touch and this slice deliberately did not widen -- do NOT re-pin this to a polymorphic scheme. ⚠️ The predicate renders WITHOUT PARENTHESES (`Conv Wrap Int Bool` for `Conv (Wrap Int) Bool`), which reads as four arguments to a two-parameter interface and does not round-trip through the parser: a printer defect (#1952, `S2: misleading`) that is newly REACHABLE rather than newly broken, because until this fix the context was erased and never printed at all. 🚨 #1952 HAS NOW LANDED (sprint/nary-predicate-slots slice 2, as its permitted rider) and this row is re-pinned to the PARENTHESISED form exactly as the previous sentence instructed: `renderConstraintCtx` renders a predicate argument at ARGUMENT precedence (3), not 2, so a structured argument keeps the parens that make the context round-trip through the parser. Bare-tyvar and nullary-`TCon` arguments are atoms at either precedence, so no other scheme row moves|f : Conv (Wrap Int) Bool => Wrap Int -> Bool -> String
s6-drain-quiescence-inferred-scheme.mdk|§6.3 the QUANTIFIED RECEIVER is the whole claim of the drain pair: `top` generalizes over the very variable the graph-end drain then reports as undetermined. A scheme printed WITHOUT the `Sh a` context would mean the receiver was determined after all and the pair would be measuring nothing|top : Sh a => a -> Int
s6-drain-quiescence-declared-scheme.mdk|§6.3 the declared-scheme twin: the unannotated `relay` inherits the written context of `nonlead` verbatim, which is what carries the quantified receiver to graph end|relay : (Ixd b a, Shb a) => a -> b -> b
s-nary-given-declared-vector-selects.mdk|#1952 on a genuinely POLYMORPHIC multi-argument context, which the row above cannot show because single-impl improvement monomorphises its `a`. Both the structured argument`s parens and the second, bare-tyvar argument are asserted here, so a "fix" that parenthesised every argument (`Conv (Wrap a) (b)`) or that dropped back to prec 2 (`Conv Wrap a b`) both go red. At the sprint base `e4587a04` this printed `f : Conv Wrap a b => Wrap a -> b -> String`|f : Conv (Wrap a) b => Wrap a -> b -> String'

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
s3-implreq-nonlead-positional-identity.mdk|#1981 SHAPE 1/2: the conditional `Sz` impl receives TWO dictionaries plus its W value. Cardinality is one per complete predicate, even though both predicates share the same lead variable|HAS|^define i64 @mdk_impl_W_sz\(i64 %arg0, i64 %arg1, i64 %arg2\)
s3-implreq-nonlead-positional-identity.mdk|#1981 ROUTE 2a/3: the first method call reads dict parameter 0|HAS|call i64 @mdk_disp_ix_0_3\(i64 %arg0,
s3-implreq-nonlead-positional-identity.mdk|#1981 ROUTE 2b/3: the second method call reads distinct dict parameter 1. Paired with 2a this pins full positional identity rather than lead-only collapse|HAS|call i64 @mdk_disp_ix_0_3\(i64 %arg1,
s3-implreq-nonlead-positional-identity-swapped.mdk|#1981 ORDER SHAPE: swapping the `requires` order preserves exactly two predicate slots and therefore the same three-argument conditional method definition|HAS|^define i64 @mdk_impl_W_sz\(i64 %arg0, i64 %arg1, i64 %arg2\)
s3-implreq-nested-positional-identity.mdk|NESTED IMPL-REQUIRES SHAPE: two complete nested predicates produce two dict params plus the W value|HAS|^define i64 @mdk_impl_W_sz\(i64 %arg0, i64 %arg1, i64 %arg2\)
s3-implreq-nested-positional-identity.mdk|NESTED IMPL-REQUIRES ROUTE 1/2: the first nested predicate reads dict parameter 0|HAS|call i64 @mdk_disp_ix_0_2\(i64 %arg0,
s3-implreq-nested-positional-identity.mdk|NESTED IMPL-REQUIRES ROUTE 2/2: the second nested predicate reads distinct dict parameter 1|HAS|call i64 @mdk_disp_ix_0_2\(i64 %arg1,
s3-implreq-nested-positional-identity-swapped.mdk|NESTED IMPL-REQUIRES SWAP SHAPE: predicate order changes no cardinality|HAS|^define i64 @mdk_impl_W_sz\(i64 %arg0, i64 %arg1, i64 %arg2\)
s3-implreq-nested-positional-identity-swapped.mdk|NESTED IMPL-REQUIRES SWAP ROUTE 1/2: the first semantic call still reads its exact slot|HAS|call i64 @mdk_disp_ix_0_2\(i64 %arg0,
s3-implreq-nested-positional-identity-swapped.mdk|NESTED IMPL-REQUIRES SWAP ROUTE 2/2: the second semantic call still reads the other slot|HAS|call i64 @mdk_disp_ix_0_2\(i64 %arg1,
s-nested-encl-positional-identity.mdk|NESTED DECLARED SHAPE: two complete nested predicates plus three value arguments give arity five|HAS|^define i64 @mdk_s_nested_encl_positional_identity__f\(i64 %arg0, i64 %arg1, i64 %arg2, i64 %arg3, i64 %arg4\)
s-nested-encl-positional-identity.mdk|NESTED DECLARED ROUTE 1/2: the first occurrence reads dict parameter 0|HAS|call i64 @mdk_disp_ix_0_2\(i64 %arg0,
s-nested-encl-positional-identity.mdk|NESTED DECLARED ROUTE 2/2: the second occurrence reads distinct dict parameter 1|HAS|call i64 @mdk_disp_ix_0_2\(i64 %arg1,
s-nested-encl-positional-identity-swapped.mdk|NESTED DECLARED SWAP SHAPE: exchanging predicates preserves the five-argument definition|HAS|^define i64 @mdk_s_nested_encl_positional_identity_swapped__f\(i64 %arg0, i64 %arg1, i64 %arg2, i64 %arg3, i64 %arg4\)
s-nested-encl-positional-identity-swapped.mdk|NESTED DECLARED SWAP ROUTE 1/2: the first semantic occurrence reads its exact slot|HAS|call i64 @mdk_disp_ix_0_2\(i64 %arg0,
s-nested-encl-positional-identity-swapped.mdk|NESTED DECLARED SWAP ROUTE 2/2: the second semantic occurrence reads the other slot|HAS|call i64 @mdk_disp_ix_0_2\(i64 %arg1,
s4-joint-residual-rdict-native.mdk|#1560 SHAPE 1/2: one joint `Conv a b` residual yields exactly one dict plus two values for `f`|HAS|^define i64 @mdk_s4_joint_residual_rdict_native__f\(i64 %arg0, i64 %arg1, i64 %arg2\)
s4-joint-residual-rdict-native.mdk|#1560 RDict 2/2: `f` forwards its leading dict parameter directly as the element dictionary of the conditional Wrap impl; no null or rebuilt scalar route may replace it|HAS|call i64 @mdk_impl_Wrap_conv\(i64 %arg0, i64 %t[0-9]+, i64 %arg2\)
s4-gen-rec-nary-one-predicate-slot.mdk|RECURSIVE CARDINALITY 1/2: one n-ary `Ix a b` predicate yields one dict plus three values, not two dicts plus three values|HAS|^define i64 @mdk_s4_gen_rec_nary_one_predicate_slot__countDown\(i64 %arg0, i64 %arg1, i64 %arg2, i64 %arg3\)
s4-gen-rec-nary-one-predicate-slot.mdk|RECURSIVE FORWARDING 2/2: the self-call forwards exactly the one leading dict parameter before its three value arguments|HAS|call i64 @mdk_s4_gen_rec_nary_one_predicate_slot__countDown\(i64 %arg0,
s4-gen-residual-inferred-context.mdk|ISSUE 1549 MECHANISM PIN 1/3: `gen` abstracts a dict for the RESIDUAL, so `nest` is arity 2 (1 dict + 1 value) for a 1-argument source function. THIS IS THE ROW THAT SEES THE SEGFAULT: pre-fix the definition was arity 1 while the impl it calls needs an element dict, and no behavioural assertion could tell the difference because run printed `wrap(int)` either way|HAS|^define i64 @mdk_s4_gen_residual_inferred_context__nest\(i64 %arg0, i64 %arg1\)
s4-gen-residual-inferred-context.mdk|ISSUE 1549 MECHANISM PIN 2/3: the abstracted dict is FORWARDED to the conditional impl as its element dict -- `%arg0`, the parameter, not a constant rebuilt at the site. An arity-2 definition that ignored its dict param would keep PIN 1/3 green|HAS|call i64 @mdk_impl_Wrap_tagOf\(i64 %arg0,
s4-gen-residual-inferred-context.mdk|ISSUE 1549 MECHANISM PIN 3/3: the CALL SITE supplies that dict (a `ptrtoint` of a dict constant). Pins the `var`/`gen` arity agreement §4 requires of producer and consumer -- a caller still applying one argument is the under-application that crashed|HAS|call i64 @mdk_s4_gen_residual_inferred_context__nest\(i64 ptrtoint
s4-gen-residual-xmod/main.mdk|ISSUE 1549 CROSS-MODULE MECHANISM PIN: the dict `gen` abstracts for the residual survives the module boundary -- `nest`, defined in nest.mdk, is emitted at arity 2 (dict + value). This is the row that would have caught a fix that worked single-file and dropped the context at an import, and it is the ONLY assertion available for this fixture`s scheme (see its TABLE row)|HAS|^define i64 @mdk_nest__nest\(i64 %arg0, i64 %arg1\)
s3-assum-inst-precedence-xmod/main.mdk|#2548 ASSUM MECHANISM PIN: `mix`, defined in mix.mdk, is emitted at arity 2 (dict + value) -- `gen` abstracted a dict for its declared `Tag2 a` context across the module boundary, exactly as required for `assum` to have anything to forward|HAS|^define i64 @mdk_mix__mix\(i64 %arg0, i64 %arg1\)
s3-assum-inst-precedence-xmod/main.mdk|#2548 ASSUM ROUTE: the `tagn x` occurrence -- goal `Tag2 a`, LITERALLY the declared predicate -- dispatches through the FORWARDED CALLER DICT `%arg0`, never rebuilding one. This is `assum` on the wire: a regression that routed this call through `inst` instead would still print the right value (both impls happen to answer their own ground goal correctly) but would drop this dict-forwarding shape|HAS|call i64 @mdk_disp_tagn_0_1\(i64 %arg0, i64 %arg1\)
s3-assum-inst-precedence-xmod/main.mdk|#2548 INST ROUTE: the `tagn (True : Bool)` occurrence -- goal `Tag2 Bool`, structurally distinct from the assumption `Tag2 a` -- compiles to a DIRECT CALL to `impl Tag2 Bool` with NO dict argument at all, because `inst` resolved and committed to the instance at elaboration time rather than deferring to any dict. This is the row `assum` alone cannot produce: a regression that routed EVERY occurrence through the forwarded dict (collapsing `inst` into `assum`) would leave this pattern absent|HAS|call i64 @mdk_impl_Bool_tagn\(i64 3\)
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
b1-xmod-default-inherited-tag/main.mdk|ARCH B-2 (B-2.2-b1) DISCRIMINATOR 1/2, and the ONLY assertion this fixture has: the CROSS-MODULE method-less impl routes through the lifted interface default, whose symbol is keyed on the head tag `optionOr tag` supplies at `keyForSite`s no-row arm and the selected one-argument declaration arity. A `b1` that deleted that fallback -- which every design document before RUN-P3-013 said it would -- moves or loses this symbol|HAS|call i64 @mdk_default_sz_Box_a1\(
b1-xmod-default-inherited-tag/main.mdk|ARCH B-2 (B-2.2-b1) DISCRIMINATOR 2/2: the SAME-MODULE twin, in the same program, takes the ordinary TAGGED route instead -- `fillImplDefaults` specialized a clause for it, so the candidate scan sees a row. The PAIR is the assertion: one source shape, two routes, and only both together show that this bite moved neither|HAS|call i64 @mdk_impl_Cup_sz\(
b1-p4-super-slot-unique-heads/main.mdk|P4 PC2: the appended super slot really is THREADED -- three params (2 dicts + 1 value) for a one-argument source function. Every other P4 assertion is vacuous without this one|HAS|^define i64 @mdk_main__both\(i64 %arg0, i64 %arg1, i64 %arg2\)
b1-p4-super-slot-unique-heads/main.mdk|P4 TRIPWIRE PROPER: the SAME dict constant is applied at BOTH slots. This is the sentence `typecheck.mdk` states as a premise ("the super slots route is identical to the subs") rendered as IR, and it is UNMOVED by B-2.2-b1 because the collision gate is False at both slots. When ARCH B-2 finally makes routes identity-bearing unconditionally, THIS is the row that must go red and be re-derived -- not silently re-blessed|HAS|call i64 @mdk_main__both\(i64 ptrtoint \(ptr @mdk_dc\.program\.0 to i64\), i64 ptrtoint \(ptr @mdk_dc\.program\.0 to i64\),
b1-p4-super-slot-unique-heads/main.mdk|P4 UNIQUE-HEAD CONTROL: at a head with ONE impl the emitted symbol is the BARE TAG -- `@mdk_impl_T_btag`, not an identity-qualified name. Stated as the positive so that an unconditional identity widening is caught here rather than in a seed re-mint|HAS|call i64 @mdk_impl_T_btag\(
b1-p4-super-slot-colliding-heads/main.mdk|B-2.2-b1 + B-2.2-e HEADLINE OBSERVABLE: with two impls of `Base` at head `Box` the route word is the canonical impl key, and that key still carries the DECLARING MODULEs interface identity -- the key reads `base::Base` followed by the pipe-delimited type args. ⚠️ AS OF THE injectiveIdent BITE THE SYMBOL IS NO LONGER THAT KEY SANITIZED: `private_mangle.injectiveIdent` writes it `zZ`-prefixed with every non-alphanumeric byte replaced by a self-delimiting `_<hex>_` escape (`_3a_` is a colon, `_7c_` a pipe, `_28_`/`_29_` the parens, `_20_` a space), so the symbol is injective rather than human-readable. THE ARCHITECTURAL CLAIM SURVIVES THE ESCAPE VERBATIM, which is why this row is still a mechanism pin and not just a spelling: alphanumeric runs pass through unescaped, so the declaring modules name `base` is still LITERALLY PRESENT in the pinned text -- declare `Base` in a DIFFERENT module and this row goes red, exactly as it did pre-escape. Pre-bite this symbol was `@mdk_impl_Base__Box_Int___btag`, with no module component; the LACKS row below is the negative half|HAS|@mdk_impl_zZbase_3a__3a_Base_7c__28_Box_20_Int_29__7c__btag\(
b1-p4-super-slot-colliding-heads/main.mdk|B-2.2-b1 + B-2.2-e NEGATIVE HALF: the pre-bite, identity-free spelling is GONE. A HAS row alone cannot see a change that ADDS the qualified symbol while leaving the bare one live somewhere, which is exactly the shape a half-applied seam (caller side moved, definition side not) produces. ⚠️ HISTORICAL NEGATIVE SINCE THE injectiveIdent BITE, AND DELIBERATELY LEFT AS ONE RATHER THAN QUIETLY RESPELLED: this literal is the SANITIZED spelling, and the sanitizer is no longer on this path at all, so no current compiler configuration emits it -- the row still catches a REVERT of the whole seam (sanitizer back, module component dropped) but no longer discriminates a half-applied one. The fail-capable negative under the CURRENT encoding is the module-free escaped key `@mdk_impl_zZBase_7c__28_Box_20_Int_29__7c__btag`; adding it is a row this pin does not yet have, reported rather than slipped in under a repin|LACKS|@mdk_impl_Base__Box_Int___btag\(
b1-p4-super-slot-colliding-heads/main.mdk|B-2.2-b1 SLOT-WORD SPLIT: the call site passes TWO DIFFERENT dict constants where the unique-head sibling passes `@mdk_dc.program.0` twice -- the declared `Deriv` slot carries the bare tag (its head is unique) and the appended `Base` slot the identity-bearing key. This is the one row in the corpus where the super slots word is DISTINGUISHABLE from the subs, which is the property #1113 needs and the premise P4 exists to falsify|HAS|call i64 @mdk_main__both\(i64 ptrtoint \(ptr @mdk_dc\.program\.0 to i64\), i64 ptrtoint \(ptr @mdk_dc\.program\.1 to i64\),
b1-xmod-same-spelled-iface-impl-selection/main.mdk|ISSUE 1514, THE ARM THAT WAS ALREADY RIGHT -- amods `impl Same Blob` occupies its OWN symbol, qualified by its DECLARING MODULE. ⚠️ READ THE PAIRING BEFORE READING THE ROW: on the BUILD arm the two same-spelled impls were ALREADY separated pre-bite, which is exactly why `build` printed the correct 11 / 110 / 7 while `run` printed 11 / 11 / 7 (the pins own measured cells). So this row and its `zmod` twin are NOT the discrimination for the drain -- section 1s value row is -- they pin that the separation the native arm always had is still there, so a future re-key cannot fix `run` by collapsing `build` down to meet it. That convergence-downwards is the one way section 1s ALL_EXACT could go green on a WORSE compiler. ⚠️ SPELLING, POST-injectiveIdent: the canonical key is `amod::Same` followed by the pipe-delimited type args, and `private_mangle.injectiveIdent` writes it `zZ`-prefixed with every non-alphanumeric byte replaced by a self-delimiting `_<hex>_` escape (`_3a_` is a colon, `_7c_` a pipe, `_28_`/`_29_` the parens, `_20_` a space), so the symbol is injective rather than human-readable -- the modules name `amod` survives the escape unescaped, so this row and its `zmod` twin are still DIFFERENT literals differing in exactly the module component, which is the whole assertion|HAS|^define i64 @mdk_impl_zZamod_3a__3a_Same_7c_Blob_7c__sizeOf\(
b1-xmod-same-spelled-iface-constrained-wrapper/main.mdk|THE SEGFAULT ASSERTION, HALF 1/3 -- amods generic call site is handed dict constant `@mdk_dc.amod.0`. On the base arm BOTH wrapper calls were handed ONE constant, so the dispatcher (which tests the dict word, not the argument) fell through to `unreachable` and the binary faulted. This row and the next are the pair: two call sites, two DIFFERENT constants, which is a property no single row can state|HAS|call i64 @mdk_amod__aWrap\(i64 ptrtoint \(ptr @mdk_dc\.amod\.0 to i64\),
b1-xmod-same-spelled-iface-constrained-wrapper/main.mdk|THE SEGFAULT ASSERTION, HALF 2/3 -- zmods generic call site is handed a DIFFERENT constant, `@mdk_dc.zmod.0`. Collapse the two modules same-spelled classes back onto one witness and this row is the one that reds, BEFORE the value row does, and it says which of the two constants went missing|HAS|call i64 @mdk_zmod__zWrap\(i64 ptrtoint \(ptr @mdk_dc\.zmod\.0 to i64\),
b1-xmod-same-spelled-iface-constrained-wrapper/main.mdk|THE SEGFAULT ASSERTION, 3/3 -- the shared dispatcher `@mdk_disp_sizeOf_0_1` has an arm reaching ZMODs impl. The two constants above are the CALLER side; this is the CALLEE side, and a half-applied seam moves exactly one of them. Deliberately NOT pinned by the literal tag words the arms compare (`icmp eq i64 %t1, <word>`), which are hashes of the route word and would re-red on any future re-mint without a behaviour change|HAS|call i64 @mdk_impl_ZBlob_sizeOf\(
b1-xmod-same-spelled-iface-impl-selection/main.mdk|ISSUE 1514 SEPARATION, second half: zmods `impl Same Blob` occupies a DIFFERENT symbol from amods. The PAIR is the assertion -- one symbol alone is satisfied by a compiler that emitted one definition and routed both readers to it, which is the collapsed state itself. ⚠️ Post-injectiveIdent both halves are `zZ`-escaped (see the amod row for the encoding); the two literals differ ONLY in the escaped module component (`zZamod_3a__3a_` vs `zZzmod_3a__3a_`), so the pair still states separation-by-declaring-module and not merely separation-by-something|HAS|^define i64 @mdk_impl_zZzmod_3a__3a_Same_7c_Blob_7c__sizeOf\(
b4bii-xmod-req-route-leg-still-spelling/main.mdk|B-4b-ii ROUTE-LEG OBSERVABLE: the constrained standalone reaches ZMODs method. `useIt`s body is a DIRECT call the checker resolved statically -- so the passed dict is NOT what decides this, and a row pinning the dict constant would pin a value nothing reads (the fixtures own header records that correction). The TARGET is the discrimination: a router that had selected AMODs same-spelled row would name `bar` here instead, at exit 0, with the value row still able to pass on an arithmetic coincidence|HAS|^  %t0 = call i64 @mdk_impl_Box_foo\(i64 %arg1\)$
b4bii-xmod-req-route-leg-still-spelling/main.mdk|B-4b-ii ROUTE-LEG ARITY: `useIt` abstracts 1 dict + 1 value. Paired with the row above so that a future bite which makes the route word identity-bearing cannot satisfy the target assertion by ALSO dropping the dict param -- that would be a silent arity move on a function whose caller still passes two|HAS|^define i64 @mdk_zmod__useIt\(i64 %arg0, i64 %arg1\)
s3-nary-sig-constraint-structured-arg.mdk|#1161 ARITY-NEUTRALITY PIN, structured half: `Ix a (List b) =>` is still ONE predicate/ONE slot -- `b` occurs only INSIDE `List b`, so it does not make this a "two bare-tyvar" predicate -- giving 1 dict + 2 values = arity 3. Guards the sibling mistake to the one above: a tyvar merely MENTIONED inside a structured argument must not be counted as its own bare-tyvar ARGUMENT when deciding whether the predicate has one|HAS|^define i64 @mdk_s3_nary_sig_constraint_structured_arg__useIx\(i64 %arg0, i64 %arg1, i64 %arg2\)
s8-xmod-reexport-alias-unconstrained/main.mdk|ISSUE 1472 MECHANISM PIN 1/2 -- THE ROW THIS FIXTURE EXISTS FOR, and the ONLY assertion in this corpus that can see the defect at all. The unrelated PRELUDE `println` (a CONSTRAINED method the user program never touches; `g` itself carries no constraint anywhere) must receive a REAL dict constant as its leading argument. Pre-fix the missed scheme-env lookup left that dict route resolving to nothing and the emitter wrote a NULL pointer, which is what faulted the binary. ⚠️ EVERY BEHAVIOURAL SIGNAL WAS GREEN pre-fix -- check 0, run printing the correct `2`, build 0 -- so section 1s value row cannot discriminate here and this row is not decoration|HAS|call i64 @mdk_core__println\(i64 ptrtoint \(ptr @mdk_dc\.[A-Za-z0-9_]+\.[0-9]+ to i64\),
s8-xmod-reexport-alias-unconstrained/main.mdk|ISSUE 1472 MECHANISM PIN 2/2 -- THE FAIL-CAPABLE NEGATIVE HALF, pinning the pre-fix operand OUT OF EXISTENCE by name. HAS alone is satisfiable by an emitter that wrote both a real dict somewhere and a null one at this site; LACKS states the exact byte sequence the segfaulting binary carried (`println(i64 0,`). The pair is what distinguishes "the dict is right" from "the crash moved"|LACKS|call i64 @mdk_core__println\(i64 0,
s8-xmod-reexport-alias-unconstrained/main.mdk|ISSUE 1472 IDENTITY PIN: the ALIAS importer`s `R.g` resolves to the DEFINER`s symbol `@mdk_lib_plain__g`, NOT to the re-exporter`s spelling. This is the cross-module value-identity claim itself, stated in the artifact that ships -- the scheme env and private_mangle must agree on WHICH module owns the binding, and this row is where that agreement is observable|HAS|call i64 @mdk_lib_plain__g\(
s8-xmod-reexport-selective-unconstrained-control/main.mdk|CONTROL FOR THE PAIR ABOVE: the SELECTIVE spelling emits the SAME definer symbol and the SAME real dict operand. ⚠️ Byte-identical expectations on purpose -- the emitted artifact must not depend on the importer spelling, so this row going red while its alias sibling stays green would mean the fix moved the CONTROL, which nothing in this slice should touch|HAS|call i64 @mdk_lib_plain__g\(
s8-xmod-reexport-alias-constrained/main.mdk|ISSUE 1427 MECHANISM PIN: the CONSTRAINED re-exported callee is emitted at arity 2 (1 dict + 1 value) under the DEFINER`s symbol, and the alias call site supplies a real dict constant. Pre-fix nothing was emitted at all -- the emitter panicked `unbound constrained fn: lib_decl__f` and produced no binary -- so this row is what tells a repaired build from a build that merely stopped crashing|HAS|call i64 @mdk_lib_decl__f\(i64 ptrtoint \(ptr @mdk_dc\.[A-Za-z0-9_]+\.[0-9]+ to i64\),
s8-xmod-reexport-alias-wildcard-twoimpl/main.mdk|RUN-XMOD-070 F1 MECHANISM PIN, HALF 1/2 -- the WILDCARD re-export`s `Sz Int` call site is handed dict constant `@mdk_dc.program.0` at the definer symbol `@mdk_lib_decl__f`. Same arity-2 (1 dict + 1 value) shape as the selective sibling`s single-impl row above, under the same WILDCARD-reached spelling|HAS|call i64 @mdk_lib_decl__f\(i64 ptrtoint \(ptr @mdk_dc\.program\.0 to i64\),
s8-xmod-reexport-alias-wildcard-twoimpl/main.mdk|RUN-XMOD-070 F1 MECHANISM PIN, HALF 2/2 -- the SAME call site`s `Sz String` invocation is handed a DIFFERENT dict constant, `@mdk_dc.program.2`, at the SAME definer symbol. Together the two halves are what a value-only assertion can only imply: two call sites of one re-exported constrained function, reached through a wildcard alias hop, routing to two DIFFERENT dicts rather than one dict winning for both -- the property the sibling row`s single-impl program cannot state at all|HAS|call i64 @mdk_lib_decl__f\(i64 ptrtoint \(ptr @mdk_dc\.program\.2 to i64\),
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
#     go to `check`'s STDOUT (`checkRoute`'s multi-module arm bundles them into the scheme dump), so a
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
VERBS='s6-2-t4-open-goal-deferred.mdk|SINGLE-FILE `W-OPEN-GOAL-COMMITTED` on `run`, which NOTHING in the tree graded before this row -- the code is `test/t4_census.sh`s subject and that tool is report-only. ⚠️ NOT a test of the allowlist: single-file `run`/`build` take `allWarnTriples`, the ONE place they widen past `runBuildWarnCodes`, so this row stays green with the allowlist entry deleted (measured). It guards the UNFILTERED arm; the s6-t4-channel-multimodule rows below guard the filtered one, and neither substitutes for the other|run|HAS:Instance for .Sh. chosen by declaration order
s6-2-t4-open-goal-deferred.mdk|...and on `build`, the sibling verb of the same widened single-file arm|build|HAS:Instance for .Sh. chosen by declaration order
s6-2-t4-open-goal-deferred.mdk|...and on `check`, whose stderr carries it even for an ENTRY module -- the baseline the two verbs above had to catch up to, and the only one of the three that was ever audible|check|HAS:Instance for .Sh. chosen by declaration order
s6-t4-channel-multimodule/main.mdk|🚨 THE ROW THE ALLOWLIST NEVER HAD: `run` surfaces `W-OPEN-GOAL-COMMITTED` for a NON-ENTRY module. This is the only assertion in the tree that consults `runBuildWarnCodes` for this code -- MEASURED by deleting `openGoalCommitWarnCode` from that list and rebuilding, which drops exactly this line while leaving `W-INCOMPARABLE-IMPLS` and every single-file row above untouched. ONCE, with lib.mdks own span, for `s6-1c-multimodule-overlap`s reason: an imported modules site is visible to more than one sweep, so a second occurrence is a real defect and not noise|run|ONCE:lib\.mdk:[0-9]+:[0-9]+: Instance for .Sh. chosen by declaration order
s6-t4-channel-multimodule/main.mdk|...and ONLY the allowlisted code: lib.mdk also carries a deliberate `W-NONEXHAUSTIVE`, an imported modules NON-allowlisted warning. Without it the row above could not tell "the allowlist gained this code" from "the whole matchWarnings channel is surfaced" -- #1185s 0 -> 4896 stderr lines|run|NOT:non-exhaustive
s6-t4-channel-multimodule/main.mdk|...and `build` reports it too, sharing the multi-module arm with `run` -- the verb that had no warning surface at all before F-3d|build|ONCE:lib\.mdk:[0-9]+:[0-9]+: Instance for .Sh. chosen by declaration order
s6-t4-channel-multimodule/main.mdk|...and `build` withholds that imported `W-NONEXHAUSTIVE`, the same negative half|build|NOT:non-exhaustive
s6-t4-channel-multimodule/main.mdk|`check` reports it for the IMPORTED module on STDERR. The ENTRY modules own warnings go to `check`s STDOUT, so a stderr row here is specifically about the non-entry position -- the half `dropEntryTriple` exists for, and the position the two verbs above are being compared against|check|ONCE:lib\.mdk:[0-9]+:[0-9]+: Instance for .Sh. chosen by declaration order
s6-t4-channel-multimodule/main.mdk|...and `check` withholds the imported `W-NONEXHAUSTIVE` too|check|NOT:non-exhaustive
s6-t4-channel-multimodule/main.mdk|`run --json` carries the code in a `Diag` envelope that still PARSES -- the machine surface of the same multi-module channel, graded by a real parser rather than by a substring|run-json|JSON:W-OPEN-GOAL-COMMITTED
s6-2-t4-open-goal-deferred.mdk|the demoted warning is VISIBLE on `run`, located, in human caret form|run|HAS:Overlapping impls of Sh
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
s6-1c-unrelated-warning-not-surfaced.mdk|S-warning-parity (#2400/F4, this diff): single-file `run` now surfaces the FULL warning channel, not just the coherence allowlist -- #1185`s cross-module constructor-oracle spew this row used to guard against cannot fire single-file (no imported constructor universe to draw from), so `W-NONEXHAUSTIVE` correctly reaches `run` here now. This row FLIPPED from EMPTY; see the fixture`s own header for the updated spec derivation|run|HAS:non-exhaustive match of .Colour.
s6-1c-unrelated-warning-not-surfaced.mdk|...and the same on `build` -- single-file `build` shares the widened arm, and #1185`s spew (the 0 -> 4896 lines measurement this row`s name refers to) is a MULTI-MODULE-only failure mode, unaffected here|build|HAS:non-exhaustive match of .Colour.
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
s4-gen-sig-num-result-rejected.mdk|#830 numeric result: missing Num is reported at the body literal, without a caller|2:6
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
p2="$(cnt v2 PASS)"; f2="$(cnt v2 FAIL)"
p3="$(cnt v3 PASS)"; f3="$(cnt v3 FAIL)"
p4="$(cnt v4 PASS)"; f4="$(cnt v4 FAIL)"
p5="$(cnt v5 PASS)"; f5="$(cnt v5 FAIL)"
p6="$(cnt v6 PASS)"; f6="$(cnt v6 FAIL)"
n2=$((p2+f2)); n3=$((p3+f3)); n4=$((p4+f4)); n5=$((p5+f5)); n6=$((p6+f6))
pass=$((p2+p3+p4+p5+p6))
fail=$((f2+f3+f4+f5+f6))
asserts=$((n2+n3+n4+n5+n6))

if [ -s "$TMP/failnotes" ]; then
  echo
  echo 'failing rows -- the clause each was pinning:'
  cat "$TMP/failnotes"
fi

echo
printf '%s: checked %d assertions -- %d passed, %d failed\n' "$(basename "$0")" "$asserts" "$pass" "$fail"
printf '  schemes %d | emitted-IR %d | decl-order-perm %d | per-verb-warning %d | diag-spans %d\n' "$n2" "$n3" "$n4" "$n5" "$n6"

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
[ "$n2" -eq 0 ] && { echo "FAIL: section 2 (schemes) made ZERO assertions -- it did not run." >&2; empty=1; }
[ "$n3" -eq 0 ] && { echo "FAIL: section 3 (emitted IR) made ZERO assertions -- it did not run." >&2; empty=1; }
[ "$n4" -eq 0 ] && { echo "FAIL: section 4 (decl-order-perm) made ZERO assertions -- the derived qualifying set was empty." >&2; empty=1; }
[ "$n5" -eq 0 ] && { echo "FAIL: section 5 (per-verb warning surface) made ZERO assertions -- it did not run." >&2; empty=1; }
[ "$n6" -eq 0 ] && { echo "FAIL: section 6 (diagnostic spans) made ZERO assertions -- it did not run." >&2; empty=1; }
[ "$empty" -eq 0 ] || exit 1

[ "$fail" -eq 0 ]
