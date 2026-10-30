# META
source_lines=17
stages=CORE_IR
# SOURCE
-- explicit Refs (Ref / setRef / .value) + pure recursive accumulation
countUp n =
  let r = Ref 0
  let _ = bump r n
  r.value
bump r 0 = r.value
bump r k =
  let _ = setRef r (r.value + 1)
  bump r (k - 1)
sumTo n = loop 0 1 n
loop acc i n
  | i > n = acc
  | otherwise = loop (acc + i) (i + 1) n
main =
  let r = Ref 41
  let _ = setRef r (r.value + 1)
  (r.value, r, countUp 5, sumTo 10)
# CORE_IR
(CProgram ((CBind "countUp" (CClause ((PVar "n")) (CBlock (CSLet false (PVar "r") (CApp (CVar "Ref" AGlobal) ((CLit (LInt 0))) CallDynamic false)) (CSLet false PWild (CApp (CVar "bump" AGlobal) ((CVar "r" (ALocal 0 0)) (CVar "n" (ALocal 1 0))) CallExact false)) (CSExpr (CFieldAccess (CVar "r" (ALocal 1 0)) "value" "" -1)))))
(CBind "bump" (CClause ((PVar "r") (PLit (LInt 0))) (CFieldAccess (CVar "r" (ALocal 1 0)) "value" "" -1)) (CClause ((PVar "r") (PVar "k")) (CBlock (CSLet false PWild (CApp (CVar "setRef" AGlobal) ((CVar "r" (ALocal 1 0)) (CBinPrim "+" (CFieldAccess (CVar "r" (ALocal 1 0)) "value" "" -1) (CLit (LInt 1)))) CallDynamic false)) (CSExpr (CApp (CVar "bump" AGlobal) ((CVar "r" (ALocal 2 0)) (CBinPrim "-" (CVar "k" (ALocal 1 0)) (CLit (LInt 1)))) CallExact true)))))
(CBind "sumTo" (CClause ((PVar "n")) (CApp (CVar "loop" AGlobal) ((CLit (LInt 0)) (CLit (LInt 1)) (CVar "n" (ALocal 0 0))) CallExact true)))
(CBind "loop" (CClause ((PVar "acc") (PVar "i") (PVar "n")) (CIf (CBinPrim ">" (CVar "i" (ALocal 1 0)) (CVar "n" (ALocal 0 0))) (CVar "acc" (ALocal 2 0)) (CIf (CVar "otherwise" AGlobal) (CApp (CVar "loop" AGlobal) ((CBinPrim "+" (CVar "acc" (ALocal 2 0)) (CVar "i" (ALocal 1 0))) (CBinPrim "+" (CVar "i" (ALocal 1 0)) (CLit (LInt 1))) (CVar "n" (ALocal 0 0))) CallExact true) (CApp (CVar "__fallthrough__" AGlobal) ((CLit LUnit)) CallDynamic true)))))
(CBind "main" (CClause () (CBlock (CSLet false (PVar "r") (CApp (CVar "Ref" AGlobal) ((CLit (LInt 41))) CallDynamic false)) (CSLet false PWild (CApp (CVar "setRef" AGlobal) ((CVar "r" (ALocal 0 0)) (CBinPrim "+" (CFieldAccess (CVar "r" (ALocal 0 0)) "value" "" -1) (CLit (LInt 1)))) CallDynamic false)) (CSExpr (CTuple (CFieldAccess (CVar "r" (ALocal 1 0)) "value" "" -1) (CVar "r" (ALocal 1 0)) (CApp (CVar "countUp" AGlobal) ((CLit (LInt 5))) CallExact false) (CApp (CVar "sumTo" AGlobal) ((CLit (LInt 10))) CallExact false))))))) () () () () (facts () () () none (externs) (manifests) (origins ((function "bump" (single "bump")) (function "countUp" (single "countUp")) (function "loop" (single "loop")) (function "main" (single "main")) (function "sumTo" (single "sumTo"))) ())) (binder-types
(b 0 "" "n" RTValue)
(b 1 "" "r" RTValue)
(b 2 "" "r" RTValue)
(b 3 "" "r" RTValue)
(b 4 "" "k" RTValue)
(b 5 "" "n" RTValue)
(b 6 "" "acc" RTValue)
(b 7 "" "i" RTValue)
(b 8 "" "n" RTValue)
(b 9 "" "r" RTValue)
(b 10 "" "countUp" RTValue RTValue)
(b 11 "" "bump" RTValue RTValue)
(b 12 "" "sumTo" RTValue RTValue)
(b 13 "" "loop" RTValue RTValue)
(b 14 "" "main" RTValue RTValue)))
