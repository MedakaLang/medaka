# META
source_lines=211
stages=DESUGAR,MARK
# SOURCE
import bytes.{Bytes, adoptByteBlockUnsafe, lendByteBlockUnsafe}

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
  | Read
  | Write
  | StreamLookup
public export data ProcessError =
  | InvalidSpawn String
  | SpawnFailed ProcessOperation Int String
  | ProcessClosed
  | StillRunning
  | WaitFailed Int String
  | CloseFailed Int String
  | Unsupported String
  | LaunchCancelled
  | InvalidIO String
  | StreamFailed ProcessOperation Int String
  | SubmissionQueueFull
  | ProcessBusy
public export data OutputStream = ChildStdout | ChildStderr
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
rawError (13, _, msg) = InvalidIO msg
rawError (14, e, msg) = StreamFailed Read e msg
rawError (15, e, msg) = StreamFailed Write e msg
rawError (16, _, _) = SubmissionQueueFull
rawError (17, _, _) = ProcessBusy
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

{- | Submit a bounded native launch without waiting for creation or exec.
     The ticket retains cleanup ownership until checkStart transfers a Process or
     abortStart positively observes terminal cleanup. Queue permits remain held
     during creation and failed cleanup; callers must keep draining pending tickets. -}
export
submit : (program : String) ->
  SpawnOptions ->
  <Exec program> Result ProcessError (LaunchTicket program)
submit program opts =
  mapErr
    rawError
    (processSubmitRaw
      program
      opts.argv
      opts.cwd
      opts.env
      (choice opts.stdin)
      (choice opts.stdout)
      (choice opts.stderr))

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

{- | The native stream selector for an output stream. -}
export
outputStreamCode : OutputStream -> Int
outputStreamCode ChildStdout = 1
outputStreamCode ChildStderr = 2

export
tryRead : Process p ->
  OutputStream ->
  Int ->
  <Exec p> Result ProcessError (Option Bytes)
tryRead p stream limit =
  match processTryReadRaw p (outputStreamCode stream) limit
    Err e => Err (rawError e)
    Ok block => Ok (map adoptByteBlockUnsafe block)

export
tryWrite : Process p ->
  Bytes ->
  Int ->
  Int ->
  <Exec p> Result ProcessError (Option Int)
tryWrite p bytes offset count =
  mapErr
    rawError
    (processTryWriteRaw p (lendByteBlockUnsafe bytes) offset count)

export
streamFd : Process p -> Int -> <Exec p> Result ProcessError Int
streamFd p stream = mapErr rawError (processStreamFdRaw p stream)

import test.{expectTrue}

test "launch progress decodes pending, failed, and aborted shapes" =
  let pending = progressResult (Ok (0, None, None))
  let failed = progressResult (Ok (2, None, Some (12, 0, "cancelled")))
  let aborted = progressResult (Ok (3, None, None))
  expectTrue (match (pending, failed, aborted)
    (Ok LaunchPending, Ok (LaunchFailed LaunchCancelled), Ok LaunchAborted) =>
      True
    _ => False)

test "stream errors preserve operation and busy state" = expectTrue (match (
  rawError (13, 0, "bad"),
  rawError (14, 5, "read"),
  rawError (15, 32, "write"),
  rawError (17, 0, "busy"),
)
  (InvalidIO "bad", StreamFailed Read 5 "read", StreamFailed Write 32 "write", ProcessBusy) =>
    True
  _ => False)
# DESUGAR
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "adoptByteBlockUnsafe" false) (mem "lendByteBlockUnsafe" false))))
(DData Public "PipeChoice" () ((variant "Piped" (ConPos)) (variant "Null" (ConPos))) ())
(DData Public "SpawnOptions" () ((variant "SpawnOptions" (ConNamed (field "argv" (TyApp (TyCon "List") (TyCon "String"))) (field "cwd" (TyCon "String")) (field "env" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "stdin" (TyCon "PipeChoice")) (field "stdout" (TyCon "PipeChoice")) (field "stderr" (TyCon "PipeChoice"))))) ())
(DData Public "ProcessOperation" () ((variant "Validate" (ConPos)) (variant "Pipe" (ConPos)) (variant "Fork" (ConPos)) (variant "Chdir" (ConPos)) (variant "ExecImage" (ConPos)) (variant "Wait" (ConPos)) (variant "Close" (ConPos)) (variant "LaunchHandshake" (ConPos)) (variant "Read" (ConPos)) (variant "Write" (ConPos)) (variant "StreamLookup" (ConPos))) ())
(DData Public "ProcessError" () ((variant "InvalidSpawn" (ConPos (TyCon "String"))) (variant "SpawnFailed" (ConPos (TyCon "ProcessOperation") (TyCon "Int") (TyCon "String"))) (variant "ProcessClosed" (ConPos)) (variant "StillRunning" (ConPos)) (variant "WaitFailed" (ConPos (TyCon "Int") (TyCon "String"))) (variant "CloseFailed" (ConPos (TyCon "Int") (TyCon "String"))) (variant "Unsupported" (ConPos (TyCon "String"))) (variant "LaunchCancelled" (ConPos)) (variant "InvalidIO" (ConPos (TyCon "String"))) (variant "StreamFailed" (ConPos (TyCon "ProcessOperation") (TyCon "Int") (TyCon "String"))) (variant "SubmissionQueueFull" (ConPos)) (variant "ProcessBusy" (ConPos))) ())
(DData Public "OutputStream" () ((variant "ChildStdout" (ConPos)) (variant "ChildStderr" (ConPos))) ())
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
(DFunDef false "rawError" ((PTuple (PLit (LInt 13)) PWild (PVar "msg"))) (EApp (EVar "InvalidIO") (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 14)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "StreamFailed") (EVar "Read")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 15)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "StreamFailed") (EVar "Write")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 16)) PWild PWild)) (EVar "SubmissionQueueFull"))
(DFunDef false "rawError" ((PTuple (PLit (LInt 17)) PWild PWild)) (EVar "ProcessBusy"))
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
(DTypeSig true "submit" (TyFun (TyNamed "program" (TyCon "String")) (TyFun (TyCon "SpawnOptions") (TyEffect ((atom "Exec" (name "program"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "LaunchTicket") (TyVar "program")))))))
(DFunDef false "submit" ((PVar "program") (PVar "opts")) (EApp (EApp (EVar "mapErr") (EVar "rawError")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "processSubmitRaw") (EVar "program")) (EFieldAccess (EVar "opts") "argv")) (EFieldAccess (EVar "opts") "cwd")) (EFieldAccess (EVar "opts") "env")) (EApp (EVar "choice") (EFieldAccess (EVar "opts") "stdin"))) (EApp (EVar "choice") (EFieldAccess (EVar "opts") "stdout"))) (EApp (EVar "choice") (EFieldAccess (EVar "opts") "stderr")))))
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
(DTypeSig true "outputStreamCode" (TyFun (TyCon "OutputStream") (TyCon "Int")))
(DFunDef false "outputStreamCode" ((PCon "ChildStdout")) (ELit (LInt 1)))
(DFunDef false "outputStreamCode" ((PCon "ChildStderr")) (ELit (LInt 2)))
(DTypeSig true "tryRead" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "OutputStream") (TyFun (TyCon "Int") (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "Option") (TyCon "Bytes"))))))))
(DFunDef false "tryRead" ((PVar "p") (PVar "stream") (PVar "limit")) (EMatch (EApp (EApp (EApp (EVar "processTryReadRaw") (EVar "p")) (EApp (EVar "outputStreamCode") (EVar "stream"))) (EVar "limit")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "rawError") (EVar "e")))) (arm (PCon "Ok" (PVar "block")) () (EApp (EVar "Ok") (EApp (EApp (EVar "map") (EVar "adoptByteBlockUnsafe")) (EVar "block"))))))
(DTypeSig true "tryWrite" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "tryWrite" ((PVar "p") (PVar "bytes") (PVar "offset") (PVar "count")) (EApp (EApp (EVar "mapErr") (EVar "rawError")) (EApp (EApp (EApp (EApp (EVar "processTryWriteRaw") (EVar "p")) (EApp (EVar "lendByteBlockUnsafe") (EVar "bytes"))) (EVar "offset")) (EVar "count"))))
(DTypeSig true "streamFd" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Int") (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyCon "Int"))))))
(DFunDef false "streamFd" ((PVar "p") (PVar "stream")) (EApp (EApp (EVar "mapErr") (EVar "rawError")) (EApp (EApp (EVar "processStreamFdRaw") (EVar "p")) (EVar "stream"))))
(DUse false (UseGroup ("test") ((mem "expectTrue" false))))
(DTest false "launch progress decodes pending, failed, and aborted shapes" (EBlock (DoLet false false (PVar "pending") (EApp (EVar "progressResult") (EApp (EVar "Ok") (ETuple (ELit (LInt 0)) (EVar "None") (EVar "None"))))) (DoLet false false (PVar "failed") (EApp (EVar "progressResult") (EApp (EVar "Ok") (ETuple (ELit (LInt 2)) (EVar "None") (EApp (EVar "Some") (ETuple (ELit (LInt 12)) (ELit (LInt 0)) (ELit (LString "cancelled")))))))) (DoLet false false (PVar "aborted") (EApp (EVar "progressResult") (EApp (EVar "Ok") (ETuple (ELit (LInt 3)) (EVar "None") (EVar "None"))))) (DoExpr (EApp (EVar "expectTrue") (EMatch (ETuple (EVar "pending") (EVar "failed") (EVar "aborted")) (arm (PTuple (PCon "Ok" (PCon "LaunchPending")) (PCon "Ok" (PCon "LaunchFailed" (PCon "LaunchCancelled"))) (PCon "Ok" (PCon "LaunchAborted"))) () (EVar "True")) (arm PWild () (EVar "False")))))))
(DTest false "stream errors preserve operation and busy state" (EApp (EVar "expectTrue") (EMatch (ETuple (EApp (EVar "rawError") (ETuple (ELit (LInt 13)) (ELit (LInt 0)) (ELit (LString "bad")))) (EApp (EVar "rawError") (ETuple (ELit (LInt 14)) (ELit (LInt 5)) (ELit (LString "read")))) (EApp (EVar "rawError") (ETuple (ELit (LInt 15)) (ELit (LInt 32)) (ELit (LString "write")))) (EApp (EVar "rawError") (ETuple (ELit (LInt 17)) (ELit (LInt 0)) (ELit (LString "busy"))))) (arm (PTuple (PCon "InvalidIO" (PLit (LString "bad"))) (PCon "StreamFailed" (PCon "Read") (PLit (LInt 5)) (PLit (LString "read"))) (PCon "StreamFailed" (PCon "Write") (PLit (LInt 32)) (PLit (LString "write"))) (PCon "ProcessBusy")) () (EVar "True")) (arm PWild () (EVar "False")))))
# MARK
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "adoptByteBlockUnsafe" false) (mem "lendByteBlockUnsafe" false))))
(DData Public "PipeChoice" () ((variant "Piped" (ConPos)) (variant "Null" (ConPos))) ())
(DData Public "SpawnOptions" () ((variant "SpawnOptions" (ConNamed (field "argv" (TyApp (TyCon "List") (TyCon "String"))) (field "cwd" (TyCon "String")) (field "env" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "stdin" (TyCon "PipeChoice")) (field "stdout" (TyCon "PipeChoice")) (field "stderr" (TyCon "PipeChoice"))))) ())
(DData Public "ProcessOperation" () ((variant "Validate" (ConPos)) (variant "Pipe" (ConPos)) (variant "Fork" (ConPos)) (variant "Chdir" (ConPos)) (variant "ExecImage" (ConPos)) (variant "Wait" (ConPos)) (variant "Close" (ConPos)) (variant "LaunchHandshake" (ConPos)) (variant "Read" (ConPos)) (variant "Write" (ConPos)) (variant "StreamLookup" (ConPos))) ())
(DData Public "ProcessError" () ((variant "InvalidSpawn" (ConPos (TyCon "String"))) (variant "SpawnFailed" (ConPos (TyCon "ProcessOperation") (TyCon "Int") (TyCon "String"))) (variant "ProcessClosed" (ConPos)) (variant "StillRunning" (ConPos)) (variant "WaitFailed" (ConPos (TyCon "Int") (TyCon "String"))) (variant "CloseFailed" (ConPos (TyCon "Int") (TyCon "String"))) (variant "Unsupported" (ConPos (TyCon "String"))) (variant "LaunchCancelled" (ConPos)) (variant "InvalidIO" (ConPos (TyCon "String"))) (variant "StreamFailed" (ConPos (TyCon "ProcessOperation") (TyCon "Int") (TyCon "String"))) (variant "SubmissionQueueFull" (ConPos)) (variant "ProcessBusy" (ConPos))) ())
(DData Public "OutputStream" () ((variant "ChildStdout" (ConPos)) (variant "ChildStderr" (ConPos))) ())
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
(DFunDef false "rawError" ((PTuple (PLit (LInt 13)) PWild (PVar "msg"))) (EApp (EVar "InvalidIO") (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 14)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "StreamFailed") (EVar "Read")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 15)) (PVar "e") (PVar "msg"))) (EApp (EApp (EApp (EVar "StreamFailed") (EVar "Write")) (EVar "e")) (EVar "msg")))
(DFunDef false "rawError" ((PTuple (PLit (LInt 16)) PWild PWild)) (EVar "SubmissionQueueFull"))
(DFunDef false "rawError" ((PTuple (PLit (LInt 17)) PWild PWild)) (EVar "ProcessBusy"))
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
(DTypeSig true "submit" (TyFun (TyNamed "program" (TyCon "String")) (TyFun (TyCon "SpawnOptions") (TyEffect ((atom "Exec" (name "program"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "LaunchTicket") (TyVar "program")))))))
(DFunDef false "submit" ((PVar "program") (PVar "opts")) (EApp (EApp (EVar "mapErr") (EVar "rawError")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "processSubmitRaw") (EVar "program")) (EFieldAccess (EVar "opts") "argv")) (EFieldAccess (EVar "opts") "cwd")) (EFieldAccess (EVar "opts") "env")) (EApp (EVar "choice") (EFieldAccess (EVar "opts") "stdin"))) (EApp (EVar "choice") (EFieldAccess (EVar "opts") "stdout"))) (EApp (EVar "choice") (EFieldAccess (EVar "opts") "stderr")))))
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
(DTypeSig true "outputStreamCode" (TyFun (TyCon "OutputStream") (TyCon "Int")))
(DFunDef false "outputStreamCode" ((PCon "ChildStdout")) (ELit (LInt 1)))
(DFunDef false "outputStreamCode" ((PCon "ChildStderr")) (ELit (LInt 2)))
(DTypeSig true "tryRead" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "OutputStream") (TyFun (TyCon "Int") (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "Option") (TyCon "Bytes"))))))))
(DFunDef false "tryRead" ((PVar "p") (PVar "stream") (PVar "limit")) (EMatch (EApp (EApp (EApp (EVar "processTryReadRaw") (EVar "p")) (EApp (EVar "outputStreamCode") (EVar "stream"))) (EVar "limit")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "rawError") (EVar "e")))) (arm (PCon "Ok" (PVar "block")) () (EApp (EVar "Ok") (EApp (EApp (EMethodRef "map") (EVar "adoptByteBlockUnsafe")) (EVar "block"))))))
(DTypeSig true "tryWrite" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "tryWrite" ((PVar "p") (PVar "bytes") (PVar "offset") (PVar "count")) (EApp (EApp (EVar "mapErr") (EVar "rawError")) (EApp (EApp (EApp (EApp (EVar "processTryWriteRaw") (EVar "p")) (EApp (EVar "lendByteBlockUnsafe") (EVar "bytes"))) (EVar "offset")) (EDictApp "count"))))
(DTypeSig true "streamFd" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Int") (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyCon "Int"))))))
(DFunDef false "streamFd" ((PVar "p") (PVar "stream")) (EApp (EApp (EVar "mapErr") (EVar "rawError")) (EApp (EApp (EVar "processStreamFdRaw") (EVar "p")) (EVar "stream"))))
(DUse false (UseGroup ("test") ((mem "expectTrue" false))))
(DTest false "launch progress decodes pending, failed, and aborted shapes" (EBlock (DoLet false false (PVar "pending") (EApp (EVar "progressResult") (EApp (EVar "Ok") (ETuple (ELit (LInt 0)) (EVar "None") (EVar "None"))))) (DoLet false false (PVar "failed") (EApp (EVar "progressResult") (EApp (EVar "Ok") (ETuple (ELit (LInt 2)) (EVar "None") (EApp (EVar "Some") (ETuple (ELit (LInt 12)) (ELit (LInt 0)) (ELit (LString "cancelled")))))))) (DoLet false false (PVar "aborted") (EApp (EVar "progressResult") (EApp (EVar "Ok") (ETuple (ELit (LInt 3)) (EVar "None") (EVar "None"))))) (DoExpr (EApp (EVar "expectTrue") (EMatch (ETuple (EVar "pending") (EVar "failed") (EVar "aborted")) (arm (PTuple (PCon "Ok" (PCon "LaunchPending")) (PCon "Ok" (PCon "LaunchFailed" (PCon "LaunchCancelled"))) (PCon "Ok" (PCon "LaunchAborted"))) () (EVar "True")) (arm PWild () (EVar "False")))))))
(DTest false "stream errors preserve operation and busy state" (EApp (EVar "expectTrue") (EMatch (ETuple (EApp (EVar "rawError") (ETuple (ELit (LInt 13)) (ELit (LInt 0)) (ELit (LString "bad")))) (EApp (EVar "rawError") (ETuple (ELit (LInt 14)) (ELit (LInt 5)) (ELit (LString "read")))) (EApp (EVar "rawError") (ETuple (ELit (LInt 15)) (ELit (LInt 32)) (ELit (LString "write")))) (EApp (EVar "rawError") (ETuple (ELit (LInt 17)) (ELit (LInt 0)) (ELit (LString "busy"))))) (arm (PTuple (PCon "InvalidIO" (PLit (LString "bad"))) (PCon "StreamFailed" (PCon "Read") (PLit (LInt 5)) (PLit (LString "read"))) (PCon "StreamFailed" (PCon "Write") (PLit (LInt 32)) (PLit (LString "write"))) (PCon "ProcessBusy")) () (EVar "True")) (arm PWild () (EVar "False")))))
