# test

Assertions for unit tests.

An assertion produces an `Expectation`, `Pass` or `Fail`, carrying the
rendered operands it compared, so a report shows the values and not only
a verdict. Write a test as `test "name" = expectEqual expected actual`
and run the file with `medaka test`, which also runs the file's doctests
and `prop` declarations. `runTests` runs a list of tests from an ordinary
program instead.

### `Expectation`

```
data Expectation
  = Pass String String
  | Fail String String String
```

The result of one assertion.

Both outcomes carry the two operands as rendered text, so a caller can
report them without the `Eq` or `Debug` instance the assertion used.
`Fail` carries a message ahead of them. An assertion with no operands to
show (`pass`, `fail`) renders both as the empty string.

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
fail msg
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

### `expectSatisfies`

```
expectSatisfies : Debug a => String -> (a -> Bool) -> a -> Expectation
expectSatisfies what p x
```

Passes when `x` satisfies `p`, naming the property as `what`.

`what` completes the sentence "expected …", so it names the property
rather than the call: `"a positive number"`, not `"p x"`. The value is
rendered in either outcome.

```medaka
> expectSatisfies "a positive number" (n => n > 0) 3
Pass "a positive number" "3"
> expectSatisfies "a positive number" (n => n > 0) 0
Fail "expected a positive number but got 0" "a positive number" "0"
```

### `expectEqual`

```
expectEqual : (Eq a, Debug a) => a -> a -> Expectation
expectEqual expected actual
```

Passes when the two values are equal.

The operands and the message render both values in their `debug` form.

```medaka
> expectEqual 42 42
Pass "42" "42"
> expectEqual 1 2
Fail "expected 1 but got 2" "1" "2"
```

### `expectNotEqual`

```
expectNotEqual : (Eq a, Debug a) => a -> a -> Expectation
expectNotEqual expected actual
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
expectLessThan expected actual
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
expectGreaterThan expected actual
```

Passes when `actual` is greater than `expected`.

```medaka
> expectGreaterThan 0 5
Pass "0" "5"
> expectGreaterThan 10 3
Fail "expected 3 > 10" "10" "3"
```

### `expectAtLeast`

```
expectAtLeast : (Ord a, Debug a) => a -> a -> Expectation
expectAtLeast floor actual
```

Passes when `actual` is at least `floor`.

Inclusive: `actual` equal to `floor` passes. Use it for a count that is
allowed to grow, where pinning the exact value would fail on every
addition.

```medaka
> expectAtLeast 3 5
Pass "3" "5"
> expectAtLeast 3 2
Fail "expected 2 >= 3" "3" "2"
```

### `expectAtMost`

```
expectAtMost : (Ord a, Debug a) => a -> a -> Expectation
expectAtMost ceiling actual
```

Passes when `actual` is at most `ceiling`.

```medaka
> expectAtMost 3 2
Pass "3" "2"
> expectAtMost 3 5
Fail "expected 5 <= 3" "3" "5"
```

### `expectOk`

```
expectOk : (Debug e, Debug a) => Result e a -> Expectation
expectOk r
```

Passes when the result is `Ok`.

```medaka
> expectOk (Ok 1 : Result String Int)
Pass "Ok _" "Ok 1"
> expectOk (Err "boom" : Result String Int)
Fail "expected Ok but got Err \"boom\"" "Ok _" "Err \"boom\""
```

### `expectErr`

```
expectErr : (Debug e, Debug a) => Result e a -> Expectation
expectErr r
```

Passes when the result is `Err`.

```medaka
> expectErr (Err "boom" : Result String Int)
Pass "Err _" "Err \"boom\""
> expectErr (Ok 1 : Result String Int)
Fail "expected Err but got Ok 1" "Err _" "Ok 1"
```

### `expectErrContains`

```
expectErrContains : (Debug e, Debug a, Display e) => String -> Result e a -> Expectation
expectErrContains needle r
```

Passes when the result is an `Err` whose message contains `needle`.

`needle` is matched against `display e`, the text a caller would print,
not against the `debug` rendering. An `Ok` fails regardless of `needle`.

```medaka
> expectErrContains "no such column" (Err "no such column: age" : Result String Int)
Pass "Err containing \"no such column\"" "Err \"no such column: age\""
> expectErrContains "no such column" (Err "syntax error" : Result String Int)
Fail "expected the error to contain \"no such column\" but got \"syntax error\"" "Err containing \"no such column\"" "Err \"syntax error\""
> expectErrContains "no such column" (Ok 1 : Result String Int)
Fail "expected Err but got Ok 1" "Err containing \"no such column\"" "Ok 1"
```

### `expectOkThen`

```
expectOkThen : (Debug e, Display e) => (a -> Expectation) -> Result e a -> Expectation
expectOkThen k _
```

Runs `k` on the `Ok` payload, or fails naming the error.

The failure message carries `display e`, so a test whose setup step
fails says why. The payload needs no `Debug` instance, so this accepts a
`Result` whose success type derives nothing, which `expectOk` cannot.

```medaka
> expectOkThen (n => expectEqual 1 n) (Ok 1 : Result String Int)
Pass "1" "1"
> expectOkThen (n => expectEqual 1 n) (Err "boom" : Result String Int)
Fail "expected Ok but got Err boom" "Ok _" "Err \"boom\""
```

### `expectSome`

```
expectSome : Debug a => Option a -> Expectation
expectSome o
```

Passes when the option is `Some`.

```medaka
> expectSome (Some 1)
Pass "Some _" "Some 1"
> expectSome (None : Option Int)
Fail "expected Some but got None" "Some _" "None"
```

### `expectNone`

```
expectNone : Debug a => Option a -> Expectation
expectNone o
```

Passes when the option is `None`.

```medaka
> expectNone (None : Option Int)
Pass "None" "None"
> expectNone (Some 1)
Fail "expected None but got Some 1" "None" "Some 1"
```

### `expectWithin`

```
expectWithin : Float -> Float -> Float -> Expectation
expectWithin expected actual eps
```

Passes when `actual` is within `eps` of `expected`.

```medaka
> expectWithin 1.0 1.0005 0.01
Pass "1.0" "1.0005"
> expectWithin 1.0 2.0 0.01
Fail "expected 2.0 within 0.01 of 1.0" "1.0" "2.0"
```

### `expectTextContainsAll`

```
expectTextContainsAll : List String -> String -> Expectation
expectTextContainsAll needles actual
```

Passes when `actual` contains every string in `needles`.

An empty `needles` list passes. On failure the message names the first
missing string, and the operands are the full requirement and the text.

```medaka
> expectationTag (expectTextContainsAll ["alpha", "gamma"] "alpha beta gamma")
"Pass"
> expectationMessage (expectTextContainsAll ["alpha", "delta"] "alpha beta gamma")
"expected text containing \"delta\""
```

### `expectLineContainsAll`

```
expectLineContainsAll : List String -> String -> Expectation
expectLineContainsAll needles actual
```

Passes when one line of `actual` contains every string in `needles`.

The strings must occur on the same line, in any order, so a source
location and its diagnostic can be required together rather than found
in different parts of a report.

```medaka
> expectationTag (expectLineContainsAll ["file.mdk:3:", "bad type"] "error: file.mdk:3: bad type\nhelp")
"Pass"
> expectationTag (expectLineContainsAll ["file.mdk:3:", "bad type"] "file.mdk:3:\nbad type")
"Fail"
```

### `expectTextStartsWithAndContains`

```
expectTextStartsWithAndContains : String -> List String -> String -> Expectation
expectTextStartsWithAndContains prefix needles actual
```

Passes when `actual` begins with `prefix` and contains every string in
`needles`.

```medaka
> expectationTag (expectTextStartsWithAndContains "accepted" ["Env"] "accepted: Env")
"Pass"
> expectationTag (expectTextStartsWithAndContains "accepted" ["Env"] "note: Env accepted")
"Fail"
```

### `expectEqualText`

```
expectEqualText : String -> String -> Expectation
expectEqualText expected actual
```

Passes when two texts are equal after removing one trailing
auto-printed Unit from each: a trailing `()`, or a last line that is
exactly `0`.

Only a `0` occupying the whole last line is removed; text that ends in
the digit `0` is compared as written. A mismatch names the first
differing line, 1-indexed. `expectEqualLines` compares without removing
anything, for text where a trailing `()` or a whole-line `0` is part of
the answer.

```medaka
> expectEqualText "same" "same"
Pass "same" "same"
> expectEqualText "result()" "result"
Pass "result" "result"
> expectEqualText "value: 10" "value: 1"
Fail "line 1: expected \"value: 10\" but got \"value: 1\"" "value: 10" "value: 1"
```

### `expectEqualLines`

```
expectEqualLines : String -> String -> Expectation
expectEqualLines expected actual
```

Passes when two texts are equal, naming the first line at which they
diverge.

Nothing is removed before comparing, so a text whose last line is
exactly `0` compares as itself. Both arguments are whole texts; a caller
holding a list of lines joins them with `"\n"`.

```medaka
> expectEqualLines "a\nb" "a\nb"
Pass "a\nb" "a\nb"
> expectEqualLines "a\nb" "a\nc"
Fail "line 2: expected \"b\" but got \"c\"" "a\nb" "a\nc"
> expectEqualLines "a" "a\nb"
Fail "line 2: expected nothing but got \"b\" (1 line remaining)" "a" "a\nb"
```

### `expectAll`

```
expectAll : List Expectation -> Expectation
expectAll es
```

Passes when every expectation in the list passes.

The result is the first `Fail`, when there is one.

```medaka
> expectAll [pass, pass, pass]
Pass "" ""
> expectAll [pass, fail "oops", pass]
Fail "oops" "" ""
```

### `labelFail`

```
labelFail : String -> Expectation -> Expectation
labelFail label _
```

The expectation with `label` prefixed onto its message when it is a
`Fail`, and unchanged when it is a `Pass`.

`expectAll` reports only the first `Fail`, so a label that says which
row or file failed has to be on the message to survive aggregation.

```medaka
> labelFail "t1" pass
Pass "" ""
> labelFail "t1" (fail "mismatch")
Fail "t1: mismatch" "" ""
```

### `expectEach`

```
expectEach : List (String, Expectation) -> Expectation
expectEach rows
```

Passes when every labelled expectation passes, naming the first that
does not.

The failure message is the row's label followed by its own message, as
in `"users.sql: line 3: …"`.

```medaka
> expectEach [("a", pass), ("b", pass)]
Pass "" ""
> expectEach [("a", pass), ("b", fail "oops")]
Fail "b: oops" "" ""
```

## Grading a check's findings

### `expectNoFindings`

```
expectNoFindings : String -> Result String (List String) -> Expectation
expectNoFindings what _
```

Passes when a check ran and reported nothing.

A check returns `Err` when it could not run and `Ok` with the lines it
found when it did. Both a check that could not run and a check that
found something fail, with different messages and operands. `what`
names the check and heads the failure message.

```medaka
> expectNoFindings "hardening" (Ok [])
Pass "no findings" "no findings"
> expectNoFindings "hardening" (Ok ["pds.service: no MemoryDenyWriteExecute"])
Fail "hardening:\n  pds.service: no MemoryDenyWriteExecute\n" "no findings" "1 findings"
> expectNoFindings "hardening" (Err "could not read pds.service")
Fail "hardening: could not read pds.service" "no findings" "the check could not run"
```

### `expectFindings`

```
expectFindings : String -> Result String (List String) -> Expectation
expectFindings what _
```

Passes when a check ran and reported at least one finding.

The inverse of `expectNoFindings`, for showing that a check can fire.
A check that could not run fails, as does one that reported nothing.
Only the count of findings is reported, not their text.

```medaka
> expectFindings "injected secret" (Ok ["shell.mdk:12: literal token"])
Pass "a finding" "1 findings"
> expectFindings "injected secret" (Ok [])
Fail "injected secret: nothing was reported" "a finding" "no findings"
> expectFindings "injected secret" (Err "could not read shell.mdk")
Fail "injected secret: could not read shell.mdk" "a finding" "the check could not run"
```

## Reading an expectation

### `expectationTag`

```
expectationTag : Expectation -> String
```

The name of the outcome's constructor, `"Pass"` or `"Fail"`.

```medaka
> expectationTag pass
"Pass"
> expectationTag (fail "not ready")
"Fail"
```

### `expectationMessage`

```
expectationMessage : Expectation -> String
```

The failure message, empty for a `Pass`.

```medaka
> expectationMessage (fail "not ready")
"not ready"
> expectationMessage pass
""
```

### `expectationExpected`

```
expectationExpected : Expectation -> String
```

The expected operand as the assertion rendered it.

```medaka
> expectationExpected (expectEqual 1 2)
"1"
```

### `expectationActual`

```
expectationActual : Expectation -> String
```

The actual operand as the assertion rendered it.

```medaka
> expectationActual (expectEqual 1 2)
"2"
```

## Running tests

### `runTests`

```
runTests : List (String, Unit -> Expectation) -> <IO> Bool
runTests tests
```

Runs a list of named tests, printing each result and a summary.

Each test is a name and a function from `Unit` to an `Expectation`.
Returns `True` when every test passes.

## Golden files

### `expectGolden`

```
expectGolden : (path : String) -> String -> <FileRead path> Expectation
expectGolden path actual
```

Compares `actual` against the contents of the golden file at `path`,
via `expectEqualText`.

Never writes the golden. A file that cannot be read, most often a golden
that does not exist yet, is a `Fail` naming the path.

```medaka
> expectGolden "stdlib/no-such-golden-doctest-fixture.golden" "hello"
Fail "expected golden stdlib/no-such-golden-doctest-fixture.golden: No such file or directory" "" "hello"
```

