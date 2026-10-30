# META
source_lines=12
stages=CORE_IR
# SOURCE
-- higher-order functions, closures, composition, pipe, sections
add x y = x + y
double = (2 * _)
inc = add 1
applyTwice f x = f (f x)
mapL f [] = []
mapL f (x :: xs) = f x :: mapL f xs
foldlL f acc [] = acc
foldlL f acc (x :: xs) = foldlL f (f acc x) xs
sumL = foldlL add 0
compd = (double >> inc)
main = (applyTwice double 3, mapL inc [1, 2, 3], sumL [1, 2, 3, 4], compd 5, 10 |> inc |> double)
# CORE_IR
(CProgram ((CBind "add" (CClause ((PVar "x") (PVar "y")) (CBinPrim "+" (CVar "x" (ALocal 1 0)) (CVar "y" (ALocal 0 0)))))
(CBind "double" (CClause () (CLam ((PVar "_s")) (CBinPrim "*" (CLit (LInt 2)) (CVar "_s" (ALocal 0 0))))))
(CBind "inc" (CClause () (CApp (CVar "add" AGlobal) ((CLit (LInt 1))) (CallPartial 1) false)))
(CBind "applyTwice" (CClause ((PVar "f") (PVar "x")) (CApp (CVar "f" (ALocal 1 0)) ((CApp (CVar "f" (ALocal 1 0)) ((CVar "x" (ALocal 0 0))) CallDynamic false)) CallDynamic true)))
(CBind "mapL" (CClause ((PVar "f") (PList)) (CList)) (CClause ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (CBinPrim "::" (CApp (CVar "f" (ALocal 1 0)) ((CVar "x" (ALocal 0 0))) CallDynamic false) (CApp (CVar "mapL" AGlobal) ((CVar "f" (ALocal 1 0)) (CVar "xs" (ALocal 0 1))) CallExact false))))
(CBind "foldlL" (CClause ((PVar "f") (PVar "acc") (PList)) (CVar "acc" (ALocal 1 0))) (CClause ((PVar "f") (PVar "acc") (PCons (PVar "x") (PVar "xs"))) (CApp (CVar "foldlL" AGlobal) ((CVar "f" (ALocal 2 0)) (CApp (CVar "f" (ALocal 2 0)) ((CVar "acc" (ALocal 1 0)) (CVar "x" (ALocal 0 0))) CallDynamic false) (CVar "xs" (ALocal 0 1))) CallExact true)))
(CBind "sumL" (CClause () (CApp (CVar "foldlL" AGlobal) ((CVar "add" AGlobal) (CLit (LInt 0))) (CallPartial 1) false)))
(CBind "compd" (CClause () (CLam ((PVar "$cf")) (CApp (CVar "inc" AGlobal) ((CApp (CVar "double" AGlobal) ((CVar "$cf" AGlobal)) (CallOver 1) false)) (CallOver 1) true))))
(CBind "main" (CClause () (CTuple (CApp (CVar "applyTwice" AGlobal) ((CVar "double" AGlobal) (CLit (LInt 3))) CallExact false) (CApp (CVar "mapL" AGlobal) ((CVar "inc" AGlobal) (CList (CLit (LInt 1)) (CLit (LInt 2)) (CLit (LInt 3)))) CallExact false) (CApp (CVar "sumL" AGlobal) ((CList (CLit (LInt 1)) (CLit (LInt 2)) (CLit (LInt 3)) (CLit (LInt 4)))) (CallOver 1) false) (CApp (CVar "compd" AGlobal) ((CLit (LInt 5))) (CallOver 1) false) (CApp (CVar "double" AGlobal) ((CApp (CVar "inc" AGlobal) ((CLit (LInt 10))) (CallOver 1) false)) (CallOver 1) false))))) () () () () (facts () () () none (externs) (manifests) (origins ((function "add" (single "add")) (function "applyTwice" (single "applyTwice")) (function "compd" (single "compd")) (function "double" (single "double")) (function "foldlL" (single "foldlL")) (function "inc" (single "inc")) (function "main" (single "main")) (function "mapL" (single "mapL")) (function "sumL" (single "sumL"))) ())) (binder-types
(b 0 "" "x" RTValue)
(b 1 "" "y" RTValue)
(b 2 "" "_s" RTValue)
(b 3 "" "f" RTValue)
(b 4 "" "x" RTValue)
(b 5 "" "f" RTValue)
(b 6 "" "f" RTValue)
(b 7 "" "x" RTValue)
(b 8 "" "xs" RTValue)
(b 9 "" "f" RTValue)
(b 10 "" "acc" RTValue)
(b 11 "" "f" RTValue)
(b 12 "" "acc" RTValue)
(b 13 "" "x" RTValue)
(b 14 "" "xs" RTValue)
(b 15 "" "$cf" RTValue)
(b 16 "" "add" RTValue RTValue)
(b 17 "" "double" RTValue RTValue)
(b 18 "" "inc" RTValue RTValue)
(b 19 "" "applyTwice" RTValue RTValue)
(b 20 "" "mapL" RTValue RTValue)
(b 21 "" "foldlL" RTValue RTValue)
(b 22 "" "sumL" RTValue RTValue)
(b 23 "" "compd" RTValue RTValue)
(b 24 "" "main" RTValue RTValue)))
