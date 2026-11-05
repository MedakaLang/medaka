# META
source_lines=227
stages=DESUGAR,MARK
# SOURCE
import async.{Async, runAsync, sleep, expiredNow, spawn, liftIO, yield}
import process.{
  SpawnOptions(..), PipeChoice(..), ExitStatus(..), OutputStream(..),
  closeStdin, dispose
}
import process_async.{
  newCancelToken, cancel, cancelled, after, deadlineWait, startUntil, waitUntil,
  WaitResult(..), readUntil, ReadResult(..), writeUntil, WriteResult(..),
  StartResult(..), LaunchStop(..)
}
import bytes.{encodeUtf8, decodeUtf8}
import string.{repeat, trim}
import time.{millis}
import test.{expectEqual, expectTrue}

options : SpawnOptions
options = SpawnOptions {
  argv = [],
  cwd = "/tmp",
  env = [],
  stdin = Null,
  stdout = Null,
  stderr = Null,
}

test "cancel tokens retain cancellation" =
  let token = newCancelToken ()
  let before = cancelled token
  cancel token
  expectEqual (False, True) (before, cancelled token)

test "cancel takes priority over an expired deadline" =
  let deadline = runAsync (after (millis -1))
  let token = newCancelToken ()
  cancel token
  let result = runAsync (startUntil "/bin/true" options deadline token)
  expectTrue (match result
    Ok (StartCancelled LaunchStopped) => True
    _ => False)

test "expired deadline stops before submission" =
  let deadline = runAsync (after (millis -1))
  let result =
    runAsync (startUntil "/bin/true" options deadline (newCancelToken ()))
  expectTrue (match result
    Ok (StartTimedOut LaunchStopped) => True
    _ => False)

test "deadline wait remains absolute after delayed scheduling" =
  let deadline = runAsync (after (millis 5))
  let _ = runAsync (sleep (millis 20))
  expectTrue (expiredNow (deadlineWait deadline))

test "launch transfers an owner and observes direct child exit" =
  let deadline = runAsync (after (millis 5000))
  let outcome =
    runAsync (startUntil "/bin/true" options deadline (newCancelToken ()))
  let result = match outcome
    Ok (Started p) =>
      let exited = runAsync (waitUntil p deadline (newCancelToken ()))
      let disposed = dispose p
      match (exited, disposed)
        (Ok (ChildExited (Exited 0)), Ok _) => True
        _ => False
    _ => False
  expectTrue result

test "writes and reads child pipes with exact bytes" =
  let opts = SpawnOptions {
    argv = [],
    cwd = "/tmp",
    env = [],
    stdin = Piped,
    stdout = Piped,
    stderr = Null,
  }
  let deadline = runAsync (after (millis 5000))
  let started =
    runAsync (startUntil "/bin/cat" opts deadline (newCancelToken ()))
  let result = match started
    Ok (Started p) =>
      let empty =
        runAsync (writeUntil p (encodeUtf8 "") deadline (newCancelToken ()))
      let written =
        runAsync
          (writeUntil p (encodeUtf8 "hello") deadline (newCancelToken ()))
      let closed = closeStdin p
      let read =
        runAsync (readUntil p ChildStdout 100 deadline (newCancelToken ()))
      let exited = runAsync (waitUntil p deadline (newCancelToken ()))
      let disposed = dispose p
      match (empty, written, closed, read, exited, disposed)
        (Ok (Written 0), Ok (Written 5), Ok _, Ok (Read bytes), Ok (ChildExited (Exited 0)), Ok _) =>
          decodeUtf8 bytes == Some "hello"
        _ => False
    _ => False
  expectTrue result

test "cancellation wakes a parked read" =
  let opts = SpawnOptions {
    argv = [],
    cwd = "/tmp",
    env = [],
    stdin = Piped,
    stdout = Piped,
    stderr = Null,
  }
  let deadline = runAsync (after (millis 5000))
  let started =
    runAsync (startUntil "/bin/cat" opts deadline (newCancelToken ()))
  let result = match started
    Ok (Started p) =>
      let token = newCancelToken ()
      let reading = deferThen (spawn
        (deferThen (sleep (millis 20)) (_ => liftIO (_ => cancel token)))) (_ =>
        readUntil p ChildStdout 100 deadline token)
      let read = runAsync reading
      let closed = closeStdin p
      let exited = runAsync (waitUntil p deadline (newCancelToken ()))
      let disposed = dispose p
      match (read, closed, exited, disposed)
        (Ok ReadCancelled, Ok _, Ok (ChildExited (Exited 0)), Ok _) => True
        _ => False
    _ => False
  expectTrue result

test "backpressured write returns its committed prefix on timeout" =
  let opts = SpawnOptions {
    argv = ["-c", "sleep 0.3; wc -c"],
    cwd = "/tmp",
    env = [],
    stdin = Piped,
    stdout = Piped,
    stderr = Null,
  }
  let launchDeadline = runAsync (after (millis 5000))
  let started =
    runAsync (startUntil "/bin/sh" opts launchDeadline (newCancelToken ()))
  let result = match started
    Ok (Started p) =>
      let bytes = encodeUtf8 (repeat 1000000 "x")
      let deadline = runAsync (after (millis 100))
      let written = runAsync (writeUntil p bytes deadline (newCancelToken ()))
      let closed = closeStdin p
      let observed =
        runAsync
          (readUntil p ChildStdout 100 launchDeadline (newCancelToken ()))
      let exited = runAsync (waitUntil p launchDeadline (newCancelToken ()))
      let disposed = dispose p
      match (written, closed, observed, exited, disposed)
        (Ok (WriteTimedOut n), Ok _, Ok (Read count), Ok (ChildExited (Exited 0)), Ok _) =>
          n > 0
            && n < 1000000
            && map trim (decodeUtf8 count) == Some (intToString n)
        _ => False
    _ => False
  expectTrue result

test "backpressured cancellation retains its committed prefix" =
  let opts = SpawnOptions {
    argv = ["-c", "sleep 0.3; wc -c"],
    cwd = "/tmp",
    env = [],
    stdin = Piped,
    stdout = Piped,
    stderr = Null,
  }
  let deadline = runAsync (after (millis 5000))
  let started =
    runAsync (startUntil "/bin/sh" opts deadline (newCancelToken ()))
  let result = match started
    Ok (Started p) =>
      let token = newCancelToken ()
      let bytes = encodeUtf8 (repeat 1000000 "x")
      let writing = deferThen (spawn
        (deferThen (sleep (millis 100)) (_ => liftIO (_ =>
          cancel token)))) (_ =>
        writeUntil p bytes deadline token)
      let written = runAsync writing
      let closed = closeStdin p
      let observed =
        runAsync (readUntil p ChildStdout 100 deadline (newCancelToken ()))
      let exited = runAsync (waitUntil p deadline (newCancelToken ()))
      let disposed = dispose p
      match (written, closed, observed, exited, disposed)
        (Ok (WriteCancelled n), Ok _, Ok (Read count), Ok (ChildExited (Exited 0)), Ok _) =>
          n > 0
            && n < 1000000
            && map trim (decodeUtf8 count) == Some (intToString n)
        _ => False
    _ => False
  expectTrue result

yieldSteps : Int -> Async e Unit
yieldSteps n =
  if n <= 0 then deferPure () else deferThen yield (_ => yieldSteps (n - 1))

test "continuous writable progress yields to cancellation" =
  let opts = SpawnOptions {
    argv = ["-c", "cat >/dev/null"],
    cwd = "/tmp",
    env = [],
    stdin = Piped,
    stdout = Null,
    stderr = Null,
  }
  let deadline = runAsync (after (millis 5000))
  let started =
    runAsync (startUntil "/bin/sh" opts deadline (newCancelToken ()))
  let result = match started
    Ok (Started p) =>
      let token = newCancelToken ()
      let bytes = encodeUtf8 (repeat 10000000 "x")
      let cancelTask =
        deferThen (yieldSteps 30) (_ => liftIO (_ => cancel token))
      let writing =
        deferThen (spawn cancelTask) (_ => writeUntil p bytes deadline token)
      let written = runAsync writing
      let closed = closeStdin p
      let exited = runAsync (waitUntil p deadline (newCancelToken ()))
      let disposed = dispose p
      match (written, closed, exited, disposed)
        (Ok (WriteCancelled n), Ok _, Ok (ChildExited (Exited 0)), Ok _) =>
          n > 0 && n < 10000000
        _ => False
    _ => False
  expectTrue result
# DESUGAR
(DUse false (UseGroup ("async") ((mem "Async" false) (mem "runAsync" false) (mem "sleep" false) (mem "expiredNow" false) (mem "spawn" false) (mem "liftIO" false) (mem "yield" false))))
(DUse false (UseGroup ("process") ((mem "SpawnOptions" true) (mem "PipeChoice" true) (mem "ExitStatus" true) (mem "OutputStream" true) (mem "closeStdin" false) (mem "dispose" false))))
(DUse false (UseGroup ("process_async") ((mem "newCancelToken" false) (mem "cancel" false) (mem "cancelled" false) (mem "after" false) (mem "deadlineWait" false) (mem "startUntil" false) (mem "waitUntil" false) (mem "WaitResult" true) (mem "readUntil" false) (mem "ReadResult" true) (mem "writeUntil" false) (mem "WriteResult" true) (mem "StartResult" true) (mem "LaunchStop" true))))
(DUse false (UseGroup ("bytes") ((mem "encodeUtf8" false) (mem "decodeUtf8" false))))
(DUse false (UseGroup ("string") ((mem "repeat" false) (mem "trim" false))))
(DUse false (UseGroup ("time") ((mem "millis" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectTrue" false))))
(DTypeSig false "options" (TyCon "SpawnOptions"))
(DFunDef false "options" () (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit)) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Null")) (fa "stdout" (EVar "Null")) (fa "stderr" (EVar "Null")))))
(DTest false "cancel tokens retain cancellation" (EBlock (DoLet false false (PVar "token") (EApp (EVar "newCancelToken") (ELit LUnit))) (DoLet false false (PVar "before") (EApp (EVar "cancelled") (EVar "token"))) (DoExpr (EApp (EVar "cancel") (EVar "token"))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EVar "False") (EVar "True"))) (ETuple (EVar "before") (EApp (EVar "cancelled") (EVar "token")))))))
(DTest false "cancel takes priority over an expired deadline" (EBlock (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt -1)))))) (DoLet false false (PVar "token") (EApp (EVar "newCancelToken") (ELit LUnit))) (DoExpr (EApp (EVar "cancel") (EVar "token"))) (DoLet false false (PVar "result") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/true"))) (EVar "options")) (EVar "deadline")) (EVar "token")))) (DoExpr (EApp (EVar "expectTrue") (EMatch (EVar "result") (arm (PCon "Ok" (PCon "StartCancelled" (PCon "LaunchStopped"))) () (EVar "True")) (arm PWild () (EVar "False")))))))
(DTest false "expired deadline stops before submission" (EBlock (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt -1)))))) (DoLet false false (PVar "result") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/true"))) (EVar "options")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoExpr (EApp (EVar "expectTrue") (EMatch (EVar "result") (arm (PCon "Ok" (PCon "StartTimedOut" (PCon "LaunchStopped"))) () (EVar "True")) (arm PWild () (EVar "False")))))))
(DTest false "deadline wait remains absolute after delayed scheduling" (EBlock (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5)))))) (DoLet false false PWild (EApp (EVar "runAsync") (EApp (EVar "sleep") (EApp (EVar "millis") (ELit (LInt 20)))))) (DoExpr (EApp (EVar "expectTrue") (EApp (EVar "expiredNow") (EApp (EVar "deadlineWait") (EVar "deadline")))))))
(DTest false "launch transfers an owner and observes direct child exit" (EBlock (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5000)))))) (DoLet false false (PVar "outcome") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/true"))) (EVar "options")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "result") (EMatch (EVar "outcome") (arm (PCon "Ok" (PCon "Started" (PVar "p"))) () (EBlock (DoLet false false (PVar "exited") (EApp (EVar "runAsync") (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "disposed") (EApp (EVar "dispose") (EVar "p"))) (DoExpr (EMatch (ETuple (EVar "exited") (EVar "disposed")) (arm (PTuple (PCon "Ok" (PCon "ChildExited" (PCon "Exited" (PLit (LInt 0))))) (PCon "Ok" PWild)) () (EVar "True")) (arm PWild () (EVar "False")))))) (arm PWild () (EVar "False")))) (DoExpr (EApp (EVar "expectTrue") (EVar "result")))))
(DTest false "writes and reads child pipes with exact bytes" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit)) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Piped")) (fa "stderr" (EVar "Null"))))) (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5000)))))) (DoLet false false (PVar "started") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/cat"))) (EVar "opts")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "result") (EMatch (EVar "started") (arm (PCon "Ok" (PCon "Started" (PVar "p"))) () (EBlock (DoLet false false (PVar "empty") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "writeUntil") (EVar "p")) (EApp (EVar "encodeUtf8") (ELit (LString "")))) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "written") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "writeUntil") (EVar "p")) (EApp (EVar "encodeUtf8") (ELit (LString "hello")))) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "closed") (EApp (EVar "closeStdin") (EVar "p"))) (DoLet false false (PVar "read") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EApp (EVar "readUntil") (EVar "p")) (EVar "ChildStdout")) (ELit (LInt 100))) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "exited") (EApp (EVar "runAsync") (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "disposed") (EApp (EVar "dispose") (EVar "p"))) (DoExpr (EMatch (ETuple (EVar "empty") (EVar "written") (EVar "closed") (EVar "read") (EVar "exited") (EVar "disposed")) (arm (PTuple (PCon "Ok" (PCon "Written" (PLit (LInt 0)))) (PCon "Ok" (PCon "Written" (PLit (LInt 5)))) (PCon "Ok" PWild) (PCon "Ok" (PCon "Read" (PVar "bytes"))) (PCon "Ok" (PCon "ChildExited" (PCon "Exited" (PLit (LInt 0))))) (PCon "Ok" PWild)) () (EBinOp "==" (EApp (EVar "decodeUtf8") (EVar "bytes")) (EApp (EVar "Some") (ELit (LString "hello"))))) (arm PWild () (EVar "False")))))) (arm PWild () (EVar "False")))) (DoExpr (EApp (EVar "expectTrue") (EVar "result")))))
(DTest false "cancellation wakes a parked read" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit)) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Piped")) (fa "stderr" (EVar "Null"))))) (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5000)))))) (DoLet false false (PVar "started") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/cat"))) (EVar "opts")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "result") (EMatch (EVar "started") (arm (PCon "Ok" (PCon "Started" (PVar "p"))) () (EBlock (DoLet false false (PVar "token") (EApp (EVar "newCancelToken") (ELit LUnit))) (DoLet false false (PVar "reading") (EApp (EApp (EVar "deferThen") (EApp (EVar "spawn") (EApp (EApp (EVar "deferThen") (EApp (EVar "sleep") (EApp (EVar "millis") (ELit (LInt 20))))) (ELam (PWild) (EApp (EVar "liftIO") (ELam (PWild) (EApp (EVar "cancel") (EVar "token")))))))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "readUntil") (EVar "p")) (EVar "ChildStdout")) (ELit (LInt 100))) (EVar "deadline")) (EVar "token"))))) (DoLet false false (PVar "read") (EApp (EVar "runAsync") (EVar "reading"))) (DoLet false false (PVar "closed") (EApp (EVar "closeStdin") (EVar "p"))) (DoLet false false (PVar "exited") (EApp (EVar "runAsync") (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "disposed") (EApp (EVar "dispose") (EVar "p"))) (DoExpr (EMatch (ETuple (EVar "read") (EVar "closed") (EVar "exited") (EVar "disposed")) (arm (PTuple (PCon "Ok" (PCon "ReadCancelled")) (PCon "Ok" PWild) (PCon "Ok" (PCon "ChildExited" (PCon "Exited" (PLit (LInt 0))))) (PCon "Ok" PWild)) () (EVar "True")) (arm PWild () (EVar "False")))))) (arm PWild () (EVar "False")))) (DoExpr (EApp (EVar "expectTrue") (EVar "result")))))
(DTest false "backpressured write returns its committed prefix on timeout" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "sleep 0.3; wc -c")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Piped")) (fa "stderr" (EVar "Null"))))) (DoLet false false (PVar "launchDeadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5000)))))) (DoLet false false (PVar "started") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/sh"))) (EVar "opts")) (EVar "launchDeadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "result") (EMatch (EVar "started") (arm (PCon "Ok" (PCon "Started" (PVar "p"))) () (EBlock (DoLet false false (PVar "bytes") (EApp (EVar "encodeUtf8") (EApp (EApp (EVar "repeat") (ELit (LInt 1000000))) (ELit (LString "x"))))) (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 100)))))) (DoLet false false (PVar "written") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "writeUntil") (EVar "p")) (EVar "bytes")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "closed") (EApp (EVar "closeStdin") (EVar "p"))) (DoLet false false (PVar "observed") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EApp (EVar "readUntil") (EVar "p")) (EVar "ChildStdout")) (ELit (LInt 100))) (EVar "launchDeadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "exited") (EApp (EVar "runAsync") (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "launchDeadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "disposed") (EApp (EVar "dispose") (EVar "p"))) (DoExpr (EMatch (ETuple (EVar "written") (EVar "closed") (EVar "observed") (EVar "exited") (EVar "disposed")) (arm (PTuple (PCon "Ok" (PCon "WriteTimedOut" (PVar "n"))) (PCon "Ok" PWild) (PCon "Ok" (PCon "Read" (PVar "count"))) (PCon "Ok" (PCon "ChildExited" (PCon "Exited" (PLit (LInt 0))))) (PCon "Ok" PWild)) () (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "<" (EVar "n") (ELit (LInt 1000000)))) (EBinOp "==" (EApp (EApp (EVar "map") (EVar "trim")) (EApp (EVar "decodeUtf8") (EVar "count"))) (EApp (EVar "Some") (EApp (EVar "intToString") (EVar "n")))))) (arm PWild () (EVar "False")))))) (arm PWild () (EVar "False")))) (DoExpr (EApp (EVar "expectTrue") (EVar "result")))))
(DTest false "backpressured cancellation retains its committed prefix" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "sleep 0.3; wc -c")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Piped")) (fa "stderr" (EVar "Null"))))) (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5000)))))) (DoLet false false (PVar "started") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/sh"))) (EVar "opts")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "result") (EMatch (EVar "started") (arm (PCon "Ok" (PCon "Started" (PVar "p"))) () (EBlock (DoLet false false (PVar "token") (EApp (EVar "newCancelToken") (ELit LUnit))) (DoLet false false (PVar "bytes") (EApp (EVar "encodeUtf8") (EApp (EApp (EVar "repeat") (ELit (LInt 1000000))) (ELit (LString "x"))))) (DoLet false false (PVar "writing") (EApp (EApp (EVar "deferThen") (EApp (EVar "spawn") (EApp (EApp (EVar "deferThen") (EApp (EVar "sleep") (EApp (EVar "millis") (ELit (LInt 100))))) (ELam (PWild) (EApp (EVar "liftIO") (ELam (PWild) (EApp (EVar "cancel") (EVar "token")))))))) (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "writeUntil") (EVar "p")) (EVar "bytes")) (EVar "deadline")) (EVar "token"))))) (DoLet false false (PVar "written") (EApp (EVar "runAsync") (EVar "writing"))) (DoLet false false (PVar "closed") (EApp (EVar "closeStdin") (EVar "p"))) (DoLet false false (PVar "observed") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EApp (EVar "readUntil") (EVar "p")) (EVar "ChildStdout")) (ELit (LInt 100))) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "exited") (EApp (EVar "runAsync") (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "disposed") (EApp (EVar "dispose") (EVar "p"))) (DoExpr (EMatch (ETuple (EVar "written") (EVar "closed") (EVar "observed") (EVar "exited") (EVar "disposed")) (arm (PTuple (PCon "Ok" (PCon "WriteCancelled" (PVar "n"))) (PCon "Ok" PWild) (PCon "Ok" (PCon "Read" (PVar "count"))) (PCon "Ok" (PCon "ChildExited" (PCon "Exited" (PLit (LInt 0))))) (PCon "Ok" PWild)) () (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "<" (EVar "n") (ELit (LInt 1000000)))) (EBinOp "==" (EApp (EApp (EVar "map") (EVar "trim")) (EApp (EVar "decodeUtf8") (EVar "count"))) (EApp (EVar "Some") (EApp (EVar "intToString") (EVar "n")))))) (arm PWild () (EVar "False")))))) (arm PWild () (EVar "False")))) (DoExpr (EApp (EVar "expectTrue") (EVar "result")))))
(DTypeSig false "yieldSteps" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "yieldSteps" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "deferPure") (ELit LUnit)) (EApp (EApp (EVar "deferThen") (EVar "yield")) (ELam (PWild) (EApp (EVar "yieldSteps") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))))
(DTest false "continuous writable progress yields to cancellation" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "cat >/dev/null")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Null")) (fa "stderr" (EVar "Null"))))) (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5000)))))) (DoLet false false (PVar "started") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/sh"))) (EVar "opts")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "result") (EMatch (EVar "started") (arm (PCon "Ok" (PCon "Started" (PVar "p"))) () (EBlock (DoLet false false (PVar "token") (EApp (EVar "newCancelToken") (ELit LUnit))) (DoLet false false (PVar "bytes") (EApp (EVar "encodeUtf8") (EApp (EApp (EVar "repeat") (ELit (LInt 10000000))) (ELit (LString "x"))))) (DoLet false false (PVar "cancelTask") (EApp (EApp (EVar "deferThen") (EApp (EVar "yieldSteps") (ELit (LInt 30)))) (ELam (PWild) (EApp (EVar "liftIO") (ELam (PWild) (EApp (EVar "cancel") (EVar "token"))))))) (DoLet false false (PVar "writing") (EApp (EApp (EVar "deferThen") (EApp (EVar "spawn") (EVar "cancelTask"))) (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "writeUntil") (EVar "p")) (EVar "bytes")) (EVar "deadline")) (EVar "token"))))) (DoLet false false (PVar "written") (EApp (EVar "runAsync") (EVar "writing"))) (DoLet false false (PVar "closed") (EApp (EVar "closeStdin") (EVar "p"))) (DoLet false false (PVar "exited") (EApp (EVar "runAsync") (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "disposed") (EApp (EVar "dispose") (EVar "p"))) (DoExpr (EMatch (ETuple (EVar "written") (EVar "closed") (EVar "exited") (EVar "disposed")) (arm (PTuple (PCon "Ok" (PCon "WriteCancelled" (PVar "n"))) (PCon "Ok" PWild) (PCon "Ok" (PCon "ChildExited" (PCon "Exited" (PLit (LInt 0))))) (PCon "Ok" PWild)) () (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "<" (EVar "n") (ELit (LInt 10000000))))) (arm PWild () (EVar "False")))))) (arm PWild () (EVar "False")))) (DoExpr (EApp (EVar "expectTrue") (EVar "result")))))
# MARK
(DUse false (UseGroup ("async") ((mem "Async" false) (mem "runAsync" false) (mem "sleep" false) (mem "expiredNow" false) (mem "spawn" false) (mem "liftIO" false) (mem "yield" false))))
(DUse false (UseGroup ("process") ((mem "SpawnOptions" true) (mem "PipeChoice" true) (mem "ExitStatus" true) (mem "OutputStream" true) (mem "closeStdin" false) (mem "dispose" false))))
(DUse false (UseGroup ("process_async") ((mem "newCancelToken" false) (mem "cancel" false) (mem "cancelled" false) (mem "after" false) (mem "deadlineWait" false) (mem "startUntil" false) (mem "waitUntil" false) (mem "WaitResult" true) (mem "readUntil" false) (mem "ReadResult" true) (mem "writeUntil" false) (mem "WriteResult" true) (mem "StartResult" true) (mem "LaunchStop" true))))
(DUse false (UseGroup ("bytes") ((mem "encodeUtf8" false) (mem "decodeUtf8" false))))
(DUse false (UseGroup ("string") ((mem "repeat" false) (mem "trim" false))))
(DUse false (UseGroup ("time") ((mem "millis" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectTrue" false))))
(DTypeSig false "options" (TyCon "SpawnOptions"))
(DFunDef false "options" () (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit)) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Null")) (fa "stdout" (EVar "Null")) (fa "stderr" (EVar "Null")))))
(DTest false "cancel tokens retain cancellation" (EBlock (DoLet false false (PVar "token") (EApp (EVar "newCancelToken") (ELit LUnit))) (DoLet false false (PVar "before") (EApp (EVar "cancelled") (EVar "token"))) (DoExpr (EApp (EVar "cancel") (EVar "token"))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EVar "False") (EVar "True"))) (ETuple (EVar "before") (EApp (EVar "cancelled") (EVar "token")))))))
(DTest false "cancel takes priority over an expired deadline" (EBlock (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt -1)))))) (DoLet false false (PVar "token") (EApp (EVar "newCancelToken") (ELit LUnit))) (DoExpr (EApp (EVar "cancel") (EVar "token"))) (DoLet false false (PVar "result") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/true"))) (EVar "options")) (EVar "deadline")) (EVar "token")))) (DoExpr (EApp (EVar "expectTrue") (EMatch (EVar "result") (arm (PCon "Ok" (PCon "StartCancelled" (PCon "LaunchStopped"))) () (EVar "True")) (arm PWild () (EVar "False")))))))
(DTest false "expired deadline stops before submission" (EBlock (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt -1)))))) (DoLet false false (PVar "result") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/true"))) (EVar "options")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoExpr (EApp (EVar "expectTrue") (EMatch (EVar "result") (arm (PCon "Ok" (PCon "StartTimedOut" (PCon "LaunchStopped"))) () (EVar "True")) (arm PWild () (EVar "False")))))))
(DTest false "deadline wait remains absolute after delayed scheduling" (EBlock (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5)))))) (DoLet false false PWild (EApp (EVar "runAsync") (EApp (EVar "sleep") (EApp (EVar "millis") (ELit (LInt 20)))))) (DoExpr (EApp (EVar "expectTrue") (EApp (EVar "expiredNow") (EApp (EVar "deadlineWait") (EVar "deadline")))))))
(DTest false "launch transfers an owner and observes direct child exit" (EBlock (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5000)))))) (DoLet false false (PVar "outcome") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/true"))) (EVar "options")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "result") (EMatch (EVar "outcome") (arm (PCon "Ok" (PCon "Started" (PVar "p"))) () (EBlock (DoLet false false (PVar "exited") (EApp (EVar "runAsync") (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "disposed") (EApp (EVar "dispose") (EVar "p"))) (DoExpr (EMatch (ETuple (EVar "exited") (EVar "disposed")) (arm (PTuple (PCon "Ok" (PCon "ChildExited" (PCon "Exited" (PLit (LInt 0))))) (PCon "Ok" PWild)) () (EVar "True")) (arm PWild () (EVar "False")))))) (arm PWild () (EVar "False")))) (DoExpr (EApp (EVar "expectTrue") (EVar "result")))))
(DTest false "writes and reads child pipes with exact bytes" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit)) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Piped")) (fa "stderr" (EVar "Null"))))) (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5000)))))) (DoLet false false (PVar "started") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/cat"))) (EVar "opts")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "result") (EMatch (EVar "started") (arm (PCon "Ok" (PCon "Started" (PVar "p"))) () (EBlock (DoLet false false (PVar "empty") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "writeUntil") (EVar "p")) (EApp (EVar "encodeUtf8") (ELit (LString "")))) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "written") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "writeUntil") (EVar "p")) (EApp (EVar "encodeUtf8") (ELit (LString "hello")))) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "closed") (EApp (EVar "closeStdin") (EVar "p"))) (DoLet false false (PVar "read") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EApp (EVar "readUntil") (EVar "p")) (EVar "ChildStdout")) (ELit (LInt 100))) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "exited") (EApp (EVar "runAsync") (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "disposed") (EApp (EVar "dispose") (EVar "p"))) (DoExpr (EMatch (ETuple (EMethodRef "empty") (EVar "written") (EVar "closed") (EVar "read") (EVar "exited") (EVar "disposed")) (arm (PTuple (PCon "Ok" (PCon "Written" (PLit (LInt 0)))) (PCon "Ok" (PCon "Written" (PLit (LInt 5)))) (PCon "Ok" PWild) (PCon "Ok" (PCon "Read" (PVar "bytes"))) (PCon "Ok" (PCon "ChildExited" (PCon "Exited" (PLit (LInt 0))))) (PCon "Ok" PWild)) () (EBinOp "==" (EApp (EVar "decodeUtf8") (EVar "bytes")) (EApp (EVar "Some") (ELit (LString "hello"))))) (arm PWild () (EVar "False")))))) (arm PWild () (EVar "False")))) (DoExpr (EApp (EVar "expectTrue") (EVar "result")))))
(DTest false "cancellation wakes a parked read" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit)) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Piped")) (fa "stderr" (EVar "Null"))))) (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5000)))))) (DoLet false false (PVar "started") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/cat"))) (EVar "opts")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "result") (EMatch (EVar "started") (arm (PCon "Ok" (PCon "Started" (PVar "p"))) () (EBlock (DoLet false false (PVar "token") (EApp (EVar "newCancelToken") (ELit LUnit))) (DoLet false false (PVar "reading") (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "spawn") (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "sleep") (EApp (EVar "millis") (ELit (LInt 20))))) (ELam (PWild) (EApp (EVar "liftIO") (ELam (PWild) (EApp (EVar "cancel") (EVar "token")))))))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "readUntil") (EVar "p")) (EVar "ChildStdout")) (ELit (LInt 100))) (EVar "deadline")) (EVar "token"))))) (DoLet false false (PVar "read") (EApp (EVar "runAsync") (EVar "reading"))) (DoLet false false (PVar "closed") (EApp (EVar "closeStdin") (EVar "p"))) (DoLet false false (PVar "exited") (EApp (EVar "runAsync") (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "disposed") (EApp (EVar "dispose") (EVar "p"))) (DoExpr (EMatch (ETuple (EVar "read") (EVar "closed") (EVar "exited") (EVar "disposed")) (arm (PTuple (PCon "Ok" (PCon "ReadCancelled")) (PCon "Ok" PWild) (PCon "Ok" (PCon "ChildExited" (PCon "Exited" (PLit (LInt 0))))) (PCon "Ok" PWild)) () (EVar "True")) (arm PWild () (EVar "False")))))) (arm PWild () (EVar "False")))) (DoExpr (EApp (EVar "expectTrue") (EVar "result")))))
(DTest false "backpressured write returns its committed prefix on timeout" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "sleep 0.3; wc -c")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Piped")) (fa "stderr" (EVar "Null"))))) (DoLet false false (PVar "launchDeadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5000)))))) (DoLet false false (PVar "started") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/sh"))) (EVar "opts")) (EVar "launchDeadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "result") (EMatch (EVar "started") (arm (PCon "Ok" (PCon "Started" (PVar "p"))) () (EBlock (DoLet false false (PVar "bytes") (EApp (EVar "encodeUtf8") (EApp (EApp (EVar "repeat") (ELit (LInt 1000000))) (ELit (LString "x"))))) (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 100)))))) (DoLet false false (PVar "written") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "writeUntil") (EVar "p")) (EVar "bytes")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "closed") (EApp (EVar "closeStdin") (EVar "p"))) (DoLet false false (PVar "observed") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EApp (EVar "readUntil") (EVar "p")) (EVar "ChildStdout")) (ELit (LInt 100))) (EVar "launchDeadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "exited") (EApp (EVar "runAsync") (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "launchDeadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "disposed") (EApp (EVar "dispose") (EVar "p"))) (DoExpr (EMatch (ETuple (EVar "written") (EVar "closed") (EVar "observed") (EVar "exited") (EVar "disposed")) (arm (PTuple (PCon "Ok" (PCon "WriteTimedOut" (PVar "n"))) (PCon "Ok" PWild) (PCon "Ok" (PCon "Read" (PVar "count"))) (PCon "Ok" (PCon "ChildExited" (PCon "Exited" (PLit (LInt 0))))) (PCon "Ok" PWild)) () (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "<" (EVar "n") (ELit (LInt 1000000)))) (EBinOp "==" (EApp (EApp (EMethodRef "map") (EVar "trim")) (EApp (EVar "decodeUtf8") (EDictApp "count"))) (EApp (EVar "Some") (EApp (EVar "intToString") (EVar "n")))))) (arm PWild () (EVar "False")))))) (arm PWild () (EVar "False")))) (DoExpr (EApp (EVar "expectTrue") (EVar "result")))))
(DTest false "backpressured cancellation retains its committed prefix" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "sleep 0.3; wc -c")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Piped")) (fa "stderr" (EVar "Null"))))) (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5000)))))) (DoLet false false (PVar "started") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/sh"))) (EVar "opts")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "result") (EMatch (EVar "started") (arm (PCon "Ok" (PCon "Started" (PVar "p"))) () (EBlock (DoLet false false (PVar "token") (EApp (EVar "newCancelToken") (ELit LUnit))) (DoLet false false (PVar "bytes") (EApp (EVar "encodeUtf8") (EApp (EApp (EVar "repeat") (ELit (LInt 1000000))) (ELit (LString "x"))))) (DoLet false false (PVar "writing") (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "spawn") (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "sleep") (EApp (EVar "millis") (ELit (LInt 100))))) (ELam (PWild) (EApp (EVar "liftIO") (ELam (PWild) (EApp (EVar "cancel") (EVar "token")))))))) (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "writeUntil") (EVar "p")) (EVar "bytes")) (EVar "deadline")) (EVar "token"))))) (DoLet false false (PVar "written") (EApp (EVar "runAsync") (EVar "writing"))) (DoLet false false (PVar "closed") (EApp (EVar "closeStdin") (EVar "p"))) (DoLet false false (PVar "observed") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EApp (EVar "readUntil") (EVar "p")) (EVar "ChildStdout")) (ELit (LInt 100))) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "exited") (EApp (EVar "runAsync") (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "disposed") (EApp (EVar "dispose") (EVar "p"))) (DoExpr (EMatch (ETuple (EVar "written") (EVar "closed") (EVar "observed") (EVar "exited") (EVar "disposed")) (arm (PTuple (PCon "Ok" (PCon "WriteCancelled" (PVar "n"))) (PCon "Ok" PWild) (PCon "Ok" (PCon "Read" (PVar "count"))) (PCon "Ok" (PCon "ChildExited" (PCon "Exited" (PLit (LInt 0))))) (PCon "Ok" PWild)) () (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "<" (EVar "n") (ELit (LInt 1000000)))) (EBinOp "==" (EApp (EApp (EMethodRef "map") (EVar "trim")) (EApp (EVar "decodeUtf8") (EDictApp "count"))) (EApp (EVar "Some") (EApp (EVar "intToString") (EVar "n")))))) (arm PWild () (EVar "False")))))) (arm PWild () (EVar "False")))) (DoExpr (EApp (EVar "expectTrue") (EVar "result")))))
(DTypeSig false "yieldSteps" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "yieldSteps" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EMethodRef "deferPure") (ELit LUnit)) (EApp (EApp (EMethodRef "deferThen") (EVar "yield")) (ELam (PWild) (EApp (EVar "yieldSteps") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))))
(DTest false "continuous writable progress yields to cancellation" (EBlock (DoLet false false (PVar "opts") (ERecordCreate "SpawnOptions" ((fa "argv" (EListLit (ELit (LString "-c")) (ELit (LString "cat >/dev/null")))) (fa "cwd" (ELit (LString "/tmp"))) (fa "env" (EListLit)) (fa "stdin" (EVar "Piped")) (fa "stdout" (EVar "Null")) (fa "stderr" (EVar "Null"))))) (DoLet false false (PVar "deadline") (EApp (EVar "runAsync") (EApp (EVar "after") (EApp (EVar "millis") (ELit (LInt 5000)))))) (DoLet false false (PVar "started") (EApp (EVar "runAsync") (EApp (EApp (EApp (EApp (EVar "startUntil") (ELit (LString "/bin/sh"))) (EVar "opts")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "result") (EMatch (EVar "started") (arm (PCon "Ok" (PCon "Started" (PVar "p"))) () (EBlock (DoLet false false (PVar "token") (EApp (EVar "newCancelToken") (ELit LUnit))) (DoLet false false (PVar "bytes") (EApp (EVar "encodeUtf8") (EApp (EApp (EVar "repeat") (ELit (LInt 10000000))) (ELit (LString "x"))))) (DoLet false false (PVar "cancelTask") (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "yieldSteps") (ELit (LInt 30)))) (ELam (PWild) (EApp (EVar "liftIO") (ELam (PWild) (EApp (EVar "cancel") (EVar "token"))))))) (DoLet false false (PVar "writing") (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "spawn") (EVar "cancelTask"))) (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "writeUntil") (EVar "p")) (EVar "bytes")) (EVar "deadline")) (EVar "token"))))) (DoLet false false (PVar "written") (EApp (EVar "runAsync") (EVar "writing"))) (DoLet false false (PVar "closed") (EApp (EVar "closeStdin") (EVar "p"))) (DoLet false false (PVar "exited") (EApp (EVar "runAsync") (EApp (EApp (EApp (EVar "waitUntil") (EVar "p")) (EVar "deadline")) (EApp (EVar "newCancelToken") (ELit LUnit))))) (DoLet false false (PVar "disposed") (EApp (EVar "dispose") (EVar "p"))) (DoExpr (EMatch (ETuple (EVar "written") (EVar "closed") (EVar "exited") (EVar "disposed")) (arm (PTuple (PCon "Ok" (PCon "WriteCancelled" (PVar "n"))) (PCon "Ok" PWild) (PCon "Ok" (PCon "ChildExited" (PCon "Exited" (PLit (LInt 0))))) (PCon "Ok" PWild)) () (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "<" (EVar "n") (ELit (LInt 10000000))))) (arm PWild () (EVar "False")))))) (arm PWild () (EVar "False")))) (DoExpr (EApp (EVar "expectTrue") (EVar "result")))))
