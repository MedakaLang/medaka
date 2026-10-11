# META
source_lines=67
stages=DESUGAR,MARK
# SOURCE
-- Tests for `insertAtInPlace` and `removeAtInPlace` in `stdlib/vector.mdk`.
--
-- The reference answers are written on lists, apart from the vector, so the
-- shifts are checked element for element rather than only by round trip.

import test.{expectEqual}
import vector.{fromList, insertAtInPlace, push, removeAtInPlace}

-- # The reference reading

insertSpec : Int -> a -> List a -> List a
insertSpec _ x [] = [x]
insertSpec i x (y :: ys) =
  if i <= 0 then x :: y :: ys else y :: insertSpec (i - 1) x ys

removeSpec : Int -> List a -> List a
removeSpec _ [] = []
removeSpec i (y :: ys) =
  if i < 0 then y :: ys else if i == 0 then ys else y :: removeSpec (i - 1) ys

-- # Fixed cases

test "insertAtInPlace before the start clamps to the front" =
  let v = fromList [1, 2, 3]
  insertAtInPlace (0 - 4) 9 v
  expectEqual [9, 1, 2, 3] (toList v)

test "insertAtInPlace past the end appends" =
  let v = fromList [1, 2, 3]
  insertAtInPlace 10 9 v
  expectEqual [1, 2, 3, 9] (toList v)

test "insertAtInPlace into an empty vector" =
  let v = fromList []
  insertAtInPlace 0 9 v
  expectEqual [9] (toList v)

test "insertAtInPlace keeps working once the backing array must grow" =
  let v = fromList [1, 2]
  insertAtInPlace 1 0 v
  push 7 v
  push 8 v
  push 9 v
  insertAtInPlace 0 5 v
  expectEqual [5, 1, 0, 2, 7, 8, 9] (toList v)

test "removeAtInPlace past the end is a no-op" =
  let v = fromList [1, 2, 3]
  removeAtInPlace 3 v
  expectEqual [1, 2, 3] (toList v)

test "removeAtInPlace of the last element" =
  let v = fromList [1, 2, 3]
  removeAtInPlace 2 v
  expectEqual [1, 2] (toList v)

-- # Properties

prop "insertAtInPlace and removeAtInPlace shift elements exactly as their list specs" (xs : List Int) (n : Int) (x : Int) =
  let ma = fromList xs
  insertAtInPlace n x ma
  let inserted = toList ma == insertSpec n x xs
  removeAtInPlace n ma
  let removed = toList ma == removeSpec n (insertSpec n x xs)
  let mb = fromList xs
  removeAtInPlace n mb
  inserted && removed && toList mb == removeSpec n xs
# DESUGAR
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DUse false (UseGroup ("vector") ((mem "fromList" false) (mem "insertAtInPlace" false) (mem "push" false) (mem "removeAtInPlace" false))))
(DTypeSig false "insertSpec" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "insertSpec" (PWild (PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "insertSpec" ((PVar "i") (PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "insertSpec") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "x")) (EVar "ys")))))
(DTypeSig false "removeSpec" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "removeSpec" (PWild (PList)) (EListLit))
(DFunDef false "removeSpec" ((PVar "i") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp "::" (EVar "y") (EVar "ys")) (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EVar "ys") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "removeSpec") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "ys"))))))
(DTest false "insertAtInPlace before the start clamps to the front" (EBlock (DoLet false false (PVar "v") (EApp (EVar "fromList") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 4)))) (ELit (LInt 9))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 9)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (EApp (EVar "toList") (EVar "v"))))))
(DTest false "insertAtInPlace past the end appends" (EBlock (DoLet false false (PVar "v") (EApp (EVar "fromList") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (ELit (LInt 10))) (ELit (LInt 9))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 9)))) (EApp (EVar "toList") (EVar "v"))))))
(DTest false "insertAtInPlace into an empty vector" (EBlock (DoLet false false (PVar "v") (EApp (EVar "fromList") (EListLit))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (ELit (LInt 0))) (ELit (LInt 9))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 9)))) (EApp (EVar "toList") (EVar "v"))))))
(DTest false "insertAtInPlace keeps working once the backing array must grow" (EBlock (DoLet false false (PVar "v") (EApp (EVar "fromList") (EListLit (ELit (LInt 1)) (ELit (LInt 2))))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (ELit (LInt 1))) (ELit (LInt 0))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "push") (ELit (LInt 7))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "push") (ELit (LInt 8))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "push") (ELit (LInt 9))) (EVar "v"))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (ELit (LInt 0))) (ELit (LInt 5))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 5)) (ELit (LInt 1)) (ELit (LInt 0)) (ELit (LInt 2)) (ELit (LInt 7)) (ELit (LInt 8)) (ELit (LInt 9)))) (EApp (EVar "toList") (EVar "v"))))))
(DTest false "removeAtInPlace past the end is a no-op" (EBlock (DoLet false false (PVar "v") (EApp (EVar "fromList") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (ELit (LInt 3))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (EApp (EVar "toList") (EVar "v"))))))
(DTest false "removeAtInPlace of the last element" (EBlock (DoLet false false (PVar "v") (EApp (EVar "fromList") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (ELit (LInt 2))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (EApp (EVar "toList") (EVar "v"))))))
(DProp false "insertAtInPlace and removeAtInPlace shift elements exactly as their list specs" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "n" (TyCon "Int")) (pp "x" (TyCon "Int"))) (EBlock (DoLet false false (PVar "ma") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (EVar "n")) (EVar "x")) (EVar "ma"))) (DoLet false false (PVar "inserted") (EBinOp "==" (EApp (EVar "toList") (EVar "ma")) (EApp (EApp (EApp (EVar "insertSpec") (EVar "n")) (EVar "x")) (EVar "xs")))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (EVar "n")) (EVar "ma"))) (DoLet false false (PVar "removed") (EBinOp "==" (EApp (EVar "toList") (EVar "ma")) (EApp (EApp (EVar "removeSpec") (EVar "n")) (EApp (EApp (EApp (EVar "insertSpec") (EVar "n")) (EVar "x")) (EVar "xs"))))) (DoLet false false (PVar "mb") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (EVar "n")) (EVar "mb"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "inserted") (EVar "removed")) (EBinOp "==" (EApp (EVar "toList") (EVar "mb")) (EApp (EApp (EVar "removeSpec") (EVar "n")) (EVar "xs")))))))
# MARK
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DUse false (UseGroup ("vector") ((mem "fromList" false) (mem "insertAtInPlace" false) (mem "push" false) (mem "removeAtInPlace" false))))
(DTypeSig false "insertSpec" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "insertSpec" (PWild (PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "insertSpec" ((PVar "i") (PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "insertSpec") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "x")) (EVar "ys")))))
(DTypeSig false "removeSpec" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "removeSpec" (PWild (PList)) (EListLit))
(DFunDef false "removeSpec" ((PVar "i") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp "::" (EVar "y") (EVar "ys")) (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EVar "ys") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "removeSpec") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "ys"))))))
(DTest false "insertAtInPlace before the start clamps to the front" (EBlock (DoLet false false (PVar "v") (EApp (EVar "fromList") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 4)))) (ELit (LInt 9))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 9)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (EApp (EMethodRef "toList") (EVar "v"))))))
(DTest false "insertAtInPlace past the end appends" (EBlock (DoLet false false (PVar "v") (EApp (EVar "fromList") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (ELit (LInt 10))) (ELit (LInt 9))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 9)))) (EApp (EMethodRef "toList") (EVar "v"))))))
(DTest false "insertAtInPlace into an empty vector" (EBlock (DoLet false false (PVar "v") (EApp (EVar "fromList") (EListLit))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (ELit (LInt 0))) (ELit (LInt 9))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 9)))) (EApp (EMethodRef "toList") (EVar "v"))))))
(DTest false "insertAtInPlace keeps working once the backing array must grow" (EBlock (DoLet false false (PVar "v") (EApp (EVar "fromList") (EListLit (ELit (LInt 1)) (ELit (LInt 2))))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (ELit (LInt 1))) (ELit (LInt 0))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "push") (ELit (LInt 7))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "push") (ELit (LInt 8))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "push") (ELit (LInt 9))) (EVar "v"))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (ELit (LInt 0))) (ELit (LInt 5))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 5)) (ELit (LInt 1)) (ELit (LInt 0)) (ELit (LInt 2)) (ELit (LInt 7)) (ELit (LInt 8)) (ELit (LInt 9)))) (EApp (EMethodRef "toList") (EVar "v"))))))
(DTest false "removeAtInPlace past the end is a no-op" (EBlock (DoLet false false (PVar "v") (EApp (EVar "fromList") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (ELit (LInt 3))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (EApp (EMethodRef "toList") (EVar "v"))))))
(DTest false "removeAtInPlace of the last element" (EBlock (DoLet false false (PVar "v") (EApp (EVar "fromList") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (ELit (LInt 2))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (EApp (EMethodRef "toList") (EVar "v"))))))
(DProp false "insertAtInPlace and removeAtInPlace shift elements exactly as their list specs" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "n" (TyCon "Int")) (pp "x" (TyCon "Int"))) (EBlock (DoLet false false (PVar "ma") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (EVar "n")) (EVar "x")) (EVar "ma"))) (DoLet false false (PVar "inserted") (EBinOp "==" (EApp (EMethodRef "toList") (EVar "ma")) (EApp (EApp (EApp (EVar "insertSpec") (EVar "n")) (EVar "x")) (EVar "xs")))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (EVar "n")) (EVar "ma"))) (DoLet false false (PVar "removed") (EBinOp "==" (EApp (EMethodRef "toList") (EVar "ma")) (EApp (EApp (EVar "removeSpec") (EVar "n")) (EApp (EApp (EApp (EVar "insertSpec") (EVar "n")) (EVar "x")) (EVar "xs"))))) (DoLet false false (PVar "mb") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (EVar "n")) (EVar "mb"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "inserted") (EVar "removed")) (EBinOp "==" (EApp (EMethodRef "toList") (EVar "mb")) (EApp (EApp (EVar "removeSpec") (EVar "n")) (EVar "xs")))))))
