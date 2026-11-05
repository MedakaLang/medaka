# META
source_lines=237
stages=DESUGAR,MARK
# SOURCE
import async.{
  Async, Wait, liftIO, awaitAny, deadlineAfter, expiredNow, waitFlag, waitRead,
  waitWrite
}
import bytes.{Bytes}
import bytes as B
import process.{
  ProcessError(..), OutputStream, outputStreamCode, ExitStatus, tryRead,
  tryWrite, streamFd, pollExit, SpawnOptions, StartError(..),
  LaunchProgress(..), submit, checkStart, abortStart
}
import time.{Duration, millis}

{- | An absolute monotonic deadline, created by `after`. -}
export data Deadline (e : Effect) = Deadline (Wait e)
{- | A cooperative cancellation token shared by operations. -}
export data CancelToken = CancelToken (Ref Bool)
{- | Read bytes, end of stream, or the reason the operation stopped. -}
public export data ReadResult =
  | Read Bytes
  | EndOfStream
  | ReadTimedOut
  | ReadCancelled
{- | The committed byte count on completion, timeout, or cancellation. -}
public export data WriteResult =
  | Written Int
  | WriteTimedOut Int
  | WriteCancelled Int
{- | Direct-child exit status or the reason observation stopped. -}
public export data WaitResult =
  | ChildExited ExitStatus
  | WaitTimedOut
  | WaitCancelled

{- | Creates an uncancelled token. -}
export
newCancelToken : Unit -> CancelToken
newCancelToken _ = CancelToken (Ref False)

{- | Cancels the token and wakes tasks waiting on it. -}
export
cancel : CancelToken -> Unit
cancel (CancelToken flag) = flag := True

{- | Reports whether the token has been cancelled. -}
export
cancelled : CancelToken -> Bool
cancelled (CancelToken flag) = !flag

{- | A wait satisfied when the token is cancelled. -}
export
cancelWait : CancelToken -> Wait e
cancelWait (CancelToken flag) = waitFlag flag

{- | Creates a deadline relative to when this deferred computation runs. -}
export
after : Duration -> Async <Clock | e> (Deadline <Clock | e>)
after duration = deferMap Deadline (deadlineAfter duration)

{- | The wait for this deadline; it does not reset on reuse. -}
export
deadlineWait : Deadline e -> Wait e
deadlineWait (Deadline wait) = wait

stop : Deadline e -> CancelToken -> <e> Option Bool
stop deadline token =
  if cancelled token then
    Some True
  else if expiredNow (deadlineWait deadline) then
    Some False
  else
    None

park : Deadline <Clock | e> ->
  CancelToken ->
  List (Wait <Clock | e>) ->
  Async <Clock | e> Unit
park deadline token extra = deferThen (deadlineAfter (millis 10)) (tick =>
  awaitAny (deadlineWait deadline :: cancelWait token :: tick :: extra))

{- | Reads a bounded chunk, stopping on cancellation or deadline. -}
export
readUntil : Process p ->
  OutputStream ->
  Int ->
  Deadline <Clock, Exec p | e> ->
  CancelToken ->
  Async <Clock, Exec p | e> (Result ProcessError ReadResult)
readUntil p stream limit deadline token =
  deferThen
    (liftIO (_ => match stop deadline token
      Some True => deferPure (Ok ReadCancelled)
      Some False => deferPure (Ok ReadTimedOut)
      None => match tryRead p stream limit
        Ok (Some bytes) =>
          deferPure
            (Ok (if B.length bytes == 0 then EndOfStream else Read bytes))
        Ok None => readPark p stream limit deadline token
        Err ProcessBusy => readPark p stream limit deadline token
        Err err => deferPure (Err err)))
    identity

readPark : Process p ->
  OutputStream ->
  Int ->
  Deadline <Clock, Exec p | e> ->
  CancelToken ->
  <Exec p> Async <Clock, Exec p | e> (Result ProcessError ReadResult)
readPark p stream limit deadline token =
  match streamFd p (outputStreamCode stream)
    Ok fd => deferThen (park deadline token [waitRead fd]) (_ =>
      readUntil p stream limit deadline token)
    Err ProcessBusy => deferThen (park deadline token []) (_ =>
      readUntil p stream limit deadline token)
    Err err => deferPure (Err err)

{- | Writes bytes until completion or stop; errors retain the committed count. -}
export
writeUntil : Process p ->
  Bytes ->
  Deadline <Clock, Exec p | e> ->
  CancelToken ->
  Async <Clock, Exec p | e> (Result (ProcessError, Int) WriteResult)
writeUntil p bytes deadline token = writeFrom p bytes 0 deadline token

writeFrom : Process p ->
  Bytes ->
  Int ->
  Deadline <Clock, Exec p | e> ->
  CancelToken ->
  Async <Clock, Exec p | e> (Result (ProcessError, Int) WriteResult)
writeFrom p bytes offset deadline token =
  deferThen
    (liftIO (_ => match stop deadline token
      Some True => deferPure (Ok (WriteCancelled offset))
      Some False => deferPure (Ok (WriteTimedOut offset))
      None =>
        if offset == B.length bytes then
          deferPure (Ok (Written offset))
        else match tryWrite p bytes offset (B.length bytes - offset)
          Ok (Some n) => writeFrom p bytes (offset + n) deadline token
          Ok None => writePark p bytes offset deadline token
          Err ProcessBusy => writePark p bytes offset deadline token
          Err err => deferPure (Err (err, offset))))
    identity

writePark : Process p ->
  Bytes ->
  Int ->
  Deadline <Clock, Exec p | e> ->
  CancelToken ->
  <Exec p> Async <Clock, Exec p | e> (Result (ProcessError, Int) WriteResult)
writePark p bytes offset deadline token = match streamFd p 0
  Ok fd => deferThen (park deadline token [waitWrite fd]) (_ =>
    writeFrom p bytes offset deadline token)
  Err ProcessBusy => deferThen (park deadline token []) (_ =>
    writeFrom p bytes offset deadline token)
  Err err => deferPure (Err (err, offset))

{- | Observes direct-child exit until cancellation or deadline. -}
export
waitUntil : Process p ->
  Deadline <Clock, Exec p | e> ->
  CancelToken ->
  Async <Clock, Exec p | e> (Result ProcessError WaitResult)
waitUntil p deadline token =
  deferThen
    (liftIO (_ => match stop deadline token
      Some True => deferPure (Ok WaitCancelled)
      Some False => deferPure (Ok WaitTimedOut)
      None => match pollExit p
        Ok (Some status) => deferPure (Ok (ChildExited status))
        Ok None =>
          deferThen (park deadline token []) (_ => waitUntil p deadline token)
        Err ProcessBusy =>
          deferThen (park deadline token []) (_ => waitUntil p deadline token)
        Err err => deferPure (Err err)))
    identity

{- | Cleanup outcome; a pending ticket must be retained and drained. -}
public export data LaunchStop ticket =
  | LaunchStopped
  | LaunchCleanupPending ticket (Option ProcessError)
  | LaunchCleanupFailed ProcessError
{- | Launch transfer or a stop with its cleanup outcome. -}
public export data StartResult process ticket =
  | Started process
  | StartTimedOut (LaunchStop ticket)
  | StartCancelled (LaunchStop ticket)

{- | Submits launch cooperatively and retains cleanup ownership on stop. -}
export
startUntil : (program : String) ->
  SpawnOptions ->
  Deadline <Clock, Exec program | e> ->
  CancelToken ->
  Async <Clock, Exec program | e> (Result (StartError (LaunchTicket program)) (StartResult (Process program) (LaunchTicket program)))
startUntil program opts deadline token =
  deferThen
    (liftIO (_ => match stop deadline token
      Some True => deferPure (Ok (StartCancelled LaunchStopped))
      Some False => deferPure (Ok (StartTimedOut LaunchStopped))
      None => match submit program opts
        Ok ticket => startPoll ticket deadline token
        Err ProcessBusy => deferThen (park deadline token []) (_ =>
          startUntil program opts deadline token)
        Err err => deferPure (Err (StartRejected err))))
    identity

startPoll : LaunchTicket p ->
  Deadline <Clock, Exec p | e> ->
  CancelToken ->
  Async <Clock, Exec p | e> (Result (StartError (LaunchTicket p)) (StartResult (Process p) (LaunchTicket p)))
startPoll ticket deadline token =
  deferThen
    (liftIO (_ => match stop deadline token
      Some True => deferPure (Ok (StartCancelled (stopLaunch ticket)))
      Some False => deferPure (Ok (StartTimedOut (stopLaunch ticket)))
      None => match checkStart ticket
        Ok (LaunchStarted p) => deferPure (Ok (Started p))
        Ok LaunchPending => deferThen (park deadline token []) (_ =>
          startPoll ticket deadline token)
        Ok (LaunchFailed err) => deferPure (Err (StartRejected err))
        Ok LaunchAborted => deferPure (Err (StartRejected LaunchCancelled))
        Err ProcessBusy => deferThen (park deadline token []) (_ =>
          startPoll ticket deadline token)
        Err err => deferPure (Err (StartCleanupPending err ticket))))
    identity

stopLaunch : LaunchTicket p -> <Exec p> LaunchStop (LaunchTicket p)
stopLaunch ticket = match abortStart ticket
  Ok LaunchAborted => LaunchStopped
  Ok (LaunchFailed err) => LaunchCleanupFailed err
  Ok LaunchPending => LaunchCleanupPending ticket None
  Ok (LaunchStarted _) => LaunchCleanupPending ticket None
  Err ProcessBusy => LaunchCleanupPending ticket None
  Err err => LaunchCleanupPending ticket (Some err)
# DESUGAR
(DUse false (UseGroup ("async") ((mem "Async" false) (mem "Wait" false) (mem "liftIO" false) (mem "awaitAny" false) (mem "deadlineAfter" false) (mem "expiredNow" false) (mem "waitFlag" false) (mem "waitRead" false) (mem "waitWrite" false))))
(DUse false (UseGroup ("bytes") ((mem "Bytes" false))))
(DUse false (UseAlias ("bytes") "B"))
(DUse false (UseGroup ("process") ((mem "ProcessError" true) (mem "OutputStream" false) (mem "outputStreamCode" false) (mem "ExitStatus" false) (mem "tryRead" false) (mem "tryWrite" false) (mem "streamFd" false) (mem "pollExit" false) (mem "SpawnOptions" false) (mem "StartError" true) (mem "LaunchProgress" true) (mem "submit" false) (mem "checkStart" false) (mem "abortStart" false))))
(DUse false (UseGroup ("time") ((mem "Duration" false) (mem "millis" false))))
(DData Abstract "Deadline" ("e") ((variant "Deadline" (ConPos (TyApp (TyCon "Wait") (TyVar "e"))))) ())
(DData Abstract "CancelToken" () ((variant "CancelToken" (ConPos (TyApp (TyCon "Ref") (TyCon "Bool"))))) ())
(DData Public "ReadResult" () ((variant "Read" (ConPos (TyCon "Bytes"))) (variant "EndOfStream" (ConPos)) (variant "ReadTimedOut" (ConPos)) (variant "ReadCancelled" (ConPos))) ())
(DData Public "WriteResult" () ((variant "Written" (ConPos (TyCon "Int"))) (variant "WriteTimedOut" (ConPos (TyCon "Int"))) (variant "WriteCancelled" (ConPos (TyCon "Int")))) ())
(DData Public "WaitResult" () ((variant "ChildExited" (ConPos (TyCon "ExitStatus"))) (variant "WaitTimedOut" (ConPos)) (variant "WaitCancelled" (ConPos))) ())
(DTypeSig true "newCancelToken" (TyFun (TyCon "Unit") (TyCon "CancelToken")))
(DFunDef false "newCancelToken" (PWild) (EApp (EVar "CancelToken") (EApp (EVar "Ref") (EVar "False"))))
(DTypeSig true "cancel" (TyFun (TyCon "CancelToken") (TyCon "Unit")))
(DFunDef false "cancel" ((PCon "CancelToken" (PVar "flag"))) (EApp (EApp (EVar "setRef") (EVar "flag")) (EVar "True")))
(DTypeSig true "cancelled" (TyFun (TyCon "CancelToken") (TyCon "Bool")))
(DFunDef false "cancelled" ((PCon "CancelToken" (PVar "flag"))) (EUnOp "!" (EVar "flag")))
(DTypeSig true "cancelWait" (TyFun (TyCon "CancelToken") (TyApp (TyCon "Wait") (TyVar "e"))))
(DFunDef false "cancelWait" ((PCon "CancelToken" (PVar "flag"))) (EApp (EVar "waitFlag") (EVar "flag")))
(DTypeSig true "after" (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock") (Some "e"))) (TyApp (TyCon "Deadline") (TyRow ("Clock") (Some "e"))))))
(DFunDef false "after" ((PVar "duration")) (EApp (EApp (EVar "deferMap") (EVar "Deadline")) (EApp (EVar "deadlineAfter") (EVar "duration"))))
(DTypeSig true "deadlineWait" (TyFun (TyApp (TyCon "Deadline") (TyVar "e")) (TyApp (TyCon "Wait") (TyVar "e"))))
(DFunDef false "deadlineWait" ((PCon "Deadline" (PVar "wait"))) (EVar "wait"))
(DTypeSig false "stop" (TyFun (TyApp (TyCon "Deadline") (TyVar "e")) (TyFun (TyCon "CancelToken") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Bool"))))))
(DFunDef false "stop" ((PVar "deadline") (PVar "token")) (EIf (EApp (EVar "cancelled") (EVar "token")) (EApp (EVar "Some") (EVar "True")) (EIf (EApp (EVar "expiredNow") (EApp (EVar "deadlineWait") (EVar "deadline"))) (EApp (EVar "Some") (EVar "False")) (EVar "None"))))
(DTypeSig false "park" (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock") (Some "e"))) (TyFun (TyCon "CancelToken") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyRow ("Clock") (Some "e")))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock") (Some "e"))) (TyCon "Unit"))))))
(DFunDef false "park" ((PVar "deadline") (PVar "token") (PVar "extra")) (EApp (EApp (EVar "deferThen") (EApp (EVar "deadlineAfter") (EApp (EVar "millis") (ELit (LInt 10))))) (ELam ((PVar "tick")) (EApp (EVar "awaitAny") (EBinOp "::" (EApp (EVar "deadlineWait") (EVar "deadline")) (EBinOp "::" (EApp (EVar "cancelWait") (EVar "token")) (EBinOp "::" (EVar "tick") (EVar "extra"))))))))
(DTypeSig true "readUntil" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "OutputStream") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyCon "ReadResult")))))))))
(DFunDef false "readUntil" ((PVar "p") (PVar "stream") (PVar "limit") (PVar "deadline") (PVar "token")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam (PWild) (EMatch (EApp (EApp (EVar "stop") (EVar "deadline")) (EVar "token")) (arm (PCon "Some" (PCon "True")) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "ReadCancelled")))) (arm (PCon "Some" (PCon "False")) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "ReadTimedOut")))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "tryRead") (EVar "p")) (EVar "stream")) (EVar "limit")) (arm (PCon "Ok" (PCon "Some" (PVar "bytes"))) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EIf (EBinOp "==" (EApp (EVar "B.length") (EVar "bytes")) (ELit (LInt 0))) (EVar "EndOfStream") (EApp (EVar "Read") (EVar "bytes")))))) (arm (PCon "Ok" (PCon "None")) () (EApp (EApp (EApp (EApp (EApp (EVar "readPark") (EVar "p")) (EVar "stream")) (EVar "limit")) (EVar "deadline")) (EVar "token"))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EApp (EApp (EApp (EVar "readPark") (EVar "p")) (EVar "stream")) (EVar "limit")) (EVar "deadline")) (EVar "token"))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "err")))))))))) (EVar "identity")))
(DTypeSig false "readPark" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "OutputStream") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyCon "ReadResult"))))))))))
(DFunDef false "readPark" ((PVar "p") (PVar "stream") (PVar "limit") (PVar "deadline") (PVar "token")) (EMatch (EApp (EApp (EVar "streamFd") (EVar "p")) (EApp (EVar "outputStreamCode") (EVar "stream"))) (arm (PCon "Ok" (PVar "fd")) () (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit (EApp (EVar "waitRead") (EVar "fd"))))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "readUntil") (EVar "p")) (EVar "stream")) (EVar "limit")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "readUntil") (EVar "p")) (EVar "stream")) (EVar "limit")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "err"))))))
(DTypeSig true "writeUntil" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Bytes") (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyTuple (TyCon "ProcessError") (TyCon "Int"))) (TyCon "WriteResult"))))))))
(DFunDef false "writeUntil" ((PVar "p") (PVar "bytes") (PVar "deadline") (PVar "token")) (EApp (EApp (EApp (EApp (EApp (EVar "writeFrom") (EVar "p")) (EVar "bytes")) (ELit (LInt 0))) (EVar "deadline")) (EVar "token")))
(DTypeSig false "writeFrom" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyTuple (TyCon "ProcessError") (TyCon "Int"))) (TyCon "WriteResult")))))))))
(DFunDef false "writeFrom" ((PVar "p") (PVar "bytes") (PVar "offset") (PVar "deadline") (PVar "token")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam (PWild) (EMatch (EApp (EApp (EVar "stop") (EVar "deadline")) (EVar "token")) (arm (PCon "Some" (PCon "True")) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EApp (EVar "WriteCancelled") (EVar "offset"))))) (arm (PCon "Some" (PCon "False")) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EApp (EVar "WriteTimedOut") (EVar "offset"))))) (arm (PCon "None") () (EIf (EBinOp "==" (EVar "offset") (EApp (EVar "B.length") (EVar "bytes"))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (EApp (EVar "Written") (EVar "offset")))) (EMatch (EApp (EApp (EApp (EApp (EVar "tryWrite") (EVar "p")) (EVar "bytes")) (EVar "offset")) (EBinOp "-" (EApp (EVar "B.length") (EVar "bytes")) (EVar "offset"))) (arm (PCon "Ok" (PCon "Some" (PVar "n"))) () (EApp (EApp (EApp (EApp (EApp (EVar "writeFrom") (EVar "p")) (EVar "bytes")) (EBinOp "+" (EVar "offset") (EVar "n"))) (EVar "deadline")) (EVar "token"))) (arm (PCon "Ok" (PCon "None")) () (EApp (EApp (EApp (EApp (EApp (EVar "writePark") (EVar "p")) (EVar "bytes")) (EVar "offset")) (EVar "deadline")) (EVar "token"))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EApp (EApp (EApp (EVar "writePark") (EVar "p")) (EVar "bytes")) (EVar "offset")) (EVar "deadline")) (EVar "token"))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "deferPure") (EApp (EVar "Err") (ETuple (EVar "err") (EVar "offset")))))))))))) (EVar "identity")))
(DTypeSig false "writePark" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyTuple (TyCon "ProcessError") (TyCon "Int"))) (TyCon "WriteResult"))))))))))
(DFunDef false "writePark" ((PVar "p") (PVar "bytes") (PVar "offset") (PVar "deadline") (PVar "token")) (EMatch (EApp (EApp (EVar "streamFd") (EVar "p")) (ELit (LInt 0))) (arm (PCon "Ok" (PVar "fd")) () (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit (EApp (EVar "waitWrite") (EVar "fd"))))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "writeFrom") (EVar "p")) (EVar "bytes")) (EVar "offset")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "writeFrom") (EVar "p")) (EVar "bytes")) (EVar "offset")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "deferPure") (EApp (EVar "Err") (ETuple (EVar "err") (EVar "offset")))))))
(DTypeSig true "waitUntil" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyCon "WaitResult")))))))
(DFunDef false "waitUntil" ((PVar "p") (PVar "deadline") (PVar "token")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam (PWild) (EMatch (EApp (EApp (EVar "stop") (EVar "deadline")) (EVar "token")) (arm (PCon "Some" (PCon "True")) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "WaitCancelled")))) (arm (PCon "Some" (PCon "False")) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "WaitTimedOut")))) (arm (PCon "None") () (EMatch (EApp (EVar "pollExit") (EVar "p")) (arm (PCon "Ok" (PCon "Some" (PVar "status"))) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EApp (EVar "ChildExited") (EVar "status"))))) (arm (PCon "Ok" (PCon "None")) () (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "err")))))))))) (EVar "identity")))
(DData Public "LaunchStop" ("ticket") ((variant "LaunchStopped" (ConPos)) (variant "LaunchCleanupPending" (ConPos (TyVar "ticket") (TyApp (TyCon "Option") (TyCon "ProcessError")))) (variant "LaunchCleanupFailed" (ConPos (TyCon "ProcessError")))) ())
(DData Public "StartResult" ("process" "ticket") ((variant "Started" (ConPos (TyVar "process"))) (variant "StartTimedOut" (ConPos (TyApp (TyCon "LaunchStop") (TyVar "ticket")))) (variant "StartCancelled" (ConPos (TyApp (TyCon "LaunchStop") (TyVar "ticket"))))) ())
(DTypeSig true "startUntil" (TyFun (TyNamed "program" (TyCon "String")) (TyFun (TyCon "SpawnOptions") (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "program"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "program"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "StartError") (TyApp (TyCon "LaunchTicket") (TyVar "program")))) (TyApp (TyApp (TyCon "StartResult") (TyApp (TyCon "Process") (TyVar "program"))) (TyApp (TyCon "LaunchTicket") (TyVar "program"))))))))))
(DFunDef false "startUntil" ((PVar "program") (PVar "opts") (PVar "deadline") (PVar "token")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam (PWild) (EMatch (EApp (EApp (EVar "stop") (EVar "deadline")) (EVar "token")) (arm (PCon "Some" (PCon "True")) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EApp (EVar "StartCancelled") (EVar "LaunchStopped"))))) (arm (PCon "Some" (PCon "False")) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EApp (EVar "StartTimedOut") (EVar "LaunchStopped"))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "submit") (EVar "program")) (EVar "opts")) (arm (PCon "Ok" (PVar "ticket")) () (EApp (EApp (EApp (EVar "startPoll") (EVar "ticket")) (EVar "deadline")) (EVar "token"))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "startUntil") (EVar "program")) (EVar "opts")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "deferPure") (EApp (EVar "Err") (EApp (EVar "StartRejected") (EVar "err"))))))))))) (EVar "identity")))
(DTypeSig false "startPoll" (TyFun (TyApp (TyCon "LaunchTicket") (TyVar "p")) (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "StartError") (TyApp (TyCon "LaunchTicket") (TyVar "p")))) (TyApp (TyApp (TyCon "StartResult") (TyApp (TyCon "Process") (TyVar "p"))) (TyApp (TyCon "LaunchTicket") (TyVar "p")))))))))
(DFunDef false "startPoll" ((PVar "ticket") (PVar "deadline") (PVar "token")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam (PWild) (EMatch (EApp (EApp (EVar "stop") (EVar "deadline")) (EVar "token")) (arm (PCon "Some" (PCon "True")) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EApp (EVar "StartCancelled") (EApp (EVar "stopLaunch") (EVar "ticket")))))) (arm (PCon "Some" (PCon "False")) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EApp (EVar "StartTimedOut") (EApp (EVar "stopLaunch") (EVar "ticket")))))) (arm (PCon "None") () (EMatch (EApp (EVar "checkStart") (EVar "ticket")) (arm (PCon "Ok" (PCon "LaunchStarted" (PVar "p"))) () (EApp (EVar "deferPure") (EApp (EVar "Ok") (EApp (EVar "Started") (EVar "p"))))) (arm (PCon "Ok" (PCon "LaunchPending")) () (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EVar "startPoll") (EVar "ticket")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Ok" (PCon "LaunchFailed" (PVar "err"))) () (EApp (EVar "deferPure") (EApp (EVar "Err") (EApp (EVar "StartRejected") (EVar "err"))))) (arm (PCon "Ok" (PCon "LaunchAborted")) () (EApp (EVar "deferPure") (EApp (EVar "Err") (EApp (EVar "StartRejected") (EVar "LaunchCancelled"))))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EVar "startPoll") (EVar "ticket")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "deferPure") (EApp (EVar "Err") (EApp (EApp (EVar "StartCleanupPending") (EVar "err")) (EVar "ticket"))))))))))) (EVar "identity")))
(DTypeSig false "stopLaunch" (TyFun (TyApp (TyCon "LaunchTicket") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyCon "LaunchStop") (TyApp (TyCon "LaunchTicket") (TyVar "p"))))))
(DFunDef false "stopLaunch" ((PVar "ticket")) (EMatch (EApp (EVar "abortStart") (EVar "ticket")) (arm (PCon "Ok" (PCon "LaunchAborted")) () (EVar "LaunchStopped")) (arm (PCon "Ok" (PCon "LaunchFailed" (PVar "err"))) () (EApp (EVar "LaunchCleanupFailed") (EVar "err"))) (arm (PCon "Ok" (PCon "LaunchPending")) () (EApp (EApp (EVar "LaunchCleanupPending") (EVar "ticket")) (EVar "None"))) (arm (PCon "Ok" (PCon "LaunchStarted" PWild)) () (EApp (EApp (EVar "LaunchCleanupPending") (EVar "ticket")) (EVar "None"))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EVar "LaunchCleanupPending") (EVar "ticket")) (EVar "None"))) (arm (PCon "Err" (PVar "err")) () (EApp (EApp (EVar "LaunchCleanupPending") (EVar "ticket")) (EApp (EVar "Some") (EVar "err"))))))
# MARK
(DUse false (UseGroup ("async") ((mem "Async" false) (mem "Wait" false) (mem "liftIO" false) (mem "awaitAny" false) (mem "deadlineAfter" false) (mem "expiredNow" false) (mem "waitFlag" false) (mem "waitRead" false) (mem "waitWrite" false))))
(DUse false (UseGroup ("bytes") ((mem "Bytes" false))))
(DUse false (UseAlias ("bytes") "B"))
(DUse false (UseGroup ("process") ((mem "ProcessError" true) (mem "OutputStream" false) (mem "outputStreamCode" false) (mem "ExitStatus" false) (mem "tryRead" false) (mem "tryWrite" false) (mem "streamFd" false) (mem "pollExit" false) (mem "SpawnOptions" false) (mem "StartError" true) (mem "LaunchProgress" true) (mem "submit" false) (mem "checkStart" false) (mem "abortStart" false))))
(DUse false (UseGroup ("time") ((mem "Duration" false) (mem "millis" false))))
(DData Abstract "Deadline" ("e") ((variant "Deadline" (ConPos (TyApp (TyCon "Wait") (TyVar "e"))))) ())
(DData Abstract "CancelToken" () ((variant "CancelToken" (ConPos (TyApp (TyCon "Ref") (TyCon "Bool"))))) ())
(DData Public "ReadResult" () ((variant "Read" (ConPos (TyCon "Bytes"))) (variant "EndOfStream" (ConPos)) (variant "ReadTimedOut" (ConPos)) (variant "ReadCancelled" (ConPos))) ())
(DData Public "WriteResult" () ((variant "Written" (ConPos (TyCon "Int"))) (variant "WriteTimedOut" (ConPos (TyCon "Int"))) (variant "WriteCancelled" (ConPos (TyCon "Int")))) ())
(DData Public "WaitResult" () ((variant "ChildExited" (ConPos (TyCon "ExitStatus"))) (variant "WaitTimedOut" (ConPos)) (variant "WaitCancelled" (ConPos))) ())
(DTypeSig true "newCancelToken" (TyFun (TyCon "Unit") (TyCon "CancelToken")))
(DFunDef false "newCancelToken" (PWild) (EApp (EVar "CancelToken") (EApp (EVar "Ref") (EVar "False"))))
(DTypeSig true "cancel" (TyFun (TyCon "CancelToken") (TyCon "Unit")))
(DFunDef false "cancel" ((PCon "CancelToken" (PVar "flag"))) (EApp (EApp (EVar "setRef") (EVar "flag")) (EVar "True")))
(DTypeSig true "cancelled" (TyFun (TyCon "CancelToken") (TyCon "Bool")))
(DFunDef false "cancelled" ((PCon "CancelToken" (PVar "flag"))) (EUnOp "!" (EVar "flag")))
(DTypeSig true "cancelWait" (TyFun (TyCon "CancelToken") (TyApp (TyCon "Wait") (TyVar "e"))))
(DFunDef false "cancelWait" ((PCon "CancelToken" (PVar "flag"))) (EApp (EVar "waitFlag") (EVar "flag")))
(DTypeSig true "after" (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock") (Some "e"))) (TyApp (TyCon "Deadline") (TyRow ("Clock") (Some "e"))))))
(DFunDef false "after" ((PVar "duration")) (EApp (EApp (EMethodRef "deferMap") (EVar "Deadline")) (EApp (EVar "deadlineAfter") (EVar "duration"))))
(DTypeSig true "deadlineWait" (TyFun (TyApp (TyCon "Deadline") (TyVar "e")) (TyApp (TyCon "Wait") (TyVar "e"))))
(DFunDef false "deadlineWait" ((PCon "Deadline" (PVar "wait"))) (EVar "wait"))
(DTypeSig false "stop" (TyFun (TyApp (TyCon "Deadline") (TyVar "e")) (TyFun (TyCon "CancelToken") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Bool"))))))
(DFunDef false "stop" ((PVar "deadline") (PVar "token")) (EIf (EApp (EVar "cancelled") (EVar "token")) (EApp (EVar "Some") (EVar "True")) (EIf (EApp (EVar "expiredNow") (EApp (EVar "deadlineWait") (EVar "deadline"))) (EApp (EVar "Some") (EVar "False")) (EVar "None"))))
(DTypeSig false "park" (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock") (Some "e"))) (TyFun (TyCon "CancelToken") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyRow ("Clock") (Some "e")))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock") (Some "e"))) (TyCon "Unit"))))))
(DFunDef false "park" ((PVar "deadline") (PVar "token") (PVar "extra")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "deadlineAfter") (EApp (EVar "millis") (ELit (LInt 10))))) (ELam ((PVar "tick")) (EApp (EVar "awaitAny") (EBinOp "::" (EApp (EVar "deadlineWait") (EVar "deadline")) (EBinOp "::" (EApp (EVar "cancelWait") (EVar "token")) (EBinOp "::" (EVar "tick") (EVar "extra"))))))))
(DTypeSig true "readUntil" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "OutputStream") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyCon "ReadResult")))))))))
(DFunDef false "readUntil" ((PVar "p") (PVar "stream") (PVar "limit") (PVar "deadline") (PVar "token")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam (PWild) (EMatch (EApp (EApp (EVar "stop") (EVar "deadline")) (EVar "token")) (arm (PCon "Some" (PCon "True")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "ReadCancelled")))) (arm (PCon "Some" (PCon "False")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "ReadTimedOut")))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "tryRead") (EVar "p")) (EVar "stream")) (EVar "limit")) (arm (PCon "Ok" (PCon "Some" (PVar "bytes"))) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EIf (EBinOp "==" (EApp (EVar "B.length") (EVar "bytes")) (ELit (LInt 0))) (EVar "EndOfStream") (EApp (EVar "Read") (EVar "bytes")))))) (arm (PCon "Ok" (PCon "None")) () (EApp (EApp (EApp (EApp (EApp (EVar "readPark") (EVar "p")) (EVar "stream")) (EVar "limit")) (EVar "deadline")) (EVar "token"))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EApp (EApp (EApp (EVar "readPark") (EVar "p")) (EVar "stream")) (EVar "limit")) (EVar "deadline")) (EVar "token"))) (arm (PCon "Err" (PVar "err")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "err")))))))))) (EVar "identity")))
(DTypeSig false "readPark" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "OutputStream") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyCon "ReadResult"))))))))))
(DFunDef false "readPark" ((PVar "p") (PVar "stream") (PVar "limit") (PVar "deadline") (PVar "token")) (EMatch (EApp (EApp (EVar "streamFd") (EVar "p")) (EApp (EVar "outputStreamCode") (EVar "stream"))) (arm (PCon "Ok" (PVar "fd")) () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit (EApp (EVar "waitRead") (EVar "fd"))))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "readUntil") (EVar "p")) (EVar "stream")) (EVar "limit")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "readUntil") (EVar "p")) (EVar "stream")) (EVar "limit")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PVar "err")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "err"))))))
(DTypeSig true "writeUntil" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Bytes") (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyTuple (TyCon "ProcessError") (TyCon "Int"))) (TyCon "WriteResult"))))))))
(DFunDef false "writeUntil" ((PVar "p") (PVar "bytes") (PVar "deadline") (PVar "token")) (EApp (EApp (EApp (EApp (EApp (EVar "writeFrom") (EVar "p")) (EVar "bytes")) (ELit (LInt 0))) (EVar "deadline")) (EVar "token")))
(DTypeSig false "writeFrom" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyTuple (TyCon "ProcessError") (TyCon "Int"))) (TyCon "WriteResult")))))))))
(DFunDef false "writeFrom" ((PVar "p") (PVar "bytes") (PVar "offset") (PVar "deadline") (PVar "token")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam (PWild) (EMatch (EApp (EApp (EVar "stop") (EVar "deadline")) (EVar "token")) (arm (PCon "Some" (PCon "True")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EApp (EVar "WriteCancelled") (EVar "offset"))))) (arm (PCon "Some" (PCon "False")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EApp (EVar "WriteTimedOut") (EVar "offset"))))) (arm (PCon "None") () (EIf (EBinOp "==" (EVar "offset") (EApp (EVar "B.length") (EVar "bytes"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EApp (EVar "Written") (EVar "offset")))) (EMatch (EApp (EApp (EApp (EApp (EVar "tryWrite") (EVar "p")) (EVar "bytes")) (EVar "offset")) (EBinOp "-" (EApp (EVar "B.length") (EVar "bytes")) (EVar "offset"))) (arm (PCon "Ok" (PCon "Some" (PVar "n"))) () (EApp (EApp (EApp (EApp (EApp (EVar "writeFrom") (EVar "p")) (EVar "bytes")) (EBinOp "+" (EVar "offset") (EVar "n"))) (EVar "deadline")) (EVar "token"))) (arm (PCon "Ok" (PCon "None")) () (EApp (EApp (EApp (EApp (EApp (EVar "writePark") (EVar "p")) (EVar "bytes")) (EVar "offset")) (EVar "deadline")) (EVar "token"))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EApp (EApp (EApp (EVar "writePark") (EVar "p")) (EVar "bytes")) (EVar "offset")) (EVar "deadline")) (EVar "token"))) (arm (PCon "Err" (PVar "err")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (ETuple (EVar "err") (EVar "offset")))))))))))) (EVar "identity")))
(DTypeSig false "writePark" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyTuple (TyCon "ProcessError") (TyCon "Int"))) (TyCon "WriteResult"))))))))))
(DFunDef false "writePark" ((PVar "p") (PVar "bytes") (PVar "offset") (PVar "deadline") (PVar "token")) (EMatch (EApp (EApp (EVar "streamFd") (EVar "p")) (ELit (LInt 0))) (arm (PCon "Ok" (PVar "fd")) () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit (EApp (EVar "waitWrite") (EVar "fd"))))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "writeFrom") (EVar "p")) (EVar "bytes")) (EVar "offset")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "writeFrom") (EVar "p")) (EVar "bytes")) (EVar "offset")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PVar "err")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (ETuple (EVar "err") (EVar "offset")))))))
(DTypeSig true "waitUntil" (TyFun (TyApp (TyCon "Process") (TyVar "p")) (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "ProcessError")) (TyCon "WaitResult")))))))
(DFunDef false "waitUntil" ((PVar "p") (PVar "deadline") (PVar "token")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam (PWild) (EMatch (EApp (EApp (EVar "stop") (EVar "deadline")) (EVar "token")) (arm (PCon "Some" (PCon "True")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "WaitCancelled")))) (arm (PCon "Some" (PCon "False")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "WaitTimedOut")))) (arm (PCon "None") () (EMatch (EApp (EVar "pollExit") (EVar "p")) (arm (PCon "Ok" (PCon "Some" (PVar "status"))) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EApp (EVar "ChildExited") (EVar "status"))))) (arm (PCon "Ok" (PCon "None")) () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PVar "err")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "err")))))))))) (EVar "identity")))
(DData Public "LaunchStop" ("ticket") ((variant "LaunchStopped" (ConPos)) (variant "LaunchCleanupPending" (ConPos (TyVar "ticket") (TyApp (TyCon "Option") (TyCon "ProcessError")))) (variant "LaunchCleanupFailed" (ConPos (TyCon "ProcessError")))) ())
(DData Public "StartResult" ("process" "ticket") ((variant "Started" (ConPos (TyVar "process"))) (variant "StartTimedOut" (ConPos (TyApp (TyCon "LaunchStop") (TyVar "ticket")))) (variant "StartCancelled" (ConPos (TyApp (TyCon "LaunchStop") (TyVar "ticket"))))) ())
(DTypeSig true "startUntil" (TyFun (TyNamed "program" (TyCon "String")) (TyFun (TyCon "SpawnOptions") (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "program"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "program"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "StartError") (TyApp (TyCon "LaunchTicket") (TyVar "program")))) (TyApp (TyApp (TyCon "StartResult") (TyApp (TyCon "Process") (TyVar "program"))) (TyApp (TyCon "LaunchTicket") (TyVar "program"))))))))))
(DFunDef false "startUntil" ((PVar "program") (PVar "opts") (PVar "deadline") (PVar "token")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam (PWild) (EMatch (EApp (EApp (EVar "stop") (EVar "deadline")) (EVar "token")) (arm (PCon "Some" (PCon "True")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EApp (EVar "StartCancelled") (EVar "LaunchStopped"))))) (arm (PCon "Some" (PCon "False")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EApp (EVar "StartTimedOut") (EVar "LaunchStopped"))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "submit") (EVar "program")) (EVar "opts")) (arm (PCon "Ok" (PVar "ticket")) () (EApp (EApp (EApp (EVar "startPoll") (EVar "ticket")) (EVar "deadline")) (EVar "token"))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "startUntil") (EVar "program")) (EVar "opts")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PVar "err")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EApp (EVar "StartRejected") (EVar "err"))))))))))) (EVar "identity")))
(DTypeSig false "startPoll" (TyFun (TyApp (TyCon "LaunchTicket") (TyVar "p")) (TyFun (TyApp (TyCon "Deadline") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyFun (TyCon "CancelToken") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Exec" (name "p"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "StartError") (TyApp (TyCon "LaunchTicket") (TyVar "p")))) (TyApp (TyApp (TyCon "StartResult") (TyApp (TyCon "Process") (TyVar "p"))) (TyApp (TyCon "LaunchTicket") (TyVar "p")))))))))
(DFunDef false "startPoll" ((PVar "ticket") (PVar "deadline") (PVar "token")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam (PWild) (EMatch (EApp (EApp (EVar "stop") (EVar "deadline")) (EVar "token")) (arm (PCon "Some" (PCon "True")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EApp (EVar "StartCancelled") (EApp (EVar "stopLaunch") (EVar "ticket")))))) (arm (PCon "Some" (PCon "False")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EApp (EVar "StartTimedOut") (EApp (EVar "stopLaunch") (EVar "ticket")))))) (arm (PCon "None") () (EMatch (EApp (EVar "checkStart") (EVar "ticket")) (arm (PCon "Ok" (PCon "LaunchStarted" (PVar "p"))) () (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EApp (EVar "Started") (EVar "p"))))) (arm (PCon "Ok" (PCon "LaunchPending")) () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EVar "startPoll") (EVar "ticket")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Ok" (PCon "LaunchFailed" (PVar "err"))) () (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EApp (EVar "StartRejected") (EVar "err"))))) (arm (PCon "Ok" (PCon "LaunchAborted")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EApp (EVar "StartRejected") (EVar "LaunchCancelled"))))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "park") (EVar "deadline")) (EVar "token")) (EListLit))) (ELam (PWild) (EApp (EApp (EApp (EVar "startPoll") (EVar "ticket")) (EVar "deadline")) (EVar "token"))))) (arm (PCon "Err" (PVar "err")) () (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EApp (EApp (EVar "StartCleanupPending") (EVar "err")) (EVar "ticket"))))))))))) (EVar "identity")))
(DTypeSig false "stopLaunch" (TyFun (TyApp (TyCon "LaunchTicket") (TyVar "p")) (TyEffect ((atom "Exec" (name "p"))) None (TyApp (TyCon "LaunchStop") (TyApp (TyCon "LaunchTicket") (TyVar "p"))))))
(DFunDef false "stopLaunch" ((PVar "ticket")) (EMatch (EApp (EVar "abortStart") (EVar "ticket")) (arm (PCon "Ok" (PCon "LaunchAborted")) () (EVar "LaunchStopped")) (arm (PCon "Ok" (PCon "LaunchFailed" (PVar "err"))) () (EApp (EVar "LaunchCleanupFailed") (EVar "err"))) (arm (PCon "Ok" (PCon "LaunchPending")) () (EApp (EApp (EVar "LaunchCleanupPending") (EVar "ticket")) (EVar "None"))) (arm (PCon "Ok" (PCon "LaunchStarted" PWild)) () (EApp (EApp (EVar "LaunchCleanupPending") (EVar "ticket")) (EVar "None"))) (arm (PCon "Err" (PCon "ProcessBusy")) () (EApp (EApp (EVar "LaunchCleanupPending") (EVar "ticket")) (EVar "None"))) (arm (PCon "Err" (PVar "err")) () (EApp (EApp (EVar "LaunchCleanupPending") (EVar "ticket")) (EApp (EVar "Some") (EVar "err"))))))
