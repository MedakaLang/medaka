# META
source_lines=11
stages=CORE_IR
# SOURCE
-- lexical scoping, shadowing, closures capturing locals, nested lambdas
makeAdder n = (m => n + m)
twice f = (x => f (f x))
counter start =
  let step = (n => n + 1)
  step (step start)
shadowTest x =
  let x = x + 100
  let y = (x => x * 2)
  (x, y 5)
main = (makeAdder 10 5, twice (makeAdder 3) 0, counter 40, shadowTest 1)
# CORE_IR
(CProgram ((CBind "makeAdder" (CClause ((PVar "n")) (CLam ((PVar "m")) (CBinPrim "+" (CVar "n" (ALocal 1 0)) (CVar "m" (ALocal 0 0))))))
(CBind "twice" (CClause ((PVar "f")) (CLam ((PVar "x")) (CApp (CVar "f" (ALocal 1 0)) ((CApp (CVar "f" (ALocal 1 0)) ((CVar "x" (ALocal 0 0))) CallDynamic false)) CallDynamic true))))
(CBind "counter" (CClause ((PVar "start")) (CBlock (CSLet false (PVar "step") (CLam ((PVar "n")) (CBinPrim "+" (CVar "n" (ALocal 0 0)) (CLit (LInt 1))))) (CSExpr (CApp (CVar "step" (ALocal 0 0)) ((CApp (CVar "step" (ALocal 0 0)) ((CVar "start" (ALocal 1 0))) CallExact false)) CallExact true)))))
(CBind "shadowTest" (CClause ((PVar "x")) (CBlock (CSLet false (PVar "x") (CBinPrim "+" (CVar "x" (ALocal 0 0)) (CLit (LInt 100)))) (CSLet false (PVar "y") (CLam ((PVar "x")) (CBinPrim "*" (CVar "x" (ALocal 0 0)) (CLit (LInt 2))))) (CSExpr (CTuple (CVar "x" (ALocal 1 0)) (CApp (CVar "y" (ALocal 0 0)) ((CLit (LInt 5))) CallExact false))))))
(CBind "main" (CClause () (CTuple (CApp (CVar "makeAdder" AGlobal) ((CLit (LInt 10)) (CLit (LInt 5))) (CallOver 1) false) (CApp (CVar "twice" AGlobal) ((CApp (CVar "makeAdder" AGlobal) ((CLit (LInt 3))) CallExact false) (CLit (LInt 0))) (CallOver 1) false) (CApp (CVar "counter" AGlobal) ((CLit (LInt 40))) CallExact false) (CApp (CVar "shadowTest" AGlobal) ((CLit (LInt 1))) CallExact false))))) () () () () (facts () () () none (externs) (manifests) (origins ((function "counter" (single "counter")) (function "main" (single "main")) (function "makeAdder" (single "makeAdder")) (function "shadowTest" (single "shadowTest")) (function "twice" (single "twice"))) ())) (binder-types
(b 0 "" "n" RTValue)
(b 1 "" "m" RTValue)
(b 2 "" "f" RTValue)
(b 3 "" "x" RTValue)
(b 4 "" "start" RTValue)
(b 5 "" "step" RTValue)
(b 6 "" "n" RTValue)
(b 7 "" "x" RTValue)
(b 8 "" "x" RTValue)
(b 9 "" "y" RTValue)
(b 10 "" "x" RTValue)
(b 11 "" "makeAdder" RTValue RTValue)
(b 12 "" "twice" RTValue RTValue)
(b 13 "" "counter" RTValue RTValue)
(b 14 "" "shadowTest" RTValue RTValue)
(b 15 "" "main" RTValue RTValue)))
