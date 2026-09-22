# `test/dict_fixtures` — the DICT-SEMANTICS conformance corpus

The fixtures in this directory are the executing corpus for
`docs/spec/DICT-SEMANTICS.md`. Three gates read them, and this file is the
prose all three share: what the corpus pins (and why that is not the same as
"correct"), the LEDGER of rows pinned to a known divergence, and the honest
punch-list of what is NOT YET COVERED.

The assertion sections keep the numbers they carried when one shell script
held all of them, because references to "section 3" and "section 4" are
scattered across this tree. Where each lives now:

| Section | Asserts | Lives in |
|---|---|---|
| 1 | verdict + value + diagnostic code, and the coverage self-audit | `test/diff_compiler_dict_semantics_test.mdk` |
| 2 | the `medaka check` scheme line | `test/diff_compiler_dict_semantics_test.mdk` |
| 3 | emitted LLVM IR (`build --keep-ir`) | `test/diff_compiler_dict_semantics_ir.sh` |
| 4 | declaration-order permutation | `test/diff_compiler_dict_semantics_permute.sh` |
| 5 | the per-verb warning surface | `test/diff_compiler_dict_semantics_test.mdk` |
| 6 | diagnostic spans | `test/diff_compiler_dict_semantics_test.mdk` |

The carried heading below still reads "FOUR ASSERTION SECTIONS": sections 5
and 6 were added after it was written and it was never renumbered. It is kept
as-is because what it is really for is the argument for why 3 and 4 exist at
all, which is unchanged.

Until this existed, `docs/spec/DICT-SEMANTICS.md` had NO EXECUTING GATE (#616).
The conformance reviewer was the sole enforcement mechanism, and reviewers are
per-PR, human-scale, and only look at the diff in front of them. That document
accumulated FOUR independent divergences in a single day (#607/#609/#610/#614),
three of them found by reading the spec against the source rather than by any
test, while every gate stayed green -- because THE COMPILER'S OWN SOURCE
CONTAINS ZERO MULTI-ARG CONSTRAINTS, so the self-hosting corpus is
constitutionally blind to the entire class. `typecheck_compiler_source.sh` and
the self-compile fixpoint cannot see any of it.

Modelled directly on test/diff_compiler_shadow_semantics.sh, whose design
decisions transfer wholesale (#616 item 2): the check/run/build agreement
harness, the pin-current-behaviour discipline, the coverage self-audit, and the
KNOWN-BAD-row-as-ledger idea are all its.

## WHAT THIS GATE PINS, AND WHY THAT IS NOT THE SAME AS "CORRECT"
⚠️ THIS GATE PINS WHAT THE BINARY ACTUALLY DOES ON CURRENT MAIN, NOT WHAT THE
SPEC SAYS SHOULD HAPPEN. A gate that asserted the spec would just be red, and a
red gate teaches people to ignore it. Divergences are pinned WITH AN ANNOTATION
NAMING THE ISSUE, so the gate doubles as the conformance ledger and
SELF-DRAINS: the day a fix lands the row goes RED and whoever fixed it must
come here and re-pin the cell.

⚠️ AND THE CONVERSE, WHICH IS THE MORE DANGEROUS HALF: A CAPTURED GOLDEN
RECORDS WHAT THE ENGINE DID, NOT WHAT IS CORRECT. Every value pinned by this
gate and by its native half was HAND-DERIVED FROM THE SPEC FIRST, in the
fixture's own header
comment, and only then compared against the binary. Where they agree the row is
CONFORMANT; where they disagree the row says so in its label and names the
issue. THREE ENGINES AGREEING DOES NOT PROVE CORRECTNESS -- several known S0s
have every engine equally wrong, which is exactly why `diff_compiler_engines`
cannot see them. s3-min-fully-general-sibling WAS such a cell (both engines
printing the same WRONG number at exit 0) until #1128 was fixed on 2026-08-01;
s6-1-4-supers-per-construction-goal was one on the build arm alone until #1127
drained on 2026-08-23. Both rows are kept, re-pinned to their hand-derived spec
answers -- a drained row is the cheapest regression test the corpus has.

## FOUR ASSERTION SECTIONS, BECAUSE VERDICTS ARE NOT ENOUGH
  1. VERDICT + VALUE, and the coverage self-audit that reads its table, now
     live in `test/diff_compiler_dict_semantics_test.mdk`, which holds the
     registry name and the cost key the retired shell script used to carry. The
     numbering
     below is kept so that every reference to "section 3" or "section 4" in
     this tree still points at the section it named.
  2. SCHEME. The exact `medaka check` scheme line for the binding under test.
     #607's and #610's discriminating probe was the scheme, not the value:
     both printed the RIGHT number while having SILENTLY DROPPED the
     constraint from the type. A verdict+value row cannot see that.
  3. EMITTED IR. `medaka build --keep-ir` and a pinned pattern over the `.ll`.
     This is the only section that can see a DEAD DICT SLOT (#607) or an
     arity skew (§8 I1) -- both invisible from behaviour alone -- and it is
     what turned "I think the wrong impl is selected" into
     `call @mdk_impl_Box_tag` on the screen for the S0 below.
  4. DECLARATION-ORDER PERMUTATION. Sections 1-3 all pin ONE declaration
     order per fixture and pass BY CONSTRUCTION for an ACCEPTANCE WIDENING --
     every golden covers the order it was captured at. For any fixture with
     >=2 `impl` blocks of one interface, reversing exactly those blocks must
     not change `check`'s verdict, `run`'s stdout, or `build`'s stdout. This
     needs no ground truth (DICT §3: selection is never "a function of search
     order, declaration order, or resolution position"), which is what makes
     it the one section that can catch "the winner is decided by order"
     without knowing the right answer -- #1154's exact shape.

⚠️ #616 item 4 asks for the TYPED, DICT-PASSED CORE IR
(`compiler/entries/core_ir_typed_modules_dump_main.mdk`). Section 3 uses
`build --keep-ir` INSTEAD, deliberately: it observes the same facts (dict-param
arity, which impl a site resolved to, which dicts were passed) on the path that
actually SHIPS, and it needs no oracle -- so that gate has no `test/bin/*`
staleness coupling and no `build_oracles.sh` registration. The Core-IR dump
route is listed under NOT YET COVERED below; it would add route-kind
(`RKey`/`RLocal`) visibility that LLVM IR flattens.

## THE LEDGER -- rows pinned to a KNOWN divergence, newest first
* s-instantiated-reselect-declared / -inferred / -general-sibling /
  -unsatisfiable-rejected -- #1909 (S0, a structured single-subject `=>` context
  committing to ONE impl at abstraction time and reusing it for every
  instantiation) FIXED by sprint/structured-predicate-carry. Four rows because
  the fix has two writers and two directions: the DECLARED channel
  (`registerMember`), the INFERRED channel (`registerInferredFor`) which OD6(a)
  binds to the same answer, the general-sibling row that catches an
  OVER-NARROWING fix, and the reject tripwire that catches a fix which bought
  its acceptance by loosening admission. #1909 had NO must_fail pin, so these
  are the only guard it has ever had. Each measured at base `bffced42` and at
  the slice head; the per-row values are in the TABLE labels and each fixture`s
  own header.
  ⚠️ THE BASE ARM FOR THESE ROWS NEEDS BOTH BASE BINARIES. `medaka build` shells
  out to `<exeDir>/medaka_emitter` (`defaultMedakaEmitter`,
  compiler/driver/build_cmd.mdk), which a head `make medaka` OVERWRITES -- so a
  base `./medaka` alone reports the HEAD emitter`s answer in its build column
  and every one of these rows reads FIXED at base. Measured that way first, and
  it manufactured a false engines-disagree finding. Set MEDAKA_EMITTER to a
  saved base emitter, or give the base arm its own tree.
* s4-2-mixed-vector-no-impl-rejected / s4-2-inferred-ground-arg-predicate-
  checked / s4-2-dedup-collision-check-not-skipped / s3-ground-requires-chain-
  depth-34 -- FOUR S0s (#1578, #1905, #1330, #1576) FIXED by
  sprint/entailment-verdict, arriving here as REPLACEMENT GUARDS rather than as
  drains of an existing row. Recorded together because the reason they exist is
  one reason, and it is a process failure worth not repeating: that sprint
  deleted three self-draining `must_fail` pins per [G-PIN-DRAIN] and added
  NOTHING in their place, and the fourth (#1905) never had a pin at all. The
  whole sprint diff contained no fixture, no gate case and no doctest, so all
  12 CI checks were green at its head while the four S0s had zero regression
  coverage between them. A pin asserts a bug STILL REPRODUCES; a fix therefore
  DELETES it, and the guard leaves with it unless someone writes the positive
  row. These are those rows. Each was verified RED at the pre-sprint arm
  `264eb95d` (built by checking that commit's compiler/types/typecheck.mdk --
  the only compiler source file the sprint touched -- over this tree and cold-
  rebuilding) and GREEN at the sprint head; the per-row measurements are in the
  TABLE labels and in each fixture's own header.
  ⚠️ THREE OF THE FOUR PRE-SPRINT FAILURES WERE SILENT ON THE VERBS THAT SHIP:
  #1905 ran to completion in the built binary printing 222 with every verb at
  exit 0; #1330 and #1576 exited 0 from `check` AND `build` and SEGFAULTED at
  139 when the binary was executed. Only #1578 had a loud verb. This is why the
  §4.2 punch-list entry below insists a fixture family for that subsection has
  to assert REJECTION of specific shapes.
  ⚠️ NOT CARRIED, AND SAY SO RATHER THAN QUIETLY OMIT: the ACCEPT-direction
  controls that shipped inside the deleted pins (#1330's `Color` WITH a Display
  impl, #1576's 33-deep twin) are green at BOTH arms, so they cannot regress-
  test these fixes and are not regression rows. They would be over-rejection
  guards -- a different job, and a real gap. Their sources are in the git
  history of test/must_fail_fixtures/.
* 1386-alias-qualified-obligation-checked / 1276-alias-run-arm-obligation-
  checked / 1386-alias-reproB-standalone-collision-rejected -- #1386 and
  #1276 are FIXED (S-alias-supply, sprint/alias-provenance) and BOTH rows
  arrive here as DRAINS, re-pointed from `test/must_fail_fixtures/1386-…`
  and `…/1276-…` per [G-PIN-DRAIN]: a pin asserts a bug STILL REPRODUCES,
  so draining it removes the guard unless a positive row replaces it. Fix:
  `compiler/types/typecheck.mdk` now supplies an `A.<method>` ->
  declaring-`Ident` entry for every method an aliased module exports
  (`aliasQualifiedMethodEntries`/`aliasMethodKeysFor`/`aliasMethodKeyRows`,
  wired into `checkBodyImpl`'s Module arm), so `recordImplObligation` now
  sees an alias-qualified occurrence and checks it against the interface
  the alias actually names, instead of never recording an obligation (or,
  for #1276, falling through to a bare-name collision table that lost the
  alias's provenance). Both now REJECT with `No impl of IA for Blob; write
  an 'impl IA Blob'.` on check/run/build alike, where base silently
  accepted (#1386) or silently ran the wrong impl's body (#1276, printing
  `2` instead of rejecting). The third row is Repro B (#1386's own
  why-note (1) candidate, constructed fresh -- no committed must_fail
  fixture existed for it): an alias occurrence colliding with an UNRELATED
  standalone of the same bare spelling in a third module. It discriminates
  the SUPPLY fix actually landed (rejects here too) from a de-alias-rewrite
  fix (which would have left this cell silently running the standalone's
  body). See test/must_fail_fixtures/ commit history for the pins' own
  claim.txt (mechanism, MEASURED pre-fix behaviour, hand-derived answers).
* 1182-alias-dispatch-half-known-bad -- 🚨 A DIFFERENT, PRE-EXISTING gap
  (#1182/#1265 class, OPEN) -- NOT drained by S-alias-supply and NOT
  touched by its fix. That fix repairs the CHECKED half (does an impl
  obligation exist); this pins the DISPATCH half (which impl's body
  actually RUNS) still disagreeing with it for an alias-qualified
  occurrence. `Blob` implements both `IA` and `IB`; `A.mth Blob` and
  `B.mth Blob` name two DIFFERENT interfaces and must print 1 then 2.
  OBSERVED (still, on this binary): 1 then 1 -- `renameAliasedMethods`
  erases the alias to a bare `mth` before dispatch is decided, so both
  calls collapse onto the same (first-declared) impl. Confirmed identical
  at both the pre-sprint merge-base `9824e65b` and the sprint head
  (F-fix-alias-collision's report, Note N1) -- neither this sprint's fix
  nor the alias-collision fix caused it. KEPT AS A KNOWN-BAD LEDGER ROW,
  pinning the CURRENT (wrong) value rather than a REJECT: this program is
  accepted and runs to completion on every verb, so there is no exit code
  to assert against. A value change here is the signal to re-pin, not a
  regression in section 4.
* s3-fn-typed-impl-heads-discriminated / s3-effect-carrying-impl-head-routes --
  #1617 (S0) and #1618 (S1) are FIXED and BOTH rows arrive here as DRAINS, from
  `test/must_fail_fixtures/1617-…` and `…/1618-…`. Recorded together because they
  are two members of ONE arm set -- `headTyconTy`'s `_ => None` wildcard in
  compiler/types/typecheck.mdk -- and the set is NOT finished, which is the whole
  reason they were re-pointed here rather than deleted:
    - #1617 (TyFun heads): every stage AGREED on None, so two function-typed heads
      shared one `noneHeadTag` bucket and DECLARATION ORDER decided the value at
      exit 0 with `check --json` clean. Fix: give `TyFun` a head tag.
    - #1618 (TyEffect head): the two projections DISAGREED -- typecheck answered
      None, eval and `core_ir_lower` STRIPPED the effect to the inner head -- so
      `check` and `run` were correct and only `build` died, on a program with one
      impl and nothing to be ambiguous about. Fix: reconcile the projections.
    - #1180 (bare `TyVar`) is the arm where None is the DOCUMENTED INTENT; that
      program must be REJECTED and neither fix repairs it.
    - #1630 (FIXED; was OPEN when the two rows above landed) is the SAME arm set
      at a headed `TyConstrained` body. Fix: one more arm on the same node walk,
      `headTyNode (TyConstrained _ t) = headTyNode t`. It has THREE rows below,
      and they grade three different channels:
        `s3-constrained-impl-head-routes` -- ONE impl, `Eq a => Int`. Pre-fix
          `check=0 run=0 build=1`, byte-identically to #1618. Load-bearing cell:
          build.
        `s3-constrained-effect-impl-head-routes` -- `Eq a => <Stdout> Int`. Exists
          because a fix special-casing the reported shape `TyConstrained cs
          (TyCon …)` would green the first row and RED this one.
        `s3-constrained-headed-impl-vs-plain-sibling` -- TWO impls. The SILENT-
          WRONGNESS channel neither of the others can see, and the reason
          `check=0 run=0 build=1` must NOT be read as a statement about the class:
          that cell triple is a property of ONE IMPL. Measured on a base arm built
          from the fix branch with the peel deleted, `impl Sz (Eq a => Box Int)`
          beside `impl Sz (Box Bool)` printed 26 in one declaration order and 28
          in the reverse, at exit 0 with `check` clean. Spec answer 27. So the
          class reaches S0 and #1630's S1 grades its REPORTED shape, not the
          class. Section 4 permutes this row; the other two have one impl each.
      🚨 THIS ENTRY IS ALSO THE ARM SET'S OWN WARNING AGAINST BOUNDING A CLASS
      FROM ONE EXAMPLE. PR #1629's commit `e051788b` -- in its commit body and in
      the `eval.headTycon` comment it landed -- declared `TyConstrained` "measured
      benign … peeling it yields a headless body", and this ledger recorded the
      class as "NOT finished" on that basis. (#1617/#1618 are ISSUES and have no
      commit bodies; cite the PR's commits.) Both true of `Eq a => a` and false of
      `Eq a => Int`. The wrapper never decided headedness; the body did. So read
      "the set is not finished" as still live: it is what has been enumerated, and
      the enumeration has now been wrong once in each direction.
  ⚠️ THE TWO ROWS DISCRIMINATE ON DIFFERENT CELLS, and reading either as a plain
  value pin makes it vacuous. #1617's value cell passes BY CONSTRUCTION on the one
  declaration order it was captured at -- its real assertion is Section 4, which
  derives this file automatically because it is a FLAT `.mdk` with two `impl Sz`
  blocks. #1618's `check` and `run` cells were ALREADY CORRECT while the bug was
  live -- its real assertion is the `build` cell that `ALL_EXACT` forces to agree.
* s6-1-4-supers-per-construction-goal -- #1127, DRAINED 2026-08-23 by
  S-predicate-representation (#1177's fix). What follows is the HISTORY the row
  pinned; the row itself is now `ALL_EXACT 77\n77`, per its fixture header's own
  drain instruction, and its Section 4 KNOWN-BAD permutation entry is GONE (the
  two build values converged, which is what that entry existed to detect).
  WAS: SILENT WRONGNESS ON THE BUILD PATH. A §3 `super` projection out of a general `C`-instance
  constructed at a GROUND goal reaches the GENERAL `D`-dict, not the
  most-specific one: `check` exits 0, `run` prints the correct 77/77, and the
  SHIPPED NATIVE BINARY prints 20/77. §6 C2 names this exact break ("a
  super-projection that reaches a general `D`-dict while an independent
  top-level goal `D τ̄` resolves to a specific one"), and §6.1.4 names the
  mechanism ("pre-resolving a polymorphic instance's supers once, against its
  general head, at declaration"). Both arms are in ONE program, so they
  disagree inside one binary. Control: s6-1-4-direct-constraint-control
  declares `D a` DIRECTLY (so `assum` reaches the dict instead of `super`) and
  native is correct -- localising the defect to the superclass arm. DISTINCT
  from #412 (CLOSED, S0), which was the impl-`requires` arm of the same §6.1.4
  family; #412's own repro was re-run on this binary and is correct.
  ⚠️ This is the row the whole gate justifies: `run` and `build` share the
  entire front end, so their DISAGREEMENT is a real observation about codegen,
  and no existing gate drives this shape.
  🔗 Section 4 (declaration-order permutation) finds a SECOND symptom of this
  same mechanism: reversing the fixture's three `D` impl blocks flips the
  BUILD arm from the wrong 20 to the right 77 while `run` stays 77/77 either
  way -- i.e. #1127 is ALSO order-sensitive on the path Section 4 grades.
  Pinned there as a KNOWN-BAD permutation row rather than silently excluded.
* s3-min-fully-general-sibling -- #1128 (S0 `verified`) is FIXED and this row
  HAS DRAINED (F-3b, 2026-08-01). Kept in the ledger as the worked example of a
  self-drain, because the shape of the fix is the useful part:
    WAS: a fully general `impl Tag a` beside `impl Tag (Box Int)` made EVERY
    `Box`-headed goal call the `Box Int` impl -- `tag (Box "s")` printed 99
    where 10 is correct, on check (exit 0, no diagnostic), on run, and on the
    shipped binary.
    MECHANISM: a bare-type-variable head has no head tycon, so `keyEntryOf`
    emitted NO `KeyEntry` for it. The general impl was never COLLECTED into the
    registry the goal searches -- it could not be out-ranked, only missed.
    FIX: register it under `noneHeadTag`, union that bucket into every goal-head
    lookup (merged on declaration index, not concatenated), and let `keyForSite`
    return the winner's own head tag instead of `None`, which was throwing the
    correctly-selected candidate away one line later.
  ⚠️ The first two thirds of that fix, WITHOUT the third, are INERT -- two
  independent agents built them and this row never moved. If you are re-deriving
  this area, that is the trap: a headless winner is selectable long before it is
  routable.
  🔗 #1113 (ARCH B-2) still owns the deeper form -- §11's arg-tag row names the
  same bare-head-tycon granularity one layer down, in eval's
  `runtimeTypeTag`/`filterByTag` RUNTIME fallback, where this fixture's site is a
  DIRECT call decided at elaboration. F-3b did NOT retire the head-tag hedge in
  `keyForSite`; it only stopped it lying about the selected instance.
* s3-nested-obligation-two-levels -- #323's eval divergence is drained by
  canonical implementation-route dictionary counts. Both engines must print
  7 then 119; the no-overlap control prints 31. Removing the canonical count
  alias restores eval's panic while the no-overlap control remains correct.
* s6-1c-per-goal-unique-min-accepted -- #614 (S2) / #311 (S3) are FIXED and this
  row HAS DRAINED (F-3d, 2026-08-01). Kept in the ledger as the worked example of
  an ACCEPTANCE WIDENING, because that direction has its own trap:
    WAS: the declaration-time coherence sweep enforced §6.1 condition (a) (global
    pairwise comparability) where the spec commits to (c) (per-goal unique
    minimum), so the §6.1 separating case -- `C (Pair Int a)`, `C (Pair a Int)`,
    `C (Pair Int Int)` -- was rejected at the SECOND `impl`. Sound, but an
    over-rejection: the third impl is the unique ⊑-minimum at the goal.
    FIX: classify the pairwise sweep instead of deleting it. A ⊑-INCOMPARABLE pair
    becomes a `W-INCOMPARABLE-IMPLS` warning (the "MAY additionally warn at
    declaration time … but acceptance is per-goal" §6.1 licenses); acceptance moves
    to the goal-site min⊑ reject F-3c installed.
  ⚠️ THE TRAP, and it is the mirror image of #1128's: **every existing golden
  covers the old, NARROWER behaviour, so all of them pass by construction on an
  over-widening.** Section 1 cannot see a program that newly compiles unless
  someone writes the row. The two checks that CAN: the ACCEPT rows' `!`-negated
  codes (a positive-only pin cannot tell "(a) was demoted" from "(a) was deleted"),
  and Section 4, which needs no ground truth at all.
  ⚠️ WHAT DID **NOT** WIDEN: two MUTUALLY-⊑ (α-equal) heads still hard-reject.
  They SATISFY (a) -- §6.1.2's ⚠️ records that the ladder breaks exactly there,
  **(a) ⇏ (c)** -- so they were never (a)'s to demote, and `entryCovers` makes
  equal heads cover each other, so the goal-site reject cannot see them either.
  s6-c1-duplicate-heads-rejected is that control.
  s6-1c-incomparable-no-minimum-control remains the discriminating control, with
  its argument INVERTED: it used to show that adding the ⊑-minimum changes nothing;
  it now shows that adding it flips the sibling to ACCEPT.
* s6-2-t4-open-goal-deferred -- #1183 (OPEN, S1 `verified`). The residue F-3d made
  user-reachable: at a NON-CLOSED goal the min⊑ arm still COMMITS to the head of
  the candidate list, so declaration order decides the value at exit 0 (1 vs 2)
  under a warning rather than in silence. §6.2 T4 says defer to quiescence; there
  is no quiescence pass (§11's T3/T4 row). Pinned as a KNOWN-BAD row in BOTH
  Section 4 ledgers (run and build) -- and the run-arm ledger was ADDED for it,
  since `RUN-DIFF` previously had no known-bad branch at all.
* s4-gen-rec-inferred-asymmetric -- #1133 DRAINED. An INFERRED mutually-recursive
  group in which only ONE body dispatches used to typecheck with both correct
  `Sz a =>` schemes, then fail on both engines with an unbound `$dict_evenSz_0`.
  The operator route erased its enclosing evidence owner before recursively
  routing the selected impl's requirements. Preserving that owner through
  `entailInst` / `stampOpRouteVal` makes the group share its one dict prefix as §4
  requires; check, eval and native now agree on `True` / `True`. The ascribed and
  symmetric controls remain, and the asymmetric row is re-pinned to ALL_EXACT.
* s5-phantom-determined-use-rejected -- #1134 (OPEN, S3 `verified`).
  OVER-REJECTION. Inside
  `useBoth : Mk a => a -> Int` the `Mk a` dict is in scope over a RIGID `a`, so
  §3 `assum` discharges the goal and §5 `(method)` projects: the spec ACCEPTS
  and prints 7. The checker rejects at the interface/impl DECLARATION and never
  looks at the use site. Paired with s5-phantom-ambiguous-use-rejected (which
  BOTH spec and impl reject) this shows the implementation rejects a strict
  SUPERSET of what the spec does -- the pair is what makes the finding land.
  ⚠️ PINNED TO #1134 (BEHAVIOUR), NOT #1107 (d) (SPEC), and that distinction is
  worth keeping because an earlier revision got it wrong: #1107 is "ARCH S-2:
  write the owed spec paragraphs" and its paragraph (d) is this finding
  verbatim -- but it is SPEC-ONLY WITH NO BEHAVIOUR CHANGE, so a REJECT row
  pinned to it would stay green through its entire lifetime and then go stale
  silently. A self-draining pin that cannot drain is worse than no pin.
  ⚠️ #1107 (d)'s TWO RESOLUTIONS MOVE IN OPPOSITE DIRECTIONS: narrowing the
  checker closes #1134 as a FIX and reds this row (automatic, re-pin to ACCEPT
  7); forbidding phantom methods in §5 closes #1134 as WORKING-AS-INTENDED,
  reds nothing, and needs this row plus its sibling relabelled BY HAND. The
  second case cannot be automated and is recorded on #1134 itself.

## NOT YET COVERED -- an honest punch-list, not a silent gap
The corpus covers §1, §2 (method-level `Q_m`), §3 (selection/`assum`/`super`/W1/
W3-type-axis incl. the DEFAULT-body half), §4 (`gen`/`gen-rec`/`gen-sig`), §5
(result + phantom + arg-tag), §6/§6.1 (C1/C2/choice-points 2,3,4), §8 (I1 incl.
dict-param ORDER, I2, I3), §9 (signature authority, vector-valued entailment)
and, as of Section 4, §3's DECLARATION-ORDER-FREEDOM clause for every
single-file fixture with >=2 impls of one interface (#1154/#1155). It does
NOT yet cover:
  * 🚨 Section 4 permutes `impl` BLOCKS. It does NOT permute the PREDICATE ORDER
    IN A SIGNATURE, and nothing else in the tree does either -- so that axis of
    DICT §3's order-freedom clause is untested by construction, and no fixture
    added to this corpus can reach it. That is not hypothetical: #1177 (S0,
    verified) is exactly this shape -- `(Dbg a, Ix a Char) => ...` prints 116
    where `(Ix a Char, Dbg a) => ...` prints 227, same program, both engines,
    check clean -- and it survived a PR (#1176) whose entire subject was
    order-freedom, because this section could not see it. Pinned meanwhile at
    test/must_fail_fixtures/1177-sig-predicate-order-decides/. Closing #1177
    should either add a second permutation strategy here (reverse the predicates
    of a `=>` context the same way the block permuter reverses impls) or record
    why not. ⚠️ A permutation differential is only order-free along the axis it
    actually permutes -- do not read section 4's green as "order does not decide".
  * 🚨 §4.2 (OBLIGATION DEFERRAL, OD1-OD6) IS NO LONGER ENTIRELY UNCOVERED, BUT
    IT IS STILL MOSTLY UNCOVERED. Six normative clauses landed in this spec
    (#1114) and for a long time this corpus did not move at all. That gap is
    STRUCTURAL, not an oversight of one PR: the coverage self-audit fails for an
    unwired FIXTURE, never for an unfixtured CLAUSE, so a whole subsection can be
    added to DICT-SEMANTICS.md and nothing here goes red.
    WHAT EXISTS NOW -- three `s4-2-*` rows, added 2026-08-25 by
    FIX-3-regression-fixtures (sprint/entailment-verdict) as the replacement
    guards for three S0s whose `must_fail` pins that sprint DELETED per
    [G-PIN-DRAIN] without replacing them:
      - OD5/OD6 dedup: s4-2-dedup-collision-check-not-skipped.mdk (#1330, now
        FIXED). Deduplication may suppress the REPORT of a duplicate obligation,
        never the CHECK. Was: five prelude-only lines, `check` 0, `build` 0,
        binary SEGFAULTS at 139.
      - deferral of a MIXED argument vector:
        s4-2-mixed-vector-no-impl-rejected.mdk (#1578, now FIXED).
      - deferral of an inferred binding's GROUND predicate argument:
        s4-2-inferred-ground-arg-predicate-checked.mdk (#1905, now FIXED).
    WHAT IS STILL UNCOVERED: OD1-OD4 have no fixture of their own, and the three
    rows above grade the REJECT direction only -- each one's ACCEPT-direction
    control (the same shape WITH a satisfying impl) is green on both arms and so
    was deliberately not carried, which leaves an over-rejecting tightening of
    this channel ungraded here. OD6's other residual, #1326 and its `run`-only
    face, is untouched; see the §11 OD6 row.
    OD1's own history is the argument for covering this section rather than
    trusting it: its first implementation passed every gate in the tree while
    dropping a decidable predicate, because a DROPPED obligation produces SILENCE
    and silence is what a golden already records for an accepted program. A
    §4.2 fixture family therefore has to assert REJECTION of specific shapes; a
    corpus of accepted programs cannot see this class at all. That is exactly the
    form the three rows above take.
  * Section 4 tests exactly ONE reordering per qualifying fixture -- a full
    reversal of the qualifying blocks -- not all N! declaration orders. For
    N=2 that IS the only nontrivial permutation; for N=3 (the corpus's max
    today) it swaps the first and last block and leaves the middle fixed, so
    an order-sensitivity that depended on adjacent-pair position rather than
    first/last would not be caught. Adding a genuine 3-cycle would need a
    second permutation strategy, not just a bigger corpus.
  * Section 4 is scoped to files directly in `test/dict_fixtures/*.mdk` --
    directory-based multi-file fixtures (`s8-i1-samename-independent-dict-arity/`
    and siblings) are excluded; none of them currently has >=2 impls of one
    interface in a single file, so nothing is silently skipped today, but a
    future multi-file fixture with that shape would need its own handling
    (which file's impl blocks to reorder is not derivable the same way).
    Directories don't match the `*.mdk` glob at all, so they are excluded by
    construction rather than by an exclusion list.
  * §2 -- the dictionary RECORD SHAPE itself (a `supers` field vs a flat
    impl-key). Only its observable consequences are pinned; asserting the
    representation needs the Core-IR dump probe. ⚠️ This exclusion is about the
    `{methods, supers}` LAYOUT only -- §2's method-level-constraint exception is
    behaviourally observable and IS covered, by
    s2-method-level-constraint-abstract.
  * §3 W2 -- instance-resolution termination (the Paterson/coverage-style
    condition). No fixture drives a diverging instance context. ⚠️ Per §11's own
    W2 row there is no static check to gate anyway -- what exists is a dynamic
    depth-32 cutoff -- so a fixture here would pin the cutoff, not the clause.
  * §3 W3 EFFECT axis, and the whole graded-interface (`Deferred*`) paragraph
    including its two verified S0s (#1094, #1095). That is
    EFFECTS-SEMANTICS' §6 to gate; only the TYPE axis is pinned here -- but note
    BOTH of its sites now are (impl body AND interface default body).
  * §6.1 choice-point 1 -- specificity compares heads only, not contexts. No
    fixture declares two α-equal heads with different contexts.
  * §6.1 condition (b) -- per-goal TOTAL order, the middle of the three. Only
    (a)-vs-(c) is separated.
  * §6.2 T3/T4's NON-CLOSED half is COVERED as of the s6-2-t3/s6-2-t4 pair, and
    as of F-3d that pair decides a VERDICT: the closed half rejects, the open half
    ACCEPTS AND RUNS. F-3c's goal-site T-AMBIGUOUS-INSTANCE is gated on the goal
    being CLOSED, because T4 defers a goal carrying an unbound metavariable rather
    than deciding it; the negative code assertion on the open half is retained
    because verdict alone cannot attribute the sibling's reject to the min⊑ arm.
    ⚠️ AN EARLIER REVISION OF THIS BULLET SAID THE GATE WAS "UNTESTABLE" on the
    grounds that a ⊑-incomparable user pair is rejected at the declaration. That
    was true and it was not a reason: errors ACCUMULATE, a declaration-time reject
    is not an early exit, and both impls still reach the selector. The refutation
    was already in this corpus itself (conflicting_impl_overlap carries both
    codes). ⚠️ A SECOND PREDICTION IN THIS BULLET WAS ALSO WRONG: F-3d does NOT
    "remove the coherence reject" -- it DEMOTES condition (a) to a warning and
    leaves the α-equal class a hard error, per the 2026-08-01 owner decision.
    What is NOT covered is the residue that widening exposes: at the open goal the
    arm still COMMITS by declaration order (#1183), pinned as a KNOWN-BAD row in
    Section 4 rather than asserted correct.
  * 🚨 Section 4 permutes `impl` BLOCKS WITHIN ONE FILE, so it is STRUCTURALLY
    BLIND to the user-vs-PRELUDE overlap class -- exactly the class F-3c exists
    to catch. Each `s6-c1-rigid-goal-*` fixture has ONE user impl, because its
    competitor is `stdlib/core.mdk`'s; there is no second block to permute and
    the prelude's declaration index cannot be moved from a fixture at all. So
    section 4 reporting order-freedom says nothing about whether a PRELUDE impl's
    position decides the answer -- which is the shape #1162 and this stage's own
    flagship fixture are about. Covered here only by the verdict rows.
  * §7 -- the WASM engine. Every row drives check/run/build; wasm is a third
    refinement the single-evaluator law also binds.
  * §4 `gen` for a LOCAL (`let`/`where`) constrained binding, as opposed to a
    top-level one. See #1052 (the local-dict pin is itself unsound).
  * The typed dict-passed Core-IR route kinds (`RKey`/`RLocal`, `CDict`), per
    the note above.
  * `run`'s STDERR on any row. The harness grades `check`'s diagnostic code (from
    `check --json`) and every engine's stdout and exit code, but has no way to
    assert a RUNTIME panic's signature -- so a row whose pinned failure is a
    `run`-time E-PANIC pins the exit code and the stdout reached, never the
    reason. Filed as #1130; s3-nested-obligation-two-levels is the row that
    currently pays for it and says so in its own header.
Adding any of these is mechanical: drop a fixture in test/dict_fixtures/ and
wire a row. The coverage self-audit in
`test/diff_compiler_dict_semantics_test.mdk` FAILS until you do, by design.
