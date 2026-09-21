# META
source_lines=687
stages=DESUGAR,MARK
# SOURCE
{- | Assertions for unit tests.

   An assertion produces an `Expectation`: `Pass` or `Fail`, each carrying
   the rendered operands the assertion compared, so a reader (or a driver
   reading a compiled probe's output) sees the values and not just a
   verdict. Write a test as `test "name" = expectEqual expected actual`,
   and run the file with `medaka test`, which also runs the doctests and
   `prop` declarations it finds. `runTests` runs a list of tests from an
   ordinary program instead.

   Import what you need: `import test.{expectEqual, expectTrue}`. -}

import list.{last}
import math.{approxEq}
import string.{contains, lines, startsWith, stripSuffix, unlines}

{- | The result of one assertion.

   Both outcomes carry the two operands as rendered text, so a caller can
   report or re-compare them without the `Eq` or `Debug` instance the
   assertion itself used. `Fail` carries a message ahead of them. An
   assertion with nothing to show (`pass`, `fail`) renders both operands
   as the empty string. -}
public export data Expectation =
  -- Pass: expected, actual.  Fail: message, expected, actual.
  | Pass String String
  | Fail String String String
  deriving (Eq, Debug)

-- # Assertions

{- | An assertion that always passes.

   > pass
   Pass "" "" -}
export
pass : Expectation
pass = Pass "" ""

{- | An assertion that fails with a message.

   > fail "not ready"
   Fail "not ready" "" "" -}
export
fail : String -> Expectation
fail msg = Fail msg "" ""

{- | Passes when the value is `True`.

   > expectTrue True
   Pass "True" "True"
   > expectTrue False
   Fail "expected True but got False" "True" "False" -}
export
expectTrue : Bool -> Expectation
expectTrue True = Pass "True" "True"
expectTrue False = Fail "expected True but got False" "True" "False"

{- | Passes when the value is `False`.

   > expectFalse False
   Pass "False" "False"
   > expectFalse True
   Fail "expected False but got True" "False" "True" -}
export
expectFalse : Bool -> Expectation
expectFalse False = Pass "False" "False"
expectFalse True = Fail "expected False but got True" "False" "True"

{- | Passes when `x` satisfies `p`, naming the property as `what`.

   The escape hatch for a one-off predicate that no other assertion here
   says. `what` completes the sentence "expected …", so it names the
   property rather than restating the call: `"a positive number"`, not
   `"p x"`. The value is rendered either way, so a failure shows what was
   actually tested.

   > expectSatisfies "a positive number" (n => n > 0) 3
   Pass "a positive number" "3"
   > expectSatisfies "a positive number" (n => n > 0) 0
   Fail "expected a positive number but got 0" "a positive number" "0" -}
export
expectSatisfies : Debug a => String -> (a -> Bool) -> a -> Expectation
expectSatisfies what p x =
  let a = debug x
  if p x then Pass what a else Fail "expected \{what} but got \{a}" what a

{- | Passes when the two values are equal.

   The operands, and the message, name both values in their `debug` form.

   > expectEqual 42 42
   Pass "42" "42"
   > expectEqual 1 2
   Fail "expected 1 but got 2" "1" "2" -}
export
expectEqual : (Eq a, Debug a) => a -> a -> Expectation
expectEqual expected actual =
  let e = debug expected
  let a = debug actual
  if eq expected actual then Pass e a else Fail "expected \{e} but got \{a}" e a

{- | Passes when the two values differ.

   > expectNotEqual 1 2
   Pass "1" "2"
   > expectNotEqual 1 1
   Fail "expected values to differ but both were 1" "1" "1" -}
export
expectNotEqual : (Eq a, Debug a) => a -> a -> Expectation
expectNotEqual expected actual =
  let e = debug expected
  let a = debug actual
  if neq expected actual then
    Pass e a
  else
    Fail ("expected values to differ but both were " ++ a) e a

{- | Passes when `actual` is less than `expected`.

   > expectLessThan 10 3
   Pass "10" "3"
   > expectLessThan 10 15
   Fail "expected 15 < 10" "10" "15" -}
export
expectLessThan : (Ord a, Debug a) => a -> a -> Expectation
expectLessThan expected actual =
  let e = debug expected
  let a = debug actual
  if lt actual expected then Pass e a else Fail "expected \{a} < \{e}" e a

{- | Passes when `actual` is greater than `expected`.

   > expectGreaterThan 0 5
   Pass "0" "5"
   > expectGreaterThan 10 3
   Fail "expected 3 > 10" "10" "3" -}
export
expectGreaterThan : (Ord a, Debug a) => a -> a -> Expectation
expectGreaterThan expected actual =
  let e = debug expected
  let a = debug actual
  if gt actual expected then Pass e a else Fail "expected \{a} > \{e}" e a

{- | Passes when `actual` is at least `floor`.

   The inclusive peer of `expectGreaterThan`, for a count whose exact value
   is not the point: a census that must find SOMETHING pins a floor, and
   pinning the current count instead would fail on every legitimate growth.

   > expectAtLeast 3 5
   Pass "3" "5"
   > expectAtLeast 3 2
   Fail "expected 2 >= 3" "3" "2" -}
export
expectAtLeast : (Ord a, Debug a) => a -> a -> Expectation
expectAtLeast floor actual =
  let e = debug floor
  let a = debug actual
  if gte actual floor then Pass e a else Fail "expected \{a} >= \{e}" e a

{- | Passes when `actual` is at most `ceiling`.

   > expectAtMost 3 2
   Pass "3" "2"
   > expectAtMost 3 5
   Fail "expected 5 <= 3" "3" "5" -}
export
expectAtMost : (Ord a, Debug a) => a -> a -> Expectation
expectAtMost ceiling actual =
  let e = debug ceiling
  let a = debug actual
  if lte actual ceiling then Pass e a else Fail "expected \{a} <= \{e}" e a

{- | Passes when the result is `Ok`.

   > expectOk (Ok 1 : Result String Int)
   Pass "Ok _" "Ok 1"
   > expectOk (Err "boom" : Result String Int)
   Fail "expected Ok but got Err \"boom\"" "Ok _" "Err \"boom\"" -}
export
expectOk : (Debug e, Debug a) => Result e a -> Expectation
expectOk r =
  let a = debug r
  match r
    Ok _ => Pass "Ok _" a
    Err _ => Fail "expected Ok but got \{a}" "Ok _" a

{- | Passes when the result is `Err`.

   > expectErr (Err "boom" : Result String Int)
   Pass "Err _" "Err \"boom\""
   > expectErr (Ok 1 : Result String Int)
   Fail "expected Err but got Ok 1" "Err _" "Ok 1" -}
export
expectErr : (Debug e, Debug a) => Result e a -> Expectation
expectErr r =
  let a = debug r
  match r
    Err _ => Pass "Err _" a
    Ok _ => Fail "expected Err but got \{a}" "Err _" a

{- | Passes when the result is `Err` whose message contains `needle`.

   Both halves are required, and for the same reason `expectSpawnFails`
   needs both: a rejection graded on the `Err` constructor alone still
   passes once the error it was written for has been replaced by a
   different one. The needle is matched against `display e`, the sentence a
   caller would print, not against `debug e`'s constructor spelling.

   > expectErrContains "no such column" (Err "no such column: age" : Result String Int)
   Pass "Err containing \"no such column\"" "Err \"no such column: age\""
   > expectErrContains "no such column" (Err "syntax error" : Result String Int)
   Fail "expected the error to contain \"no such column\" but got \"syntax error\"" "Err containing \"no such column\"" "Err \"syntax error\""
   > expectErrContains "no such column" (Ok 1 : Result String Int)
   Fail "expected Err but got Ok 1" "Err containing \"no such column\"" "Ok 1" -}
export
expectErrContains : (Debug e, Debug a, Display e) =>
  String ->
  Result e a ->
  Expectation
expectErrContains needle r =
  let want = "Err containing \{debug needle}"
  let a = debug r
  match r
    Ok _ => Fail "expected Err but got \{a}" want a
    Err e =>
      if contains needle (display e) then
        Pass want a
      else
        Fail
          "expected the error to contain \{debug needle} but got \{debug (display e)}"
          want
          a

{- | Runs `k` on the `Ok` payload, and fails naming the error otherwise.

   The unwrap-or-fail guard, as a verb. A hand-written `match` whose `Err`
   arm is `expectTrue False` (or any bare `fail`) throws the error away and
   reports only that the step did not reach its assertion; this keeps the
   error in the message, which is the only thing that says WHY.

   The payload needs no `Debug`, so this reaches a `Result` whose success
   type is a program type that derives nothing, the case the plain
   `expectOk` cannot take.

   > expectOkThen (n => expectEqual 1 n) (Ok 1 : Result String Int)
   Pass "1" "1"
   > expectOkThen (n => expectEqual 1 n) (Err "boom" : Result String Int)
   Fail "expected Ok but got Err boom" "Ok _" "Err \"boom\"" -}
export
expectOkThen : (Debug e, Display e) =>
  (a -> Expectation) ->
  Result e a ->
  Expectation
expectOkThen k (Ok v) = k v
expectOkThen _ (Err e) =
  Fail "expected Ok but got Err \{display e}" "Ok _" "Err \{debug e}"

{- | Passes when the option is `Some`.

   > expectSome (Some 1)
   Pass "Some _" "Some 1"
   > expectSome (None : Option Int)
   Fail "expected Some but got None" "Some _" "None" -}
export
expectSome : Debug a => Option a -> Expectation
expectSome o =
  let a = debug o
  match o
    Some _ => Pass "Some _" a
    None => Fail "expected Some but got \{a}" "Some _" a

{- | Passes when the option is `None`.

   > expectNone (None : Option Int)
   Pass "None" "None"
   > expectNone (Some 1)
   Fail "expected None but got Some 1" "None" "Some 1" -}
export
expectNone : Debug a => Option a -> Expectation
expectNone o =
  let a = debug o
  match o
    None => Pass "None" a
    Some _ => Fail "expected None but got \{a}" "None" a

{- | Passes when `actual` is within `eps` of `expected`.

   > expectWithin 1.0 1.0005 0.01
   Pass "1.0" "1.0005"
   > expectWithin 1.0 2.0 0.01
   Fail "expected 2.0 within 0.01 of 1.0" "1.0" "2.0" -}
export
expectWithin : Float -> Float -> Float -> Expectation
expectWithin expected actual eps =
  let e = debug expected
  let a = debug actual
  if approxEq expected actual eps then
    Pass e a
  else
    Fail "expected \{a} within \{debug eps} of \{e}" e a

missingTextNeedles : List String -> String -> List String
missingTextNeedles needles actual =
  filter (needle => not (contains needle actual)) needles

{- | Passes when `actual` contains every string in `needles`.

   An empty `needles` list passes. On failure, the message names the first
   missing string while the operands retain the full requirement and text.

   > expectationTag (expectTextContainsAll ["alpha", "gamma"] "alpha beta gamma")
   "Pass"
   > expectationMessage (expectTextContainsAll ["alpha", "delta"] "alpha beta gamma")
   "expected text containing \"delta\"" -}
export
expectTextContainsAll : List String -> String -> Expectation
expectTextContainsAll needles actual =
  let expected = debug needles
  match missingTextNeedles needles actual
    [] => Pass expected actual
    missing :: _ =>
      Fail "expected text containing \{debug missing}" expected actual

lineContainsAll : List String -> String -> Bool
lineContainsAll needles line = match missingTextNeedles needles line
  [] => True
  _ => False

{- | Passes when one line of `actual` contains every string in `needles`.

   The strings must occur on the same line, in any order. This is useful for
   binding a source location to its diagnostic instead of finding each in a
   different part of a multi-error report.

   > expectationTag (expectLineContainsAll ["file.mdk:3:", "bad type"] "error: file.mdk:3: bad type\nhelp")
   "Pass"
   > expectationTag (expectLineContainsAll ["file.mdk:3:", "bad type"] "file.mdk:3:\nbad type")
   "Fail" -}
export
expectLineContainsAll : List String -> String -> Expectation
expectLineContainsAll needles actual =
  let expected = debug needles
  if any (lineContainsAll needles) (lines actual) then
    Pass expected actual
  else
    Fail "expected one line containing every required string" expected actual

{- | Passes when `actual` begins with `prefix` and contains every string in
   `needles`.

   > expectationTag (expectTextStartsWithAndContains "accepted" ["Env"] "accepted: Env")
   "Pass"
   > expectationTag (expectTextStartsWithAndContains "accepted" ["Env"] "note: Env accepted")
   "Fail" -}
export
expectTextStartsWithAndContains : String -> List String -> String -> Expectation
expectTextStartsWithAndContains prefix needles actual =
  let expected = "prefix \{debug prefix}, substrings \{debug needles}"
  if not (startsWith prefix actual) then
    Fail "expected text starting with \{debug prefix}" expected actual
  else match missingTextNeedles needles actual
    [] => Pass expected actual
    missing :: _ =>
      Fail "expected text containing \{debug missing}" expected actual

-- The single normalizer for the trailing-Unit shapes the shell `strip_unit`
-- helpers across test/*.sh disagree on: strips a trailing "()" suffix if
-- present, else drops the LAST LINE when it is exactly "0" (the auto-printed
-- Unit value or exit code a probe's last line carries). The "0" arm is
-- WHOLE-LINE, not a bare suffix strip: an earlier draft stripped a trailing
-- "0" character from anywhere the text ended in one, so "10" and "1" (or
-- "…0" and "…" for any real numeral) compared equal — a silent wrong-answer
-- in the one primitive every migrated gate's text comparison goes through.
-- Anchoring to "the whole last line reads 0" is what the shell precedent's
-- own safest variant already does for "()" (`${/^()$/d;}`); this applies the
-- same discipline to "0". The shell scripts' seven variants stay as they are.
normalizeTrailingUnit : String -> String
-- lint-disable-next-line rule-stdlib-reimpl
normalizeTrailingUnit s = match stripSuffix "()" s
  Some s2 => s2
  None => match last (lines s)
    Some "0" => optionOr s (stripSuffix "0" s)
    _ => s

-- Renders the first line at which two line lists diverge, 1-indexed.
diffLineMsg : Int -> List String -> List String -> String
diffLineMsg n [] [] = "expected and actual differ only outside their lines"
diffLineMsg n [] (a :: _) =
  "line \{intToString n}: expected nothing but got \{debug a}"
diffLineMsg n (e :: _) [] =
  "line \{intToString n}: expected \{debug e} but got nothing"
diffLineMsg n (e :: es) (a :: asL) =
  if e == a then
    diffLineMsg (n + 1) es asL
  else
    "line \{intToString n}: expected \{debug e} but got \{debug a}"

{- | Passes when two texts are equal after normalizing one trailing
   auto-printed Unit shape: a trailing `()` suffix, or a last line that is
   exactly `0`. Ordinary text ending in the digit `0` is NOT touched — only
   a `0` occupying the whole last line normalizes.

   A mismatch names the first differing line, 1-indexed, rather than
   dumping both texts whole. `expectEqualLines` is the sibling that
   normalizes nothing, for text where a trailing `()` or a whole-line `0`
   is data rather than a driver's artefact.

   > expectEqualText "same" "same"
   Pass "same" "same"
   > expectEqualText "result()" "result"
   Pass "result" "result"
   > expectEqualText "value: 10" "value: 1"
   Fail "line 1: expected \"value: 10\" but got \"value: 1\"" "value: 10" "value: 1" -}
export
expectEqualText : String -> String -> Expectation
expectEqualText expected actual =
  let e = normalizeTrailingUnit expected
  let a = normalizeTrailingUnit actual
  if e == a then Pass e a else Fail (diffLineMsg 1 (lines e) (lines a)) e a

{- | Passes when two texts are equal, naming the first line at which they
   diverge.

   `expectEqualText` without the normalizer: nothing is stripped, so a text
   whose last line is exactly `0` compares as itself. A query result set
   ending in a `0` row and one that printed no row at all are different
   answers, and only this separates them.

   Whole texts rather than line lists, so a caller holding captured output
   compares it directly; a caller holding lines joins them with `"\n"`.

   > expectEqualLines "a\nb" "a\nb"
   Pass "a\nb" "a\nb"
   > expectEqualLines "a\nb" "a\nc"
   Fail "line 2: expected \"b\" but got \"c\"" "a\nb" "a\nc"
   > expectEqualLines "a" "a\nb"
   Fail "line 2: expected nothing but got \"b\"" "a" "a\nb" -}
export
expectEqualLines : String -> String -> Expectation
expectEqualLines expected actual =
  if expected == actual then
    Pass expected actual
  else
    Fail (diffLineMsg 1 (lines expected) (lines actual)) expected actual

-- Helper for expectAll: accumulate the first Fail, or stay Pass.  An
-- aggregate pass has no single pair of operands to report, so it collapses
-- to `pass` rather than keeping some arbitrary member's.
expectAllStep : Expectation -> Expectation -> Expectation
expectAllStep (Fail msg e a) _ = Fail msg e a
expectAllStep (Pass _ _) (Fail msg e a) = Fail msg e a
expectAllStep (Pass _ _) (Pass _ _) = pass

{- | Passes when every expectation in the list passes.

   The result is the first `Fail`, when there is one.

   > expectAll [pass, pass, pass]
   Pass "" ""
   > expectAll [pass, fail "oops", pass]
   Fail "oops" "" "" -}
export
expectAll : List Expectation -> Expectation
expectAll es = fold expectAllStep pass es

{- | `e`, with `label` prefixed onto its message when it is a `Fail`.

   For a comparison run under a label (which row, which table, which file)
   the label has to travel WITH the message: `expectAll` forwards the first
   `Fail` out of many and drops everything beside it, so a label kept
   anywhere else is the thing nobody prints.

   > labelFail "t1" pass
   Pass "" ""
   > labelFail "t1" (fail "mismatch")
   Fail "t1: mismatch" "" "" -}
export
labelFail : String -> Expectation -> Expectation
labelFail _ (Pass e a) = Pass e a
labelFail label (Fail m e a) = Fail "\{label}: \{m}" e a

{- | Passes when every labelled expectation passes, naming the first that
   does not.

   `expectAll` over rows that each need saying which one they were: one
   `test` block sweeping a corpus reports `"users.sql: line 3: …"` instead
   of a bare line number that fits every row equally.

   > expectEach [("a", pass), ("b", pass)]
   Pass "" ""
   > expectEach [("a", pass), ("b", fail "oops")]
   Fail "b: oops" "" "" -}
export
expectEach : List (String, Expectation) -> Expectation
expectEach rows = expectAll (map ((label, e) => labelFail label e) rows)

-- # Grading a check's findings

-- A finding, indented under the `what` line that heads the report, so a
-- multi-line failure message reads as one block belonging to one check
-- rather than as several unrelated messages.
indentFinding : String -> String
indentFinding hit = "  \{hit}"

{- | Passes when `check` ran and reported nothing.

   The shape a scan-shaped test wants: a check returns either the reason it
   could not run or the lines it found, and those are three outcomes, not
   two. A plain `expectOk` would pass on a check that ran and found
   violations, and a plain `expectEqual []` would report "could not run" as
   though it were a finding.

   `what` names the check, and heads the failure so a suite of scans says
   which one fired.

   > expectNoFindings "hardening" (Ok [])
   Pass "no findings" "no findings"
   > expectNoFindings "hardening" (Ok ["pds.service: no MemoryDenyWriteExecute"])
   Fail "hardening:\n  pds.service: no MemoryDenyWriteExecute\n" "no findings" "1 findings"
   > expectNoFindings "hardening" (Err "could not read pds.service")
   Fail "hardening: could not read pds.service" "no findings" "the check could not run" -}
export
expectNoFindings : String -> Result String (List String) -> Expectation
expectNoFindings what (Err e) =
  Fail "\{what}: \{e}" "no findings" "the check could not run"
expectNoFindings _ (Ok []) = Pass "no findings" "no findings"
expectNoFindings what (Ok hits) =
  Fail
    "\{what}:\n\{unlines (map indentFinding hits)}"
    "no findings"
    "\{intToString (length hits)} findings"

{- | Passes when `check` ran and reported at least one finding.

   `expectNoFindings`'s mutation control, where a clean report is the
   failure. The count, not the text: a control proves the check can fire at
   all, and pinning which line fired would restate the check beside it.

   > expectFindings "injected secret" (Ok ["shell.mdk:12: literal token"])
   Pass "a finding" "1 findings"
   > expectFindings "injected secret" (Ok [])
   Fail "injected secret: nothing was reported" "a finding" "no findings"
   > expectFindings "injected secret" (Err "could not read shell.mdk")
   Fail "injected secret: could not read shell.mdk" "a finding" "the check could not run" -}
export
expectFindings : String -> Result String (List String) -> Expectation
expectFindings what (Err e) =
  Fail "\{what}: \{e}" "a finding" "the check could not run"
expectFindings what (Ok []) =
  Fail "\{what}: nothing was reported" "a finding" "no findings"
expectFindings _ (Ok hits) =
  Pass "a finding" "\{intToString (length hits)} findings"

-- # Reading an expectation

-- These four read an `Expectation` without naming its constructors, which a
-- caller that also declares a `Pass` or a `Fail` of its own cannot otherwise
-- do: the constructors resolve in this module, the accessors travel.

{- | The name of the outcome's constructor, `"Pass"` or `"Fail"`.

   > expectationTag pass
   "Pass"
   > expectationTag (fail "not ready")
   "Fail" -}
export
expectationTag : Expectation -> String
expectationTag (Pass _ _) = "Pass"
expectationTag (Fail _ _ _) = "Fail"

{- | The failure message, empty for a `Pass`.

   > expectationMessage (fail "not ready")
   "not ready"
   > expectationMessage pass
   "" -}
export
expectationMessage : Expectation -> String
expectationMessage (Pass _ _) = ""
expectationMessage (Fail m _ _) = m

{- | The expected operand as the assertion rendered it.

   > expectationExpected (expectEqual 1 2)
   "1" -}
export
expectationExpected : Expectation -> String
expectationExpected (Pass e _) = e
expectationExpected (Fail _ e _) = e

{- | The actual operand as the assertion rendered it.

   > expectationActual (expectEqual 1 2)
   "2" -}
export
expectationActual : Expectation -> String
expectationActual (Pass _ a) = a
expectationActual (Fail _ _ a) = a

-- # Running tests

goTests : List (String, Unit -> Expectation) -> Int -> Int -> <IO> Bool
goTests [] passed failed =
  println "\n\{intToString passed} passed, \{intToString failed} failed"
  eq failed 0
goTests ((name, thunk) :: rest) passed failed = match thunk ()
  Pass _ _ =>
    println ("  ok   " ++ name)
    goTests rest (passed + 1) failed
  Fail msg _ _ =>
    println "  FAIL \{name}: \{msg}"
    goTests rest passed (failed + 1)

{- | Runs a list of named tests, printing each result and a summary.

   Each test is a name and a function from `Unit` to an `Expectation`.
   Returns `True` when every test passes. -}
export
runTests : List (String, Unit -> Expectation) -> <IO> Bool
runTests tests = goTests tests 0 0

-- # Golden files

{- | Compares `actual` against the golden file at `path`, via
   `expectEqualText`.

   Read-only: never writes or blesses a golden. A read failure (most often
   a golden that does not exist yet) surfaces as a `Fail` naming it, so a
   caller doesn't need a separate branch for "no golden" versus "golden
   didn't match."

   > expectGolden "stdlib/no-such-golden-doctest-fixture.golden" "hello"
   Fail "expected golden stdlib/no-such-golden-doctest-fixture.golden: No such file or directory" "" "hello" -}
export
expectGolden : String -> String -> <FileRead "_"> Expectation
expectGolden path actual = match readFile path
  Err e => Fail "expected golden \{path}: \{e}" "" actual
  Ok golden => expectEqualText golden actual

-- ── Instance laws ────────────────────────────────────────────────────────
-- LAW: derived `Eq Expectation` must separate the two constructors AND the
-- payload; an assertion library whose results compare equal regardless of
-- the failure message would make every `expectEqual` over an `Expectation`
-- pass vacuously.
prop "Eq Expectation separates constructors and payloads" (m : String) =
  pass == pass
    && fail m == fail m
    && pass == fail m == False
    && fail m == fail (m ++ "!") == False

-- LAW: the operands travel on BOTH outcomes, so a passing assertion is
-- still distinguishable by the values it compared — the property the
-- native arm's driver reads instead of trusting the verdict.
prop "a passing expectEqual carries both rendered operands" (n : Int) =
  expectEqual n n == Pass (debug n) (debug n)

-- LAW: `Debug` agrees with `Eq`: equal expectations render identically,
-- distinguishable ones render differently.
prop "Debug Expectation agrees with Eq" (m : String) =
  debug (fail m) == debug (fail m) && debug (fail m) == debug pass == False

-- LAW (regression, the S0-2 review finding): `expectEqualText`'s trailing-Unit
-- normalizer must never treat "a value with a literal 0 appended" as the same
-- text as the value alone — that collapse ("10" == "1") was the actual bug.
-- `normalizeTrailingUnit` only drops a `0` that is the WHOLE last line, so `s`
-- and `s ++ "0"` (which puts the extra digit ON `s`'s own last line, not on a
-- line of its own) must always compare unequal.
-- LAW: `labelFail` touches the message and nothing else. A `Pass` comes back
-- unchanged, so labelling a sweep's rows cannot turn a passing row into a
-- reportable one; a `Fail`'s message gains the label and its operands do not,
-- so the label is never mistaken for part of a compared value.
prop "labelFail is identity on Pass and prefixes the message on Fail" (l : String) (m : String) =
  labelFail l pass == pass && labelFail l (fail m) == fail "\{l}: \{m}"

-- LAW: `expectAtLeast` is inclusive at its own floor. The boundary is the
-- whole reason it exists beside `expectGreaterThan`: a census pinned at "at
-- least 1" must accept exactly 1.
prop "expectAtLeast passes when actual equals the floor" (n : Int) =
  expectationTag (expectAtLeast n n) == "Pass"

prop "expectEqualText never conflates a value with that value plus a digit" (n : Int) =
  let s = intToString (abs n)
  match expectEqualText s (s ++ "0")
    Pass _ _ => False
    Fail _ _ _ => True
# DESUGAR
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("math") ((mem "approxEq" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "lines" false) (mem "startsWith" false) (mem "stripSuffix" false) (mem "unlines" false))))
(DData Public "Expectation" () ((variant "Pass" (ConPos (TyCon "String") (TyCon "String"))) (variant "Fail" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Expectation")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Pass" (PVar "__a0") (PVar "__a1")) (PCon "Pass" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "Fail" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "Fail" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Expectation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Pass" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Pass ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1"))))) (arm (PCon "Fail" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Fail ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))))))))
(DTypeSig true "pass" (TyCon "Expectation"))
(DFunDef false "pass" () (EApp (EApp (EVar "Pass") (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig true "fail" (TyFun (TyCon "String") (TyCon "Expectation")))
(DFunDef false "fail" ((PVar "msg")) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig true "expectTrue" (TyFun (TyCon "Bool") (TyCon "Expectation")))
(DFunDef false "expectTrue" ((PCon "True")) (EApp (EApp (EVar "Pass") (ELit (LString "True"))) (ELit (LString "True"))))
(DFunDef false "expectTrue" ((PCon "False")) (EApp (EApp (EApp (EVar "Fail") (ELit (LString "expected True but got False"))) (ELit (LString "True"))) (ELit (LString "False"))))
(DTypeSig true "expectFalse" (TyFun (TyCon "Bool") (TyCon "Expectation")))
(DFunDef false "expectFalse" ((PCon "False")) (EApp (EApp (EVar "Pass") (ELit (LString "False"))) (ELit (LString "False"))))
(DFunDef false "expectFalse" ((PCon "True")) (EApp (EApp (EApp (EVar "Fail") (ELit (LString "expected False but got True"))) (ELit (LString "False"))) (ELit (LString "True"))))
(DTypeSig true "expectSatisfies" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyCon "String") (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyVar "a") (TyCon "Expectation"))))))
(DFunDef false "expectSatisfies" ((PVar "what") (PVar "p") (PVar "x")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "x"))) (DoExpr (EIf (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "Pass") (EVar "what")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString " but got "))) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (EVar "what")) (EVar "a"))))))
(DTypeSig true "expectEqual" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectEqual" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EVar "eq") (EVar "expected")) (EVar "actual")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString " but got "))) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectNotEqual" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectNotEqual" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EVar "neq") (EVar "expected")) (EVar "actual")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (ELit (LString "expected values to differ but both were ")) (EVar "a"))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectLessThan" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectLessThan" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EVar "lt") (EVar "actual")) (EVar "expected")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString " < "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectGreaterThan" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectGreaterThan" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EVar "gt") (EVar "actual")) (EVar "expected")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString " > "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectAtLeast" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectAtLeast" ((PVar "floor") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "debug") (EVar "floor"))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EVar "gte") (EVar "actual")) (EVar "floor")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString " >= "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectAtMost" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectAtMost" ((PVar "ceiling") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "debug") (EVar "ceiling"))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EVar "lte") (EVar "actual")) (EVar "ceiling")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString " <= "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectOk" (TyConstrained ((cstr "Debug" (TyVar "e")) (cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectOk" ((PVar "r")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "r"))) (DoExpr (EMatch (EVar "r") (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "Pass") (ELit (LString "Ok _"))) (EVar "a"))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Ok but got ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "Ok _"))) (EVar "a")))))))
(DTypeSig true "expectErr" (TyConstrained ((cstr "Debug" (TyVar "e")) (cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectErr" ((PVar "r")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "r"))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" PWild) () (EApp (EApp (EVar "Pass") (ELit (LString "Err _"))) (EVar "a"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Err but got ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "Err _"))) (EVar "a")))))))
(DTypeSig true "expectErrContains" (TyConstrained ((cstr "Debug" (TyVar "e")) (cstr "Debug" (TyVar "a")) (cstr "Display" (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Expectation")))))
(DFunDef false "expectErrContains" ((PVar "needle") (PVar "r")) (EBlock (DoLet false false (PVar "want") (EBinOp "++" (EBinOp "++" (ELit (LString "Err containing ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "needle")))) (ELit (LString "")))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "r"))) (DoExpr (EMatch (EVar "r") (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Err but got ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (EVar "want")) (EVar "a"))) (arm (PCon "Err" (PVar "e")) () (EIf (EApp (EApp (EVar "contains") (EVar "needle")) (EApp (EVar "display") (EVar "e"))) (EApp (EApp (EVar "Pass") (EVar "want")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected the error to contain ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "needle")))) (ELit (LString " but got "))) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "display") (EVar "e"))))) (ELit (LString "")))) (EVar "want")) (EVar "a"))))))))
(DTypeSig true "expectOkThen" (TyConstrained ((cstr "Debug" (TyVar "e")) (cstr "Display" (TyVar "e"))) (TyFun (TyFun (TyVar "a") (TyCon "Expectation")) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Expectation")))))
(DFunDef false "expectOkThen" ((PVar "k") (PCon "Ok" (PVar "v"))) (EApp (EVar "k") (EVar "v")))
(DFunDef false "expectOkThen" (PWild (PCon "Err" (PVar "e"))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Ok but got Err ")) (EApp (EVar "display") (EApp (EVar "display") (EVar "e")))) (ELit (LString "")))) (ELit (LString "Ok _"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Err ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "e")))) (ELit (LString "")))))
(DTypeSig true "expectSome" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectSome" ((PVar "o")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "o"))) (DoExpr (EMatch (EVar "o") (arm (PCon "Some" PWild) () (EApp (EApp (EVar "Pass") (ELit (LString "Some _"))) (EVar "a"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Some but got ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "Some _"))) (EVar "a")))))))
(DTypeSig true "expectNone" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectNone" ((PVar "o")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "o"))) (DoExpr (EMatch (EVar "o") (arm (PCon "None") () (EApp (EApp (EVar "Pass") (ELit (LString "None"))) (EVar "a"))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected None but got ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "None"))) (EVar "a")))))))
(DTypeSig true "expectWithin" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Expectation")))))
(DFunDef false "expectWithin" ((PVar "expected") (PVar "actual") (PVar "eps")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "approxEq") (EVar "expected")) (EVar "actual")) (EVar "eps")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString " within "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "eps")))) (ELit (LString " of "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig false "missingTextNeedles" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "missingTextNeedles" ((PVar "needles") (PVar "actual")) (EApp (EApp (EVar "filter") (ELam ((PVar "needle")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "needle")) (EVar "actual"))))) (EVar "needles")))
(DTypeSig true "expectTextContainsAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Expectation"))))
(DFunDef false "expectTextContainsAll" ((PVar "needles") (PVar "actual")) (EBlock (DoLet false false (PVar "expected") (EApp (EVar "debug") (EVar "needles"))) (DoExpr (EMatch (EApp (EApp (EVar "missingTextNeedles") (EVar "needles")) (EVar "actual")) (arm (PList) () (EApp (EApp (EVar "Pass") (EVar "expected")) (EVar "actual"))) (arm (PCons (PVar "missing") PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected text containing ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "missing")))) (ELit (LString "")))) (EVar "expected")) (EVar "actual")))))))
(DTypeSig false "lineContainsAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "lineContainsAll" ((PVar "needles") (PVar "line")) (EMatch (EApp (EApp (EVar "missingTextNeedles") (EVar "needles")) (EVar "line")) (arm (PList) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig true "expectLineContainsAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Expectation"))))
(DFunDef false "expectLineContainsAll" ((PVar "needles") (PVar "actual")) (EBlock (DoLet false false (PVar "expected") (EApp (EVar "debug") (EVar "needles"))) (DoExpr (EIf (EApp (EApp (EVar "any") (EApp (EVar "lineContainsAll") (EVar "needles"))) (EApp (EVar "lines") (EVar "actual"))) (EApp (EApp (EVar "Pass") (EVar "expected")) (EVar "actual")) (EApp (EApp (EApp (EVar "Fail") (ELit (LString "expected one line containing every required string"))) (EVar "expected")) (EVar "actual"))))))
(DTypeSig true "expectTextStartsWithAndContains" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Expectation")))))
(DFunDef false "expectTextStartsWithAndContains" ((PVar "prefix") (PVar "needles") (PVar "actual")) (EBlock (DoLet false false (PVar "expected") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "prefix ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "prefix")))) (ELit (LString ", substrings "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "needles")))) (ELit (LString "")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "actual"))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected text starting with ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "prefix")))) (ELit (LString "")))) (EVar "expected")) (EVar "actual")) (EMatch (EApp (EApp (EVar "missingTextNeedles") (EVar "needles")) (EVar "actual")) (arm (PList) () (EApp (EApp (EVar "Pass") (EVar "expected")) (EVar "actual"))) (arm (PCons (PVar "missing") PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected text containing ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "missing")))) (ELit (LString "")))) (EVar "expected")) (EVar "actual"))))))))
(DTypeSig false "normalizeTrailingUnit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normalizeTrailingUnit" ((PVar "s")) (EMatch (EApp (EApp (EVar "stripSuffix") (ELit (LString "()"))) (EVar "s")) (arm (PCon "Some" (PVar "s2")) () (EVar "s2")) (arm (PCon "None") () (EMatch (EApp (EVar "last") (EApp (EVar "lines") (EVar "s"))) (arm (PCon "Some" (PLit (LString "0"))) () (EApp (EApp (EVar "optionOr") (EVar "s")) (EApp (EApp (EVar "stripSuffix") (ELit (LString "0"))) (EVar "s")))) (arm PWild () (EVar "s"))))))
(DTypeSig false "diffLineMsg" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "diffLineMsg" ((PVar "n") (PList) (PList)) (ELit (LString "expected and actual differ only outside their lines")))
(DFunDef false "diffLineMsg" ((PVar "n") (PList) (PCons (PVar "a") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ": expected nothing but got "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "a")))) (ELit (LString ""))))
(DFunDef false "diffLineMsg" ((PVar "n") (PCons (PVar "e") PWild) (PList)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ": expected "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "e")))) (ELit (LString " but got nothing"))))
(DFunDef false "diffLineMsg" ((PVar "n") (PCons (PVar "e") (PVar "es")) (PCons (PVar "a") (PVar "asL"))) (EIf (EBinOp "==" (EVar "e") (EVar "a")) (EApp (EApp (EApp (EVar "diffLineMsg") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "es")) (EVar "asL")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ": expected "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "e")))) (ELit (LString " but got "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "a")))) (ELit (LString "")))))
(DTypeSig true "expectEqualText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Expectation"))))
(DFunDef false "expectEqualText" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "normalizeTrailingUnit") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "normalizeTrailingUnit") (EVar "actual"))) (DoExpr (EIf (EBinOp "==" (EVar "e") (EVar "a")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EApp (EApp (EApp (EVar "diffLineMsg") (ELit (LInt 1))) (EApp (EVar "lines") (EVar "e"))) (EApp (EVar "lines") (EVar "a")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectEqualLines" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Expectation"))))
(DFunDef false "expectEqualLines" ((PVar "expected") (PVar "actual")) (EIf (EBinOp "==" (EVar "expected") (EVar "actual")) (EApp (EApp (EVar "Pass") (EVar "expected")) (EVar "actual")) (EApp (EApp (EApp (EVar "Fail") (EApp (EApp (EApp (EVar "diffLineMsg") (ELit (LInt 1))) (EApp (EVar "lines") (EVar "expected"))) (EApp (EVar "lines") (EVar "actual")))) (EVar "expected")) (EVar "actual"))))
(DTypeSig false "expectAllStep" (TyFun (TyCon "Expectation") (TyFun (TyCon "Expectation") (TyCon "Expectation"))))
(DFunDef false "expectAllStep" ((PCon "Fail" (PVar "msg") (PVar "e") (PVar "a")) PWild) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (EVar "e")) (EVar "a")))
(DFunDef false "expectAllStep" ((PCon "Pass" PWild PWild) (PCon "Fail" (PVar "msg") (PVar "e") (PVar "a"))) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (EVar "e")) (EVar "a")))
(DFunDef false "expectAllStep" ((PCon "Pass" PWild PWild) (PCon "Pass" PWild PWild)) (EVar "pass"))
(DTypeSig true "expectAll" (TyFun (TyApp (TyCon "List") (TyCon "Expectation")) (TyCon "Expectation")))
(DFunDef false "expectAll" ((PVar "es")) (EApp (EApp (EApp (EVar "fold") (EVar "expectAllStep")) (EVar "pass")) (EVar "es")))
(DTypeSig true "labelFail" (TyFun (TyCon "String") (TyFun (TyCon "Expectation") (TyCon "Expectation"))))
(DFunDef false "labelFail" (PWild (PCon "Pass" (PVar "e") (PVar "a"))) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")))
(DFunDef false "labelFail" ((PVar "label") (PCon "Fail" (PVar "m") (PVar "e") (PVar "a"))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))) (EVar "e")) (EVar "a")))
(DTypeSig true "expectEach" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expectation"))) (TyCon "Expectation")))
(DFunDef false "expectEach" ((PVar "rows")) (EApp (EVar "expectAll") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "label") (PVar "e"))) (EApp (EApp (EVar "labelFail") (EVar "label")) (EVar "e")))) (EVar "rows"))))
(DTypeSig false "indentFinding" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "indentFinding" ((PVar "hit")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "hit"))) (ELit (LString ""))))
(DTypeSig true "expectNoFindings" (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Expectation"))))
(DFunDef false "expectNoFindings" ((PVar "what") (PCon "Err" (PVar "e"))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "what"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (ELit (LString "no findings"))) (ELit (LString "the check could not run"))))
(DFunDef false "expectNoFindings" (PWild (PCon "Ok" (PList))) (EApp (EApp (EVar "Pass") (ELit (LString "no findings"))) (ELit (LString "no findings"))))
(DFunDef false "expectNoFindings" ((PVar "what") (PCon "Ok" (PVar "hits"))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "what"))) (ELit (LString ":\n"))) (EApp (EVar "display") (EApp (EVar "unlines") (EApp (EApp (EVar "map") (EVar "indentFinding")) (EVar "hits"))))) (ELit (LString "")))) (ELit (LString "no findings"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "length") (EVar "hits"))))) (ELit (LString " findings")))))
(DTypeSig true "expectFindings" (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Expectation"))))
(DFunDef false "expectFindings" ((PVar "what") (PCon "Err" (PVar "e"))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "what"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (ELit (LString "a finding"))) (ELit (LString "the check could not run"))))
(DFunDef false "expectFindings" ((PVar "what") (PCon "Ok" (PList))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "what"))) (ELit (LString ": nothing was reported")))) (ELit (LString "a finding"))) (ELit (LString "no findings"))))
(DFunDef false "expectFindings" (PWild (PCon "Ok" (PVar "hits"))) (EApp (EApp (EVar "Pass") (ELit (LString "a finding"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "length") (EVar "hits"))))) (ELit (LString " findings")))))
(DTypeSig true "expectationTag" (TyFun (TyCon "Expectation") (TyCon "String")))
(DFunDef false "expectationTag" ((PCon "Pass" PWild PWild)) (ELit (LString "Pass")))
(DFunDef false "expectationTag" ((PCon "Fail" PWild PWild PWild)) (ELit (LString "Fail")))
(DTypeSig true "expectationMessage" (TyFun (TyCon "Expectation") (TyCon "String")))
(DFunDef false "expectationMessage" ((PCon "Pass" PWild PWild)) (ELit (LString "")))
(DFunDef false "expectationMessage" ((PCon "Fail" (PVar "m") PWild PWild)) (EVar "m"))
(DTypeSig true "expectationExpected" (TyFun (TyCon "Expectation") (TyCon "String")))
(DFunDef false "expectationExpected" ((PCon "Pass" (PVar "e") PWild)) (EVar "e"))
(DFunDef false "expectationExpected" ((PCon "Fail" PWild (PVar "e") PWild)) (EVar "e"))
(DTypeSig true "expectationActual" (TyFun (TyCon "Expectation") (TyCon "String")))
(DFunDef false "expectationActual" ((PCon "Pass" PWild (PVar "a"))) (EVar "a"))
(DFunDef false "expectationActual" ((PCon "Fail" PWild PWild (PVar "a"))) (EVar "a"))
(DTypeSig false "goTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Expectation")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "goTests" ((PList) (PVar "passed") (PVar "failed")) (EBlock (DoExpr (EApp (EVar "println") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "passed")))) (ELit (LString " passed, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "failed")))) (ELit (LString " failed"))))) (DoExpr (EApp (EApp (EVar "eq") (EVar "failed")) (ELit (LInt 0))))))
(DFunDef false "goTests" ((PCons (PTuple (PVar "name") (PVar "thunk")) (PVar "rest")) (PVar "passed") (PVar "failed")) (EMatch (EApp (EVar "thunk") (ELit LUnit)) (arm (PCon "Pass" PWild PWild) () (EBlock (DoExpr (EApp (EVar "println") (EBinOp "++" (ELit (LString "  ok   ")) (EVar "name")))) (DoExpr (EApp (EApp (EApp (EVar "goTests") (EVar "rest")) (EBinOp "+" (EVar "passed") (ELit (LInt 1)))) (EVar "failed"))))) (arm (PCon "Fail" (PVar "msg") PWild PWild) () (EBlock (DoExpr (EApp (EVar "println") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EVar "goTests") (EVar "rest")) (EVar "passed")) (EBinOp "+" (EVar "failed") (ELit (LInt 1)))))))))
(DTypeSig true "runTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Expectation")))) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "runTests" ((PVar "tests")) (EApp (EApp (EApp (EVar "goTests") (EVar "tests")) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig true "expectGolden" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyCon "Expectation")))))
(DFunDef false "expectGolden" ((PVar "path") (PVar "actual")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected golden ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (ELit (LString ""))) (EVar "actual"))) (arm (PCon "Ok" (PVar "golden")) () (EApp (EApp (EVar "expectEqualText") (EVar "golden")) (EVar "actual")))))
(DProp false "Eq Expectation separates constructors and payloads" ((pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "pass") (EVar "pass")) (EBinOp "==" (EApp (EVar "fail") (EVar "m")) (EApp (EVar "fail") (EVar "m")))) (EBinOp "==" (EBinOp "==" (EVar "pass") (EApp (EVar "fail") (EVar "m"))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EApp (EVar "fail") (EVar "m")) (EApp (EVar "fail") (EBinOp "++" (EVar "m") (ELit (LString "!"))))) (EVar "False"))))
(DProp false "a passing expectEqual carries both rendered operands" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "expectEqual") (EVar "n")) (EVar "n")) (EApp (EApp (EVar "Pass") (EApp (EVar "debug") (EVar "n"))) (EApp (EVar "debug") (EVar "n")))))
(DProp false "Debug Expectation agrees with Eq" ((pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "debug") (EApp (EVar "fail") (EVar "m"))) (EApp (EVar "debug") (EApp (EVar "fail") (EVar "m")))) (EBinOp "==" (EBinOp "==" (EApp (EVar "debug") (EApp (EVar "fail") (EVar "m"))) (EApp (EVar "debug") (EVar "pass"))) (EVar "False"))))
(DProp false "labelFail is identity on Pass and prefixes the message on Fail" ((pp "l" (TyCon "String")) (pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "labelFail") (EVar "l")) (EVar "pass")) (EVar "pass")) (EBinOp "==" (EApp (EApp (EVar "labelFail") (EVar "l")) (EApp (EVar "fail") (EVar "m"))) (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "l"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))))
(DProp false "expectAtLeast passes when actual equals the floor" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "expectationTag") (EApp (EApp (EVar "expectAtLeast") (EVar "n")) (EVar "n"))) (ELit (LString "Pass"))))
(DProp false "expectEqualText never conflates a value with that value plus a digit" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "intToString") (EApp (EVar "abs") (EVar "n")))) (DoExpr (EMatch (EApp (EApp (EVar "expectEqualText") (EVar "s")) (EBinOp "++" (EVar "s") (ELit (LString "0")))) (arm (PCon "Pass" PWild PWild) () (EVar "False")) (arm (PCon "Fail" PWild PWild PWild) () (EVar "True"))))))
# MARK
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("math") ((mem "approxEq" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "lines" false) (mem "startsWith" false) (mem "stripSuffix" false) (mem "unlines" false))))
(DData Public "Expectation" () ((variant "Pass" (ConPos (TyCon "String") (TyCon "String"))) (variant "Fail" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Expectation")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Pass" (PVar "__a0") (PVar "__a1")) (PCon "Pass" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "Fail" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "Fail" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Expectation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Pass" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Pass ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "Fail" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Fail ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))))))))
(DTypeSig true "pass" (TyCon "Expectation"))
(DFunDef false "pass" () (EApp (EApp (EVar "Pass") (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig true "fail" (TyFun (TyCon "String") (TyCon "Expectation")))
(DFunDef false "fail" ((PVar "msg")) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig true "expectTrue" (TyFun (TyCon "Bool") (TyCon "Expectation")))
(DFunDef false "expectTrue" ((PCon "True")) (EApp (EApp (EVar "Pass") (ELit (LString "True"))) (ELit (LString "True"))))
(DFunDef false "expectTrue" ((PCon "False")) (EApp (EApp (EApp (EVar "Fail") (ELit (LString "expected True but got False"))) (ELit (LString "True"))) (ELit (LString "False"))))
(DTypeSig true "expectFalse" (TyFun (TyCon "Bool") (TyCon "Expectation")))
(DFunDef false "expectFalse" ((PCon "False")) (EApp (EApp (EVar "Pass") (ELit (LString "False"))) (ELit (LString "False"))))
(DFunDef false "expectFalse" ((PCon "True")) (EApp (EApp (EApp (EVar "Fail") (ELit (LString "expected False but got True"))) (ELit (LString "False"))) (ELit (LString "True"))))
(DTypeSig true "expectSatisfies" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyCon "String") (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyVar "a") (TyCon "Expectation"))))))
(DFunDef false "expectSatisfies" ((PVar "what") (PVar "p") (PVar "x")) (EBlock (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "x"))) (DoExpr (EIf (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "Pass") (EVar "what")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString " but got "))) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (EVar "what")) (EVar "a"))))))
(DTypeSig true "expectEqual" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectEqual" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EMethodRef "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EMethodRef "eq") (EVar "expected")) (EVar "actual")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString " but got "))) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectNotEqual" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectNotEqual" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EMethodRef "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EDictApp "neq") (EVar "expected")) (EVar "actual")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (ELit (LString "expected values to differ but both were ")) (EVar "a"))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectLessThan" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectLessThan" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EMethodRef "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EMethodRef "lt") (EVar "actual")) (EVar "expected")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString " < "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectGreaterThan" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectGreaterThan" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EMethodRef "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EMethodRef "gt") (EVar "actual")) (EVar "expected")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString " > "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectAtLeast" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectAtLeast" ((PVar "floor") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EMethodRef "debug") (EVar "floor"))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EMethodRef "gte") (EVar "actual")) (EVar "floor")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString " >= "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectAtMost" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectAtMost" ((PVar "ceiling") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EMethodRef "debug") (EVar "ceiling"))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EMethodRef "lte") (EVar "actual")) (EVar "ceiling")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString " <= "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectOk" (TyConstrained ((cstr "Debug" (TyVar "e")) (cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectOk" ((PVar "r")) (EBlock (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "r"))) (DoExpr (EMatch (EVar "r") (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "Pass") (ELit (LString "Ok _"))) (EVar "a"))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Ok but got ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "Ok _"))) (EVar "a")))))))
(DTypeSig true "expectErr" (TyConstrained ((cstr "Debug" (TyVar "e")) (cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectErr" ((PVar "r")) (EBlock (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "r"))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" PWild) () (EApp (EApp (EVar "Pass") (ELit (LString "Err _"))) (EVar "a"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Err but got ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "Err _"))) (EVar "a")))))))
(DTypeSig true "expectErrContains" (TyConstrained ((cstr "Debug" (TyVar "e")) (cstr "Debug" (TyVar "a")) (cstr "Display" (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Expectation")))))
(DFunDef false "expectErrContains" ((PVar "needle") (PVar "r")) (EBlock (DoLet false false (PVar "want") (EBinOp "++" (EBinOp "++" (ELit (LString "Err containing ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "needle")))) (ELit (LString "")))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "r"))) (DoExpr (EMatch (EVar "r") (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Err but got ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (EVar "want")) (EVar "a"))) (arm (PCon "Err" (PVar "e")) () (EIf (EApp (EApp (EVar "contains") (EVar "needle")) (EApp (EMethodRef "display") (EVar "e"))) (EApp (EApp (EVar "Pass") (EVar "want")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected the error to contain ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "needle")))) (ELit (LString " but got "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EMethodRef "display") (EVar "e"))))) (ELit (LString "")))) (EVar "want")) (EVar "a"))))))))
(DTypeSig true "expectOkThen" (TyConstrained ((cstr "Debug" (TyVar "e")) (cstr "Display" (TyVar "e"))) (TyFun (TyFun (TyVar "a") (TyCon "Expectation")) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Expectation")))))
(DFunDef false "expectOkThen" ((PVar "k") (PCon "Ok" (PVar "v"))) (EApp (EVar "k") (EVar "v")))
(DFunDef false "expectOkThen" (PWild (PCon "Err" (PVar "e"))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Ok but got Err ")) (EApp (EMethodRef "display") (EApp (EMethodRef "display") (EVar "e")))) (ELit (LString "")))) (ELit (LString "Ok _"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Err ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "e")))) (ELit (LString "")))))
(DTypeSig true "expectSome" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectSome" ((PVar "o")) (EBlock (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "o"))) (DoExpr (EMatch (EVar "o") (arm (PCon "Some" PWild) () (EApp (EApp (EVar "Pass") (ELit (LString "Some _"))) (EVar "a"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected Some but got ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "Some _"))) (EVar "a")))))))
(DTypeSig true "expectNone" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Expectation"))))
(DFunDef false "expectNone" ((PVar "o")) (EBlock (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "o"))) (DoExpr (EMatch (EVar "o") (arm (PCon "None") () (EApp (EApp (EVar "Pass") (ELit (LString "None"))) (EVar "a"))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected None but got ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (ELit (LString "None"))) (EVar "a")))))))
(DTypeSig true "expectWithin" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Expectation")))))
(DFunDef false "expectWithin" ((PVar "expected") (PVar "actual") (PVar "eps")) (EBlock (DoLet false false (PVar "e") (EApp (EMethodRef "debug") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EMethodRef "debug") (EVar "actual"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "approxEq") (EVar "expected")) (EVar "actual")) (EVar "eps")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString " within "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "eps")))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "e")) (EVar "a"))))))
(DTypeSig false "missingTextNeedles" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "missingTextNeedles" ((PVar "needles") (PVar "actual")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "needle")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "needle")) (EVar "actual"))))) (EVar "needles")))
(DTypeSig true "expectTextContainsAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Expectation"))))
(DFunDef false "expectTextContainsAll" ((PVar "needles") (PVar "actual")) (EBlock (DoLet false false (PVar "expected") (EApp (EMethodRef "debug") (EVar "needles"))) (DoExpr (EMatch (EApp (EApp (EVar "missingTextNeedles") (EVar "needles")) (EVar "actual")) (arm (PList) () (EApp (EApp (EVar "Pass") (EVar "expected")) (EVar "actual"))) (arm (PCons (PVar "missing") PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected text containing ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "missing")))) (ELit (LString "")))) (EVar "expected")) (EVar "actual")))))))
(DTypeSig false "lineContainsAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "lineContainsAll" ((PVar "needles") (PVar "line")) (EMatch (EApp (EApp (EVar "missingTextNeedles") (EVar "needles")) (EVar "line")) (arm (PList) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig true "expectLineContainsAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Expectation"))))
(DFunDef false "expectLineContainsAll" ((PVar "needles") (PVar "actual")) (EBlock (DoLet false false (PVar "expected") (EApp (EMethodRef "debug") (EVar "needles"))) (DoExpr (EIf (EApp (EApp (EDictApp "any") (EApp (EVar "lineContainsAll") (EVar "needles"))) (EApp (EVar "lines") (EVar "actual"))) (EApp (EApp (EVar "Pass") (EVar "expected")) (EVar "actual")) (EApp (EApp (EApp (EVar "Fail") (ELit (LString "expected one line containing every required string"))) (EVar "expected")) (EVar "actual"))))))
(DTypeSig true "expectTextStartsWithAndContains" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Expectation")))))
(DFunDef false "expectTextStartsWithAndContains" ((PVar "prefix") (PVar "needles") (PVar "actual")) (EBlock (DoLet false false (PVar "expected") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "prefix ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "prefix")))) (ELit (LString ", substrings "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "needles")))) (ELit (LString "")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "actual"))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected text starting with ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "prefix")))) (ELit (LString "")))) (EVar "expected")) (EVar "actual")) (EMatch (EApp (EApp (EVar "missingTextNeedles") (EVar "needles")) (EVar "actual")) (arm (PList) () (EApp (EApp (EVar "Pass") (EVar "expected")) (EVar "actual"))) (arm (PCons (PVar "missing") PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "expected text containing ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "missing")))) (ELit (LString "")))) (EVar "expected")) (EVar "actual"))))))))
(DTypeSig false "normalizeTrailingUnit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normalizeTrailingUnit" ((PVar "s")) (EMatch (EApp (EApp (EVar "stripSuffix") (ELit (LString "()"))) (EVar "s")) (arm (PCon "Some" (PVar "s2")) () (EVar "s2")) (arm (PCon "None") () (EMatch (EApp (EVar "last") (EApp (EVar "lines") (EVar "s"))) (arm (PCon "Some" (PLit (LString "0"))) () (EApp (EApp (EVar "optionOr") (EVar "s")) (EApp (EApp (EVar "stripSuffix") (ELit (LString "0"))) (EVar "s")))) (arm PWild () (EVar "s"))))))
(DTypeSig false "diffLineMsg" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "diffLineMsg" ((PVar "n") (PList) (PList)) (ELit (LString "expected and actual differ only outside their lines")))
(DFunDef false "diffLineMsg" ((PVar "n") (PList) (PCons (PVar "a") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ": expected nothing but got "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "a")))) (ELit (LString ""))))
(DFunDef false "diffLineMsg" ((PVar "n") (PCons (PVar "e") PWild) (PList)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ": expected "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "e")))) (ELit (LString " but got nothing"))))
(DFunDef false "diffLineMsg" ((PVar "n") (PCons (PVar "e") (PVar "es")) (PCons (PVar "a") (PVar "asL"))) (EIf (EBinOp "==" (EVar "e") (EVar "a")) (EApp (EApp (EApp (EVar "diffLineMsg") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "es")) (EVar "asL")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ": expected "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "e")))) (ELit (LString " but got "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "a")))) (ELit (LString "")))))
(DTypeSig true "expectEqualText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Expectation"))))
(DFunDef false "expectEqualText" ((PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "e") (EApp (EVar "normalizeTrailingUnit") (EVar "expected"))) (DoLet false false (PVar "a") (EApp (EVar "normalizeTrailingUnit") (EVar "actual"))) (DoExpr (EIf (EBinOp "==" (EVar "e") (EVar "a")) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EApp (EApp (EApp (EVar "diffLineMsg") (ELit (LInt 1))) (EApp (EVar "lines") (EVar "e"))) (EApp (EVar "lines") (EVar "a")))) (EVar "e")) (EVar "a"))))))
(DTypeSig true "expectEqualLines" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Expectation"))))
(DFunDef false "expectEqualLines" ((PVar "expected") (PVar "actual")) (EIf (EBinOp "==" (EVar "expected") (EVar "actual")) (EApp (EApp (EVar "Pass") (EVar "expected")) (EVar "actual")) (EApp (EApp (EApp (EVar "Fail") (EApp (EApp (EApp (EVar "diffLineMsg") (ELit (LInt 1))) (EApp (EVar "lines") (EVar "expected"))) (EApp (EVar "lines") (EVar "actual")))) (EVar "expected")) (EVar "actual"))))
(DTypeSig false "expectAllStep" (TyFun (TyCon "Expectation") (TyFun (TyCon "Expectation") (TyCon "Expectation"))))
(DFunDef false "expectAllStep" ((PCon "Fail" (PVar "msg") (PVar "e") (PVar "a")) PWild) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (EVar "e")) (EVar "a")))
(DFunDef false "expectAllStep" ((PCon "Pass" PWild PWild) (PCon "Fail" (PVar "msg") (PVar "e") (PVar "a"))) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (EVar "e")) (EVar "a")))
(DFunDef false "expectAllStep" ((PCon "Pass" PWild PWild) (PCon "Pass" PWild PWild)) (EVar "pass"))
(DTypeSig true "expectAll" (TyFun (TyApp (TyCon "List") (TyCon "Expectation")) (TyCon "Expectation")))
(DFunDef false "expectAll" ((PVar "es")) (EApp (EApp (EApp (EMethodRef "fold") (EVar "expectAllStep")) (EVar "pass")) (EVar "es")))
(DTypeSig true "labelFail" (TyFun (TyCon "String") (TyFun (TyCon "Expectation") (TyCon "Expectation"))))
(DFunDef false "labelFail" (PWild (PCon "Pass" (PVar "e") (PVar "a"))) (EApp (EApp (EVar "Pass") (EVar "e")) (EVar "a")))
(DFunDef false "labelFail" ((PVar "label") (PCon "Fail" (PVar "m") (PVar "e") (PVar "a"))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))) (EVar "e")) (EVar "a")))
(DTypeSig true "expectEach" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expectation"))) (TyCon "Expectation")))
(DFunDef false "expectEach" ((PVar "rows")) (EApp (EVar "expectAll") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "label") (PVar "e"))) (EApp (EApp (EVar "labelFail") (EVar "label")) (EVar "e")))) (EVar "rows"))))
(DTypeSig false "indentFinding" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "indentFinding" ((PVar "hit")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "hit"))) (ELit (LString ""))))
(DTypeSig true "expectNoFindings" (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Expectation"))))
(DFunDef false "expectNoFindings" ((PVar "what") (PCon "Err" (PVar "e"))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (ELit (LString "no findings"))) (ELit (LString "the check could not run"))))
(DFunDef false "expectNoFindings" (PWild (PCon "Ok" (PList))) (EApp (EApp (EVar "Pass") (ELit (LString "no findings"))) (ELit (LString "no findings"))))
(DFunDef false "expectNoFindings" ((PVar "what") (PCon "Ok" (PVar "hits"))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString ":\n"))) (EApp (EMethodRef "display") (EApp (EVar "unlines") (EApp (EApp (EMethodRef "map") (EVar "indentFinding")) (EVar "hits"))))) (ELit (LString "")))) (ELit (LString "no findings"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EMethodRef "length") (EVar "hits"))))) (ELit (LString " findings")))))
(DTypeSig true "expectFindings" (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Expectation"))))
(DFunDef false "expectFindings" ((PVar "what") (PCon "Err" (PVar "e"))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (ELit (LString "a finding"))) (ELit (LString "the check could not run"))))
(DFunDef false "expectFindings" ((PVar "what") (PCon "Ok" (PList))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString ": nothing was reported")))) (ELit (LString "a finding"))) (ELit (LString "no findings"))))
(DFunDef false "expectFindings" (PWild (PCon "Ok" (PVar "hits"))) (EApp (EApp (EVar "Pass") (ELit (LString "a finding"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EMethodRef "length") (EVar "hits"))))) (ELit (LString " findings")))))
(DTypeSig true "expectationTag" (TyFun (TyCon "Expectation") (TyCon "String")))
(DFunDef false "expectationTag" ((PCon "Pass" PWild PWild)) (ELit (LString "Pass")))
(DFunDef false "expectationTag" ((PCon "Fail" PWild PWild PWild)) (ELit (LString "Fail")))
(DTypeSig true "expectationMessage" (TyFun (TyCon "Expectation") (TyCon "String")))
(DFunDef false "expectationMessage" ((PCon "Pass" PWild PWild)) (ELit (LString "")))
(DFunDef false "expectationMessage" ((PCon "Fail" (PVar "m") PWild PWild)) (EVar "m"))
(DTypeSig true "expectationExpected" (TyFun (TyCon "Expectation") (TyCon "String")))
(DFunDef false "expectationExpected" ((PCon "Pass" (PVar "e") PWild)) (EVar "e"))
(DFunDef false "expectationExpected" ((PCon "Fail" PWild (PVar "e") PWild)) (EVar "e"))
(DTypeSig true "expectationActual" (TyFun (TyCon "Expectation") (TyCon "String")))
(DFunDef false "expectationActual" ((PCon "Pass" PWild (PVar "a"))) (EVar "a"))
(DFunDef false "expectationActual" ((PCon "Fail" PWild PWild (PVar "a"))) (EVar "a"))
(DTypeSig false "goTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Expectation")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "goTests" ((PList) (PVar "passed") (PVar "failed")) (EBlock (DoExpr (EApp (EDictApp "println") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "passed")))) (ELit (LString " passed, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "failed")))) (ELit (LString " failed"))))) (DoExpr (EApp (EApp (EMethodRef "eq") (EVar "failed")) (ELit (LInt 0))))))
(DFunDef false "goTests" ((PCons (PTuple (PVar "name") (PVar "thunk")) (PVar "rest")) (PVar "passed") (PVar "failed")) (EMatch (EApp (EVar "thunk") (ELit LUnit)) (arm (PCon "Pass" PWild PWild) () (EBlock (DoExpr (EApp (EDictApp "println") (EBinOp "++" (ELit (LString "  ok   ")) (EVar "name")))) (DoExpr (EApp (EApp (EApp (EVar "goTests") (EVar "rest")) (EBinOp "+" (EVar "passed") (ELit (LInt 1)))) (EVar "failed"))))) (arm (PCon "Fail" (PVar "msg") PWild PWild) () (EBlock (DoExpr (EApp (EDictApp "println") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EVar "goTests") (EVar "rest")) (EVar "passed")) (EBinOp "+" (EVar "failed") (ELit (LInt 1)))))))))
(DTypeSig true "runTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Expectation")))) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "runTests" ((PVar "tests")) (EApp (EApp (EApp (EVar "goTests") (EVar "tests")) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig true "expectGolden" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyCon "Expectation")))))
(DFunDef false "expectGolden" ((PVar "path") (PVar "actual")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected golden ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (ELit (LString ""))) (EVar "actual"))) (arm (PCon "Ok" (PVar "golden")) () (EApp (EApp (EVar "expectEqualText") (EVar "golden")) (EVar "actual")))))
(DProp false "Eq Expectation separates constructors and payloads" ((pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "pass") (EVar "pass")) (EBinOp "==" (EApp (EVar "fail") (EVar "m")) (EApp (EVar "fail") (EVar "m")))) (EBinOp "==" (EBinOp "==" (EVar "pass") (EApp (EVar "fail") (EVar "m"))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EApp (EVar "fail") (EVar "m")) (EApp (EVar "fail") (EBinOp "++" (EVar "m") (ELit (LString "!"))))) (EVar "False"))))
(DProp false "a passing expectEqual carries both rendered operands" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EDictApp "expectEqual") (EVar "n")) (EVar "n")) (EApp (EApp (EVar "Pass") (EApp (EMethodRef "debug") (EVar "n"))) (EApp (EMethodRef "debug") (EVar "n")))))
(DProp false "Debug Expectation agrees with Eq" ((pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "==" (EApp (EMethodRef "debug") (EApp (EVar "fail") (EVar "m"))) (EApp (EMethodRef "debug") (EApp (EVar "fail") (EVar "m")))) (EBinOp "==" (EBinOp "==" (EApp (EMethodRef "debug") (EApp (EVar "fail") (EVar "m"))) (EApp (EMethodRef "debug") (EVar "pass"))) (EVar "False"))))
(DProp false "labelFail is identity on Pass and prefixes the message on Fail" ((pp "l" (TyCon "String")) (pp "m" (TyCon "String"))) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "labelFail") (EVar "l")) (EVar "pass")) (EVar "pass")) (EBinOp "==" (EApp (EApp (EVar "labelFail") (EVar "l")) (EApp (EVar "fail") (EVar "m"))) (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))))
(DProp false "expectAtLeast passes when actual equals the floor" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "expectationTag") (EApp (EApp (EDictApp "expectAtLeast") (EVar "n")) (EVar "n"))) (ELit (LString "Pass"))))
(DProp false "expectEqualText never conflates a value with that value plus a digit" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "intToString") (EApp (EMethodRef "abs") (EVar "n")))) (DoExpr (EMatch (EApp (EApp (EVar "expectEqualText") (EVar "s")) (EBinOp "++" (EVar "s") (ELit (LString "0")))) (arm (PCon "Pass" PWild PWild) () (EVar "False")) (arm (PCon "Fail" PWild PWild PWild) () (EVar "True"))))))
