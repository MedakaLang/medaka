# test

Assertions for unit tests.

An assertion produces an `Expectation`: `Pass` or `Fail`, each carrying
the rendered operands the assertion compared, so a reader (or a driver
reading a compiled probe's output) sees the values and not just a
verdict. Write a test as `test "name" = expectEqual expected actual`,
and run the file with `medaka test`, which also runs the doctests and
`prop` declarations it finds. `runTests` runs a list of tests from an
ordinary program instead.

Import what you need: `import test.{expectEqual, expectTrue}`.

### `Expectation`

```
data Expectation
  = Pass String String
  | Fail String String String
```

The result of one assertion.

Both outcomes carry the two operands as rendered text, so a caller can
report or re-compare them without the `Eq` or `Debug` instance the
assertion itself used. `Fail` carries a message ahead of them. An
assertion with nothing to show (`pass`, `fail`) renders both operands
as the empty string.

Instances: `Eq`, `Debug`

## Assertions

### `pass`

```
pass : Expectation
```

An assertion that always passes.

```medaka
> pass
Pass "" ""
```

### `fail`

```
fail : String -> Expectation
```

An assertion that fails with a message.

```medaka
> fail "not ready"
Fail "not ready" "" ""
```

### `expectTrue`

```
expectTrue : Bool -> Expectation
```

Passes when the value is `True`.

```medaka
> expectTrue True
Pass "True" "True"
> expectTrue False
Fail "expected True but got False" "True" "False"
```

### `expectFalse`

```
expectFalse : Bool -> Expectation
```

Passes when the value is `False`.

```medaka
> expectFalse False
Pass "False" "False"
> expectFalse True
Fail "expected False but got True" "False" "True"
```

### `expectEqual`

```
expectEqual : (Eq a, Debug a) => a -> a -> Expectation
```

Passes when the two values are equal.

The operands, and the message, name both values in their `debug` form.

```medaka
> expectEqual 42 42
Pass "42" "42"
> expectEqual 1 2
Fail "expected 1 but got 2" "1" "2"
```

### `expectNotEqual`

```
expectNotEqual : (Eq a, Debug a) => a -> a -> Expectation
```

Passes when the two values differ.

```medaka
> expectNotEqual 1 2
Pass "1" "2"
> expectNotEqual 1 1
Fail "expected values to differ but both were 1" "1" "1"
```

### `expectLessThan`

```
expectLessThan : (Ord a, Debug a) => a -> a -> Expectation
```

Passes when `actual` is less than `expected`.

```medaka
> expectLessThan 10 3
Pass "10" "3"
> expectLessThan 10 15
Fail "expected 15 < 10" "10" "15"
```

### `expectGreaterThan`

```
expectGreaterThan : (Ord a, Debug a) => a -> a -> Expectation
```

Passes when `actual` is greater than `expected`.

```medaka
> expectGreaterThan 0 5
Pass "0" "5"
> expectGreaterThan 10 3
Fail "expected 3 > 10" "10" "3"
```

### `expectOk`

```
expectOk : (Debug e, Debug a) => Result e a -> Expectation
```

Passes when the result is `Ok`.

```medaka
> expectOk (Ok 1)
Pass "Ok _" "Ok 1"
> expectOk (Err "boom")
Fail "expected Ok but got Err \"boom\"" "Ok _" "Err \"boom\""
```

### `expectErr`

```
expectErr : (Debug e, Debug a) => Result e a -> Expectation
```

Passes when the result is `Err`.

```medaka
> expectErr (Err "boom")
Pass "Err _" "Err \"boom\""
> expectErr (Ok 1)
Fail "expected Err but got Ok 1" "Err _" "Ok 1"
```

### `expectSome`

```
expectSome : Debug a => Option a -> Expectation
```

Passes when the option is `Some`.

```medaka
> expectSome (Some 1)
Pass "Some _" "Some 1"
> expectSome None
Fail "expected Some but got None" "Some _" "None"
```

### `expectNone`

```
expectNone : Debug a => Option a -> Expectation
```

Passes when the option is `None`.

```medaka
> expectNone None
Pass "None" "None"
> expectNone (Some 1)
Fail "expected None but got Some 1" "None" "Some 1"
```

### `expectWithin`

```
expectWithin : Float -> Float -> Float -> Expectation
```

Passes when `actual` is within `eps` of `expected`.

```medaka
> expectWithin 1.0 1.0005 0.01
Pass "1.0" "1.0005"
> expectWithin 1.0 2.0 0.01
Fail "expected 2.0 within 0.01 of 1.0" "1.0" "2.0"
```

### `expectEqualText`

```
expectEqualText : String -> String -> Expectation
```

Passes when two texts are equal after normalizing one trailing
auto-printed Unit shape: a trailing `()` suffix, or a last line that is
exactly `0`. Ordinary text ending in the digit `0` is NOT touched — only
a `0` occupying the whole last line normalizes.

A mismatch names the first differing line, 1-indexed, rather than
dumping both texts whole.

```medaka
> expectEqualText "same" "same"
Pass "same" "same"
> expectEqualText "result()" "result"
Pass "result" "result"
> expectEqualText "value: 10" "value: 1"
Fail "line 1: expected \"value: 10\" but got \"value: 1\"" "value: 10" "value: 1"
```

### `expectAll`

```
expectAll : List Expectation -> Expectation
```

Passes when every expectation in the list passes.

The result is the first `Fail`, when there is one.

```medaka
> expectAll [pass, pass, pass]
Pass "" ""
> expectAll [pass, fail "oops", pass]
Fail "oops" "" ""
```

## Running tests

### `runTests`

```
runTests : List (String, Unit -> Expectation) -> <IO> Bool
```

Runs a list of named tests, printing each result and a summary.

Each test is a name and a function from `Unit` to an `Expectation`.
Returns `True` when every test passes.

## Golden files

### `expectGolden`

```
expectGolden : String -> String -> <FileRead _> Expectation
```

Compares `actual` against the golden file at `path`, via
`expectEqualText`.

Read-only: never writes or blesses a golden. A read failure (most often
a golden that does not exist yet) surfaces as a `Fail` naming it, so a
caller doesn't need a separate branch for "no golden" versus "golden
didn't match."

```medaka
> expectGolden "stdlib/no-such-golden-doctest-fixture.golden" "hello"
Fail "expected golden stdlib/no-such-golden-doctest-fixture.golden: No such file or directory" "" "hello"
```

## Instances

