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
# s6-1-4-supers-per-construction-goal still is one, on the build arm alone.
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
# * s6-1-4-supers-per-construction-goal -- #1127 (OPEN, S0 `verified`). SILENT
#   WRONGNESS ON THE BUILD PATH. A §3 `super` projection out of a general `C`-instance
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
#   * 🚨 §4.2 (OBLIGATION DEFERRAL, OD1-OD6) IS ENTIRELY UNCOVERED -- six normative
#     clauses landed in this spec (#1114) and this gate did not move. That gap is
#     STRUCTURAL, not an oversight of one PR: this file's self-audit fails for an
#     unwired FIXTURE, never for an unfixtured CLAUSE, so a whole subsection can be
#     added to DICT-SEMANTICS.md and nothing here goes red. Recorded as the honest
#     minimum until fixtures exist.
#     Two of the six are already known NOT to hold, so a fixture would be red today
#     rather than green -- which is the point of writing them down:
#       - OD5 is DIVERGENT on the constrained-binding channel: #1330 (OPEN, S0,
#         verified) -- five prelude-only lines, `check` 0, `build` 0, binary
#         SEGFAULTS, because a dedup key collision skips the CHECK and not merely
#         the report.
#       - OD6 has three measured residuals (#1330, #1326 and its `run`-only face);
#         see the §11 OD6 row.
#     OD1's own history is the argument for covering this section rather than
#     trusting it: its first implementation passed every gate in the tree while
#     dropping a decidable predicate, because a DROPPED obligation produces SILENCE
#     and silence is what a golden already records for an accepted program. A
#     §4.2 fixture family therefore has to assert REJECTION of specific shapes; a
#     corpus of accepted programs cannot see this class at all.
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
s3-nary-requires-multi-entry.mdk|§1/§3 the same judgement at a TWO-ENTRY `requires Dbg2 a, Ix a Char`: the second obligation grounds to `Ix Int Char` and its matching set is again the singleton, so 222+5=227 (pre-fix this printed 116). ⚠️ Its SIBLING ORDERING `requires Ix a Char, Dbg2 a` STILL prints 116 on this binary and is pinned as a must-fail at test/must_fail_fixtures/1154-multi-entry-requires-decl-order-decides/ -- do NOT reorder this clause to match the body|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|227|
s3-nested-obligation-most-specific.mdk|§2 uniformity + §3 `inst`/`assum`: the nested `requires` obligation of the general instance resolves MOST-SPECIFICALLY at the construction goal (the #203 shape from §3`s own worked example)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99\n109|
s3-nested-obligation-two-levels.mdk|§2/§7 LEDGER #323 (OPEN): at nesting depth >=2 under overlap `run` E-PANICs `unknown op ‘+’` while check and the NATIVE binary are correct (7 then 119). build`s value is pinned because it is RIGHT; run`s pinned stdout is the `7` SENTINEL it emits before dying, which pins that it reached the failing line rather than falling over earlier. ⚠️ REACH POINT, NOT REASON -- run`s stderr is ungradeable (#1130), so a different fault on the same line would still pass. The row drains when run stops panicking|ACCEPT|REJECT|ACCEPT|BUILD_EXACT|7%%7\n119|
s3-nested-no-overlap-control.mdk|CONTROL for #323: identical depth, overlapping impl REMOVED -- eval handles depth-3 recursive context discharge fine (31), so #323`s trigger is the OVERLAP, not the depth|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|31|
s3-min-fully-general-sibling.mdk|§3 `inst` = min⊑(match) WITH A FULLY-GENERAL SIBLING -- the #1128 DRAIN (F-3b). `impl Tag a` beside `impl Tag (Box Int)`: goal `Tag (Box Int)` matches BOTH and min⊑ takes the concrete one (99); goals `Tag (Box String)` / `Tag (Box Bool)` match the general one ALONE, because no substitution makes `Box Int` into `Box String` (10, 10). This row pinned the WRONG 99/99/99 until 2026-08-01; the value below is the SPEC answer the fixture`s own header hand-derived before the fix existed, not a recapture of what the engine started doing|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99\n10\n10|
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
s4-gen-rec-shared-dict-params.mdk|§4 `gen-rec` (#44 vein): a mutually-recursive group shares ONE `λ d̄.` prefix; recursive occurrences reuse the group`s dict params instead of re-entering entailment|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|True\nTrue|
s4-gen-rec-inferred-context.mdk|§4 `gen-rec` with the context INFERRED rather than ascribed -- the `gen` sourcing, a different code path from its `gen-sig` twin per #610`s mechanism note. ⚠️ BOTH bodies dispatch, so this row does NOT discriminate group sourcing from per-binding sourcing (an earlier revision wrongly claimed it did); it is a regression guard on the schemes and values. The discriminating form is the asymmetric row below|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|True\nTrue|
s4-gen-rec-inferred-asymmetric.mdk|§4 `gen-rec` DISCRIMINATOR -- LEDGER #1133 (OPEN, S1 LOUD BREAKAGE): an INFERRED mutually-recursive group in which only ONE body dispatches. check ACCEPTS and reports BOTH schemes as `Sz a =>` (the group-wide `P` attribution is right), then NEITHER engine will execute it -- run E-PANICs `unbound identifier: $dict_evenSz_0`, build dies `unbound dict witness ... in emit env (dict not threaded to this site)`. §4`s named failure mode, caught before it can become a wrong value. Controls: the ascribed twin and the symmetric row both run fine; mirroring which body dispatches fails symmetrically|ACCEPT|REJECT|REJECT|NONE||
s5-return-position-dispatch.mdk|§5 RESULT position: `mk : Int -> a` has no argument whose runtime tag reveals the instance, so dispatch can only come from the statically-determined dictionary. Both calls pass an identical Int literal|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|1\n2|
s5-phantom-ambiguous-use-rejected.mdk|§5 PHANTOM position, AMBIGUOUS use: §4 `var` cannot discharge `Mk ?a` with nothing fixing `?a`, so the SPEC rejects it too (§5 says only HOW a phantom dispatches, never that this program resolves). CONFORMANT ON THE VERDICT, with the caveat that spec and impl reject at different SITES -- spec the use, impl the declaration -- which the spec leaves unspecified|REJECT|REJECT|REJECT|NONE||T-PHANTOM-METHOD
s5-phantom-determined-use-rejected.mdk|§5 PHANTOM position, DETERMINED use -- LEDGER #1134 (OPEN, S3 OVER-REJECTION): inside `useBoth : Mk a => a -> Int` the dict is in scope over a RIGID `a`, so §3 `assum` discharges it and §5 `(method)` projects -- the spec ACCEPTS and prints 7. The checker rejects at the DECLARATION regardless. Paired with the ambiguous row this proves the impl rejects a strict SUPERSET of what the spec does. ⚠️ Drains on #1134 (BEHAVIOUR), never on #1107 (d), which is spec-only and changes no behaviour|REJECT|REJECT|REJECT|NONE||T-PHANTOM-METHOD
s5-argtag-unsound-under-overlap.mdk|§5 arg-tag dispatch is an OPTIMIZATION, not a semantics: two calls with the same runtime `List` head tag must answer 99 and 10, which no arg-tag selector can do. ALSO the one-token control for the s3-min-fully-general-sibling S0|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99\n10|
s6-c1-duplicate-heads-rejected.mdk|§6 C1 + §3: two α-equal heads are mutually ⊑, so there is no UNIQUE ⊑-minimum -- ambiguous overlap, rejected. Duplicate heads never tie-break. ⚠️ THE ROW F-3d DELIBERATELY DID NOT WIDEN: α-equal heads SATISFY condition (a) (they are ⊑-comparable), so this was never (a)`s to demote -- it is a C1 violation, and F-3d demotes (a) alone. It also has no second line of defence: `entryCovers` makes equal heads cover each other, so the goal-site min⊑ reject never sees this shape|REJECT|REJECT|REJECT|NONE||T-CONFLICTING-IMPL
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
i7-flatten-arm-fresh-universe.mdk|§8 I7 + §7.1 -- THE FLATTEN-ARM / MODULE-ARM PARTITION TRIPWIRE (#1446). The three `obUniv*` rows are per-RUN accumulators that survive `resetState`, and the five prelude-FLATTENED internal passes have no prelude boundary, so an identity-keyed row written by a stamped pass and read by a flattened one would MISS. It does not reproduce, for a STRUCTURAL reason: there are exactly TWO `ImplUniverse` sources and they are ARM-GATED (the `Flat` arm builds a fresh `buildImplUniverse prog`; only `Module` reads the accumulator; all five flattened sites route to `Flat`). ⚠️ THAT SEPARATION IS NOW LOAD-BEARING AND E-1 (#1115) IS THE UNIT THAT BREAKS IT -- this row is what must go RED instead of silently missing. No imports, so `check` takes the Flat arm while `run`/`build` additionally drive the flattened discovery passes; every dispatch is a PRELUDE impl reached through a conditional instance, and all four I7 classes (Num/Eq/Ord/Semigroup) are exercised on one file. ⚠️ HONEST LIMIT: an end-to-end consequence pin, not a direct assertion about which universe object a pass read -- it cannot tell `the partition held` from `it broke and both universes agreed`. Treat RED as `read the arm partition again`, not as a diagnosis|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|6\n[Some 1, None]\n[1, 2, 3]\nTrue\nTrue|
s6-1-4-supers-per-construction-goal.mdk|§6.1 choice-point 4 / §6 C2 / §3 `super` -- LEDGER #1127 (OPEN, S0 SILENT WRONGNESS ON THE BUILD PATH): a SUPERCLASS projection out of a general `C`-instance built at a ground goal reaches the GENERAL `D` dict. check exit 0; run prints the CORRECT 77/77; the SHIPPED BINARY prints 20/77. §6.1.4`s "tempting-but-wrong" pre-bake, live. Distinct from #412 (CLOSED, impl-`requires` arm -- its repro is correct on this binary)|ACCEPT|ACCEPT|ACCEPT|SPLIT_EXACT|77\n77%%20\n77|
s6-1-4-direct-constraint-control.mdk|CONTROL for #1127: the SAME instance set, goal and call shape with `D a` declared DIRECTLY, so `dm` is reached by §3 `assum` instead of `super`. Native is CORRECT here (77/77), which localises the defect to the superclass-projection arm rather than to min⊑ selection|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|77\n77|
s8-i1-samename-independent-dict-arity/main.mdk|§8 I1: dict arity is keyed by BINDING IDENTITY, not bare name -- two modules` same-named `widget` abstract 1 and 0 dicts respectively (arity asserted structurally in section 3)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|101\n201|
s8-i2-global-instance-env/main.mdk|§8 I2 / §6 C4: `IE` is assembled across the WHOLE import graph -- the sole `impl Sz Coin` is reached only transitively, and `main` never imports its module at all|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|42|
s8-i3-evidence-travels/main.mdk|§8 I3: a constrained binding does not re-resolve its own predicates -- the only impl is declared DOWNSTREAM of `twice`, so the dict provably came from the call site|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|42|
s3-nary-sig-constraint-goal-vector.mdk|§1/§3 `match(IE,C τ̄)` on the `=>`-CONSTRAINED-SIGNATURE leg: `useIx : Ix a Char => a -> Int` at `a := Int` gives the goal `Ix Int Char`, whose matching set is the SINGLETON {`Ix Int Char`} -- `Ix Int Bool` never reaches the selector. 222 (#1161 regression pin -- the signature`s predicate was SHATTERED into one dict slot per BARE-TYVAR argument, so `Char` was discarded at registration, the arg-0-only goal made both impls match, they are incomparable, and DECLARATION ORDER printed 111 at exit 0 on both engines). Section 4 permutes it. ⚠️ Pins the ROUTING half only: #1161 symptom 2 (an unsatisfiable `Ix a Bool =>` accepted at exit 0, context dropped from the scheme) is a different channel, still OPEN, pinned at test/must_fail_fixtures/1161-sig-constraint-unsatisfiable-accepted|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|222|
s3-nary-sig-constraint-structured-arg.mdk|§3 the same judgement with a STRUCTURED predicate argument, `Ix a (List b) =>`: the goal `Ix Int (List Char)` again matches a singleton, 222. THE ONLY DEFENCE against the substitution half of the #1161 fix -- the stored vector lives in the SIGNATURE`s instantiation vars, so a top-level-only substitution leaves the interior `b` of `List b` a stale signature var, `matchTyMonos` fails against BOTH ground heads, and an EMPTY candidate set degrades to first-declared (measured during scoping: 222 -> 111). ⚠️ F-3c (#1155) structurally CANNOT cover this class: `pickMostSpecificEntry []` returns None rather than taking the ambiguity arm, so an empty candidate set stays silently first-match even after that arm goes loud|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|222|
s9-vector-valued-entailment-rejected.mdk|§9 signature authority: the `Q_sig ⊩ P`ᵢ` side condition is VECTOR-VALUED -- `{Ix a b, Ix c d}` does not entail a joint `Ix a d` even though every ARGUMENT appears. The row that separates a real n-ary obligation from #607`s two single-param facts|REJECT|REJECT|REJECT|NONE||T-MISSING-CONSTRAINT'

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
s4-gen-rec-inferred-context.mdk|§4 `gen-rec` P` is the GROUP`s, so BOTH bindings generalize over `Sz a` -- not only the one whose body mentions `sz` first|evenSz : Sz a => a -> Int -> Bool
s4-gen-rec-inferred-context.mdk|§4 `gen-rec` the other half of the group|oddSz : Sz a => a -> Int -> Bool'

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
s8-i1-samename-independent-dict-arity/main.mdk|§8 I1 the CONSTRAINED same-named binding abstracts ONE dict: arity 2|HAS|^define i64 @mdk_lefty__widget\(i64 %arg0, i64 %arg1\)
s8-i1-samename-independent-dict-arity/main.mdk|§8 I1 the UNCONSTRAINED same-named binding abstracts NONE: arity 1. A bare-name arity table would force a phantom dict param here and the call site would over-apply|HAS|^define i64 @mdk_righty__widget\(i64 %arg0\)
s3-min-subsumes.mdk|§3 the ground goal resolves STATICALLY to the specific impl -- a direct call, no runtime arm-matching|HAS|call i64 @mdk_impl_Int_dflt\(
s3-min-fully-general-sibling.mdk|#1128 MECHANISM PIN 1/3: the general impl IS emitted -- so it was not DCE`d away, and (pre-F-3b) its absence from every call site was a selection decision rather than a missing definition. Retained post-drain: it is what makes PIN 2/3 an assertion about DISPATCH rather than about existence|HAS|define i64 @mdk_impl___none___tag\(
s3-min-fully-general-sibling.mdk|#1128 MECHANISM PIN 2/3, RE-PINNED BY THE F-3b DRAIN: the general impl is now called at EXACTLY THE TWO sites whose goal matches it alone. This row read `LACKS` (found 0) while #1128 was open. COUNT, not HAS, is load-bearing here: `HAS` would be satisfied by one call, so a regression collapsing all three sites onto the general impl -- the mirror image of the original bug -- would keep it green|COUNT=2|call i64 @mdk_impl___none___tag\(
s3-min-fully-general-sibling.mdk|#1128 MECHANISM PIN 3/3, RE-PINNED: exactly ONE site calls the `Box Int` impl -- the only goal it matches. Paired with PIN 2/3 this pins the whole 3-site partition (2 general + 1 concrete = 3 calls), which no behavioural assertion can see and which `HAS` left half-unstated (adversarial review F1: a change routing all three through some THIRD symbol kept the old row green under a false label)|COUNT=1|call i64 @mdk_impl_Box_tag\(
s8-i1-dict-param-order.mdk|§8 I1 ORDER, structural half: a TWO-predicate binding must abstract FOUR parameters (2 dicts + 2 values). The value 503 alone cannot see a count change that unification happens to absorb|HAS|^define i64 @mdk_s8_i1_dict_param_order__pair2\(i64 %arg0, i64 %arg1, i64 %arg2, i64 %arg3\)
s3-nary-sig-constraint-goal-vector.mdk|#1161 ARITY-NEUTRALITY PIN. Recording the predicate`s ARGUMENT VECTOR must not move emitted dict arity -- that is the property the whole F-3a-ii design rests on (the vector table is SLOT-PARALLEL to funConstraintsRef, never inside it, so dictArityOf/dictPass/scopeArities are untouched). `Ix a Char => a -> Int` shatters into ONE bare-tyvar slot, so `useIx` abstracts 1 dict + 1 value = arity 2. NO behavioural assertion can see this: promoting the predicate to a joint dict slot would print the same 222|HAS|^define i64 @mdk_s3_nary_sig_constraint_goal_vector__useIx\(i64 %arg0, i64 %arg1\)
s3-nary-sig-constraint-structured-arg.mdk|#1161 ARITY-NEUTRALITY PIN, structured half: `Ix a (List b) =>` still shatters into exactly ONE slot -- `b` occurs only INSIDE `List b`, so it is not a bare-tyvar argument and gets no slot of its own -- giving 1 dict + 2 values = arity 3. Guards the sibling mistake to the one above: giving every tyvar MENTIONED in a predicate a slot, rather than every bare-tyvar ARGUMENT|HAS|^define i64 @mdk_s3_nary_sig_constraint_structured_arg__useIx\(i64 %arg0, i64 %arg1, i64 %arg2\)'

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
KNOWNBAD_PERM='s6-1-4-supers-per-construction-goal.mdk|D|20\n77|77\n77|#1127
s6-2-t4-open-goal-deferred.mdk|Sh|1|2|#1183'

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
s4-gen-sig-residual-uncovered-rejected.mdk|issue 1549 gen-sig: the uncovered-residual reject lands at the DEFINITION (the body expression that needs it), which is the half a call-site span cannot distinguish|36:15'

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
