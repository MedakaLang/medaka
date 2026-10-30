# META
source_lines=24
stages=DESUGAR,MARK
# SOURCE
-- Tests for `countBy` and `groupByKey` in `stdlib/map.mdk`.

import map.{countBy, entries, groupByKey}
import test.{expectEqual}

test "countBy of an empty list is empty" =
  expectEqual [] (entries (countBy (x => x) ([] : List Int)))

test "countBy counts each key" =
  expectEqual [(0, 2), (1, 3)] (entries (countBy (x => x % 2) [1, 2, 3, 4, 5]))

test "groupByKey of an empty list is empty" =
  expectEqual [] (entries (groupByKey (x => x) ([] : List Int)))

test "groupByKey keeps input order inside a group" =
  expectEqual
    [(0, [4, 2, 6]), (1, [5, 1, 3])]
    (entries (groupByKey (x => x % 2) [5, 4, 1, 2, 3, 6]))

test "groupByKey on a long list stays linear and ordered" =
  let xs = [1..=20000]
  expectEqual
    [(0, 10000), (1, 10000)]
    (entries (map length (groupByKey (x => x % 2) xs)))
# DESUGAR
(DUse false (UseGroup ("map") ((mem "countBy" false) (mem "entries" false) (mem "groupByKey" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTest false "countBy of an empty list is empty" (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EVar "entries") (EApp (EApp (EVar "countBy") (ELam ((PVar "x")) (EVar "x"))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))))))
(DTest false "countBy counts each key" (EApp (EApp (EVar "expectEqual") (EListLit (ETuple (ELit (LInt 0)) (ELit (LInt 2))) (ETuple (ELit (LInt 1)) (ELit (LInt 3))))) (EApp (EVar "entries") (EApp (EApp (EVar "countBy") (ELam ((PVar "x")) (EBinOp "%" (EVar "x") (ELit (LInt 2))))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)))))))
(DTest false "groupByKey of an empty list is empty" (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EVar "entries") (EApp (EApp (EVar "groupByKey") (ELam ((PVar "x")) (EVar "x"))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))))))
(DTest false "groupByKey keeps input order inside a group" (EApp (EApp (EVar "expectEqual") (EListLit (ETuple (ELit (LInt 0)) (EListLit (ELit (LInt 4)) (ELit (LInt 2)) (ELit (LInt 6)))) (ETuple (ELit (LInt 1)) (EListLit (ELit (LInt 5)) (ELit (LInt 1)) (ELit (LInt 3)))))) (EApp (EVar "entries") (EApp (EApp (EVar "groupByKey") (ELam ((PVar "x")) (EBinOp "%" (EVar "x") (ELit (LInt 2))))) (EListLit (ELit (LInt 5)) (ELit (LInt 4)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 6)))))))
(DTest false "groupByKey on a long list stays linear and ordered" (EBlock (DoLet false false (PVar "xs") (ERangeList (ELit (LInt 1)) (ELit (LInt 20000)) true)) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ETuple (ELit (LInt 0)) (ELit (LInt 10000))) (ETuple (ELit (LInt 1)) (ELit (LInt 10000))))) (EApp (EVar "entries") (EApp (EApp (EVar "map") (EVar "length")) (EApp (EApp (EVar "groupByKey") (ELam ((PVar "x")) (EBinOp "%" (EVar "x") (ELit (LInt 2))))) (EVar "xs"))))))))
# MARK
(DUse false (UseGroup ("map") ((mem "countBy" false) (mem "entries" false) (mem "groupByKey" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTest false "countBy of an empty list is empty" (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EVar "entries") (EApp (EApp (EVar "countBy") (ELam ((PVar "x")) (EVar "x"))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))))))
(DTest false "countBy counts each key" (EApp (EApp (EVar "expectEqual") (EListLit (ETuple (ELit (LInt 0)) (ELit (LInt 2))) (ETuple (ELit (LInt 1)) (ELit (LInt 3))))) (EApp (EVar "entries") (EApp (EApp (EVar "countBy") (ELam ((PVar "x")) (EBinOp "%" (EVar "x") (ELit (LInt 2))))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)))))))
(DTest false "groupByKey of an empty list is empty" (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EVar "entries") (EApp (EApp (EVar "groupByKey") (ELam ((PVar "x")) (EVar "x"))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))))))
(DTest false "groupByKey keeps input order inside a group" (EApp (EApp (EVar "expectEqual") (EListLit (ETuple (ELit (LInt 0)) (EListLit (ELit (LInt 4)) (ELit (LInt 2)) (ELit (LInt 6)))) (ETuple (ELit (LInt 1)) (EListLit (ELit (LInt 5)) (ELit (LInt 1)) (ELit (LInt 3)))))) (EApp (EVar "entries") (EApp (EApp (EVar "groupByKey") (ELam ((PVar "x")) (EBinOp "%" (EVar "x") (ELit (LInt 2))))) (EListLit (ELit (LInt 5)) (ELit (LInt 4)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 6)))))))
(DTest false "groupByKey on a long list stays linear and ordered" (EBlock (DoLet false false (PVar "xs") (ERangeList (ELit (LInt 1)) (ELit (LInt 20000)) true)) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ETuple (ELit (LInt 0)) (ELit (LInt 10000))) (ETuple (ELit (LInt 1)) (ELit (LInt 10000))))) (EApp (EVar "entries") (EApp (EApp (EMethodRef "map") (EMethodRef "length")) (EApp (EApp (EVar "groupByKey") (ELam ((PVar "x")) (EBinOp "%" (EVar "x") (ELit (LInt 2))))) (EVar "xs"))))))))
