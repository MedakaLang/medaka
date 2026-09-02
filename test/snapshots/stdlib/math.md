# META
source_lines=293
stages=DESUGAR,MARK
# SOURCE
{- | Floating-point math and a few integer helpers.

   The libm functions (`sqrt`, `exp`, `log`, `sin`, `pow`, `floor`, and the
   rest) and the constants `pi` and `e` are primitives, in scope everywhere
   without an import; see the `runtime` page. This module adds the
   functions built on them: angle conversion, float predicates,
   interpolation, and exact integer division, `gcd`, `lcm`, and `powInt`.

   `abs`, `signum`, `min`, `max`, and `clamp` come from the prelude and
   work on floats already.

   The float functions run on the native backend only. On the WebAssembly
   backend they trap. -}

-- Wasm currently ports only five float externs; every other float extern
-- (including this batch and the pre-existing `floatRem`) routes to a trap on
-- the WasmGC backend.  The transcendentals need a host-import seam or a
-- polyfill and are deferred.

-- # Angles

{- | An angle in degrees converted to radians.

   > toRadians 0.0
   0.0 -}
export
toRadians : Float -> Float
toRadians deg = deg * pi / 180.0

{- | An angle in radians converted to degrees.

   > toDegrees 0.0
   0.0 -}
export
toDegrees : Float -> Float
toDegrees rad = rad * 180.0 / pi

-- # Float predicates

{- | Whether `x` is NaN, the one value not equal to itself.

   > isNaN 1.0
   False -}
export
isNaN : Float -> Bool
isNaN x = x /= x

-- A finite `x` has `x - x == 0.0`; an infinite `x` has `x - x == NaN`.
{- | Whether `x` is positive or negative infinity.

   > isInfinite 1.0
   False -}
export
isInfinite : Float -> Bool
isInfinite x = not (isNaN x) && isNaN (x - x)

{- | Whether `x` is an ordinary number: neither NaN nor infinite.

   > isFinite 1.0
   True -}
export
isFinite : Float -> Bool
isFinite x = not (isNaN x) && not (isInfinite x)

-- # Interpolation

{- | The point a fraction `t` of the way from `a` to `b`: `a + (b - a) * t`.

   `t` is not clamped, so a value outside `[0.0, 1.0]` extrapolates.
   `lerp a b (clamp 0.0 1.0 t)` is the clamped form.

   > lerp 0.0 10.0 0.5
   5.0
   > lerp 0.0 10.0 2.0
   20.0 -}
export
lerp : Float -> Float -> Float -> Float
lerp a b t = a + (b - a) * t

-- > lerp 0.0 10.0 0.0
-- 0.0
-- > lerp 0.0 10.0 1.0
-- 10.0
-- > lerp 0.0 10.0 (0.0 - 1.0)
-- -10.0

{- | Whether `a` and `b` differ by at most `eps`.

   The tolerance is absolute, so choose `eps` to suit the magnitude of the
   values. `False` whenever either value is NaN, and also for two equal
   infinities, since their difference is NaN.

   > approxEq 1.0 1.0000001 0.001
   True
   > approxEq 1.0 2.0 0.001
   False -}
export
approxEq : Float -> Float -> Float -> Bool
approxEq a b eps = abs (a - b) <= eps

-- > approxEq 0.0 0.0 0.0
-- True

-- # Logarithms

{- | The logarithm of `x` in base `base`, computed as `log x / log base`.

   Subject to floating-point rounding, so `logBase 10.0 1000.0` is not
   exactly `3.0`.

   > logBase 2.0 8.0
   3.0 -}
export
logBase : Float -> Float -> Float
logBase base x = log x / log base

-- > logBase 10.0 1000.0
-- 2.9999999999999996

-- # Integers

{- | Division rounding the quotient towards negative infinity.

   The `/` operator rounds towards zero, so the two differ on negative
   operands. This is the form that calendar and index arithmetic want.

   > floorDiv 7 3
   2
   > floorDiv (0 - 7) 3
   -3 -}
export
floorDiv : Int -> Int -> Int
floorDiv a b =
  let q = a / b
  let r = a - q * b
  if r /= 0 && r < 0 /= (b < 0) then q - 1 else q

-- > floorDiv 7 (0 - 3)
-- -3
-- > floorDiv (0 - 7) (0 - 3)
-- 2
-- > floorDiv 0 5
-- 0

{- | The remainder that goes with `floorDiv`, taking the sign of the
   divisor.

   `floorDiv a b * b + floorMod a b` is always `a`. The `%` operator takes
   the sign of the dividend instead.

   > floorMod 7 3
   1
   > floorMod (0 - 7) 3
   2 -}
export
floorMod : Int -> Int -> Int
floorMod a b = a - floorDiv a b * b

-- > floorMod 7 (0 - 3)
-- -2
-- > floorMod (0 - 7) (0 - 3)
-- -1
-- > floorMod 0 5
-- 0

{- | The greatest common divisor, never negative.

   `gcd 0 0` is `0`.

   > gcd 12 18
   6 -}
export
gcd : Int -> Int -> Int
gcd a b = gcdGo (absInt a) (absInt b)

-- > gcd 17 5
-- 1

gcdGo : Int -> Int -> Int
gcdGo a 0 = a
gcdGo a b = gcdGo b (a % b)

{- | The least common multiple, never negative.

   `0` when either argument is `0`.

   > lcm 4 6
   12 -}
export
lcm : Int -> Int -> Int
lcm 0 _ = 0
lcm _ 0 = 0
lcm a b = absInt (a / gcd a b * b)

-- > lcm 3 5
-- 15

-- Keeps its `Int` suffix while `gcd`/`lcm` lost theirs: `runtime.pow` is an
-- extern, in scope unqualified everywhere, and a `math.pow` would meet it
-- head-on in that scope.
{- | `b` raised to the integer power `n`.

   `1` when `n <= 0`. `pow` is the float form.

   > powInt 2 10
   1024 -}
export
powInt : Int -> Int -> Int
powInt _ 0 = 1
powInt b n = if n < 0 then 1 else powGo b n 1

-- > powInt 3 0
-- 1
-- > powInt 5 3
-- 125

powGo : Int -> Int -> Int -> Int
powGo _ 0 acc = acc
powGo b n acc =
  let acc2 = if n % 2 == 1 then acc * b else acc
  powGo (b * b) (n / 2) acc2

-- Absolute value on Int (local helper: core's `abs` is a Num method but a
-- monomorphic helper keeps the fast integer path here self-contained).
absInt : Int -> Int
absInt n = if n < 0 then 0 - n else n

-- ── Doctests for a sample of the raw libm externs (native only) ─────────
-- These externs come straight from runtime.mdk; a representative sample is
-- doctested here since being in this module's scope re-exposes them.
--
-- > sqrt 4.0
-- 2.0
-- > sqrt 9.0
-- 3.0
-- > cbrt 8.0
-- 2.0
-- > exp 0.0
-- 1.0
-- > log e
-- 1.0
-- > log2 8.0
-- 3.0
-- > log10 1000.0
-- 3.0
-- > sin 0.0
-- 0.0
-- > cos 0.0
-- 1.0
-- > tan 0.0
-- 0.0
-- > asin 0.0
-- 0.0
-- > acos 1.0
-- 0.0
-- > atan 0.0
-- 0.0
-- > sinh 0.0
-- 0.0
-- > cosh 0.0
-- 1.0
-- > tanh 0.0
-- 0.0
-- > floor 3.7
-- 3.0
-- > ceil 3.2
-- 4.0
-- > round 2.5
-- 3.0
-- > trunc 3.9
-- 3.0
-- > pow 2.0 3.0
-- 8.0
-- > atan2 0.0 1.0
-- 0.0
-- > hypot 3.0 4.0
-- 5.0

-- ── Property tests (integer helpers — exact, sign-safe) ─────────────────

prop "gcd is commutative" (a : Int) (b : Int) = eq (gcd a b) (gcd b a)

prop "gcd divides both arguments (when nonzero)" (a : Int) (b : Int) =
  let g = gcd a b
  eq g 0 || a % g == 0 && b % g == 0

prop "lcm is commutative" (a : Int) (b : Int) = eq (lcm a b) (lcm b a)

prop "powInt b 2 equals b * b" (b : Int) = eq (powInt b 2) (b * b)

prop "powInt b 1 equals b" (b : Int) = eq (powInt b 1) b

prop "powInt b 0 equals 1" (b : Int) = eq (powInt b 0) 1
# DESUGAR
(DTypeSig true "toRadians" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "toRadians" ((PVar "deg")) (EBinOp "/" (EBinOp "*" (EVar "deg") (EVar "pi")) (ELit (LFloat 180.0))))
(DTypeSig true "toDegrees" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "toDegrees" ((PVar "rad")) (EBinOp "/" (EBinOp "*" (EVar "rad") (ELit (LFloat 180.0))) (EVar "pi")))
(DTypeSig true "isNaN" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "isNaN" ((PVar "x")) (EBinOp "/=" (EVar "x") (EVar "x")))
(DTypeSig true "isInfinite" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "isInfinite" ((PVar "x")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isNaN") (EVar "x"))) (EApp (EVar "isNaN") (EBinOp "-" (EVar "x") (EVar "x")))))
(DTypeSig true "isFinite" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "isFinite" ((PVar "x")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isNaN") (EVar "x"))) (EApp (EVar "not") (EApp (EVar "isInfinite") (EVar "x")))))
(DTypeSig true "lerp" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float")))))
(DFunDef false "lerp" ((PVar "a") (PVar "b") (PVar "t")) (EBinOp "+" (EVar "a") (EBinOp "*" (EBinOp "-" (EVar "b") (EVar "a")) (EVar "t"))))
(DTypeSig true "approxEq" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Bool")))))
(DFunDef false "approxEq" ((PVar "a") (PVar "b") (PVar "eps")) (EBinOp "<=" (EApp (EVar "abs") (EBinOp "-" (EVar "a") (EVar "b"))) (EVar "eps")))
(DTypeSig true "logBase" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DFunDef false "logBase" ((PVar "base") (PVar "x")) (EBinOp "/" (EApp (EVar "log") (EVar "x")) (EApp (EVar "log") (EVar "base"))))
(DTypeSig true "floorDiv" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "floorDiv" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "q") (EBinOp "/" (EVar "a") (EVar "b"))) (DoLet false false (PVar "r") (EBinOp "-" (EVar "a") (EBinOp "*" (EVar "q") (EVar "b")))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "r") (ELit (LInt 0))) (EBinOp "/=" (EBinOp "<" (EVar "r") (ELit (LInt 0))) (EBinOp "<" (EVar "b") (ELit (LInt 0))))) (EBinOp "-" (EVar "q") (ELit (LInt 1))) (EVar "q")))))
(DTypeSig true "floorMod" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "floorMod" ((PVar "a") (PVar "b")) (EBinOp "-" (EVar "a") (EBinOp "*" (EApp (EApp (EVar "floorDiv") (EVar "a")) (EVar "b")) (EVar "b"))))
(DTypeSig true "gcd" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gcd" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "gcdGo") (EApp (EVar "absInt") (EVar "a"))) (EApp (EVar "absInt") (EVar "b"))))
(DTypeSig false "gcdGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gcdGo" ((PVar "a") (PLit (LInt 0))) (EVar "a"))
(DFunDef false "gcdGo" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "gcdGo") (EVar "b")) (EBinOp "%" (EVar "a") (EVar "b"))))
(DTypeSig true "lcm" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lcm" ((PLit (LInt 0)) PWild) (ELit (LInt 0)))
(DFunDef false "lcm" (PWild (PLit (LInt 0))) (ELit (LInt 0)))
(DFunDef false "lcm" ((PVar "a") (PVar "b")) (EApp (EVar "absInt") (EBinOp "*" (EBinOp "/" (EVar "a") (EApp (EApp (EVar "gcd") (EVar "a")) (EVar "b"))) (EVar "b"))))
(DTypeSig true "powInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "powInt" (PWild (PLit (LInt 0))) (ELit (LInt 1)))
(DFunDef false "powInt" ((PVar "b") (PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LInt 1)) (EApp (EApp (EApp (EVar "powGo") (EVar "b")) (EVar "n")) (ELit (LInt 1)))))
(DTypeSig false "powGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "powGo" (PWild (PLit (LInt 0)) (PVar "acc")) (EVar "acc"))
(DFunDef false "powGo" ((PVar "b") (PVar "n") (PVar "acc")) (EBlock (DoLet false false (PVar "acc2") (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1))) (EBinOp "*" (EVar "acc") (EVar "b")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EVar "powGo") (EBinOp "*" (EVar "b") (EVar "b"))) (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "acc2")))))
(DTypeSig false "absInt" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "absInt" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")))
(DProp false "gcd is commutative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "gcd") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "gcd") (EVar "b")) (EVar "a"))))
(DProp false "gcd divides both arguments (when nonzero)" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EBlock (DoLet false false (PVar "g") (EApp (EApp (EVar "gcd") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "||" (EApp (EApp (EVar "eq") (EVar "g")) (ELit (LInt 0))) (EBinOp "&&" (EBinOp "==" (EBinOp "%" (EVar "a") (EVar "g")) (ELit (LInt 0))) (EBinOp "==" (EBinOp "%" (EVar "b") (EVar "g")) (ELit (LInt 0))))))))
(DProp false "lcm is commutative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "lcm") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "lcm") (EVar "b")) (EVar "a"))))
(DProp false "powInt b 2 equals b * b" ((pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 2)))) (EBinOp "*" (EVar "b") (EVar "b"))))
(DProp false "powInt b 1 equals b" ((pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 1)))) (EVar "b")))
(DProp false "powInt b 0 equals 1" ((pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 0)))) (ELit (LInt 1))))
# MARK
(DTypeSig true "toRadians" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "toRadians" ((PVar "deg")) (EBinOp "/" (EBinOp "*" (EVar "deg") (EVar "pi")) (ELit (LFloat 180.0))))
(DTypeSig true "toDegrees" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "toDegrees" ((PVar "rad")) (EBinOp "/" (EBinOp "*" (EVar "rad") (ELit (LFloat 180.0))) (EVar "pi")))
(DTypeSig true "isNaN" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "isNaN" ((PVar "x")) (EBinOp "/=" (EVar "x") (EVar "x")))
(DTypeSig true "isInfinite" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "isInfinite" ((PVar "x")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isNaN") (EVar "x"))) (EApp (EVar "isNaN") (EBinOp "-" (EVar "x") (EVar "x")))))
(DTypeSig true "isFinite" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "isFinite" ((PVar "x")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isNaN") (EVar "x"))) (EApp (EVar "not") (EApp (EVar "isInfinite") (EVar "x")))))
(DTypeSig true "lerp" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float")))))
(DFunDef false "lerp" ((PVar "a") (PVar "b") (PVar "t")) (EBinOp "+" (EVar "a") (EBinOp "*" (EBinOp "-" (EVar "b") (EVar "a")) (EVar "t"))))
(DTypeSig true "approxEq" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Bool")))))
(DFunDef false "approxEq" ((PVar "a") (PVar "b") (PVar "eps")) (EBinOp "<=" (EApp (EMethodRef "abs") (EBinOp "-" (EVar "a") (EVar "b"))) (EVar "eps")))
(DTypeSig true "logBase" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DFunDef false "logBase" ((PVar "base") (PVar "x")) (EBinOp "/" (EApp (EVar "log") (EVar "x")) (EApp (EVar "log") (EVar "base"))))
(DTypeSig true "floorDiv" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "floorDiv" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "q") (EBinOp "/" (EVar "a") (EVar "b"))) (DoLet false false (PVar "r") (EBinOp "-" (EVar "a") (EBinOp "*" (EVar "q") (EVar "b")))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "r") (ELit (LInt 0))) (EBinOp "/=" (EBinOp "<" (EVar "r") (ELit (LInt 0))) (EBinOp "<" (EVar "b") (ELit (LInt 0))))) (EBinOp "-" (EVar "q") (ELit (LInt 1))) (EVar "q")))))
(DTypeSig true "floorMod" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "floorMod" ((PVar "a") (PVar "b")) (EBinOp "-" (EVar "a") (EBinOp "*" (EApp (EApp (EVar "floorDiv") (EVar "a")) (EVar "b")) (EVar "b"))))
(DTypeSig true "gcd" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gcd" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "gcdGo") (EApp (EVar "absInt") (EVar "a"))) (EApp (EVar "absInt") (EVar "b"))))
(DTypeSig false "gcdGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gcdGo" ((PVar "a") (PLit (LInt 0))) (EVar "a"))
(DFunDef false "gcdGo" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "gcdGo") (EVar "b")) (EBinOp "%" (EVar "a") (EVar "b"))))
(DTypeSig true "lcm" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lcm" ((PLit (LInt 0)) PWild) (ELit (LInt 0)))
(DFunDef false "lcm" (PWild (PLit (LInt 0))) (ELit (LInt 0)))
(DFunDef false "lcm" ((PVar "a") (PVar "b")) (EApp (EVar "absInt") (EBinOp "*" (EBinOp "/" (EVar "a") (EApp (EApp (EVar "gcd") (EVar "a")) (EVar "b"))) (EVar "b"))))
(DTypeSig true "powInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "powInt" (PWild (PLit (LInt 0))) (ELit (LInt 1)))
(DFunDef false "powInt" ((PVar "b") (PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LInt 1)) (EApp (EApp (EApp (EVar "powGo") (EVar "b")) (EVar "n")) (ELit (LInt 1)))))
(DTypeSig false "powGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "powGo" (PWild (PLit (LInt 0)) (PVar "acc")) (EVar "acc"))
(DFunDef false "powGo" ((PVar "b") (PVar "n") (PVar "acc")) (EBlock (DoLet false false (PVar "acc2") (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1))) (EBinOp "*" (EVar "acc") (EVar "b")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EVar "powGo") (EBinOp "*" (EVar "b") (EVar "b"))) (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "acc2")))))
(DTypeSig false "absInt" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "absInt" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")))
(DProp false "gcd is commutative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "gcd") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "gcd") (EVar "b")) (EVar "a"))))
(DProp false "gcd divides both arguments (when nonzero)" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EBlock (DoLet false false (PVar "g") (EApp (EApp (EVar "gcd") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "||" (EApp (EApp (EMethodRef "eq") (EVar "g")) (ELit (LInt 0))) (EBinOp "&&" (EBinOp "==" (EBinOp "%" (EVar "a") (EVar "g")) (ELit (LInt 0))) (EBinOp "==" (EBinOp "%" (EVar "b") (EVar "g")) (ELit (LInt 0))))))))
(DProp false "lcm is commutative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "lcm") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "lcm") (EVar "b")) (EVar "a"))))
(DProp false "powInt b 2 equals b * b" ((pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 2)))) (EBinOp "*" (EVar "b") (EVar "b"))))
(DProp false "powInt b 1 equals b" ((pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 1)))) (EVar "b")))
(DProp false "powInt b 0 equals 1" ((pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 0)))) (ELit (LInt 1))))
