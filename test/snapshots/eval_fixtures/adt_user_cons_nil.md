# META
source_lines=22
stages=CORE_IR
# SOURCE
-- REGRESSION GUARD: user constructors literally named `Cons`/`Nil` (the names
-- the built-in list syntax canonicalises to).  BEFORE the decodeHead reserved-
-- name fix this PANICKED ceval ("no matching clause in match"): decodeHead keyed
-- the built-in list heads by the user-facing names, so `data T = Cons … | Nil`
-- lowered its arms to the built-in HCons/HNil heads, whose headExtract probes a
-- VList shape against the actual VCon "Cons"/"Nil" value and falls through to
-- CTFail.  The AST tree-walker ran it correctly the whole time, so this fixture
-- is byte-identical across the tree-walker, ceval, the bytecode VM, and the LLVM
-- spike only once the built-in heads key off RESERVED synthetic names instead.
data T = Cons Int T | Nil

sumT lst = match lst
  Cons x xs => x + sumT xs
  Nil => 0

lenT lst = match lst
  Cons _ xs => 1 + lenT xs
  Nil => 0

main =
  let xs = Cons 10 (Cons 20 (Cons 30 Nil))
  (sumT xs, lenT xs, sumT Nil)
# CORE_IR
(CProgram ((CBind "sumT" (CClause ((PVar "lst")) (CDecision (CVar "lst" (ALocal 0 0)) ((arm (PCon "Cons" (PVar "x") (PVar "xs")) () (CBinPrim "+" (CVar "x" (ALocal 0 0)) (CApp (CVar "sumT" AGlobal) ((CVar "xs" (ALocal 0 1))) CallExact false))) (arm (PCon "Nil") () (CLit (LInt 0)))) (CTSwitch ((CTBranch (HCon "Cons" 2) (CTLeaf 0)) (CTBranch (HCon "Nil" 0) (CTLeaf 1))) CTFail))))
(CBind "lenT" (CClause ((PVar "lst")) (CDecision (CVar "lst" (ALocal 0 0)) ((arm (PCon "Cons" PWild (PVar "xs")) () (CBinPrim "+" (CLit (LInt 1)) (CApp (CVar "lenT" AGlobal) ((CVar "xs" (ALocal 0 0))) CallExact false))) (arm (PCon "Nil") () (CLit (LInt 0)))) (CTSwitch ((CTBranch (HCon "Cons" 2) (CTLeaf 0)) (CTBranch (HCon "Nil" 0) (CTLeaf 1))) CTFail))))
(CBind "main" (CClause () (CBlock (CSLet false (PVar "xs") (CApp (CVar "Cons" AGlobal) ((CLit (LInt 10)) (CApp (CVar "Cons" AGlobal) ((CLit (LInt 20)) (CApp (CVar "Cons" AGlobal) ((CLit (LInt 30)) (CVar "Nil" AGlobal)) CallExact false)) CallExact false)) CallExact false)) (CSExpr (CTuple (CApp (CVar "sumT" AGlobal) ((CVar "xs" (ALocal 0 0))) CallExact false) (CApp (CVar "lenT" AGlobal) ((CVar "xs" (ALocal 0 0))) CallExact false) (CApp (CVar "sumT" AGlobal) ((CVar "Nil" AGlobal)) CallExact false))))))) ((ca "Cons" 2) (ca "Nil" 0)) ((ct "Cons" "T") (ct "Nil" "T")) () () (facts () () () none (externs) (manifests) (origins ((function "lenT" (single "lenT")) (function "main" (single "main")) (function "sumT" (single "sumT"))) ((owner "T" ((constructor "Cons" (single "Cons")) (constructor "Nil" (single "Nil"))))))) (binder-types
(b 0 "" "lst" RTValue)
(b 1 "" "x" RTValue)
(b 2 "" "xs" RTValue)
(b 3 "" "lst" RTValue)
(b 4 "" "xs" RTValue)
(b 5 "" "xs" RTValue)
(b 6 "" "sumT" RTValue RTValue)
(b 7 "" "lenT" RTValue RTValue)
(b 8 "" "main" RTValue RTValue)))
