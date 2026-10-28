# META
source_lines=15
stages=DESUGAR,MARK
# SOURCE
-- Stack-depth tests for `stdlib/core.mdk`.
--
-- These build million-element lists, which the interpreter cannot run: it has
-- no tail-call optimisation and caps call depth at 25000. The module is
-- therefore rostered native-only in `test/stdlib_suite_test.mdk`.

import test.{expectEqual}

-- # List andThen

test "List andThen is stack safe on a long input" =
  expectEqual 1000000 (length (andThen [1..=1000000] (x => [x])))

test "List andThen is stack safe on a long inner list" =
  expectEqual 1000000 (length (andThen [1] (x => [1..=1000000])))
# DESUGAR
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTest false "List andThen is stack safe on a long input" (EApp (EApp (EVar "expectEqual") (ELit (LInt 1000000))) (EApp (EVar "length") (EApp (EApp (EVar "andThen") (ERangeList (ELit (LInt 1)) (ELit (LInt 1000000)) true)) (ELam ((PVar "x")) (EListLit (EVar "x")))))))
(DTest false "List andThen is stack safe on a long inner list" (EApp (EApp (EVar "expectEqual") (ELit (LInt 1000000))) (EApp (EVar "length") (EApp (EApp (EVar "andThen") (EListLit (ELit (LInt 1)))) (ELam ((PVar "x")) (ERangeList (ELit (LInt 1)) (ELit (LInt 1000000)) true))))))
# MARK
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTest false "List andThen is stack safe on a long input" (EApp (EApp (EVar "expectEqual") (ELit (LInt 1000000))) (EApp (EMethodRef "length") (EApp (EApp (EMethodRef "andThen") (ERangeList (ELit (LInt 1)) (ELit (LInt 1000000)) true)) (ELam ((PVar "x")) (EListLit (EVar "x")))))))
(DTest false "List andThen is stack safe on a long inner list" (EApp (EApp (EVar "expectEqual") (ELit (LInt 1000000))) (EApp (EMethodRef "length") (EApp (EApp (EMethodRef "andThen") (EListLit (ELit (LInt 1)))) (ELam ((PVar "x")) (ERangeList (ELit (LInt 1)) (ELit (LInt 1000000)) true))))))
