# META
source_lines=170
stages=DESUGAR,MARK
# SOURCE
public export data PipeChoice = Piped | Null

public export data SpawnOptions = SpawnOptions {
  argv : List String,
  cwd : String,
  env : List (String, String),
  stdin : PipeChoice,
  stdout : PipeChoice,
  stderr : PipeChoice,
}

public export data ProcessOperation =
  | Validate
  | Pipe
  | Fork
  | Chdir
  | ExecImage
  | Wait
  | Close
  | LaunchHandshake
public export data ProcessError =
  | InvalidSpawn String
  | SpawnFailed ProcessOperation Int String
  | ProcessClosed
  | StillRunning
  | WaitFailed Int String
  | CloseFailed Int String
  | Unsupported String
  | LaunchCancelled
public export data ExitStatus = Exited Int | Signalled Int Bool
public export data StartError ticket =
  | StartRejected ProcessError
  | StartCleanupPending ProcessError ticket
public export data LaunchProgress process =
  | LaunchPending
  | LaunchStarted process
  | LaunchFailed ProcessError
  | LaunchAborted

choice : PipeChoice -> Int
choice Piped = 0
choice Null = 1

rawError : (Int, Int, String) -> ProcessError
rawError (0, _, msg) = InvalidSpawn msg
rawError (1, e, msg) = SpawnFailed Pipe e msg
rawError (2, e, msg) = SpawnFailed Fork e msg
rawError (3, e, msg) = SpawnFailed Chdir e msg
rawError (4, e, msg) = SpawnFailed ExecImage e msg
rawError (5, e, msg) = WaitFailed e msg
rawError (6, e, msg) = CloseFailed e msg
rawError (7, _, msg) = Unsupported msg
rawError (8, _, _) = ProcessClosed
rawError (9, _, _) = StillRunning
rawError (10, _, msg) = Unsupported msg
rawError (11, e, msg) = SpawnFailed LaunchHandshake e msg
rawError (12, _, _) = LaunchCancelled
rawError _ = panic "process: invalid error code"

startResult : Result (Int, Int, String, Option (LaunchTicket p)) (Process p) ->
  Result (StartError (LaunchTicket p)) (Process p)
startResult (Ok p) = Ok p
startResult (Err (op, err, msg, None)) =
  Err (StartRejected (rawError (op, err, msg)))
startResult (Err (op, err, msg, Some ticket)) =
  Err (StartCleanupPending (rawError (op, err, msg)) ticket)

progressResult : Result (Int, Int, String) (Int, Option (Process p), Option (Int, Int, String)) ->
  Result ProcessError (LaunchProgress (Process p))
progressResult (Err e) = Err (rawError e)
progressResult (Ok (0, None, None)) = Ok LaunchPending
progressResult (Ok (1, Some p, None)) = Ok (LaunchStarted p)
progressResult (Ok (2, None, Some e)) = Ok (LaunchFailed (rawError e))
progressResult (Ok (3, None, None)) = Ok LaunchAborted
progressResult _ = panic "process: invalid launch progress ABI"

export
start : (program : String) ->
  SpawnOptions ->
  <Exec program> Result (StartError (LaunchTicket program)) (Process program)
start program opts =
  startResult
    (processStartRaw
      program
      opts.argv
      opts.cwd
      opts.env
      (choice opts.stdin)
      (choice opts.stdout)
      (choice opts.stderr))

export
retryStart : LaunchTicket p ->
  <Exec p> Result (StartError (LaunchTicket p)) (Process p)
retryStart ticket = startResult (processRetryStartRaw ticket)

export
checkStart : LaunchTicket p ->
  <Exec p> Result ProcessError (LaunchProgress (Process p))
checkStart ticket = progressResult (processCheckStartRaw ticket)

export
abortStart : LaunchTicket p ->
  <Exec p> Result ProcessError (LaunchProgress (Process p))
abortStart ticket = progressResult (processAbortStartRaw ticket)

exitStatus : (Int, Int, Bool) -> ExitStatus
exitStatus (0, code, _) = Exited code
exitStatus (1, sig, core) = Signalled sig core
exitStatus _ = panic "process: invalid exit status ABI"

export
pollExit : Process p -> <Exec p> Result ProcessError (Option ExitStatus)
pollExit p = match processPollExitRaw p
  Err e => Err (rawError e)
  Ok status => Ok (map exitStatus status)

export
closeStdin : Process p -> <Exec p> Result ProcessError Unit
closeStdin p = mapErr rawError (processCloseStdinRaw p)

export
dispose : Process p -> <Exec p> Result ProcessError Unit
dispose p = mapErr rawError (processDisposeRaw p)

import test.{expectTrue, fail}

waitForTest : Process p -> Int -> <Exec p> Bool
waitForTest _ 0 = False
waitForTest p n = match pollExit p
  Ok (Some (Exited 42)) => True
  Ok None => waitForTest p (n - 1)
  _ => False

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
              let exited = waitForTest owner 1000000
              match dispose p
                Ok _ => expectTrue exited
                Err _ => fail "dispose failed"
            Err _ => fail "close stdin failed"
          _ => fail "child was not live"
        _ => fail "owner container lost"

test "launch progress decodes pending, failed, and aborted shapes" =
  let pending = progressResult (Ok (0, None, None))
  let failed = progressResult (Ok (2, None, Some (12, 0, "cancelled")))
  let aborted = progressResult (Ok (3, None, None))
  expectTrue (match (pending, failed, aborted)
    (Ok LaunchPending, Ok (LaunchFailed LaunchCancelled), Ok LaunchAborted) =>
      True
    _ => False)
# DESUGAR
(DData Public "PipeChoice" () ((variant "Piped" (ConPos)) (variant "Null" (ConPos))) ())
(DData Public "SpawnOptions" () ((variant "SpawnOptions" (ConNamed (field "argv" (TyApp (TyCon "List") (TyCon "String"))) (field "cwd" (TyCon "String")) (field "env" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "stdin" (TyCon "PipeChoice")) (field "stdout" (TyCon "PipeChoice")) (field "stderr" (TyCon "PipeChoice"))))) ())
(DData Public "ProcessOperation" () ((variant "Validate" (ConPos)) (variant "Pipe" (ConPos)) (variant "Fork" (ConPos)) (variant "Chdir" (ConPos)) (variant "ExecImage" (ConPos)) (variant "Wait" (ConPos)) (variant "Close" (ConPos)) (variant "LaunchHandshake" (ConPos))) ())
(DData Public "ProcessError" () ((variant "InvalidSpawn" (ConPos (TyCon "String"))) (variant "SpawnFailed" (ConPos (TyCon "ProcessOperation") (TyCon "Int") (TyCon "String"))) (variant "ProcessClosed" (ConPos)) (variant "StillRunning" (ConPos)) (variant "WaitFailed" (ConPos (TyCon "Int") (TyCon "String"))) (variant "CloseFailed" (ConPos (TyCon "Int") (TyCon "String"))) (variant "Unsupported" (ConPos (TyCon "String"))) (variant "LaunchCancelled" (ConPos))) ())
(DData Public "ExitStatus" () ((variant "Exited" (ConPos (TyCon "Int"))) (variant "Signalled" (ConPos (TyCon "Int") (TyCon "Bool")))) ())
(DData Public "StartError" ("ticket") ((variant "StartRejected" (ConPos (TyCon "ProcessError"))) (variant "StartCleanupPending" (ConPos (TyCon "ProcessError") (TyVar "ticket")))) ())
(DData Public "LaunchProgress" ("process") ((variant "LaunchPending" (ConPos)) (variant "LaunchStarted" (ConPos (TyVar "process"))) (variant "LaunchFailed" (ConPos (TyCon "ProcessError"))) (variant "LaunchAborted" (ConPos))) ())
(DTypeSig false "choice" (TyFun (TyCon "PipeChoice") (TyCon "Int")))
(DFunDef false "choice" ((PCon "Piped")) (ELit (LInt 0)))
(DFunDef false "choice" ((PCon "Null")) (ELit (LInt 1)))
(DTypeSig false "rawError" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String")) (TyCon "ProcessError")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 0)) PWild (PVar "msg"))) (EApp (EVar "InvalidSpawn") (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 1)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "SpawnFailed") (EVar "Pipe")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 2)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "SpawnFailed") (EVar "Fork")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 3)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "SpawnFailed") (EVar "Chdir")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 4)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "SpawnFailed") (EVar "ExecImage")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 5)) (PVar "e") (PVar "msg"))) (EApp (EApp (EVar "WaitFailed") (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 6)) (PVar "e") (PVar "msg"))) (EApp (EApp (EVar "CloseFailed") (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 7)) PWild (PVar "msg"))) (EApp (EVar "Unsupported") (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 8)) PWild PWild)) (EVar "ProcessClosed"))
(DFunDef false "rawError" ((PTuple (PLit (LInt 9)) PWild PWild)) (EVar "StillRunning"))
(DFunDef false "rawError" ((PTuple (PLit (LInt 10)) PWild (PVar "msg"))) (EApp (EVar "Unsupported") (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 11)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "SpawnFailed") (EVar "LaunchHandshake")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 12)) PWild PWild)) (EVar "LaunchCancelled"))
(DFunDef false "rawError" (PWild) (EApp (EVar "panic") (ELit (LString "process: invalid error code"))))
(DTypeSig false "startResult" (TyFun (TyApp (TyApp (TyCon "Result") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "LaunchTicket") (TyVar "p"))))) (TyApp (TyCon "Process") (TyVar "p"))) (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "StartError") (TyApp (TyCon "LaunchTicket") (TyVar "p")))) (TyApp (TyCon "Process") (TyVar "p")))))
(DFunDef false "startResult" ((PCon "Ok" (PVar "p"))) (EApp (EVar "Ok") (EVar "p")))
(DFunDef false "startResult" ((PCon "Err" (PTuple (PVar "op") (PVar "err") (PVar "msg") (PCon "None")))) (EApp (EVar "Err") (EApp (EVar "StartRejected") (EApp (EVar "rawError") (ETuple (EVar "op") (EVar "err") (EVar "msg"))))))
(DFunDef false "startResult" ((PCon "Err" (PTuple (PVar "op") (PVar "err") (PVar "msg") (PCon "Some" (PVar "ticket"))))) (EApp (EVar "Err") (EApp (EApp (EVar "StartCleanupPending") (EApp (EVar "rawError") (ETuple (EVar "op") (EVar "err") (EVar "msg")))) (EVar "ticket"))))
(DTypeSig false "progressResult" (TyFun (TyApp (TyApp (TyCon "Result") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyTuple (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "Process") (TyVar "p"))) (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))) (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "LaunchProgress") (TyApp (TyCon "Process") (TyVar "p"))))))
(DFunDef false "progressResult" ((PCon "Err" (PVar "e"))) (EApp (EVar "Err") (EApp (EVar "rawError") (EVar "e"))))
(DFunDef false "progressResult" ((PCon "Ok" (PTuple (PLit (LInt 0)) (PCon "None") (PCon "None")))) (EApp (EVar "Ok") (EVar "LaunchPending")))
(DFunDef false "progressResult" ((PCon "Ok" (PTuple (PLit (LInt 1)) (PCon "Some" (PVar "p")) (PCon "None")))) (EApp (EVar "Ok") (EApp (EVar "LaunchStarted") (EVar "p"))))
(DFunDef false "progressResult" ((PCon "Ok" (PTuple (PLit (LInt 2)) (PCon "None") (PCon "Some" (PVar "e"))))) (EApp (EVar "Ok") (EApp (EVar "LaunchFailed") (EApp (EVar "rawError") (EVar "e")))))
(DFunDef false "progressResult" ((PCon "Ok" (PTuple (PLit (LInt 3)) (PCon "None") (PCon "None")))) (EApp (EVar "Ok") (EVar "LaunchAborted")))
(DFunDef false "progressResult" (PWild) (EApp (EVar "panic") (ELit (LString "process: invalid launch progress ABI"))))
(DTypeSig true "start" (TyFun (TyNamed "program" (TyCon "String")) (TyFun (TyCon "SpawnOptions") (TyEffect ((atom "Exec" (name "program"))) None (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "StartError") (TyApp (TyCon "LaunchTicket") (TyVar "program")))) (TyApp (TyCon "Process") (TyVar "program")))))))
(DFunDef false "start" ((PVar "program") (PVar "opts")) (EApp (EVar "startResult") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "processStartRaw") (EVar "program")) (EFieldAccess (EVar "opts") "argv")) (EFieldAccess (EVar "opts") "cwd")) (EFieldAccess (EVar "opts") "env")) (EApp (EVar "choice") (EFieldAccess (EVar "opts") "stdin"))) (EApp (EVar "choice") (EFieldAccess (EVar "opts") "stdout"))) (EApp (EVar "choice") (EFieldAccess (EVar "opts") "stderr")))))
(DTypeSig true "retryStart" (TyFun (TyApp (TyCon "LaunchTicket") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "StartError") (TyApp (TyCon "LaunchTicket") (TyVar "p")))) (TyApp (TyCon "Process") (TyVar "p"))))))
(DFunDef false "retryStart" ((PVar "ticket")) (EApp (EVar "startResult") (EApp (EVar "processRetryStartRaw") (EVar "ticket"))))
(DTypeSig true "checkStart" (TyFun (TyApp (TyCon "LaunchTicket") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "LaunchProgress") (TyApp (TyCon "Process") (TyVar "p")))))))
(DFunDef false "checkStart" ((PVar "ticket")) (EApp (EVar "progressResult") (EApp (EVar "processCheckStartRaw") (EVar "ticket"))))
(DTypeSig true "abortStart" (TyFun (TyApp (TyCon "LaunchTicket") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "LaunchProgress") (TyApp (TyCon "Process") (TyVar "p")))))))
(DFunDef false "abortStart" ((PVar "ticket")) (EApp (EVar "progressResult") (EApp (EVar "processAbortStartRaw") (EVar "ticket"))))
(DTypeSig false "exitStatus" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Bool")) (TyCon "ExitStatus")))
(DFunDef false "exitStatus" ((PTuple (PLit (LInt 0)) (PVar "code") PWild)) (EApp (EVar "Exited") (EVar "code")))
(DFunDef false "exitStatus" ((PTuple (PLit (LInt 1)) (PVar "sig") (PVar "core"))) (EApp (EApp (EVar "Signalled") (EVar "sig")) (EVar "core")))
(DFunDef false "exitStatus" (PWild) (EApp (EVar "panic") (ELit (LString "process: invalid exit status ABI"))))
(DTypeSig true "pollExit" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "Option") (TyCon "ExitStatus"))))))
(DFunDef false "pollExit" ((PVar "p")) (EMatch (EApp (EVar "processPollExitRaw") (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "rawError") (EVar "e")))) (arm (PCon "Ok" (PVar "status")) () (EApp (EVar "Ok") (EApp (EApp (EVar "map") (EVar "exitStatus")) (EVar "status"))))))
(DTypeSig true "closeStdin" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyCon "Unit")))))
(DFunDef false "closeStdin" ((PVar "p")) (EApp (EApp (EVar "mapErr") (EVar "rawError")) (EApp (EVar "processCloseStdinRaw") (EVar "p"))))
(DTypeSig true "dispose" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyCon "Unit")))))
(DFunDef false "dispose" ((PVar "p")) (EApp (EApp (EVar "mapErr") (EVar "rawError")) (EApp (EVar "processDisposeRaw") (EVar "p"))))
(DUse false (UseGroup ("test") ((mem "expectTrue" false) (mem "fail" false))))
(DTypeSig false "waitForTest" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Int") (TyEffect ((atom "Exec" (name "p"))) None (TyCon "Bool")))))
(DFunDef false "waitForTest" (PWild (PLit (LInt 0))) (EVar "False"))
(DFunDef false "waitForTest" ((PVar "p") (PVar "n")) (EMatch (EApp (EVar "pollExit") (EVar "p")) (arm (PCon "Ok" (PCon "Some" (PCon "Exited" (PLit (LInt 42))))) () (EVar "True")) (arm (PCon "Ok" (PCon "None")) () (EApp (EApp (EVar "waitForTest") (EVar "p")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (arm PWild () (EVar "False"))))
(DTest false "native process retains an owner until stdin closes and exit is reaped" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "read line; exit 42")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Null")) (fa "stderr" (EVar "Null"))))) (DoExpr (EMatch (EApp (EApp (EVar "start") (ELit (LString "/bin/sh"))) (EVar "opts")) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "process start failed")))) (arm (PCon "Ok" (PVar "p")) () (EBlock (DoLet false false (PVar "held") (EApp (EVar "Ref") (EVar "p"))) (DoLet false false (PVar "get") (ELam (PWild) (EUnOp "!" (EVar "held")))) (DoLet false false (PVar "owners") (EListLit (EApp (EVar "get") (ELit LUnit)))) (DoLet false false PWild (EApp (EApp (EVar "arrayMake") (ELit (LInt 100000))) (ELit (LInt 123)))) (DoExpr (EMatch (EVar "owners") (arm (PList (PVar "owner")) () (EMatch (EApp (EVar "pollExit") (EVar "owner")) (arm (PCon "Ok" (PCon "None")) () (EMatch (EApp (EVar "closeStdin") (EApp (EVar "get") (ELit LUnit))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "exited") (EApp (EApp (EVar "waitForTest") (EVar "owner")) (ELit (LInt 1000000)))) (DoExpr (EMatch (EApp (EVar "dispose") (EVar "p")) (arm (PCon "Ok" PWild) () (EApp (EVar "expectTrue") (EVar "exited"))) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "dispose failed")))))))) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "close stdin failed")))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "child was not live")))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "owner container lost"))))))))))))
(DTest false "launch progress decodes pending, failed, and aborted shapes" (EBlock (DoLet false false (PVar "pending") (EApp (EVar "progressResult") (EApp (EVar "Ok") (ETuple (ELit (LInt 0)) (EVar "None") (EVar "None"))))) (DoLet false false (PVar "failed") (EApp (EVar "progressResult") (EApp (EVar "Ok") (ETuple (ELit (LInt 2)) (EVar "None") (EApp (EVar "Some") (ETuple (ELit (LInt 12)) (ELit (LInt 0)) (ELit (LString "cancelled")))))))) (DoLet false false (PVar "aborted") (EApp (EVar "progressResult") (EApp (EVar "Ok") (ETuple (ELit (LInt 3)) (EVar "None") (EVar "None"))))) (DoExpr (EApp (EVar "expectTrue") (EMatch (ETuple (EVar "pending") (EVar "failed") (EVar "aborted")) (arm (PTuple (PCon "Ok" (PCon "LaunchPending")) (PCon "Ok" (PCon "LaunchFailed" (PCon "LaunchCancelled"))) (PCon "Ok" (PCon "LaunchAborted"))) () (EVar "True")) (arm PWild () (EVar "False")))))))
# MARK
(DData Public "PipeChoice" () ((variant "Piped" (ConPos)) (variant "Null" (ConPos))) ())
(DData Public "SpawnOptions" () ((variant "SpawnOptions" (ConNamed (field "argv" (TyApp (TyCon "List") (TyCon "String"))) (field "cwd" (TyCon "String")) (field "env" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "stdin" (TyCon "PipeChoice")) (field "stdout" (TyCon "PipeChoice")) (field "stderr" (TyCon "PipeChoice"))))) ())
(DData Public "ProcessOperation" () ((variant "Validate" (ConPos)) (variant "Pipe" (ConPos)) (variant "Fork" (ConPos)) (variant "Chdir" (ConPos)) (variant "ExecImage" (ConPos)) (variant "Wait" (ConPos)) (variant "Close" (ConPos)) (variant "LaunchHandshake" (ConPos))) ())
(DData Public "ProcessError" () ((variant "InvalidSpawn" (ConPos (TyCon "String"))) (variant "SpawnFailed" (ConPos (TyCon "ProcessOperation") (TyCon "Int") (TyCon "String"))) (variant "ProcessClosed" (ConPos)) (variant "StillRunning" (ConPos)) (variant "WaitFailed" (ConPos (TyCon "Int") (TyCon "String"))) (variant "CloseFailed" (ConPos (TyCon "Int") (TyCon "String"))) (variant "Unsupported" (ConPos (TyCon "String"))) (variant "LaunchCancelled" (ConPos))) ())
(DData Public "ExitStatus" () ((variant "Exited" (ConPos (TyCon "Int"))) (variant "Signalled" (ConPos (TyCon "Int") (TyCon "Bool")))) ())
(DData Public "StartError" ("ticket") ((variant "StartRejected" (ConPos (TyCon "ProcessError"))) (variant "StartCleanupPending" (ConPos (TyCon "ProcessError") (TyVar "ticket")))) ())
(DData Public "LaunchProgress" ("process") ((variant "LaunchPending" (ConPos)) (variant "LaunchStarted" (ConPos (TyVar "process"))) (variant "LaunchFailed" (ConPos (TyCon "ProcessError"))) (variant "LaunchAborted" (ConPos))) ())
(DTypeSig false "choice" (TyFun (TyCon "PipeChoice") (TyCon "Int")))
(DFunDef false "choice" ((PCon "Piped")) (ELit (LInt 0)))
(DFunDef false "choice" ((PCon "Null")) (ELit (LInt 1)))
(DTypeSig false "rawError" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String")) (TyCon "ProcessError")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 0)) PWild (PVar "msg"))) (EApp (EVar "InvalidSpawn") (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 1)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "SpawnFailed") (EVar "Pipe")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 2)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "SpawnFailed") (EVar "Fork")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 3)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "SpawnFailed") (EVar "Chdir")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 4)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "SpawnFailed") (EVar "ExecImage")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 5)) (PVar "e") (PVar "msg"))) (EApp (EApp (EVar "WaitFailed") (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 6)) (PVar "e") (PVar "msg"))) (EApp (EApp (EVar "CloseFailed") (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 7)) PWild (PVar "msg"))) (EApp (EVar "Unsupported") (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 8)) PWild PWild)) (EVar "ProcessClosed"))
(DFunDef false "rawError" ((PTuple (PLit (LInt 9)) PWild PWild)) (EVar "StillRunning"))
(DFunDef false "rawError" ((PTuple (PLit (LInt 10)) PWild (PVar "msg"))) (EApp (EVar "Unsupported") (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 11)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "SpawnFailed") (EVar "LaunchHandshake")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 12)) PWild PWild)) (EVar "LaunchCancelled"))
(DFunDef false "rawError" (PWild) (EApp (EVar "panic") (ELit (LString "process: invalid error code"))))
(DTypeSig false "startResult" (TyFun (TyApp (TyApp (TyCon "Result") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "LaunchTicket") (TyVar "p"))))) (TyApp (TyCon "Process") (TyVar "p"))) (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "StartError") (TyApp (TyCon "LaunchTicket") (TyVar "p")))) (TyApp (TyCon "Process") (TyVar "p")))))
(DFunDef false "startResult" ((PCon "Ok" (PVar "p"))) (EApp (EVar "Ok") (EVar "p")))
(DFunDef false "startResult" ((PCon "Err" (PTuple (PVar "op") (PVar "err") (PVar "msg") (PCon "None")))) (EApp (EVar "Err") (EApp (EVar "StartRejected") (EApp (EVar "rawError") (ETuple (EVar "op") (EVar "err") (EVar "msg"))))))
(DFunDef false "startResult" ((PCon "Err" (PTuple (PVar "op") (PVar "err") (PVar "msg") (PCon "Some" (PVar "ticket"))))) (EApp (EVar "Err") (EApp (EApp (EVar "StartCleanupPending") (EApp (EVar "rawError") (ETuple (EVar "op") (EVar "err") (EVar "msg")))) (EVar "ticket"))))
(DTypeSig false "progressResult" (TyFun (TyApp (TyApp (TyCon "Result") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyTuple (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "Process") (TyVar "p"))) (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))) (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "LaunchProgress") (TyApp (TyCon "Process") (TyVar "p"))))))
(DFunDef false "progressResult" ((PCon "Err" (PVar "e"))) (EApp (EVar "Err") (EApp (EVar "rawError") (EVar "e"))))
(DFunDef false "progressResult" ((PCon "Ok" (PTuple (PLit (LInt 0)) (PCon "None") (PCon "None")))) (EApp (EVar "Ok") (EVar "LaunchPending")))
(DFunDef false "progressResult" ((PCon "Ok" (PTuple (PLit (LInt 1)) (PCon "Some" (PVar "p")) (PCon "None")))) (EApp (EVar "Ok") (EApp (EVar "LaunchStarted") (EVar "p"))))
(DFunDef false "progressResult" ((PCon "Ok" (PTuple (PLit (LInt 2)) (PCon "None") (PCon "Some" (PVar "e"))))) (EApp (EVar "Ok") (EApp (EVar "LaunchFailed") (EApp (EVar "rawError") (EVar "e")))))
(DFunDef false "progressResult" ((PCon "Ok" (PTuple (PLit (LInt 3)) (PCon "None") (PCon "None")))) (EApp (EVar "Ok") (EVar "LaunchAborted")))
(DFunDef false "progressResult" (PWild) (EApp (EVar "panic") (ELit (LString "process: invalid launch progress ABI"))))
(DTypeSig true "start" (TyFun (TyNamed "program" (TyCon "String")) (TyFun (TyCon "SpawnOptions") (TyEffect ((atom "Exec" (name "program"))) None (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "StartError") (TyApp (TyCon "LaunchTicket") (TyVar "program")))) (TyApp (TyCon "Process") (TyVar "program")))))))
(DFunDef false "start" ((PVar "program") (PVar "opts")) (EApp (EVar "startResult") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "processStartRaw") (EVar "program")) (EFieldAccess (EVar "opts") "argv")) (EFieldAccess (EVar "opts") "cwd")) (EFieldAccess (EVar "opts") "env")) (EApp (EVar "choice") (EFieldAccess (EVar "opts") "stdin"))) (EApp (EVar "choice") (EFieldAccess (EVar "opts") "stdout"))) (EApp (EVar "choice") (EFieldAccess (EVar "opts") "stderr")))))
(DTypeSig true "retryStart" (TyFun (TyApp (TyCon "LaunchTicket") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "StartError") (TyApp (TyCon "LaunchTicket") (TyVar "p")))) (TyApp (TyCon "Process") (TyVar "p"))))))
(DFunDef false "retryStart" ((PVar "ticket")) (EApp (EVar "startResult") (EApp (EVar "processRetryStartRaw") (EVar "ticket"))))
(DTypeSig true "checkStart" (TyFun (TyApp (TyCon "LaunchTicket") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "LaunchProgress") (TyApp (TyCon "Process") (TyVar "p")))))))
(DFunDef false "checkStart" ((PVar "ticket")) (EApp (EVar "progressResult") (EApp (EVar "processCheckStartRaw") (EVar "ticket"))))
(DTypeSig true "abortStart" (TyFun (TyApp (TyCon "LaunchTicket") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "LaunchProgress") (TyApp (TyCon "Process") (TyVar "p")))))))
(DFunDef false "abortStart" ((PVar "ticket")) (EApp (EVar "progressResult") (EApp (EVar "processAbortStartRaw") (EVar "ticket"))))
(DTypeSig false "exitStatus" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Bool")) (TyCon "ExitStatus")))
(DFunDef false "exitStatus" ((PTuple (PLit (LInt 0)) (PVar "code") PWild)) (EApp (EVar "Exited") (EVar "code")))
(DFunDef false "exitStatus" ((PTuple (PLit (LInt 1)) (PVar "sig") (PVar "core"))) (EApp (EApp (EVar "Signalled") (EVar "sig")) (EVar "core")))
(DFunDef false "exitStatus" (PWild) (EApp (EVar "panic") (ELit (LString "process: invalid exit status ABI"))))
(DTypeSig true "pollExit" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "Option") (TyCon "ExitStatus"))))))
(DFunDef false "pollExit" ((PVar "p")) (EMatch (EApp (EVar "processPollExitRaw") (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "rawError") (EVar "e")))) (arm (PCon "Ok" (PVar "status")) () (EApp (EVar "Ok") (EApp (EApp (EMethodRef "map") (EVar "exitStatus")) (EVar "status"))))))
(DTypeSig true "closeStdin" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyCon "Unit")))))
(DFunDef false "closeStdin" ((PVar "p")) (EApp (EApp (EVar "mapErr") (EVar "rawError")) (EApp (EVar "processCloseStdinRaw") (EVar "p"))))
(DTypeSig true "dispose" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyCon "Unit")))))
(DFunDef false "dispose" ((PVar "p")) (EApp (EApp (EVar "mapErr") (EVar "rawError")) (EApp (EVar "processDisposeRaw") (EVar "p"))))
(DUse false (UseGroup ("test") ((mem "expectTrue" false) (mem "fail" false))))
(DTypeSig false "waitForTest" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Int") (TyEffect ((atom "Exec" (name "p"))) None (TyCon "Bool")))))
(DFunDef false "waitForTest" (PWild (PLit (LInt 0))) (EVar "False"))
(DFunDef false "waitForTest" ((PVar "p") (PVar "n")) (EMatch (EApp (EVar "pollExit") (EVar "p")) (arm (PCon "Ok" (PCon "Some" (PCon "Exited" (PLit (LInt 42))))) () (EVar "True")) (arm (PCon "Ok" (PCon "None")) () (EApp (EApp (EVar "waitForTest") (EVar "p")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (arm PWild () (EVar "False"))))
(DTest false "native process retains an owner until stdin closes and exit is reaped" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "read line; exit 42")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Null")) (fa "stderr" (EVar "Null"))))) (DoExpr (EMatch (EApp (EApp (EVar "start") (ELit (LString "/bin/sh"))) (EVar "opts")) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "process start failed")))) (arm (PCon "Ok" (PVar "p")) () (EBlock (DoLet false false (PVar "held") (EApp (EVar "Ref") (EVar "p"))) (DoLet false false (PVar "get") (ELam (PWild) (EUnOp "!" (EVar "held")))) (DoLet false false (PVar "owners") (EListLit (EApp (EVar "get") (ELit LUnit)))) (DoLet false false PWild (EApp (EApp (EVar "arrayMake") (ELit (LInt 100000))) (ELit (LInt 123)))) (DoExpr (EMatch (EVar "owners") (arm (PList (PVar "owner")) () (EMatch (EApp (EVar "pollExit") (EVar "owner")) (arm (PCon "Ok" (PCon "None")) () (EMatch (EApp (EVar "closeStdin") (EApp (EVar "get") (ELit LUnit))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "exited") (EApp (EApp (EVar "waitForTest") (EVar "owner")) (ELit (LInt 1000000)))) (DoExpr (EMatch (EApp (EVar "dispose") (EVar "p")) (arm (PCon "Ok" PWild) () (EApp (EVar "expectTrue") (EVar "exited"))) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "dispose failed")))))))) (arm (PCon "Err" PWild) () (EApp (EVar "fail") (ELit (LString "close stdin failed")))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "child was not live")))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "owner container lost"))))))))))))
(DTest false "launch progress decodes pending, failed, and aborted shapes" (EBlock (DoLet false false (PVar "pending") (EApp (EVar "progressResult") (EApp (EVar "Ok") (ETuple (ELit (LInt 0)) (EVar "None") (EVar "None"))))) (DoLet false false (PVar "failed") (EApp (EVar "progressResult") (EApp (EVar "Ok") (ETuple (ELit (LInt 2)) (EVar "None") (EApp (EVar "Some") (ETuple (ELit (LInt 12)) (ELit (LInt 0)) (ELit (LString "cancelled")))))))) (DoLet false false (PVar "aborted") (EApp (EVar "progressResult") (EApp (EVar "Ok") (ETuple (ELit (LInt 3)) (EVar "None") (EVar "None"))))) (DoExpr (EApp (EVar "expectTrue") (EMatch (ETuple (EVar "pending") (EVar "failed") (EVar "aborted")) (arm (PTuple (PCon "Ok" (PCon "LaunchPending")) (PCon "Ok" (PCon "LaunchFailed" (PCon "LaunchCancelled"))) (PCon "Ok" (PCon "LaunchAborted"))) () (EVar "True")) (arm PWild () (EVar "False")))))))
