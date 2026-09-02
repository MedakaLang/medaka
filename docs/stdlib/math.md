# math

Floating-point math and a few integer helpers.

The libm functions (`sqrt`, `exp`, `log`, `sin`, `pow`, `floor`, and the
rest) and the constants `pi` and `e` are primitives, in scope everywhere
without an import; see the `runtime` page. This module adds the
functions built on them: angle conversion, float predicates,
interpolation, and exact integer division, `gcd`, `lcm`, and `powInt`.

`abs`, `signum`, `min`, `max`, and `clamp` come from the prelude and
work on floats already.

The float functions run on the native backend only. On the WebAssembly
backend they trap.

## Angles

### `toRadians`

```
toRadians : Float -> Float
```

An angle in degrees converted to radians.

```medaka
> toRadians 0.0
0.0
```

### `toDegrees`

```
toDegrees : Float -> Float
```

An angle in radians converted to degrees.

```medaka
> toDegrees 0.0
0.0
```

## Float predicates

### `isNaN`

```
isNaN : Float -> Bool
```

Whether `x` is NaN, the one value not equal to itself.

```medaka
> isNaN 1.0
False
```

### `isInfinite`

```
isInfinite : Float -> Bool
```

Whether `x` is positive or negative infinity.

```medaka
> isInfinite 1.0
False
```

### `isFinite`

```
isFinite : Float -> Bool
```

Whether `x` is an ordinary number: neither NaN nor infinite.

```medaka
> isFinite 1.0
True
```

## Interpolation

### `lerp`

```
lerp : Float -> Float -> Float -> Float
```

The point a fraction `t` of the way from `a` to `b`: `a + (b - a) * t`.

`t` is not clamped, so a value outside `[0.0, 1.0]` extrapolates.
`lerp a b (clamp 0.0 1.0 t)` is the clamped form.

```medaka
> lerp 0.0 10.0 0.5
5.0
> lerp 0.0 10.0 2.0
20.0
```

### `approxEq`

```
approxEq : Float -> Float -> Float -> Bool
```

Whether `a` and `b` differ by at most `eps`.

The tolerance is absolute, so choose `eps` to suit the magnitude of the
values. `False` whenever either value is NaN, and also for two equal
infinities, since their difference is NaN.

```medaka
> approxEq 1.0 1.0000001 0.001
True
> approxEq 1.0 2.0 0.001
False
```

## Logarithms

### `logBase`

```
logBase : Float -> Float -> Float
```

The logarithm of `x` in base `base`, computed as `log x / log base`.

Subject to floating-point rounding, so `logBase 10.0 1000.0` is not
exactly `3.0`.

```medaka
> logBase 2.0 8.0
3.0
```

## Integers

### `floorDiv`

```
floorDiv : Int -> Int -> Int
```

Division rounding the quotient towards negative infinity.

The `/` operator rounds towards zero, so the two differ on negative
operands. This is the form that calendar and index arithmetic want.

```medaka
> floorDiv 7 3
2
> floorDiv (0 - 7) 3
-3
```

### `floorMod`

```
floorMod : Int -> Int -> Int
```

The remainder that goes with `floorDiv`, taking the sign of the
divisor.

`floorDiv a b * b + floorMod a b` is always `a`. The `%` operator takes
the sign of the dividend instead.

```medaka
> floorMod 7 3
1
> floorMod (0 - 7) 3
2
```

### `gcd`

```
gcd : Int -> Int -> Int
```

The greatest common divisor, never negative.

`gcd 0 0` is `0`.

```medaka
> gcd 12 18
6
```

### `lcm`

```
lcm : Int -> Int -> Int
```

The least common multiple, never negative.

`0` when either argument is `0`.

```medaka
> lcm 4 6
12
```

### `powInt`

```
powInt : Int -> Int -> Int
```

`b` raised to the integer power `n`.

`1` when `n <= 0`. `pow` is the float form.

```medaka
> powInt 2 10
1024
```

