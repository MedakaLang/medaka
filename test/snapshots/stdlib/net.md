# META
source_lines=362
stages=DESUGAR,MARK
# SOURCE
{- | TCP connections and name resolution.

   `connect` opens a connection and `listen` and `accept` receive them.
   `Connection` and `Listener` are distinct handle types, so one cannot be
   passed where the other is expected. `sendAll` and `recvAll`
   loop until every byte is transferred, and `sendString`, `recvString`,
   `sendLine`, and `recvLine` work in UTF-8 text. `withConnection`,
   `withListener`, and `serveLoop` close their handle when the body
   finishes, on the `Ok` and `Err` paths alike.

   Every operation returns `Result String a`, with the host's error message
   in `Err`. Networking works only in a program built for the native
   backend: the interpreter does not bind the `net` primitives, and the
   WebAssembly backend rejects a program that imports this module. -}

-- Medaka has no RAII / `finally` / catchable panics: a bracket acquires,
-- runs the body, and closes unconditionally, then returns the body's
-- result.  Because a `Result`-returning body has no non-local exit (a panic
-- ends the process outright, reclaiming the fd for free), "run the body then
-- close" is airtight (NET-DESIGN.md §4).  This module is verified by a
-- compiled loopback fixture rather than doctests, which would run under the
-- interpreter (NET-DESIGN.md §7).

import array.{setInPlace}
import vector.{Vector, new, push, toArray}
import string.{toUtf8, fromUtf8}
import time.{Duration, toMillis}
import test.{expectAll, expectEqual, expectTrue}

-- # Handles

-- A handle is the runtime's own socket: nothing here or in `net_async` builds
-- one, so a handle is only ever at the authority the extern that opened it
-- was granted, and every operation on it is charged there.

{- | A connected TCP socket, from `connect` or `accept`, at the authority of
   the host it reaches. -}
export type Connection (h : Authority Net) = Socket h

-- | A listening TCP socket, from `listen`, at the authority of its address.
export type Listener (a : Authority Net) = ListenSocket a

-- | Which direction of a connection `shutdown` closes.
public export data Shutdown = ShutdownRead | ShutdownWrite | ShutdownBoth

-- # Clients

{- | The numeric addresses a host name resolves to.

   `resolve "localhost"` gives `Ok ["127.0.0.1"]` or similar. -}
export
resolve : (host : String) -> <Net host> Result String (List String)
resolve host = netResolve host

{- | A connection to `host` on `port`.

   The host name is resolved first. `withConnection` is the form that
   closes the connection for you. -}
export
connect : (host : String) -> Int -> <Net host> Result String (Connection host)
connect host port = netTcpConnect host port

-- # Servers

{- | A listener bound to `addr` on `port`.

   Port `0` lets the system pick a free port; `listenPort` reports which. -}
export
listen : (addr : String) -> Int -> <Net addr> Result String (Listener addr)
listen addr port = netTcpListen addr port

-- | The port a listener is bound to.
export
listenPort : Listener a -> <Net a> Result String Int
listenPort lis = netListenPort lis

{- | Waits for the next connection to a listener.

   The connection is at the listener's authority: it is reached through the
   address the listener was granted. -}
export
accept : Listener a -> <Net a> Result String (Connection a)
accept lis = netTcpAccept lis

-- # Transfer

{- | Sends bytes in one call. The result is the number of bytes written,
   which may be fewer than given.

   `sendAll` is the form that sends everything. -}
export
send : Connection h -> Array Int -> <Net h> Result String Int
send conn bs = netSend conn bs

{- | Receives up to `n` bytes in one call.

   An empty array means the peer has closed the connection. `recvAll` is the
   form that reads to the end. -}
export
recv : Connection h -> Int -> <Net h> Result String (Array Int)
recv conn n = netRecv conn n

{- | Sends every byte, looping over `send` as needed.

   `Err` on the first failed send, or when a send writes nothing, which is
   treated as a stalled connection. -}
export
sendAll : Connection h -> Array Int -> <Net h> Result String Unit
sendAll conn bs = sendAllFrom (bytes off => netSendFrom conn bytes off) bs 0

sendAllFrom : (Array Int -> Int -> <e> Result String Int) ->
  Array Int ->
  Int ->
  <e> Result String Unit
sendAllFrom write bs off =
  if off >= arrayLength bs then
    Ok ()
  else match write bs off
    Err e => Err e
    Ok 0 => Err "net.sendAll: 0 bytes written (connection stalled)"
    Ok n => sendAllFrom write bs (off + n)

testSentBytes : Array Int -> Int -> Int -> List Int
testSentBytes bs i hi =
  if i >= hi then [] else arrayGetUnsafe i bs :: testSentBytes bs (i + 1) hi

testRecordAlias : Ref (Option (Array Int)) ->
  Ref Bool ->
  Array Int ->
  Int ->
  Unit
testRecordAlias first aliasSeen bs call =
  if call == 0 then
    first := Some bs
  else if call == 1 then match !first
    Some original =>
      let _ = setInPlace 0 251 original
      aliasSeen := arrayGetUnsafe 0 bs == 251
    None => ()

testScriptedSend : Ref Int ->
  Ref (List Int) ->
  Ref (List Int) ->
  Ref (Option (Array Int)) ->
  Ref Bool ->
  Array Int ->
  Int ->
  Result String Int
testScriptedSend calls offsets sent first aliasSeen bs off =
  let call = !calls
  calls := call + 1
  offsets := !offsets ++ [off]
  let _ = testRecordAlias first aliasSeen bs call
  if call >= 3 then
    Err "unexpected fourth send"
  else
    let n =
      if call == 0 then 2 else if call == 1 then 3 else arrayLength bs - off
    sent := !sent ++ testSentBytes bs off (off + n)
    Ok n

testScriptedObservation : Unit ->
  (Result String Unit, Int, List Int, List Int, Bool)
testScriptedObservation _ =
  let calls = Ref 0
  let offsets = Ref []
  let sent = Ref []
  let first = Ref None
  let aliasSeen = Ref False
  let payload = arrayFromList [10, 20, 30, 40, 50, 60, 70, 80]
  let result =
    sendAllFrom (testScriptedSend calls offsets sent first aliasSeen) payload 0
  (result, !calls, !offsets, !sent, !aliasSeen)

test "sendAll keeps one array while offsets cover exact bytes" =
  let (result, calls, offsets, sent, aliasSeen) = testScriptedObservation ()
  expectAll [
    expectEqual (Ok ()) result,
    expectEqual 3 calls,
    expectEqual [0, 2, 5] offsets,
    expectEqual [10, 20, 30, 40, 50, 60, 70, 80] sent,
    expectTrue aliasSeen,
  ]

test "sendAll rejects a zero-byte write exactly" =
  expectEqual
    (Err "net.sendAll: 0 bytes written (connection stalled)")
    (sendAllFrom (_ _ => Ok 0) (arrayFromList [1]) 0)

testFirstErrorSend : Ref Int ->
  Ref (List Int) ->
  Array Int ->
  Int ->
  Result String Int
testFirstErrorSend calls offsets _ off =
  let call = !calls
  calls := call + 1
  offsets := !offsets ++ [off]
  if call == 0 then Ok 2 else if call == 1 then Err "boom" else Err "late call"

test "sendAll returns the first host error without another write" =
  let calls = Ref 0
  let offsets = Ref []
  let result =
    sendAllFrom
      (testFirstErrorSend calls offsets)
      (arrayFromList [1, 2, 3, 4])
      0
  expectAll [
    expectEqual (Err "boom") result,
    expectEqual 2 !calls,
    expectEqual [0, 2] !offsets,
  ]

recvAllLoop : Connection h -> Vector Int -> <Net h> Result String (Array Int)
recvAllLoop conn buf = match recv conn 4096
  Err e => Err e
  Ok chunk =>
    if arrayLength chunk == 0 then
      Ok (toArray buf)
    else
      let _ = fold (acc b => let _ = push b buf in acc) () chunk
      recvAllLoop conn buf

{- | Receives everything until the peer closes the connection.

   `Err` on the first failed receive; whatever was read before it is
   discarded. -}
export
recvAll : Connection h -> <Net h> Result String (Array Int)
recvAll conn = recvAllLoop conn (new ())

-- # Text

-- | Sends a string as UTF-8, every byte of it.
export
sendString : Connection h -> String -> <Net h> Result String Unit
sendString conn s = sendAll conn (toUtf8 s)

{- | Receives everything until the peer closes the connection, decoded as
   UTF-8.

   For a connection that stays open, read a line at a time with `recvLine`
   or a bounded amount with `recv`. -}
export
recvString : Connection h -> <Net h> Result String String
recvString conn = map fromUtf8 (recvAll conn)

-- | Sends a string as UTF-8 followed by a newline.
export
sendLine : Connection h -> String -> <Net h> Result String Unit
sendLine conn s = sendString conn (s ++ "\n")

recvLineLoop : Connection h ->
  Vector Int ->
  <Net h> Result String (Option String)
recvLineLoop conn buf = match recv conn 1
  Err e => Err e
  Ok chunk =>
    if arrayLength chunk == 0 then
      -- EOF: no trailing newline seen. Report whatever was buffered, if any.
      if isEmpty buf then Ok None else Ok (Some (fromUtf8 (toArray buf)))
    else
      let b = arrayGetUnsafe 0 chunk
      if b == 10 then
        Ok (Some (fromUtf8 (toArray buf)))
      else
        let _ = push b buf
        recvLineLoop conn buf

{- | Receives one line, without its newline.

   `None` when the peer has closed the connection and nothing was pending.
   A final line with no newline is still returned. Reads one byte per call,
   so it suits small line-based messages, not bulk transfer. -}
export
recvLine : Connection h -> <Net h> Result String (Option String)
recvLine conn = recvLineLoop conn (new ())

-- # Lifecycle

-- | Shuts down one or both directions of a connection without closing it.
export
shutdown : Connection h -> Shutdown -> <Net h> Result String Unit
shutdown conn how = netShutdown conn (shutdownCode how)

shutdownCode : Shutdown -> Int
shutdownCode ShutdownRead = 0
shutdownCode ShutdownWrite = 1
shutdownCode ShutdownBoth = 2

{- | Closes a connection.

   Closing twice is not an error. `withConnection` closes for you. -}
export
close : Connection h -> <Net h> Result String Unit
close conn = netClose conn

-- | Closes a listener.
export
closeListener : Listener a -> <Net a> Result String Unit
closeListener lis = netCloseListener lis

{- | Sets a connection's send and receive timeout.

   A zero duration means no timeout. Set one on any long-lived connection
   so a stalled peer cannot block forever. -}
export
setTimeout : Connection h -> Duration -> <Net h> Result String Unit
setTimeout conn d = netSetTimeout conn (toMillis d)

{- | Connects to `host` on `port`, runs `body` on the connection, and closes
   it whatever `body` returns.

   The result is `body`'s result, or the connection error when connecting
   fails, in which case `body` does not run.

   `withConnection "127.0.0.1" 9000 (conn => sendString conn "hi")` -}
export
withConnection : (host : String) ->
  Int ->
  (Connection host -> <Net host | e> Result String a) ->
  <Net host | e> Result String a
withConnection host port body = match connect host port
  Err e => Err e
  Ok conn =>
    let r = body conn
    let _ = close conn
    r

{- | Listens on `addr` and `port`, runs `body` on the listener, and closes
   it whatever `body` returns.

   The result is `body`'s result, or the error when listening fails. -}
export
withListener : (addr : String) ->
  Int ->
  (Listener addr -> <Net addr | e> Result String a) ->
  <Net addr | e> Result String a
withListener addr port body = match listen addr port
  Err e => Err e
  Ok lis =>
    let r = body lis
    let _ = closeListener lis
    r

{- | Accepts connections forever, running `handle` on each and closing it
   afterwards.

   A failure in `handle` closes that connection and the loop continues. A
   failure in `accept` ends the loop with the error. Pair it with
   `withListener` to close the listener when the loop ends. -}
export
serveLoop : Listener a ->
  (Connection a -> <Net a | e> Result String Unit) ->
  <Net a | e> Result String Unit
serveLoop lis handle = match accept lis
  Err e => Err e
  Ok conn =>
    let _ = handle conn
    let _ = close conn
    serveLoop lis handle
# DESUGAR
(DUse false (UseGroup ("array") ((mem "setInPlace" false))))
(DUse false (UseGroup ("vector") ((mem "Vector" false) (mem "new" false) (mem "push" false) (mem "toArray" false))))
(DUse false (UseGroup ("string") ((mem "toUtf8" false) (mem "fromUtf8" false))))
(DUse false (UseGroup ("time") ((mem "Duration" false) (mem "toMillis" false))))
(DUse false (UseGroup ("test") ((mem "expectAll" false) (mem "expectEqual" false) (mem "expectTrue" false))))
(DTypeAlias true "Connection" ("h") (TyApp (TyCon "Socket") (TyVar "h")))
(DTypeAlias true "Listener" ("a") (TyApp (TyCon "ListenSocket") (TyVar "a")))
(DData Public "Shutdown" () ((variant "ShutdownRead" (ConPos)) (variant "ShutdownWrite" (ConPos)) (variant "ShutdownBoth" (ConPos))) ())
(DTypeSig true "resolve" (TyFun (TyNamed "host" (TyCon "String")) (TyEffect ((atom "Net" (name "host"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "resolve" ((PVar "host")) (EApp (EVar "netResolve") (EVar "host")))
(DTypeSig true "connect" (TyFun (TyNamed "host" (TyCon "String")) (TyFun (TyCon "Int") (TyEffect ((atom "Net" (name "host"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "host")))))))
(DFunDef false "connect" ((PVar "host") (PVar "port")) (EApp (EApp (EVar "netTcpConnect") (EVar "host")) (EVar "port")))
(DTypeSig true "listen" (TyFun (TyNamed "addr" (TyCon "String")) (TyFun (TyCon "Int") (TyEffect ((atom "Net" (name "addr"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Listener") (TyVar "addr")))))))
(DFunDef false "listen" ((PVar "addr") (PVar "port")) (EApp (EApp (EVar "netTcpListen") (EVar "addr")) (EVar "port")))
(DTypeSig true "listenPort" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyEffect ((atom "Net" (name "a"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "listenPort" ((PVar "lis")) (EApp (EVar "netListenPort") (EVar "lis")))
(DTypeSig true "accept" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyEffect ((atom "Net" (name "a"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "a"))))))
(DFunDef false "accept" ((PVar "lis")) (EApp (EVar "netTcpAccept") (EVar "lis")))
(DTypeSig true "send" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "send" ((PVar "conn") (PVar "bs")) (EApp (EApp (EVar "netSend") (EVar "conn")) (EVar "bs")))
(DTypeSig true "recv" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Int") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "recv" ((PVar "conn") (PVar "n")) (EApp (EApp (EVar "netRecv") (EVar "conn")) (EVar "n")))
(DTypeSig true "sendAll" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendAll" ((PVar "conn") (PVar "bs")) (EApp (EApp (EApp (EVar "sendAllFrom") (ELam ((PVar "bytes") (PVar "off")) (EApp (EApp (EApp (EVar "netSendFrom") (EVar "conn")) (EVar "bytes")) (EVar "off")))) (EVar "bs")) (ELit (LInt 0))))
(DTypeSig false "sendAllFrom" (TyFun (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "sendAllFrom" ((PVar "write") (PVar "bs") (PVar "off")) (EIf (EBinOp ">=" (EVar "off") (EApp (EVar "arrayLength") (EVar "bs"))) (EApp (EVar "Ok") (ELit LUnit)) (EMatch (EApp (EApp (EVar "write") (EVar "bs")) (EVar "off")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PLit (LInt 0))) () (EApp (EVar "Err") (ELit (LString "net.sendAll: 0 bytes written (connection stalled)")))) (arm (PCon "Ok" (PVar "n")) () (EApp (EApp (EApp (EVar "sendAllFrom") (EVar "write")) (EVar "bs")) (EBinOp "+" (EVar "off") (EVar "n")))))))
(DTypeSig false "testSentBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "testSentBytes" ((PVar "bs") (PVar "i") (PVar "hi")) (EIf (EBinOp ">=" (EVar "i") (EVar "hi")) (EListLit) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "bs")) (EApp (EApp (EApp (EVar "testSentBytes") (EVar "bs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "hi")))))
(DTypeSig false "testRecordAlias" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "testRecordAlias" ((PVar "first") (PVar "aliasSeen") (PVar "bs") (PVar "call")) (EIf (EBinOp "==" (EVar "call") (ELit (LInt 0))) (EApp (EApp (EVar "setRef") (EVar "first")) (EApp (EVar "Some") (EVar "bs"))) (EIf (EBinOp "==" (EVar "call") (ELit (LInt 1))) (EMatch (EUnOp "!" (EVar "first")) (arm (PCon "Some" (PVar "original")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (ELit (LInt 0))) (ELit (LInt 251))) (EVar "original"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "aliasSeen")) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "bs")) (ELit (LInt 251))))))) (arm (PCon "None") () (ELit LUnit))) (ELit LUnit))))
(DTypeSig false "testScriptedSend" (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))))))
(DFunDef false "testScriptedSend" ((PVar "calls") (PVar "offsets") (PVar "sent") (PVar "first") (PVar "aliasSeen") (PVar "bs") (PVar "off")) (EBlock (DoLet false false (PVar "call") (EUnOp "!" (EVar "calls"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EVar "call") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "offsets")) (EBinOp "++" (EUnOp "!" (EVar "offsets")) (EListLit (EVar "off"))))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "testRecordAlias") (EVar "first")) (EVar "aliasSeen")) (EVar "bs")) (EVar "call"))) (DoExpr (EIf (EBinOp ">=" (EVar "call") (ELit (LInt 3))) (EApp (EVar "Err") (ELit (LString "unexpected fourth send"))) (EBlock (DoLet false false (PVar "n") (EIf (EBinOp "==" (EVar "call") (ELit (LInt 0))) (ELit (LInt 2)) (EIf (EBinOp "==" (EVar "call") (ELit (LInt 1))) (ELit (LInt 3)) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bs")) (EVar "off"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "sent")) (EBinOp "++" (EUnOp "!" (EVar "sent")) (EApp (EApp (EApp (EVar "testSentBytes") (EVar "bs")) (EVar "off")) (EBinOp "+" (EVar "off") (EVar "n")))))) (DoExpr (EApp (EVar "Ok") (EVar "n"))))))))
(DTypeSig false "testScriptedObservation" (TyFun (TyCon "Unit") (TyTuple (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")) (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "testScriptedObservation" (PWild) (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "offsets") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "sent") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "first") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false (PVar "aliasSeen") (EApp (EVar "Ref") (EVar "False"))) (DoLet false false (PVar "payload") (EApp (EVar "arrayFromList") (EListLit (ELit (LInt 10)) (ELit (LInt 20)) (ELit (LInt 30)) (ELit (LInt 40)) (ELit (LInt 50)) (ELit (LInt 60)) (ELit (LInt 70)) (ELit (LInt 80))))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EVar "sendAllFrom") (EApp (EApp (EApp (EApp (EApp (EVar "testScriptedSend") (EVar "calls")) (EVar "offsets")) (EVar "sent")) (EVar "first")) (EVar "aliasSeen"))) (EVar "payload")) (ELit (LInt 0)))) (DoExpr (ETuple (EVar "result") (EUnOp "!" (EVar "calls")) (EUnOp "!" (EVar "offsets")) (EUnOp "!" (EVar "sent")) (EUnOp "!" (EVar "aliasSeen"))))))
(DTest false "sendAll keeps one array while offsets cover exact bytes" (EBlock (DoLet false false (PTuple (PVar "result") (PVar "calls") (PVar "offsets") (PVar "sent") (PVar "aliasSeen")) (EApp (EVar "testScriptedObservation") (ELit LUnit))) (DoExpr (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (ELit LUnit))) (EVar "result")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 3))) (EVar "calls")) (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 0)) (ELit (LInt 2)) (ELit (LInt 5)))) (EVar "offsets")) (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 10)) (ELit (LInt 20)) (ELit (LInt 30)) (ELit (LInt 40)) (ELit (LInt 50)) (ELit (LInt 60)) (ELit (LInt 70)) (ELit (LInt 80)))) (EVar "sent")) (EApp (EVar "expectTrue") (EVar "aliasSeen")))))))
(DTest false "sendAll rejects a zero-byte write exactly" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "net.sendAll: 0 bytes written (connection stalled)")))) (EApp (EApp (EApp (EVar "sendAllFrom") (ELam (PWild PWild) (EApp (EVar "Ok") (ELit (LInt 0))))) (EApp (EVar "arrayFromList") (EListLit (ELit (LInt 1))))) (ELit (LInt 0)))))
(DTypeSig false "testFirstErrorSend" (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "testFirstErrorSend" ((PVar "calls") (PVar "offsets") PWild (PVar "off")) (EBlock (DoLet false false (PVar "call") (EUnOp "!" (EVar "calls"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EVar "call") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "offsets")) (EBinOp "++" (EUnOp "!" (EVar "offsets")) (EListLit (EVar "off"))))) (DoExpr (EIf (EBinOp "==" (EVar "call") (ELit (LInt 0))) (EApp (EVar "Ok") (ELit (LInt 2))) (EIf (EBinOp "==" (EVar "call") (ELit (LInt 1))) (EApp (EVar "Err") (ELit (LString "boom"))) (EApp (EVar "Err") (ELit (LString "late call"))))))))
(DTest false "sendAll returns the first host error without another write" (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "offsets") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EVar "sendAllFrom") (EApp (EApp (EVar "testFirstErrorSend") (EVar "calls")) (EVar "offsets"))) (EApp (EVar "arrayFromList") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4))))) (ELit (LInt 0)))) (DoExpr (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "boom")))) (EVar "result")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 2))) (EUnOp "!" (EVar "calls"))) (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 0)) (ELit (LInt 2)))) (EUnOp "!" (EVar "offsets"))))))))
(DTypeSig false "recvAllLoop" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Vector") (TyCon "Int")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "recvAllLoop" ((PVar "conn") (PVar "buf")) (EMatch (EApp (EApp (EVar "recv") (EVar "conn")) (ELit (LInt 4096))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "chunk")) () (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "chunk")) (ELit (LInt 0))) (EApp (EVar "Ok") (EApp (EVar "toArray") (EVar "buf"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "b")) (ELet false PWild (EApp (EApp (EVar "push") (EVar "b")) (EVar "buf")) (EVar "acc")))) (ELit LUnit)) (EVar "chunk"))) (DoExpr (EApp (EApp (EVar "recvAllLoop") (EVar "conn")) (EVar "buf"))))))))
(DTypeSig true "recvAll" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))
(DFunDef false "recvAll" ((PVar "conn")) (EApp (EApp (EVar "recvAllLoop") (EVar "conn")) (EApp (EVar "new") (ELit LUnit))))
(DTypeSig true "sendString" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "String") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendString" ((PVar "conn") (PVar "s")) (EApp (EApp (EVar "sendAll") (EVar "conn")) (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig true "recvString" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "recvString" ((PVar "conn")) (EApp (EApp (EVar "map") (EVar "fromUtf8")) (EApp (EVar "recvAll") (EVar "conn"))))
(DTypeSig true "sendLine" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "String") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendLine" ((PVar "conn") (PVar "s")) (EApp (EApp (EVar "sendString") (EVar "conn")) (EBinOp "++" (EVar "s") (ELit (LString "\n")))))
(DTypeSig false "recvLineLoop" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Vector") (TyCon "Int")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "recvLineLoop" ((PVar "conn") (PVar "buf")) (EMatch (EApp (EApp (EVar "recv") (EVar "conn")) (ELit (LInt 1))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "chunk")) () (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "chunk")) (ELit (LInt 0))) (EIf (EApp (EVar "isEmpty") (EVar "buf")) (EApp (EVar "Ok") (EVar "None")) (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EVar "fromUtf8") (EApp (EVar "toArray") (EVar "buf")))))) (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "chunk"))) (DoExpr (EIf (EBinOp "==" (EVar "b") (ELit (LInt 10))) (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EVar "fromUtf8") (EApp (EVar "toArray") (EVar "buf"))))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "push") (EVar "b")) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "recvLineLoop") (EVar "conn")) (EVar "buf")))))))))))
(DTypeSig true "recvLine" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "recvLine" ((PVar "conn")) (EApp (EApp (EVar "recvLineLoop") (EVar "conn")) (EApp (EVar "new") (ELit LUnit))))
(DTypeSig true "shutdown" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Shutdown") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "shutdown" ((PVar "conn") (PVar "how")) (EApp (EApp (EVar "netShutdown") (EVar "conn")) (EApp (EVar "shutdownCode") (EVar "how"))))
(DTypeSig false "shutdownCode" (TyFun (TyCon "Shutdown") (TyCon "Int")))
(DFunDef false "shutdownCode" ((PCon "ShutdownRead")) (ELit (LInt 0)))
(DFunDef false "shutdownCode" ((PCon "ShutdownWrite")) (ELit (LInt 1)))
(DFunDef false "shutdownCode" ((PCon "ShutdownBoth")) (ELit (LInt 2)))
(DTypeSig true "close" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "close" ((PVar "conn")) (EApp (EVar "netClose") (EVar "conn")))
(DTypeSig true "closeListener" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyEffect ((atom "Net" (name "a"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "closeListener" ((PVar "lis")) (EApp (EVar "netCloseListener") (EVar "lis")))
(DTypeSig true "setTimeout" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Duration") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "setTimeout" ((PVar "conn") (PVar "d")) (EApp (EApp (EVar "netSetTimeout") (EVar "conn")) (EApp (EVar "toMillis") (EVar "d"))))
(DTypeSig true "withConnection" (TyFun (TyNamed "host" (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyFun (TyApp (TyCon "Connection") (TyVar "host")) (TyEffect ((atom "Net" (name "host"))) (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))) (TyEffect ((atom "Net" (name "host"))) (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))))
(DFunDef false "withConnection" ((PVar "host") (PVar "port") (PVar "body")) (EMatch (EApp (EApp (EVar "connect") (EVar "host")) (EVar "port")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "conn")) () (EBlock (DoLet false false (PVar "r") (EApp (EVar "body") (EVar "conn"))) (DoLet false false PWild (EApp (EVar "close") (EVar "conn"))) (DoExpr (EVar "r"))))))
(DTypeSig true "withListener" (TyFun (TyNamed "addr" (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyFun (TyApp (TyCon "Listener") (TyVar "addr")) (TyEffect ((atom "Net" (name "addr"))) (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))) (TyEffect ((atom "Net" (name "addr"))) (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))))
(DFunDef false "withListener" ((PVar "addr") (PVar "port") (PVar "body")) (EMatch (EApp (EApp (EVar "listen") (EVar "addr")) (EVar "port")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "lis")) () (EBlock (DoLet false false (PVar "r") (EApp (EVar "body") (EVar "lis"))) (DoLet false false PWild (EApp (EVar "closeListener") (EVar "lis"))) (DoExpr (EVar "r"))))))
(DTypeSig true "serveLoop" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyFun (TyFun (TyApp (TyCon "Connection") (TyVar "a")) (TyEffect ((atom "Net" (name "a"))) (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyEffect ((atom "Net" (name "a"))) (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "serveLoop" ((PVar "lis") (PVar "handle")) (EMatch (EApp (EVar "accept") (EVar "lis")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "conn")) () (EBlock (DoLet false false PWild (EApp (EVar "handle") (EVar "conn"))) (DoLet false false PWild (EApp (EVar "close") (EVar "conn"))) (DoExpr (EApp (EApp (EVar "serveLoop") (EVar "lis")) (EVar "handle")))))))
# MARK
(DUse false (UseGroup ("array") ((mem "setInPlace" false))))
(DUse false (UseGroup ("vector") ((mem "Vector" false) (mem "new" false) (mem "push" false) (mem "toArray" false))))
(DUse false (UseGroup ("string") ((mem "toUtf8" false) (mem "fromUtf8" false))))
(DUse false (UseGroup ("time") ((mem "Duration" false) (mem "toMillis" false))))
(DUse false (UseGroup ("test") ((mem "expectAll" false) (mem "expectEqual" false) (mem "expectTrue" false))))
(DTypeAlias true "Connection" ("h") (TyApp (TyCon "Socket") (TyVar "h")))
(DTypeAlias true "Listener" ("a") (TyApp (TyCon "ListenSocket") (TyVar "a")))
(DData Public "Shutdown" () ((variant "ShutdownRead" (ConPos)) (variant "ShutdownWrite" (ConPos)) (variant "ShutdownBoth" (ConPos))) ())
(DTypeSig true "resolve" (TyFun (TyNamed "host" (TyCon "String")) (TyEffect ((atom "Net" (name "host"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "resolve" ((PVar "host")) (EApp (EVar "netResolve") (EVar "host")))
(DTypeSig true "connect" (TyFun (TyNamed "host" (TyCon "String")) (TyFun (TyCon "Int") (TyEffect ((atom "Net" (name "host"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "host")))))))
(DFunDef false "connect" ((PVar "host") (PVar "port")) (EApp (EApp (EVar "netTcpConnect") (EVar "host")) (EVar "port")))
(DTypeSig true "listen" (TyFun (TyNamed "addr" (TyCon "String")) (TyFun (TyCon "Int") (TyEffect ((atom "Net" (name "addr"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Listener") (TyVar "addr")))))))
(DFunDef false "listen" ((PVar "addr") (PVar "port")) (EApp (EApp (EVar "netTcpListen") (EVar "addr")) (EVar "port")))
(DTypeSig true "listenPort" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyEffect ((atom "Net" (name "a"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "listenPort" ((PVar "lis")) (EApp (EVar "netListenPort") (EVar "lis")))
(DTypeSig true "accept" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyEffect ((atom "Net" (name "a"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Connection") (TyVar "a"))))))
(DFunDef false "accept" ((PVar "lis")) (EApp (EVar "netTcpAccept") (EVar "lis")))
(DTypeSig true "send" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "send" ((PVar "conn") (PVar "bs")) (EApp (EApp (EVar "netSend") (EVar "conn")) (EVar "bs")))
(DTypeSig true "recv" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Int") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "recv" ((PVar "conn") (PVar "n")) (EApp (EApp (EVar "netRecv") (EVar "conn")) (EVar "n")))
(DTypeSig true "sendAll" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendAll" ((PVar "conn") (PVar "bs")) (EApp (EApp (EApp (EVar "sendAllFrom") (ELam ((PVar "bytes") (PVar "off")) (EApp (EApp (EApp (EVar "netSendFrom") (EVar "conn")) (EVar "bytes")) (EVar "off")))) (EVar "bs")) (ELit (LInt 0))))
(DTypeSig false "sendAllFrom" (TyFun (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "sendAllFrom" ((PVar "write") (PVar "bs") (PVar "off")) (EIf (EBinOp ">=" (EVar "off") (EApp (EVar "arrayLength") (EVar "bs"))) (EApp (EVar "Ok") (ELit LUnit)) (EMatch (EApp (EApp (EVar "write") (EVar "bs")) (EVar "off")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PLit (LInt 0))) () (EApp (EVar "Err") (ELit (LString "net.sendAll: 0 bytes written (connection stalled)")))) (arm (PCon "Ok" (PVar "n")) () (EApp (EApp (EApp (EVar "sendAllFrom") (EVar "write")) (EVar "bs")) (EBinOp "+" (EVar "off") (EVar "n")))))))
(DTypeSig false "testSentBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "testSentBytes" ((PVar "bs") (PVar "i") (PVar "hi")) (EIf (EBinOp ">=" (EVar "i") (EVar "hi")) (EListLit) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "bs")) (EApp (EApp (EApp (EVar "testSentBytes") (EVar "bs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "hi")))))
(DTypeSig false "testRecordAlias" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "testRecordAlias" ((PVar "first") (PVar "aliasSeen") (PVar "bs") (PVar "call")) (EIf (EBinOp "==" (EVar "call") (ELit (LInt 0))) (EApp (EApp (EVar "setRef") (EVar "first")) (EApp (EVar "Some") (EVar "bs"))) (EIf (EBinOp "==" (EVar "call") (ELit (LInt 1))) (EMatch (EUnOp "!" (EVar "first")) (arm (PCon "Some" (PVar "original")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (ELit (LInt 0))) (ELit (LInt 251))) (EVar "original"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "aliasSeen")) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "bs")) (ELit (LInt 251))))))) (arm (PCon "None") () (ELit LUnit))) (ELit LUnit))))
(DTypeSig false "testScriptedSend" (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))))))
(DFunDef false "testScriptedSend" ((PVar "calls") (PVar "offsets") (PVar "sent") (PVar "first") (PVar "aliasSeen") (PVar "bs") (PVar "off")) (EBlock (DoLet false false (PVar "call") (EUnOp "!" (EVar "calls"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EVar "call") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "offsets")) (EBinOp "++" (EUnOp "!" (EVar "offsets")) (EListLit (EVar "off"))))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "testRecordAlias") (EVar "first")) (EVar "aliasSeen")) (EVar "bs")) (EVar "call"))) (DoExpr (EIf (EBinOp ">=" (EVar "call") (ELit (LInt 3))) (EApp (EVar "Err") (ELit (LString "unexpected fourth send"))) (EBlock (DoLet false false (PVar "n") (EIf (EBinOp "==" (EVar "call") (ELit (LInt 0))) (ELit (LInt 2)) (EIf (EBinOp "==" (EVar "call") (ELit (LInt 1))) (ELit (LInt 3)) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bs")) (EVar "off"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "sent")) (EBinOp "++" (EUnOp "!" (EVar "sent")) (EApp (EApp (EApp (EVar "testSentBytes") (EVar "bs")) (EVar "off")) (EBinOp "+" (EVar "off") (EVar "n")))))) (DoExpr (EApp (EVar "Ok") (EVar "n"))))))))
(DTypeSig false "testScriptedObservation" (TyFun (TyCon "Unit") (TyTuple (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")) (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "testScriptedObservation" (PWild) (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "offsets") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "sent") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "first") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false (PVar "aliasSeen") (EApp (EVar "Ref") (EVar "False"))) (DoLet false false (PVar "payload") (EApp (EVar "arrayFromList") (EListLit (ELit (LInt 10)) (ELit (LInt 20)) (ELit (LInt 30)) (ELit (LInt 40)) (ELit (LInt 50)) (ELit (LInt 60)) (ELit (LInt 70)) (ELit (LInt 80))))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EVar "sendAllFrom") (EApp (EApp (EApp (EApp (EApp (EVar "testScriptedSend") (EVar "calls")) (EVar "offsets")) (EVar "sent")) (EVar "first")) (EVar "aliasSeen"))) (EVar "payload")) (ELit (LInt 0)))) (DoExpr (ETuple (EVar "result") (EUnOp "!" (EVar "calls")) (EUnOp "!" (EVar "offsets")) (EUnOp "!" (EVar "sent")) (EUnOp "!" (EVar "aliasSeen"))))))
(DTest false "sendAll keeps one array while offsets cover exact bytes" (EBlock (DoLet false false (PTuple (PVar "result") (PVar "calls") (PVar "offsets") (PVar "sent") (PVar "aliasSeen")) (EApp (EVar "testScriptedObservation") (ELit LUnit))) (DoExpr (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (ELit LUnit))) (EVar "result")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 3))) (EVar "calls")) (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 0)) (ELit (LInt 2)) (ELit (LInt 5)))) (EVar "offsets")) (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 10)) (ELit (LInt 20)) (ELit (LInt 30)) (ELit (LInt 40)) (ELit (LInt 50)) (ELit (LInt 60)) (ELit (LInt 70)) (ELit (LInt 80)))) (EVar "sent")) (EApp (EVar "expectTrue") (EVar "aliasSeen")))))))
(DTest false "sendAll rejects a zero-byte write exactly" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "net.sendAll: 0 bytes written (connection stalled)")))) (EApp (EApp (EApp (EVar "sendAllFrom") (ELam (PWild PWild) (EApp (EVar "Ok") (ELit (LInt 0))))) (EApp (EVar "arrayFromList") (EListLit (ELit (LInt 1))))) (ELit (LInt 0)))))
(DTypeSig false "testFirstErrorSend" (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "testFirstErrorSend" ((PVar "calls") (PVar "offsets") PWild (PVar "off")) (EBlock (DoLet false false (PVar "call") (EUnOp "!" (EVar "calls"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EVar "call") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "offsets")) (EBinOp "++" (EUnOp "!" (EVar "offsets")) (EListLit (EVar "off"))))) (DoExpr (EIf (EBinOp "==" (EVar "call") (ELit (LInt 0))) (EApp (EVar "Ok") (ELit (LInt 2))) (EIf (EBinOp "==" (EVar "call") (ELit (LInt 1))) (EApp (EVar "Err") (ELit (LString "boom"))) (EApp (EVar "Err") (ELit (LString "late call"))))))))
(DTest false "sendAll returns the first host error without another write" (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "offsets") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EVar "sendAllFrom") (EApp (EApp (EVar "testFirstErrorSend") (EVar "calls")) (EVar "offsets"))) (EApp (EVar "arrayFromList") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4))))) (ELit (LInt 0)))) (DoExpr (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "boom")))) (EVar "result")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 2))) (EUnOp "!" (EVar "calls"))) (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 0)) (ELit (LInt 2)))) (EUnOp "!" (EVar "offsets"))))))))
(DTypeSig false "recvAllLoop" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Vector") (TyCon "Int")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "recvAllLoop" ((PVar "conn") (PVar "buf")) (EMatch (EApp (EApp (EVar "recv") (EVar "conn")) (ELit (LInt 4096))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "chunk")) () (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "chunk")) (ELit (LInt 0))) (EApp (EVar "Ok") (EApp (EVar "toArray") (EVar "buf"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "b")) (ELet false PWild (EApp (EApp (EVar "push") (EVar "b")) (EVar "buf")) (EVar "acc")))) (ELit LUnit)) (EVar "chunk"))) (DoExpr (EApp (EApp (EVar "recvAllLoop") (EVar "conn")) (EVar "buf"))))))))
(DTypeSig true "recvAll" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))
(DFunDef false "recvAll" ((PVar "conn")) (EApp (EApp (EVar "recvAllLoop") (EVar "conn")) (EApp (EVar "new") (ELit LUnit))))
(DTypeSig true "sendString" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "String") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendString" ((PVar "conn") (PVar "s")) (EApp (EApp (EVar "sendAll") (EVar "conn")) (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig true "recvString" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "recvString" ((PVar "conn")) (EApp (EApp (EMethodRef "map") (EVar "fromUtf8")) (EApp (EVar "recvAll") (EVar "conn"))))
(DTypeSig true "sendLine" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "String") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendLine" ((PVar "conn") (PVar "s")) (EApp (EApp (EVar "sendString") (EVar "conn")) (EBinOp "++" (EVar "s") (ELit (LString "\n")))))
(DTypeSig false "recvLineLoop" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyApp (TyCon "Vector") (TyCon "Int")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "recvLineLoop" ((PVar "conn") (PVar "buf")) (EMatch (EApp (EApp (EVar "recv") (EVar "conn")) (ELit (LInt 1))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "chunk")) () (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "chunk")) (ELit (LInt 0))) (EIf (EApp (EMethodRef "isEmpty") (EVar "buf")) (EApp (EVar "Ok") (EVar "None")) (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EVar "fromUtf8") (EApp (EVar "toArray") (EVar "buf")))))) (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "chunk"))) (DoExpr (EIf (EBinOp "==" (EVar "b") (ELit (LInt 10))) (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EVar "fromUtf8") (EApp (EVar "toArray") (EVar "buf"))))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "push") (EVar "b")) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "recvLineLoop") (EVar "conn")) (EVar "buf")))))))))))
(DTypeSig true "recvLine" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "recvLine" ((PVar "conn")) (EApp (EApp (EVar "recvLineLoop") (EVar "conn")) (EApp (EVar "new") (ELit LUnit))))
(DTypeSig true "shutdown" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Shutdown") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "shutdown" ((PVar "conn") (PVar "how")) (EApp (EApp (EVar "netShutdown") (EVar "conn")) (EApp (EVar "shutdownCode") (EVar "how"))))
(DTypeSig false "shutdownCode" (TyFun (TyCon "Shutdown") (TyCon "Int")))
(DFunDef false "shutdownCode" ((PCon "ShutdownRead")) (ELit (LInt 0)))
(DFunDef false "shutdownCode" ((PCon "ShutdownWrite")) (ELit (LInt 1)))
(DFunDef false "shutdownCode" ((PCon "ShutdownBoth")) (ELit (LInt 2)))
(DTypeSig true "close" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "close" ((PVar "conn")) (EApp (EVar "netClose") (EVar "conn")))
(DTypeSig true "closeListener" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyEffect ((atom "Net" (name "a"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "closeListener" ((PVar "lis")) (EApp (EVar "netCloseListener") (EVar "lis")))
(DTypeSig true "setTimeout" (TyFun (TyApp (TyCon "Connection") (TyVar "h")) (TyFun (TyCon "Duration") (TyEffect ((atom "Net" (name "h"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "setTimeout" ((PVar "conn") (PVar "d")) (EApp (EApp (EVar "netSetTimeout") (EVar "conn")) (EApp (EVar "toMillis") (EVar "d"))))
(DTypeSig true "withConnection" (TyFun (TyNamed "host" (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyFun (TyApp (TyCon "Connection") (TyVar "host")) (TyEffect ((atom "Net" (name "host"))) (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))) (TyEffect ((atom "Net" (name "host"))) (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))))
(DFunDef false "withConnection" ((PVar "host") (PVar "port") (PVar "body")) (EMatch (EApp (EApp (EVar "connect") (EVar "host")) (EVar "port")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "conn")) () (EBlock (DoLet false false (PVar "r") (EApp (EVar "body") (EVar "conn"))) (DoLet false false PWild (EApp (EVar "close") (EVar "conn"))) (DoExpr (EVar "r"))))))
(DTypeSig true "withListener" (TyFun (TyNamed "addr" (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyFun (TyApp (TyCon "Listener") (TyVar "addr")) (TyEffect ((atom "Net" (name "addr"))) (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))) (TyEffect ((atom "Net" (name "addr"))) (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))))
(DFunDef false "withListener" ((PVar "addr") (PVar "port") (PVar "body")) (EMatch (EApp (EApp (EVar "listen") (EVar "addr")) (EVar "port")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "lis")) () (EBlock (DoLet false false (PVar "r") (EApp (EVar "body") (EVar "lis"))) (DoLet false false PWild (EApp (EVar "closeListener") (EVar "lis"))) (DoExpr (EVar "r"))))))
(DTypeSig true "serveLoop" (TyFun (TyApp (TyCon "Listener") (TyVar "a")) (TyFun (TyFun (TyApp (TyCon "Connection") (TyVar "a")) (TyEffect ((atom "Net" (name "a"))) (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyEffect ((atom "Net" (name "a"))) (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "serveLoop" ((PVar "lis") (PVar "handle")) (EMatch (EApp (EVar "accept") (EVar "lis")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "conn")) () (EBlock (DoLet false false PWild (EApp (EVar "handle") (EVar "conn"))) (DoLet false false PWild (EApp (EVar "close") (EVar "conn"))) (DoExpr (EApp (EApp (EVar "serveLoop") (EVar "lis")) (EVar "handle")))))))
