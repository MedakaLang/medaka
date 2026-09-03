# META
source_lines=185
stages=DESUGAR,MARK
# SOURCE
{- | Assertions for unit tests.

   An assertion produces an `Expectation`: `Pass` or `Fail`, each carrying
   the rendered operands the assertion compared, so a reader — or a driver
   reading a compiled probe's output — sees the values and not just a
   verdict. Write a test as `test "name" = expectEqual expected actual`,
   and run the file with `medaka test`, which also runs the doctests and
   `prop` declarations it finds. `runTests` runs a list of tests from an
   ordinary program instead.

   Import what you need: `import test.{expectEqual, expectTrue}`. -}

{- | The result of one assertion.

   Both outcomes carry the two operands as rendered text, so a caller can
   report or re-compare them without the `Eq` or `Debug` instance the
   assertion itself used. `Fail` carries a message ahead of them. An
   assertion with nothing to show — `pass`, `fail` — renders both operands
   as the empty string. -}
public export data Expectation =
  -- Pass: expected, actual.  Fail: message, expected, actual.
  | Pass String String
  | Fail String String String
  deriving (Eq, Debug)

-- # Assertions

{- | An assertion that always passes.

   > pass
   Pass "" "" -}
export
pass : Expectation
pass = Pass "" ""

{- | An assertion that fails with a message.

   > fail "not ready"
   Fail "not ready" "" "" -}
export
fail : String -> Expectation
fail msg = Fail msg "" ""

{- | Passes when the value is `True`.

   > expectTrue True
   Pass "True" "True"
   > expectTrue False
   Fail "expected True but got False" "True" "False" -}
export
expectTrue : Bool -> Expectation
expectTrue True = Pass "True" "True"
expectTrue False = Fail "expected True but got False" "True" "False"

{- | Passes when the value is `False`.

   > expectFalse False
   Pass "False" "False"
   > expectFalse True
   Fail "expected False but got True" "False" "True" -}
export
expectFalse : Bool -> Expectation
expectFalse False = Pass "False" "False"
expectFalse True = Fail "expected False but got True" "False" "True"

{- | Passes when the two values are equal.

   The operands, and the message, name both values in their `debug` form.

   > expectEqual 42 42
   Pass "42" "42"
   > expectEqual 1 2
   Fail "expected 1 but got 2" "1" "2" -}
export
expectEqual : (Eq a, Debug a) => a -> a -> Expectation
expectEqual expected actual =
  let e = debug expected
  let a = debug actual
  if eq expected actual then Pass e a else Fail "expected \{e} but got \{a}" e a

{- | Passes when the two values differ.

   > expectNotEqual 1 2
   Pass "1" "2"
   > expectNotEqual 1 1
   Fail "expected values to differ but both were 1" "1" "1" -}
export
expectNotEqual : (Eq a, Debug a) => a -> a -> Expectation
expectNotEqual expected actual =
  let e = debug expected
  let a = debug actual
  if neq expected actual then
    Pass e a
  else
    Fail ("expected values to differ but both were " ++ a) e a

{- | Passes when `actual` is less than `expected`.

   > expectLessThan 10 3
   Pass "10" "3"
   > expectLessThan 10 15
   Fail "expected 15 < 10" "10" "15" -}
export
expectLessThan : (Ord a, Debug a) => a -> a -> Expectation
expectLessThan expected actual =
  let e = debug expected
  let a = debug actual
  if lt actual expected then Pass e a else Fail "expected \{a} < \{e}" e a

{- | Passes when `actual` is greater than `expected`.

   > expectGreaterThan 0 5
   Pass "0" "5"
   > expectGreaterThan 10 3
   Fail "expected 3 > 10" "10" "3" -}
export
expectGreaterThan : (Ord a, Debug a) => a -> a -> Expectation
expectGreaterThan expected actual =
  let e = debug expected
  let a = debug actual
  if gt actual expected then Pass e a else Fail "expected \{a} > \{e}" e a

-- Helper for expectAll: accumulate the first Fail, or stay Pass.  An
-- aggregate pass has no single pair of operands to report, so it collapses
-- to `pass` rather than keeping some arbitrary member's.
expectAllStep : Expectation -> Expectation -> Expectation
expectAllStep (Fail msg e a) _ = Fail msg e a
expectAllStep (Pass _ _) (Fail msg e a) = Fail msg e a
expectAllStep (Pass _ _) (Pass _ _) = pass

{- | Passes when every expectation in the list passes.

   The result is the first `Fail`, when there is one.

   > expectAll [pass, pass, pass]
   Pass "" ""
   > expectAll [pass, fail "oops", pass]
   Fail "oops" "" "" -}
export
expectAll : List Expectation -> Expectation
expectAll es = fold expectAllStep pass es

-- # Running tests

goTests : List (String, Unit -> Expectation) -> Int -> Int -> <IO> Bool
goTests [] passed failed =
  println "\n\{intToString passed} passed, \{intToString failed} failed"
  eq failed 0
goTests ((name, thunk) :: rest) passed failed = match thunk ()
  Pass _ _ =>
    println ("  ok   " ++ name)
    goTests rest (passed + 1) failed
  Fail msg _ _ =>
    println "  FAIL \{name}: \{msg}"
    goTests rest passed (failed + 1)

{- | Runs a list of named tests, printing each result and a summary.

   Each test is a name and a function from `Unit` to an `Expectation`.
   Returns `True` when every test passes. -}
export
runTests : List (String, Unit -> Expectation) -> <IO> Bool
runTests tests = goTests tests 0 0

-- ── Instance laws ────────────────────────────────────────────────────────
-- LAW: derived `Eq Expectation` must separate the two constructors AND the
-- payload; an assertion library whose results compare equal regardless of
-- the failure message would make every `expectEqual` over an `Expectation`
-- pass vacuously.
prop "Eq Expectation separates constructors and payloads" (m : String) =
  pass == pass
    && fail m == fail m
    && pass == fail m == False
    && fail m == fail (m ++ "!") == False

-- LAW: the operands travel on BOTH outcomes, so a passing assertion is
-- still distinguishable by the values it compared — the property the
-- native arm's driver reads instead of trusting the verdict.
prop "a passing expectEqual carries both rendered operands" (n : Int) =
  expectEqual n n == Pass (debug n) (debug n)

-- LAW: `Debug` agrees with `Eq`: equal expectations render identically,
-- distinguishable ones render differently.
prop "Debug Expectation agrees with Eq" (m : String) =
  debug (fail m) == debug (fail m) && debug (fail m) == debug pass == False
# DESUGAR
(DData Public "Expectation" () ((variant "Pass" (ConPos (TyCon "String") (TyCon "String"))) (variant "Fail" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Expectation")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Pass" (PVar "__a0") (PVar "__a1")) (PCon "Pass" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "Fail" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "Fail" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Expectation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Pass" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Pass ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1"))))) (arm (PCon "Fail" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Fail ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))))))))
(DTypeSig true "pass" (TyCon "Expectation"))
(DFunDef false "pass" () (EApp (EApp (EVar "Pass") (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig true "fail" (TyFun (TyCon "String") (TyCon "Expectation")))
(DFunDef false "fail" ((PVar "msg")) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig true "expectTrue" (TyFun (TyCon "Bool") (TyCon "Expectation")))
(DFunDef false "expectTrue" ((PCon "True")) (EApp (EApp (EVar "Pass") (ELit (LString "True"))) (ELit (LString "True"))))
(DFunDef false "expectTrue" ((PCon "False")) (EApp (EApp (EApp (EVar "Fail") (ELit (LString "expected True but got False"))) (ELit (LString "True"))) (ELit (LString "False"))))
(DTypeSig true "expectFalse" (TyFun (TyCon "Bool") (TyCon "Expectation")))
(DFunDef false "expectFalse" ((PCon "False")) (EApp (EApp (EVar "Pass") (ELit (LString "False"))) (ELit (LString "False"))))
(DFunDef false "expectFalse" ((PCon "True")) (EApp (EApp (EApp (EVar "Fail") (ELit (LString "expected False but got True"))) (ELit (LString "False"))) (ELit (LString "True"))))
(DTypeSig true "expectEqual" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectEqual" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EVar "eq") (EVar "expected")) (EVar "actual")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString " but got "))) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectNotEqual" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectNotEqual" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EVar "neq") (EVar "expected")) (EVar "actual")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (ELit (LString "expected values to differ but both were ")) (EVar "a"))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectLessThan" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectLessThan" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EVar "lt") (EVar "actual")) (EVar "expected")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString " < "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectGreaterThan" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectGreaterThan" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EVar "gt") (EVar "actual")) (EVar "expected")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString " > "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig false "expectAllStep" (TyFun (TyCon "Expectation") (TyFun (TyCon "Expectation") (TyCon "Expectation"))))
(DFunDef false "expectAllStep" ((PCon "Fail" (PVar "msg") (PVar "e") (PVar "a")) PWild) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (EVar "e")) (EVar "a")))
(DFunDef false "expectAllStep" ((PCon "Pass" PWild PWild) (PCon "Fail" (PVar "msg") (PVar "e") (PVar "a"))) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (EVar "e")) (EVar "a")))
(DFunDef false "expectAllStep" ((PCon "Pass" PWild PWild) (PCon "Pass" PWild PWild)) (EVar "pass"))
(DTypeSig true "expectAll" (TyFun (TyApp (TyCon "List") (TyCon "Expectation")) (TyCon "Expectation")))
(DFunDef false "expectAll" ((PVar "es")) (EApp (EApp (EApp (EVar "fold") (EVar "expectAllStep")) (EVar "pass")) (EVar "es")))
(DTypeSig false "goTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Expectation")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "goTests" ((PList) (PVar "passed") (PVar "failed")) (EBlock (DoExpr (EApp (EVar "println") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "passed")))) (ELit (LString " passed, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "failed")))) (ELit (LString " failed"))))) (DoExpr (EApp (EApp (EVar "eq") (EVar "failed")) (ELit (LInt 0))))))
(DFunDef false "goTests" ((PCons (PTuple (PVar "name") (PVar "thunk")) (PVar "rest")) (PVar "passed") (PVar "failed")) (EMatch (EApp (EVar "thunk") (ELit LUnit)) (arm (PCon "Pass" PWild PWild) () (EBlock (DoExpr (EApp (EVar "println") (EBinOp "++" (ELit (LString "  ok   ")) (EVar "name")))) (DoExpr (EApp (EApp (EApp (EVar "goTests") (EVar "rest")) (EBinOp "+" (EVar "passed") (ELit (LInt 1)))) (EVar "failed"))))) (arm (PCon "Fail" (PVar "msg") PWild PWild) () (EBlock (DoExpr (EApp (EVar "println") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EVar "goTests") (EVar "rest")) (EVar "passed")) (EBinOp "+" (EVar "failed") (ELit (LInt 1)))))))))
(DTypeSig true "runTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Expectation")))) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "runTests" ((PVar "tests")) (EApp (EApp (EApp (EVar "goTests") (EVar "tests")) (ELit (LInt 0))) (ELit (LInt 0))))
(DProp false "Eq Expectation separates constructors and payloads" ((pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "pass") (EVar "pass")) (EBinOp "==" (EApp (EVar "fail") (EVar "m")) (EApp (EVar "fail") (EVar "m")))) (EBinOp "==" (EBinOp "==" (EVar "pass") (EApp (EVar "fail") (EVar "m"))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EApp (EVar "fail") (EVar "m")) (EApp (EVar "fail") (EBinOp "++" (EVar "m") (ELit (LString "!"))))) (EVar "False"))))
(DProp false "a passing expectEqual carries both rendered operands" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "expectEqual") (EVar "n")) (EVar "n")) (EApp (EApp (EVar "Pass") (EApp (EVar "debug") (EVar "n"))) (EApp (EVar "debug") (EVar "n")))))
(DProp false "Debug Expectation agrees with Eq" ((pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "debug") (EApp (EVar "fail") (EVar "m"))) (EApp (EVar "debug") (EApp (EVar "fail") (EVar "m")))) (EBinOp "==" (EBinOp "==" (EApp (EVar "debug") (EApp (EVar "fail") (EVar "m"))) (EApp (EVar "debug") (EVar "pass"))) (EVar "False"))))
# MARK
(DData Public "Expectation" () ((variant "Pass" (ConPos (TyCon "String") (TyCon "String"))) (variant "Fail" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Expectation")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Pass" (PVar "__a0") (PVar "__a1")) (PCon "Pass" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "Fail" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "Fail" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Expectation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Pass" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Pass ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "Fail" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Fail ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))))))))
(DTypeSig true "pass" (TyCon "Expectation"))
(DFunDef false "pass" () (EApp (EApp (EVar "Pass") (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig true "fail" (TyFun (TyCon "String") (TyCon "Expectation")))
(DFunDef false "fail" ((PVar "msg")) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig true "expectTrue" (TyFun (TyCon "Bool") (TyCon "Expectation")))
(DFunDef false "expectTrue" ((PCon "True")) (EApp (EApp (EVar "Pass") (ELit (LString "True"))) (ELit (LString "True"))))
(DFunDef false "expectTrue" ((PCon "False")) (EApp (EApp (EApp (EVar "Fail") (ELit (LString "expected True but got False"))) (ELit (LString "True"))) (ELit (LString "False"))))
(DTypeSig true "expectFalse" (TyFun (TyCon "Bool") (TyCon "Expectation")))
(DFunDef false "expectFalse" ((PCon "False")) (EApp (EApp (EVar "Pass") (ELit (LString "False"))) (ELit (LString "False"))))
(DFunDef false "expectFalse" ((PCon "True")) (EApp (EApp (EApp (EVar "Fail") (ELit (LString "expected False but got True"))) (ELit (LString "False"))) (ELit (LString "True"))))
(DTypeSig true "expectEqual" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectEqual" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EMethodRef "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EMethodRef "eq") (EVar "expected")) (EVar "actual")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString " but got "))) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectNotEqual" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectNotEqual" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EMethodRef "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EDictApp "neq") (EVar "expected")) (EVar "actual")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (ELit (LString "expected values to differ but both were ")) (EVar "a"))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectLessThan" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectLessThan" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EMethodRef "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EMethodRef "lt") (EVar "actual")) (EVar "expected")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString " < "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectGreaterThan" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectGreaterThan" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EMethodRef "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EMethodRef "gt") (EVar "actual")) (EVar "expected")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString " > "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig false "expectAllStep" (TyFun (TyCon "Expectation") (TyFun (TyCon "Expectation") (TyCon "Expectation"))))
(DFunDef false "expectAllStep" ((PCon "Fail" (PVar "msg") (PVar "e") (PVar "a")) PWild) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (EVar "e")) (EVar "a")))
(DFunDef false "expectAllStep" ((PCon "Pass" PWild PWild) (PCon "Fail" (PVar "msg") (PVar "e") (PVar "a"))) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (EVar "e")) (EVar "a")))
(DFunDef false "expectAllStep" ((PCon "Pass" PWild PWild) (PCon "Pass" PWild PWild)) (EVar "pass"))
(DTypeSig true "expectAll" (TyFun (TyApp (TyCon "List") (TyCon "Expectation")) (TyCon "Expectation")))
(DFunDef false "expectAll" ((PVar "es")) (EApp (EApp (EApp (EMethodRef "fold") (EVar "expectAllStep")) (EVar "pass")) (EVar "es")))
(DTypeSig false "goTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Expectation")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "goTests" ((PList) (PVar "passed") (PVar "failed")) (EBlock (DoExpr (EApp (EDictApp "println") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "passed")))) (ELit (LString " passed, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "failed")))) (ELit (LString " failed"))))) (DoExpr (EApp (EApp (EMethodRef "eq") (EVar "failed")) (ELit (LInt 0))))))
(DFunDef false "goTests" ((PCons (PTuple (PVar "name") (PVar "thunk")) (PVar "rest")) (PVar "passed") (PVar "failed")) (EMatch (EApp (EVar "thunk") (ELit LUnit)) (arm (PCon "Pass" PWild PWild) () (EBlock (DoExpr (EApp (EDictApp "println") (EBinOp "++" (ELit (LString "  ok   ")) (EVar "name")))) (DoExpr (EApp (EApp (EApp (EVar "goTests") (EVar "rest")) (EBinOp "+" (EVar "passed") (ELit (LInt 1)))) (EVar "failed"))))) (arm (PCon "Fail" (PVar "msg") PWild PWild) () (EBlock (DoExpr (EApp (EDictApp "println") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EVar "goTests") (EVar "rest")) (EVar "passed")) (EBinOp "+" (EVar "failed") (ELit (LInt 1)))))))))
(DTypeSig true "runTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Expectation")))) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "runTests" ((PVar "tests")) (EApp (EApp (EApp (EVar "goTests") (EVar "tests")) (ELit (LInt 0))) (ELit (LInt 0))))
(DProp false "Eq Expectation separates constructors and payloads" ((pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "pass") (EVar "pass")) (EBinOp "==" (EApp (EVar "fail") (EVar "m")) (EApp (EVar "fail") (EVar "m")))) (EBinOp "==" (EBinOp "==" (EVar "pass") (EApp (EVar "fail") (EVar "m"))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EApp (EVar "fail") (EVar "m")) (EApp (EVar "fail") (EBinOp "++" (EVar "m") (ELit (LString "!"))))) (EVar "False"))))
(DProp false "a passing expectEqual carries both rendered operands" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EDictApp "expectEqual") (EVar "n")) (EVar "n")) (EApp (EApp (EVar "Pass") (EApp (EMethodRef "debug") (EVar "n"))) (EApp (EMethodRef "debug") (EVar "n")))))
(DProp false "Debug Expectation agrees with Eq" ((pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "==" (EApp (EMethodRef "debug") (EApp (EVar "fail") (EVar "m"))) (EApp (EMethodRef "debug") (EApp (EVar "fail") (EVar "m")))) (EBinOp "==" (EBinOp "==" (EApp (EMethodRef "debug") (EApp (EVar "fail") (EVar "m"))) (EApp (EMethodRef "debug") (EVar "pass"))) (EVar "False"))))
