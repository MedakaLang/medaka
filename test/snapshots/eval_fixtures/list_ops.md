# META
source_lines=13
stages=CORE_IR
# SOURCE
-- cons / append, list patterns, equality & ordering, let
revApp [] acc = acc
revApp (x :: xs) acc = revApp xs (x :: acc)
rev xs = revApp xs []
len [] = 0
len (_ :: xs) = 1 + len xs
zip2 [] _ = []
zip2 _ [] = []
zip2 (x :: xs) (y :: ys) = (x, y) :: zip2 xs ys
main =
  let a = [1, 2, 3]
  let b = [4, 5]
  (rev a, a ++ b, len (a ++ b), [1, 2] == [1, 2], [1, 2] < [1, 3], zip2 a b)
# CORE_IR
(CProgram ((CBind "revApp" (CClause ((PList) (PVar "acc")) (CVar "acc" (ALocal 0 0))) (CClause ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (CApp (CVar "revApp" AGlobal) ((CVar "xs" (ALocal 1 1)) (CBinPrim "::" (CVar "x" (ALocal 1 0)) (CVar "acc" (ALocal 0 0)))) CallExact true)))
(CBind "rev" (CClause ((PVar "xs")) (CApp (CVar "revApp" AGlobal) ((CVar "xs" (ALocal 0 0)) (CList)) CallExact true)))
(CBind "len" (CClause ((PList)) (CLit (LInt 0))) (CClause ((PCons PWild (PVar "xs"))) (CBinPrim "+" (CLit (LInt 1)) (CApp (CVar "len" AGlobal) ((CVar "xs" (ALocal 0 0))) CallExact false))))
(CBind "zip2" (CClause ((PList) PWild) (CList)) (CClause (PWild (PList)) (CList)) (CClause ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (CBinPrim "::" (CTuple (CVar "x" (ALocal 1 0)) (CVar "y" (ALocal 0 0))) (CApp (CVar "zip2" AGlobal) ((CVar "xs" (ALocal 1 1)) (CVar "ys" (ALocal 0 1))) CallExact false))))
(CBind "main" (CClause () (CBlock (CSLet false (PVar "a") (CList (CLit (LInt 1)) (CLit (LInt 2)) (CLit (LInt 3)))) (CSLet false (PVar "b") (CList (CLit (LInt 4)) (CLit (LInt 5)))) (CSExpr (CTuple (CApp (CVar "rev" AGlobal) ((CVar "a" (ALocal 1 0))) CallExact false) (CBinPrim "++" (CVar "a" (ALocal 1 0)) (CVar "b" (ALocal 0 0))) (CApp (CVar "len" AGlobal) ((CBinPrim "++" (CVar "a" (ALocal 1 0)) (CVar "b" (ALocal 0 0)))) CallExact false) (CBinPrim "==" (CList (CLit (LInt 1)) (CLit (LInt 2))) (CList (CLit (LInt 1)) (CLit (LInt 2)))) (CBinPrim "<" (CList (CLit (LInt 1)) (CLit (LInt 2))) (CList (CLit (LInt 1)) (CLit (LInt 3)))) (CApp (CVar "zip2" AGlobal) ((CVar "a" (ALocal 1 0)) (CVar "b" (ALocal 0 0))) CallExact false))))))) () () () () (facts () () () none (externs) (manifests) (origins ((function "len" (single "len")) (function "main" (single "main")) (function "rev" (single "rev")) (function "revApp" (single "revApp")) (function "zip2" (single "zip2"))) ())) (binder-types
(b 0 "" "acc" RTValue)
(b 1 "" "x" RTValue)
(b 2 "" "xs" RTValue)
(b 3 "" "acc" RTValue)
(b 4 "" "xs" RTValue)
(b 5 "" "xs" RTValue)
(b 6 "" "x" RTValue)
(b 7 "" "xs" RTValue)
(b 8 "" "y" RTValue)
(b 9 "" "ys" RTValue)
(b 10 "" "a" RTValue)
(b 11 "" "b" RTValue)
(b 12 "" "revApp" RTValue RTValue)
(b 13 "" "rev" RTValue RTValue)
(b 14 "" "len" RTValue RTValue)
(b 15 "" "zip2" RTValue RTValue)
(b 16 "" "main" RTValue RTValue)))
