# META
source_lines=313
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

import math.{approxEq}
import string.{lines, stripSuffix}

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

{- | Passes when the result is `Ok`.

   > expectOk (Ok 1)
   Pass "Ok _" "Ok 1"
   > expectOk (Err "boom")
   Fail "expected Ok but got Err \"boom\"" "Ok _" "Err \"boom\"" -}
export
expectOk : (Debug e, Debug a) => Result e a -> Expectation
expectOk r =
  let a = debug r
  match r
    Ok _ => Pass "Ok _" a
    Err _ => Fail "expected Ok but got \{a}" "Ok _" a

{- | Passes when the result is `Err`.

   > expectErr (Err "boom")
   Pass "Err _" "Err \"boom\""
   > expectErr (Ok 1)
   Fail "expected Err but got Ok 1" "Err _" "Ok 1" -}
export
expectErr : (Debug e, Debug a) => Result e a -> Expectation
expectErr r =
  let a = debug r
  match r
    Err _ => Pass "Err _" a
    Ok _ => Fail "expected Err but got \{a}" "Err _" a

{- | Passes when the option is `Some`.

   > expectSome (Some 1)
   Pass "Some _" "Some 1"
   > expectSome None
   Fail "expected Some but got None" "Some _" "None" -}
export
expectSome : Debug a => Option a -> Expectation
expectSome o =
  let a = debug o
  match o
    Some _ => Pass "Some _" a
    None => Fail "expected Some but got \{a}" "Some _" a

{- | Passes when the option is `None`.

   > expectNone None
   Pass "None" "None"
   > expectNone (Some 1)
   Fail "expected None but got Some 1" "None" "Some 1" -}
export
expectNone : Debug a => Option a -> Expectation
expectNone o =
  let a = debug o
  match o
    None => Pass "None" a
    Some _ => Fail "expected None but got \{a}" "None" a

{- | Passes when `actual` is within `eps` of `expected`.

   > expectWithin 1.0 1.0005 0.01
   Pass "1.0" "1.0005"
   > expectWithin 1.0 2.0 0.01
   Fail "expected 2.0 within 0.01 of 1.0" "1.0" "2.0" -}
export
expectWithin : Float -> Float -> Float -> Expectation
expectWithin expected actual eps =
  let e = debug expected
  let a = debug actual
  if approxEq expected actual eps then
    Pass e a
  else
    Fail "expected \{a} within \{debug eps} of \{e}" e a

-- The single normalizer for the trailing-Unit shapes the shell `strip_unit`
-- helpers across test/*.sh disagree on: strips a trailing "()" if present,
-- else a trailing "0" (the auto-printed Unit value or exit code a probe's
-- last line carries). The shell scripts' seven variants stay as they are.
normalizeTrailingUnit : String -> String
-- lint-disable-next-line rule-stdlib-reimpl
normalizeTrailingUnit s = match stripSuffix "()" s
  Some s2 => s2
  None => optionOr s (stripSuffix "0" s)

-- Renders the first line at which two line lists diverge, 1-indexed.
diffLineMsg : Int -> List String -> List String -> String
diffLineMsg n [] [] = "expected and actual differ only outside their lines"
diffLineMsg n [] (a :: _) =
  "line \{intToString n}: expected nothing but got \{debug a}"
diffLineMsg n (e :: _) [] =
  "line \{intToString n}: expected \{debug e} but got nothing"
diffLineMsg n (e :: es) (a :: asL) =
  if e == a then
    diffLineMsg (n + 1) es asL
  else
    "line \{intToString n}: expected \{debug e} but got \{debug a}"

{- | Passes when two texts are equal after normalizing one trailing
   auto-printed Unit shape (a trailing `()` or `0`).

   A mismatch names the first differing line, 1-indexed, rather than
   dumping both texts whole. -}
export
expectEqualText : String -> String -> Expectation
expectEqualText expected actual =
  let e = normalizeTrailingUnit expected
  let a = normalizeTrailingUnit actual
  if e == a then Pass e a else Fail (diffLineMsg 1 (lines e) (lines a)) e a

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

-- # Golden files

{- | Compares `actual` against the golden file at `path`, via
   `expectEqualText`.

   Read-only: never writes or blesses a golden. A read failure — most often
   a golden that does not exist yet — surfaces as a `Fail` naming it, so a
   caller doesn't need a separate branch for "no golden" versus "golden
   didn't match."

   > expectGolden "stdlib/no-such-golden-doctest-fixture.golden" "hello"
   Fail "expected golden stdlib/no-such-golden-doctest-fixture.golden: No such file or directory" "" "hello" -}
export
expectGolden : String -> String -> <FileRead "_"> Expectation
expectGolden path actual = match readFile path
  Err e => Fail "expected golden \{path}: \{e}" "" actual
  Ok golden => expectEqualText golden actual

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
(DUse false (UseGroup ("math") ((mem "approxEq" false))))
(DUse false (UseGroup ("string") ((mem "lines" false) (mem "stripSuffix" false))))
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
(DTypeSig true "expectOk" (TyConstrained ((cstr "Debug" (TyVar "e")) (cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectOk" ((PVar "r")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "r"))) (DoExpr (EMatch (EVar "r") (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "Pass") (ELit (LString "Ok _"))) (EVar "a"))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Ok but got ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "Ok _"))) (EVar "a")))))))
(DTypeSig true "expectErr" (TyConstrained ((cstr "Debug" (TyVar "e")) (cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectErr" ((PVar "r")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "r"))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" PWild) () (EApp (EApp (EVar "Pass") (ELit (LString "Err _"))) (EVar "a"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Err but got ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "Err _"))) (EVar "a")))))))
(DTypeSig true "expectSome" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectSome" ((PVar "o")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "o"))) (DoExpr (EMatch (EVar "o") (arm (PCon "Some" PWild) () (EApp (EApp (EVar "Pass") (ELit (LString "Some _"))) (EVar "a"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Some but got ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "Some _"))) (EVar "a")))))))
(DTypeSig true "expectNone" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectNone" ((PVar "o")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "o"))) (DoExpr (EMatch (EVar "o") (arm (PCon "None") () (EApp (EApp (EVar "Pass") (ELit (LString "None"))) (EVar "a"))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected None but got ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "None"))) (EVar "a")))))))
(DTypeSig true "expectWithin" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Expectation")))))
(DFunDef false "expectWithin" ((PVar "expected") (PVar "actual") (PVar "eps")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "approxEq") (EVar "expected")) (EVar "actual")) (EVar "eps")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString " within "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "eps")))) (ELit (LString " of "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig false "normalizeTrailingUnit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normalizeTrailingUnit" ((PVar "s")) (EMatch (EApp (EApp (EVar "stripSuffix") (ELit (LString "()"))) (EVar "s")) (arm (PCon "Some" (PVar "s2")) () (EVar "s2")) (arm (PCon "None") () (EApp (EApp (EVar "optionOr") (EVar "s")) (EApp (EApp (EVar "stripSuffix") (ELit (LString "0"))) (EVar "s"))))))
(DTypeSig false "diffLineMsg" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "diffLineMsg" ((PVar "n") (PList) (PList)) (ELit (LString "expected and actual differ only outside their lines")))
(DFunDef false "diffLineMsg" ((PVar "n") (PList) (PCons (PVar "a") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ": expected nothing but got "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "a")))) (ELit (LString ""))))
(DFunDef false "diffLineMsg" ((PVar "n") (PCons (PVar "e") PWild) (PList)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ": expected "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "e")))) (ELit (LString " but got nothing"))))
(DFunDef false "diffLineMsg" ((PVar "n") (PCons (PVar "e") (PVar "es")) (PCons (PVar "a") (PVar "asL"))) (EIf (EBinOp "==" (EVar "e") (EVar "a")) (EApp (EApp (EApp (EVar "diffLineMsg") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "es")) (EVar "asL")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ": expected "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "e")))) (ELit (LString " but got "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "a")))) (ELit (LString "")))))
(DTypeSig true "expectEqualText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Expectation"))))
(DFunDef false "expectEqualText" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "normalizeTrailingUnit") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "normalizeTrailingUnit") (EVar "actual"))) (DoExpr (EIf (EBinOp "==" (EVar "e") (EVar "a")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EApp (EApp (EApp (EVar "diffLineMsg") (ELit (LInt 1))) (EApp (EVar "lines") (EVar "e"))) (EApp (EVar "lines") (EVar "a")))) (EVar "e")) (EVar "a"))))))
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
(DTypeSig true "expectGolden" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyCon "Expectation")))))
(DFunDef false "expectGolden" ((PVar "path") (PVar "actual")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected golden ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (ELit (LString ""))) (EVar "actual"))) (arm (PCon "Ok" (PVar "golden")) () (EApp (EApp (EVar "expectEqualText") (EVar "golden")) (EVar "actual")))))
(DProp false "Eq Expectation separates constructors and payloads" ((pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "pass") (EVar "pass")) (EBinOp "==" (EApp (EVar "fail") (EVar "m")) (EApp (EVar "fail") (EVar "m")))) (EBinOp "==" (EBinOp "==" (EVar "pass") (EApp (EVar "fail") (EVar "m"))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EApp (EVar "fail") (EVar "m")) (EApp (EVar "fail") (EBinOp "++" (EVar "m") (ELit (LString "!"))))) (EVar "False"))))
(DProp false "a passing expectEqual carries both rendered operands" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "expectEqual") (EVar "n")) (EVar "n")) (EApp (EApp (EVar "Pass") (EApp (EVar "debug") (EVar "n"))) (EApp (EVar "debug") (EVar "n")))))
(DProp false "Debug Expectation agrees with Eq" ((pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "debug") (EApp (EVar "fail") (EVar "m"))) (EApp (EVar "debug") (EApp (EVar "fail") (EVar "m")))) (EBinOp "==" (EBinOp "==" (EApp (EVar "debug") (EApp (EVar "fail") (EVar "m"))) (EApp (EVar "debug") (EVar "pass"))) (EVar "False"))))
# MARK
(DUse false (UseGroup ("math") ((mem "approxEq" false))))
(DUse false (UseGroup ("string") ((mem "lines" false) (mem "stripSuffix" false))))
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
(DTypeSig true "expectOk" (TyConstrained ((cstr "Debug" (TyVar "e")) (cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectOk" ((PVar "r")) (EBlock (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "r"))) (DoExpr (EMatch (EVar "r") (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "Pass") (ELit (LString "Ok _"))) (EVar "a"))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Ok but got ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "Ok _"))) (EVar "a")))))))
(DTypeSig true "expectErr" (TyConstrained ((cstr "Debug" (TyVar "e")) (cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectErr" ((PVar "r")) (EBlock (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "r"))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" PWild) () (EApp (EApp (EVar "Pass") (ELit (LString "Err _"))) (EVar "a"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Err but got ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "Err _"))) (EVar "a")))))))
(DTypeSig true "expectSome" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectSome" ((PVar "o")) (EBlock (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "o"))) (DoExpr (EMatch (EVar "o") (arm (PCon "Some" PWild) () (EApp (EApp (EVar "Pass") (ELit (LString "Some _"))) (EVar "a"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Some but got ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "Some _"))) (EVar "a")))))))
(DTypeSig true "expectNone" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectNone" ((PVar "o")) (EBlock (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "o"))) (DoExpr (EMatch (EVar "o") (arm (PCon "None") () (EApp (EApp (EVar "Pass") (ELit (LString "None"))) (EVar "a"))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected None but got ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "None"))) (EVar "a")))))))
(DTypeSig true "expectWithin" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Expectation")))))
(DFunDef false "expectWithin" ((PVar "expected") (PVar "actual") (PVar "eps")) (EBlock (DoLet false false (PVar "e") (EApp (EMethodRef "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "approxEq") (EVar "expected")) (EVar "actual")) (EVar "eps")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString " within "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "eps")))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig false "normalizeTrailingUnit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normalizeTrailingUnit" ((PVar "s")) (EMatch (EApp (EApp (EVar "stripSuffix") (ELit (LString "()"))) (EVar "s")) (arm (PCon "Some" (PVar "s2")) () (EVar "s2")) (arm (PCon "None") () (EApp (EApp (EVar "optionOr") (EVar "s")) (EApp (EApp (EVar "stripSuffix") (ELit (LString "0"))) (EVar "s"))))))
(DTypeSig false "diffLineMsg" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "diffLineMsg" ((PVar "n") (PList) (PList)) (ELit (LString "expected and actual differ only outside their lines")))
(DFunDef false "diffLineMsg" ((PVar "n") (PList) (PCons (PVar "a") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ": expected nothing but got "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "a")))) (ELit (LString ""))))
(DFunDef false "diffLineMsg" ((PVar "n") (PCons (PVar "e") PWild) (PList)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ": expected "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "e")))) (ELit (LString " but got nothing"))))
(DFunDef false "diffLineMsg" ((PVar "n") (PCons (PVar "e") (PVar "es")) (PCons (PVar "a") (PVar "asL"))) (EIf (EBinOp "==" (EVar "e") (EVar "a")) (EApp (EApp (EApp (EVar "diffLineMsg") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "es")) (EVar "asL")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ": expected "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "e")))) (ELit (LString " but got "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "a")))) (ELit (LString "")))))
(DTypeSig true "expectEqualText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Expectation"))))
(DFunDef false "expectEqualText" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "normalizeTrailingUnit") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "normalizeTrailingUnit") (EVar "actual"))) (DoExpr (EIf (EBinOp "==" (EVar "e") (EVar "a")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EApp (EApp (EApp (EVar "diffLineMsg") (ELit (LInt 1))) (EApp (EVar "lines") (EVar "e"))) (EApp (EVar "lines") (EVar "a")))) (EVar "e")) (EVar "a"))))))
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
(DTypeSig true "expectGolden" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyCon "Expectation")))))
(DFunDef false "expectGolden" ((PVar "path") (PVar "actual")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected golden ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (ELit (LString ""))) (EVar "actual"))) (arm (PCon "Ok" (PVar "golden")) () (EApp (EApp (EVar "expectEqualText") (EVar "golden")) (EVar "actual")))))
(DProp false "Eq Expectation separates constructors and payloads" ((pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "pass") (EVar "pass")) (EBinOp "==" (EApp (EVar "fail") (EVar "m")) (EApp (EVar "fail") (EVar "m")))) (EBinOp "==" (EBinOp "==" (EVar "pass") (EApp (EVar "fail") (EVar "m"))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EApp (EVar "fail") (EVar "m")) (EApp (EVar "fail") (EBinOp "++" (EVar "m") (ELit (LString "!"))))) (EVar "False"))))
(DProp false "a passing expectEqual carries both rendered operands" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EDictApp "expectEqual") (EVar "n")) (EVar "n")) (EApp (EApp (EVar "Pass") (EApp (EMethodRef "debug") (EVar "n"))) (EApp (EMethodRef "debug") (EVar "n")))))
(DProp false "Debug Expectation agrees with Eq" ((pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "==" (EApp (EMethodRef "debug") (EApp (EVar "fail") (EVar "m"))) (EApp (EMethodRef "debug") (EApp (EVar "fail") (EVar "m")))) (EBinOp "==" (EBinOp "==" (EApp (EMethodRef "debug") (EApp (EVar "fail") (EVar "m"))) (EApp (EMethodRef "debug") (EVar "pass"))) (EVar "False"))))
