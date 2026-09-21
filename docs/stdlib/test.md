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

### `expectSatisfies`

```
expectSatisfies : Debug a => String -> (a -> Bool) -> a -> Expectation
```

Passes when `x` satisfies `p`, naming the property as `what`.

The escape hatch for a one-off predicate that no other assertion here
says. `what` completes the sentence "expected …", so it names the
property rather than restating the call: `"a positive number"`, not
`"p x"`. The value is rendered either way, so a failure shows what was
actually tested.

```medaka
> expectSatisfies "a positive number" (n => n > 0) 3
Pass "a positive number" "3"
> expectSatisfies "a positive number" (n => n > 0) 0
Fail "expected a positive number but got 0" "a positive number" "0"
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

### `expectAtLeast`

```
expectAtLeast : (Ord a, Debug a) => a -> a -> Expectation
```

Passes when `actual` is at least `floor`.

The inclusive peer of `expectGreaterThan`, for a count whose exact value
is not the point: a census that must find SOMETHING pins a floor, and
pinning the current count instead would fail on every legitimate growth.

```medaka
> expectAtLeast 3 5
Pass "3" "5"
> expectAtLeast 3 2
Fail "expected 2 >= 3" "3" "2"
```

### `expectAtMost`

```
expectAtMost : (Ord a, Debug a) => a -> a -> Expectation
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
```

Passes when the result is `Err` whose message contains `needle`.

Both halves are required, and for the same reason `expectSpawnFails`
needs both: a rejection graded on the `Err` constructor alone still
passes once the error it was written for has been replaced by a
different one. The needle is matched against `display e`, the sentence a
caller would print, not against `debug e`'s constructor spelling.

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
```

Runs `k` on the `Ok` payload, and fails naming the error otherwise.

The unwrap-or-fail guard, as a verb. A hand-written `match` whose `Err`
arm is `expectTrue False` (or any bare `fail`) throws the error away and
reports only that the step did not reach its assertion; this keeps the
error in the message, which is the only thing that says WHY.

The payload needs no `Debug`, so this reaches a `Result` whose success
type is a program type that derives nothing, the case the plain
`expectOk` cannot take.

```medaka
> expectOkThen (n => expectEqual 1 n) (Ok 1 : Result String Int)
Pass "1" "1"
> expectOkThen (n => expectEqual 1 n) (Err "boom" : Result String Int)
Fail "expected Ok but got Err boom" "Ok _" "Err \"boom\""
```

### `expectSome`

```
expectSome : Debug a => Option a -> Expectation
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
```

Passes when `actual` contains every string in `needles`.

An empty `needles` list passes. On failure, the message names the first
missing string while the operands retain the full requirement and text.

```medaka
> expectationTag (expectTextContainsAll ["alpha", "gamma"] "alpha beta gamma")
"Pass"
> expectationMessage (expectTextContainsAll ["alpha", "delta"] "alpha beta gamma")
"expected text containing \"delta\""
```

### `expectLineContainsAll`

```
expectLineContainsAll : List String -> String -> Expectation
```

Passes when one line of `actual` contains every string in `needles`.

The strings must occur on the same line, in any order. This is useful for
binding a source location to its diagnostic instead of finding each in a
different part of a multi-error report.

```medaka
> expectationTag (expectLineContainsAll ["file.mdk:3:", "bad type"] "error: file.mdk:3: bad type\nhelp")
"Pass"
> expectationTag (expectLineContainsAll ["file.mdk:3:", "bad type"] "file.mdk:3:\nbad type")
"Fail"
```

### `expectTextStartsWithAndContains`

```
expectTextStartsWithAndContains : String -> List String -> String -> Expectation
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
```

Passes when two texts are equal after normalizing one trailing
auto-printed Unit shape: a trailing `()` suffix, or a last line that is
exactly `0`. Ordinary text ending in the digit `0` is NOT touched — only
a `0` occupying the whole last line normalizes.

A mismatch names the first differing line, 1-indexed, rather than
dumping both texts whole. `expectEqualLines` is the sibling that
normalizes nothing, for text where a trailing `()` or a whole-line `0`
is data rather than a driver's artefact.

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
```

Passes when two texts are equal, naming the first line at which they
diverge.

`expectEqualText` without the normalizer: nothing is stripped, so a text
whose last line is exactly `0` compares as itself. A query result set
ending in a `0` row and one that printed no row at all are different
answers, and only this separates them.

Whole texts rather than line lists, so a caller holding captured output
compares it directly; a caller holding lines joins them with `"\n"`.

```medaka
> expectEqualLines "a\nb" "a\nb"
Pass "a\nb" "a\nb"
> expectEqualLines "a\nb" "a\nc"
Fail "line 2: expected \"b\" but got \"c\"" "a\nb" "a\nc"
> expectEqualLines "a" "a\nb"
Fail "line 2: expected nothing but got \"b\"" "a" "a\nb"
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

### `labelFail`

```
labelFail : String -> Expectation -> Expectation
```

`e`, with `label` prefixed onto its message when it is a `Fail`.

For a comparison run under a label (which row, which table, which file)
the label has to travel WITH the message: `expectAll` forwards the first
`Fail` out of many and drops everything beside it, so a label kept
anywhere else is the thing nobody prints.

```medaka
> labelFail "t1" pass
Pass "" ""
> labelFail "t1" (fail "mismatch")
Fail "t1: mismatch" "" ""
```

### `expectEach`

```
expectEach : List (String, Expectation) -> Expectation
```

Passes when every labelled expectation passes, naming the first that
does not.

`expectAll` over rows that each need saying which one they were: one
`test` block sweeping a corpus reports `"users.sql: line 3: …"` instead
of a bare line number that fits every row equally.

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
```

Passes when `check` ran and reported nothing.

The shape a scan-shaped test wants: a check returns either the reason it
could not run or the lines it found, and those are three outcomes, not
two. A plain `expectOk` would pass on a check that ran and found
violations, and a plain `expectEqual []` would report "could not run" as
though it were a finding.

`what` names the check, and heads the failure so a suite of scans says
which one fired.

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
```

Passes when `check` ran and reported at least one finding.

`expectNoFindings`'s mutation control, where a clean report is the
failure. The count, not the text: a control proves the check can fire at
all, and pinning which line fired would restate the check beside it.

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

