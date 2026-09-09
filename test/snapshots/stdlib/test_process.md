# META
source_lines=227
stages=DESUGAR,MARK
# SOURCE
{- | Assertions for a test that runs a program.

   A test whose subject is a whole toolchain (a compiler verb, a script, any
   binary) cannot compute its answer; it has to spawn the thing and grade
   what came back. `expectSpawnOk`, `expectSpawnFails` and
   `expectSpawnOkLine` grade a spawn, and `medakaRoot`, `underRoot` and
   `medakaBin` say which files and which binary a test addresses.

   The two jobs are deliberately separate: a grader that also resolved the
   binary would have to name a verb, and callers need `check`, `run` and
   `test`.

   A test that grades a whole directory of `medaka test` suites reads their
   executed-assertion counts with `testAssertionCount`, and keeps its roster
   closed over the directory with `testFileStem`, `unrosteredTestFiles` and
   `missingTestFiles`.

   These assertions reach a subprocess extern, which `medaka test` does not
   bind under the interpreter, so a file using them runs under `medaka test
   --native`.

   Import what you need: `import test_process.{expectSpawnOk, medakaBin}`. -}

import io.{getEnvOr, runVerb}
import json.{asInt, get, parse}
import list.{somes}
import string.{contains, endsWith, lines, stripSuffix, unwords}
import test.{Expectation(..)}

-- # Locating the tree

{- | The root of the Medaka tree under test, from `MEDAKA_ROOT`, or `"."`
   when that is unset.

   Files are located through this rather than through the working
   directory: a test runner exports the root and inherits whatever
   directory its own caller happened to be in. -}
export
medakaRoot : <IO> String
medakaRoot = getEnvOr "MEDAKA_ROOT" "."

-- | The path `rel`, which is relative to the tree root, resolved under
-- `medakaRoot`.
export
underRoot : String -> <IO> String
underRoot rel = "\{medakaRoot}/\{rel}"

{- | The Medaka binary to spawn, from `MEDAKA`, defaulting to the one in
   `medakaRoot`.

   The default is a path, never the bare name `medaka`, so an unset
   `MEDAKA` cannot resolve to some other build on `PATH`, or to nothing at
   all, which still spawns and exits 127 with no output, an outcome any
   assertion phrased over the output would accept. -}
export
medakaBin : <IO> String
medakaBin = getEnvOr "MEDAKA" "\{medakaRoot}/medaka"

-- # Grading a spawn

{- | Passes when running `cmd` with `args` exits 0.

   The exit code is the whole assertion: a program that produced no output
   at all still has to have exited 0. The failure message carries stdout
   and stderr concatenated, since which stream a diagnostic lands on is not
   what this asserts on.

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

   Both halves are required. A rejection graded on the exit code alone
   stays green once the diagnostic it was written for has been deleted, and
   one graded on the text alone accepts a program that never ran. `needle`
   is matched against stdout and stderr concatenated.

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

{- | Passes when running `cmd` with `args` exits 0 and one whole line of its
   output equals `wantLine`.

   The control-case peer of `expectSpawnFails`: exit 0 alone accepts a
   program that ran and printed the wrong answer, and a substring accepts a
   line that merely contains the expected one, so a longer or differently
   prefixed line still passes. `wantLine` is matched against a whole line of
   stdout and stderr concatenated, with a trailing carriage return removed.

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

{- | The executed-assertion count of `path`, from the `summary.passed` field
   of `medaka test --json`, or `Err` naming what went wrong.

   `extraArgs` are passed to `medaka test` before the path, so a suite that
   needs the compiled engine is spawned with `["--native"]`. The count comes
   from `--json` rather than the human transcript, so a change to the
   transcript's shape cannot silently zero it. A suite that exits nonzero is
   an `Err`, never a count, because a failed assertion is not a smaller
   number of passing ones. -}
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
          "`\{line}` exited \{intToString code} — an assertion failed, or the file did not run: \{debug (out ++ err)}"
      else match parse out
        Err e => Err "\{path}: --json output did not parse: \{e}"
        Ok j => match get "summary" j
          None => Err "\{path}: no \"summary\" in --json output"
          Some summary => match get "passed" summary
            None => Err "\{path}: no \"summary.passed\" in --json output"
            Some p => match asInt p
              None => Err "\{path}: \"summary.passed\" is not an integer"
              Some n => Ok n

{- | The `*_test.mdk` stems in `dir` that are absent from `known`.

   `known` is the caller's roster plus whatever it deliberately exempts, so
   an empty result means the roster is closed over the directory and a new
   test file cannot be added without either joining the roster or taking an
   exemption. -}
export
unrosteredTestFiles : String ->
  List String ->
  <FileRead "_"> Result String (List String)
unrosteredTestFiles dir known = match listDir dir
  Err e => Err "could not list \{dir}: \{e}"
  Ok names =>
    Ok (filter (n => not (elem n known)) (somes (map testFileStem names)))

{- | The stems in `wanted` that name no `*_test.mdk` file in `dir`.

   The other half of a closed roster: a roster or exemption row naming a file
   that was renamed or deleted still reads as coverage, and only this
   reports it. -}
export
missingTestFiles : String ->
  List String ->
  <FileRead "_"> Result String (List String)
missingTestFiles dir wanted = match listDir dir
  Err e => Err "could not list \{dir}: \{e}"
  Ok names =>
    let present = somes (map testFileStem names)
    Ok (filter (n => not (elem n present)) wanted)
# DESUGAR
(DUse false (UseGroup ("io") ((mem "getEnvOr" false) (mem "runVerb" false))))
(DUse false (UseGroup ("json") ((mem "asInt" false) (mem "get" false) (mem "parse" false))))
(DUse false (UseGroup ("list") ((mem "somes" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "endsWith" false) (mem "lines" false) (mem "stripSuffix" false) (mem "unwords" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" true))))
(DTypeSig true "medakaRoot" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "medakaRoot" () (EApp (EApp (EVar "getEnvOr") (ELit (LString "MEDAKA_ROOT"))) (ELit (LString "."))))
(DTypeSig true "underRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "underRoot" ((PVar "rel")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "medakaRoot"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "rel"))) (ELit (LString ""))))
(DTypeSig true "medakaBin" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "medakaBin" () (EApp (EApp (EVar "getEnvOr") (ELit (LString "MEDAKA"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "medakaRoot"))) (ELit (LString "/medaka")))))
(DTypeSig true "expectSpawnOk" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec")) None (TyCon "Expectation")))))
(DFunDef false "expectSpawnOk" ((PVar "cmd") (PVar "args")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (ELit (LString "exit 0"))) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "a") (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EVar "Pass") (ELit (LString "exit 0"))) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "debug") (EBinOp "++" (EVar "out") (EVar "err"))))) (ELit (LString "")))) (ELit (LString "exit 0"))) (EVar "a"))))))))))
(DTypeSig true "expectSpawnFails" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ((hole "Exec")) None (TyCon "Expectation"))))))
(DFunDef false "expectSpawnFails" ((PVar "cmd") (PVar "args") (PVar "needle")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoLet false false (PVar "want") (EBinOp "++" (EBinOp "++" (ELit (LString "nonzero exit, output containing ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "needle")))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "want")) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "text") (EBinOp "++" (EVar "out") (EVar "err"))) (DoLet false false (PVar "got") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", output "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "text")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited 0, expected it to fail")))) (EVar "want")) (EVar "got")) (EIf (EApp (EApp (EVar "contains") (EVar "needle")) (EVar "text")) (EApp (EApp (EVar "Pass") (EVar "want")) (EVar "got")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString " but its output does not contain "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "needle")))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got")))))))))))
(DTypeSig true "expectSpawnOkLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ((hole "Exec")) None (TyCon "Expectation"))))))
(DFunDef false "expectSpawnOkLine" ((PVar "cmd") (PVar "args") (PVar "wantLine")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoLet false false (PVar "want") (EBinOp "++" (EBinOp "++" (ELit (LString "exit 0, output with a line ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "wantLine")))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EVar "want")) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "text") (EBinOp "++" (EVar "out") (EVar "err"))) (DoLet false false (PVar "got") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", output "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "text")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", expected 0: "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got")) (EIf (EApp (EApp (EVar "elem") (EVar "wantLine")) (EApp (EVar "lines") (EVar "text"))) (EApp (EApp (EVar "Pass") (EVar "want")) (EVar "got")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited 0 but no output line equals "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "wantLine")))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got")))))))))))
(DTypeSig true "testFileStem" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "testFileStem" ((PVar "name")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "name")) (EApp (EApp (EVar "stripSuffix") (ELit (LString ".mdk"))) (EVar "name")) (EVar "None")))
(DTypeSig true "testAssertionCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec") "IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "testAssertionCount" ((PVar "path") (PVar "extraArgs")) (EBlock (DoLet false false (PVar "args") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "test"))) (EVar "extraArgs")) (EListLit (EVar "path") (ELit (LString "--json"))))) (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "medakaBin") (EVar "args")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "medakaBin")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString " — an assertion failed, or the file did not run: "))) (EApp (EVar "display") (EApp (EVar "debug") (EBinOp "++" (EVar "out") (EVar "err"))))) (ELit (LString "")))) (EMatch (EApp (EVar "parse") (EVar "out")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": --json output did not parse: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "j")) () (EMatch (EApp (EApp (EVar "get") (ELit (LString "summary"))) (EVar "j")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": no \"summary\" in --json output"))))) (arm (PCon "Some" (PVar "summary")) () (EMatch (EApp (EApp (EVar "get") (ELit (LString "passed"))) (EVar "summary")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": no \"summary.passed\" in --json output"))))) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EVar "asInt") (EVar "p")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": \"summary.passed\" is not an integer"))))) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EVar "n"))))))))))))))))
(DTypeSig true "unrosteredTestFiles" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "unrosteredTestFiles" ((PVar "dir") (PVar "known")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not list ")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "names")) () (EApp (EVar "Ok") (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EVar "n")) (EVar "known"))))) (EApp (EVar "somes") (EApp (EApp (EVar "map") (EVar "testFileStem")) (EVar "names"))))))))
(DTypeSig true "missingTestFiles" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "missingTestFiles" ((PVar "dir") (PVar "wanted")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not list ")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "names")) () (EBlock (DoLet false false (PVar "present") (EApp (EVar "somes") (EApp (EApp (EVar "map") (EVar "testFileStem")) (EVar "names")))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EVar "n")) (EVar "present"))))) (EVar "wanted"))))))))
# MARK
(DUse false (UseGroup ("io") ((mem "getEnvOr" false) (mem "runVerb" false))))
(DUse false (UseGroup ("json") ((mem "asInt" false) (mem "get" false) (mem "parse" false))))
(DUse false (UseGroup ("list") ((mem "somes" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "endsWith" false) (mem "lines" false) (mem "stripSuffix" false) (mem "unwords" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" true))))
(DTypeSig true "medakaRoot" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "medakaRoot" () (EApp (EApp (EVar "getEnvOr") (ELit (LString "MEDAKA_ROOT"))) (ELit (LString "."))))
(DTypeSig true "underRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "underRoot" ((PVar "rel")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "medakaRoot"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "rel"))) (ELit (LString ""))))
(DTypeSig true "medakaBin" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "medakaBin" () (EApp (EApp (EVar "getEnvOr") (ELit (LString "MEDAKA"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "medakaRoot"))) (ELit (LString "/medaka")))))
(DTypeSig true "expectSpawnOk" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec")) None (TyCon "Expectation")))))
(DFunDef false "expectSpawnOk" ((PVar "cmd") (PVar "args")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (ELit (LString "exit 0"))) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "a") (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EVar "Pass") (ELit (LString "exit 0"))) (EVar "a")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EBinOp "++" (EVar "out") (EVar "err"))))) (ELit (LString "")))) (ELit (LString "exit 0"))) (EVar "a"))))))))))
(DTypeSig true "expectSpawnFails" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ((hole "Exec")) None (TyCon "Expectation"))))))
(DFunDef false "expectSpawnFails" ((PVar "cmd") (PVar "args") (PVar "needle")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoLet false false (PVar "want") (EBinOp "++" (EBinOp "++" (ELit (LString "nonzero exit, output containing ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "needle")))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "want")) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "text") (EBinOp "++" (EVar "out") (EVar "err"))) (DoLet false false (PVar "got") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", output "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "text")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited 0, expected it to fail")))) (EVar "want")) (EVar "got")) (EIf (EApp (EApp (EVar "contains") (EVar "needle")) (EVar "text")) (EApp (EApp (EVar "Pass") (EVar "want")) (EVar "got")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString " but its output does not contain "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "needle")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got")))))))))))
(DTypeSig true "expectSpawnOkLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ((hole "Exec")) None (TyCon "Expectation"))))))
(DFunDef false "expectSpawnOkLine" ((PVar "cmd") (PVar "args") (PVar "wantLine")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "cmd") (EVar "args")))) (DoLet false false (PVar "want") (EBinOp "++" (EBinOp "++" (ELit (LString "exit 0, output with a line ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "wantLine")))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "cmd")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EVar "want")) (ELit (LString "no spawn")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "text") (EBinOp "++" (EVar "out") (EVar "err"))) (DoLet false false (PVar "got") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "exit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", output "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "text")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", expected 0: "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got")) (EIf (EApp (EApp (EDictApp "elem") (EVar "wantLine")) (EApp (EVar "lines") (EVar "text"))) (EApp (EApp (EVar "Pass") (EVar "want")) (EVar "got")) (EApp (EApp (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited 0 but no output line equals "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "wantLine")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "text")))) (ELit (LString "")))) (EVar "want")) (EVar "got")))))))))))
(DTypeSig true "testFileStem" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "testFileStem" ((PVar "name")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "name")) (EApp (EApp (EVar "stripSuffix") (ELit (LString ".mdk"))) (EVar "name")) (EVar "None")))
(DTypeSig true "testAssertionCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec") "IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "testAssertionCount" ((PVar "path") (PVar "extraArgs")) (EBlock (DoLet false false (PVar "args") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "test"))) (EVar "extraArgs")) (EListLit (EVar "path") (ELit (LString "--json"))))) (DoLet false false (PVar "line") (EApp (EVar "unwords") (EBinOp "::" (EVar "medakaBin") (EVar "args")))) (DoExpr (EMatch (EApp (EApp (EVar "runVerb") (EVar "medakaBin")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not run `")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString "` exited "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString " — an assertion failed, or the file did not run: "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EBinOp "++" (EVar "out") (EVar "err"))))) (ELit (LString "")))) (EMatch (EApp (EVar "parse") (EVar "out")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": --json output did not parse: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "j")) () (EMatch (EApp (EApp (EVar "get") (ELit (LString "summary"))) (EVar "j")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": no \"summary\" in --json output"))))) (arm (PCon "Some" (PVar "summary")) () (EMatch (EApp (EApp (EVar "get") (ELit (LString "passed"))) (EVar "summary")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": no \"summary.passed\" in --json output"))))) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EVar "asInt") (EVar "p")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": \"summary.passed\" is not an integer"))))) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EVar "n"))))))))))))))))
(DTypeSig true "unrosteredTestFiles" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "unrosteredTestFiles" ((PVar "dir") (PVar "known")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not list ")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "names")) () (EApp (EVar "Ok") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EVar "n")) (EVar "known"))))) (EApp (EVar "somes") (EApp (EApp (EMethodRef "map") (EVar "testFileStem")) (EVar "names"))))))))
(DTypeSig true "missingTestFiles" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "missingTestFiles" ((PVar "dir") (PVar "wanted")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not list ")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "names")) () (EBlock (DoLet false false (PVar "present") (EApp (EVar "somes") (EApp (EApp (EMethodRef "map") (EVar "testFileStem")) (EVar "names")))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EVar "n")) (EVar "present"))))) (EVar "wanted"))))))))
