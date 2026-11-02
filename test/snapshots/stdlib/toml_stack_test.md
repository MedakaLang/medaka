# META
source_lines=14
stages=DESUGAR,MARK
# SOURCE
-- Deep-document tests for `stdlib/toml.mdk`.
--
-- The largest document `tableEntries` accepts builds a 100000-element list,
-- which the interpreter cannot run: it has no tail-call optimisation and caps
-- call depth at 25000. The module is therefore rostered native-only in
-- `test/stdlib_suite_test.mdk`.

import toml.{parse, tableEntries}
import test.{expectEqual, expectOkThen}

test "tableEntries reads the last entry the limit admits" =
  expectOkThen
    (es => expectEqual 100000 (length es))
    (parse "[gate.99999]\nname = \"x\"" |> flatMap (tableEntries "gate"))
# DESUGAR
(DUse false (UseGroup ("toml") ((mem "parse" false) (mem "tableEntries" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectOkThen" false))))
(DTest false "tableEntries reads the last entry the limit admits" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 100000))) (EApp (EVar "length") (EVar "es"))))) (EBinOp "|>" (EApp (EVar "parse") (ELit (LString "[gate.99999]\nname = \"x\""))) (EApp (EVar "flatMap") (EApp (EVar "tableEntries") (ELit (LString "gate")))))))
# MARK
(DUse false (UseGroup ("toml") ((mem "parse" false) (mem "tableEntries" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectOkThen" false))))
(DTest false "tableEntries reads the last entry the limit admits" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 100000))) (EApp (EMethodRef "length") (EVar "es"))))) (EBinOp "|>" (EApp (EVar "parse") (ELit (LString "[gate.99999]\nname = \"x\""))) (EApp (EDictApp "flatMap") (EApp (EVar "tableEntries") (ELit (LString "gate")))))))
