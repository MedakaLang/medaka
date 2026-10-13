# META
source_lines=21
stages=CORE_IR
# SOURCE
-- Effect-polymorphism erasure (STAGE2-DESIGN §2.3).  `runTwice`'s effect row `e`
-- is a quantified VARIABLE — instantiated to distinct rows at distinct call sites
-- (the Ref-mutating `bump` vs the pure `square`).  After
-- erasure both instantiations flow through the SAME combinator code: effects
-- carry no runtime witness, so an effect-polymorphic function is represented
-- identically to a monomorphic one.  Diffed against the tree-walker by eval /
-- core_ir / eval_bytecode harnesses — all three must agree, proving erasure is
-- semantics-preserving across the AST walker, the Core IR evaluator, and the VM.
runTwice : (a -> <e> a) -> a -> <e> a
runTwice f x = f (f x)

bump r u =
  let _ = setRef r (r.value + 1)
  r.value

square x = x * x

main =
  let r = Ref 7
  -- Ref-mutating instantiation vs pure instantiation (e = {})
  (runTwice (bump r) 0, runTwice square 3, r.value)
# CORE_IR
(CProgram ((CBind "runTwice" (CClause ((PVar "f") (PVar "x")) (CApp (CVar "f" (ALocal 1 0)) ((CApp (CVar "f" (ALocal 1 0)) ((CVar "x" (ALocal 0 0))) CallDynamic false)) CallDynamic true)))
(CBind "bump" (CClause ((PVar "r") (PVar "u")) (CBlock (CSLet false PWild (CApp (CVar "setRef" AGlobal) ((CVar "r" (ALocal 1 0)) (CBinPrim "+" (CFieldAccess (CVar "r" (ALocal 1 0)) "value" "" -1) (CLit (LInt 1)))) CallDynamic false)) (CSExpr (CFieldAccess (CVar "r" (ALocal 2 0)) "value" "" -1)))))
(CBind "square" (CClause ((PVar "x")) (CBinPrim "*" (CVar "x" (ALocal 0 0)) (CVar "x" (ALocal 0 0)))))
(CBind "main" (CClause () (CBlock (CSLet false (PVar "r") (CApp (CVar "Ref" AGlobal) ((CLit (LInt 7))) CallDynamic false)) (CSExpr (CTuple (CApp (CVar "runTwice" AGlobal) ((CApp (CVar "bump" AGlobal) ((CVar "r" (ALocal 0 0))) (CallPartial 1) false) (CLit (LInt 0))) CallExact false) (CApp (CVar "runTwice" AGlobal) ((CVar "square" AGlobal) (CLit (LInt 3))) CallExact false) (CFieldAccess (CVar "r" (ALocal 0 0)) "value" "" -1))))))) () () () () (facts () ()) (binder-types
(b 0 "" "f" RTValue)
(b 1 "" "x" RTValue)
(b 2 "" "r" RTValue)
(b 3 "" "u" RTValue)
(b 4 "" "x" RTValue)
(b 5 "" "r" RTValue)
(b 6 "" "runTwice" RTValue RTValue)
(b 7 "" "bump" RTValue RTValue)
(b 8 "" "square" RTValue RTValue)
(b 9 "" "main" RTValue RTValue)))
