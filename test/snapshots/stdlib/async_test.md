# META
source_lines=11
stages=DESUGAR,MARK
# SOURCE
import async.{runAsync, deadlineAfter, expiredNow, waitFlag, sleep}
import time.{millis}
import test.{expectTrue, expectFalse}

test "expiredNow checks the carried timer without yielding" =
  let wait = runAsync (deadlineAfter (millis 5))
  let _ = runAsync (sleep (millis 20))
  expectTrue (expiredNow wait)

test "expiredNow does not expire a flag wait" =
  expectFalse (expiredNow (waitFlag (Ref True)))
# DESUGAR
(DUse false (UseGroup ("async") ((mem "runAsync" false) (mem "deadlineAfter" false) (mem "expiredNow" false) (mem "waitFlag" false) (mem "sleep" false))))
(DUse false (UseGroup ("time") ((mem "millis" false))))
(DUse false (UseGroup ("test") ((mem "expectTrue" false) (mem "expectFalse" false))))
(DTest false "expiredNow checks the carried timer without yielding" (EBlock (DoLet false false (PVar "wait") (EApp (EVar "runAsync") (EApp (EVar "deadlineAfter") (EApp (EVar "millis") (ELit (LInt 5)))))) (DoLet false false PWild (EApp (EVar "runAsync") (EApp (EVar "sleep") (EApp (EVar "millis") (ELit (LInt 20)))))) (DoExpr (EApp (EVar "expectTrue") (EApp (EVar "expiredNow") (EVar "wait"))))))
(DTest false "expiredNow does not expire a flag wait" (EApp (EVar "expectFalse") (EApp (EVar "expiredNow") (EApp (EVar "waitFlag") (EApp (EVar "Ref") (EVar "True"))))))
# MARK
(DUse false (UseGroup ("async") ((mem "runAsync" false) (mem "deadlineAfter" false) (mem "expiredNow" false) (mem "waitFlag" false) (mem "sleep" false))))
(DUse false (UseGroup ("time") ((mem "millis" false))))
(DUse false (UseGroup ("test") ((mem "expectTrue" false) (mem "expectFalse" false))))
(DTest false "expiredNow checks the carried timer without yielding" (EBlock (DoLet false false (PVar "wait") (EApp (EVar "runAsync") (EApp (EVar "deadlineAfter") (EApp (EVar "millis") (ELit (LInt 5)))))) (DoLet false false PWild (EApp (EVar "runAsync") (EApp (EVar "sleep") (EApp (EVar "millis") (ELit (LInt 20)))))) (DoExpr (EApp (EVar "expectTrue") (EApp (EVar "expiredNow") (EVar "wait"))))))
(DTest false "expiredNow does not expire a flag wait" (EApp (EVar "expectFalse") (EApp (EVar "expiredNow") (EApp (EVar "waitFlag") (EApp (EVar "Ref") (EVar "True"))))))
