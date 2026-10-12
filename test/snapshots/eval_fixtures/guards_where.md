# META
source_lines=12
stages=CORE_IR
# SOURCE
-- function guards + where-clause local bindings
classify n
  | n < 0 = "neg"
  | n == 0 = "zero"
  | otherwise = "pos"
hypotSq a b = sq a + sq b
  where
    sq x = x * x
fib n
  | n < 2 = n
  | otherwise = fib (n - 1) + fib (n - 2)
main = (classify (0 - 5), classify 0, classify 9, hypotSq 3 4, fib 10)
# CORE_IR
(CProgram ((CBind "classify" (CClause ((PVar "n")) (CIf (CBinPrim "<" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CLit (LString "neg")) (CIf (CBinPrim "==" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CLit (LString "zero")) (CIf (CVar "otherwise" AGlobal) (CLit (LString "pos")) (CApp (CVar "__fallthrough__" AGlobal) ((CLit LUnit)) CallDynamic true))))))
(CBind "hypotSq" (CClause ((PVar "a") (PVar "b")) (CLetGroup ((CBind "sq" (CClause ((PVar "x")) (CBinPrim "*" (CVar "x" (ALocal 0 0)) (CVar "x" (ALocal 0 0)))))) (CBinPrim "+" (CApp (CVar "sq" (ALocal 0 0)) ((CVar "a" (ALocal 2 0))) CallExact false) (CApp (CVar "sq" (ALocal 0 0)) ((CVar "b" (ALocal 1 0))) CallExact false)))))
(CBind "fib" (CClause ((PVar "n")) (CIf (CBinPrim "<" (CVar "n" (ALocal 0 0)) (CLit (LInt 2))) (CVar "n" (ALocal 0 0)) (CIf (CVar "otherwise" AGlobal) (CBinPrim "+" (CApp (CVar "fib" AGlobal) ((CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1)))) CallExact false) (CApp (CVar "fib" AGlobal) ((CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 2)))) CallExact false)) (CApp (CVar "__fallthrough__" AGlobal) ((CLit LUnit)) CallDynamic true)))))
(CBind "main" (CClause () (CTuple (CApp (CVar "classify" AGlobal) ((CBinPrim "-" (CLit (LInt 0)) (CLit (LInt 5)))) CallExact false) (CApp (CVar "classify" AGlobal) ((CLit (LInt 0))) CallExact false) (CApp (CVar "classify" AGlobal) ((CLit (LInt 9))) CallExact false) (CApp (CVar "hypotSq" AGlobal) ((CLit (LInt 3)) (CLit (LInt 4))) CallExact false) (CApp (CVar "fib" AGlobal) ((CLit (LInt 10))) CallExact false))))) () () () () (facts () ()) (binder-types
(b 0 "" "n" RTValue)
(b 1 "" "a" RTValue)
(b 2 "" "b" RTValue)
(b 3 "" "x" RTValue)
(b 4 "" "n" RTValue)
(b 5 "" "classify" RTValue RTValue)
(b 6 "" "sq" RTValue RTValue)
(b 7 "" "hypotSq" RTValue RTValue)
(b 8 "" "fib" RTValue RTValue)
(b 9 "" "main" RTValue RTValue)))
