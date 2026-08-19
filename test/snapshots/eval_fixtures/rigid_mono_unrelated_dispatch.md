# META
source_lines=77
stages=CORE_IR
# SOURCE
-- #1110 ARCH A-1 PR A: `Mono.TRigid`, the rigid type-variable constructor split
-- out of `Mono.TCon` (compiler/types/typecheck.mdk).
--
-- 🚨 THIS CORPUS IS TYPECHECK-FREE, SO THIS FIXTURE REACHES NO `Mono` CODE AT ALL.
-- Verified, not assumed — all five consumers stop before `types/typecheck.mdk`:
--   compiler/entries/eval_main.mdk:19   evalMain (desugar (parse src))
--   compiler/entries/core_ir_main.mdk:33
--   compiler/entries/core_ir_roundtrip_main.mdk:28
--                                       lowerProgram (annotateProgram (desugar (parse src)))
--   compiler/tools/snapshot.mdk:588     cprogramToSexp (lowerProgram (annotateProgram d))
-- None imports `types.typecheck`; `types/annotate.mdk`, `ir/core_ir_lower.mdk`,
-- `ir/core_ir_eval.mdk` and `eval/eval.mdk` have ZERO word-bounded `Mono` hits;
-- and this fixture's own snapshot header reads `stages=CORE_IR` with no TYPES
-- section.  So NO `Mono` is constructed, no rigid is minted, `ppGo` is never
-- called, and NONE of the 21 `TRigid` arms is exercised here.
--
-- 🚨 WHAT THIS FIXTURE ACTUALLY PINS, then — and nothing more: that a
-- `data D = D { slot : q }` declaration carrying an unbound type variable does
-- not perturb PARSE → DESUGAR → ANNOTATE → LOWER → EVAL for the ordinary,
-- concrete code beside it.  That is a real property (a new declaration shape
-- must not move an unrelated dispatch answer on the untyped engines) and it is
-- what the four goldens grade.  It is NOT coverage of the `Mono` split.
--
-- ⚠️ Twice now this header claimed more than had been run — first that it caught
-- a swallowed dispatch key, then that it walked the eleven exhaustive `Mono`
-- matches.  Both were false for the same reason, and a probe showing this file
-- stays green when `headTyconMono`'s arm is deleted was read as evidence for the
-- narrower claim when it supported the wider one.  Claim only what you ran.
--
-- ALL `Mono`-arm coverage lives elsewhere:
--   test/typecheck_error_fixtures/rigid_mono_head_key.mdk
--     the goal-side dispatch key (`headTyconMono`); positive-controlled — deleting
--     that arm makes the program silently ACCEPT, and the fixture fails.
--   test/must_fail_fixtures/1243-rigid-forges-builtin-tuple-head/
--     the seven cross-population arms; positive-controlled — deleting `unifyN`'s
--     two makes the pin DRAIN.
--
-- ⚠️ COUPLED TO #1240 (`data Holder = Holder { slot : q }` — an unbound type
-- variable in a constructor field type is accepted with NO diagnostic).  The
-- `data Holder` line below is verbatim #1240's repro.  When #1240 is fixed this
-- file becomes a compile error and reds FIVE gates: bootstrap_eval,
-- diff_compiler_eval, diff_compiler_core_ir, diff_compiler_core_ir_roundtrip and
-- diff_compiler_snapshot_core_ir.  Whoever fixes #1240 meets that red here first:
-- either drop the `Holder` declaration (the rest of the fixture stands alone) or
-- retire this file — the two fixtures named above carry the `Mono` coverage.
--
-- Expected value derived by hand BEFORE running anything (AGENTS.md: a captured
-- golden records what the engine did, not what is correct):
--   tag (Bead 4)   -> "bead"    · size (Bead 4)   -> 4
--   tag (Strand 3) -> "strand"  · size (Strand 3) -> 3 * 10 = 30
--   both (Bead 4)  -> "bead" ++ "/" ++ "4"  -> "bead/4"
--   total          -> 4 + 30 = 34
--   the tuple      -> (bead, 34, bead/4, strand/30)

data Holder = Holder { slot : q }

interface Bit a where
  tag : a -> String
  size : a -> Int

data Bead = Bead Int

data Strand = Strand Int

impl Bit Bead where
  tag _ = "bead"
  size (Bead n) = n

impl Bit Strand where
  tag _ = "strand"
  size (Strand n) = n * 10

both b = tag b ++ "/" ++ intToString (size b)

total = size (Bead 4) + size (Strand 3)

main = (tag (Bead 4), total, both (Bead 4), both (Strand 3))
# CORE_IR
(CProgram ((CBind "both" (CClause ((PVar "b")) (CBinPrim "++" (CBinPrim "++" (CApp (CVar "tag" AGlobal) (CVar "b" (ALocal 0 0))) (CLit (LString "/"))) (CApp (CVar "intToString" AGlobal) (CApp (CVar "size" AGlobal) (CVar "b" (ALocal 0 0)))))))
(CBind "total" (CClause () (CBinPrim "+" (CApp (CVar "size" AGlobal) (CApp (CVar "Bead" AGlobal) (CLit (LInt 4)))) (CApp (CVar "size" AGlobal) (CApp (CVar "Strand" AGlobal) (CLit (LInt 3)))))))
(CBind "main" (CClause () (CTuple (CApp (CVar "tag" AGlobal) (CApp (CVar "Bead" AGlobal) (CLit (LInt 4)))) (CVar "total" AGlobal) (CApp (CVar "both" AGlobal) (CApp (CVar "Bead" AGlobal) (CLit (LInt 4)))) (CApp (CVar "both" AGlobal) (CApp (CVar "Strand" AGlobal) (CLit (LInt 3)))))))) ((ca "Holder" 1) (ca "Bead" 1) (ca "Strand" 1)) ((ct "Holder" "Holder") (ct "Bead" "Bead") (ct "Strand" "Strand")) ((CImplEntry "tag" 0 (CImplTagged "Bead" "Bit|Bead|" "Bit" (0) (PWild) (CLit (LString "bead")))) (CImplEntry "size" 0 (CImplTagged "Bead" "Bit|Bead|" "Bit" (0) ((PCon "Bead" (PVar "n"))) (CVar "n" (ALocal 0 0)))) (CImplEntry "tag" 0 (CImplTagged "Strand" "Bit|Strand|" "Bit" (0) (PWild) (CLit (LString "strand")))) (CImplEntry "size" 0 (CImplTagged "Strand" "Bit|Strand|" "Bit" (0) ((PCon "Strand" (PVar "n"))) (CBinPrim "*" (CVar "n" (ALocal 0 0)) (CLit (LInt 10)))))))
