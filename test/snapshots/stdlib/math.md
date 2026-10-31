# META
source_lines=473
stages=DESUGAR,MARK
# SOURCE
{- | Floating-point math and a few integer helpers.

   The libm functions (`sqrt`, `exp`, `log`, `sin`, `pow`, `floor`, and the
   rest) and the constants `pi` and `e` are primitives, in scope everywhere
   without an import; see the `runtime` page. This module adds the
   functions built on them: angle conversion, float predicates,
   interpolation, and exact integer division, `gcd`, `lcm`, and `powInt`.

   `abs`, `signum`, `min`, `max`, and `clamp` come from the prelude and
   work on floats already. -}

import list.{drop, sort}

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

-- # Statistics

{- | The arithmetic mean of a list, or `None` for an empty list.

   The elements are added in floating point, so the last digits can differ
   from Python's statistics module, which sums exactly.

   > mean [1.0, 2.0, 3.0, 6.0]
   Some 3.0
   > mean []
   None -}
export
mean : List Float -> Option Float
mean [] = None
mean xs = Some (meanOf xs)

-- The mean of a non-empty list.
meanOf : List Float -> Float
meanOf xs = sum xs / intToFloat (length xs)

{- | The median of a list, or `None` for an empty list.

   For an odd length it is the middle value, and for an even length the mean
   of the two middle values. A NaN in the list gives an unspecified result.

   For an even length the result can differ in the last digit from
   `percentile 50.0`, which interpolates instead of averaging.

   > median [3.0, 1.0, 2.0]
   Some 2.0
   > median [4.0, 1.0, 3.0, 2.0]
   Some 2.5
   > median [1.0, 2.0, 1.0 / 0.0]
   Some 2.0 -}
export
median : List Float -> Option Float
median xs = medianSorted (length xs) (sort xs)

medianSorted : Int -> List Float -> Option Float
medianSorted 0 _ = None
medianSorted n sorted =
  let half = n / 2
  match drop (if isEven n then half - 1 else half) sorted
    a :: b :: _ => Some (if isEven n then (a + b) / 2.0 else a)
    a :: _ => Some a
    [] => None

{- | The sample standard deviation, dividing by `n - 1` as Python's
   statistics module does, or `None` for fewer than two values.

   The sums are taken in floating point, so the last digits can differ from
   Python's statistics module, which sums exactly. A NaN in the list gives an
   unspecified result.

   > stdev [1.0, 3.0]
   Some 1.4142135623730951
   > stdev [1.0]
   None -}
export
stdev : List Float -> Option Float
stdev xs
  | length xs < 2 = None
  | otherwise =
    let m = meanOf xs
    let squares = sum (map (x => (x - m) * (x - m)) xs)
    Some (sqrt (squares / intToFloat (length xs - 1)))

{- | The `p`th percentile of a list, for `p` from 0 to 100, or `None` for an
   empty list or a `p` outside that range.

   It interpolates linearly between the closest ranks of the sorted list, as
   numpy's default and Excel's inclusive percentile do, and an exact rank gives
   that element itself. A NaN in the list gives an unspecified result.

   For an odd length `percentile 50.0 xs` equals `median xs`; for an even
   length the two can differ in the last digit.

   > percentile 0.0 [4.0, 1.0, 3.0, 2.0]
   Some 1.0
   > percentile 50.0 [4.0, 1.0, 3.0, 2.0]
   Some 2.5
   > percentile 100.0 [4.0, 1.0, 3.0, 2.0]
   Some 4.0
   > percentile 100.0 [1.0, 1.0 / 0.0]
   Some inf
   > percentile 101.0 [1.0]
   None -}
export
percentile : Float -> List Float -> Option Float
percentile p xs
  | isNaN p || p < 0.0 || p > 100.0 = None
  | otherwise = interpolateRank (p / 100.0) (sort xs)

-- numpy's interpolation: exact at both ends. At `t == 0.0` it is `a` without reading
-- `b`, which may be infinite.
rankLerp : Float -> Float -> Float -> Float
rankLerp a b t
  | t == 0.0 = a
  | t >= 0.5 = b - (b - a) * (1.0 - t)
  | otherwise = a + (b - a) * t

-- `sorted` is ascending; the rank `q * (n - 1)` falls between two neighbours.
interpolateRank : Float -> List Float -> Option Float
interpolateRank _ [] = None
interpolateRank q sorted =
  let rank = q * intToFloat (length sorted - 1)
  let lo = floatToInt (floor rank)
  let t = rank - intToFloat lo
  match drop lo sorted
    a :: b :: _ => Some (rankLerp a b t)
    a :: _ => Some a
    [] => None

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

-- # Rounding to integers

{- | The integer nearest to `x`, with a half rounded away from zero.

   Values outside the `Int` range saturate to the nearest bound, and `NaN`
   gives `0`.

   > roundInt 2.5
   3
   > roundInt (-2.5)
   -3 -}
export
roundInt : Float -> Int
roundInt x = floatToInt (round x)

-- > roundInt 0.4
-- 0
-- > roundInt 1.0e20
-- 4611686018427387903
-- > roundInt (0.0 - 1.0e20)
-- -4611686018427387904
-- > roundInt (0.0 / 0.0)
-- 0

{- | The greatest integer not above `x`.

   Values outside the `Int` range saturate to the nearest bound, and `NaN`
   gives `0`.

   > floorInt 3.7
   3
   > floorInt (-0.5)
   -1 -}
export
floorInt : Float -> Int
floorInt x = floatToInt (floor x)

-- > floorInt (0.0 - 1.0e20)
-- -4611686018427387904
-- > floorInt (0.0 / 0.0)
-- 0

{- | The least integer not below `x`.

   Values outside the `Int` range saturate to the nearest bound, and `NaN`
   gives `0`.

   > ceilInt 3.2
   4
   > ceilInt (-0.5)
   0 -}
export
ceilInt : Float -> Int
ceilInt x = floatToInt (ceil x)

-- > ceilInt 1.0e20
-- 4611686018427387903
-- > ceilInt (0.0 / 0.0)
-- 0

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
floorMod a b =
  let r = a % b
  if r /= 0 && r < 0 /= (b < 0) then r + b else r

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
gcd a b = 0 - gcdGo (negMagnitude a) (negMagnitude b)

-- > gcd 17 5
-- 1
-- > gcd intMinBound 6
-- 2

-- Euclid on non-positive values: `intMinBound` has no positive `Int`, so the
-- magnitudes are negated rather than made positive, and only a result of 2^62
-- (the gcd of `intMinBound` with itself or with 0) cannot be returned.
gcdGo : Int -> Int -> Int
gcdGo a 0 = a
gcdGo a b = gcdGo b (a % b)

negMagnitude : Int -> Int
negMagnitude n = if n > 0 then 0 - n else n

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

-- The base is squared only while bits of `n` remain, so the last square, which
-- the result never uses, is not computed (it can pass `Int` when the result
-- does not).
powGo : Int -> Int -> Int -> Int
powGo _ 0 acc = acc
powGo b n acc =
  let acc2 = if n % 2 == 1 then acc * b else acc
  if n / 2 == 0 then acc2 else powGo (b * b) (n / 2) acc2

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
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "sort" false))))
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
(DTypeSig true "mean" (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "mean" ((PList)) (EVar "None"))
(DFunDef false "mean" ((PVar "xs")) (EApp (EVar "Some") (EApp (EVar "meanOf") (EVar "xs"))))
(DTypeSig false "meanOf" (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyCon "Float")))
(DFunDef false "meanOf" ((PVar "xs")) (EBinOp "/" (EApp (EVar "sum") (EVar "xs")) (EApp (EVar "intToFloat") (EApp (EVar "length") (EVar "xs")))))
(DTypeSig true "median" (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "median" ((PVar "xs")) (EApp (EApp (EVar "medianSorted") (EApp (EVar "length") (EVar "xs"))) (EApp (EVar "sort") (EVar "xs"))))
(DTypeSig false "medianSorted" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float")))))
(DFunDef false "medianSorted" ((PLit (LInt 0)) PWild) (EVar "None"))
(DFunDef false "medianSorted" ((PVar "n") (PVar "sorted")) (EBlock (DoLet false false (PVar "half") (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (DoExpr (EMatch (EApp (EApp (EVar "drop") (EIf (EApp (EVar "isEven") (EVar "n")) (EBinOp "-" (EVar "half") (ELit (LInt 1))) (EVar "half"))) (EVar "sorted")) (arm (PCons (PVar "a") (PCons (PVar "b") PWild)) () (EApp (EVar "Some") (EIf (EApp (EVar "isEven") (EVar "n")) (EBinOp "/" (EBinOp "+" (EVar "a") (EVar "b")) (ELit (LFloat 2.0))) (EVar "a")))) (arm (PCons (PVar "a") PWild) () (EApp (EVar "Some") (EVar "a"))) (arm (PList) () (EVar "None"))))))
(DTypeSig true "stdev" (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "stdev" ((PVar "xs")) (EIf (EBinOp "<" (EApp (EVar "length") (EVar "xs")) (ELit (LInt 2))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "m") (EApp (EVar "meanOf") (EVar "xs"))) (DoLet false false (PVar "squares") (EApp (EVar "sum") (EApp (EApp (EVar "map") (ELam ((PVar "x")) (EBinOp "*" (EBinOp "-" (EVar "x") (EVar "m")) (EBinOp "-" (EVar "x") (EVar "m"))))) (EVar "xs")))) (DoExpr (EApp (EVar "Some") (EApp (EVar "sqrt") (EBinOp "/" (EVar "squares") (EApp (EVar "intToFloat") (EBinOp "-" (EApp (EVar "length") (EVar "xs")) (ELit (LInt 1))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "percentile" (TyFun (TyCon "Float") (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float")))))
(DFunDef false "percentile" ((PVar "p") (PVar "xs")) (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "isNaN") (EVar "p")) (EBinOp "<" (EVar "p") (ELit (LFloat 0.0)))) (EBinOp ">" (EVar "p") (ELit (LFloat 100.0)))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "interpolateRank") (EBinOp "/" (EVar "p") (ELit (LFloat 100.0)))) (EApp (EVar "sort") (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "rankLerp" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float")))))
(DFunDef false "rankLerp" ((PVar "a") (PVar "b") (PVar "t")) (EIf (EBinOp "==" (EVar "t") (ELit (LFloat 0.0))) (EVar "a") (EIf (EBinOp ">=" (EVar "t") (ELit (LFloat 0.5))) (EBinOp "-" (EVar "b") (EBinOp "*" (EBinOp "-" (EVar "b") (EVar "a")) (EBinOp "-" (ELit (LFloat 1.0)) (EVar "t")))) (EIf (EVar "otherwise") (EBinOp "+" (EVar "a") (EBinOp "*" (EBinOp "-" (EVar "b") (EVar "a")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "interpolateRank" (TyFun (TyCon "Float") (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float")))))
(DFunDef false "interpolateRank" (PWild (PList)) (EVar "None"))
(DFunDef false "interpolateRank" ((PVar "q") (PVar "sorted")) (EBlock (DoLet false false (PVar "rank") (EBinOp "*" (EVar "q") (EApp (EVar "intToFloat") (EBinOp "-" (EApp (EVar "length") (EVar "sorted")) (ELit (LInt 1)))))) (DoLet false false (PVar "lo") (EApp (EVar "floatToInt") (EApp (EVar "floor") (EVar "rank")))) (DoLet false false (PVar "t") (EBinOp "-" (EVar "rank") (EApp (EVar "intToFloat") (EVar "lo")))) (DoExpr (EMatch (EApp (EApp (EVar "drop") (EVar "lo")) (EVar "sorted")) (arm (PCons (PVar "a") (PCons (PVar "b") PWild)) () (EApp (EVar "Some") (EApp (EApp (EApp (EVar "rankLerp") (EVar "a")) (EVar "b")) (EVar "t")))) (arm (PCons (PVar "a") PWild) () (EApp (EVar "Some") (EVar "a"))) (arm (PList) () (EVar "None"))))))
(DTypeSig true "logBase" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DFunDef false "logBase" ((PVar "base") (PVar "x")) (EBinOp "/" (EApp (EVar "log") (EVar "x")) (EApp (EVar "log") (EVar "base"))))
(DTypeSig true "roundInt" (TyFun (TyCon "Float") (TyCon "Int")))
(DFunDef false "roundInt" ((PVar "x")) (EApp (EVar "floatToInt") (EApp (EVar "round") (EVar "x"))))
(DTypeSig true "floorInt" (TyFun (TyCon "Float") (TyCon "Int")))
(DFunDef false "floorInt" ((PVar "x")) (EApp (EVar "floatToInt") (EApp (EVar "floor") (EVar "x"))))
(DTypeSig true "ceilInt" (TyFun (TyCon "Float") (TyCon "Int")))
(DFunDef false "ceilInt" ((PVar "x")) (EApp (EVar "floatToInt") (EApp (EVar "ceil") (EVar "x"))))
(DTypeSig true "floorDiv" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "floorDiv" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "q") (EBinOp "/" (EVar "a") (EVar "b"))) (DoLet false false (PVar "r") (EBinOp "-" (EVar "a") (EBinOp "*" (EVar "q") (EVar "b")))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "r") (ELit (LInt 0))) (EBinOp "/=" (EBinOp "<" (EVar "r") (ELit (LInt 0))) (EBinOp "<" (EVar "b") (ELit (LInt 0))))) (EBinOp "-" (EVar "q") (ELit (LInt 1))) (EVar "q")))))
(DTypeSig true "floorMod" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "floorMod" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "r") (EBinOp "%" (EVar "a") (EVar "b"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "r") (ELit (LInt 0))) (EBinOp "/=" (EBinOp "<" (EVar "r") (ELit (LInt 0))) (EBinOp "<" (EVar "b") (ELit (LInt 0))))) (EBinOp "+" (EVar "r") (EVar "b")) (EVar "r")))))
(DTypeSig true "gcd" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gcd" ((PVar "a") (PVar "b")) (EBinOp "-" (ELit (LInt 0)) (EApp (EApp (EVar "gcdGo") (EApp (EVar "negMagnitude") (EVar "a"))) (EApp (EVar "negMagnitude") (EVar "b")))))
(DTypeSig false "gcdGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gcdGo" ((PVar "a") (PLit (LInt 0))) (EVar "a"))
(DFunDef false "gcdGo" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "gcdGo") (EVar "b")) (EBinOp "%" (EVar "a") (EVar "b"))))
(DTypeSig false "negMagnitude" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "negMagnitude" ((PVar "n")) (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")))
(DTypeSig true "lcm" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lcm" ((PLit (LInt 0)) PWild) (ELit (LInt 0)))
(DFunDef false "lcm" (PWild (PLit (LInt 0))) (ELit (LInt 0)))
(DFunDef false "lcm" ((PVar "a") (PVar "b")) (EApp (EVar "absInt") (EBinOp "*" (EBinOp "/" (EVar "a") (EApp (EApp (EVar "gcd") (EVar "a")) (EVar "b"))) (EVar "b"))))
(DTypeSig true "powInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "powInt" (PWild (PLit (LInt 0))) (ELit (LInt 1)))
(DFunDef false "powInt" ((PVar "b") (PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LInt 1)) (EApp (EApp (EApp (EVar "powGo") (EVar "b")) (EVar "n")) (ELit (LInt 1)))))
(DTypeSig false "powGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "powGo" (PWild (PLit (LInt 0)) (PVar "acc")) (EVar "acc"))
(DFunDef false "powGo" ((PVar "b") (PVar "n") (PVar "acc")) (EBlock (DoLet false false (PVar "acc2") (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1))) (EBinOp "*" (EVar "acc") (EVar "b")) (EVar "acc"))) (DoExpr (EIf (EBinOp "==" (EBinOp "/" (EVar "n") (ELit (LInt 2))) (ELit (LInt 0))) (EVar "acc2") (EApp (EApp (EApp (EVar "powGo") (EBinOp "*" (EVar "b") (EVar "b"))) (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "acc2"))))))
(DTypeSig false "absInt" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "absInt" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")))
(DProp false "gcd is commutative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "gcd") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "gcd") (EVar "b")) (EVar "a"))))
(DProp false "gcd divides both arguments (when nonzero)" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EBlock (DoLet false false (PVar "g") (EApp (EApp (EVar "gcd") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "||" (EApp (EApp (EVar "eq") (EVar "g")) (ELit (LInt 0))) (EBinOp "&&" (EBinOp "==" (EBinOp "%" (EVar "a") (EVar "g")) (ELit (LInt 0))) (EBinOp "==" (EBinOp "%" (EVar "b") (EVar "g")) (ELit (LInt 0))))))))
(DProp false "lcm is commutative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "lcm") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "lcm") (EVar "b")) (EVar "a"))))
(DProp false "powInt b 2 equals b * b" ((pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 2)))) (EBinOp "*" (EVar "b") (EVar "b"))))
(DProp false "powInt b 1 equals b" ((pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 1)))) (EVar "b")))
(DProp false "powInt b 0 equals 1" ((pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 0)))) (ELit (LInt 1))))
# MARK
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "sort" false))))
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
(DTypeSig true "mean" (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "mean" ((PList)) (EVar "None"))
(DFunDef false "mean" ((PVar "xs")) (EApp (EVar "Some") (EApp (EVar "meanOf") (EVar "xs"))))
(DTypeSig false "meanOf" (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyCon "Float")))
(DFunDef false "meanOf" ((PVar "xs")) (EBinOp "/" (EApp (EDictApp "sum") (EVar "xs")) (EApp (EVar "intToFloat") (EApp (EMethodRef "length") (EVar "xs")))))
(DTypeSig true "median" (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "median" ((PVar "xs")) (EApp (EApp (EVar "medianSorted") (EApp (EMethodRef "length") (EVar "xs"))) (EApp (EVar "sort") (EVar "xs"))))
(DTypeSig false "medianSorted" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float")))))
(DFunDef false "medianSorted" ((PLit (LInt 0)) PWild) (EVar "None"))
(DFunDef false "medianSorted" ((PVar "n") (PVar "sorted")) (EBlock (DoLet false false (PVar "half") (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (DoExpr (EMatch (EApp (EApp (EVar "drop") (EIf (EApp (EVar "isEven") (EVar "n")) (EBinOp "-" (EVar "half") (ELit (LInt 1))) (EVar "half"))) (EVar "sorted")) (arm (PCons (PVar "a") (PCons (PVar "b") PWild)) () (EApp (EVar "Some") (EIf (EApp (EVar "isEven") (EVar "n")) (EBinOp "/" (EBinOp "+" (EVar "a") (EVar "b")) (ELit (LFloat 2.0))) (EVar "a")))) (arm (PCons (PVar "a") PWild) () (EApp (EVar "Some") (EVar "a"))) (arm (PList) () (EVar "None"))))))
(DTypeSig true "stdev" (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "stdev" ((PVar "xs")) (EIf (EBinOp "<" (EApp (EMethodRef "length") (EVar "xs")) (ELit (LInt 2))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "m") (EApp (EVar "meanOf") (EVar "xs"))) (DoLet false false (PVar "squares") (EApp (EDictApp "sum") (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (EBinOp "*" (EBinOp "-" (EVar "x") (EVar "m")) (EBinOp "-" (EVar "x") (EVar "m"))))) (EVar "xs")))) (DoExpr (EApp (EVar "Some") (EApp (EVar "sqrt") (EBinOp "/" (EVar "squares") (EApp (EVar "intToFloat") (EBinOp "-" (EApp (EMethodRef "length") (EVar "xs")) (ELit (LInt 1))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "percentile" (TyFun (TyCon "Float") (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float")))))
(DFunDef false "percentile" ((PVar "p") (PVar "xs")) (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "isNaN") (EVar "p")) (EBinOp "<" (EVar "p") (ELit (LFloat 0.0)))) (EBinOp ">" (EVar "p") (ELit (LFloat 100.0)))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "interpolateRank") (EBinOp "/" (EVar "p") (ELit (LFloat 100.0)))) (EApp (EVar "sort") (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "rankLerp" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float")))))
(DFunDef false "rankLerp" ((PVar "a") (PVar "b") (PVar "t")) (EIf (EBinOp "==" (EVar "t") (ELit (LFloat 0.0))) (EVar "a") (EIf (EBinOp ">=" (EVar "t") (ELit (LFloat 0.5))) (EBinOp "-" (EVar "b") (EBinOp "*" (EBinOp "-" (EVar "b") (EVar "a")) (EBinOp "-" (ELit (LFloat 1.0)) (EVar "t")))) (EIf (EVar "otherwise") (EBinOp "+" (EVar "a") (EBinOp "*" (EBinOp "-" (EVar "b") (EVar "a")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "interpolateRank" (TyFun (TyCon "Float") (TyFun (TyApp (TyCon "List") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float")))))
(DFunDef false "interpolateRank" (PWild (PList)) (EVar "None"))
(DFunDef false "interpolateRank" ((PVar "q") (PVar "sorted")) (EBlock (DoLet false false (PVar "rank") (EBinOp "*" (EVar "q") (EApp (EVar "intToFloat") (EBinOp "-" (EApp (EMethodRef "length") (EVar "sorted")) (ELit (LInt 1)))))) (DoLet false false (PVar "lo") (EApp (EVar "floatToInt") (EApp (EVar "floor") (EVar "rank")))) (DoLet false false (PVar "t") (EBinOp "-" (EVar "rank") (EApp (EVar "intToFloat") (EVar "lo")))) (DoExpr (EMatch (EApp (EApp (EVar "drop") (EVar "lo")) (EVar "sorted")) (arm (PCons (PVar "a") (PCons (PVar "b") PWild)) () (EApp (EVar "Some") (EApp (EApp (EApp (EVar "rankLerp") (EVar "a")) (EVar "b")) (EVar "t")))) (arm (PCons (PVar "a") PWild) () (EApp (EVar "Some") (EVar "a"))) (arm (PList) () (EVar "None"))))))
(DTypeSig true "logBase" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DFunDef false "logBase" ((PVar "base") (PVar "x")) (EBinOp "/" (EApp (EVar "log") (EVar "x")) (EApp (EVar "log") (EVar "base"))))
(DTypeSig true "roundInt" (TyFun (TyCon "Float") (TyCon "Int")))
(DFunDef false "roundInt" ((PVar "x")) (EApp (EVar "floatToInt") (EApp (EVar "round") (EVar "x"))))
(DTypeSig true "floorInt" (TyFun (TyCon "Float") (TyCon "Int")))
(DFunDef false "floorInt" ((PVar "x")) (EApp (EVar "floatToInt") (EApp (EVar "floor") (EVar "x"))))
(DTypeSig true "ceilInt" (TyFun (TyCon "Float") (TyCon "Int")))
(DFunDef false "ceilInt" ((PVar "x")) (EApp (EVar "floatToInt") (EApp (EVar "ceil") (EVar "x"))))
(DTypeSig true "floorDiv" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "floorDiv" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "q") (EBinOp "/" (EVar "a") (EVar "b"))) (DoLet false false (PVar "r") (EBinOp "-" (EVar "a") (EBinOp "*" (EVar "q") (EVar "b")))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "r") (ELit (LInt 0))) (EBinOp "/=" (EBinOp "<" (EVar "r") (ELit (LInt 0))) (EBinOp "<" (EVar "b") (ELit (LInt 0))))) (EBinOp "-" (EVar "q") (ELit (LInt 1))) (EVar "q")))))
(DTypeSig true "floorMod" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "floorMod" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "r") (EBinOp "%" (EVar "a") (EVar "b"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "r") (ELit (LInt 0))) (EBinOp "/=" (EBinOp "<" (EVar "r") (ELit (LInt 0))) (EBinOp "<" (EVar "b") (ELit (LInt 0))))) (EBinOp "+" (EVar "r") (EVar "b")) (EVar "r")))))
(DTypeSig true "gcd" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gcd" ((PVar "a") (PVar "b")) (EBinOp "-" (ELit (LInt 0)) (EApp (EApp (EVar "gcdGo") (EApp (EVar "negMagnitude") (EVar "a"))) (EApp (EVar "negMagnitude") (EVar "b")))))
(DTypeSig false "gcdGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gcdGo" ((PVar "a") (PLit (LInt 0))) (EVar "a"))
(DFunDef false "gcdGo" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "gcdGo") (EVar "b")) (EBinOp "%" (EVar "a") (EVar "b"))))
(DTypeSig false "negMagnitude" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "negMagnitude" ((PVar "n")) (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")))
(DTypeSig true "lcm" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lcm" ((PLit (LInt 0)) PWild) (ELit (LInt 0)))
(DFunDef false "lcm" (PWild (PLit (LInt 0))) (ELit (LInt 0)))
(DFunDef false "lcm" ((PVar "a") (PVar "b")) (EApp (EVar "absInt") (EBinOp "*" (EBinOp "/" (EVar "a") (EApp (EApp (EVar "gcd") (EVar "a")) (EVar "b"))) (EVar "b"))))
(DTypeSig true "powInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "powInt" (PWild (PLit (LInt 0))) (ELit (LInt 1)))
(DFunDef false "powInt" ((PVar "b") (PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LInt 1)) (EApp (EApp (EApp (EVar "powGo") (EVar "b")) (EVar "n")) (ELit (LInt 1)))))
(DTypeSig false "powGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "powGo" (PWild (PLit (LInt 0)) (PVar "acc")) (EVar "acc"))
(DFunDef false "powGo" ((PVar "b") (PVar "n") (PVar "acc")) (EBlock (DoLet false false (PVar "acc2") (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1))) (EBinOp "*" (EVar "acc") (EVar "b")) (EVar "acc"))) (DoExpr (EIf (EBinOp "==" (EBinOp "/" (EVar "n") (ELit (LInt 2))) (ELit (LInt 0))) (EVar "acc2") (EApp (EApp (EApp (EVar "powGo") (EBinOp "*" (EVar "b") (EVar "b"))) (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "acc2"))))))
(DTypeSig false "absInt" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "absInt" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")))
(DProp false "gcd is commutative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "gcd") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "gcd") (EVar "b")) (EVar "a"))))
(DProp false "gcd divides both arguments (when nonzero)" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EBlock (DoLet false false (PVar "g") (EApp (EApp (EVar "gcd") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "||" (EApp (EApp (EMethodRef "eq") (EVar "g")) (ELit (LInt 0))) (EBinOp "&&" (EBinOp "==" (EBinOp "%" (EVar "a") (EVar "g")) (ELit (LInt 0))) (EBinOp "==" (EBinOp "%" (EVar "b") (EVar "g")) (ELit (LInt 0))))))))
(DProp false "lcm is commutative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "lcm") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "lcm") (EVar "b")) (EVar "a"))))
(DProp false "powInt b 2 equals b * b" ((pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 2)))) (EBinOp "*" (EVar "b") (EVar "b"))))
(DProp false "powInt b 1 equals b" ((pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 1)))) (EVar "b")))
(DProp false "powInt b 0 equals 1" ((pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 0)))) (ELit (LInt 1))))
