# test

test.mdk — unit testing library.
Import what you need: `import test.{expectEqual, expectTrue, …}`
Run with: `medaka test your_file.mdk`
See STDLIB.md for the division-of-labour between doctests / props / tests.

## `Expectation`

```
data Expectation
  = Pass
  | Fail String
```

The result of a single test expectation.

## `Eq Expectation`

```
impl Eq Expectation
```

## `Debug Expectation`

```
impl Debug Expectation
```

## `pass`

```
pass : Expectation
```

Always passes.


*(doctest — run by `medaka test`)*

```medaka
> pass
Pass
```

## `fail`

```
fail : String -> Expectation
```

Fails with the given message.


*(doctest — run by `medaka test`)*

```medaka
> fail "not ready"
Fail "not ready"
```

## `expectTrue`

```
expectTrue : Bool -> Expectation
```

Passes when the `Bool` is `True`.


*(doctest — run by `medaka test`)*

```medaka
> expectTrue True
Pass
> expectTrue False
Fail "expected True but got False"
```

## `expectFalse`

```
expectFalse : Bool -> Expectation
```

Passes when the `Bool` is `False`.


*(doctest — run by `medaka test`)*

```medaka
> expectFalse False
Pass
> expectFalse True
Fail "expected False but got True"
```

## `expectEqual`

```
expectEqual : a -> a -> Expectation
```

Passes when the two values are equal.


*(doctest — run by `medaka test`)*

```medaka
> expectEqual 42 42
Pass
> expectEqual 1 2
Fail "expected 1 but got 2"
```

## `expectNotEqual`

```
expectNotEqual : a -> a -> Expectation
```

Passes when the two values are not equal.


*(doctest — run by `medaka test`)*

```medaka
> expectNotEqual 1 2
Pass
> expectNotEqual 1 1
Fail "expected values to differ but both were 1"
```

## `expectLessThan`

```
expectLessThan : a -> a -> Expectation
```

Passes when `actual < expected`.


*(doctest — run by `medaka test`)*

```medaka
> expectLessThan 10 3
Pass
> expectLessThan 10 15
Fail "expected 15 < 10"
```

## `expectGreaterThan`

```
expectGreaterThan : a -> a -> Expectation
```

Passes when `actual > expected`.


*(doctest — run by `medaka test`)*

```medaka
> expectGreaterThan 0 5
Pass
> expectGreaterThan 10 3
Fail "expected 3 > 10"
```

## `expectAll`

```
expectAll : List Expectation -> Expectation
```

Combine a list of expectations: passes only when all of them pass.
The first `Fail` is returned immediately.


*(doctest — run by `medaka test`)*

```medaka
> expectAll [Pass, Pass, Pass]
Pass
> expectAll [Pass, Fail "oops", Pass]
Fail "oops"
```

## `runTests`

```
runTests : List (String, Unit -> Expectation) -> <IO> Bool
```

Run a list of `(name, thunk)` test pairs.  Prints each result and a
final summary; returns `True` when all tests pass.

