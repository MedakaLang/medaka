# META
source_lines=82
stages=DESUGAR,MARK
# SOURCE
import process.{
  PipeChoice(..),
  SpawnOptions(..),
  ProcessError(..),
  ProcessOperation(..),
  StartError(..),
  ExitStatus(..),
  start,
  pollExit,
  closeStdin,
  dispose,
}
import test.{Expectation(..), expectTrue, fail, pass}

options : SpawnOptions
options = SpawnOptions {
  argv = ["-c", "read line; exit 42"],
  cwd = "/tmp",
  env = [],
  stdin = Piped,
  stdout = Null,
  stderr = Null,
}

waitExit : Process p -> Int -> <Exec p> Expectation
waitExit _ 0 = fail "pollExit remained pending after 1000000 attempts"
waitExit p n = match pollExit p
  Ok (Some (Exited 42)) => pass
  Ok (Some (Exited code)) =>
    fail "pollExit returned exit code \{intToString code}, expected 42"
  Ok (Some (Signalled sig _)) =>
    fail "pollExit returned signal \{intToString sig}, expected exit 42"
  Ok None => waitExit p (n - 1)
  Err _ => fail "pollExit returned an error while waiting for exit 42"

test "process aliases share close, exit and disposal state" =
  match start "/bin/sh" options
    Err _ => fail "start failed"
    Ok p =>
      let alias = p
      match (pollExit p, dispose alias, closeStdin p, closeStdin alias)
        (Ok None, Err StillRunning, Ok _, Ok _) =>
          let exited = waitExit alias 1000000
          match exited
            Fail _ _ _ => exited
            _ => match (pollExit p, dispose alias, dispose p, pollExit alias)
              (Ok (Some (Exited 42)), Ok _, Ok _, Err ProcessClosed) => pass
              _ => fail "terminal alias state"
        _ => fail "live alias state"

test "missing executable is a launch error" =
  match start "/medaka-no-such-image" options
    Err (StartRejected (SpawnFailed ExecImage _ _)) => expectTrue True
    _ => fail "missing image did not report ExecImage"

test "native process retains an owner until stdin closes and exit is reaped" =
  let opts = SpawnOptions {
    argv = ["-c", "read line; exit 42"],
    cwd = "/tmp",
    env = [],
    stdin = Piped,
    stdout = Null,
    stderr = Null,
  }
  match start "/bin/sh" opts
    Err _ => fail "process start failed"
    Ok p =>
      let held = Ref p
      let get = _ => !held
      let owners = [get ()]
      let _ = arrayMake 100000 123
      match owners
        [owner] => match pollExit owner
          Ok None => match closeStdin (get ())
            Ok _ =>
              let exited = waitExit owner 1000000
              match dispose p
                Ok _ => exited
                Err _ => fail "dispose failed"
            Err _ => fail "close stdin failed"
          _ => fail "child was not live"
        _ => fail "owner container lost"
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("process") ((mem "PipeChoice" true) (mem "SpawnOptions" true) (mem "ProcessError" true) (mem "ProcessOperation" true) (mem "StartError" true) (mem "ExitStatus" true) (mem "start" false) (mem "pollExit" false) (mem "closeStdin" false) (mem "dispose" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" true) (mem "expectTrue" false) (mem "fail" false) (mem "pass" false))))
(DTypeSig false "options" (TyCon "SpawnOptions"))
(DFunDef false "options" () (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "read line; exit 42")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Null")) (fa "stderr" (EVar "Null")))))
(DTypeSig false "waitExit" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Int") (TyEffect ((atom "Exec" (name "p"))) None (TyCon "Expectation")))))
(DFunDef false "waitExit" (PWild (PLit (LInt 0))) (EApp (EVar "fail") (ELit (LString "pollExit remained pending after 1000000 attempts"))))
(DFunDef false "waitExit" ((PVar "p") (PVar "n")) (EMatch (EApp (EVar "pollExit") (EVar "p")) (arm (PCon "Ok" (PCon "Some" (PCon "Exited" (PLit (LInt 42))))) () (EVar "pass")) (arm (PCon "Ok" (PCon "Some" (PCon "Exited" (PVar "code")))) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "pollExit returned exit code ")) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", expected 42"))))) (arm (PCon "Ok" (PCon "Some" (PCon "Signalled" (PVar "sig") PWild))) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "pollExit returned signal ")) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "sig")))) (ELit (LString ", expected exit 42"))))) (arm (PCon "Ok" (PCon "None")) () (EApp (EApp (EVar "waitExit") (EVar "p")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "pollExit returned an error while waiting for exit 42"))))))
(DTest false "process aliases share close, exit and disposal state" (EMatch (EApp (EApp (EVar "start") (ELit (LString "/bin/sh"))) (EVar "options")) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "start failed")))) (arm (PCon "Ok" (PVar "p")) () (EBlock (DoLet false false (PVar "alias") (EVar "p")) (DoExpr (EMatch (ETuple (EApp (EVar "pollExit") (EVar "p")) (EApp (EVar "dispose") (EVar "alias")) (EApp (EVar "closeStdin") (EVar "p")) (EApp (EVar "closeStdin") (EVar "alias"))) (arm (PTuple (PCon "Ok" (PCon "None")) (PCon "Err" (PCon "StillRunning")) (PCon "Ok" PWild) (PCon "Ok" PWild)) () (EBlock (DoLet false false (PVar "exited") (EApp (EApp (EVar "waitExit") (EVar "alias")) (ELit (LInt 1000000)))) (DoExpr (EMatch (EVar "exited") (arm (PCon "Fail" PWild PWild PWild) () (EVar "exited")) (arm PWild () (EMatch (ETuple (EApp (EVar "pollExit") (EVar "p")) (EApp (EVar "dispose") (EVar "alias")) (EApp (EVar "dispose") (EVar "p")) (EApp (EVar "pollExit") (EVar "alias"))) (arm (PTuple (PCon "Ok" (PCon "Some" (PCon "Exited" (PLit (LInt 42))))) (PCon "Ok" PWild) (PCon "Ok" PWild) (PCon "Err" (PCon "ProcessClosed"))) () (EVar "pass")) (arm PWild () (EApp (EVar "fail") (ELit (LString "terminal alias state")))))))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "live alias state"))))))))))
(DTest false "missing executable is a launch error" (EMatch (EApp (EApp (EVar "start") (ELit (LString "/medaka-no-such-image"))) (EVar "options")) (arm (PCon "Err" (PCon "StartRejected" (PCon "SpawnFailed" (PCon "ExecImage") PWild PWild))) () (EApp (EVar "expectTrue") (EVar "True"))) (arm PWild () (EApp (EVar "fail") (ELit (LString "missing image did not report ExecImage"))))))
(DTest false "native process retains an owner until stdin closes and exit is reaped" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "read line; exit 42")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Null")) (fa "stderr" (EVar "Null"))))) (DoExpr (EMatch (EApp (EApp (EVar "start") (ELit (LString "/bin/sh"))) (EVar "opts")) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "process start failed")))) (arm (PCon "Ok" (PVar "p")) () (EBlock (DoLet false false (PVar "held") (EApp (EVar "Ref") (EVar "p"))) (DoLet false false (PVar "get") (ELam (PWild) (EUnOp "!" (EVar "held")))) (DoLet false false (PVar "owners") (EListLit (EApp (EVar "get") (ELit LUnit)))) (DoLet false false PWild (EApp (EApp (EVar "arrayMake") (ELit (LInt 100000))) (ELit (LInt 123)))) (DoExpr (EMatch (EVar "owners") (arm (PList (PVar "owner")) () (EMatch (EApp (EVar "pollExit") (EVar "owner")) (arm (PCon "Ok" (PCon "None")) () (EMatch (EApp (EVar "closeStdin") (EApp (EVar "get") (ELit LUnit))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "exited") (EApp (EApp (EVar "waitExit") (EVar "owner")) (ELit (LInt 1000000)))) (DoExpr (EMatch (EApp (EVar "dispose") (EVar "p")) (arm (PCon "Ok" PWild) () (EVar "exited")) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "dispose failed")))))))) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "close stdin failed")))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "child was not live")))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "owner container lost"))))))))))))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("process") ((mem "PipeChoice" true) (mem "SpawnOptions" true) (mem "ProcessError" true) (mem "ProcessOperation" true) (mem "StartError" true) (mem "ExitStatus" true) (mem "start" false) (mem "pollExit" false) (mem "closeStdin" false) (mem "dispose" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" true) (mem "expectTrue" false) (mem "fail" false) (mem "pass" false))))
(DTypeSig false "options" (TyCon "SpawnOptions"))
(DFunDef false "options" () (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "read line; exit 42")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Null")) (fa "stderr" (EVar "Null")))))
(DTypeSig false "waitExit" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Int") (TyEffect ((atom "Exec" (name "p"))) None (TyCon "Expectation")))))
(DFunDef false "waitExit" (PWild (PLit (LInt 0))) (EApp (EVar "fail") (ELit (LString "pollExit remained pending after 1000000 attempts"))))
(DFunDef false "waitExit" ((PVar "p") (PVar "n")) (EMatch (EApp (EVar "pollExit") (EVar "p")) (arm (PCon "Ok" (PCon "Some" (PCon "Exited" (PLit (LInt 42))))) () (EVar "pass")) (arm (PCon "Ok" (PCon "Some" (PCon "Exited" (PVar "code")))) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "pollExit returned exit code ")) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ", expected 42"))))) (arm (PCon "Ok" (PCon "Some" (PCon "Signalled" (PVar "sig") PWild))) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "pollExit returned signal ")) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EVar "sig")))) (ELit (LString ", expected exit 42"))))) (arm (PCon "Ok" (PCon "None")) () (EApp (EApp (EVar "waitExit") (EVar "p")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "pollExit returned an error while waiting for exit 42"))))))
(DTest false "process aliases share close, exit and disposal state" (EMatch (EApp (EApp (EVar "start") (ELit (LString "/bin/sh"))) (EVar "options")) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "start failed")))) (arm (PCon "Ok" (PVar "p")) () (EBlock (DoLet false false (PVar "alias") (EVar "p")) (DoExpr (EMatch (ETuple (EApp (EVar "pollExit") (EVar "p")) (EApp (EVar "dispose") (EVar "alias")) (EApp (EVar "closeStdin") (EVar "p")) (EApp (EVar "closeStdin") (EVar "alias"))) (arm (PTuple (PCon "Ok" (PCon "None")) (PCon "Err" (PCon "StillRunning")) (PCon "Ok" PWild) (PCon "Ok" PWild)) () (EBlock (DoLet false false (PVar "exited") (EApp (EApp (EVar "waitExit") (EVar "alias")) (ELit (LInt 1000000)))) (DoExpr (EMatch (EVar "exited") (arm (PCon "Fail" PWild PWild PWild) () (EVar "exited")) (arm PWild () (EMatch (ETuple (EApp (EVar "pollExit") (EVar "p")) (EApp (EVar "dispose") (EVar "alias")) (EApp (EVar "dispose") (EVar "p")) (EApp (EVar "pollExit") (EVar "alias"))) (arm (PTuple (PCon "Ok" (PCon "Some" (PCon "Exited" (PLit (LInt 42))))) (PCon "Ok" PWild) (PCon "Ok" PWild) (PCon "Err" (PCon "ProcessClosed"))) () (EVar "pass")) (arm PWild () (EApp (EVar "fail") (ELit (LString "terminal alias state")))))))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "live alias state"))))))))))
(DTest false "missing executable is a launch error" (EMatch (EApp (EApp (EVar "start") (ELit (LString "/medaka-no-such-image"))) (EVar "options")) (arm (PCon "Err" (PCon "StartRejected" (PCon "SpawnFailed" (PCon "ExecImage") PWild PWild))) () (EApp (EVar "expectTrue") (EVar "True"))) (arm PWild () (EApp (EVar "fail") (ELit (LString "missing image did not report ExecImage"))))))
(DTest false "native process retains an owner until stdin closes and exit is reaped" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "read line; exit 42")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Null")) (fa "stderr" (EVar "Null"))))) (DoExpr (EMatch (EApp (EApp (EVar "start") (ELit (LString "/bin/sh"))) (EVar "opts")) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "process start failed")))) (arm (PCon "Ok" (PVar "p")) () (EBlock (DoLet false false (PVar "held") (EApp (EVar "Ref") (EVar "p"))) (DoLet false false (PVar "get") (ELam (PWild) (EUnOp "!" (EVar "held")))) (DoLet false false (PVar "owners") (EListLit (EApp (EVar "get") (ELit LUnit)))) (DoLet false false PWild (EApp (EApp (EVar "arrayMake") (ELit (LInt 100000))) (ELit (LInt 123)))) (DoExpr (EMatch (EVar "owners") (arm (PList (PVar "owner")) () (EMatch (EApp (EVar "pollExit") (EVar "owner")) (arm (PCon "Ok" (PCon "None")) () (EMatch (EApp (EVar "closeStdin") (EApp (EVar "get") (ELit LUnit))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "exited") (EApp (EApp (EVar "waitExit") (EVar "owner")) (ELit (LInt 1000000)))) (DoExpr (EMatch (EApp (EVar "dispose") (EVar "p")) (arm (PCon "Ok" PWild) () (EVar "exited")) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "dispose failed")))))))) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "close stdin failed")))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "child was not live")))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "owner container lost"))))))))))))
