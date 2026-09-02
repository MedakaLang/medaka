# META
source_lines=178
stages=DESUGAR,MARK
# SOURCE
{- | A result type that collects every error instead of stopping at the
   first.

   `Validation e a` has the same shape as `Result e a`, with `Failure` and
   `Success` in place of `Err` and `Ok`. Its `Applicative` instance
   combines the errors of two failures with `++`, so validating several
   independent fields reports every problem at once. Convert with
   `toResult` and `fromResult`.

   There is no `Thenable` instance: sequencing with `andThen` has to stop
   at the first failure, which is the opposite of accumulating. To
   sequence, convert to a `Result` first.

   `toResult` and `fromResult` share their names with prelude functions on
   `Option`. Import this module qualified, `import validation as V`, and
   write `V.toResult`. -}

import core.{
  Result,
  Ok,
  Err,
  Mappable,
  Applicative,
  Semigroup,
  Eq,
  Debug,
  Display,
  Foldable,
  Traversable,
}

{- | A validated value: `Success` with the value, or `Failure` with the
   accumulated errors.

   > toResult (Success 1)
   Ok 1
   > toResult (Failure "bad")
   Err "bad" -}
public export data Validation e a = Failure e | Success a

export impl Mappable (Validation e) where
  map f (Success a) = Success (f a)
  map _ (Failure e) = Failure e

{- | `ap` combines the errors of two failures with `++`, so a chain of
   validations collects every error.

   > toResult (ap (Failure ["bad name"] : Validation (List String) (Int -> Int)) (Failure ["bad age"] : Validation (List String) Int))
   Err ["bad name", "bad age"] -}
export impl Applicative (Validation e) requires Semigroup e where
  pure a = Success a
  ap (Failure e1) (Failure e2) = Failure (e1 ++ e2)
  ap (Failure e) _ = Failure e
  ap (Success f) v = map f v

-- > toResult (ap (Failure ["bad name"] : Validation (List String) (Int -> Int)) (Success 5 : Validation (List String) Int))
-- Err ["bad name"]
-- > toResult (ap (pure (n => n + 1) : Validation (List String) (Int -> Int)) (Success 5 : Validation (List String) Int))
-- Ok 6

export impl Foldable (Validation e) where
  fold _ acc (Failure _) = acc
  fold f acc (Success x) = f acc x
  foldRight _ acc (Failure _) = acc
  foldRight f acc (Success x) = f x acc
  toList (Failure _) = []
  toList (Success x) = [x]

-- Multi-clause + return-position `pure` loops in eval for Thenable impls;
-- see the note above core.mdk's Traversable impls; do not split.
-- lint-disable-next-line rule-match-on-param
export impl Traversable (Validation e) where
  traverse f v = match v
    Failure e => pure (Failure e)
    Success x => map Success (f x)

export impl Eq (Validation e a) requires Eq e, Eq a where
  eq (Failure x) (Failure y) = eq x y
  eq (Success x) (Success y) = eq x y
  eq _ _ = False

export impl Debug (Validation e a) requires Debug e, Debug a where
  debug (Failure e) = "Failure " ++ debug e
  debug (Success a) = "Success " ++ debug a

{- | `++` combines two failures' errors, combines two successes' values,
   and keeps the failure when there is one of each.

   There is no `Monoid` instance, since no value is an identity on both
   sides.

   > display (append (Failure ["a"] : Validation (List String) (List Int)) (Failure ["b"]))
   "Failure [a, b]"
   > display (append (Success [1] : Validation (List String) (List Int)) (Success [2]))
   "Success [1, 2]" -}
export impl Semigroup (Validation e a) requires Semigroup e, Semigroup a where
  append (Failure x) (Failure y) = Failure (append x y)
  append (Failure x) (Success _) = Failure x
  append (Success _) (Failure y) = Failure y
  append (Success x) (Success y) = Success (append x y)

-- > display (append (Failure ["a"] : Validation (List String) (List Int)) (Success [2]))
-- "Failure [a]"

{- | `display` renders a value as `Success x` or `Failure e`.

   > display (Success 7)
   "Success 7"
   > display (Failure "bad")
   "Failure bad" -}
export impl Display (Validation e a) requires Display e, Display a where
  display (Failure e) = "Failure " ++ display e
  display (Success a) = "Success " ++ display a

{- | The validation as a `Result`, for sequencing with `andThen`.

   > toResult (Success 1)
   Ok 1 -}
export
toResult : Validation e a -> Result e a
toResult (Success a) = Ok a
toResult (Failure e) = Err e

{- | A `Result` as a validation, for combining with others.

   > fromResult (Ok 1 : Result String Int)
   Success 1
   > fromResult (Err "bad" : Result String Int)
   Failure "bad" -}
export
fromResult : Result e a -> Validation e a
fromResult (Ok a) = Success a
fromResult (Err e) = Failure e

-- ─── Property tests ─────────────────────────────────────────────────────

prop "toResult/fromResult round-trip on Success" (n : Int) =
  toResult (fromResult (Ok n : Result Int Int)) == (Ok n : Result Int Int)

prop "toResult/fromResult round-trip on Failure" (n : Int) =
  toResult (fromResult (Err n : Result Int Int)) == (Err n : Result Int Int)

prop "map identity is identity on Success" (n : Int) =
  map identity (Success n : Validation Int Int) == Success n

prop "map identity is identity on Failure" (n : Int) =
  map identity (Failure n : Validation Int Int) == Failure n

-- ── Semigroup laws ──────────────────────────────────────────────────────
-- LAW: associativity, over all eight `Failure`/`Success` combinations of
-- three operands.  Associativity is the ONLY law `Semigroup` has, and a
-- first-failure-wins definition would break it, so this is the whole
-- justification for the instance.

vOf : Bool -> Int -> Validation (List Int) (List Int)
vOf True n = Success [n]
vOf False n = Failure [n]

prop "Semigroup Validation is associative" (p : Bool) (q : Bool) (r : Bool) (n : Int) =
  let a = vOf p n
  let b = vOf q (n + 1)
  let c = vOf r (n + 2)
  append (append a b) c == append a (append b c)

-- LAW: `append` ACCUMULATES on the failure side rather than keeping only the
-- first error -- the property that makes it agree with the accumulating
-- `Applicative` instead of with `Result`'s short-circuit.
prop "Semigroup Validation accumulates both failures" (x : Int) (y : Int) =
  let got =
    append (Failure [x] : Validation (List Int) (List Int)) (Failure [y])
  got == Failure [x, y]

-- LAW: a `Failure` on either side survives -- `append` never upgrades a
-- failure to a success.
prop "Semigroup Validation never discards a failure" (n : Int) (p : Bool) =
  let ok = Success [n] : Validation (List Int) (List Int)
  append (Failure [n]) ok == Failure [n]
    && append ok (Failure [n]) == Failure [n]
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Result" false) (mem "Ok" false) (mem "Err" false) (mem "Mappable" false) (mem "Applicative" false) (mem "Semigroup" false) (mem "Eq" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Traversable" false))))
(DData Public "Validation" ("e" "a") ((variant "Failure" (ConPos (TyVar "e"))) (variant "Success" (ConPos (TyVar "a")))) ())
(DImpl true "Mappable" ((TyApp (TyCon "Validation") (TyVar "e"))) () ((im "map" ((PVar "f") (PCon "Success" (PVar "a"))) (EApp (EVar "Success") (EApp (EVar "f") (EVar "a")))) (im "map" (PWild (PCon "Failure" (PVar "e"))) (EApp (EVar "Failure") (EVar "e")))))
(DImpl true "Applicative" ((TyApp (TyCon "Validation") (TyVar "e"))) ((req "Semigroup" ((TyVar "e")))) ((im "pure" ((PVar "a")) (EApp (EVar "Success") (EVar "a"))) (im "ap" ((PCon "Failure" (PVar "e1")) (PCon "Failure" (PVar "e2"))) (EApp (EVar "Failure") (EBinOp "++" (EVar "e1") (EVar "e2")))) (im "ap" ((PCon "Failure" (PVar "e")) PWild) (EApp (EVar "Failure") (EVar "e"))) (im "ap" ((PCon "Success" (PVar "f")) (PVar "v")) (EApp (EApp (EVar "map") (EVar "f")) (EVar "v")))))
(DImpl true "Foldable" ((TyApp (TyCon "Validation") (TyVar "e"))) () ((im "fold" (PWild (PVar "acc") (PCon "Failure" PWild)) (EVar "acc")) (im "fold" ((PVar "f") (PVar "acc") (PCon "Success" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "x"))) (im "foldRight" (PWild (PVar "acc") (PCon "Failure" PWild)) (EVar "acc")) (im "foldRight" ((PVar "f") (PVar "acc") (PCon "Success" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "x")) (EVar "acc"))) (im "toList" ((PCon "Failure" PWild)) (EListLit)) (im "toList" ((PCon "Success" (PVar "x"))) (EListLit (EVar "x")))))
(DImpl true "Traversable" ((TyApp (TyCon "Validation") (TyVar "e"))) () ((im "traverse" ((PVar "f") (PVar "v")) (EMatch (EVar "v") (arm (PCon "Failure" (PVar "e")) () (EApp (EVar "pure") (EApp (EVar "Failure") (EVar "e")))) (arm (PCon "Success" (PVar "x")) () (EApp (EApp (EVar "map") (EVar "Success")) (EApp (EVar "f") (EVar "x"))))))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Eq" ((TyVar "e"))) (req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "Failure" (PVar "x")) (PCon "Failure" (PVar "y"))) (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y"))) (im "eq" ((PCon "Success" (PVar "x")) (PCon "Success" (PVar "y"))) (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Debug" ((TyVar "e"))) (req "Debug" ((TyVar "a")))) ((im "debug" ((PCon "Failure" (PVar "e"))) (EBinOp "++" (ELit (LString "Failure ")) (EApp (EVar "debug") (EVar "e")))) (im "debug" ((PCon "Success" (PVar "a"))) (EBinOp "++" (ELit (LString "Success ")) (EApp (EVar "debug") (EVar "a"))))))
(DImpl true "Semigroup" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Semigroup" ((TyVar "e"))) (req "Semigroup" ((TyVar "a")))) ((im "append" ((PCon "Failure" (PVar "x")) (PCon "Failure" (PVar "y"))) (EApp (EVar "Failure") (EApp (EApp (EVar "append") (EVar "x")) (EVar "y")))) (im "append" ((PCon "Failure" (PVar "x")) (PCon "Success" PWild)) (EApp (EVar "Failure") (EVar "x"))) (im "append" ((PCon "Success" PWild) (PCon "Failure" (PVar "y"))) (EApp (EVar "Failure") (EVar "y"))) (im "append" ((PCon "Success" (PVar "x")) (PCon "Success" (PVar "y"))) (EApp (EVar "Success") (EApp (EApp (EVar "append") (EVar "x")) (EVar "y"))))))
(DImpl true "Display" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Display" ((TyVar "e"))) (req "Display" ((TyVar "a")))) ((im "display" ((PCon "Failure" (PVar "e"))) (EBinOp "++" (ELit (LString "Failure ")) (EApp (EVar "display") (EVar "e")))) (im "display" ((PCon "Success" (PVar "a"))) (EBinOp "++" (ELit (LString "Success ")) (EApp (EVar "display") (EVar "a"))))))
(DTypeSig true "toResult" (TyFun (TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))))
(DFunDef false "toResult" ((PCon "Success" (PVar "a"))) (EApp (EVar "Ok") (EVar "a")))
(DFunDef false "toResult" ((PCon "Failure" (PVar "e"))) (EApp (EVar "Err") (EVar "e")))
(DTypeSig true "fromResult" (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))))
(DFunDef false "fromResult" ((PCon "Ok" (PVar "a"))) (EApp (EVar "Success") (EVar "a")))
(DFunDef false "fromResult" ((PCon "Err" (PVar "e"))) (EApp (EVar "Failure") (EVar "e")))
(DProp false "toResult/fromResult round-trip on Success" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "toResult") (EApp (EVar "fromResult") (EAnnot (EApp (EVar "Ok") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int"))))) (EAnnot (EApp (EVar "Ok") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))))
(DProp false "toResult/fromResult round-trip on Failure" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "toResult") (EApp (EVar "fromResult") (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int"))))) (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))))
(DProp false "map identity is identity on Success" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "map") (EVar "identity")) (EAnnot (EApp (EVar "Success") (EVar "n")) (TyApp (TyApp (TyCon "Validation") (TyCon "Int")) (TyCon "Int")))) (EApp (EVar "Success") (EVar "n"))))
(DProp false "map identity is identity on Failure" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "map") (EVar "identity")) (EAnnot (EApp (EVar "Failure") (EVar "n")) (TyApp (TyApp (TyCon "Validation") (TyCon "Int")) (TyCon "Int")))) (EApp (EVar "Failure") (EVar "n"))))
(DTypeSig false "vOf" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Validation") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "vOf" ((PCon "True") (PVar "n")) (EApp (EVar "Success") (EListLit (EVar "n"))))
(DFunDef false "vOf" ((PCon "False") (PVar "n")) (EApp (EVar "Failure") (EListLit (EVar "n"))))
(DProp false "Semigroup Validation is associative" ((pp "p" (TyCon "Bool")) (pp "q" (TyCon "Bool")) (pp "r" (TyCon "Bool")) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "vOf") (EVar "p")) (EVar "n"))) (DoLet false false (PVar "b") (EApp (EApp (EVar "vOf") (EVar "q")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoLet false false (PVar "c") (EApp (EApp (EVar "vOf") (EVar "r")) (EBinOp "+" (EVar "n") (ELit (LInt 2))))) (DoExpr (EBinOp "==" (EApp (EApp (EVar "append") (EApp (EApp (EVar "append") (EVar "a")) (EVar "b"))) (EVar "c")) (EApp (EApp (EVar "append") (EVar "a")) (EApp (EApp (EVar "append") (EVar "b")) (EVar "c")))))))
(DProp false "Semigroup Validation accumulates both failures" ((pp "x" (TyCon "Int")) (pp "y" (TyCon "Int"))) (EBlock (DoLet false false (PVar "got") (EApp (EApp (EVar "append") (EAnnot (EApp (EVar "Failure") (EListLit (EVar "x"))) (TyApp (TyApp (TyCon "Validation") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))) (EApp (EVar "Failure") (EListLit (EVar "y"))))) (DoExpr (EBinOp "==" (EVar "got") (EApp (EVar "Failure") (EListLit (EVar "x") (EVar "y")))))))
(DProp false "Semigroup Validation never discards a failure" ((pp "n" (TyCon "Int")) (pp "p" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "ok") (EAnnot (EApp (EVar "Success") (EListLit (EVar "n"))) (TyApp (TyApp (TyCon "Validation") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "append") (EApp (EVar "Failure") (EListLit (EVar "n")))) (EVar "ok")) (EApp (EVar "Failure") (EListLit (EVar "n")))) (EBinOp "==" (EApp (EApp (EVar "append") (EVar "ok")) (EApp (EVar "Failure") (EListLit (EVar "n")))) (EApp (EVar "Failure") (EListLit (EVar "n"))))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Result" false) (mem "Ok" false) (mem "Err" false) (mem "Mappable" false) (mem "Applicative" false) (mem "Semigroup" false) (mem "Eq" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Traversable" false))))
(DData Public "Validation" ("e" "a") ((variant "Failure" (ConPos (TyVar "e"))) (variant "Success" (ConPos (TyVar "a")))) ())
(DImpl true "Mappable" ((TyApp (TyCon "Validation") (TyVar "e"))) () ((im "map" ((PVar "f") (PCon "Success" (PVar "a"))) (EApp (EVar "Success") (EApp (EVar "f") (EVar "a")))) (im "map" (PWild (PCon "Failure" (PVar "e"))) (EApp (EVar "Failure") (EVar "e")))))
(DImpl true "Applicative" ((TyApp (TyCon "Validation") (TyVar "e"))) ((req "Semigroup" ((TyVar "e")))) ((im "pure" ((PVar "a")) (EApp (EVar "Success") (EVar "a"))) (im "ap" ((PCon "Failure" (PVar "e1")) (PCon "Failure" (PVar "e2"))) (EApp (EVar "Failure") (EBinOp "++" (EVar "e1") (EVar "e2")))) (im "ap" ((PCon "Failure" (PVar "e")) PWild) (EApp (EVar "Failure") (EVar "e"))) (im "ap" ((PCon "Success" (PVar "f")) (PVar "v")) (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "v")))))
(DImpl true "Foldable" ((TyApp (TyCon "Validation") (TyVar "e"))) () ((im "fold" (PWild (PVar "acc") (PCon "Failure" PWild)) (EVar "acc")) (im "fold" ((PVar "f") (PVar "acc") (PCon "Success" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "x"))) (im "foldRight" (PWild (PVar "acc") (PCon "Failure" PWild)) (EVar "acc")) (im "foldRight" ((PVar "f") (PVar "acc") (PCon "Success" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "x")) (EVar "acc"))) (im "toList" ((PCon "Failure" PWild)) (EListLit)) (im "toList" ((PCon "Success" (PVar "x"))) (EListLit (EVar "x")))))
(DImpl true "Traversable" ((TyApp (TyCon "Validation") (TyVar "e"))) () ((im "traverse" ((PVar "f") (PVar "v")) (EMatch (EVar "v") (arm (PCon "Failure" (PVar "e")) () (EApp (EMethodRef "pure") (EApp (EVar "Failure") (EVar "e")))) (arm (PCon "Success" (PVar "x")) () (EApp (EApp (EMethodRef "map") (EVar "Success")) (EApp (EVar "f") (EVar "x"))))))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Eq" ((TyVar "e"))) (req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "Failure" (PVar "x")) (PCon "Failure" (PVar "y"))) (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y"))) (im "eq" ((PCon "Success" (PVar "x")) (PCon "Success" (PVar "y"))) (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Debug" ((TyVar "e"))) (req "Debug" ((TyVar "a")))) ((im "debug" ((PCon "Failure" (PVar "e"))) (EBinOp "++" (ELit (LString "Failure ")) (EApp (EMethodRef "debug") (EVar "e")))) (im "debug" ((PCon "Success" (PVar "a"))) (EBinOp "++" (ELit (LString "Success ")) (EApp (EMethodRef "debug") (EVar "a"))))))
(DImpl true "Semigroup" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Semigroup" ((TyVar "e"))) (req "Semigroup" ((TyVar "a")))) ((im "append" ((PCon "Failure" (PVar "x")) (PCon "Failure" (PVar "y"))) (EApp (EVar "Failure") (EApp (EApp (EMethodRef "append") (EVar "x")) (EVar "y")))) (im "append" ((PCon "Failure" (PVar "x")) (PCon "Success" PWild)) (EApp (EVar "Failure") (EVar "x"))) (im "append" ((PCon "Success" PWild) (PCon "Failure" (PVar "y"))) (EApp (EVar "Failure") (EVar "y"))) (im "append" ((PCon "Success" (PVar "x")) (PCon "Success" (PVar "y"))) (EApp (EVar "Success") (EApp (EApp (EMethodRef "append") (EVar "x")) (EVar "y"))))))
(DImpl true "Display" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Display" ((TyVar "e"))) (req "Display" ((TyVar "a")))) ((im "display" ((PCon "Failure" (PVar "e"))) (EBinOp "++" (ELit (LString "Failure ")) (EApp (EMethodRef "display") (EVar "e")))) (im "display" ((PCon "Success" (PVar "a"))) (EBinOp "++" (ELit (LString "Success ")) (EApp (EMethodRef "display") (EVar "a"))))))
(DTypeSig true "toResult" (TyFun (TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))))
(DFunDef false "toResult" ((PCon "Success" (PVar "a"))) (EApp (EVar "Ok") (EVar "a")))
(DFunDef false "toResult" ((PCon "Failure" (PVar "e"))) (EApp (EVar "Err") (EVar "e")))
(DTypeSig true "fromResult" (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))))
(DFunDef false "fromResult" ((PCon "Ok" (PVar "a"))) (EApp (EVar "Success") (EVar "a")))
(DFunDef false "fromResult" ((PCon "Err" (PVar "e"))) (EApp (EVar "Failure") (EVar "e")))
(DProp false "toResult/fromResult round-trip on Success" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "toResult") (EApp (EVar "fromResult") (EAnnot (EApp (EVar "Ok") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int"))))) (EAnnot (EApp (EVar "Ok") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))))
(DProp false "toResult/fromResult round-trip on Failure" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "toResult") (EApp (EVar "fromResult") (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int"))))) (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))))
(DProp false "map identity is identity on Success" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EMethodRef "map") (EVar "identity")) (EAnnot (EApp (EVar "Success") (EVar "n")) (TyApp (TyApp (TyCon "Validation") (TyCon "Int")) (TyCon "Int")))) (EApp (EVar "Success") (EVar "n"))))
(DProp false "map identity is identity on Failure" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EMethodRef "map") (EVar "identity")) (EAnnot (EApp (EVar "Failure") (EVar "n")) (TyApp (TyApp (TyCon "Validation") (TyCon "Int")) (TyCon "Int")))) (EApp (EVar "Failure") (EVar "n"))))
(DTypeSig false "vOf" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Validation") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "vOf" ((PCon "True") (PVar "n")) (EApp (EVar "Success") (EListLit (EVar "n"))))
(DFunDef false "vOf" ((PCon "False") (PVar "n")) (EApp (EVar "Failure") (EListLit (EVar "n"))))
(DProp false "Semigroup Validation is associative" ((pp "p" (TyCon "Bool")) (pp "q" (TyCon "Bool")) (pp "r" (TyCon "Bool")) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "vOf") (EVar "p")) (EVar "n"))) (DoLet false false (PVar "b") (EApp (EApp (EVar "vOf") (EVar "q")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoLet false false (PVar "c") (EApp (EApp (EVar "vOf") (EVar "r")) (EBinOp "+" (EVar "n") (ELit (LInt 2))))) (DoExpr (EBinOp "==" (EApp (EApp (EMethodRef "append") (EApp (EApp (EMethodRef "append") (EVar "a")) (EVar "b"))) (EVar "c")) (EApp (EApp (EMethodRef "append") (EVar "a")) (EApp (EApp (EMethodRef "append") (EVar "b")) (EVar "c")))))))
(DProp false "Semigroup Validation accumulates both failures" ((pp "x" (TyCon "Int")) (pp "y" (TyCon "Int"))) (EBlock (DoLet false false (PVar "got") (EApp (EApp (EMethodRef "append") (EAnnot (EApp (EVar "Failure") (EListLit (EVar "x"))) (TyApp (TyApp (TyCon "Validation") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))) (EApp (EVar "Failure") (EListLit (EVar "y"))))) (DoExpr (EBinOp "==" (EVar "got") (EApp (EVar "Failure") (EListLit (EVar "x") (EVar "y")))))))
(DProp false "Semigroup Validation never discards a failure" ((pp "n" (TyCon "Int")) (pp "p" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "ok") (EAnnot (EApp (EVar "Success") (EListLit (EVar "n"))) (TyApp (TyApp (TyCon "Validation") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EApp (EMethodRef "append") (EApp (EVar "Failure") (EListLit (EVar "n")))) (EVar "ok")) (EApp (EVar "Failure") (EListLit (EVar "n")))) (EBinOp "==" (EApp (EApp (EMethodRef "append") (EVar "ok")) (EApp (EVar "Failure") (EListLit (EVar "n")))) (EApp (EVar "Failure") (EListLit (EVar "n"))))))))
