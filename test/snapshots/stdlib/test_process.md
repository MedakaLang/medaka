# META
source_lines=481
stages=DESUGAR,MARK
# SOURCE
{- | Assertions for a test that runs a program.

   A test whose subject is a whole program (a compiler verb, a script, any
   binary) spawns it and grades what came back. `expectSpawnOk`,
   `expectSpawnFails` and `expectSpawnOkLine` grade a spawn. `medakaRoot`,
   `underRoot` and `medakaBin` locate the tree and the binary under test.
   `boundedVerb` puts a time limit on one spawn, and `scratchDir` hands out
   a directory to write in.

   A test that grades a directory of `medaka test` suites reads their
   assertion counts with `testAssertionCount` and checks its roster against
   the directory with `testFileStem`, `unrosteredTestFiles` and
   `missingTestFiles`.

   These assertions spawn a subprocess, which the interpreter does not
   support, so a file using them runs under `medaka test --native`. -}

import io.{getEnvOr, runVerb}
import json.{asInt, get, parse}
import list.{somes}
import string.{
  contains,
  drop,
  endsWith,
  indexOf,
  lines,
  startsWith,
  stripPrefix,
  stripSuffix,
  trim,
  unwords,
}
import test.{Expectation(..)}

-- # Locating the tree

{- | The root of the Medaka tree under test: `MEDAKA_ROOT`, or `"."` when
   it is unset.

   Files are located through this rather than through the working
   directory, which a test does not control. -}
export
medakaRoot : <IO> String
medakaRoot = getEnvOr "MEDAKA_ROOT" "."

-- | The path `rel`, relative to the tree root, resolved under `medakaRoot`.
export
underRoot : String -> <IO> String
underRoot rel = "\{medakaRoot}/\{rel}"

{- | The Medaka binary to spawn: `MEDAKA`, or `medaka` in `medakaRoot`
   when it is unset.

   The default is a path, so an unset `MEDAKA` never resolves to another
   build on `PATH`. -}
export
medakaBin : <IO> String
medakaBin = getEnvOr "MEDAKA" "\{medakaRoot}/medaka"

-- # Spawning

{- | The time limit `boundedVerb` puts on one spawn, in seconds.

   With a limit on each spawn, a subject that hangs fails its own row
   instead of the whole job. -}
export
spawnTimeoutSeconds : Int
spawnTimeoutSeconds = 60

{- | Runs `cmd` with `args` as `io.runVerb` does, killing it after
   `spawnTimeoutSeconds`.

   A killed spawn is an ordinary nonzero exit, not an `Err`.

   > boundedVerb "sh" ["-c", "printf hi; exit 3"]
   Ok (3, "hi", "") -}
export
boundedVerb : String ->
  List String ->
  <Exec "_"> Result String (Int, String, String)
boundedVerb cmd args = boundedVerbSeconds spawnTimeoutSeconds cmd args

{- | `boundedVerb` with the time limit given as `secs`, for a spawn that
   needs longer than `spawnTimeoutSeconds`.

   `cmd` is looked up on `PATH` through `env`, so a command that does not
   exist reports exit 127 with `env`'s message on stderr rather than a
   spawn that never ran. The wording of that message varies between
   systems.

   > boundedVerbSeconds 5 "sh" ["-c", "printf hi; exit 3"]
   Ok (3, "hi", "")
   > map ((c, o, e) => (c, o, e /= "")) (boundedVerbSeconds 5 "medaka-no-such-verb" [])
   Ok (127, "", True) -}
export
boundedVerbSeconds : Int ->
  String ->
  List String ->
  <Exec "_"> Result String (Int, String, String)
boundedVerbSeconds secs cmd args =
  runVerb
    "perl"
    (["-e", "alarm \{intToString secs}; exec @ARGV", "env", cmd] ++ args)

{- | A fresh, empty directory for a test that has to write files.

   Each call returns a directory nothing else holds, so concurrent runs of
   the same test do not collide. The caller owns the directory and removes
   it.

   > map (startsWith "/") scratchDir
   Ok True -}
export
scratchDir : <Exec "_"> Result String String
scratchDir = match runVerb "mktemp" ["-d"]
  Err e => Err e
  Ok (0, out, _) => Ok (trim out)
  Ok (code, _, err) => Err "mktemp -d exited \{intToString code}: \{err}"

-- # Grading a spawn

{- | Passes when running `cmd` with `args` exits 0.

   Output is not graded. The failure message carries stdout and stderr
   concatenated.

   > expectSpawnOk "true" []
   Pass "exit 0" "exit 0"
   > expectSpawnOk "false" []
   Fail "`false` exited 1: \"\"" "exit 0" "exit 1" -}
export
expectSpawnOk : String -> List String -> <Exec "_"> Expectation
expectSpawnOk cmd args =
  let line = unwords (cmd :: args)
  match runVerb cmd args
    Err e => Fail "could not run `\{line}`: \{e}" "exit 0" "no spawn"
    Ok (code, out, err) =>
      let a = "exit \{intToString code}"
      if code == 0 then
        Pass "exit 0" a
      else
        Fail
          "`\{line}` exited \{intToString code}: \{debug (out ++ err)}"
          "exit 0"
          a

{- | Passes when running `cmd` with `args` exits nonzero and its output
   contains `needle`.

   Both conditions are required: exit 0 fails whatever was printed, and a
   nonzero exit whose output lacks `needle` fails naming what was printed.
   `needle` is matched against stdout and stderr concatenated.

   > expectSpawnFails "sh" ["-c", "exit 3"] ""
   Pass "nonzero exit, output containing \"\"" "exit 3, output \"\""
   > expectSpawnFails "true" [] "boom"
   Fail "`true` exited 0, expected it to fail" "nonzero exit, output containing \"boom\"" "exit 0, output \"\"" -}
export
expectSpawnFails : String -> List String -> String -> <Exec "_"> Expectation
expectSpawnFails cmd args needle =
  let line = unwords (cmd :: args)
  let want = "nonzero exit, output containing \{debug needle}"
  match runVerb cmd args
    Err e => Fail "could not run `\{line}`: \{e}" want "no spawn"
    Ok (code, out, err) =>
      let text = out ++ err
      let got = "exit \{intToString code}, output \{debug text}"
      if code == 0 then
        Fail "`\{line}` exited 0, expected it to fail" want got
      else if contains needle text then
        Pass want got
      else
        Fail
          "`\{line}` exited \{intToString code} but its output does not contain \{debug needle}: \{debug text}"
          want
          got

{- | Passes when running `cmd` with `args` exits nonzero and its output
   contains every string in `needles`.

   The strings may occur in any order and on different lines, and are
   matched against stdout and stderr concatenated. An empty `needles` list
   grades the exit code alone. To require the strings on one line, grade
   the captured output with `test.expectLineContainsAll`.

   > expectSpawnFailsAll "sh" ["-c", "printf alpha-beta; exit 3"] ["alpha", "beta"]
   Pass "nonzero exit, output containing [\"alpha\", \"beta\"]" "exit 3, output \"alpha-beta\""
   > expectSpawnFailsAll "sh" ["-c", "printf alpha; exit 3"] ["alpha", "beta"]
   Fail "`sh -c printf alpha; exit 3` exited 3 but its output does not contain \"beta\": \"alpha\"" "nonzero exit, output containing [\"alpha\", \"beta\"]" "exit 3, output \"alpha\""
   > expectSpawnFailsAll "true" [] ["alpha"]
   Fail "`true` exited 0, expected it to fail" "nonzero exit, output containing [\"alpha\"]" "exit 0, output \"\"" -}
export
expectSpawnFailsAll : String ->
  List String ->
  List String ->
  <Exec "_"> Expectation
expectSpawnFailsAll cmd args needles =
  let line = unwords (cmd :: args)
  let want = "nonzero exit, output containing \{debug needles}"
  match runVerb cmd args
    Err e => Fail "could not run `\{line}`: \{e}" want "no spawn"
    Ok (code, out, err) =>
      let text = out ++ err
      let got = "exit \{intToString code}, output \{debug text}"
      if code == 0 then
        Fail "`\{line}` exited 0, expected it to fail" want got
      else match filter (n => not (contains n text)) needles
        [] => Pass want got
        missing :: _ =>
          Fail
            "`\{line}` exited \{intToString code} but its output does not contain \{debug missing}: \{debug text}"
            want
            got

{- | Passes when running `cmd` with `args` exits 0 and one whole line of its
   output equals `wantLine`.

   A line that merely contains `wantLine` does not match. Lines are taken
   from stdout and stderr concatenated, with a trailing carriage return
   removed.

   > expectSpawnOkLine "echo" ["hi"] "hi"
   Pass "exit 0, output with a line \"hi\"" "exit 0, output \"hi\\n\""
   > expectSpawnOkLine "echo" ["said hi"] "hi"
   Fail "`echo said hi` exited 0 but no output line equals \"hi\": \"said hi\\n\"" "exit 0, output with a line \"hi\"" "exit 0, output \"said hi\\n\"" -}
export
expectSpawnOkLine : String -> List String -> String -> <Exec "_"> Expectation
expectSpawnOkLine cmd args wantLine =
  let line = unwords (cmd :: args)
  let want = "exit 0, output with a line \{debug wantLine}"
  match runVerb cmd args
    Err e => Fail "could not run `\{line}`: \{e}" want "no spawn"
    Ok (code, out, err) =>
      let text = out ++ err
      let got = "exit \{intToString code}, output \{debug text}"
      if code /= 0 then
        Fail
          "`\{line}` exited \{intToString code}, expected 0: \{debug text}"
          want
          got
      else if elem wantLine (lines text) then
        Pass want got
      else
        Fail
          "`\{line}` exited 0 but no output line equals \{debug wantLine}: \{debug text}"
          want
          got

-- # Grading a directory of suites

{- | The stem of a `*_test.mdk` file name, or `None` when `name` is not one.

   > testFileStem "expr_test.mdk"
   Some "expr_test"
   > testFileStem "expr.mdk"
   None -}
export
testFileStem : String -> Option String
testFileStem name =
  if endsWith "_test.mdk" name then stripSuffix ".mdk" name else None

-- How much of a failed spawn's captured output a failure message carries,
-- in characters. A failing `medaka test --json` run can emit tens of
-- kilobytes; the tail is kept because that is where a runner prints what
-- failed.
failureOutputTailChars : Int
failureOutputTailChars = 2000

{- | The last `limit` characters of `text`, prefixed with a count of what was
   dropped when anything was.

   > outputTailOf 3 "abcdef"
   "[3 earlier characters omitted] def"
   > outputTailOf 6 "abcdef"
   "abcdef" -}
outputTailOf : Int -> String -> String
outputTailOf limit text =
  let extra = stringLength text - limit
  if extra <= 0 then
    text
  else
    "[\{intToString extra} earlier characters omitted] \{drop extra text}"

-- | `outputTailOf` at the ceiling a failure message carries.
outputTail : String -> String
outputTail text = outputTailOf failureOutputTailChars text

{- | The number of assertions `medaka test --json` reports as passed for the
   suite at `path`, or `Err` naming what went wrong.

   `extraArgs` are passed to `medaka test` before the path, so a suite that
   needs the compiled engine is spawned with `["--native"]`. A suite that
   exits nonzero is an `Err`, never a smaller count. The `Err` for a
   failing run carries the tail of its output. -}
export
testAssertionCount : String -> List String -> <Exec "_", IO> Result String Int
testAssertionCount path extraArgs =
  let args = ["test"] ++ extraArgs ++ [path, "--json"]
  let line = unwords (medakaBin :: args)
  match runVerb medakaBin args
    Err e => Err "could not run `\{line}`: \{e}"
    Ok (code, out, err) =>
      if code /= 0 then
        Err
          "`\{line}` exited \{intToString code} — an assertion failed, or the file did not run: \{debug (outputTail (out ++ err))}"
      else match parse out
        Err e => Err "\{path}: --json output did not parse: \{e}"
        Ok j => match get "summary" j
          None => Err "\{path}: no \"summary\" in --json output"
          Some summary => match get "passed" summary
            None => Err "\{path}: no \"summary.passed\" in --json output"
            Some p => match asInt p
              None => Err "\{path}: \"summary.passed\" is not an integer"
              Some n => Ok n

{- | The units `namer` finds among `entries` that are absent from `known`.

   `namer` turns a directory entry into the name a roster spells, or `None`
   for an entry that is not a unit, which is skipped.

   > unrosteredUnits testFileStem ["a_test"] ["a_test.mdk", "b_test.mdk", "readme.md"]
   ["b_test"] -}
export
unrosteredUnits : (String -> Option String) ->
  List String ->
  List String ->
  List String
unrosteredUnits namer known entries =
  filter (n => not (elem n known)) (somes (map namer entries))

{- | The names in `wanted` for which `namer` finds no entry in `entries`.

   The complement of `unrosteredUnits`: it reports a roster row naming a
   unit that is no longer present. Both functions take the roster before
   the entries.

   > missingUnits testFileStem ["a_test", "b_test"] ["a_test.mdk"]
   ["b_test"] -}
export
missingUnits : (String -> Option String) ->
  List String ->
  List String ->
  List String
missingUnits namer wanted entries =
  let present = somes (map namer entries)
  filter (n => not (elem n present)) wanted

{- | The `*_test.mdk` stems in `dir` that are absent from `known`.

   `known` is the roster plus any exemptions, so an empty result means every
   test file in `dir` is accounted for. -}
export
unrosteredTestFiles : String ->
  List String ->
  <FileRead "_"> Result String (List String)
unrosteredTestFiles dir known = match listDir dir
  Err e => Err "could not list \{dir}: \{e}"
  Ok names => Ok (unrosteredUnits testFileStem known names)

{- | The stems in `wanted` that name no `*_test.mdk` file in `dir`.

   Reports a roster row whose file is no longer present. -}
export
missingTestFiles : String ->
  List String ->
  <FileRead "_"> Result String (List String)
missingTestFiles dir wanted = match listDir dir
  Err e => Err "could not list \{dir}: \{e}"
  Ok names => Ok (missingUnits testFileStem wanted names)

-- # Grading a floor roster against its own `test` blocks

-- The opening text of a floor-assertion title, `test "`. `ungradedRosterRows`
-- reads a roster module's own source for titles of this shape, so the shape
-- is spelled once here rather than kept as a second list beside the blocks.
floorTitleOpen : String
floorTitleOpen = "test \""

-- The text a floor-assertion title puts between the unit's name and the
-- number it commits.
floorTitleMid : String
floorTitleMid = ".mdk executed >="

-- | The unit a floor-assertion title on `line` claims, given the path
-- prefix that roster's titles are spelled with, or `None` for any other
-- line.
titledFloorName : String -> String -> Option String
titledFloorName titlePrefix line =
  match stripPrefix (floorTitleOpen ++ titlePrefix) line
    None => None
    Some rest => map (i => stringSlice 0 i rest) (indexOf floorTitleMid rest)

-- | The unit a grading call on `line` actually passes, given the call's
-- opening text up to that argument's quote, or `None` for any other line.
gradedFloorName : String -> String -> Option String
gradedFloorName callOpen line = match indexOf callOpen line
  None => None
  Some i =>
    let rest = stringSlice (i + stringLength callOpen) (stringLength line) line
    map (j => stringSlice 0 j rest) (indexOf "\"" rest)

-- | The unit graded by the body following a title line: the lines up to the
-- next top-level `test` declaration, so a block that grades nothing cannot
-- borrow the following block's call.
gradedFloorAfter : String -> List String -> Option String
gradedFloorAfter _ [] = None
gradedFloorAfter callOpen (line :: rest) = match stripPrefix floorTitleOpen line
  Some _ => None
  None => match gradedFloorName callOpen line
    Some graded => Some graded
    None => gradedFloorAfter callOpen rest

-- Every floor-assertion title in `sourceLines`, paired with the unit the
-- block's own body grades. The title is prose and the argument is the lookup
-- key, so the two can disagree; a disagreeing block leaves the titled row's
-- floor unapplied while the row still reads as covered.
floorBlockPairs : String ->
  String ->
  List String ->
  List (String, Option String)
floorBlockPairs _ _ [] = []
floorBlockPairs titlePrefix callOpen (line :: rest) =
  match titledFloorName titlePrefix line
    None => floorBlockPairs titlePrefix callOpen rest
    Some titled => match gradedFloorName callOpen line
      Some graded =>
        (titled, Some graded) :: floorBlockPairs titlePrefix callOpen rest
      None =>
        (titled, gradedFloorAfter callOpen rest)
          :: floorBlockPairs titlePrefix callOpen rest

floorPairAgrees : (String, Option String) -> Bool
floorPairAgrees (titled, Some graded) = titled == graded
floorPairAgrees (_, None) = False

{- | The names in `roster` that no `test` block in `sourceLines` both names
   in its title and grades in its body.

   `titlePrefix` is the path prefix the titles are spelled with, such as
   `"stdlib/"`, and `callOpen` is the grading call's opening text up to the
   quote of its name argument, such as `"floorExpectation \""`.
   `sourceLines` is the roster module's own source, read with
   `io.readLines`. A block whose title and grading call name different
   units counts for neither; `disagreeingFloorBlocks` reports those. The
   roster comes before the scanned lines, as in `unrosteredUnits`.

   > ungradedRosterRows "s/" "grade \"" ["a", "b"] ["test \"s/a.mdk executed >= 1 assertions\" = grade \"a\""]
   ["b"] -}
export
ungradedRosterRows : String ->
  String ->
  List String ->
  List String ->
  List String
ungradedRosterRows titlePrefix callOpen roster sourceLines =
  let pairs = floorBlockPairs titlePrefix callOpen sourceLines
  let graded = map fst (filter floorPairAgrees pairs)
  filter (n => not (elem n graded)) roster

-- | A disagreeing block rendered as `<name its title claims> -> <name its
-- body grades>`.
renderFloorDisagreement : (String, Option String) -> String
renderFloorDisagreement (titled, None) = "\{titled} -> grades nothing"
renderFloorDisagreement (titled, Some graded) = "\{titled} -> \{graded}"

{- | The blocks in `sourceLines` whose title and grading call name different
   units, each rendered as `<titled> -> <graded>`.

   A block that grades nothing renders as `<titled> -> grades nothing`.
   `ungradedRosterRows` reports the rows such a block leaves ungraded.

   > disagreeingFloorBlocks "s/" "grade \"" ["test \"s/a.mdk executed >= 1 assertions\" = grade \"b\""]
   ["a -> b"] -}
export
disagreeingFloorBlocks : String -> String -> List String -> List String
disagreeingFloorBlocks titlePrefix callOpen sourceLines =
  map
    renderFloorDisagreement
    (filter
      (pair => not (floorPairAgrees pair))
      (floorBlockPairs titlePrefix callOpen sourceLines))
# DESUGAR
(DUse false (UseGroup ("io") ((mem "getEnvOr" false) (mem "runVerb" false))))
(DUse false (UseGroup ("json") ((mem "asInt" false) (mem "get" false) (mem "parse" false))))
(DUse false (UseGroup ("list") ((mem "somes" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "drop" false) (mem "endsWith" false) (mem "indexOf" false) (mem "lines" false) (mem "startsWith" false) (mem "stripPrefix" false) (mem "stripSuffix" false) (mem "trim" false) (mem "unwords" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" true))))
(DTypeSig true "medakaRoot" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "medakaRoot" () (EApp (EApp (EVar "getEnvOr") (ELit (LString "MEDAKA_ROOT"))) (ELit (LString "."))))
(DTypeSig true "underRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "underRoot" ((PVar "rel")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "medakaRoot"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "rel"))) (ELit (LString ""))))
(DTypeSig true "medakaBin" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "medakaBin" () (EApp (EApp (EVar "getEnvOr") (ELit (LString "MEDAKA"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "medakaRoot"))) (ELit (LString "/medaka")))))
(DTypeSig true "spawnTimeoutSeconds" (TyCon "Int"))
(DFunDef false "spawnTimeoutSeconds" () (ELit (LInt 60)))
(DTypeSig true "boundedVerb" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String")))))))
(DFunDef false "boundedVerb" ((PVar "cmd") (PVar "args")) (EApp (EApp (EApp (EVar "boundedVerbSeconds") (EVar "spawnTimeoutSeconds")) (EVar "cmd")) (EVar "args")))
(DTypeSig true "boundedVerbSeconds" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String"))))))))
(DFunDef false "boundedVerbSeconds" ((PVar "secs") (PVar "cmd") (PVar "args")) (EApp (EApp (EVar "runVerb") (ELit (LString "perl"))) (EBinOp "++" (EListLit (ELit (LString "-e")) (EBinOp "++" (EBinOp "++" (ELit (LString "alarm ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "secs")))) (ELit (LString "; exec @ARGV"))) (ELit (LString "env")) (EVar "cmd")) (EVar "args"))))
(DTypeSig true "scratchDir" (TyEffect ((hole "Exec")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))
(DFunDef false "scratchDir" () (EMatch (EApp (EApp (EVar "runVerb") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EApp (EVar "Ok") (EApp (EVar "trim") (EVar "out")))) (arm (PCon "Ok" (PTuple (PVar "code") PWild (PVar "err"))) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mktemp -d exited ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "err"))) (ELit (LString "")))))))
(DTypeSig true "expectSpawnOk" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec")) None (TyCon "Expectation")))))
(DFunDef false "expectSpawnOk" ((PVar "cmd") (PVar "args")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (ELit (LString "exit 0"))) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "a") (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EVar "Pass") (ELit (LString "exit 0"))) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "debug") (EBinOp "++" (EVar "out") (EVar "err"))))) (ELit (LString "")))) (ELit (LString "exit 0"))) (EVar "a"))))))))))
(DTypeSig true "expectSpawnFails" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ((hole "Exec")) None (TyCon "Expectation"))))))
(DFunDef false "expectSpawnFails" ((PVar "cmd") (PVar "args") (PVar "needle")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoLet false false (PVar "want") (EBinOp "++" (EBinOp "++" (ELit (LString "nonzero exit, output containing ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "needle")))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "want")) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "text") (EBinOp "++" (EVar "out") (EVar "err"))) (DoLet false false (PVar "got") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", output "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "text")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited 0, expected it to fail")))) (EVar "want")) (EVar "got")) (EIf (EApp (EApp (EVar "contains") (EVar "needle")) (EVar "text")) (EApp (EApp (EVar "Pass") (EVar "want")) (EVar "got")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString " but its output does not contain "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "needle")))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got")))))))))))
(DTypeSig true "expectSpawnFailsAll" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec")) None (TyCon "Expectation"))))))
(DFunDef false "expectSpawnFailsAll" ((PVar "cmd") (PVar "args") (PVar "needles")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoLet false false (PVar "want") (EBinOp "++" (EBinOp "++" (ELit (LString "nonzero exit, output containing ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "needles")))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "want")) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "text") (EBinOp "++" (EVar "out") (EVar "err"))) (DoLet false false (PVar "got") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", output "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "text")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited 0, expected it to fail")))) (EVar "want")) (EVar "got")) (EMatch (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "text"))))) (EVar "needles")) (arm (PList) () (EApp (EApp (EVar "Pass") (EVar "want")) (EVar "got"))) (arm (PCons (PVar "missing") PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString " but its output does not contain "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "missing")))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got"))))))))))))
(DTypeSig true "expectSpawnOkLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ((hole "Exec")) None (TyCon "Expectation"))))))
(DFunDef false "expectSpawnOkLine" ((PVar "cmd") (PVar "args") (PVar "wantLine")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoLet false false (PVar "want") (EBinOp "++" (EBinOp "++" (ELit (LString "exit 0, output with a line ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "wantLine")))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "want")) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "text") (EBinOp "++" (EVar "out") (EVar "err"))) (DoLet false false (PVar "got") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", output "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "text")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", expected 0: "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got")) (EIf (EApp (EApp (EVar "elem") (EVar "wantLine")) (EApp (EVar "lines") (EVar "text"))) (EApp (EApp (EVar "Pass") (EVar "want")) (EVar "got")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited 0 but no output line equals "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "wantLine")))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got")))))))))))
(DTypeSig true "testFileStem" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "testFileStem" ((PVar "name")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "name")) (EApp (EApp (EVar "stripSuffix") (ELit (LString ".mdk"))) (EVar "name")) (EVar "None")))
(DTypeSig false "failureOutputTailChars" (TyCon "Int"))
(DFunDef false "failureOutputTailChars" () (ELit (LInt 2000)))
(DTypeSig false "outputTailOf" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "outputTailOf" ((PVar "limit") (PVar "text")) (EBlock (DoLet false false (PVar "extra") (EBinOp "-" (EApp (EVar "stringLength") (EVar "text")) (EVar "limit"))) (DoExpr (EIf (EBinOp "<=" (EVar "extra") (ELit (LInt 0))) (EVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "extra")))) (ELit (LString " earlier characters omitted] "))) (EApp (EVar "display") (EApp (EApp (EVar "drop") (EVar "extra")) (EVar "text")))) (ELit (LString "")))))))
(DTypeSig false "outputTail" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "outputTail" ((PVar "text")) (EApp (EApp (EVar "outputTailOf") (EVar "failureOutputTailChars")) (EVar "text")))
(DTypeSig true "testAssertionCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec") "IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "testAssertionCount" ((PVar "path") (PVar "extraArgs")) (EBlock (DoLet false false (PVar "args") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "test"))) (EVar "extraArgs")) (EListLit (EVar "path") (ELit (LString "--json"))))) (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "medakaBin") (EVar "args")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "medakaBin")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString " — an assertion failed, or the file did not run: "))) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "outputTail") (EBinOp "++" (EVar "out") (EVar "err")))))) (ELit (LString "")))) (EMatch (EApp (EVar "parse") (EVar "out")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": --json output did not parse: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "j")) () (EMatch (EApp (EApp (EVar "get") (ELit (LString "summary"))) (EVar "j")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": no \"summary\" in --json output"))))) (arm (PCon "Some" (PVar "summary")) () (EMatch (EApp (EApp (EVar "get") (ELit (LString "passed"))) (EVar "summary")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": no \"summary.passed\" in --json output"))))) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EVar "asInt") (EVar "p")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": \"summary.passed\" is not an integer"))))) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EVar "n"))))))))))))))))
(DTypeSig true "unrosteredUnits" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "unrosteredUnits" ((PVar "namer") (PVar "known") (PVar "entries")) (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EVar "n")) (EVar "known"))))) (EApp (EVar "somes") (EApp (EApp (EVar "map") (EVar "namer")) (EVar "entries")))))
(DTypeSig true "missingUnits" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "missingUnits" ((PVar "namer") (PVar "wanted") (PVar "entries")) (EBlock (DoLet false false (PVar "present") (EApp (EVar "somes") (EApp (EApp (EVar "map") (EVar "namer")) (EVar "entries")))) (DoExpr (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EVar "n")) (EVar "present"))))) (EVar "wanted")))))
(DTypeSig true "unrosteredTestFiles" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "unrosteredTestFiles" ((PVar "dir") (PVar "known")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not list ")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "names")) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "unrosteredUnits") (EVar "testFileStem")) (EVar "known")) (EVar "names"))))))
(DTypeSig true "missingTestFiles" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "missingTestFiles" ((PVar "dir") (PVar "wanted")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not list ")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "names")) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "missingUnits") (EVar "testFileStem")) (EVar "wanted")) (EVar "names"))))))
(DTypeSig false "floorTitleOpen" (TyCon "String"))
(DFunDef false "floorTitleOpen" () (ELit (LString "test \"")))
(DTypeSig false "floorTitleMid" (TyCon "String"))
(DFunDef false "floorTitleMid" () (ELit (LString ".mdk executed >=")))
(DTypeSig false "titledFloorName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "titledFloorName" ((PVar "titlePrefix") (PVar "line")) (EMatch (EApp (EApp (EVar "stripPrefix") (EBinOp "++" (EVar "floorTitleOpen") (EVar "titlePrefix"))) (EVar "line")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "rest")) () (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "rest")))) (EApp (EApp (EVar "indexOf") (EVar "floorTitleMid")) (EVar "rest"))))))
(DTypeSig false "gradedFloorName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "gradedFloorName" ((PVar "callOpen") (PVar "line")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "callOpen")) (EVar "line")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "callOpen")))) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "j")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "j")) (EVar "rest")))) (EApp (EApp (EVar "indexOf") (ELit (LString "\""))) (EVar "rest"))))))))
(DTypeSig false "gradedFloorAfter" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "gradedFloorAfter" (PWild (PList)) (EVar "None"))
(DFunDef false "gradedFloorAfter" ((PVar "callOpen") (PCons (PVar "line") (PVar "rest"))) (EMatch (EApp (EApp (EVar "stripPrefix") (EVar "floorTitleOpen")) (EVar "line")) (arm (PCon "Some" PWild) () (EVar "None")) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "gradedFloorName") (EVar "callOpen")) (EVar "line")) (arm (PCon "Some" (PVar "graded")) () (EApp (EVar "Some") (EVar "graded"))) (arm (PCon "None") () (EApp (EApp (EVar "gradedFloorAfter") (EVar "callOpen")) (EVar "rest")))))))
(DTypeSig false "floorBlockPairs" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "floorBlockPairs" (PWild PWild (PList)) (EListLit))
(DFunDef false "floorBlockPairs" ((PVar "titlePrefix") (PVar "callOpen") (PCons (PVar "line") (PVar "rest"))) (EMatch (EApp (EApp (EVar "titledFloorName") (EVar "titlePrefix")) (EVar "line")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "floorBlockPairs") (EVar "titlePrefix")) (EVar "callOpen")) (EVar "rest"))) (arm (PCon "Some" (PVar "titled")) () (EMatch (EApp (EApp (EVar "gradedFloorName") (EVar "callOpen")) (EVar "line")) (arm (PCon "Some" (PVar "graded")) () (EBinOp "::" (ETuple (EVar "titled") (EApp (EVar "Some") (EVar "graded"))) (EApp (EApp (EApp (EVar "floorBlockPairs") (EVar "titlePrefix")) (EVar "callOpen")) (EVar "rest")))) (arm (PCon "None") () (EBinOp "::" (ETuple (EVar "titled") (EApp (EApp (EVar "gradedFloorAfter") (EVar "callOpen")) (EVar "rest"))) (EApp (EApp (EApp (EVar "floorBlockPairs") (EVar "titlePrefix")) (EVar "callOpen")) (EVar "rest"))))))))
(DTypeSig false "floorPairAgrees" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Bool")))
(DFunDef false "floorPairAgrees" ((PTuple (PVar "titled") (PCon "Some" (PVar "graded")))) (EBinOp "==" (EVar "titled") (EVar "graded")))
(DFunDef false "floorPairAgrees" ((PTuple PWild (PCon "None"))) (EVar "False"))
(DTypeSig true "ungradedRosterRows" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ungradedRosterRows" ((PVar "titlePrefix") (PVar "callOpen") (PVar "roster") (PVar "sourceLines")) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EApp (EVar "floorBlockPairs") (EVar "titlePrefix")) (EVar "callOpen")) (EVar "sourceLines"))) (DoLet false false (PVar "graded") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "filter") (EVar "floorPairAgrees")) (EVar "pairs")))) (DoExpr (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EVar "n")) (EVar "graded"))))) (EVar "roster")))))
(DTypeSig false "renderFloorDisagreement" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "renderFloorDisagreement" ((PTuple (PVar "titled") (PCon "None"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "titled"))) (ELit (LString " -> grades nothing"))))
(DFunDef false "renderFloorDisagreement" ((PTuple (PVar "titled") (PCon "Some" (PVar "graded")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "titled"))) (ELit (LString " -> "))) (EApp (EVar "display") (EVar "graded"))) (ELit (LString ""))))
(DTypeSig true "disagreeingFloorBlocks" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "disagreeingFloorBlocks" ((PVar "titlePrefix") (PVar "callOpen") (PVar "sourceLines")) (EApp (EApp (EVar "map") (EVar "renderFloorDisagreement")) (EApp (EApp (EVar "filter") (ELam ((PVar "pair")) (EApp (EVar "not") (EApp (EVar "floorPairAgrees") (EVar "pair"))))) (EApp (EApp (EApp (EVar "floorBlockPairs") (EVar "titlePrefix")) (EVar "callOpen")) (EVar "sourceLines")))))
# MARK
(DUse false (UseGroup ("io") ((mem "getEnvOr" false) (mem "runVerb" false))))
(DUse false (UseGroup ("json") ((mem "asInt" false) (mem "get" false) (mem "parse" false))))
(DUse false (UseGroup ("list") ((mem "somes" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "drop" false) (mem "endsWith" false) (mem "indexOf" false) (mem "lines" false) (mem "startsWith" false) (mem "stripPrefix" false) (mem "stripSuffix" false) (mem "trim" false) (mem "unwords" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" true))))
(DTypeSig true "medakaRoot" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "medakaRoot" () (EApp (EApp (EVar "getEnvOr") (ELit (LString "MEDAKA_ROOT"))) (ELit (LString "."))))
(DTypeSig true "underRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "underRoot" ((PVar "rel")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "medakaRoot"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "rel"))) (ELit (LString ""))))
(DTypeSig true "medakaBin" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "medakaBin" () (EApp (EApp (EVar "getEnvOr") (ELit (LString "MEDAKA"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "medakaRoot"))) (ELit (LString "/medaka")))))
(DTypeSig true "spawnTimeoutSeconds" (TyCon "Int"))
(DFunDef false "spawnTimeoutSeconds" () (ELit (LInt 60)))
(DTypeSig true "boundedVerb" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String")))))))
(DFunDef false "boundedVerb" ((PVar "cmd") (PVar "args")) (EApp (EApp (EApp (EVar "boundedVerbSeconds") (EVar "spawnTimeoutSeconds")) (EVar "cmd")) (EVar "args")))
(DTypeSig true "boundedVerbSeconds" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String"))))))))
(DFunDef false "boundedVerbSeconds" ((PVar "secs") (PVar "cmd") (PVar "args")) (EApp (EApp (EVar "runVerb") (ELit (LString "perl"))) (EBinOp "++" (EListLit (ELit (LString "-e")) (EBinOp "++" (EBinOp "++" (ELit (LString "alarm ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "secs")))) (ELit (LString "; exec @ARGV"))) (ELit (LString "env")) (EVar "cmd")) (EVar "args"))))
(DTypeSig true "scratchDir" (TyEffect ((hole "Exec")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))
(DFunDef false "scratchDir" () (EMatch (EApp (EApp (EVar "runVerb") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EApp (EVar "Ok") (EApp (EVar "trim") (EVar "out")))) (arm (PCon "Ok" (PTuple (PVar "code") PWild (PVar "err"))) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mktemp -d exited ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "err"))) (ELit (LString "")))))))
(DTypeSig true "expectSpawnOk" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec")) None (TyCon "Expectation")))))
(DFunDef false "expectSpawnOk" ((PVar "cmd") (PVar "args")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (ELit (LString "exit 0"))) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "a") (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EVar "Pass") (ELit (LString "exit 0"))) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EBinOp "++" (EVar "out") (EVar "err"))))) (ELit (LString "")))) (ELit (LString "exit 0"))) (EVar "a"))))))))))
(DTypeSig true "expectSpawnFails" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ((hole "Exec")) None (TyCon "Expectation"))))))
(DFunDef false "expectSpawnFails" ((PVar "cmd") (PVar "args") (PVar "needle")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoLet false false (PVar "want") (EBinOp "++" (EBinOp "++" (ELit (LString "nonzero exit, output containing ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "needle")))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "want")) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "text") (EBinOp "++" (EVar "out") (EVar "err"))) (DoLet false false (PVar "got") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", output "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "text")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited 0, expected it to fail")))) (EVar "want")) (EVar "got")) (EIf (EApp (EApp (EVar "contains") (EVar "needle")) (EVar "text")) (EApp (EApp (EVar "Pass") (EVar "want")) (EVar "got")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString " but its output does not contain "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "needle")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got")))))))))))
(DTypeSig true "expectSpawnFailsAll" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec")) None (TyCon "Expectation"))))))
(DFunDef false "expectSpawnFailsAll" ((PVar "cmd") (PVar "args") (PVar "needles")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoLet false false (PVar "want") (EBinOp "++" (EBinOp "++" (ELit (LString "nonzero exit, output containing ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "needles")))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "want")) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "text") (EBinOp "++" (EVar "out") (EVar "err"))) (DoLet false false (PVar "got") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", output "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "text")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited 0, expected it to fail")))) (EVar "want")) (EVar "got")) (EMatch (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "text"))))) (EVar "needles")) (arm (PList) () (EApp (EApp (EVar "Pass") (EVar "want")) (EVar "got"))) (arm (PCons (PVar "missing") PWild) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString " but its output does not contain "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "missing")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got"))))))))))))
(DTypeSig true "expectSpawnOkLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ((hole "Exec")) None (TyCon "Expectation"))))))
(DFunDef false "expectSpawnOkLine" ((PVar "cmd") (PVar "args") (PVar "wantLine")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoLet false false (PVar "want") (EBinOp "++" (EBinOp "++" (ELit (LString "exit 0, output with a line ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "wantLine")))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "want")) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "text") (EBinOp "++" (EVar "out") (EVar "err"))) (DoLet false false (PVar "got") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", output "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "text")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", expected 0: "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got")) (EIf (EApp (EApp (EDictApp "elem") (EVar "wantLine")) (EApp (EVar "lines") (EVar "text"))) (EApp (EApp (EVar "Pass") (EVar "want")) (EVar "got")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited 0 but no output line equals "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "wantLine")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got")))))))))))
(DTypeSig true "testFileStem" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "testFileStem" ((PVar "name")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "name")) (EApp (EApp (EVar "stripSuffix") (ELit (LString ".mdk"))) (EVar "name")) (EVar "None")))
(DTypeSig false "failureOutputTailChars" (TyCon "Int"))
(DFunDef false "failureOutputTailChars" () (ELit (LInt 2000)))
(DTypeSig false "outputTailOf" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "outputTailOf" ((PVar "limit") (PVar "text")) (EBlock (DoLet false false (PVar "extra") (EBinOp "-" (EApp (EVar "stringLength") (EVar "text")) (EVar "limit"))) (DoExpr (EIf (EBinOp "<=" (EVar "extra") (ELit (LInt 0))) (EVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "extra")))) (ELit (LString " earlier characters omitted] "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "drop") (EVar "extra")) (EVar "text")))) (ELit (LString "")))))))
(DTypeSig false "outputTail" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "outputTail" ((PVar "text")) (EApp (EApp (EVar "outputTailOf") (EVar "failureOutputTailChars")) (EVar "text")))
(DTypeSig true "testAssertionCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec") "IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "testAssertionCount" ((PVar "path") (PVar "extraArgs")) (EBlock (DoLet false false (PVar "args") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "test"))) (EVar "extraArgs")) (EListLit (EVar "path") (ELit (LString "--json"))))) (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "medakaBin") (EVar "args")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "medakaBin")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString " — an assertion failed, or the file did not run: "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EVar "outputTail") (EBinOp "++" (EVar "out") (EVar "err")))))) (ELit (LString "")))) (EMatch (EApp (EVar "parse") (EVar "out")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": --json output did not parse: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "j")) () (EMatch (EApp (EApp (EVar "get") (ELit (LString "summary"))) (EVar "j")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": no \"summary\" in --json output"))))) (arm (PCon "Some" (PVar "summary")) () (EMatch (EApp (EApp (EVar "get") (ELit (LString "passed"))) (EVar "summary")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": no \"summary.passed\" in --json output"))))) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EVar "asInt") (EVar "p")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": \"summary.passed\" is not an integer"))))) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EVar "n"))))))))))))))))
(DTypeSig true "unrosteredUnits" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "unrosteredUnits" ((PVar "namer") (PVar "known") (PVar "entries")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EVar "n")) (EVar "known"))))) (EApp (EVar "somes") (EApp (EApp (EMethodRef "map") (EVar "namer")) (EVar "entries")))))
(DTypeSig true "missingUnits" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "missingUnits" ((PVar "namer") (PVar "wanted") (PVar "entries")) (EBlock (DoLet false false (PVar "present") (EApp (EVar "somes") (EApp (EApp (EMethodRef "map") (EVar "namer")) (EVar "entries")))) (DoExpr (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EVar "n")) (EVar "present"))))) (EVar "wanted")))))
(DTypeSig true "unrosteredTestFiles" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "unrosteredTestFiles" ((PVar "dir") (PVar "known")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not list ")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "names")) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "unrosteredUnits") (EVar "testFileStem")) (EVar "known")) (EVar "names"))))))
(DTypeSig true "missingTestFiles" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "missingTestFiles" ((PVar "dir") (PVar "wanted")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not list ")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "names")) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "missingUnits") (EVar "testFileStem")) (EVar "wanted")) (EVar "names"))))))
(DTypeSig false "floorTitleOpen" (TyCon "String"))
(DFunDef false "floorTitleOpen" () (ELit (LString "test \"")))
(DTypeSig false "floorTitleMid" (TyCon "String"))
(DFunDef false "floorTitleMid" () (ELit (LString ".mdk executed >=")))
(DTypeSig false "titledFloorName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "titledFloorName" ((PVar "titlePrefix") (PVar "line")) (EMatch (EApp (EApp (EVar "stripPrefix") (EBinOp "++" (EVar "floorTitleOpen") (EVar "titlePrefix"))) (EVar "line")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "rest")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "rest")))) (EApp (EApp (EVar "indexOf") (EVar "floorTitleMid")) (EVar "rest"))))))
(DTypeSig false "gradedFloorName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "gradedFloorName" ((PVar "callOpen") (PVar "line")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "callOpen")) (EVar "line")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "callOpen")))) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "j")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "j")) (EVar "rest")))) (EApp (EApp (EVar "indexOf") (ELit (LString "\""))) (EVar "rest"))))))))
(DTypeSig false "gradedFloorAfter" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "gradedFloorAfter" (PWild (PList)) (EVar "None"))
(DFunDef false "gradedFloorAfter" ((PVar "callOpen") (PCons (PVar "line") (PVar "rest"))) (EMatch (EApp (EApp (EVar "stripPrefix") (EVar "floorTitleOpen")) (EVar "line")) (arm (PCon "Some" PWild) () (EVar "None")) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "gradedFloorName") (EVar "callOpen")) (EVar "line")) (arm (PCon "Some" (PVar "graded")) () (EApp (EVar "Some") (EVar "graded"))) (arm (PCon "None") () (EApp (EApp (EVar "gradedFloorAfter") (EVar "callOpen")) (EVar "rest")))))))
(DTypeSig false "floorBlockPairs" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "floorBlockPairs" (PWild PWild (PList)) (EListLit))
(DFunDef false "floorBlockPairs" ((PVar "titlePrefix") (PVar "callOpen") (PCons (PVar "line") (PVar "rest"))) (EMatch (EApp (EApp (EVar "titledFloorName") (EVar "titlePrefix")) (EVar "line")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "floorBlockPairs") (EVar "titlePrefix")) (EVar "callOpen")) (EVar "rest"))) (arm (PCon "Some" (PVar "titled")) () (EMatch (EApp (EApp (EVar "gradedFloorName") (EVar "callOpen")) (EVar "line")) (arm (PCon "Some" (PVar "graded")) () (EBinOp "::" (ETuple (EVar "titled") (EApp (EVar "Some") (EVar "graded"))) (EApp (EApp (EApp (EVar "floorBlockPairs") (EVar "titlePrefix")) (EVar "callOpen")) (EVar "rest")))) (arm (PCon "None") () (EBinOp "::" (ETuple (EVar "titled") (EApp (EApp (EVar "gradedFloorAfter") (EVar "callOpen")) (EVar "rest"))) (EApp (EApp (EApp (EVar "floorBlockPairs") (EVar "titlePrefix")) (EVar "callOpen")) (EVar "rest"))))))))
(DTypeSig false "floorPairAgrees" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Bool")))
(DFunDef false "floorPairAgrees" ((PTuple (PVar "titled") (PCon "Some" (PVar "graded")))) (EBinOp "==" (EVar "titled") (EVar "graded")))
(DFunDef false "floorPairAgrees" ((PTuple PWild (PCon "None"))) (EVar "False"))
(DTypeSig true "ungradedRosterRows" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ungradedRosterRows" ((PVar "titlePrefix") (PVar "callOpen") (PVar "roster") (PVar "sourceLines")) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EApp (EVar "floorBlockPairs") (EVar "titlePrefix")) (EVar "callOpen")) (EVar "sourceLines"))) (DoLet false false (PVar "graded") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EMethodRef "filter") (EVar "floorPairAgrees")) (EVar "pairs")))) (DoExpr (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EVar "n")) (EVar "graded"))))) (EVar "roster")))))
(DTypeSig false "renderFloorDisagreement" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "renderFloorDisagreement" ((PTuple (PVar "titled") (PCon "None"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "titled"))) (ELit (LString " -> grades nothing"))))
(DFunDef false "renderFloorDisagreement" ((PTuple (PVar "titled") (PCon "Some" (PVar "graded")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "titled"))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EVar "graded"))) (ELit (LString ""))))
(DTypeSig true "disagreeingFloorBlocks" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "disagreeingFloorBlocks" ((PVar "titlePrefix") (PVar "callOpen") (PVar "sourceLines")) (EApp (EApp (EMethodRef "map") (EVar "renderFloorDisagreement")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "pair")) (EApp (EVar "not") (EApp (EVar "floorPairAgrees") (EVar "pair"))))) (EApp (EApp (EApp (EVar "floorBlockPairs") (EVar "titlePrefix")) (EVar "callOpen")) (EVar "sourceLines")))))
