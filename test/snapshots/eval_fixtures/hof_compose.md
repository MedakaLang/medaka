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
(CBind "main" (CClause () (CTuple (CApp (CVar "applyTwice" AGlobal) ((CVar "double" AGlobal) (CLit (LInt 3))) CallExact false) (CApp (CVar "mapL" AGlobal) ((CVar "inc" AGlobal) (CList (CLit (LInt 1)) (CLit (LInt 2)) (CLit (LInt 3)))) CallExact false) (CApp (CVar "sumL" AGlobal) ((CList (CLit (LInt 1)) (CLit (LInt 2)) (CLit (LInt 3)) (CLit (LInt 4)))) (CallOver 1) false) (CApp (CVar "compd" AGlobal) ((CLit (LInt 5))) (CallOver 1) false) (CApp (CVar "double" AGlobal) ((CApp (CVar "inc" AGlobal) ((CLit (LInt 10))) (CallOver 1) false)) (CallOver 1) false))))) () () () () (facts () ()) (binder-types
(b 15 "" "$cf" RTValue)))
