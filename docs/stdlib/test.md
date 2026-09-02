# test

Assertions for unit tests.

An assertion produces an `Expectation`: `Pass`, or `Fail` with a
message. Write a test as `test "name" = expectEqual expected actual`,
and run the file with `medaka test`, which also runs the doctests and
`prop` declarations it finds. `runTests` runs a list of tests from an
ordinary program instead.

Import what you need: `import test.{expectEqual, expectTrue}`.

### `Expectation`

```
data Expectation
  = Pass
  | Fail String
```

The result of one assertion.

Instances: `Eq`, `Debug`

## Assertions

### `pass`

```
pass : Expectation
```

An assertion that always passes.

```medaka
> pass
Pass
```

### `fail`

```
fail : String -> Expectation
```

An assertion that fails with a message.

```medaka
> fail "not ready"
Fail "not ready"
```

### `expectTrue`

```
expectTrue : Bool -> Expectation
```

Passes when the value is `True`.

```medaka
> expectTrue True
Pass
> expectTrue False
Fail "expected True but got False"
```

### `expectFalse`

```
expectFalse : Bool -> Expectation
```

Passes when the value is `False`.

```medaka
> expectFalse False
Pass
> expectFalse True
Fail "expected False but got True"
```

### `expectEqual`

```
expectEqual : (Eq a, Debug a) => a -> a -> Expectation
```

Passes when the two values are equal.

The message names both values in their `debug` form.

```medaka
> expectEqual 42 42
Pass
> expectEqual 1 2
Fail "expected 1 but got 2"
```

### `expectNotEqual`

```
expectNotEqual : (Eq a, Debug a) => a -> a -> Expectation
```

Passes when the two values differ.

```medaka
> expectNotEqual 1 2
Pass
> expectNotEqual 1 1
Fail "expected values to differ but both were 1"
```

### `expectLessThan`

```
expectLessThan : (Ord a, Debug a) => a -> a -> Expectation
```

Passes when `actual` is less than `expected`.

```medaka
> expectLessThan 10 3
Pass
> expectLessThan 10 15
Fail "expected 15 < 10"
```

### `expectGreaterThan`

```
expectGreaterThan : (Ord a, Debug a) => a -> a -> Expectation
```

Passes when `actual` is greater than `expected`.

```medaka
> expectGreaterThan 0 5
Pass
> expectGreaterThan 10 3
Fail "expected 3 > 10"
```

### `expectAll`

```
expectAll : List Expectation -> Expectation
```

Passes when every expectation in the list passes.

The result is the first `Fail`, when there is one.

```medaka
> expectAll [Pass, Pass, Pass]
Pass
> expectAll [Pass, Fail "oops", Pass]
Fail "oops"
```

## Running tests

### `runTests`

```
runTests : List (String, Unit -> Expectation) -> <IO> Bool
```

Runs a list of named tests, printing each result and a summary.

Each test is a name and a function from `Unit` to an `Expectation`.
Returns `True` when every test passes.

## Instances

