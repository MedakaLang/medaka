# math

math.mdk — floating-point math: roots, transcendentals, rounding, and a
handful of pure integer helpers.

See STDLIB.md for the module plan.

This is a thin pure-Medaka layer over the libm externs declared in
stdlib/runtime.mdk (`sqrt`/`exp`/`log`/`sin`/… — 22 one- and two-arg
Float functions, each a direct call into the C runtime's math.h shim).
The externs themselves are globally in scope (like every runtime
primitive); this module adds the derived conveniences on top of them.

Constants `pi` and `e` are runtime externs (see runtime.mdk) and are
available unqualified everywhere — this module just documents them here.

── Backend scope ──────────────────────────────────────────────────────
The math externs are NATIVE / LLVM only.  Wasm currently ports only five
float externs; every other float extern (including this batch AND the
pre-existing `floatRem`) routes to a trap on the WasmGC backend.  Wasm
math is a native-only residual: the transcendentals need a host-import
seam or a polyfill and are DEFERRED.  On native (`medaka run` / `build`)
everything here works.

── What is NOT here (already generic in the prelude) ──────────────────
• `abs` / `signum` — `Num Float` methods in core (use them directly).
• `min` / `max` / `clamp` — `Ord`-generic in core; `clamp lo hi x`
already works for Float, so there is no Float-specific `clampF`.

## `toRadians`

```
toRadians : Float -> Float
```

Convert degrees to radians.


*(doctest — run by `medaka test`)*

```medaka
> toRadians 0.0
0.0
```

## `toDegrees`

```
toDegrees : Float -> Float
```

Convert radians to degrees.


*(doctest — run by `medaka test`)*

```medaka
> toDegrees 0.0
0.0
```

## `isNaN`

```
isNaN : Float -> Bool
```

True iff the argument is NaN (the only value not equal to itself).


*(doctest — run by `medaka test`)*

```medaka
> isNaN 1.0
False
```

## `isInfinite`

```
isInfinite : Float -> Bool
```

True iff the argument is positive or negative infinity.  A finite `x`
  has `x - x == 0.0`; an infinite `x` has `x - x == NaN`.


*(doctest — run by `medaka test`)*

```medaka
> isInfinite 1.0
False
```

## `isFinite`

```
isFinite : Float -> Bool
```

True iff the argument is neither NaN nor infinite — i.e. an ordinary,
  representable Float.  The third of the `isNaN`/`isInfinite`/`isFinite`
  trio.


*(doctest — run by `medaka test`)*

```medaka
> isFinite 1.0
True
```

## `lerp`

```
lerp : Float -> Float -> Float -> Float
```

Linear interpolation from `a` (at `t = 0.0`) to `b` (at `t = 1.0`):
  `lerp a b t = a + (b - a) * t`.  `t` is **not clamped** — `t` outside
  `[0.0, 1.0]` extrapolates past `a`/`b` rather than saturating, matching
  the usual graphics convention (GLSL `mix`, Rust's `f64::lerp`) and this
  module's own house style of leaving clamping to the generic `clamp` in
  `core` (see the module header) rather than baking it into every
  interpolant. Compose `lerp a b (clamp 0.0 1.0 t)` for a clamped result.


*(doctest — run by `medaka test`)*

```medaka
> lerp 0.0 10.0 0.5
5.0
> lerp 0.0 10.0 0.0
0.0
> lerp 0.0 10.0 1.0
10.0
> lerp 0.0 10.0 2.0
20.0
> lerp 0.0 10.0 (0.0 - 1.0)
-10.0
```

## `approxEq`

```
approxEq : Float -> Float -> Float -> Bool
```

Approximate equality: `True` iff `|a - b| <= eps`.  Uses an ABSOLUTE
  epsilon (not relative/scale-aware) — the natural choice for a general
  tolerance-compare utility, since a relative epsilon is undefined at
  `a == b == 0.0` and requires a design decision (relative to which
  operand?) this module does not need to make.  Callers comparing
  large-magnitude Floats should pick an `eps` that accounts for scale.

  NaN: `|NaN - x|` is NaN, and every IEEE `<=` involving NaN is `False`
  (this repo's decided semantics — see EMITTER-SEMANTICS.md §4 N5: derived
  `< <= > >=` stay IEEE). So `approxEq NaN NaN eps` is `False` for every
  `eps`, including `NaN` itself — consistent with `isNaN` (`x /= x`) and
  with plain `==` already treating NaN as equal to nothing, itself
  included.

  The same reasoning makes `approxEq Infinity Infinity eps` `False` too
  (not `True`, which may surprise): `Infinity - Infinity` is IEEE NaN, so
  it hits the exact same `NaN <= eps` dead end.  There is no special-cased
  "equal infinities" path — this function is arithmetic-only, on purpose.


*(doctest — run by `medaka test`)*

```medaka
> approxEq 1.0 1.0000001 0.001
True
> approxEq 1.0 2.0 0.001
False
> approxEq 0.0 0.0 0.0
True
```

## `logBase`

```
logBase : Float -> Float -> Float
```

Logarithm of `x` in an arbitrary base: `logBase b x = log x / log b`. Not
  exact in general (it's a log division, IEEE 754 float rounding applies);
  the second example below asserts the real computed value, confirmed
  externally via `python3 -c "import math; print(repr(math.log(1000.0)/math.log(10.0)))"`.


*(doctest — run by `medaka test`)*

```medaka
> logBase 2.0 8.0
3.0
> logBase 10.0 1000.0
2.9999999999999996
```

## `floorDiv`

```
floorDiv : Int -> Int -> Int
```

Floor division: rounds the quotient toward negative infinity, unlike
  Medaka's `/` which truncates toward zero (see `stdlib/runtime.mdk` and
  `compiler/backend/llvm_emit.mdk`'s `sdiv`).  This is the variant index
  arithmetic and calendar math want — `stdlib/time.mdk`'s civil-calendar
  conversion needs it so a negative (pre-1970) epoch second maps to the
  correct earlier day rather than truncating toward 1970.

  Promoted here from a private helper `time.mdk` hand-rolled internally
  (see #433) — this is the SAME algorithm, unchanged, so every caller's
  behavior at negative operands and at zero is unchanged.


*(doctest — run by `medaka test`)*

```medaka
> floorDiv 7 3
2
> floorDiv (0 - 7) 3
-3
> floorDiv 7 (0 - 3)
-3
> floorDiv (0 - 7) (0 - 3)
2
> floorDiv 0 5
0
```

## `floorMod`

```
floorMod : Int -> Int -> Int
```

Floor modulo: the remainder that pairs with `floorDiv`, so
  `floorDiv a b * b + floorMod a b == a` always holds and the result
  takes the SIGN OF THE DIVISOR (unlike `%`, which takes the sign of the
  dividend because it pairs with truncating `/`) — the Python-`%`
  convention, not the C-`%`/Medaka-`%` one.


*(doctest — run by `medaka test`)*

```medaka
> floorMod 7 3
1
> floorMod (0 - 7) 3
2
> floorMod 7 (0 - 3)
-2
> floorMod (0 - 7) (0 - 3)
-1
> floorMod 0 5
0
```

## `gcdInt`

```
gcdInt : Int -> Int -> Int
```

Greatest common divisor via the Euclidean algorithm, on absolute
  values so the result is non-negative.  `gcdInt 0 0 = 0`.


*(doctest — run by `medaka test`)*

```medaka
> gcdInt 12 18
6
> gcdInt 17 5
1
```

## `lcmInt`

```
lcmInt : Int -> Int -> Int
```

Least common multiple, non-negative.  `lcmInt _ 0 = 0`.


*(doctest — run by `medaka test`)*

```medaka
> lcmInt 4 6
12
> lcmInt 3 5
15
```

## `powInt`

```
powInt : Int -> Int -> Int
```

Integer exponentiation by squaring.  A non-positive exponent yields 1
  (the empty product); `powInt b 0 = 1` for any `b`.


*(doctest — run by `medaka test`)*

```medaka
> powInt 2 10
1024
> powInt 3 0
1
> powInt 5 3
125
```

