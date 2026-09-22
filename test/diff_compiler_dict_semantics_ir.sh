#!/bin/sh
# DICT-SEMANTICS section 3 -- EMITTED LLVM IR (docs/spec/DICT-SEMANTICS.md).
#
# `medaka build --keep-ir` over a fixture, and a pinned extended-regex over the
# `.ll` it leaves behind. This is the only section of the conformance suite that
# can see a DEAD DICT SLOT (#607) or an arity skew (§8 I1) -- both invisible from
# behaviour alone -- and it is what turned "I think the wrong impl is selected"
# into `call @mdk_impl_Box_tag` on the screen.
#
# The corpus, the discipline every row pins under, the KNOWN-DIVERGENCE ledger
# and the NOT-YET-COVERED punch-list are shared with the two other gates that
# read `test/dict_fixtures`, and live in `test/dict_fixtures/README.md`. Read it
# before adding, re-pinning or draining a row here. The section numbering it
# records is the numbering this file is section 3 of.
#
# The registry entry says `migration = "native-rewrite"`: that is where this
# check is going, not something it could do today. The port needs a precedented
# native way to read a `--keep-ir` `.ll` back off disk and grade a pattern over
# it, and no test module in this tree does that yet. Building that seam here
# rather than in the test library is the shape epic #2600 exists to stop, so the
# rewrite waits for the first module that needs it for its own sake.
#
# Usage:  sh test/diff_compiler_dict_semantics_ir.sh

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
: >"$TMP/v3"

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

# ── Tally ────────────────────────────────────────────────────────────────────
# The `printf | while read` loop above runs in a SUBSHELL under dash/ash (POSIX
# permits it and dash does fork the last pipeline stage), so shell variables
# mutated inside it do not survive. Every verdict is therefore appended to a
# FILE, which does, and the totals are derived from that -- never from a
# variable, and never from an exit code.
cnt() { c="$(grep -c "^$2\$" "$TMP/$1" 2>/dev/null || true)"; [ -n "$c" ] || c=0; echo "$c"; }
p3="$(cnt v3 PASS)"; f3="$(cnt v3 FAIL)"
n3=$((p3+f3))

echo
printf '%s: checked %d assertions -- %d passed, %d failed\n' "$(basename "$0")" "$n3" "$p3" "$f3"
printf '  emitted-IR %d\n' "$n3"

# ⚠️ AN EMPTY SECTION IS A FAILURE, NOT A PASS. Three gates in this tree once
# shelled out to a tool that was not installed, printed `skipping`, and exited 0
# -- so a required tandem gate had never once executed on that machine. "Green"
# is not "ran", and a gate that can silently no-op will. Deleting or commenting
# out the table above must RED this gate, not shrink it quietly.
[ "$n3" -eq 0 ] && { echo "FAIL: section 3 (emitted IR) made ZERO assertions -- it did not run." >&2; exit 1; }

[ "$f3" -eq 0 ]
