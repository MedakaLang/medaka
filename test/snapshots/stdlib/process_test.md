# META
source_lines=55
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
import test.{expectTrue, fail}

options : SpawnOptions
options = SpawnOptions {
  argv = ["-c", "read line; exit 42"],
  cwd = "/tmp",
  env = [],
  stdin = Piped,
  stdout = Null,
  stderr = Null,
}

waitExit : Process p -> Int -> <Exec p> Bool
waitExit _ 0 = False
waitExit p n = match pollExit p
  Ok (Some (Exited 42)) => True
  Ok None => waitExit p (n - 1)
  _ => False

test "process aliases share close, exit and disposal state" =
  match start "/bin/sh" options
    Err _ => fail "start failed"
    Ok p =>
      let alias = p
      match (pollExit p, dispose alias, closeStdin p, closeStdin alias)
        (Ok None, Err StillRunning, Ok _, Ok _) =>
          if waitExit alias 1000000 then match (
            pollExit p,
            dispose alias,
            dispose p,
            pollExit alias,
          )
            (Ok (Some (Exited 42)), Ok _, Ok _, Err ProcessClosed) =>
              expectTrue True
            _ => fail "terminal alias state"
          else
            fail "exit was not observed"
        _ => fail "live alias state"

test "missing executable is a launch error" =
  match start "/medaka-no-such-image" options
    Err (StartRejected (SpawnFailed ExecImage _ _)) => expectTrue True
    _ => fail "missing image did not report ExecImage"
# DESUGAR
(DUse false (UseGroup ("process") ((mem "PipeChoice" true) (mem "SpawnOptions" true) (mem "ProcessError" true) (mem "ProcessOperation" true) (mem "StartError" true) (mem "ExitStatus" true) (mem "start" false) (mem "pollExit" false) (mem "closeStdin" false) (mem "dispose" false))))
(DUse false (UseGroup ("test") ((mem "expectTrue" false) (mem "fail" false))))
(DTypeSig false "options" (TyCon "SpawnOptions"))
(DFunDef false "options" () (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "read line; exit 42")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Null")) (fa "stderr" (EVar "Null")))))
(DTypeSig false "waitExit" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Int") (TyEffect ((atom "Exec" (name "p"))) None (TyCon "Bool")))))
(DFunDef false "waitExit" (PWild (PLit (LInt 0))) (EVar "False"))
(DFunDef false "waitExit" ((PVar "p") (PVar "n")) (EMatch (EApp (EVar "pollExit") (EVar "p")) (arm (PCon "Ok" (PCon "Some" (PCon "Exited" (PLit (LInt 42))))) () (EVar "True")) (arm (PCon "Ok" (PCon "None")) () (EApp (EApp (EVar "waitExit") (EVar "p")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (arm PWild () (EVar "False"))))
(DTest false "process aliases share close, exit and disposal state" (EMatch (EApp (EApp (EVar "start") (ELit (LString "/bin/sh"))) (EVar "options")) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "start failed")))) (arm (PCon "Ok" (PVar "p")) () (EBlock (DoLet false false (PVar "alias") (EVar "p")) (DoExpr (EMatch (ETuple (EApp (EVar "pollExit") (EVar "p")) (EApp (EVar "dispose") (EVar "alias")) (EApp (EVar "closeStdin") (EVar "p")) (EApp (EVar "closeStdin") (EVar "alias"))) (arm (PTuple (PCon "Ok" (PCon "None")) (PCon "Err" (PCon "StillRunning")) (PCon "Ok" PWild) (PCon "Ok" PWild)) () (EIf (EApp (EApp (EVar "waitExit") (EVar "alias")) (ELit (LInt 1000000))) (EMatch (ETuple (EApp (EVar "pollExit") (EVar "p")) (EApp (EVar "dispose") (EVar "alias")) (EApp (EVar "dispose") (EVar "p")) (EApp (EVar "pollExit") (EVar "alias"))) (arm (PTuple (PCon "Ok" (PCon "Some" (PCon "Exited" (PLit (LInt 42))))) (PCon "Ok" PWild) (PCon "Ok" PWild) (PCon "Err" (PCon "ProcessClosed"))) () (EApp (EVar "expectTrue") (EVar "True"))) (arm PWild () (EApp (EVar "fail") (ELit (LString "terminal alias state"))))) (EApp (EVar "fail") (ELit (LString "exit was not observed"))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "live alias state"))))))))))
(DTest false "missing executable is a launch error" (EMatch (EApp (EApp (EVar "start") (ELit (LString "/medaka-no-such-image"))) (EVar "options")) (arm (PCon "Err" (PCon "StartRejected" (PCon "SpawnFailed" (PCon "ExecImage") PWild PWild))) () (EApp (EVar "expectTrue") (EVar "True"))) (arm PWild () (EApp (EVar "fail") (ELit (LString "missing image did not report ExecImage"))))))
# MARK
(DUse false (UseGroup ("process") ((mem "PipeChoice" true) (mem "SpawnOptions" true) (mem "ProcessError" true) (mem "ProcessOperation" true) (mem "StartError" true) (mem "ExitStatus" true) (mem "start" false) (mem "pollExit" false) (mem "closeStdin" false) (mem "dispose" false))))
(DUse false (UseGroup ("test") ((mem "expectTrue" false) (mem "fail" false))))
(DTypeSig false "options" (TyCon "SpawnOptions"))
(DFunDef false "options" () (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "read line; exit 42")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Null")) (fa "stderr" (EVar "Null")))))
(DTypeSig false "waitExit" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Int") (TyEffect ((atom "Exec" (name "p"))) None (TyCon "Bool")))))
(DFunDef false "waitExit" (PWild (PLit (LInt 0))) (EVar "False"))
(DFunDef false "waitExit" ((PVar "p") (PVar "n")) (EMatch (EApp (EVar "pollExit") (EVar "p")) (arm (PCon "Ok" (PCon "Some" (PCon "Exited" (PLit (LInt 42))))) () (EVar "True")) (arm (PCon "Ok" (PCon "None")) () (EApp (EApp (EVar "waitExit") (EVar "p")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (arm PWild () (EVar "False"))))
(DTest false "process aliases share close, exit and disposal state" (EMatch (EApp (EApp (EVar "start") (ELit (LString "/bin/sh"))) (EVar "options")) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "start failed")))) (arm (PCon "Ok" (PVar "p")) () (EBlock (DoLet false false (PVar "alias") (EVar "p")) (DoExpr (EMatch (ETuple (EApp (EVar "pollExit") (EVar "p")) (EApp (EVar "dispose") (EVar "alias")) (EApp (EVar "closeStdin") (EVar "p")) (EApp (EVar "closeStdin") (EVar "alias"))) (arm (PTuple (PCon "Ok" (PCon "None")) (PCon "Err" (PCon "StillRunning")) (PCon "Ok" PWild) (PCon "Ok" PWild)) () (EIf (EApp (EApp (EVar "waitExit") (EVar "alias")) (ELit (LInt 1000000))) (EMatch (ETuple (EApp (EVar "pollExit") (EVar "p")) (EApp (EVar "dispose") (EVar "alias")) (EApp (EVar "dispose") (EVar "p")) (EApp (EVar "pollExit") (EVar "alias"))) (arm (PTuple (PCon "Ok" (PCon "Some" (PCon "Exited" (PLit (LInt 42))))) (PCon "Ok" PWild) (PCon "Ok" PWild) (PCon "Err" (PCon "ProcessClosed"))) () (EApp (EVar "expectTrue") (EVar "True"))) (arm PWild () (EApp (EVar "fail") (ELit (LString "terminal alias state"))))) (EApp (EVar "fail") (ELit (LString "exit was not observed"))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "live alias state"))))))))))
(DTest false "missing executable is a launch error" (EMatch (EApp (EApp (EVar "start") (ELit (LString "/medaka-no-such-image"))) (EVar "options")) (arm (PCon "Err" (PCon "StartRejected" (PCon "SpawnFailed" (PCon "ExecImage") PWild PWild))) () (EApp (EVar "expectTrue") (EVar "True"))) (arm PWild () (EApp (EVar "fail") (ELit (LString "missing image did not report ExecImage"))))))
