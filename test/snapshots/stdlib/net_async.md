# META
source_lines=415
stages=DESUGAR,MARK
# SOURCE
-- net_async.mdk — the non-blocking half of `net`, over the async scheduler.
--
-- Every operation here tries its syscall, and on would-block parks the task
-- with `awaitAny` until the descriptor is ready, then retries.  Readiness is
-- level-triggered, so a retry after any wake is correct.  The socket is
-- switched to non-blocking mode by `accept` and by `connect`; a `Connection`
-- from the blocking `net.connect` is switched on first use.  Deadlines are a
-- wait set of the descriptor plus a `deadlineAfter`; the task itself decides
-- to give up, so no task is ever dropped
-- (docs/design/ASYNC-RUNTIME-DESIGN.md §0a).
--
-- A handle is the runtime's socket at the authority its opening extern was
-- granted; this module builds none, it only passes them on, so every
-- operation is charged at the handle's own authority.  The descriptor number
-- a wait needs is read from the handle (`socketFd`), and grants nothing.

import async.{
  Async,
  Wait,
  liftIO,
  spawn,
  awaitAny,
  waitRead,
  waitWrite,
  deadlineAfter,
  expired,
}
import bytes as B
import bytes.{Bytes, adoptByteBlockUnsafe}
import net.{Connection, Listener}
import net as N
import time.{Duration}

{- | TCP over the async scheduler: the `net` operations that park instead of
   blocking, so many connections share one thread.

   `connect`, `accept`, `recv`, `send`, and `sendAll` mirror their `net`
   namesakes but return `Async` values that park until the socket is ready.
   `connectWithin`, `recvWithin` and `sendAllWithin` give up after a
   `Duration` with `Err "timed out"`. `serve` is an accept loop that runs each connection's
   handler as its own task and closes the connection when the handler
   finishes. Use `import net_async as A` and call `A.accept`, `A.recv`, and
   so on.

   Every operation performs `<Net h>` at the authority of the socket it
   uses, and one that parks also reads the clock: a parked task waits on its
   descriptor with a timeout. Drive the program with `runAsync` or a
   `main : Async e Unit`. Networking works only in a program built for the
   native target. -}

{- | Connects to `host` on `port`, parking until the handshake finishes
   instead of blocking the thread.

   The returned socket is already non-blocking. Resolving `host` still
   blocks; only the handshake parks, which is the wait an unreachable or
   overloaded peer makes unbounded. On every failure the socket is closed
   before the `Err` is returned, so the caller has nothing to release. -}
export
connect : (host : String) ->
  Int ->
  Async <Clock, Net host | e> (Result String (Connection host))
connect host port =
  deferThen (startConnect host port) (started => connectStarted started)

startConnect : (host : String) ->
  Int ->
  Async <Net host | e> (Result String (Connection host))
startConnect host port = liftIO (u => netConnectStart host port)

connectStarted : Result String (Connection h) ->
  Async <Clock, Net h | e> (Result String (Connection h))
connectStarted (Err e) = deferPure (Err e)
connectStarted (Ok conn) = connectPending conn

connectPending : Connection h ->
  Async <Clock, Net h | e> (Result String (Connection h))
connectPending conn =
  deferThen (liftIO (u => netConnectCheck conn)) (step => connectStep conn step)

-- `Ok None` is a handshake still in flight, which is why the check is asked
-- again after every wake rather than trusted to mean readiness: a woken task
-- retries (stdlib/async.mdk's `Wait`), and an unconnected socket reports a
-- zero `SO_ERROR` exactly like a connected one.
connectStep : Connection h ->
  Result String (Option Unit) ->
  Async <Clock, Net h | e> (Result String (Connection h))
connectStep conn (Ok None) =
  deferThen (awaitAny [waitWrite (socketFd conn)]) (_ => connectPending conn)
connectStep conn (Ok (Some _)) = deferPure (Ok conn)
connectStep conn (Err e) = abandonConnect conn e

-- | `connect` that gives up after `d` with `Err "timed out"`.
export
connectWithin : Duration ->
  (host : String) ->
  Int ->
  Async <Clock, Net host | e> (Result String (Connection host))
connectWithin d host port =
  deferThen (deadlineAfter d) (dl => connectFrom host port dl)

connectFrom : (host : String) ->
  Int ->
  Wait <Clock, Net host | e> ->
  Async <Clock, Net host | e> (Result String (Connection host))
connectFrom host port dl =
  deferThen (startConnect host port) (started => connectUntilStarted started dl)

connectUntilStarted : Result String (Connection h) ->
  Wait <Clock, Net h | e> ->
  Async <Clock, Net h | e> (Result String (Connection h))
connectUntilStarted (Err e) _ = deferPure (Err e)
connectUntilStarted (Ok conn) dl = connectUntil conn dl

connectUntil : Connection h ->
  Wait <Clock, Net h | e> ->
  Async <Clock, Net h | e> (Result String (Connection h))
connectUntil conn dl = deferThen (liftIO (u => netConnectCheck conn)) (step =>
  connectUntilStep conn dl step)

connectUntilStep : Connection h ->
  Wait <Clock, Net h | e> ->
  Result String (Option Unit) ->
  Async <Clock, Net h | e> (Result String (Connection h))
connectUntilStep conn dl (Ok None) = deferThen (expired dl) (late =>
  if late then
    abandonConnect conn "timed out"
  else
    deferThen (awaitAny [waitWrite (socketFd conn), dl]) (_ =>
      connectUntil conn dl))
connectUntilStep conn _ (Ok (Some _)) = deferPure (Ok conn)
connectUntilStep conn _ (Err e) = abandonConnect conn e

-- The socket belongs to the wrapper until a `Connection` reaches the caller,
-- so a give-up path that left it open would leak one descriptor per failed
-- dial — a server that proxies would run out of them while every dial still
-- looked like an ordinary error.
abandonConnect : Connection h ->
  String ->
  Async <Net h | e> (Result String (Connection h))
abandonConnect conn message =
  deferThen (close conn) (_ => deferPure (Err message))

{- | Accepts the next connection, parking until one arrives. The listener
   and the accepted socket are switched to non-blocking mode.

   The connection is at the listener's authority: it is reached through the
   address the listener was granted. -}
export
accept : Listener a -> Async <Clock, Net a | e> (Result String (Connection a))
accept lis =
  deferThen (liftIO (u => tryAccept lis)) (step => acceptStep lis step)

tryAccept : Listener a -> <Net a> Result String (Option (Connection a))
tryAccept lis = match netSetNonblockListener lis True
  Ok _ => match netTryAccept lis
    Ok (Some c) => map (_ => Some c) (netSetNonblock c True)
    Ok None => Ok None
    Err e => Err e
  Err e => Err e

acceptStep : Listener a ->
  Result String (Option (Connection a)) ->
  Async <Clock, Net a | e> (Result String (Connection a))
acceptStep lis (Ok None) =
  deferThen (awaitAny [waitRead (listenSocketFd lis)]) (_ => accept lis)
acceptStep _ (Ok (Some c)) = deferPure (Ok c)
acceptStep _ (Err e) = deferPure (Err e)

{- | Receives up to `n` bytes, parking until some arrive.

   The result is sized to what arrived, not to `n`. An empty result is end
   of stream. -}
export
recv : Connection h -> Int -> Async <Clock, Net h | e> (Result String Bytes)
recv conn n = deferThen (pendingRecv conn n) (step => recvStep conn n step)

-- One non-blocking attempt as an `Async` step, shared by `recv` and the
-- deadline-bearing loop below.
pendingRecv : Connection h ->
  Int ->
  Async <Net h | e> (Result String (Option Bytes))
pendingRecv conn n = liftIO (u => tryRecv conn n)

tryRecv : Connection h -> Int -> <Net h> Result String (Option Bytes)
tryRecv conn n = match netSetNonblock conn True
  -- The block was allocated by this very call and the runtime kept no
  -- reference to it, so it has one owner and nothing can write it behind the
  -- byte string's back: adopting it is safe where the general contract on
  -- `adoptByteBlockUnsafe` would demand a copy.
  Ok _ => match netTryRecvBytes conn n
    Ok (Some bb) => Ok (Some (adoptByteBlockUnsafe bb))
    Ok None => Ok None
    Err e => Err e
  Err e => Err e

recvStep : Connection h ->
  Int ->
  Result String (Option Bytes) ->
  Async <Clock, Net h | e> (Result String Bytes)
recvStep conn n (Ok None) =
  deferThen (awaitAny [waitRead (socketFd conn)]) (_ => recv conn n)
recvStep _ _ (Ok (Some bs)) = deferPure (Ok bs)
recvStep _ _ (Err e) = deferPure (Err e)

-- | `recv` that gives up after `d` with `Err "timed out"`.
export
recvWithin : Duration ->
  Connection h ->
  Int ->
  Async <Clock, Net h | e> (Result String Bytes)
recvWithin d conn n = deferThen (deadlineAfter d) (dl => recvUntil conn dl n)

recvUntil : Connection h ->
  Wait <Clock, Net h | e> ->
  Int ->
  Async <Clock, Net h | e> (Result String Bytes)
recvUntil conn dl n =
  deferThen (pendingRecv conn n) (step => recvUntilStep conn dl n step)

recvUntilStep : Connection h ->
  Wait <Clock, Net h | e> ->
  Int ->
  Result String (Option Bytes) ->
  Async <Clock, Net h | e> (Result String Bytes)
recvUntilStep conn dl n (Ok None) =
  deferThen (expired dl) (late => recvWake conn dl n late)
recvUntilStep _ _ _ (Ok (Some bs)) = deferPure (Ok bs)
recvUntilStep _ _ _ (Err e) = deferPure (Err e)

-- What the deadline-bearing loop does once `expired` has answered: give up,
-- or park on the descriptor and ask again after any wake.
recvWake : Connection h ->
  Wait <Clock, Net h | e> ->
  Int ->
  Bool ->
  Async <Clock, Net h | e> (Result String Bytes)
recvWake _ _ _ True = deferPure (Err "timed out")
recvWake conn dl n False = deferThen (awaitAny [
  waitRead (socketFd conn),
  dl,
]) (_ =>
  recvUntil conn dl n)

-- | Sends what the socket will take now, parking until it takes some.
-- The count may be short; `sendAll` loops.
export
send : Connection h -> Bytes -> Async <Clock, Net h | e> (Result String Int)
send conn bytes =
  sendWindow conn (B.lendByteBlockUnsafe bytes) 0 (B.length bytes)

-- Every sending operation reads the payload's own block through a window
-- `[off, end)`, so no retry or offset copies the bytes.
sendWindow : Connection h ->
  ByteBlock ->
  Int ->
  Int ->
  Async <Clock, Net h | e> (Result String Int)
sendWindow conn bb off end = deferThen (liftIO (u =>
  trySend conn bb off end)) (step =>
  sendStep conn bb off end step)

trySend : Connection h ->
  ByteBlock ->
  Int ->
  Int ->
  <Net h> Result String (Option Int)
trySend conn bb off end = match netSetNonblock conn True
  Ok _ => netTrySendBytesFrom conn bb off end
  Err e => Err e

sendStep : Connection h ->
  ByteBlock ->
  Int ->
  Int ->
  Result String (Option Int) ->
  Async <Clock, Net h | e> (Result String Int)
sendStep conn bb off end (Ok None) = deferThen (awaitAny [
  waitWrite (socketFd conn),
]) (_ =>
  sendWindow conn bb off end)
sendStep _ _ _ _ (Ok (Some n)) = deferPure (Ok n)
sendStep _ _ _ _ (Err e) = deferPure (Err e)

-- | Sends every byte, parking as needed.
export
sendAll : Connection h -> Bytes -> Async <Clock, Net h | e> (Result String Unit)
sendAll conn bytes =
  sendFrom conn (B.lendByteBlockUnsafe bytes) 0 (B.length bytes)

-- The loop keeps an offset into the one block rather than slicing it, and the
-- extern sends at most 64 KiB per call, so a large payload costs its own
-- length, not its length squared.
sendFrom : Connection h ->
  ByteBlock ->
  Int ->
  Int ->
  Async <Clock, Net h | e> (Result String Unit)
sendFrom conn bb off end =
  if off >= end then
    deferPure (Ok ())
  else
    deferThen (liftIO (u => trySend conn bb off end)) (step =>
      sendFromStep conn bb off end step)

sendFromStep : Connection h ->
  ByteBlock ->
  Int ->
  Int ->
  Result String (Option Int) ->
  Async <Clock, Net h | e> (Result String Unit)
sendFromStep conn bb off end (Ok None) = deferThen (awaitAny [
  waitWrite (socketFd conn),
]) (_ =>
  sendFrom conn bb off end)
sendFromStep conn bb off end (Ok (Some n)) = sendFrom conn bb (off + n) end
sendFromStep _ _ _ _ (Err e) = deferPure (Err e)

-- | `sendAll` that gives up after `d` with `Err "timed out"`.
export
sendAllWithin : Duration ->
  Connection h ->
  Bytes ->
  Async <Clock, Net h | e> (Result String Unit)
sendAllWithin d conn bytes =
  let bb = B.lendByteBlockUnsafe bytes
  let end = B.length bytes
  deferThen (deadlineAfter d) (dl => sendUntil conn dl bb 0 end)

-- The deadline is checked before every attempt, so no round of work runs
-- past it unobserved.
sendUntil : Connection h ->
  Wait <Clock, Net h | e> ->
  ByteBlock ->
  Int ->
  Int ->
  Async <Clock, Net h | e> (Result String Unit)
sendUntil conn dl bb off end =
  if off >= end then
    deferPure (Ok ())
  else
    deferThen (expired dl) (late =>
      if late then
        deferPure (Err "timed out")
      else
        sendUntilTry conn dl bb off end)

sendUntilTry : Connection h ->
  Wait <Clock, Net h | e> ->
  ByteBlock ->
  Int ->
  Int ->
  Async <Clock, Net h | e> (Result String Unit)
sendUntilTry conn dl bb off end = deferThen (liftIO (u =>
  trySend conn bb off end)) (step =>
  sendUntilStep conn dl bb off end step)

sendUntilStep : Connection h ->
  Wait <Clock, Net h | e> ->
  ByteBlock ->
  Int ->
  Int ->
  Result String (Option Int) ->
  Async <Clock, Net h | e> (Result String Unit)
sendUntilStep conn dl bb off end (Ok None) = deferThen (awaitAny [
  waitWrite (socketFd conn),
  dl,
]) (_ =>
  sendUntil conn dl bb off end)
sendUntilStep conn dl bb off end (Ok (Some n)) =
  sendUntil conn dl bb (off + n) end
sendUntilStep _ _ _ _ _ (Err e) = deferPure (Err e)

-- | Sends a string as UTF-8, parking as needed.
export
sendString : Connection h ->
  String ->
  Async <Clock, Net h | e> (Result String Unit)
sendString conn s = sendAll conn (B.encodeUtf8 s)

-- | Closes a connection.
export
close : Connection h -> Async <Net h | e> (Result String Unit)
close conn = liftIO (u => N.close conn)

-- | Closes a listener. A task parked in `accept` on it wakes with an error,
-- which ends a `serve` loop.
export
closeListener : Listener a -> Async <Net a | e> (Result String Unit)
closeListener lis = liftIO (u => N.closeListener lis)

{- | Accepts connections until `accept` fails, running `handle` on each in
   a task of its own and closing the connection when the handler finishes.

   A failure in `handle` closes that connection and the loop continues. A
   failure in `accept`, including the listener being closed, ends the loop
   with the error. -}
export
serve : Listener a ->
  (Connection a -> Async <Clock, Net a | e> (Result String Unit)) ->
  Async <Clock, Net a | e> (Result String Unit)
serve lis handle = deferThen (accept lis) (r => serveStep lis handle r)

serveStep : Listener a ->
  (Connection a -> Async <Clock, Net a | e> (Result String Unit)) ->
  Result String (Connection a) ->
  Async <Clock, Net a | e> (Result String Unit)
serveStep lis handle (Ok conn) =
  deferThen (spawn (handleThenClose handle conn)) (_ => serve lis handle)
serveStep _ _ (Err e) = deferPure (Err e)

handleThenClose : (Connection a -> Async <Clock, Net a | e> (Result String Unit)) ->
  Connection a ->
  Async <Clock, Net a | e> Unit
handleThenClose handle conn =
  deferThen (handle conn) (_ => deferMap (_ => ()) (close conn))
# DESUGAR
(DUse false (UseGroup ("async") ((mem "Async" false) (mem "Wait" false) (mem "liftIO" false) (mem "spawn" false) (mem "awaitAny" false) (mem "waitRead" false) (mem "waitWrite" false) (mem "deadlineAfter" false) (mem "expired" false))))
(DUse false (UseAlias ("bytes") "B"))
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "adoptByteBlockUnsafe" false))))
(DUse false (UseGroup ("net") ((mem "Connection" false) (mem "Listener" false))))
(DUse false (UseAlias ("net") "N"))
(DUse false (UseGroup ("time") ((mem "Duration" false))))
(DTypeSig true "connect" (TyFun (TyNamed "host" (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "host"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "host")))))))
(DFunDef false "connect" ((PVar "host") (PVar "port")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "startConnect") (EVar "host")) (EVar "port"))) (ELam ((PVar "started")) (EApp (EVar "connectStarted") (EVar "started")))))
(DTypeSig false "startConnect" (TyFun (TyNamed "host" (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ((atom "Net" (name "host"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "host")))))))
(DFunDef false "startConnect" ((PVar "host") (PVar "port")) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EVar "netConnectStart") (EVar "host")) (EVar "port")))))
(DTypeSig false "connectStarted" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h"))))))
(DFunDef false "connectStarted" ((PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DFunDef false "connectStarted" ((PCon "Ok" (PVar "conn"))) (EApp (EVar "connectPending") (EVar "conn")))
(DTypeSig false "connectPending" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h"))))))
(DFunDef false "connectPending" ((PVar "conn")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "netConnectCheck") (EVar "conn"))))) (ELam ((PVar "step")) (EApp (EApp (EVar "connectStep") (EVar "conn")) (EVar "step")))))
(DTypeSig false "connectStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Unit"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h")))))))
(DFunDef false "connectStep" ((PVar "conn") (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitWrite") (EApp (EVar "socketFd") (EVar "conn")))))) (ELam (PWild) (EApp (EVar "connectPending") (EVar "conn")))))
(DFunDef false "connectStep" ((PVar "conn") (PCon "Ok" (PCon "Some" PWild))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "conn"))))
(DFunDef false "connectStep" ((PVar "conn") (PCon "Err" (PVar "e"))) (EApp (EApp (EVar "abandonConnect") (EVar "conn")) (EVar "e")))
(DTypeSig true "connectWithin" (TyFun (TyCon "Duration") (TyFun (TyNamed "host" (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "host"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "host"))))))))
(DFunDef false "connectWithin" ((PVar "d") (PVar "host") (PVar "port")) (EApp (EApp (EVar "deferThen") (EApp (EVar "deadlineAfter") (EVar "d"))) (ELam ((PVar "dl")) (EApp (EApp (EApp (EVar "connectFrom") (EVar "host")) (EVar "port")) (EVar "dl")))))
(DTypeSig false "connectFrom" (TyFun (TyNamed "host" (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "host"))) (Some "e"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "host"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "host"))))))))
(DFunDef false "connectFrom" ((PVar "host") (PVar "port") (PVar "dl")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "startConnect") (EVar "host")) (EVar "port"))) (ELam ((PVar "started")) (EApp (EApp (EVar "connectUntilStarted") (EVar "started")) (EVar "dl")))))
(DTypeSig false "connectUntilStarted" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h"))) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h")))))))
(DFunDef false "connectUntilStarted" ((PCon "Err" (PVar "e")) PWild) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DFunDef false "connectUntilStarted" ((PCon "Ok" (PVar "conn")) (PVar "dl")) (EApp (EApp (EVar "connectUntil") (EVar "conn")) (EVar "dl")))
(DTypeSig false "connectUntil" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h")))))))
(DFunDef false "connectUntil" ((PVar "conn") (PVar "dl")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "netConnectCheck") (EVar "conn"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EVar "connectUntilStep") (EVar "conn")) (EVar "dl")) (EVar "step")))))
(DTypeSig false "connectUntilStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Unit"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h"))))))))
(DFunDef false "connectUntilStep" ((PVar "conn") (PVar "dl") (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "expired") (EVar "dl"))) (ELam ((PVar "late")) (EIf (EVar "late") (EApp (EApp (EVar "abandonConnect") (EVar "conn")) (ELit (LString "timed out"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitWrite") (EApp (EVar "socketFd") (EVar "conn"))) (EVar "dl")))) (ELam (PWild) (EApp (EApp (EVar "connectUntil") (EVar "conn")) (EVar "dl"))))))))
(DFunDef false "connectUntilStep" ((PVar "conn") PWild (PCon "Ok" (PCon "Some" PWild))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "conn"))))
(DFunDef false "connectUntilStep" ((PVar "conn") PWild (PCon "Err" (PVar "e"))) (EApp (EApp (EVar "abandonConnect") (EVar "conn")) (EVar "e")))
(DTypeSig false "abandonConnect" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Async") (TyRow ((atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h")))))))
(DFunDef false "abandonConnect" ((PVar "conn") (PVar "message")) (EApp (EApp (EVar "deferThen") (EApp (EVar "close") (EVar "conn"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "message"))))))
(DTypeSig true "accept" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "a"))))))
(DFunDef false "accept" ((PVar "lis")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "tryAccept") (EVar "lis"))))) (ELam ((PVar "step")) (EApp (EApp (EVar "acceptStep") (EVar "lis")) (EVar "step")))))
(DTypeSig false "tryAccept" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyEffect ((atom "Net" (name "a"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "Connection") (TyVar "a")))))))
(DFunDef false "tryAccept" ((PVar "lis")) (EMatch (EApp (EApp (EVar "netSetNonblockListener") (EVar "lis")) (EVar "True")) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "netTryAccept") (EVar "lis")) (arm (PCon "Ok" (PCon "Some" (PVar "c"))) () (EApp (EApp (EVar "map") (ELam (PWild) (EApp (EVar "Some") (EVar "c")))) (EApp (EApp (EVar "netSetNonblock") (EVar "c")) (EVar "True")))) (arm (PCon "Ok" (PCon "None")) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "acceptStep" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "Connection") (TyVar "a")))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "a")))))))
(DFunDef false "acceptStep" ((PVar "lis") (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitRead") (EApp (EVar "listenSocketFd") (EVar "lis")))))) (ELam (PWild) (EApp (EVar "accept") (EVar "lis")))))
(DFunDef false "acceptStep" (PWild (PCon "Ok" (PCon "Some" (PVar "c")))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "c"))))
(DFunDef false "acceptStep" (PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "recv" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bytes"))))))
(DFunDef false "recv" ((PVar "conn") (PVar "n")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "pendingRecv") (EVar "conn")) (EVar "n"))) (ELam ((PVar "step")) (EApp (EApp (EApp (EVar "recvStep") (EVar "conn")) (EVar "n")) (EVar "step")))))
(DTypeSig false "pendingRecv" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ((atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Bytes")))))))
(DFunDef false "pendingRecv" ((PVar "conn") (PVar "n")) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EVar "tryRecv") (EVar "conn")) (EVar "n")))))
(DTypeSig false "tryRecv" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Int") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Bytes")))))))
(DFunDef false "tryRecv" ((PVar "conn") (PVar "n")) (EMatch (EApp (EApp (EVar "netSetNonblock") (EVar "conn")) (EVar "True")) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "netTryRecvBytes") (EVar "conn")) (EVar "n")) (arm (PCon "Ok" (PCon "Some" (PVar "bb"))) () (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EVar "adoptByteBlockUnsafe") (EVar "bb"))))) (arm (PCon "Ok" (PCon "None")) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "recvStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Bytes"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bytes")))))))
(DFunDef false "recvStep" ((PVar "conn") (PVar "n") (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitRead") (EApp (EVar "socketFd") (EVar "conn")))))) (ELam (PWild) (EApp (EApp (EVar "recv") (EVar "conn")) (EVar "n")))))
(DFunDef false "recvStep" (PWild PWild (PCon "Ok" (PCon "Some" (PVar "bs")))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "bs"))))
(DFunDef false "recvStep" (PWild PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "recvWithin" (TyFun (TyCon "Duration") (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bytes")))))))
(DFunDef false "recvWithin" ((PVar "d") (PVar "conn") (PVar "n")) (EApp (EApp (EVar "deferThen") (EApp (EVar "deadlineAfter") (EVar "d"))) (ELam ((PVar "dl")) (EApp (EApp (EApp (EVar "recvUntil") (EVar "conn")) (EVar "dl")) (EVar "n")))))
(DTypeSig false "recvUntil" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bytes")))))))
(DFunDef false "recvUntil" ((PVar "conn") (PVar "dl") (PVar "n")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "pendingRecv") (EVar "conn")) (EVar "n"))) (ELam ((PVar "step")) (EApp (EApp (EApp (EApp (EVar "recvUntilStep") (EVar "conn")) (EVar "dl")) (EVar "n")) (EVar "step")))))
(DTypeSig false "recvUntilStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Bytes"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bytes"))))))))
(DFunDef false "recvUntilStep" ((PVar "conn") (PVar "dl") (PVar "n") (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "expired") (EVar "dl"))) (ELam ((PVar "late")) (EApp (EApp (EApp (EApp (EVar "recvWake") (EVar "conn")) (EVar "dl")) (EVar "n")) (EVar "late")))))
(DFunDef false "recvUntilStep" (PWild PWild PWild (PCon "Ok" (PCon "Some" (PVar "bs")))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "bs"))))
(DFunDef false "recvUntilStep" (PWild PWild PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig false "recvWake" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bytes"))))))))
(DFunDef false "recvWake" (PWild PWild PWild (PCon "True")) (EApp (EVar "deferPure") (EApp (EVar "Err") (ELit (LString "timed out")))))
(DFunDef false "recvWake" ((PVar "conn") (PVar "dl") (PVar "n") (PCon "False")) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitRead") (EApp (EVar "socketFd") (EVar "conn"))) (EVar "dl")))) (ELam (PWild) (EApp (EApp (EApp (EVar "recvUntil") (EVar "conn")) (EVar "dl")) (EVar "n")))))
(DTypeSig true "send" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "send" ((PVar "conn") (PVar "bytes")) (EApp (EApp (EApp (EApp (EVar "sendWindow") (EVar "conn")) (EApp (EVar "B.lendByteBlockUnsafe") (EVar "bytes"))) (ELit (LInt 0))) (EApp (EVar "B.length") (EVar "bytes"))))
(DTypeSig false "sendWindow" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))))
(DFunDef false "sendWindow" ((PVar "conn") (PVar "bb") (PVar "off") (PVar "end")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EApp (EApp (EVar "trySend") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EApp (EApp (EVar "sendStep") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end")) (EVar "step")))))
(DTypeSig false "trySend" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "trySend" ((PVar "conn") (PVar "bb") (PVar "off") (PVar "end")) (EMatch (EApp (EApp (EVar "netSetNonblock") (EVar "conn")) (EVar "True")) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EVar "netTrySendBytesFrom") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "sendStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))))))
(DFunDef false "sendStep" ((PVar "conn") (PVar "bb") (PVar "off") (PVar "end") (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitWrite") (EApp (EVar "socketFd") (EVar "conn")))))) (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "sendWindow") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end")))))
(DFunDef false "sendStep" (PWild PWild PWild PWild (PCon "Ok" (PCon "Some" (PVar "n")))) (EApp (EVar "deferPure") (EApp (EVar "Ok") (EVar "n"))))
(DFunDef false "sendStep" (PWild PWild PWild PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "sendAll" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendAll" ((PVar "conn") (PVar "bytes")) (EApp (EApp (EApp (EApp (EVar "sendFrom") (EVar "conn")) (EApp (EVar "B.lendByteBlockUnsafe") (EVar "bytes"))) (ELit (LInt 0))) (EApp (EVar "B.length") (EVar "bytes"))))
(DTypeSig false "sendFrom" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))))
(DFunDef false "sendFrom" ((PVar "conn") (PVar "bb") (PVar "off") (PVar "end")) (EIf (EBinOp ">=" (EVar "off") (EVar "end")) (EApp (EVar "deferPure") (EApp (EVar "Ok") (ELit LUnit))) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EApp (EApp (EVar "trySend") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EApp (EApp (EVar "sendFromStep") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end")) (EVar "step"))))))
(DTypeSig false "sendFromStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))))
(DFunDef false "sendFromStep" ((PVar "conn") (PVar "bb") (PVar "off") (PVar "end") (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitWrite") (EApp (EVar "socketFd") (EVar "conn")))))) (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "sendFrom") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end")))))
(DFunDef false "sendFromStep" ((PVar "conn") (PVar "bb") (PVar "off") (PVar "end") (PCon "Ok" (PCon "Some" (PVar "n")))) (EApp (EApp (EApp (EApp (EVar "sendFrom") (EVar "conn")) (EVar "bb")) (EBinOp "+" (EVar "off") (EVar "n"))) (EVar "end")))
(DFunDef false "sendFromStep" (PWild PWild PWild PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "sendAllWithin" (TyFun (TyCon "Duration") (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "sendAllWithin" ((PVar "d") (PVar "conn") (PVar "bytes")) (EBlock (DoLet false false (PVar "bb") (EApp (EVar "B.lendByteBlockUnsafe") (EVar "bytes"))) (DoLet false false (PVar "end") (EApp (EVar "B.length") (EVar "bytes"))) (DoExpr (EApp (EApp (EVar "deferThen") (EApp (EVar "deadlineAfter") (EVar "d"))) (ELam ((PVar "dl")) (EApp (EApp (EApp (EApp (EApp (EVar "sendUntil") (EVar "conn")) (EVar "dl")) (EVar "bb")) (ELit (LInt 0))) (EVar "end")))))))
(DTypeSig false "sendUntil" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))))
(DFunDef false "sendUntil" ((PVar "conn") (PVar "dl") (PVar "bb") (PVar "off") (PVar "end")) (EIf (EBinOp ">=" (EVar "off") (EVar "end")) (EApp (EVar "deferPure") (EApp (EVar "Ok") (ELit LUnit))) (EApp (EApp (EVar "deferThen") (EApp (EVar "expired") (EVar "dl"))) (ELam ((PVar "late")) (EIf (EVar "late") (EApp (EVar "deferPure") (EApp (EVar "Err") (ELit (LString "timed out")))) (EApp (EApp (EApp (EApp (EApp (EVar "sendUntilTry") (EVar "conn")) (EVar "dl")) (EVar "bb")) (EVar "off")) (EVar "end")))))))
(DTypeSig false "sendUntilTry" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))))
(DFunDef false "sendUntilTry" ((PVar "conn") (PVar "dl") (PVar "bb") (PVar "off") (PVar "end")) (EApp (EApp (EVar "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EApp (EApp (EVar "trySend") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "sendUntilStep") (EVar "conn")) (EVar "dl")) (EVar "bb")) (EVar "off")) (EVar "end")) (EVar "step")))))
(DTypeSig false "sendUntilStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))))))
(DFunDef false "sendUntilStep" ((PVar "conn") (PVar "dl") (PVar "bb") (PVar "off") (PVar "end") (PCon "Ok" (PCon "None"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitWrite") (EApp (EVar "socketFd") (EVar "conn"))) (EVar "dl")))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "sendUntil") (EVar "conn")) (EVar "dl")) (EVar "bb")) (EVar "off")) (EVar "end")))))
(DFunDef false "sendUntilStep" ((PVar "conn") (PVar "dl") (PVar "bb") (PVar "off") (PVar "end") (PCon "Ok" (PCon "Some" (PVar "n")))) (EApp (EApp (EApp (EApp (EApp (EVar "sendUntil") (EVar "conn")) (EVar "dl")) (EVar "bb")) (EBinOp "+" (EVar "off") (EVar "n"))) (EVar "end")))
(DFunDef false "sendUntilStep" (PWild PWild PWild PWild PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "sendString" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendString" ((PVar "conn") (PVar "s")) (EApp (EApp (EVar "sendAll") (EVar "conn")) (EApp (EVar "B.encodeUtf8") (EVar "s"))))
(DTypeSig true "close" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyApp (TyApp (TyCon "Async") (TyRow ((atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "close" ((PVar "conn")) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "N.close") (EVar "conn")))))
(DTypeSig true "closeListener" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyRow ((atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "closeListener" ((PVar "lis")) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "N.closeListener") (EVar "lis")))))
(DTypeSig true "serve" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyFun (TyFun (TyApp (TyCon "Connection") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "serve" ((PVar "lis") (PVar "handle")) (EApp (EApp (EVar "deferThen") (EApp (EVar "accept") (EVar "lis"))) (ELam ((PVar "r")) (EApp (EApp (EApp (EVar "serveStep") (EVar "lis")) (EVar "handle")) (EVar "r")))))
(DTypeSig false "serveStep" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyFun (TyFun (TyApp (TyCon "Connection") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "serveStep" ((PVar "lis") (PVar "handle") (PCon "Ok" (PVar "conn"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "spawn") (EApp (EApp (EVar "handleThenClose") (EVar "handle")) (EVar "conn")))) (ELam (PWild) (EApp (EApp (EVar "serve") (EVar "lis")) (EVar "handle")))))
(DFunDef false "serveStep" (PWild PWild (PCon "Err" (PVar "e"))) (EApp (EVar "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig false "handleThenClose" (TyFun (TyFun (TyApp (TyCon "Connection") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Connection") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyCon "Unit")))))
(DFunDef false "handleThenClose" ((PVar "handle") (PVar "conn")) (EApp (EApp (EVar "deferThen") (EApp (EVar "handle") (EVar "conn"))) (ELam (PWild) (EApp (EApp (EVar "deferMap") (ELam (PWild) (ELit LUnit))) (EApp (EVar "close") (EVar "conn"))))))
# MARK
(DUse false (UseGroup ("async") ((mem "Async" false) (mem "Wait" false) (mem "liftIO" false) (mem "spawn" false) (mem "awaitAny" false) (mem "waitRead" false) (mem "waitWrite" false) (mem "deadlineAfter" false) (mem "expired" false))))
(DUse false (UseAlias ("bytes") "B"))
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "adoptByteBlockUnsafe" false))))
(DUse false (UseGroup ("net") ((mem "Connection" false) (mem "Listener" false))))
(DUse false (UseAlias ("net") "N"))
(DUse false (UseGroup ("time") ((mem "Duration" false))))
(DTypeSig true "connect" (TyFun (TyNamed "host" (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "host"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "host")))))))
(DFunDef false "connect" ((PVar "host") (PVar "port")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "startConnect") (EVar "host")) (EVar "port"))) (ELam ((PVar "started")) (EApp (EVar "connectStarted") (EVar "started")))))
(DTypeSig false "startConnect" (TyFun (TyNamed "host" (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ((atom "Net" (name "host"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "host")))))))
(DFunDef false "startConnect" ((PVar "host") (PVar "port")) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EVar "netConnectStart") (EVar "host")) (EVar "port")))))
(DTypeSig false "connectStarted" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h"))))))
(DFunDef false "connectStarted" ((PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DFunDef false "connectStarted" ((PCon "Ok" (PVar "conn"))) (EApp (EVar "connectPending") (EVar "conn")))
(DTypeSig false "connectPending" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h"))))))
(DFunDef false "connectPending" ((PVar "conn")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "netConnectCheck") (EVar "conn"))))) (ELam ((PVar "step")) (EApp (EApp (EVar "connectStep") (EVar "conn")) (EVar "step")))))
(DTypeSig false "connectStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Unit"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h")))))))
(DFunDef false "connectStep" ((PVar "conn") (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitWrite") (EApp (EVar "socketFd") (EVar "conn")))))) (ELam (PWild) (EApp (EVar "connectPending") (EVar "conn")))))
(DFunDef false "connectStep" ((PVar "conn") (PCon "Ok" (PCon "Some" PWild))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "conn"))))
(DFunDef false "connectStep" ((PVar "conn") (PCon "Err" (PVar "e"))) (EApp (EApp (EVar "abandonConnect") (EVar "conn")) (EVar "e")))
(DTypeSig true "connectWithin" (TyFun (TyCon "Duration") (TyFun (TyNamed "host" (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "host"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "host"))))))))
(DFunDef false "connectWithin" ((PVar "d") (PVar "host") (PVar "port")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "deadlineAfter") (EVar "d"))) (ELam ((PVar "dl")) (EApp (EApp (EApp (EVar "connectFrom") (EVar "host")) (EVar "port")) (EVar "dl")))))
(DTypeSig false "connectFrom" (TyFun (TyNamed "host" (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "host"))) (Some "e"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "host"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "host"))))))))
(DFunDef false "connectFrom" ((PVar "host") (PVar "port") (PVar "dl")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "startConnect") (EVar "host")) (EVar "port"))) (ELam ((PVar "started")) (EApp (EApp (EVar "connectUntilStarted") (EVar "started")) (EVar "dl")))))
(DTypeSig false "connectUntilStarted" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h"))) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h")))))))
(DFunDef false "connectUntilStarted" ((PCon "Err" (PVar "e")) PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DFunDef false "connectUntilStarted" ((PCon "Ok" (PVar "conn")) (PVar "dl")) (EApp (EApp (EVar "connectUntil") (EVar "conn")) (EVar "dl")))
(DTypeSig false "connectUntil" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h")))))))
(DFunDef false "connectUntil" ((PVar "conn") (PVar "dl")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "netConnectCheck") (EVar "conn"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EVar "connectUntilStep") (EVar "conn")) (EVar "dl")) (EVar "step")))))
(DTypeSig false "connectUntilStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Unit"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h"))))))))
(DFunDef false "connectUntilStep" ((PVar "conn") (PVar "dl") (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expired") (EVar "dl"))) (ELam ((PVar "late")) (EIf (EVar "late") (EApp (EApp (EVar "abandonConnect") (EVar "conn")) (ELit (LString "timed out"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitWrite") (EApp (EVar "socketFd") (EVar "conn"))) (EVar "dl")))) (ELam (PWild) (EApp (EApp (EVar "connectUntil") (EVar "conn")) (EVar "dl"))))))))
(DFunDef false "connectUntilStep" ((PVar "conn") PWild (PCon "Ok" (PCon "Some" PWild))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "conn"))))
(DFunDef false "connectUntilStep" ((PVar "conn") PWild (PCon "Err" (PVar "e"))) (EApp (EApp (EVar "abandonConnect") (EVar "conn")) (EVar "e")))
(DTypeSig false "abandonConnect" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Async") (TyRow ((atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "h")))))))
(DFunDef false "abandonConnect" ((PVar "conn") (PVar "message")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "close") (EVar "conn"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "message"))))))
(DTypeSig true "accept" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "a"))))))
(DFunDef false "accept" ((PVar "lis")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "tryAccept") (EVar "lis"))))) (ELam ((PVar "step")) (EApp (EApp (EVar "acceptStep") (EVar "lis")) (EVar "step")))))
(DTypeSig false "tryAccept" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyEffect ((atom "Net" (name "a"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "Connection") (TyVar "a")))))))
(DFunDef false "tryAccept" ((PVar "lis")) (EMatch (EApp (EApp (EVar "netSetNonblockListener") (EVar "lis")) (EVar "True")) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "netTryAccept") (EVar "lis")) (arm (PCon "Ok" (PCon "Some" (PVar "c"))) () (EApp (EApp (EMethodRef "map") (ELam (PWild) (EApp (EVar "Some") (EVar "c")))) (EApp (EApp (EVar "netSetNonblock") (EVar "c")) (EVar "True")))) (arm (PCon "Ok" (PCon "None")) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "acceptStep" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "Connection") (TyVar "a")))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "a")))))))
(DFunDef false "acceptStep" ((PVar "lis") (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitRead") (EApp (EVar "listenSocketFd") (EVar "lis")))))) (ELam (PWild) (EApp (EVar "accept") (EVar "lis")))))
(DFunDef false "acceptStep" (PWild (PCon "Ok" (PCon "Some" (PVar "c")))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "c"))))
(DFunDef false "acceptStep" (PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "recv" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bytes"))))))
(DFunDef false "recv" ((PVar "conn") (PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "pendingRecv") (EVar "conn")) (EVar "n"))) (ELam ((PVar "step")) (EApp (EApp (EApp (EVar "recvStep") (EVar "conn")) (EVar "n")) (EVar "step")))))
(DTypeSig false "pendingRecv" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ((atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Bytes")))))))
(DFunDef false "pendingRecv" ((PVar "conn") (PVar "n")) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EVar "tryRecv") (EVar "conn")) (EVar "n")))))
(DTypeSig false "tryRecv" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Int") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Bytes")))))))
(DFunDef false "tryRecv" ((PVar "conn") (PVar "n")) (EMatch (EApp (EApp (EVar "netSetNonblock") (EVar "conn")) (EVar "True")) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "netTryRecvBytes") (EVar "conn")) (EVar "n")) (arm (PCon "Ok" (PCon "Some" (PVar "bb"))) () (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EVar "adoptByteBlockUnsafe") (EVar "bb"))))) (arm (PCon "Ok" (PCon "None")) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "recvStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Bytes"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bytes")))))))
(DFunDef false "recvStep" ((PVar "conn") (PVar "n") (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitRead") (EApp (EVar "socketFd") (EVar "conn")))))) (ELam (PWild) (EApp (EApp (EVar "recv") (EVar "conn")) (EVar "n")))))
(DFunDef false "recvStep" (PWild PWild (PCon "Ok" (PCon "Some" (PVar "bs")))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "bs"))))
(DFunDef false "recvStep" (PWild PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "recvWithin" (TyFun (TyCon "Duration") (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bytes")))))))
(DFunDef false "recvWithin" ((PVar "d") (PVar "conn") (PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "deadlineAfter") (EVar "d"))) (ELam ((PVar "dl")) (EApp (EApp (EApp (EVar "recvUntil") (EVar "conn")) (EVar "dl")) (EVar "n")))))
(DTypeSig false "recvUntil" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bytes")))))))
(DFunDef false "recvUntil" ((PVar "conn") (PVar "dl") (PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "pendingRecv") (EVar "conn")) (EVar "n"))) (ELam ((PVar "step")) (EApp (EApp (EApp (EApp (EVar "recvUntilStep") (EVar "conn")) (EVar "dl")) (EVar "n")) (EVar "step")))))
(DTypeSig false "recvUntilStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Bytes"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bytes"))))))))
(DFunDef false "recvUntilStep" ((PVar "conn") (PVar "dl") (PVar "n") (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expired") (EVar "dl"))) (ELam ((PVar "late")) (EApp (EApp (EApp (EApp (EVar "recvWake") (EVar "conn")) (EVar "dl")) (EVar "n")) (EVar "late")))))
(DFunDef false "recvUntilStep" (PWild PWild PWild (PCon "Ok" (PCon "Some" (PVar "bs")))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "bs"))))
(DFunDef false "recvUntilStep" (PWild PWild PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig false "recvWake" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bytes"))))))))
(DFunDef false "recvWake" (PWild PWild PWild (PCon "True")) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (ELit (LString "timed out")))))
(DFunDef false "recvWake" ((PVar "conn") (PVar "dl") (PVar "n") (PCon "False")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitRead") (EApp (EVar "socketFd") (EVar "conn"))) (EVar "dl")))) (ELam (PWild) (EApp (EApp (EApp (EVar "recvUntil") (EVar "conn")) (EVar "dl")) (EVar "n")))))
(DTypeSig true "send" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "send" ((PVar "conn") (PVar "bytes")) (EApp (EApp (EApp (EApp (EVar "sendWindow") (EVar "conn")) (EApp (EVar "B.lendByteBlockUnsafe") (EVar "bytes"))) (ELit (LInt 0))) (EApp (EVar "B.length") (EVar "bytes"))))
(DTypeSig false "sendWindow" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))))
(DFunDef false "sendWindow" ((PVar "conn") (PVar "bb") (PVar "off") (PVar "end")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EApp (EApp (EVar "trySend") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EApp (EApp (EVar "sendStep") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end")) (EVar "step")))))
(DTypeSig false "trySend" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "trySend" ((PVar "conn") (PVar "bb") (PVar "off") (PVar "end")) (EMatch (EApp (EApp (EVar "netSetNonblock") (EVar "conn")) (EVar "True")) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EVar "netTrySendBytesFrom") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "sendStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))))))
(DFunDef false "sendStep" ((PVar "conn") (PVar "bb") (PVar "off") (PVar "end") (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitWrite") (EApp (EVar "socketFd") (EVar "conn")))))) (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "sendWindow") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end")))))
(DFunDef false "sendStep" (PWild PWild PWild PWild (PCon "Ok" (PCon "Some" (PVar "n")))) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (EVar "n"))))
(DFunDef false "sendStep" (PWild PWild PWild PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "sendAll" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendAll" ((PVar "conn") (PVar "bytes")) (EApp (EApp (EApp (EApp (EVar "sendFrom") (EVar "conn")) (EApp (EVar "B.lendByteBlockUnsafe") (EVar "bytes"))) (ELit (LInt 0))) (EApp (EVar "B.length") (EVar "bytes"))))
(DTypeSig false "sendFrom" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))))
(DFunDef false "sendFrom" ((PVar "conn") (PVar "bb") (PVar "off") (PVar "end")) (EIf (EBinOp ">=" (EVar "off") (EVar "end")) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (ELit LUnit))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EApp (EApp (EVar "trySend") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EApp (EApp (EVar "sendFromStep") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end")) (EVar "step"))))))
(DTypeSig false "sendFromStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))))
(DFunDef false "sendFromStep" ((PVar "conn") (PVar "bb") (PVar "off") (PVar "end") (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitWrite") (EApp (EVar "socketFd") (EVar "conn")))))) (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "sendFrom") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end")))))
(DFunDef false "sendFromStep" ((PVar "conn") (PVar "bb") (PVar "off") (PVar "end") (PCon "Ok" (PCon "Some" (PVar "n")))) (EApp (EApp (EApp (EApp (EVar "sendFrom") (EVar "conn")) (EVar "bb")) (EBinOp "+" (EVar "off") (EVar "n"))) (EVar "end")))
(DFunDef false "sendFromStep" (PWild PWild PWild PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "sendAllWithin" (TyFun (TyCon "Duration") (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "sendAllWithin" ((PVar "d") (PVar "conn") (PVar "bytes")) (EBlock (DoLet false false (PVar "bb") (EApp (EVar "B.lendByteBlockUnsafe") (EVar "bytes"))) (DoLet false false (PVar "end") (EApp (EVar "B.length") (EVar "bytes"))) (DoExpr (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "deadlineAfter") (EVar "d"))) (ELam ((PVar "dl")) (EApp (EApp (EApp (EApp (EApp (EVar "sendUntil") (EVar "conn")) (EVar "dl")) (EVar "bb")) (ELit (LInt 0))) (EVar "end")))))))
(DTypeSig false "sendUntil" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))))
(DFunDef false "sendUntil" ((PVar "conn") (PVar "dl") (PVar "bb") (PVar "off") (PVar "end")) (EIf (EBinOp ">=" (EVar "off") (EVar "end")) (EApp (EMethodRef "deferPure") (EApp (EVar "Ok") (ELit LUnit))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expired") (EVar "dl"))) (ELam ((PVar "late")) (EIf (EVar "late") (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (ELit (LString "timed out")))) (EApp (EApp (EApp (EApp (EApp (EVar "sendUntilTry") (EVar "conn")) (EVar "dl")) (EVar "bb")) (EVar "off")) (EVar "end")))))))
(DTypeSig false "sendUntilTry" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))))
(DFunDef false "sendUntilTry" ((PVar "conn") (PVar "dl") (PVar "bb") (PVar "off") (PVar "end")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EApp (EApp (EApp (EVar "trySend") (EVar "conn")) (EVar "bb")) (EVar "off")) (EVar "end"))))) (ELam ((PVar "step")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "sendUntilStep") (EVar "conn")) (EVar "dl")) (EVar "bb")) (EVar "off")) (EVar "end")) (EVar "step")))))
(DTypeSig false "sendUntilStep" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Wait") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))))))
(DFunDef false "sendUntilStep" ((PVar "conn") (PVar "dl") (PVar "bb") (PVar "off") (PVar "end") (PCon "Ok" (PCon "None"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "awaitAny") (EListLit (EApp (EVar "waitWrite") (EApp (EVar "socketFd") (EVar "conn"))) (EVar "dl")))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "sendUntil") (EVar "conn")) (EVar "dl")) (EVar "bb")) (EVar "off")) (EVar "end")))))
(DFunDef false "sendUntilStep" ((PVar "conn") (PVar "dl") (PVar "bb") (PVar "off") (PVar "end") (PCon "Ok" (PCon "Some" (PVar "n")))) (EApp (EApp (EApp (EApp (EApp (EVar "sendUntil") (EVar "conn")) (EVar "dl")) (EVar "bb")) (EBinOp "+" (EVar "off") (EVar "n"))) (EVar "end")))
(DFunDef false "sendUntilStep" (PWild PWild PWild PWild PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig true "sendString" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendString" ((PVar "conn") (PVar "s")) (EApp (EApp (EVar "sendAll") (EVar "conn")) (EApp (EVar "B.encodeUtf8") (EVar "s"))))
(DTypeSig true "close" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyApp (TyApp (TyCon "Async") (TyRow ((atom "Net" (name "h"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "close" ((PVar "conn")) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "N.close") (EVar "conn")))))
(DTypeSig true "closeListener" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyRow ((atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "closeListener" ((PVar "lis")) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "N.closeListener") (EVar "lis")))))
(DTypeSig true "serve" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyFun (TyFun (TyApp (TyCon "Connection") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "serve" ((PVar "lis") (PVar "handle")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "accept") (EVar "lis"))) (ELam ((PVar "r")) (EApp (EApp (EApp (EVar "serveStep") (EVar "lis")) (EVar "handle")) (EVar "r")))))
(DTypeSig false "serveStep" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyFun (TyFun (TyApp (TyCon "Connection") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "serveStep" ((PVar "lis") (PVar "handle") (PCon "Ok" (PVar "conn"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "spawn") (EApp (EApp (EVar "handleThenClose") (EVar "handle")) (EVar "conn")))) (ELam (PWild) (EApp (EApp (EVar "serve") (EVar "lis")) (EVar "handle")))))
(DFunDef false "serveStep" (PWild PWild (PCon "Err" (PVar "e"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Err") (EVar "e"))))
(DTypeSig false "handleThenClose" (TyFun (TyFun (TyApp (TyCon "Connection") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Connection") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyRow ("Clock" (atom "Net" (name "a"))) (Some "e"))) (TyCon "Unit")))))
(DFunDef false "handleThenClose" ((PVar "handle") (PVar "conn")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "handle") (EVar "conn"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferMap") (ELam (PWild) (ELit LUnit))) (EApp (EVar "close") (EVar "conn"))))))
