# META
source_lines=217
stages=DESUGAR,MARK
# SOURCE
-- net_async.mdk — the non-blocking half of `net`, over the async scheduler.
--
-- Every operation here tries its syscall, and on would-block parks the task
-- with `awaitAny` until the descriptor is ready, then retries.  Readiness is
-- level-triggered, so a retry after any wake is correct.  The socket is
-- switched to non-blocking mode by `accept`; a `Connection` from the blocking
-- `net.connect` is switched on first use.  Deadlines are a wait set of the
-- descriptor plus a `WaitUntil`; the task itself decides to give up, so no
-- task is ever dropped (docs/design/ASYNC-RUNTIME-DESIGN.md §0a).

import array.{drop}
import async.{Async, Wait(..), liftIO, spawn, awaitAny, deadlineAfter, expired}
import net.{Connection(..), Listener(..)}
import net as N
import string.{toUtf8}
import time.{Duration}

{- | TCP over the async scheduler: the `net` operations that park instead of
   blocking, so many connections share one thread.

   `accept`, `recv`, `send`, and `sendAll` mirror their `net` namesakes but
   return `Async` values that park until the socket is ready. `recvWithin`
   and `sendAllWithin` give up after a `Duration` with `Err "timed out"`.
   `serve` is an accept loop that runs each connection's handler as its
   own task and closes the connection when the handler finishes. Use
   `import net_async as A` and call `A.accept`, `A.recv`, and so on.

   Every operation performs `<Net "_">`, and the deadline forms also read
   the clock. Drive the program with `runAsyncIO` or a `main : Async e Unit`.
   Networking works only in a program built for the native target. -}

-- | Accepts the next connection, parking until one arrives. The listener
-- and the accepted socket are switched to non-blocking mode.
export
accept : Listener -> Async <Net "_" | e> (Result String Connection)
accept lis =
  deferThen (liftIO (u => tryAccept lis)) (step => acceptStep lis step)

tryAccept : Listener -> <Net "_"> Result String (Option Connection)
tryAccept (Listener fd) = match netSetNonblock fd True
  Ok _ => match netTryAccept fd
    Ok (Some c) => map (_ => Some (Connection c)) (netSetNonblock c True)
    Ok None => Ok None
    Err e => Err e
  Err e => Err e

acceptStep : Listener ->
  Result String (Option Connection) ->
  Async <Net "_" | e> (Result String Connection)
acceptStep (Listener fd) (Ok None) =
  deferThen (awaitAny [WaitRead fd]) (_ => accept (Listener fd))
acceptStep _ (Ok (Some c)) = deferPure (Ok c)
acceptStep _ (Err e) = deferPure (Err e)

-- | Receives up to `n` bytes, parking until some arrive. An empty array is
-- end of stream.
export
recv : Connection -> Int -> Async <Net "_" | e> (Result String (Array Int))
recv conn n =
  deferThen (liftIO (u => tryRecv conn n)) (step => recvStep conn n step)

tryRecv : Connection -> Int -> <Net "_"> Result String (Option (Array Int))
tryRecv (Connection fd) n = match netSetNonblock fd True
  Ok _ => netTryRecv fd n
  Err e => Err e

recvStep : Connection ->
  Int ->
  Result String (Option (Array Int)) ->
  Async <Net "_" | e> (Result String (Array Int))
recvStep (Connection fd) n (Ok None) =
  deferThen (awaitAny [WaitRead fd]) (_ => recv (Connection fd) n)
recvStep _ _ (Ok (Some bs)) = deferPure (Ok bs)
recvStep _ _ (Err e) = deferPure (Err e)

-- | `recv` that gives up after `d` with `Err "timed out"`.
export
recvWithin : Duration ->
  Connection ->
  Int ->
  Async <Clock, Net "_" | e> (Result String (Array Int))
recvWithin d conn n = deferThen (deadlineAfter d) (dl => recvUntil dl conn n)

recvUntil : Wait ->
  Connection ->
  Int ->
  Async <Clock, Net "_" | e> (Result String (Array Int))
recvUntil dl conn n = deferThen (liftIO (u => tryRecv conn n)) (step =>
  recvUntilStep dl conn n step)

recvUntilStep : Wait ->
  Connection ->
  Int ->
  Result String (Option (Array Int)) ->
  Async <Clock, Net "_" | e> (Result String (Array Int))
recvUntilStep dl (Connection fd) n (Ok None) = deferThen (expired dl) (late =>
  if late then
    deferPure (Err "timed out")
  else
    deferThen (awaitAny [WaitRead fd, dl]) (_ =>
      recvUntil dl (Connection fd) n))
recvUntilStep _ _ _ (Ok (Some bs)) = deferPure (Ok bs)
recvUntilStep _ _ _ (Err e) = deferPure (Err e)

-- | Sends what the socket will take now, parking until it takes some.
-- The count may be short; `sendAll` loops.
export
send : Connection -> Array Int -> Async <Net "_" | e> (Result String Int)
send conn bytes = deferThen (liftIO (u => trySend conn bytes)) (step =>
  sendStep conn bytes step)

trySend : Connection -> Array Int -> <Net "_"> Result String (Option Int)
trySend (Connection fd) bytes = match netSetNonblock fd True
  Ok _ => netTrySend fd bytes
  Err e => Err e

sendStep : Connection ->
  Array Int ->
  Result String (Option Int) ->
  Async <Net "_" | e> (Result String Int)
sendStep (Connection fd) bytes (Ok None) =
  deferThen (awaitAny [WaitWrite fd]) (_ => send (Connection fd) bytes)
sendStep _ _ (Ok (Some n)) = deferPure (Ok n)
sendStep _ _ (Err e) = deferPure (Err e)

-- | Sends every byte, parking as needed.
export
sendAll : Connection -> Array Int -> Async <Net "_" | e> (Result String Unit)
sendAll conn bytes =
  if length bytes == 0 then
    deferPure (Ok ())
  else
    deferThen (send conn bytes) (r => sendAllStep conn bytes r)

sendAllStep : Connection ->
  Array Int ->
  Result String Int ->
  Async <Net "_" | e> (Result String Unit)
sendAllStep conn bytes (Ok n) = sendAll conn (drop n bytes)
sendAllStep _ _ (Err e) = deferPure (Err e)

-- | `sendAll` that gives up after `d` with `Err "timed out"`.
export
sendAllWithin : Duration ->
  Connection ->
  Array Int ->
  Async <Clock, Net "_" | e> (Result String Unit)
sendAllWithin d conn bytes =
  deferThen (deadlineAfter d) (dl => sendUntil dl conn bytes)

sendUntil : Wait ->
  Connection ->
  Array Int ->
  Async <Clock, Net "_" | e> (Result String Unit)
sendUntil dl conn bytes =
  if length bytes == 0 then
    deferPure (Ok ())
  else
    deferThen (liftIO (u => trySend conn bytes)) (step =>
      sendUntilStep dl conn bytes step)

sendUntilStep : Wait ->
  Connection ->
  Array Int ->
  Result String (Option Int) ->
  Async <Clock, Net "_" | e> (Result String Unit)
sendUntilStep dl (Connection fd) bytes (Ok None) = deferThen (expired
  dl) (late =>
  if late then
    deferPure (Err "timed out")
  else
    deferThen (awaitAny [WaitWrite fd, dl]) (_ =>
      sendUntil dl (Connection fd) bytes))
sendUntilStep dl conn bytes (Ok (Some n)) = sendUntil dl conn (drop n bytes)
sendUntilStep _ _ _ (Err e) = deferPure (Err e)

-- | Sends a string as UTF-8, parking as needed.
export
sendString : Connection -> String -> Async <Net "_" | e> (Result String Unit)
sendString conn s = sendAll conn (toUtf8 s)

-- | Closes a connection.
export
close : Connection -> Async <Net "_" | e> (Result String Unit)
close conn = liftIO (u => N.close conn)

-- | Closes a listener. A task parked in `accept` on it wakes with an error,
-- which ends a `serve` loop.
export
closeListener : Listener -> Async <Net "_" | e> (Result String Unit)
closeListener lis = liftIO (u => N.closeListener lis)

{- | Accepts connections until `accept` fails, running `handle` on each in
   a task of its own and closing the connection when the handler finishes.

   A failure in `handle` closes that connection and the loop continues. A
   failure in `accept`, including the listener being closed, ends the loop
   with the error. -}
export
serve : Listener ->
  (Connection -> Async <Net "_" | e> (Result String Unit)) ->
  Async <Net "_" | e> (Result String Unit)
serve lis handle = deferThen (accept lis) (r => serveStep lis handle r)

serveStep : Listener ->
  (Connection -> Async <Net "_" | e> (Result String Unit)) ->
  Result String Connection ->
  Async <Net "_" | e> (Result String Unit)
serveStep lis handle (Ok conn) =
  deferThen (spawn (handleThenClose handle conn)) (_ => serve lis handle)
serveStep _ _ (Err e) = deferPure (Err e)

handleThenClose : (Connection -> Async <Net "_" | e> (Result String Unit)) ->
  Connection ->
  Async <Net "_" | e> Unit
handleThenClose handle conn =
  deferThen (handle conn) (_ => deferMap (_ => ()) (close conn))
# DESUGAR
(DUse false (UseGroup ("array") ((mem "drop" false))))
(DUse false (UseGroup ("async") ((mem "Async" false) (mem "Wait" true) (mem "liftIO" false) (mem "spawn" false) (mem "awaitAny" false) (mem "deadlineAfter" false) (mem "expired" false))))
(DUse false (UseGroup ("net") ((mem "Connection" true) (mem "Listener" true))))
(DUse false (UseAlias ("net") "N"))
(DUse false (UseGroup ("string") ((mem "toUtf8" false))))
(DUse false (UseGroup ("time") ((mem "Duration" false))))
(DTypeSig true "accept" (TyFun (TyCon "Listener") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Connection")))))
(DFunDef false "accept" ((PVar "lis")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "tryAccept") (EVar "lis"))))) (ELam ((PVar "step")) (EApp (EApp (EVar "acceptStep") (EVar "lis")) (EVar "step")))))
(DTypeSig false "tryAccept" (TyFun (TyCon "Listener") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Connection"))))))
(DFunDef false "tryAccept" ((PCon "Listener" (PVar "fd"))) (EMatch (EApp (EApp (EVar "netSetNonblock") (EVar "fd")) (EVar "True")) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "netTryAccept") (EVar "fd")) (arm (PCon "Ok" (PCon "Some" (PVar "c"))) () (EApp (EApp (EVar "map") (ELam (PWild) (EApp (EVar "Some") (EApp (EVar "Connection") (EVar "c"))))) (EApp (EApp (EVar "netSetNonblock") (EVar "c")) (EVar "True")))) (arm (PCon "Ok" (PCon "None")) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "acceptStep" (TyFun (TyCon "Listener") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Connection"))) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Connection"))))))
(DFunDef false "acceptStep" ((PCon "Listener" (PVar "fd")) (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "WaitRead") (EVar "fd"))))) (ELam (PWild) (EApp (EVar "accept") (EApp (EVar "Listener") (EVar "fd"))))))
(DFunDef false "acceptStep" (PWild (PCon "Ok" (PCon "Some" (PVar "c")))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "c"))))
(DFunDef false "acceptStep" (PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "recv" (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "recv" ((PVar "conn") (PVar "n")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EVar "tryRecv") (EVar "conn")) (EVar "n"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EVar "recvStep") (EVar "conn")) (EVar "n")) (EVar "step")))))
(DTypeSig false "tryRecv" (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "tryRecv" ((PCon "Connection" (PVar "fd")) (PVar "n")) (EMatch (EApp (EApp (EVar "netSetNonblock") (EVar "fd")) (EVar "True")) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "netTryRecv") (EVar "fd")) (EVar "n"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "recvStep" (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "recvStep" ((PCon "Connection" (PVar "fd")) (PVar "n") (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "WaitRead") (EVar "fd"))))) (ELam (PWild) (EApp (EApp (EVar "recv") (EApp (EVar "Connection") (EVar "fd"))) (EVar "n")))))
(DFunDef false "recvStep" (PWild PWild (PCon "Ok" (PCon "Some" (PVar "bs")))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "bs"))))
(DFunDef false "recvStep" (PWild PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "recvWithin" (TyFun (TyCon "Duration") (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "recvWithin" ((PVar "d") (PVar "conn") (PVar "n")) (EApp (EApp (EVar "deferThen") (EApp (EVar "deadlineAfter") (EVar "d"))) (ELam ((PVar "dl")) (EApp (EApp (EApp (EVar "recvUntil") (EVar "dl")) (EVar "conn")) (EVar "n")))))
(DTypeSig false "recvUntil" (TyFun (TyCon "Wait") (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "recvUntil" ((PVar "dl") (PVar "conn") (PVar "n")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EVar "tryRecv") (EVar "conn")) (EVar "n"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EApp (EVar "recvUntilStep") (EVar "dl")) (EVar "conn")) (EVar "n")) (EVar "step")))))
(DTypeSig false "recvUntilStep" (TyFun (TyCon "Wait") (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))))
(DFunDef false "recvUntilStep" ((PVar "dl") (PCon "Connection" (PVar "fd")) (PVar "n") (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "expired") (EVar "dl"))) (ELam ((PVar "late")) (EIf (EVar "late") (EApp (EVar "deferPure") (EApp (EVar "Err") (ELit (LString "timed out")))) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "WaitRead") (EVar "fd")) (EVar "dl")))) (ELam (PWild) (EApp (EApp (EApp (EVar "recvUntil") (EVar "dl")) (EApp (EVar "Connection") (EVar "fd"))) (EVar "n"))))))))
(DFunDef false "recvUntilStep" (PWild PWild PWild (PCon "Ok" (PCon "Some" (PVar "bs")))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "bs"))))
(DFunDef false "recvUntilStep" (PWild PWild PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "send" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "send" ((PVar "conn") (PVar "bytes")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EVar "trySend") (EVar "conn")) (EVar "bytes"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EVar "sendStep") (EVar "conn")) (EVar "bytes")) (EVar "step")))))
(DTypeSig false "trySend" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "trySend" ((PCon "Connection" (PVar "fd")) (PVar "bytes")) (EMatch (EApp (EApp (EVar "netSetNonblock") (EVar "fd")) (EVar "True")) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "netTrySend") (EVar "fd")) (EVar "bytes"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "sendStep" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "sendStep" ((PCon "Connection" (PVar "fd")) (PVar "bytes") (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "WaitWrite") (EVar "fd"))))) (ELam (PWild) (EApp (EApp (EVar "send") (EApp (EVar "Connection") (EVar "fd"))) (EVar "bytes")))))
(DFunDef false "sendStep" (PWild PWild (PCon "Ok" (PCon "Some" (PVar "n")))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "n"))))
(DFunDef false "sendStep" (PWild PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "sendAll" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendAll" ((PVar "conn") (PVar "bytes")) (EIf (EBinOp "==" (EApp (EVar "length") (EVar "bytes")) (ELit (LInt 0))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (ELit LUnit))) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "send") (EVar "conn")) (EVar "bytes"))) (ELam ((PVar "r")) (EApp (EApp (EApp (EVar "sendAllStep") (EVar "conn")) (EVar "bytes")) (EVar "r"))))))
(DTypeSig false "sendAllStep" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "sendAllStep" ((PVar "conn") (PVar "bytes") (PCon "Ok" (PVar "n"))) (EApp (EApp (EVar "sendAll") (EVar "conn")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "bytes"))))
(DFunDef false "sendAllStep" (PWild PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "sendAllWithin" (TyFun (TyCon "Duration") (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "sendAllWithin" ((PVar "d") (PVar "conn") (PVar "bytes")) (EApp (EApp (EVar "deferThen") (EApp (EVar "deadlineAfter") (EVar "d"))) (ELam ((PVar "dl")) (EApp (EApp (EApp (EVar "sendUntil") (EVar "dl")) (EVar "conn")) (EVar "bytes")))))
(DTypeSig false "sendUntil" (TyFun (TyCon "Wait") (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "sendUntil" ((PVar "dl") (PVar "conn") (PVar "bytes")) (EIf (EBinOp "==" (EApp (EVar "length") (EVar "bytes")) (ELit (LInt 0))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (ELit LUnit))) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EVar "trySend") (EVar "conn")) (EVar "bytes"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EApp (EVar "sendUntilStep") (EVar "dl")) (EVar "conn")) (EVar "bytes")) (EVar "step"))))))
(DTypeSig false "sendUntilStep" (TyFun (TyCon "Wait") (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))))
(DFunDef false "sendUntilStep" ((PVar "dl") (PCon "Connection" (PVar "fd")) (PVar "bytes") (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "expired") (EVar "dl"))) (ELam ((PVar "late")) (EIf (EVar "late") (EApp (EVar "deferPure") (EApp (EVar "Err") (ELit (LString "timed out")))) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "WaitWrite") (EVar "fd")) (EVar "dl")))) (ELam (PWild) (EApp (EApp (EApp (EVar "sendUntil") (EVar "dl")) (EApp (EVar "Connection") (EVar "fd"))) (EVar "bytes"))))))))
(DFunDef false "sendUntilStep" ((PVar "dl") (PVar "conn") (PVar "bytes") (PCon "Ok" (PCon "Some" (PVar "n")))) (EApp (EApp (EApp (EVar "sendUntil") (EVar "dl")) (EVar "conn")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "bytes"))))
(DFunDef false "sendUntilStep" (PWild PWild PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "sendString" (TyFun (TyCon "Connection") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendString" ((PVar "conn") (PVar "s")) (EApp (EApp (EVar "sendAll") (EVar "conn")) (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig true "close" (TyFun (TyCon "Connection") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "close" ((PVar "conn")) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "N.close") (EVar "conn")))))
(DTypeSig true "closeListener" (TyFun (TyCon "Listener") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "closeListener" ((PVar "lis")) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "N.closeListener") (EVar "lis")))))
(DTypeSig true "serve" (TyFun (TyCon "Listener") (TyFun (TyFun (TyCon "Connection") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "serve" ((PVar "lis") (PVar "handle")) (EApp (EApp (EVar "deferThen") (EApp (EVar "accept") (EVar "lis"))) (ELam ((PVar "r")) (EApp (EApp (EApp (EVar "serveStep") (EVar "lis")) (EVar "handle")) (EVar "r")))))
(DTypeSig false "serveStep" (TyFun (TyCon "Listener") (TyFun (TyFun (TyCon "Connection") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Connection")) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "serveStep" ((PVar "lis") (PVar "handle") (PCon "Ok" (PVar "conn"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "spawn") (EApp (EApp (EVar "handleThenClose") (EVar "handle")) (EVar "conn")))) (ELam (PWild) (EApp (EApp (EVar "serve") (EVar "lis")) (EVar "handle")))))
(DFunDef false "serveStep" (PWild PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig false "handleThenClose" (TyFun (TyFun (TyCon "Connection") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyFun (TyCon "Connection") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyCon "Unit")))))
(DFunDef false "handleThenClose" ((PVar "handle") (PVar "conn")) (EApp (EApp (EVar "deferThen") (EApp (EVar "handle") (EVar "conn"))) (ELam (PWild) (EApp (EApp (EVar "deferMap") (ELam (PWild) (ELit LUnit))) (EApp (EVar "close") (EVar "conn"))))))
# MARK
(DUse false (UseGroup ("array") ((mem "drop" false))))
(DUse false (UseGroup ("async") ((mem "Async" false) (mem "Wait" true) (mem "liftIO" false) (mem "spawn" false) (mem "awaitAny" false) (mem "deadlineAfter" false) (mem "expired" false))))
(DUse false (UseGroup ("net") ((mem "Connection" true) (mem "Listener" true))))
(DUse false (UseAlias ("net") "N"))
(DUse false (UseGroup ("string") ((mem "toUtf8" false))))
(DUse false (UseGroup ("time") ((mem "Duration" false))))
(DTypeSig true "accept" (TyFun (TyCon "Listener") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Connection")))))
(DFunDef false "accept" ((PVar "lis")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "tryAccept") (EVar "lis"))))) (ELam ((PVar "step")) (EApp (EApp (EVar "acceptStep") (EVar "lis")) (EVar "step")))))
(DTypeSig false "tryAccept" (TyFun (TyCon "Listener") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Connection"))))))
(DFunDef false "tryAccept" ((PCon "Listener" (PVar "fd"))) (EMatch (EApp (EApp (EVar "netSetNonblock") (EVar "fd")) (EVar "True")) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "netTryAccept") (EVar "fd")) (arm (PCon "Ok" (PCon "Some" (PVar "c"))) () (EApp (EApp (EMethodRef "map") (ELam (PWild) (EApp (EVar "Some") (EApp (EVar "Connection") (EVar "c"))))) (EApp (EApp (EVar "netSetNonblock") (EVar "c")) (EVar "True")))) (arm (PCon "Ok" (PCon "None")) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "acceptStep" (TyFun (TyCon "Listener") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Connection"))) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Connection"))))))
(DFunDef false "acceptStep" ((PCon "Listener" (PVar "fd")) (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "WaitRead") (EVar "fd"))))) (ELam (PWild) (EApp (EVar "accept") (EApp (EVar "Listener") (EVar "fd"))))))
(DFunDef false "acceptStep" (PWild (PCon "Ok" (PCon "Some" (PVar "c")))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "c"))))
(DFunDef false "acceptStep" (PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "recv" (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "recv" ((PVar "conn") (PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EVar "tryRecv") (EVar "conn")) (EVar "n"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EVar "recvStep") (EVar "conn")) (EVar "n")) (EVar "step")))))
(DTypeSig false "tryRecv" (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "tryRecv" ((PCon "Connection" (PVar "fd")) (PVar "n")) (EMatch (EApp (EApp (EVar "netSetNonblock") (EVar "fd")) (EVar "True")) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "netTryRecv") (EVar "fd")) (EVar "n"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "recvStep" (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "recvStep" ((PCon "Connection" (PVar "fd")) (PVar "n") (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "WaitRead") (EVar "fd"))))) (ELam (PWild) (EApp (EApp (EVar "recv") (EApp (EVar "Connection") (EVar "fd"))) (EVar "n")))))
(DFunDef false "recvStep" (PWild PWild (PCon "Ok" (PCon "Some" (PVar "bs")))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "bs"))))
(DFunDef false "recvStep" (PWild PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "recvWithin" (TyFun (TyCon "Duration") (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "recvWithin" ((PVar "d") (PVar "conn") (PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "deadlineAfter") (EVar "d"))) (ELam ((PVar "dl")) (EApp (EApp (EApp (EVar "recvUntil") (EVar "dl")) (EVar "conn")) (EVar "n")))))
(DTypeSig false "recvUntil" (TyFun (TyCon "Wait") (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "recvUntil" ((PVar "dl") (PVar "conn") (PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EVar "tryRecv") (EVar "conn")) (EVar "n"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EApp (EVar "recvUntilStep") (EVar "dl")) (EVar "conn")) (EVar "n")) (EVar "step")))))
(DTypeSig false "recvUntilStep" (TyFun (TyCon "Wait") (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))))
(DFunDef false "recvUntilStep" ((PVar "dl") (PCon "Connection" (PVar "fd")) (PVar "n") (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expired") (EVar "dl"))) (ELam ((PVar "late")) (EIf (EVar "late") (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (ELit (LString "timed out")))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "WaitRead") (EVar "fd")) (EVar "dl")))) (ELam (PWild) (EApp (EApp (EApp (EVar "recvUntil") (EVar "dl")) (EApp (EVar "Connection") (EVar "fd"))) (EVar "n"))))))))
(DFunDef false "recvUntilStep" (PWild PWild PWild (PCon "Ok" (PCon "Some" (PVar "bs")))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "bs"))))
(DFunDef false "recvUntilStep" (PWild PWild PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "send" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "send" ((PVar "conn") (PVar "bytes")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EVar "trySend") (EVar "conn")) (EVar "bytes"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EVar "sendStep") (EVar "conn")) (EVar "bytes")) (EVar "step")))))
(DTypeSig false "trySend" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "trySend" ((PCon "Connection" (PVar "fd")) (PVar "bytes")) (EMatch (EApp (EApp (EVar "netSetNonblock") (EVar "fd")) (EVar "True")) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "netTrySend") (EVar "fd")) (EVar "bytes"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "sendStep" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "sendStep" ((PCon "Connection" (PVar "fd")) (PVar "bytes") (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "WaitWrite") (EVar "fd"))))) (ELam (PWild) (EApp (EApp (EVar "send") (EApp (EVar "Connection") (EVar "fd"))) (EVar "bytes")))))
(DFunDef false "sendStep" (PWild PWild (PCon "Ok" (PCon "Some" (PVar "n")))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "n"))))
(DFunDef false "sendStep" (PWild PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "sendAll" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendAll" ((PVar "conn") (PVar "bytes")) (EIf (EBinOp "==" (EApp (EMethodRef "length") (EVar "bytes")) (ELit (LInt 0))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (ELit LUnit))) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "send") (EVar "conn")) (EVar "bytes"))) (ELam ((PVar "r")) (EApp (EApp (EApp (EVar "sendAllStep") (EVar "conn")) (EVar "bytes")) (EVar "r"))))))
(DTypeSig false "sendAllStep" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "sendAllStep" ((PVar "conn") (PVar "bytes") (PCon "Ok" (PVar "n"))) (EApp (EApp (EVar "sendAll") (EVar "conn")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "bytes"))))
(DFunDef false "sendAllStep" (PWild PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "sendAllWithin" (TyFun (TyCon "Duration") (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "sendAllWithin" ((PVar "d") (PVar "conn") (PVar "bytes")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "deadlineAfter") (EVar "d"))) (ELam ((PVar "dl")) (EApp (EApp (EApp (EVar "sendUntil") (EVar "dl")) (EVar "conn")) (EVar "bytes")))))
(DTypeSig false "sendUntil" (TyFun (TyCon "Wait") (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "sendUntil" ((PVar "dl") (PVar "conn") (PVar "bytes")) (EIf (EBinOp "==" (EApp (EMethodRef "length") (EVar "bytes")) (ELit (LInt 0))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (ELit LUnit))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EVar "trySend") (EVar "conn")) (EVar "bytes"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EApp (EVar "sendUntilStep") (EVar "dl")) (EVar "conn")) (EVar "bytes")) (EVar "step"))))))
(DTypeSig false "sendUntilStep" (TyFun (TyCon "Wait") (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))))
(DFunDef false "sendUntilStep" ((PVar "dl") (PCon "Connection" (PVar "fd")) (PVar "bytes") (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expired") (EVar "dl"))) (ELam ((PVar "late")) (EIf (EVar "late") (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (ELit (LString "timed out")))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "WaitWrite") (EVar "fd")) (EVar "dl")))) (ELam (PWild) (EApp (EApp (EApp (EVar "sendUntil") (EVar "dl")) (EApp (EVar "Connection") (EVar "fd"))) (EVar "bytes"))))))))
(DFunDef false "sendUntilStep" ((PVar "dl") (PVar "conn") (PVar "bytes") (PCon "Ok" (PCon "Some" (PVar "n")))) (EApp (EApp (EApp (EVar "sendUntil") (EVar "dl")) (EVar "conn")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "bytes"))))
(DFunDef false "sendUntilStep" (PWild PWild PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "sendString" (TyFun (TyCon "Connection") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendString" ((PVar "conn") (PVar "s")) (EApp (EApp (EVar "sendAll") (EVar "conn")) (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig true "close" (TyFun (TyCon "Connection") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "close" ((PVar "conn")) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "N.close") (EVar "conn")))))
(DTypeSig true "closeListener" (TyFun (TyCon "Listener") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "closeListener" ((PVar "lis")) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "N.closeListener") (EVar "lis")))))
(DTypeSig true "serve" (TyFun (TyCon "Listener") (TyFun (TyFun (TyCon "Connection") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "serve" ((PVar "lis") (PVar "handle")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "accept") (EVar "lis"))) (ELam ((PVar "r")) (EApp (EApp (EApp (EVar "serveStep") (EVar "lis")) (EVar "handle")) (EVar "r")))))
(DTypeSig false "serveStep" (TyFun (TyCon "Listener") (TyFun (TyFun (TyCon "Connection") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Connection")) (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "serveStep" ((PVar "lis") (PVar "handle") (PCon "Ok" (PVar "conn"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "spawn") (EApp (EApp (EVar "handleThenClose") (EVar "handle")) (EVar "conn")))) (ELam (PWild) (EApp (EApp (EVar "serve") (EVar "lis")) (EVar "handle")))))
(DFunDef false "serveStep" (PWild PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig false "handleThenClose" (TyFun (TyFun (TyCon "Connection") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyFun (TyCon "Connection") (TyApp (TyApp (TyCon "Async") (TyRow ((hole "Net")) (Some "e"))) (TyCon "Unit")))))
(DFunDef false "handleThenClose" ((PVar "handle") (PVar "conn")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "handle") (EVar "conn"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferMap") (ELam (PWild) (ELit LUnit))) (EApp (EVar "close") (EVar "conn"))))))
