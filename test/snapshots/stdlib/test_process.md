# META
source_lines=111
stages=DESUGAR,MARK
# SOURCE
{- | Assertions for a test that runs a program.

   A test whose subject is a whole toolchain — a compiler verb, a script,
   any binary — cannot compute its answer; it has to spawn the thing and
   grade what came back. `expectSpawnOk` and `expectSpawnFails` grade a
   spawn, and `medakaRoot`, `underRoot` and `medakaBin` say which files and
   which binary a test addresses.

   The two jobs are deliberately separate: a grader that also resolved the
   binary would have to name a verb, and callers need `check`, `run` and
   `test`.

   These assertions reach a subprocess extern, which `medaka test` does not
   bind under the interpreter, so a file using them runs under `medaka test
   --native`.

   Import what you need: `import test_process.{expectSpawnOk, medakaBin}`. -}

import io.{getEnvOr, runVerb}
import string.{contains, unwords}
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
   `MEDAKA` cannot resolve to some other build on `PATH` — or to nothing at
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
# DESUGAR
(DUse false (UseGroup ("io") ((mem "getEnvOr" false) (mem "runVerb" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "unwords" false))))
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
# MARK
(DUse false (UseGroup ("io") ((mem "getEnvOr" false) (mem "runVerb" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "unwords" false))))
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
