# META
source_lines=33
stages=DESUGAR,MARK
# SOURCE
-- Tests for `Down` in `stdlib/list.mdk`.

import list.{Down(..), sortOn}
import test.{expectEqual, expectFalse, expectTrue}

-- # Ordering

test "Down reverses every comparison operator" =
  expectTrue
    (Down 1 > Down 2 && Down 1 >= Down 2 && Down 2 < Down 1 && Down 2 <= Down 1)

test "Down of equal values is neither less nor greater" =
  expectFalse (Down 3 < Down 3 || Down 3 > Down 3)

test "Down compares as the reverse of the wrapped compare" =
  expectEqual Gt (compare (Down 1) (Down 2))

test "Down renders with its constructor" = expectEqual "Down 3" (debug (Down 3))

-- # Sorting

test "sortOn Down sorts descending" =
  expectEqual [3, 2, 1] (sortOn (x => Down x) [1, 3, 2])

test "sortOn Down keeps input order among equal keys" =
  expectEqual
    [("b", 2), ("a", 2), ("c", 1)]
    (sortOn (r => Down (snd r)) [("b", 2), ("c", 1), ("a", 2)])

test "a tuple key sorts one part descending and another ascending" =
  expectEqual
    [("a", 2), ("c", 2), ("b", 1)]
    (sortOn (r => (Down (snd r), fst r)) [("b", 1), ("c", 2), ("a", 2)])
# DESUGAR
(DUse false (UseGroup ("list") ((mem "Down" true) (mem "sortOn" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectFalse" false) (mem "expectTrue" false))))
(DTest false "Down reverses every comparison operator" (EApp (EVar "expectTrue") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EApp (EVar "Down") (ELit (LInt 1))) (EApp (EVar "Down") (ELit (LInt 2)))) (EBinOp ">=" (EApp (EVar "Down") (ELit (LInt 1))) (EApp (EVar "Down") (ELit (LInt 2))))) (EBinOp "<" (EApp (EVar "Down") (ELit (LInt 2))) (EApp (EVar "Down") (ELit (LInt 1))))) (EBinOp "<=" (EApp (EVar "Down") (ELit (LInt 2))) (EApp (EVar "Down") (ELit (LInt 1)))))))
(DTest false "Down of equal values is neither less nor greater" (EApp (EVar "expectFalse") (EBinOp "||" (EBinOp "<" (EApp (EVar "Down") (ELit (LInt 3))) (EApp (EVar "Down") (ELit (LInt 3)))) (EBinOp ">" (EApp (EVar "Down") (ELit (LInt 3))) (EApp (EVar "Down") (ELit (LInt 3)))))))
(DTest false "Down compares as the reverse of the wrapped compare" (EApp (EApp (EVar "expectEqual") (EVar "Gt")) (EApp (EApp (EVar "compare") (EApp (EVar "Down") (ELit (LInt 1)))) (EApp (EVar "Down") (ELit (LInt 2))))))
(DTest false "Down renders with its constructor" (EApp (EApp (EVar "expectEqual") (ELit (LString "Down 3"))) (EApp (EVar "debug") (EApp (EVar "Down") (ELit (LInt 3))))))
(DTest false "sortOn Down sorts descending" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 3)) (ELit (LInt 2)) (ELit (LInt 1)))) (EApp (EApp (EVar "sortOn") (ELam ((PVar "x")) (EApp (EVar "Down") (EVar "x")))) (EListLit (ELit (LInt 1)) (ELit (LInt 3)) (ELit (LInt 2))))))
(DTest false "sortOn Down keeps input order among equal keys" (EApp (EApp (EVar "expectEqual") (EListLit (ETuple (ELit (LString "b")) (ELit (LInt 2))) (ETuple (ELit (LString "a")) (ELit (LInt 2))) (ETuple (ELit (LString "c")) (ELit (LInt 1))))) (EApp (EApp (EVar "sortOn") (ELam ((PVar "r")) (EApp (EVar "Down") (EApp (EVar "snd") (EVar "r"))))) (EListLit (ETuple (ELit (LString "b")) (ELit (LInt 2))) (ETuple (ELit (LString "c")) (ELit (LInt 1))) (ETuple (ELit (LString "a")) (ELit (LInt 2)))))))
(DTest false "a tuple key sorts one part descending and another ascending" (EApp (EApp (EVar "expectEqual") (EListLit (ETuple (ELit (LString "a")) (ELit (LInt 2))) (ETuple (ELit (LString "c")) (ELit (LInt 2))) (ETuple (ELit (LString "b")) (ELit (LInt 1))))) (EApp (EApp (EVar "sortOn") (ELam ((PVar "r")) (ETuple (EApp (EVar "Down") (EApp (EVar "snd") (EVar "r"))) (EApp (EVar "fst") (EVar "r"))))) (EListLit (ETuple (ELit (LString "b")) (ELit (LInt 1))) (ETuple (ELit (LString "c")) (ELit (LInt 2))) (ETuple (ELit (LString "a")) (ELit (LInt 2)))))))
# MARK
(DUse false (UseGroup ("list") ((mem "Down" true) (mem "sortOn" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectFalse" false) (mem "expectTrue" false))))
(DTest false "Down reverses every comparison operator" (EApp (EVar "expectTrue") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EApp (EVar "Down") (ELit (LInt 1))) (EApp (EVar "Down") (ELit (LInt 2)))) (EBinOp ">=" (EApp (EVar "Down") (ELit (LInt 1))) (EApp (EVar "Down") (ELit (LInt 2))))) (EBinOp "<" (EApp (EVar "Down") (ELit (LInt 2))) (EApp (EVar "Down") (ELit (LInt 1))))) (EBinOp "<=" (EApp (EVar "Down") (ELit (LInt 2))) (EApp (EVar "Down") (ELit (LInt 1)))))))
(DTest false "Down of equal values is neither less nor greater" (EApp (EVar "expectFalse") (EBinOp "||" (EBinOp "<" (EApp (EVar "Down") (ELit (LInt 3))) (EApp (EVar "Down") (ELit (LInt 3)))) (EBinOp ">" (EApp (EVar "Down") (ELit (LInt 3))) (EApp (EVar "Down") (ELit (LInt 3)))))))
(DTest false "Down compares as the reverse of the wrapped compare" (EApp (EApp (EVar "expectEqual") (EVar "Gt")) (EApp (EApp (EMethodRef "compare") (EApp (EVar "Down") (ELit (LInt 1)))) (EApp (EVar "Down") (ELit (LInt 2))))))
(DTest false "Down renders with its constructor" (EApp (EApp (EVar "expectEqual") (ELit (LString "Down 3"))) (EApp (EMethodRef "debug") (EApp (EVar "Down") (ELit (LInt 3))))))
(DTest false "sortOn Down sorts descending" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 3)) (ELit (LInt 2)) (ELit (LInt 1)))) (EApp (EApp (EVar "sortOn") (ELam ((PVar "x")) (EApp (EVar "Down") (EVar "x")))) (EListLit (ELit (LInt 1)) (ELit (LInt 3)) (ELit (LInt 2))))))
(DTest false "sortOn Down keeps input order among equal keys" (EApp (EApp (EVar "expectEqual") (EListLit (ETuple (ELit (LString "b")) (ELit (LInt 2))) (ETuple (ELit (LString "a")) (ELit (LInt 2))) (ETuple (ELit (LString "c")) (ELit (LInt 1))))) (EApp (EApp (EVar "sortOn") (ELam ((PVar "r")) (EApp (EVar "Down") (EApp (EVar "snd") (EVar "r"))))) (EListLit (ETuple (ELit (LString "b")) (ELit (LInt 2))) (ETuple (ELit (LString "c")) (ELit (LInt 1))) (ETuple (ELit (LString "a")) (ELit (LInt 2)))))))
(DTest false "a tuple key sorts one part descending and another ascending" (EApp (EApp (EVar "expectEqual") (EListLit (ETuple (ELit (LString "a")) (ELit (LInt 2))) (ETuple (ELit (LString "c")) (ELit (LInt 2))) (ETuple (ELit (LString "b")) (ELit (LInt 1))))) (EApp (EApp (EVar "sortOn") (ELam ((PVar "r")) (ETuple (EApp (EVar "Down") (EApp (EVar "snd") (EVar "r"))) (EApp (EVar "fst") (EVar "r"))))) (EListLit (ETuple (ELit (LString "b")) (ELit (LInt 1))) (ETuple (ELit (LString "c")) (ELit (LInt 2))) (ETuple (ELit (LString "a")) (ELit (LInt 2)))))))
