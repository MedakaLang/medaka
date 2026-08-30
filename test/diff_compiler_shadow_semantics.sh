#!/bin/sh
# SHADOW-SEMANTICS decision-matrix gate (docs/spec/SHADOW-SEMANTICS.md).
#
# test/shadow_fixtures/ is the enforcement corpus for that spec -- one fixture
# per matrix cell -- and until this gate existed NOTHING ran it (audit finding,
# 2026-07-13: 5 orphaned fixture directories tree-wide; this was the worst,
# because it is a SPEC's enforcement, not just a regression corpus). A design
# agent needing to know what a cell actually does had to drive every fixture by
# hand. See test/diff_compiler_run_check_agreement.sh for the general shape
# this gate follows (check/run/build agreement, exit-code AND value).
#
# ⚠️ THIS GATE PINS WHAT THE BINARY ACTUALLY DOES ON CURRENT MAIN, NOT WHAT THE
# SPEC SAYS SHOULD HAPPEN. Per clause S7, `run`/`check`/`build` are specified to
# agree on every cell, so this gate checks all three -- exit-code verdict AND,
# for cells where run+build both accept, that they print the SAME, PINNED
# value (a P0-20-shaped bug -- build exits 0 printing a WRONG number -- is
# invisible to an exit-code-only gate; see that gate's own history).
#
# As of this writing (main past PR #25/#26/#27, binary rebuilt from THAT tree),
# every matrix cell that ships a fixture in test/shadow_fixtures/ is CONFORMANT
# -- check/run/build agree with each other AND with the doc's S1-S9-specified
# outcome -- EXCEPT d11 (below). That includes rows 10/12/13/14 (d4b/d5b/d9/d8),
# whose STATUS column in the doc's section-2 table used to say BUG: that column
# was STALE (P0-19 2026-07-10 + P0-20 2026-07-13 closed all four, as the doc's
# OWN section-5 update notes said a few paragraphs below the stale table). This
# gate's empirical run is what proved it, and the table has now been corrected
# to match -- with this gate cited as the enforcement.
#
# ###################################################################
# # 2026-07-14 -- THE S2 INVERSION. FIVE ROWS FLIPPED ACCEPT->REJECT #
# ###################################################################
# A top-level standalone now WINS over a same-named interface method inside the
# module that DEFINES it (compiler/SHADOW-INVERSION-DESIGN.md; docs/spec/
# SHADOW-SEMANTICS.md S2). The impl universe is no longer consulted for a
# DEFINER shadow. The bug it fixes: a user`s
#
#     eq : List Int -> List Int -> Bool
#     eq a b = True
#     main = println (debug (eq [1] [2]))      -- printed False. SILENTLY.
#
# was ERASED by the prelude`s `impl Eq List` -- on check AND run AND build, so
# by S7 (they all agree) NO differential gate could see it, BY CONSTRUCTION.
# That is exactly why this gate pins VALUES, and it is the only gate that could
# have caught the fix landing wrong.
#
# The five rows re-pinned, each ACCEPT -> located REJECT (`Type mismatch: Int
# vs <receiver>` at the call site, on all three paths):
#   d2 -- live-impl receiver                    (S2)
#   d3 -- N-way: S3 is now VACUOUS for a definer shadow
#   d6 -- live impl at a PARAMETRIC head        (S2)
#   d7 -- two-param method                      (S8)
#   d8 -- iface+impl IMPORTED                   (S6)
# Nothing that REJECTed became an ACCEPT: the change is monotonically MORE
# rejecting for definer shadows, which is what makes it safe to land.
#
# ⚠️ d8 DELIBERATELY REVERTS ebb8ee90 (P0-19 batch 2, row 14), which was two
# days old and made a definer shadow dispatch to a cross-module impl. That fix
# faithfully implemented the OLD S2; the inversion abolishes the rule it
# implemented. This is NOT a regression -- see the row`s label.
#
# ###################################################################
# # THE CORPUS WAS STRUCTURALLY BLIND TO THE UNGROUNDED RECEIVER    #
# ###################################################################
# d12 and i5 (added 2026-07-14) close a hole that let this gate grade 18/0 over a
# REAL BREAK. Every importer fixture -- i1, i3, i4 -- uses a GROUNDED receiver (a
# Box, a Tok, a List). Not one used a bare numeric literal. But a numeric literal
# is `Num a => a`: it is UNGROUNDED at inference time and only unifies to Int
# LATER. So the routing decision is taken on a receiver that HAS NO HEAD TYCON
# YET, and the type is then resolved against a receiver that has SINCE CHANGED.
#
# That shape -- ONE DECISION, DERIVED TWICE, AT TWO DIFFERENT TIMES, OVER A VALUE
# THAT CHANGED IN BETWEEN -- is the recurring root cause of this whole arc (P0-20;
# .claude/workstreams/COMPILER-SOUNDNESS.md). It bit `inferShadowApp` exactly as
# S1-RESIDUAL-B predicted it would, and the symptom was a *higher-kinded* unify
# accident: the prelude's `Foldable.isEmpty : t a -> Bool` swallowed the literal as
# `t := Int, a := Int`, giving the tell-tale `Type mismatch: Int literal vs Int Int`.
#
# ⭐ A GATE THAT CANNOT EXPRESS A CELL CANNOT DEFEND IT. When adding a shadow
# fixture, vary the receiver's PROVENANCE (literal / grounded / dict-bound), not
# just its type -- that axis is where every silent bug in this arc has lived.
#
# ⚠️ i1/i3/i4/i5 (IMPORTER shadows) MUST NOT MOVE. Fork 1 confines the
# inversion to DEFINER shadows: an `import` is a SIBLING scope, not an inner
# one. Inverting importers would break the everyday `import map` pattern
# (i4: `isEmpty [1,2]` must still reach `Foldable.isEmpty`). During
# development this gate caught exactly that -- inferDefinerShadowApp also
# serves importer shadows on the mangled emit path, via definerShadowArgHead`s
# `routeLocalSym != ""` arm. If any of them moves, the inversion has leaked.
# STOP.
#
# (This warning used to name d11 alongside them, for a DIFFERENT reason -- it
# was the KNOWN-BAD row and had to stay pinned to the bug. #54 fixed the bug
# and d11 moved, deliberately, to REJECT/REJECT/REJECT; the four importer rows
# did NOT, which is the evidence the definer-only split held.)
#
# d10 is the ledger working as designed. It was added by THIS gate as a
# KNOWN-BAD row pinning the S-1 bug (a CONSTRAINED standalone `Num a =>` shadow
# whose RLocal route carried no dictionary -- check green, run E-PANIC, build
# silently printing a garbage heap pointer). PR #25 then FIXED it, and this
# gate went RED on the very next run -- exactly what a ledger entry is for ("it
# must FAIL when the bug is fixed, so it can't rot"). The row is now re-pinned
# to the FIXED behavior: ACCEPT/ACCEPT/ACCEPT, value 4, run == build.
#
# d11 was that ledger row too, and it drained on 2026-07-17 (#54). It pinned
# S-3: a multi-TYPARAM interface (`interface Ix a i`) bypassed the whole
# definer-shadow machinery, because every entry point gated on
# `singleParamIfaceMethod` -- which, despite its name, counts INTERFACE type
# params, not method params. `check`+`build` agreed on the OLD pre-inversion
# per-receiver answer (4 then 3) while `run`, which has no route stamp to
# follow and resolves the bare name lexically, E-PANICked `unknown op '*'` --
# an S7 path-agreement violation. The fix splits that predicate by shadow KIND
# (`ifaceMethodName` for definers -- the S2 inversion never queries the impl
# universe, so typaram arity is irrelevant to it; `singleTyparamIfaceMethod`
# keeps gating the Fork-1 importer arms, whose per-receiver rule DOES key on the
# receiver standing at the interface's one typaram). d11's row went RED on the
# very next run and is now re-pinned to the fixed behavior -- REJECT/REJECT/
# REJECT, the d7 twin at multi-typaram width. THE LEDGER WORKED TWICE (d10, d11).
#
# ###################################################################
# # d21 -- WHAT DRIVING d11's FIX TO ITS EDGES ACTUALLY FOUND       #
# ###################################################################
# d11 pinned the LOUD half. Crossing its axis (typaram arity) with the one this
# gate's own ⭐ rule above names -- receiver PROVENANCE -- found the SILENT half,
# and nothing in the corpus could express it. d21 is d11 with an S5 dict-bound
# receiver (`useIface : Ix a i => a -> i -> Int`). On eedd1482, pre-#54:
#
#     check -> exit 0, reporting `useIface : a -> b -> Int`
#              (the `Ix a i =>` constraint SILENTLY DROPPED from the scheme)
#     run   -> E-PANIC `unknown op '*'`
#     build -> exit 0; the shipped binary printed  69867028434928  then  3
#              -- a RAW HEAP POINTER rendered as an Int, at exit 0
#
# That is the S-1 / P0-20 garbage-pointer shape, live, reachable through the same
# bypass d11 pinned -- and STRICTLY WORSE than d11's panic, because it is silent.
# #54 closed it: all three engines gave the identical located reject. What d21 then
# pinned was the RESIDUAL -- S5's carve-out ("a dict-bound `=>` receiver DISPATCHES")
# was unreachable at multi-typaram width -- and #54 wrote that the row must be
# RE-PROBED, not assumed, the day the cause was fixed.
#
# ✅ 2026-07-17: #604 LANDED, THE ROW WENT RED, AND THE RE-PROBE SAYS ACCEPT 4,3.
# The cause was never in the shadow machinery. Ty's `TyApp Ty Ty` is BINARY, so
# `Ix a i` nests as `TyApp (TyApp (TyCon Ix) a) i`; parser.mdk's extractConstraints
# matched only the ONE-arg `TyApp (TyCon iface _) arg`, so no arm matched and EVERY
# >=2-ARG CONSTRAINT WAS SILENTLY DISCARDED at parse (TyConstrained []). S5's
# antecedent was false because there was NO constraint. definerReceiverIsDictVar
# handles multi-arg constraints fine -- it never received one. #604 taught
# extractConstraints to walk the spine; the carve-out started working with NO change
# here. 4/400/3 at N-way width confirms the dict dispatch is real, not an accident.
# THE LEDGER HAS NOW WORKED THREE TIMES: d10 (S-1), d11 (S-3), d21 (S5/#604).
#
# ⚠️ TWO MISTAKES OF #54's, CORRECTED HERE, BOTH WORTH REMEMBERING:
#   1. It pinned d21 mode NONE -- VERDICTS ONLY. When #604 flipped the cell to
#      ACCEPT, a NONE row would have gone green reporting `ACCEPT ACCEPT ACCEPT`
#      WITHOUT EVER LOOKING AT WHAT IT PRINTED. On a gate whose entire reason for
#      existing is that S7 makes agreement worthless as evidence. Now ALL_EXACT.
#      IF A ROW CAN ACCEPT, PIN ITS VALUE.
#   2. It predicted the dispatch value as "3, 6". That is d7's pair, copied. The
#      correct pair is 4, 3. A predicted value in a doc is an unprobed claim.
#
# ⚠️ AND THE TRAP THE VALUE ITSELF SETS: d21's 4,3 is NUMERICALLY IDENTICAL to d11's
# old BUG output. d11's 4 was an UNQUALIFIED call the impl universe stole (the
# abolished pre-inversion S2). d21's 4 is dispatch the author EXPLICITLY REQUESTED by
# writing `Ix a i =>` (S5). Same number, opposite verdict. Do not "fix" it back.
#
# ⚠️ d21 is the ONE row here that depends on #604. Its importer twin i10 (row 30) does
# not -- no `=>` appears in it.
#
# d18 (#410) and its importer twin i6b (#669) were the last KNOWN gaps here -- both
# BUILD_CRASH (value-position shadow typed as the method scheme on the EMIT path -> a
# function element type -> NULL Display element dict -> SEGFAULT). FIXED 2026-07-19 by
# maybeStandaloneValueMonoEmit (types/typecheck.mdk); both are now ALL_EXACT [2, 3, 4].
#
# Untested-per-the-doc (rows 21-23: importer value-position / importer N-way /
# return-position method shadow) ship NO fixture in test/shadow_fixtures/ and
# are out of scope here -- adding fixtures for them is follow-up work, not a
# silent gap in THIS gate (this gate covers 100% of what test/shadow_fixtures/
# actually contains, checked by the coverage self-audit below, which fails
# loudly the moment a new fixture is dropped into the directory without being
# wired into the TABLE).
#
# Usage:  sh test/diff_compiler_shadow_semantics.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/shadow_fixtures"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir: $FIXDIR"; exit 2; }

bound() { perl -e 'alarm 60; exec @ARGV' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; asserts=0

# Table: entry-path (relative to FIXDIR) | label | exp_check | exp_run | exp_build | mode | value
#   exp_* in {ACCEPT, REJECT} -- ACCEPT means exit 0, REJECT means nonzero exit.
#   mode in:
#     NONE             -- no stdout assertion (all three REJECT; nothing ran)
#     ALL_EXACT        -- run and build both ACCEPT: their stdouts, AND the
#                         pinned `value`, must all be byte-identical (S7 value
#                         agreement + ground-truth pin, P0-20 shape)
#     BUILD_EXACT      -- only build's stdout is asserted against `value`
#                         (used when run is expected to REJECT but build is
#                         expected to ACCEPT with a specific, deterministic
#                         value -- a check/build-agree-run-diverges split)
#     BUILD_CRASH      -- KNOWN-BAD ledger: build exits 0 but the SHIPPED BINARY
#                         crashes with the SPECIFIC pinned signature (exit 139 /
#                         SIGSEGV-SIGBUS, stderr `E-FATAL-SIGNAL`) while run
#                         prints `value` correctly. Pins the crash SIGNATURE
#                         (not merely "nonzero"), run's value, AND the
#                         signature, so the row self-drains (goes RED) the day
#                         the bug is fixed -- and ALSO goes RED, surfacing a
#                         NEW bug instead of hiding it, if the binary starts
#                         crashing for a DIFFERENT reason (#463).
#     BUILD_NOTEQ_INT  -- build's stdout must be a bare integer (digits only)
#                         that is NOT equal to `value` (used for a
#                         non-deterministic garbage-pointer miscompile, where
#                         the wrong value differs run to run but is always
#                         "some integer, not the right one")
#   `value` uses literal backslash-n for embedded newlines (expanded via
#   `printf '%b'`); empty for mode NONE.
TABLE='d1b_definer_noimpl_zeroimpls.mdk|D1b definer, iface has ZERO impls (S2)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d1_definer_noimpl.mdk|D1 definer, no-impl receiver, impl exists elsewhere (S2)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d2_definer_liveimpl.mdk|D2 definer, live-impl receiver is now a located REJECT (S2 INVERSION: `size (Box 3)` no longer dispatches -- the module`s own `size : Int -> Int` wins, so Box mistypes)|REJECT|REJECT|REJECT|NONE|
d3_definer_nway.mdk|D3 definer, N-way: every live-impl receiver REJECTs (S3 INVERSION: S3 is vacuous for a definer shadow -- no receiver selects an impl; only `size 3` survives)|REJECT|REJECT|REJECT|NONE|
d4_definer_value_pos.mdk|D4 definer, value position over no-impl elements (S4)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[2, 3, 4]
d4b_definer_value_pos_liveimpl.mdk|D4b definer, value position over LIVE-impl elements (S4)|REJECT|REJECT|REJECT|NONE|
d5_definer_poly_receiver.mdk|D5 definer, ungrounded receiver monomorphises to standalone (S5)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d5b_definer_poly_liveimpl_call.mdk|D5b definer, poly wrapper CALLED at live-impl type (S5)|REJECT|REJECT|REJECT|NONE|
d6_definer_parametric_receiver.mdk|D6 definer, live impl at a PARAMETRIC head is now a located REJECT (S2 INVERSION: `impl Sizeable (P a)` no longer steals `size (P True)`)|REJECT|REJECT|REJECT|NONE|
d7_definer_multiparam_method.mdk|D7 definer, two-param method shadow now REJECTs its live-impl receiver (S8 INVERSION: `comb (Box 1) (Box 2)` types against the standalone `comb : Int -> Int -> Int`)|REJECT|REJECT|REJECT|NONE|
d9_definer_reject.mdk|D9 definer, no-impl receiver + standalone domain mismatch (S2)|REJECT|REJECT|REJECT|NONE|
d8_definer_imported_impl/main.mdk|D8 definer, IMPORTED iface+impl now REJECTs too (S6 INVERSION -- deliberately REVERTS the P0-19-batch-2 row-14 fix ebb8ee90, which made this dispatch cross-module: S6 is now trivial because the impl universe is never queried for a definer shadow, so WHERE the impl lives cannot change the outcome)|REJECT|REJECT|REJECT|NONE|
i1_importer_local_iface/main.mdk|I1/I2 importer shadow, LOCAL interface (S2/S6)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n4
i3_importer_imported_iface/main.mdk|I3 importer shadow, iface+impl in a THIRD module (S6)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n4
i4_importer_prelude_iface/main.mdk|I4 importer shadow of a PRELUDE method (S2, stdlib shape)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|True\nFalse\nFalse\nTrue
d10_definer_constrained.mdk|D10 definer, CONSTRAINED standalone dict-passed via RLocal (S9, was the S-1 bug)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d11_definer_multityparam_iface.mdk|D11 definer, multi-TYPARAM interface (`interface Ix a i`) now REJECTs its live-impl receiver like every other definer shadow (S2/S8 INVERSION; S-3 FIXED 2026-07-17 #54 -- was the last KNOWN-BAD row: check+build kept the OLD per-receiver answer 4,3 while run E-PANICked `unknown op '*'`, an S7 violation. The definer entry points gated on a typaram COUNT (singleParamIfaceMethod, now split into ifaceMethodName for definers / singleTyparamIfaceMethod for Fork-1 importers), which excused `Ix a i` from the machinery. `get (Box 3) 1` mistypes against the standalone `get : Int -> Int -> Int`; `get 3 1` -> 3. The d7 twin at multi-TYPARAM width)|REJECT|REJECT|REJECT|NONE|
d12_definer_ungrounded_literal.mdk|D12 definer, UNGROUNDED numeric-literal receiver whose grounded head HAS a live prelude impl (S2+S5; the P0-20 cell, now inverted: the standalone wins, 3 not False)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n30
i5_importer_ungrounded_literal/main.mdk|I5 importer, UNGROUNDED numeric-literal receiver (S2+S5; regression for S1-RESIDUAL-B, closed 2026-07-14) + the FORK-1 control in the same fixture (isEmpty [1,2] must still reach Foldable)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|True\nFalse\nFalse\nTrue
i6_importer_value_pos/main.mdk|I6 importer, value position over no-impl elements (S4, matrix row 21a; #411 -- was check+run ACCEPT [2,3,4] but BUILD died `no impl of method size for type Int`, a loud S7 split on a valid program). The importer twin of d4: expected IDENTICAL to row 9|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[2, 3, 4]
i7_importer_value_pos_liveimpl/main.mdk|I7 importer, value position over LIVE-impl elements (S4, matrix row 21b; #411 -- was the SILENT half: check zero diags and run AND build both printed [1, 2], all three engines agreeing on the forbidden answer). The importer twin of d4b: expected IDENTICAL to row 10|REJECT|REJECT|REJECT|NONE|
i8_importer_nway/main.mdk|I8 importer, N-way multi-impl (S3, matrix row 22): per-receiver, UNCHANGED for importer shadows -- the FORK-1 control at N-way width, which must NOT follow row 6`s definer flip to REJECT. Probed conformant while fixing #411|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n30\n4
i9_importer_return_pos/main.mdk|I9 importer, RETURN-POSITION method shadow (S4, matrix row 23): `mk : Int -> a` has no receiver param, so the value-position rule gives the standalone. Probed conformant while fixing #411|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d13_definer_return_pos.mdk|D13 definer, RETURN-POSITION method shadow (S4, matrix row 23, definer half): the d-twin of I9. Probed conformant while fixing #411|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d17_definer_value_pos_arity_differ.mdk|D17 definer, value position where METHOD arity (2) DIFFERS from STANDALONE arity (1) (S4; S1-RESIDUAL-A, #410). The emitter lift built a 2-arity closure over a 1-arity body, so map got PAPs back and build printed heap pointers as Ints at exit 0 -- SILENT WRONGNESS. Fixed by methValArity (route-derived, not name-derived). D4/D4b are arity-EQUAL, which is why the corpus was blind to this|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[2, 3, 4]
d19_definer_value_pos_arity_differ_zeroimpls.mdk|D19 definer, arity-differ value position with ZERO impls (S2+S4, #410) -- shadow-hood + arity mismatch + value position suffice; the impl universe is irrelevant|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[2, 3, 4]
d20_definer_value_pos_arity_differ_opposite.mdk|D20 definer, OPPOSITE arity direction to d17: METHOD arity 1 < STANDALONE arity 2 (S4, #410). Pins the other side of the route-derived arity -- the closure must be arity 2 so `f 1 2` is a saturated direct call|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3
i10_importer_multityparam_iface/main.mdk|I10 importer shadow of a method on a MULTI-TYPARAM interface (S2 importer arm / Fork 1, matrix row 30): the i1 shape one axis over. Box has a live impl -> dispatch (3+1=4); Int has none -> the imported standalone (3*1=3). ADDED 2026-07-17 -- and it DISPROVED the row-30 note #54 wrote: #54 reasoned that because the importer entry points decline at multi-typaram width, the occurrence falls to ordinary dispatch which has no else-standalone arm, and recorded a `probable live divergence from S2`, UNVERIFIED. Probed once #604 unblocked it: CONFORMANT. Ordinary dispatch reaches the impl for a live-impl head, and for a no-impl head the env binding of the bare name IS the imported standalone, so S2`s fallback falls out. 4/400/3 at N-way width too. #604-INDEPENDENT (no `=>` in the fixture)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4\n3
d21_definer_multityparam_dictvar_receiver.mdk|D21 definer, S5 CARVE-OUT at MULTI-TYPARAM width: a dict-bound `Ix a i =>` receiver DISPATCHES (S5), while the unqualified `get 3 1` on the same name takes the standalone (S2). GAP CLOSED 2026-07-17 by #604 (parser: extractConstraints now walks the whole TyApp spine, so a >=2-arg constraint reaches typecheck at all) -- this row was pinned REJECT/REJECT/REJECT as an S5 GAP by #54 and went RED the day #604 landed, which is the ledger working a THIRD time. NOTE the mode is ALL_EXACT, not NONE: the #54 row asserted only AGREEMENT, and agreement is the PRECONDITION for the worst bug this gate knows about, so the values are now pinned. WARNING: the value 4,3 is numerically IDENTICAL to d11`s old BUG output and is not the same thing -- d11`s 4 was an UNQUALIFIED call the impl universe stole (the abolished pre-inversion S2); d21`s 4 is dispatch the author EXPLICITLY REQUESTED by writing `Ix a i =>` (S5). Same number, opposite verdict. Do not fix this back|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4\n3
d18_definer_value_pos_arity_differ_unannot.mdk|D18 FIXED (#410, was BUILD_CRASH): d17 WITHOUT the List Int annotation. The EMIT path typed the value-position shadow as the METHOD scheme (a -> a -> Int) because maybeStandaloneValueMono is keyed on the BARE name, which the mangler had renamed; so map size inferred element type Int -> Int (a function) and println`s Display (List (Int -> Int)) stamped a NULL element dict (RNone -> i64 0) -> SEGFAULT, while run followed the RLocal route and was correct. Fixed by maybeStandaloneValueMonoEmit (types/typecheck.mdk): inferMethodAt now recovers the post-mangle shadow via the route sym and pins the standalone scheme, grounding the element before resolveDictApps. Now ALL_EXACT [2, 3, 4]|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[2, 3, 4]
i6b_importer_value_pos_arity_differ_unannot/main.mdk|I6b FIXED (#669, importer twin of d18): an IMPORTED standalone size : Int -> Int shadows a LOCAL interface Sizeable a where size : a -> a -> Int (arity DIFFERS), used bare in value position (map size [1,2,3]). Same NULL element dict SEGFAULT as d18 before the fix -- one root cause, one fix site (maybeStandaloneValueMonoEmit`s standaloneSchemeFor resolves the definer via the env under the mangled sym and the importer via the same accessor). Exercised through the multi-module loader (prov.mdk + main.mdk). ALL_EXACT [2, 3, 4]|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[2, 3, 4]
d18b_definer_value_pos_string_elem.mdk|D18b (#410 non-defaulting variant of d18): value-position definer shadow with STRING elements (map size ["a","b","c"]). String has NO Num-defaulting fallback, so this pins that maybeStandaloneValueMonoEmit`s grounding of the element is REAL -- if it regressed, the element would be a function type (String -> String), Display (List (String -> String)) would stamp a NULL element dict, and build would SEGFAULT. ALL_EXACT [a!, b!, c!]|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[a!, b!, c!]
d22_definer_multityparam_value_pos.mdk|D22 FIXED (#724, was BUILD_CRASH): d18 at MULTI-TYPARAM width -- a definer value-position shadow of a method on `interface Ix a i` (two type params), the cell the corpus lacked (d18 is single-typaram; d11 is multi-typaram but an APP head). The CHECK path grounded it to the standalone `Int -> Int` typaram-AGNOSTICALLY (maybeStandaloneValueMono`s definer arm = ifaceMethodName), but the EMIT path DECLINED it behind a blanket singleTyparamIfaceMethod gate, so map size inferred a function element type -> NULL Display element dict -> the shipped binary SEGFAULTed (139) while check/run were clean [2,3,4] -- the #410 skew at multi-typaram width. Fixed 2026-07-19 by splitting maybeStandaloneValueMonoEmit`s gate per shadow KIND (emitValueShadowGate): the DEFINER arm is now ifaceMethodName (typaram-agnostic, mirroring check), the IMPORTER arm stays singleTyparamIfaceMethod (i10/Fork 1). Now ALL_EXACT [2, 3, 4]. Safe against the multi-typaram app-head ambiguity because a definer app head is always bracketed by inferDefinerShadowApp (isDefinerShadow = ifaceMethodName), so the only definer occurrence reaching the emit pin with shadowHeadCtxRef False is a genuine value position; see d22z below|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[2, 3, 4]
d22b_definer_multityparam_value_pos_string_elem.mdk|D22b (#724 non-defaulting variant of d22): d22 with STRING elements (map size ["a","b","c"]). d18b at multi-typaram width -- String has NO Num-defaulting fallback, so if emitValueShadowGate`s definer arm regressed to declining multi-typaram definers the element would be a function type (String -> String) with no Display, a NULL element dict, and build would SEGFAULT. Pins that the multi-typaram definer grounding is REAL. ALL_EXACT [a!, b!, c!]|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[a!, b!, c!]
i11_importer_extern_receiver/main.mdk|I11 importer shadow of a PRELUDE method (Display.display) with an EXTERN-SOURCED receiver -- the i4 shape on the PROVENANCE axis this gate`s own ⭐ rule names. `display (3 : Int)` and `display (stringLength "xy")` have the SAME receiver type and MUST route the same way; every other cell in this corpus uses an annotated or literal receiver, so the corpus graded 36/36 over the S0 this pins. Extern signatures in stdlib/runtime.mdk never pass through resolve`s head-stamping walk, so their monos carry no TyConOrigin -- a dispatch-existence test that compares the goal head`s IDENTITY rather than its SPELLING answers False for lines 3-4 only and silently reroutes them to the imported standalone `display : Tok -> String` (loud here, `Type mismatch: Tok vs Int`; SILENT in the `debug` variant, which prints the standalone`s answer at exit 0). Added by the adversarial review of PR #1274 (#1111 A-2.2b); the fix is `implExistsForHeadGo` projecting BOTH sides through `dispHeadTab`, the same projection the bucketing uses|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|tok\n3\n2\n97
d22z_definer_multityparam_apphead_control.mdk|D22z (#724 APP-HEAD CONTROL for the emit-gate relaxation): the SAME multi-typaram interface as d22, but the shadow name is used BOTH in value position (map size [1,2,3] -> standalone, [2,3,4]) AND as an application head (size 10 -> applied standalone, 11) in one program. Pins that relaxing emitValueShadowGate`s definer arm to ifaceMethodName did NOT mis-ground the multi-typaram app head: a definer app head is bracketed shadowHeadCtxRef True by inferDefinerShadowApp before its head is typed, so it NEVER reaches maybeStandaloneValueMonoEmit as a value position. If the relaxation over-fired, `size 10` would be pinned to `Int -> Int` as a VALUE and mis-elaborate. check/run/build all print ([2, 3, 4], 11)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|([2, 3, 4], 11)
i12_importer_iface_not_nameable/main.mdk|I12 (#1353 / #1375) importer shadow where the interface is NOT NAMEABLE in the occurrence`s module -- S1`s interface operand is scoped to `nameable in M` (SHADOW-SEMANTICS.md 1.0; ruling #1375). `Sizeable` is neither declared in main.mdk, nor imported by it, nor the prelude: it reaches the loaded graph only TRANSITIVELY, through `bridge`s PLAIN import of smod.{sf}, which re-exports nothing. So `size` is not a shadow here and the occurrence is the standalone main.mdk explicitly imported: 99. THIS IS THE CORPUS-GAP ROW #1375 RECORDS AS OWED -- before it, every unit put the shadowed interface INSIDE the occurrence module`s nameable set, so the corpus graded 37/37 identically under BOTH readings of the clause and could not have discriminated the ruling either way. It was #1353 (S0): adding one `import bridge.{bf}` line changed the `size` call from the imported standalone to an impl body in a module with no import path to here -- exit 0, no diagnostic, on check AND run AND build, which is precisely the S7-agreement shape that makes a differential gate blind. Replaces the drained test/must_fail_fixtures/1353-transitive-iface-shadow-no-visibility pin: a drained pin is DELETED, so without this row a fixed S0 has no guard at all|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99
i13_importer_not_nameable_liveimpl/main.mdk|I13 (#1375`s sharper repro) the i12 shape with a LIVE IMPL at the receiver`s head tycon, pinning the direction that shows the clause changing what a WRITABLE name denotes. main.mdk imports `size : Int -> Int` from `prov` and `Box` from `boxmod`; `Sizeable` and `impl Sizeable Box` live in `ifcmod`, reachable only through `bridge`s plain import. Not nameable means not a shadow, so `size (Box 3)` applies the imported Int -> Int standalone to a Box: located REJECT `Type mismatch: Int vs Box`. Under the graph-global reading the SAME source is ACCEPTED at exit 0 printing 300 -- an impl body the author cannot name, selected for a receiver the name they DID write cannot accept. i12 pins a wrong VALUE, this pins a wrong DENOTATION; the two fail for different reasons|REJECT|REJECT|REJECT|NONE|
i14_importer_iface_via_reexport_chain/main.mdk|I14 (#1380 S1-CHAIN) importer shadow whose interface is nameable ONLY THROUGH A RE-EXPORT CHAIN. `Sizeable` is not declared here, not the prelude, and `ifc` is not imported here -- it arrives via `reexp`, whose `export import ifc.{Sizeable}` re-exports it by TYPE name and names no method. 1.0`s `nameable in M` covers that case verbatim, so `size` IS a shadow, `Box` has a live impl, and it dispatches: 300. MUST EQUAL row `direct.mdk` below -- the same interface reached without the hop. THE CORPUS CONTAINED NO `export import` AT ALL before this cell (derive it with: grep -rl export.import test/shadow_fixtures/), which is why the first cut of the #1353 fix could build its predicate out of a METHOD-name index, answer NOT-NAMEABLE for a chain that names no method, and REJECT this program while `direct.mdk` printed 300 -- a false reject on a program the base accepts, and the exact non-conformance S1-CHAIN enumerates|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|300
i14_importer_iface_via_reexport_chain/direct.mdk|I14-direct: the CONTROL for the row above, graded as its own row. Byte-identical except `import ifc.{Sizeable}` in place of `import reexp.{Sizeable}`. Re-routing one import through a re-exporter cannot change a program`s meaning, so whatever the answer is, the two rows must agree -- an invariant that holds under EITHER reading of the clause, which is what makes it the thing to code against rather than the value|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|300
i15_importer_iface_one_hop_unbound/main.mdk|I15 (#1353, ONE-HOP form) the interface`s home module IS imported -- and the interface is still not nameable, because the import binds only `sf`. Independent evidence, true on the base binary too: writing `impl Sizeable Blob` in this module is rejected `Unknown interface: Sizeable`. So `size` is not a shadow and the imported standalone answers: 99. This is #1353`s own repro with the bridge hop REMOVED -- one line shorter than i12 -- and it is a DIFFERENT cell, not a duplicate: the first cut of the fix admitted a dependency`s whole interface set on any import of it, so i12 was green while this shape still printed the impl`s 7, leaving the S0 narrowed rather than fixed with its must-fail pin already deleted|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99
i15_importer_iface_one_hop_unbound/bare.mdk|I15-bare: the BARE-IMPORT spelling of the cell above, graded separately because it takes a different arm of the predicate -- `import smod.{sf}` is a member list naming no interface, a bare `import smod` is an EMPTY member list. A filter that read the empty list as BINDS-EVERYTHING (the way a wildcard legitimately is read) would pass the row above and fail this one. A bare import binds no names; it exists to bring impls into scope, which S2 governs and S1 does not|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99
i16_importer_iface_via_chain_silent/main.mdk|I16 the SILENT corner of the chain axis. Same `export import ifc.{Sizeable}` hop as i14, but the impl and the standalone share the receiver head (String), so BOTH candidates typecheck and the shadow decision is observable ONLY as a value: 7 (the impl) if `size` is a shadow here, 99 (the standalone) if it is not. Per S1 the interface IS nameable through the chain, so it dispatches: 7. MUST EQUAL row `direct.mdk` below. WHY SEPARATE FROM i14: i14 uses a receiver the standalone cannot accept, so a lost shadow is a located REJECT -- loud. This corpus history is that the loud half of a defect gets a fixture and the silent half does not (d18/d21, i6/i7), and the silent half is the one that ships. A lost shadow here prints 99 at exit 0 on all three verbs with no diagnostic, and only a pinned VALUE can catch it|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|7
i16_importer_iface_via_chain_silent/direct.mdk|I16-direct: the CONTROL for the row above, graded as its own row -- the chain hop removed, `ifc` imported directly. On the silent axis this pair IS the test: neither file can fail loudly, so only their agreement plus the pinned value can detect a chain hop that changed the program meaning|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|7
i17_importer_two_ifaces_neither_nameable/main.mdk|I17 (#1351) TWO unrelated interfaces declare the same bare method name at DIFFERENT dispatch argument indices, and NEITHER is nameable here -- this module imports both of their modules but binds only `af` and `zf`. So `mth` is not a shadow, the occurrence is the standalone explicitly imported, and the answer is 99. The standalone `fmodI.mth` is LOAD-BEARING: the bare-name dispatch-index table`s only reader is gated on `standaloneValuesRef`, so without it the table is never read and this graph would be immune to the defect. MUST EQUAL the `order-swapped.mdk` row below. VALUE DERIVED, NOT CAPTURED: #1351 hand-derived it before any fix -- the call passes a String in FIRST position while `impl IZ String`s method takes an Int first, so reaching that body is wrong under every reading and the only defensible answers were the standalone (99) or a rejection; S1 picks the standalone. ⚠️ `universeMethodDispatchIdxRef` is STILL bare-name-keyed and read first-match -- this graph no longer REACHES it, so that keying defect is latent, not removed|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99
i17_importer_two_ifaces_neither_nameable/order-swapped.mdk|I17-swapped: byte-identical to the row above except the two interface-module import lines are swapped, graded as its own row. Reordering import clauses is cosmetic, so the two must agree; before the fix they disagreed about whether the program COMPILES AT ALL -- main.mdk accepted at exit 0 printing 7, this one was rejected `Type mismatch: Int vs String`. ⚠️ A PAIR IS WEAKER THAN A PERMUTATION DIFFERENTIAL: three clauses have six orderings and this pins two. The other four are NOT owed -- test/import_order_fixtures/1351-methoddispatchidx-import-order-collision/ is this same graph in the permutation corpus and it is STILL LEDGERED there: an early round of this fix drained the row, a later round RE-POINTED the fixture instead (entry member list `zmodI.{zf}` -> `zmodI.{IZ, zf}`) and RE-CUT the two signatures, so test/diff_compiler_import_order.sh still reports it KNOWN-BAD #1351, still diverging exactly as pinned. 🚨 DO NOT restore the old spelling to make that case converge -- converging is what the re-point exists to prevent, because #1351 is OPEN and the old spelling stopped reaching the defect (with neither interface nameable, `mth` is not a shadow and the bare-name dispatch-index table is never consulted). These two rows are the SEMANTIC companion: they say WHY the answer is 99 (neither interface is nameable in the entry) and pin the VALUE on all three verbs, which an invariance check alone cannot -- six orderings agreeing on a WRONG value is invariant too|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99
i18_importer_alias_not_nameable/main.mdk|I18 (S1-NS (a), UNION) an interface reached ONLY through a module ALIAS. CONFORMANT: 7 is the correct answer, not a placeholder. Arm (i), the TYPE arm, fails as expected -- an alias cannot put a TYPE name in scope (alias-qualified names in type position are a parse error) and `impl Sizeable Blob` in this module is rejected `Unknown interface: Sizeable` -- but (a) is a UNION and arm (ii), the VALUE arm, is satisfied independently: `S.size` is a legal call, so the module alias admits `size` as a callable method on its own. `size` is therefore an importer shadow, S2 finds a live `impl Sizeable String`, and dispatch (7) is what conformance requires; 99 would be the non-conformant answer here. MECHANISM KEPT FOR THE RECORD, not the reason 7 is right: renameAliasedMethods rewrites `S.size` to a BARE `size`, so an alias-qualified call and a bare standalone reference are the same token by the time any rule here runs (see both.mdk) -- which is why an import-clause-shaped rule can never recover which spelling was written. Conditioning admission on names-otherwise-bound was tried anyway and produced run=99 against a binary of 7 at exit 0, a NEW silent divergence, worse than what it tried to fix|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|7
i18_importer_alias_not_nameable/both.mdk|I18-both: BOTH spellings in ONE module -- `size` (the imported standalone) and `S.size` (an alias-qualified method call). They MUST mean different things, 99 then 7. 🚨 WHAT THIS ROW DEFENDS IS THE AGREEMENT, NOT THE VALUES: run gives the SAME answer to both because the qualifier is erased before the mark pass, and the pinned 7,7 records that rather than endorsing it. What must hold is run == BUILT BINARY, and that is what a fix in this area breaks first -- filtering argNames and the mangled shadow map with DIFFERENT predicates made run print 7,7 while the binary printed 99,7, a split base does not have. An ACCEPT/REJECT column cannot see any of this: every cell exits 0|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|7\n7
i19_importer_sibling_method_silent/main.mdk|I19 (S1-NS (a), PER-METHOD) the interface is reached ONLY by naming a SIBLING method. `import ifc.{tag}` admits `tag` and nothing else -- measurably: writing `size x` on the strength of that import is rejected Unbound variable: size. So `size` is not in S1 right operand, not a shadow, and the imported standalone answers 42. 🚨 THE SILENT CELL: the standalone domain COVERS the impl head (both String), so both candidates typecheck and every verb exits 0 -- the pre-#1353 compiler printed 777, the impl body, on evidence about a DIFFERENT name. Only a pinned VALUE can see this; no ACCEPT/REJECT column can. 777 -> 42 is an acceptance NARROWING reaching its silent half, which S1-SCOPE charges as the ruling own cost and the corpus blindness note says the corpus could not express -- which is why the ruling OWES this cell|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|42
d23_definer_sibling_method_silent/main.mdk|D23 (S1-NS (a), the DEFINER twin of i19) this module DEFINES its own `size` and reaches the interface only by naming a SIBLING method, so `size` is not in S1 right operand and the module OWN top-level binding answers: 42. 🚨 THIS IS THE S0 THE WHOLE S1-NS PASS IS ABOUT AND IT HAD NO FIXTURE AT ALL: under per-ROW admission the interface was admitted because a DIFFERENT method was named, `size` became a shadow, S2 definer inversion never fired, and a module own top-level function was silently replaced by a foreign impl body printing 777 at exit 0 with no diagnostic on any verb. ⚠️ BASELINE, so the sentence above is not over-read: the MERGE BASE already gives 42 here. This cell fails only against the intermediate state of the PR that introduced per-ROW admission, so it guards a regression that unit introduced rather than one it inherited -- do not cite it as evidence the unit changed behaviour on main. Receiver is String -- inside the standalone domain AND at the impl head -- so both candidates typecheck and only the pinned value discriminates. Paired with i19 because S2 treats definer and importer differently and a fix repairing one alone leaves the other silent|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|42
i20_importer_method_reexport_chain/main.mdk|I20 (S1-NS (a), RE-EXPORT ARM SYMMETRY) the method arrives through a chain that re-exports it by METHOD name (`export import ifc.{size, Box}`) and names the interface nowhere. The VALUE arm admits `size` at every re-export depth, so it is an ordinary dispatch and `impl Sizeable Int` gives 50. 🚨 GRADED ON BUILD because that is the only verb that could see it: an implementation whose RE-EXPORT arm matches interface names only leaves `size` out of the dispatch-eligible set, the mark pass leaves a plain EVar, emit falls into arg-tag dispatch, and build fails E-PANIC arg-tag dispatch on impl type that owns no constructors while check exits 0 and run prints the right answer. That asymmetry was LIVE on this PR -- a fourth independent namespace guess at the one site nobody had counted -- and S1-NS enumerates it non-conformant. The `impl Sizeable Int` is load-bearing: a PRIMITIVE receiver is what turns the missing mark into a panic, because a primitive carries no cell tag|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|50
d24_definer_return_pos_not_nameable/main.mdk|D24 (S1-NS (b), RETURN-POSITION) this module DEFINES its own `zed` and reaches smod only via `import smod.{sf}`, which admits neither the type name Zed nor the method name zed -- so `zed` is not in S1 right operand, not a shadow, and the module own binding answers 42. 🚨 THE WHOLE CORPUS WAS ARG-POSITION UNTIL THIS CELL: every interface method in test/shadow_fixtures/ mentioned its typaram in an ARGUMENT, and `zed : a` does not. That single axis selects a DIFFERENT input to the mark pass -- returnPosMethodNames, which was concatenated RAW while the arg-position inputs were filtered -- so dispatch-eligibility was a strict SUPERSET of shadow-hood (S1-NS Newly NON-CONFORMANT (1)) and 52 assertions were green over it. Measured before the fix: run 777 (an impl reached through an interface this module cannot name) vs BUILT BINARY 42, both exit 0, no diagnostic. Graded on run AND build because neither verb alone, and no ACCEPT/REJECT column, can see it|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|42
d25_definer_return_pos_nameable/main.mdk|D25 (S2 definer arm, RETURN-POSITION, matrix row 39 / #1430) the DISCRIMINATING TWIN of d24: same return-position method, but `Zed` is imported BY NAME so the interface IS nameable here, `zed` IS a definer shadow, and S2 inversion is unconditional -- the module own binding answers 42 on every verb. 🚨 THE CORPUS HAD ONLY THE NOT-NAMEABLE SIDE: d24 and i21 were the only return-position cells and BOTH pass because S1 DECLINES TO CLASSIFY, so neither ever reaches S2 inversion at all -- row 39 own words, "this is why row 38 must not be read as covering return position". The cell that DOES reach it lived only as a self-draining must-fail pin, which this gate cannot see. Measured before the fix, MEDAKA_STRICT=1, redirected with $? read separately: check exit 0 zero diagnostics, run exit 0 printing 777 (the impl body -- the S0 half), build exit 1 E-PANIC unbound method: zed. Three verbs, three answers. Graded ALL_EXACT because every ACCEPT/REJECT column was already ACCEPT on the check arm while the value was wrong. Root cause was a TYPE/ROUTE split, not a classification miss: maybeStandaloneValueMono had already pinned the TYPE to the standalone while recordRLocalSite declined to push any route site, because a return-position method has no dispatch argument and methodDispatchIdx answers None|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|42
d26_definer_nonzero_dispatch_idx.mdk|D26 (S2/S5 definer arms at NON-ZERO DISPATCH INDEX, #1815) the interface dispatches on argument 1 (`mth : Int -> b -> Int`), and until this cell EVERY definer fixture in this corpus dispatched on argument 0 -- the axis the corpus was blind to by construction, because the application-head arms peel a BARE head and a bare head is the node supplying argument 0. Two denotations, both pinned by value: `mth 3 4` takes the module own standalone (S2, no impl at Int) = 12, and `viaDict 3 (Box 4)` dispatches through the enclosing `IZ b =>` dict var (S5 carve-out, live impl at Box) = 707. 🚨 MEASURED ON THE BASE BINARY (342bdf82, cold-built in this worktree, MEDAKA_STRICT=1, redirected with $? read separately): check/run/build ALL exit 1, `Type mismatch: Int vs Box` at the `viaDict` call -- because `viaDict`s written signature had been silently replaced by the standalone whole declared type `Int -> Int -> Int`. This row is the LOUD half; d26b is the silent one, and the two receivers differ in head here precisely so a lost carve-out cannot hide. Values hand-derived from S2/S5, not captured|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|12\n707
d26b_definer_nonzero_dispatch_idx_silent.mdk|D26b (#1815) the SILENT half of d26 and not a duplicate of it. The live `impl IZ Int` sits at the SAME head as the standalone declared domain at argument 1, so both denotations are well-typed at both call sites and every verb exits 0 whichever way the decision goes -- only the pinned value can discriminate. `mth 3 4` = 12 (S2 inversion; 777 is the impl body, the silent-wrongness answer) and `viaDict 3 4` = 777 (S5 carve-out; 12 would be the wrong one). Same interface, same method name, same receiver TYPE -- the two lines differ ONLY in the receivers PROVENANCE (grounded literal vs dict-bound), the axis this gate own ⭐ rule names, at the dispatch index the corpus lacked. 🚨 MEASURED ON THE BASE BINARY (342bdf82): run AND the built binary both printed `12` for BOTH lines at exit 0 with check clean -- the dict-bound receiver silently lost its carve-out and took the standalone. No ACCEPT/REJECT column and no other row in this corpus could see that. Values hand-derived from S2/S5, not captured|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|12\n777
i21_importer_return_pos_not_nameable/main.mdk|I21: the IMPORTER twin of d24 -- same return-position axis with the standalone IMPORTED rather than defined here. Not redundant: S2 states its rule PER KIND and the two kinds reach the mark pass by different paths (a definer name is mangled to main__zed on emit, an importer name is rewritten to the provider symbol), so a fix repairing one leaves the other silent -- the shape this corpus was bitten by at d18/i6b and d22/i7. Same measured split before the fix: run 777, binary 42|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|42
i22_importer_member_alias_not_nameable/main.mdk|I22 the method arrives under a MEMBER ALIAS. 🚨 PINS A KNOWN-WRONG ANSWER and does NOT claim 7 is correct: under S1-NS (a)(ii) the VALUE arm admits a method the import path makes CALLABLE, and the only name this module can write for it is `sz` -- it cannot write `size` for the method at all -- so `size` denotes fmod standalone and 99 is correct. MECHANISM: selectIfaceRows narrows by member ORIGIN (map fst bs), so {size as sz} admits `size` rather than `sz`. 🚨 THE FIX SHAPE IS NOT KNOWN AND THE OBVIOUS ONE IS INERT -- this row used to say the fix was one token, key the VALUE arm on snd. It cannot move this row, derivably: elaborateModules calls renameAliasedMethods (its only call site) BEFORE it writes graphIfaceMethodsRef and before the mark pass, and that rewrites {size as sz} to {size}, so snd == fst by the time selectIfaceRows runs. A reviewer implemented the one-token change, rebuilt, and measured main.mdk still at 7. Any real fix spans both functions and is a design question. NOT A REGRESSION -- base prints 7 too, so the member-alias arm is exactly where this unit changes nothing -- and re-keying is a behaviour change on an axis no ruling covers, so it is PINNED to self-drain rather than fixed here. An earlier source comment called this deviation unobservable because aliased method imports were broken; both halves are false (`sz "ab"` prints 7, and this pair reaches the difference)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|7
i22_importer_member_alias_not_nameable/bare.mdk|I22-bare: the DISCRIMINATOR, graded as its own row -- byte-identical except a bare `import ifc` replaces `import ifc.{size as sz}`. Both spellings admit the same amount of the interface (NOTHING writable: a bare import binds no names, a member alias binds only `sz`), so both should print 99 -- and only this one does. The pair is what makes i22 a defect report rather than a captured golden: one number could be argued intended, two spellings with equal admission and different answers cannot both be right. It is also the proof that the correct value is reachable rather than hypothetical|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99
i23_importer_admitted_iface_holds_impl/main.mdk|I23 (RUN-METHID-136) THE FALSE-MISS DIRECTION of `ieRowAdmittedBy`, which no acceptance clause of S-impl-query-by-declaration covered. The admitted set is the singleton `{IA}` (`import amodI.{IA, af}` names it; `import zmodI` is bare so `IZ` is not nameable), `IA.mth : a -> Int -> Int` puts its dispatch typaram at index 0, the receiver is `"abc"` head String, and `impl IA String` EXISTS in amodI -- so the impl query HITS and the answer is that impl`s body, 55. 🚨 THE FAILURE MODE IS SILENT, NOT LOUD: if the conjunct answers False where it should answer True, nothing errors -- the query falls through to the bare-name STANDALONE FALLBACK `fmodI.mth = 99` and the program prints a plausible number at exit 0. That is why this row pins the VALUE on all three verbs; an exit-code-only or reject-only assertion cannot see a wrong path that produces a right-looking answer. VALUE HAND-DERIVED from the declared signatures (not captured), and independently measured by the impl-query slice-breaker (attempt 5, corpus IMPLADM); fixture files copied VERBATIM from that breaker`s corpus|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|55
i24_importer_samespelled_ifaces_admitted_holds_impl/main.mdk|I24 (RUN-METHID-136) the SAME-SPELLED twin of i23: both interfaces are literally named `Method`, so bare-name keying cannot distinguish them and only DECLARATION identity can. amodI2`s `Method` is the admitted one (`import amodI2.{Method, af}`) and carries `impl Method String = 55`; zmodI2`s unrelated `Method` (dispatch index 1, `impl Method String = 7`) is reached only by a bare import and is not nameable. Same silent failure mode as i23 -- a false MISS prints the standalone `fmodI2.mth = 99`, not an error -- and additionally a WRONG-DECLARATION hit would print 7, so this row discriminates three outcomes (55 correct / 99 fallback / 7 wrong declaration) that an exit-code gate collapses into one. VALUE HAND-DERIVED from the declared signatures (not captured), independently measured by the impl-query slice-breaker (attempt c2, corpus SS3); fixture files copied VERBATIM from that breaker`s corpus|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|55
x1_prelude_standalone_not_left_operand.mdk|X1 (S1-PRELUDE, ruled 2026-08-10, #1375 item 2) THE PRELUDE LEFT-OPERAND CELL, and the corpus had none: every other unit here puts the standalone in the module or imports it explicitly, so the question of whether an IMPLICIT PRELUDE standalone can be S1 left operand graded nowhere. `isEven` is a prelude standalone (core.mdk `export isEven : Int -> Bool`), the interface method of that name is declared HERE, and the receiver 7 is at a head with NO impl Parity but INSIDE the prelude standalone domain. RULED: the prelude is not in S1 left operand, so this is NOT a shadow, the bare name is the INTERFACE METHOD, and ordinary dispatch finds no impl -- located REJECT on all three verbs. The REJECTED reading (admit the prelude standalone as an importer shadow) would ACCEPT and print False, because S2 importer arm falls back to the standalone when no impl sits at the head. 🚨 VALUE HAND-DERIVED FROM THE RULING, NOT CAPTURED: the execution arms are KNOWN TO DISAGREE on neighbouring cells of this same collision (#1492 loud, and the silent run-vs-binary split at SHADOW-SEMANTICS matrix row 49, filed as #1497), so at most one could serve as an oracle and capturing could have enshrined the opposite denotation. NO MECHANISM ASSERTED -- the partial-application account is measured FALSE (#1492, arity-independent symptom)|REJECT|REJECT|REJECT|NONE|
x2_prelude_standalone_zeroimpls.mdk|X2 (S1-PRELUDE) X1 with ZERO impls of the colliding interface -- the d1b/d19 move applied to the prelude cell. Closes a different escape hatch: an implementation that consulted the impl universe before deciding the NAME would answer X1 correctly for the wrong reason. With no impl to consult, the only thing that can produce this reject is the interface method having taken the name outright, which is exactly what S1-PRELUDE (a) says (no S2 arm applies, the impl universe is never consulted to decide the name). Under the rejected reading this ACCEPTs and prints False. VALUE HAND-DERIVED, NOT CAPTURED|REJECT|REJECT|REJECT|NONE|
x3_prelude_standalone_arity_differ.mdk|X3 (S1-PRELUDE) the ARITY-DIFFERING sibling. X1 and X2 both collide with a prelude standalone whose arity MATCHES the interface method, so a reader could conclude the rule is gated on the signatures lining up. It is not: prelude `count` takes two arguments (core.mdk `export count : Foldable t => (a -> <e> Bool) -> t a -> <e> Int`) against an interface method of arity 1, and the name still goes to the interface method -- yielding an over-application diagnostic AND No impl of Sized for the function argument. Under the rejected importer reading no impl sits at the head of the function argument, so it would fall back to the prelude standalone, ACCEPT, and print 3. VALUE HAND-DERIVED, NOT CAPTURED|REJECT|REJECT|REJECT|NONE|
x4_prelude_standalone_live_impl_receiver.mdk|X4 (S1-PRELUDE (a), matrix row 49) THE ACCEPTING HALF of the prelude left-operand cell. x1/x2/x3 all place the receiver OUTSIDE the interface`s impl universe, so all three are REJECTs and the rule was graded only where it kills the program -- an implementation that handed the name to the PRELUDE STANDALONE whenever the standalone happened to be well-typed at the receiver satisfied every one of them. Here the receiver lies in BOTH denotations` domains (7 is an Int, prelude `isEven : Int -> Bool` accepts it, AND `impl Parity Int` sits at its head), so BOTH readings are well-typed and exit 0 and only the VALUE separates them: the ruling says the implicit prelude is in neither half of S1`s left-operand kind partition, so the bare name is the INTERFACE METHOD and dispatch yields True; the rejected reading yields the prelude`s False. Receiver provenance is deliberately the UNGROUNDED one (a bare numeric literal, `Num a => a` at the moment the denotation is decided). 🚨 VALUE HAND-DERIVED FROM THE RULING, NOT CAPTURED: when this row was written the two arms DISAGREED here (#1497 -- run printed False, the built binary True, both exit 0, check clean), so capturing from either engine would have enshrined one reading by accident. Mechanism, established by this row`s fix: eval`s `globalNames` allocated TWO cells for the colliding name and `findCell` returned the FIRST for both installs, so the prelude group -- installed LAST -- overwrote the coalesced method dispatcher|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|True
x5_prelude_constrained_standalone_live_impl.mdk|X5 (S1-PRELUDE (a), matrix row 49) x4`s CONSTRAINED twin, and not a duplicate: prelude `count` is `Foldable t => (a -> <e> Bool) -> t a -> <e> Int`, and elaboration PREPENDS a `$dict` parameter to a `=>`-constrained prelude function, so the two rows stress the same rule against callee shapes differing by one argument. That is why the same defect presented as a SILENT wrong value at x4`s shape and as an under-applied callee (#1492: run E-PANIC `intToString: not an Int` against a built binary printing 7) at this one -- and why the arity-independence measured in #1492 was never evidence against a single mechanism. Receiver provenance is the GROUNDED complement of x4`s literal: `Box 7`. VALUE HAND-DERIVED FROM THE RULING, NOT CAPTURED|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|7
i25_importer_alias_qualified_prelude_method/main.mdk|I25 (#1684, S1 STANDALONE operand at the OCCURRENCE spelling) an ALIAS-QUALIFIED reference to an imported standalone whose bare name collides with a PRELUDE interface method, MULTI-MODULE. §1.0 scopes the standalone operand to what is defined in M or imported into M, and `import amod as A` imports it under the local name `A.shrink` -- bare `shrink` is bound by no import form here, so it names nothing in this module and shadows nothing in it. The answer 6 is HAND-DERIVED (amod`s `n + 1` at 5), not captured; `[0, 2]` is `Arbitrary.shrink`s prelude default, an interface this program declares no impl for and never mentions. 🚨 THIS ROW IS GRADED ON THE BUILT BINARY, WHICH IS THE ONLY CHANNEL THE DEFECT APPEARED ON: at base, check was clean at exit 0 and run printed 6 while the binary printed [0, 2], both exit 0, no diagnostic -- an ACCEPT/REJECT-only gate is blind to it, and grading run alone would have pinned the already-correct answer. Mechanism: private_mangle collapses BOTH spellings of the import onto the one symbol `amod__shrink`, computeMangledShadowMap recovered `amod__shrink` to bare `shrink` from amod`s funDefs, and rewriteArgScoped`s shadow-map arm then rewrote the alias-qualified occurrence as if it had been written bare|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|6
i25_importer_alias_qualified_prelude_method/bare.mdk|I25-bare: main.mdk with ONE variable changed, the import form -- and the FORK-1 control that keeps #1684`s fix from widening into every spelling. `import amod.{shrink}` DOES bind bare `shrink`, so `shrink 5` IS an S1 importer-shadow occurrence, S2`s importer arm finds the live prelude `impl Arbitrary Int` at the receiver head, and dispatch is what conformance requires. A fix that handed the alias-qualified occurrence back to the standalone by relaxing the rule for all spellings moves THIS cell too, and the everyday `import map` pattern with it (the same thing i1/i3/i4/i5 defend, at the prelude-method width). Measured UNCHANGED across the fix -- run and the built binary printed [0, 2] before it and after -- which is why the value is derived from the clause rather than read off the agreement|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[0, 2]
x6_prelude_iface_method_unit_main.mdk|X6 (#2155, S1-PRELUDE (a)) THE DECLARED-BUT-NEVER-CALLED CELL, and the corpus had none: every other prelude-collision row here (x1-x5) CALLS the colliding name, so all of them grade what a bare occurrence denotes and not one grades what merely DECLARING the method costs a module that writes no such occurrence at all. `println` is the collision and this source never applies it; main is an ordinary Unit IO action, so the answer must be identical to naming the method `printX` -- accept, print hi. MEASURED ON THE BASE BINARY (fc301229, cold-built in this worktree): `medaka check` exit 1, `No impl of Ifc for Unit` AT NO LOCATION (range 0,0, rendered as 1:0 -- the interface decl, which has nothing to do with it), and `run`/`build` the same. MECHANISM: the composite-main auto-print wrap (`main = <e>` -> `main = println <e>`) is gated on `shouldAutoPrintMain` -> `mainTypeIsUnit ()` -> `mainSchemeRef`, and on the check/LSP/playground path (diagnostics.mdk `analyzeFrom`) NOTHING had ever written that ref -- only the emit driver`s `elaborateModules` did -- so the query answered False for EVERY main and the wrap fired on a Unit one. The synthesized `println` then denotes the interface method, exactly as S1-PRELUDE (a) requires, and demands `Ifc Unit`. The wrap is INVISIBLE on an unshadowed `println` (`Display Unit` exists, the obligation discharges silently), which is why only a shadow row can see this and why x7 is pinned next to it|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|hi
x7_composite_main_autoprint_no_shadow.mdk|X7 (#2155) the CONTROL for x6 and the half a one-directional fix breaks: no interface, no shadow, a bare non-Unit VALUE main -- the cell the auto-print wrap exists FOR (COMPOSITE-MAIN-AUTOPRINT-DESIGN section 10). x6 stops the wrap firing on a Unit main; narrowing that gate one step further -- disabling the wrap on the check path, or reading main`s type from a ref still empty -- turns this row`s `(1, abc)` into an EMPTY stdout at exit 0, which no ACCEPT/REJECT column can see. Hence the value pin. `run` REJECTs BY DESIGN, not by defect (#1681: `medaka run` exits 1 whenever the W-MAIN-SHAPE warning fires, because run never applies or prints a non-Unit main and exit 0 there was indistinguishable from a clean run), so the mode is BUILD_EXACT|ACCEPT|REJECT|ACCEPT|BUILD_EXACT|(1, abc)
x8_prelude_iface_method_dispatches.mdk|X8 (#2155, S1-PRELUDE (a)) x6`s ACCEPTING-BY-DISPATCH half: `println` is declared as an interface method AND CALLED, on a receiver whose head carries a live `impl Ifc Box`. The ruling (#1499, 2026-08-10) says the implicit prelude is not an S1 left operand, so the method wins the bare name outright and `println (Box 41)` must reach THIS module`s body for 42 -- not the prelude`s `Display a => a -> <IO> Unit`. Not a duplicate of x6: x6 pins that a DECLARED-but-uncalled shadow costs nothing, this pins that a CALLED one still denotes what the ruling says. It is also the row that discriminates the fix SHAPE -- repairing x6 by making the wrap`s synthesized occurrence mean the prelude`s `println` unconditionally cannot tell its own `EVar "println"` from the one written on the last line here, so that fix moves this cell and this one goes RED. Value hand-derived from the impl body (`n + 1` at 41), not captured|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|42
i26_importer_nonzero_dispatch_idx/main.mdk|I26 (#2154, importer arms at NON-ZERO DISPATCH INDEX, mirror of D26/#1815) `mth` is IMPORTED from prov (not defined here) and shadows this module`s own `IZ.mth`, whose interface dispatches on argument 1 -- until this cell every importer fixture in this corpus dispatched on argument 0, the axis shadowStandaloneHead/inferShadowApp were blind to by construction (they peel a BARE head, the node supplying argument 0). Two denotations, both pinned by value: `mth 3 4` grounds the ungrounded literal receiver to the imported standalone`s domain, finds no `impl IZ Int`, and takes the standalone (S5): 3 * 4 = 12; `viaDict 3 (Box 4)` dispatches through the enclosing `IZ b =>` dict var (Fork-2 carve-out, live impl at Box): 700 + 3 + 4 = 707. 🚨 MEASURED ON THE BASE BINARY (1d9a6025, cold-built in this worktree, MEDAKA_STRICT=1, redirected with $? read separately): check/run/build ALL exit 1, `Type mismatch: Int vs Box` at the `viaDict` CALL SITE (not the shadowed declaration) -- `viaDict`s written signature had been silently replaced by the imported standalone`s whole declared type `Int -> Int -> Int`, exactly #2154`s reported symptom. Values hand-derived from S2/S5, not captured|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|12\n707
i26b_importer_nonzero_dispatch_idx_rename_control/main.mdk|I26b (#2154) the RENAME CONTROL for i26: the provider exports the standalone under a non-colliding name (`mthx`), so there is no shadow at all and `mth` inside `viaDict` resolves purely to the interface method at every occurrence, including the OUTER spine node (dispatch index 1) the new importer spine arm targets -- if that arm mis-fired on an ordinary, non-shadow call at nonzero dispatch index it would show up here. `mthx 3 4` is an ordinary call unrelated to any shadow machinery (12); `viaDict 3 (Box 4)` is ordinary interface dispatch with no shadow in scope (707) -- same two values as i26 by construction, since i26`s shadow-arm answers are required to agree with the unshadowed baseline at this shape|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|12\n707
i27_importer_two_admitted_disagree/main.mdk|I27 (#2188) S2-DECL (d) BULLET 3 -- TWO admitted declarations that DISAGREE, the arm that until now had NO FIXTURE ANYWHERE (S2-DECL-SCOPE says so in as many words). `IA` and `IZ` are each named in their own import clause, so S1-NS (a)`s TYPE arm admits BOTH. Their own denotations differ: `IA.mth : a -> Int -> Int` dispatches at argument 0 (head String) and `impl IA String` exists, so IA denotes that impl (55); `IZ.mth : Int -> b -> Int` dispatches at argument 1 (head Int) and no `impl IZ Int` exists anywhere, so IZ denotes the imported standalone (99). Two admitted, two denotations => a LOCATED REJECT at the occurrence, `T-AMBIGUOUS-SHADOW-DECL`. 🚨 THIS ROW PINS A VERDICT, NOT A VALUE, AND THAT IS THE STRONGER PIN HERE: at base 7e5ec5e7 this program COMPILED and printed 99 in this clause order and 55 with the two clauses swapped, on run AND on the shipped binary -- so a value pin is satisfiable by either half of an order-dependent coin flip, while `REJECT` on all three verbs in BOTH orders is not. The order-swapped row below is the S2-DECL (e) half|REJECT|REJECT|REJECT|NONE|
i27_importer_two_admitted_disagree/order-swapped.mdk|I27-swapped: byte-identical to the row above except the two interface-module import clauses are swapped. S2-DECL (e) verbatim -- a resolution rule whose answer moves when two `import` clauses are swapped is non-conformant WHATEVER value it produces, `including when the two orders differ only in accepting versus rejecting`. This ordering is the one that printed 55 at base while `main.mdk` printed 99; the pair pins that they now agree, and agree on REJECT|REJECT|REJECT|REJECT|NONE|
i28_importer_two_admitted_agree/main.mdk|I28 (#2188) S2-DECL (d) BULLET 2 -- TWO admitted declarations that AGREE, and what they agree on is the standalone. The module graph is the recovered #1664 corpus VERBATIM (`git show 23472016^:test/must_fail_fixtures/1664-decl-agreeing-both-admitted/`, drained and deleted 2026-08-29); i27 above is this same graph plus `impl IA String`, so ONE impl is the entire delta between the two cells and this row is what proves the reject is keyed on DISAGREEMENT rather than on admission COUNT. With no `impl IA String`, IA falls to the imported standalone at head String; IZ falls to it too (its receiver is argument 1, an Int, and no `impl IZ Int` exists) -- one denotation, so (d) bullet 2 ACCEPTS and the value is `fmodI.mth = 99`. ⚠️ `impl IZ String` (body 7) IS in the graph and must stay: 7 is NEITHER declaration`s denotation, so a 7 on any verb is #1664`s S2-DECL (c) violation returning, not a value drift. VALUE HAND-DERIVED from the declared signatures, and independently derived first-hand by the deleted pin`s own claim.txt|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99
i28_importer_two_admitted_agree/order-swapped.mdk|I28-swapped: the S2-DECL (e) half of the agreeing cell -- byte-identical but for the two swapped interface import clauses. An agreeing cell can hide order-dependence just as an accepting one can, so the invariance is pinned on the ACCEPT side too and not only on i27`s reject side|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|99
x9_prelude_numlit_iface_method_own_impl.mdk|X9 (#2157, S0) THE NUMERIC-LITERAL CELL of the prelude-method collision, and the corpus had none: x1-x8 all collide with a prelude name written as an IDENTIFIER, so every one of them grades what a bare occurrence denotes -- and a numeric literal mentions no identifier at all, which is precisely why no row could see this. `fromInt` is the PRELUDE `Num`s own method; declaring a user interface method of that name put a second row under the bare key `"fromInt"` in `methodIfaceParamsRef`, and `recordImplObligation`s `omLookup` (bare NAME, no interface identity, last-write-wins) then recorded EVERY numeric literals impl obligation against the USERs interface. #259 had already fixed the literals TYPE by identity (`seedNumLitFromIntScheme`); the OBLIGATION half still went through the spelling. MEASURED ON THE BASE BINARY (d5d71833, cold-built in this worktree, MEDAKA_STRICT=1): `medaka check` exit 1, `No impl of Buildable for Int` pointed at the literal `1000` -- three lines under an `impl Buildable Tag` that plainly exists. Both denotations are pinned by value so a fix that over-corrects is visible too: the ANNOTATED `fromInt 5` must still take `Buildable` (1005 = Tag (5 + 1000) unwrapped) while the bare literals take `Num` (3 = 1 + 2). Values hand-derived from the sources, not captured|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|1005\n3
x10_prelude_numlit_iface_method_declared_only.mdk|X10 (#2157) x9s WIDER-SCOPE half, and not a duplicate of it: the issue title says the defect lives in the same-named methods own impl body, and this row is what proves that framing WRONG. Here `fromInt` is only DECLARED -- no impl, no occurrence of it anywhere -- and the only arithmetic is a plain `1 + 2` in `main`. The obligation table is populated from the `interface` DECLARATION alone and read at every literal, so the misfire needs neither an impl nor a call: MEASURED ON THE BASE BINARY (d5d71833), `medaka check` exit 1 with `No impl of Buildable for Int` at the `2` of `1 + 2`. The ZERO-IMPL shape is the d1b/d19 move, deliberately: with no `impl Buildable` in the universe, an implementation that picked the literals interface correctly by consulting the impl universe rather than by declaration identity cannot pass this row. Value hand-derived (3), not captured|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3
x11_println_ordinary_redef_nonunit_main.mdk|X11 (fix round, prelude-shadow-build-agreement) `println` redefined as an ORDINARY top-level standalone (NOT an interface method), plain non-Unit IO main, NO interface anywhere -- isolates slice 3`s `mainSchemeRef` fix from the shadow-collision family entirely (x6/x7/x8 all put the collision behind an interface method). Per the packet: REJECTs at all three verbs at base (`Type mismatch: Int vs Unit`, empty `mainSchemeRef` misfiring the composite-main auto-print wrap`s `mainTypeIsUnit` check); MEASURED at sprint head (33af90fe, this worktree, MEDAKA_STRICT=1): check/run/build all ACCEPT and print `hi`|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|hi
x12_autoprint_wrap_prelude_pin.mdk|X12 (#2185, S0) the COMPILER`S OWN synthesized `println` occurrence (the auto-print wrap), not a user-written one -- x6/x8 grade a user-written bare `println`, this grades the wrap`s synthetic one under the identical shadow (`impl Ifc Int where println n = n + 1000`, bare VALUE `main = 7`). MEASURED ON THE BASE BINARY (93a40382): check/build ACCEPT, built binary prints 1007 -- the wrap silently dispatched through the module`s own impl (S0: right-looking wrong number, no diagnostic). FIXED (this slice): the wrap no longer spells `println` at all, so it is not capturable -- built binary must print 7. `run` REJECTs BY DESIGN regardless (#1681, mirrors x7/x11: a non-Unit VALUE main), graded BUILD_EXACT. Value hand-derived from the literal `main = 7`, not captured|ACCEPT|REJECT|ACCEPT|BUILD_EXACT|7
x13_autoprint_wrap_prelude_pin_noimpl.mdk|X13 (#2185, S0, packet §4b LICENSED FLIP) x12`s NO-IMPL sibling: `Ifc` declares a method literally named `println` but NO impl exists anywhere -- the unimplemented interface is otherwise wholly irrelevant (nothing calls it), the same "declared and never called costs nothing" shape x6 pins for a user occurrence. MEASURED ON THE BASE BINARY (93a40382): check/run/build ALL REJECT, `No impl of Ifc for Int`, order-invariant -- the wrap`s synthesized `println` was marked as a dispatch against this module`s `Ifc` and found no impl. FIXED (this slice, Val-licensed 2026-08-30 to flip reject -> accept): the wrap no longer spells `println`, so it cannot route through `Ifc` -- check/build must ACCEPT and the built binary must print 1. `run` REJECTs BY DESIGN regardless (#1681, mirrors x7/x11/x12: a non-Unit VALUE main) -- NOT a regression from the packet`s "run exits 0" expectation, which contradicts `run`s pre-existing, deliberate, unconditional non-Unit-main refusal (measured identically on the totally unrelated x7/x11 controls) -- graded BUILD_EXACT. Value hand-derived from the literal `main = 1`, not captured|ACCEPT|REJECT|ACCEPT|BUILD_EXACT|1'

# --- Coverage self-audit: every top-level fixture unit (a .mdk file, or a
# directory) in FIXDIR must appear in TABLE, or this gate silently re-creates
# the exact orphan-corpus problem it exists to close. ---
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
    fail=$((fail+1))
    printf 'FAIL coverage: %s exists in %s but is NOT wired into this gate'"'"'s TABLE\n' "$a" "$FIXDIR"
  fi
done
asserts=$((asserts+1))
if [ "$uncovered" -eq 0 ]; then
  pass=$((pass+1))
  printf 'ok   coverage: every fixture in %s is wired into this gate (%d units)\n' "$FIXDIR" "$(printf '%s\n' "$actual" | grep -c .)"
fi
echo

printf '%-70s %-6s %-6s %-6s %-11s %s\n' 'fixture' 'check' 'run' 'build' 'value' 'result'
printf '%-70s %-6s %-6s %-6s %-11s %s\n' '----------------------------------------------------------------------' '------' '------' '------' '-----------' '------'

printf '%s\n' "$TABLE" | while IFS='|' read -r entry label exp_check exp_run exp_build mode value; do
  [ -z "$entry" ] && continue
  entrypath="$FIXDIR/$entry"
  base="$(printf '%s' "$entry" | sed 's#/main\.mdk$##' | tr '/' '_')"

  if [ ! -f "$entrypath" ]; then
    printf '%-70s %s\n' "$entry" 'FAIL MISSING FIXTURE FILE'
    echo "FAIL" >> "$TMP/verdicts"
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
    bin_code=$?
  else
    build_v='REJECT'
    : >"$TMP/$base.build.out"
    bin_code=0
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
        printf '%b\n' "$value" > "$TMP/$base.expected"
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
        printf '%b\n' "$value" > "$TMP/$base.expected"
        if cmp -s "$TMP/$base.build.out" "$TMP/$base.expected"; then
          value_v='ok'
        else
          value_v='WRONG'
          row_ok=0
        fi
      else
        value_v='n/a'
      fi
      ;;
    BUILD_CRASH)
      # KNOWN-BAD ledger cell, NOT a skip: `build` exits 0 and ships a binary
      # that CRASHES with the SPECIFIC pinned signature -- exit 139 (the
      # runtime's SIGSEGV/SIGBUS fault handler calls `_exit(139)` explicitly,
      # runtime/medaka_rt.c's mdk_chain_previous -- deterministic on both
      # Linux and macOS since it's an explicit exit code in our own C, not the
      # shell's raw signal-death convention) AND stderr carries
      # `E-FATAL-SIGNAL` -- while `run` prints the correct `value`.
      #
      # #463: an exit-code-only check (`bin_code != 0`) absorbs ANY future
      # crash into "still correctly broken" as long as run's stdout still
      # matches -- a SECOND, unrelated crash could hide in this cell forever.
      # Pinning the exact code AND the stderr signature closes that: a crash
      # for a DIFFERENT reason (different code, or 139 with different stderr,
      # e.g. a stack overflow's E-STACK-OVERFLOW/134) now FAILS this row
      # instead of being absorbed as "ok".
      #
      # Asserting the crash signature, run's value, AND (implicitly, via
      # NO-CRASH-FIXED) the eventual fix is what makes this self-draining: the
      # day the underlying bug is fixed the binary stops crashing, this row
      # goes RED, and whoever fixed it MUST come here and re-pin the cell to
      # ALL_EXACT. A `NONE` row would have silently absorbed the fix and
      # taught nobody.
      if [ "$build_v" = 'ACCEPT' ]; then
        printf '%b\n' "$value" > "$TMP/$base.expected"
        if [ "$bin_code" -eq 0 ]; then
          value_v='NO-CRASH-FIXED'   # <-- the drain fired: re-pin this row
          row_ok=0
        elif [ "$bin_code" -ne 139 ]; then
          value_v="WRONG-CRASH-CODE:$bin_code"   # crashed, but NOT the pinned way
          row_ok=0
        elif ! grep -q 'E-FATAL-SIGNAL' "$TMP/$base.build.runerr" 2>/dev/null; then
          value_v='WRONG-CRASH-SIG'   # exit 139 but not our fault handler's signature
          row_ok=0
        elif cmp -s "$TMP/$base.run.out" "$TMP/$base.expected"; then
          value_v="ok(crash:$bin_code)"
        else
          value_v='RUN-DIFF'
          row_ok=0
        fi
      else
        value_v='n/a'
      fi
      ;;
    BUILD_NOTEQ_INT)
      if [ "$build_v" = 'ACCEPT' ]; then
        got="$(tr -d '[:space:]' < "$TMP/$base.build.out")"
        case "$got" in
          ''|*[!0-9]*)
            value_v='NOTINT'
            row_ok=0
            ;;
          "$value")
            value_v='EQ-WANT-NE'
            row_ok=0
            ;;
          *)
            value_v='ok(garbage)'
            ;;
        esac
      else
        value_v='n/a'
      fi
      ;;
  esac

  if [ "$row_ok" -eq 1 ]; then
    result='PASS'
    echo "PASS" >> "$TMP/verdicts"
  else
    result='FAIL'
    echo "FAIL" >> "$TMP/verdicts"
  fi
  printf '%-70s %-6s %-6s %-6s %-11s %s\n' "$entry" "$check_v" "$run_v" "$build_v" "$value_v" "$result"
done

# The `printf | while read` above runs in dash/ash as a subshell of the
# pipeline (POSIX allows this; dash actually does fork the last stage of a
# pipe), so pass/fail/asserts mutated INSIDE that loop would NOT survive to
# here. We therefore tally the real per-row verdicts from $TMP/verdicts
# (written from inside the loop, which DOES survive since it's a file, not a
# shell variable) rather than trusting variables mutated in the subshell.
if [ -f "$TMP/verdicts" ]; then
  row_pass="$(grep -c '^PASS$' "$TMP/verdicts")"
  row_fail="$(grep -c '^FAIL$' "$TMP/verdicts")"
else
  row_pass=0
  row_fail=0
fi
pass=$((pass+row_pass))
fail=$((fail+row_fail))
asserts=$((asserts+row_pass+row_fail))

echo
printf '%s: %d passed, %d failed (%d assertions)\n' "$(basename "$0")" "$pass" "$fail" "$asserts"
[ "$fail" -eq 0 ]
