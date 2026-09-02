# test

## `Expectation`

```
data Expectation
  = Pass
  | Fail String
```

Instances: `Eq`, `Debug`

The result of a single test expectation.

## `pass`

```
pass : Expectation
```

Always passes.

```medaka
> pass
Pass
```

## `fail`

```
fail : String -> Expectation
```

Fails with the given message.

```medaka
> fail "not ready"
Fail "not ready"
```

## `expectTrue`

```
expectTrue : Bool -> Expectation
```

Passes when the `Bool` is `True`.

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

```medaka
> expectFalse False
Pass
> expectFalse True
Fail "expected False but got True"
```

## `expectEqual`

```
expectEqual : (Eq a, Debug a) => a -> a -> Expectation
```

Passes when the two values are equal.

```medaka
> expectEqual 42 42
Pass
> expectEqual 1 2
Fail "expected 1 but got 2"
```

## `expectNotEqual`

```
expectNotEqual : (Eq a, Debug a) => a -> a -> Expectation
```

Passes when the two values are not equal.

```medaka
> expectNotEqual 1 2
Pass
> expectNotEqual 1 1
Fail "expected values to differ but both were 1"
```

## `expectLessThan`

```
expectLessThan : (Ord a, Debug a) => a -> a -> Expectation
```

Passes when `actual < expected`.

```medaka
> expectLessThan 10 3
Pass
> expectLessThan 10 15
Fail "expected 15 < 10"
```

## `expectGreaterThan`

```
expectGreaterThan : (Ord a, Debug a) => a -> a -> Expectation
```

Passes when `actual > expected`.

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

## Instances

