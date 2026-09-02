# META
source_lines=238
stages=DESUGAR,MARK
# SOURCE
{- | TCP connections and name resolution.

   `connect` opens a connection and `listen` and `accept` receive them.
   `Connection` and `Listener` are opaque handles: they cannot be built from
   a raw descriptor or confused with each other. `sendAll` and `recvAll`
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

import array.{drop}
import vector.{Vector, new, push, toArray}
import string.{toUtf8, fromUtf8}

-- # Handles

-- Constructors are not exported: user code can hold a `Connection`/`Listener`
-- but cannot construct, inspect, or forge one from a raw `Int`.

-- | A connected TCP socket, from `connect` or `accept`.
export data Connection = Connection Int

-- | A listening TCP socket, from `listen`.
export data Listener = Listener Int

-- # Clients

{- | The numeric addresses a host name resolves to.

   `resolve "localhost"` gives `Ok ["127.0.0.1"]` or similar. -}
export
resolve : String -> <Net "_"> Result String (List String)
resolve host = netResolve host

{- | A connection to `host` on `port`.

   The host name is resolved first. `withConnection` is the form that
   closes the connection for you. -}
export
connect : String -> Int -> <Net "_"> Result String Connection
connect host port = map Connection (netTcpConnect host port)

-- # Servers

{- | A listener bound to `addr` on `port`.

   Port `0` lets the system pick a free port; `listenPort` reports which. -}
export
listen : String -> Int -> <Net "_"> Result String Listener
listen addr port = map Listener (netTcpListen addr port)

-- | The port a listener is bound to.
export
listenPort : Listener -> <Net "_"> Result String Int
listenPort (Listener fd) = netListenPort fd

-- | Waits for the next connection to a listener.
export
accept : Listener -> <Net "_"> Result String Connection
accept (Listener fd) = map Connection (netTcpAccept fd)

-- # Transfer

{- | Sends bytes in one call. The result is the number of bytes written,
   which may be fewer than given.

   `sendAll` is the form that sends everything. -}
export
send : Connection -> Array Int -> <Net "_"> Result String Int
send (Connection fd) bs = netSend fd bs

{- | Receives up to `n` bytes in one call.

   An empty array means the peer has closed the connection. `recvAll` is the
   form that reads to the end. -}
export
recv : Connection -> Int -> <Net "_"> Result String (Array Int)
recv (Connection fd) n = netRecv fd n

{- | Sends every byte, looping over `send` as needed.

   `Err` on the first failed send, or when a send writes nothing, which is
   treated as a stalled connection. -}
export
sendAll : Connection -> Array Int -> <Net "_"> Result String Unit
sendAll conn bs =
  if arrayLength bs == 0 then Ok ()
  else match send conn bs
    Err e => Err e
    Ok 0 => Err "net.sendAll: 0 bytes written (connection stalled)"
    Ok n => sendAll conn (drop n bs)

recvAllLoop : Connection -> Vector Int -> <Net "_"> Result String (Array Int)
recvAllLoop conn buf = match recv conn 4096
  Err e => Err e
  Ok chunk => if arrayLength chunk == 0 then Ok (toArray buf)
  else
    let _ = fold (acc b => let _ = push b buf in acc) () chunk
    recvAllLoop conn buf

{- | Receives everything until the peer closes the connection.

   `Err` on the first failed receive; whatever was read before it is
   discarded. -}
export
recvAll : Connection -> <Net "_"> Result String (Array Int)
recvAll conn = recvAllLoop conn (new ())

-- # Text

-- | Sends a string as UTF-8, every byte of it.
export
sendString : Connection -> String -> <Net "_"> Result String Unit
sendString conn s = sendAll conn (toUtf8 s)

{- | Receives everything until the peer closes the connection, decoded as
   UTF-8.

   For a connection that stays open, read a line at a time with `recvLine`
   or a bounded amount with `recv`. -}
export
recvString : Connection -> <Net "_"> Result String String
recvString conn = map fromUtf8 (recvAll conn)

-- | Sends a string as UTF-8 followed by a newline.
export
sendLine : Connection -> String -> <Net "_"> Result String Unit
sendLine conn s = sendString conn (s ++ "\n")

recvLineLoop : Connection -> Vector Int -> <Net "_"> Result String (Option String)
recvLineLoop conn buf =
  match recv conn 1
    Err e => Err e
    Ok chunk =>
      if arrayLength chunk == 0 then
        -- EOF: no trailing newline seen. Report whatever was buffered, if any.
        if isEmpty buf then Ok None
        else Ok (Some (fromUtf8 (toArray buf)))
      else
        let b = arrayGetUnsafe 0 chunk
        if b == 10 then Ok (Some (fromUtf8 (toArray buf)))
        else
          let _ = push b buf
          recvLineLoop conn buf

{- | Receives one line, without its newline.

   `None` when the peer has closed the connection and nothing was pending.
   A final line with no newline is still returned. Reads one byte per call,
   so it suits small line-based messages, not bulk transfer. -}
export
recvLine : Connection -> <Net "_"> Result String (Option String)
recvLine conn = recvLineLoop conn (new ())

-- # Lifecycle

{- | Shuts down one or both directions of a connection without closing it:
   `0` for reading, `1` for writing, `2` for both. -}
export
shutdown : Connection -> Int -> <Net "_"> Result String Unit
shutdown (Connection fd) how = netShutdown fd how

{- | Closes a connection.

   Closing twice is not an error. `withConnection` closes for you. -}
export
close : Connection -> <Net "_"> Result String Unit
close (Connection fd) = netClose fd

-- | Closes a listener.
export
closeListener : Listener -> <Net "_"> Result String Unit
closeListener (Listener fd) = netClose fd

{- | Sets a connection's send and receive timeout in milliseconds.

   `0` means no timeout. Set one on any long-lived connection so a stalled
   peer cannot block forever. -}
export
setTimeout : Connection -> Int -> <Net "_"> Result String Unit
setTimeout (Connection fd) ms = netSetTimeout fd ms

{- | Connects to `host` on `port`, runs `body` on the connection, and closes
   it whatever `body` returns.

   The result is `body`'s result, or the connection error when connecting
   fails, in which case `body` does not run.

   `withConnection "127.0.0.1" 9000 (conn => sendString conn "hi")` -}
export
withConnection : String -> Int -> (Connection -> <Net "_"> Result String a) -> <Net "_"> Result String a
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
withListener : String -> Int -> (Listener -> <Net "_"> Result String a) -> <Net "_"> Result String a
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
serveLoop : Listener -> (Connection -> <Net "_"> Result String Unit) -> <Net "_"> Result String Unit
serveLoop lis handle = match accept lis
  Err e => Err e
  Ok conn =>
    let _ = handle conn
    let _ = close conn
    serveLoop lis handle
# DESUGAR
(DUse false (UseGroup ("array") ((mem "drop" false))))
(DUse false (UseGroup ("vector") ((mem "Vector" false) (mem "new" false) (mem "push" false) (mem "toArray" false))))
(DUse false (UseGroup ("string") ((mem "toUtf8" false) (mem "fromUtf8" false))))
(DData Abstract "Connection" () ((variant "Connection" (ConPos (TyCon "Int")))) ())
(DData Abstract "Listener" () ((variant "Listener" (ConPos (TyCon "Int")))) ())
(DTypeSig true "resolve" (TyFun (TyCon "String") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "resolve" ((PVar "host")) (EApp (EVar "netResolve") (EVar "host")))
(DTypeSig true "connect" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Connection"))))))
(DFunDef false "connect" ((PVar "host") (PVar "port")) (EApp (EApp (EVar "map") (EVar "Connection")) (EApp (EApp (EVar "netTcpConnect") (EVar "host")) (EVar "port"))))
(DTypeSig true "listen" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Listener"))))))
(DFunDef false "listen" ((PVar "addr") (PVar "port")) (EApp (EApp (EVar "map") (EVar "Listener")) (EApp (EApp (EVar "netTcpListen") (EVar "addr")) (EVar "port"))))
(DTypeSig true "listenPort" (TyFun (TyCon "Listener") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "listenPort" ((PCon "Listener" (PVar "fd"))) (EApp (EVar "netListenPort") (EVar "fd")))
(DTypeSig true "accept" (TyFun (TyCon "Listener") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Connection")))))
(DFunDef false "accept" ((PCon "Listener" (PVar "fd"))) (EApp (EApp (EVar "map") (EVar "Connection")) (EApp (EVar "netTcpAccept") (EVar "fd"))))
(DTypeSig true "send" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "send" ((PCon "Connection" (PVar "fd")) (PVar "bs")) (EApp (EApp (EVar "netSend") (EVar "fd")) (EVar "bs")))
(DTypeSig true "recv" (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "recv" ((PCon "Connection" (PVar "fd")) (PVar "n")) (EApp (EApp (EVar "netRecv") (EVar "fd")) (EVar "n")))
(DTypeSig true "sendAll" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendAll" ((PVar "conn") (PVar "bs")) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "bs")) (ELit (LInt 0))) (EApp (EVar "Ok") (ELit LUnit)) (EMatch (EApp (EApp (EVar "send") (EVar "conn")) (EVar "bs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PLit (LInt 0))) () (EApp (EVar "Err") (ELit (LString "net.sendAll: 0 bytes written (connection stalled)")))) (arm (PCon "Ok" (PVar "n")) () (EApp (EApp (EVar "sendAll") (EVar "conn")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "bs")))))))
(DTypeSig false "recvAllLoop" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Vector") (TyCon "Int")) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "recvAllLoop" ((PVar "conn") (PVar "buf")) (EMatch (EApp (EApp (EVar "recv") (EVar "conn")) (ELit (LInt 4096))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "chunk")) () (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "chunk")) (ELit (LInt 0))) (EApp (EVar "Ok") (EApp (EVar "toArray") (EVar "buf"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "b")) (ELet false PWild (EApp (EApp (EVar "push") (EVar "b")) (EVar "buf")) (EVar "acc")))) (ELit LUnit)) (EVar "chunk"))) (DoExpr (EApp (EApp (EVar "recvAllLoop") (EVar "conn")) (EVar "buf"))))))))
(DTypeSig true "recvAll" (TyFun (TyCon "Connection") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))
(DFunDef false "recvAll" ((PVar "conn")) (EApp (EApp (EVar "recvAllLoop") (EVar "conn")) (EApp (EVar "new") (ELit LUnit))))
(DTypeSig true "sendString" (TyFun (TyCon "Connection") (TyFun (TyCon "String") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendString" ((PVar "conn") (PVar "s")) (EApp (EApp (EVar "sendAll") (EVar "conn")) (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig true "recvString" (TyFun (TyCon "Connection") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "recvString" ((PVar "conn")) (EApp (EApp (EVar "map") (EVar "fromUtf8")) (EApp (EVar "recvAll") (EVar "conn"))))
(DTypeSig true "sendLine" (TyFun (TyCon "Connection") (TyFun (TyCon "String") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendLine" ((PVar "conn") (PVar "s")) (EApp (EApp (EVar "sendString") (EVar "conn")) (EBinOp "++" (EVar "s") (ELit (LString "\n")))))
(DTypeSig false "recvLineLoop" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Vector") (TyCon "Int")) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "recvLineLoop" ((PVar "conn") (PVar "buf")) (EMatch (EApp (EApp (EVar "recv") (EVar "conn")) (ELit (LInt 1))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "chunk")) () (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "chunk")) (ELit (LInt 0))) (EIf (EApp (EVar "isEmpty") (EVar "buf")) (EApp (EVar "Ok") (EVar "None")) (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EVar "fromUtf8") (EApp (EVar "toArray") (EVar "buf")))))) (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "chunk"))) (DoExpr (EIf (EBinOp "==" (EVar "b") (ELit (LInt 10))) (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EVar "fromUtf8") (EApp (EVar "toArray") (EVar "buf"))))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "push") (EVar "b")) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "recvLineLoop") (EVar "conn")) (EVar "buf")))))))))))
(DTypeSig true "recvLine" (TyFun (TyCon "Connection") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "recvLine" ((PVar "conn")) (EApp (EApp (EVar "recvLineLoop") (EVar "conn")) (EApp (EVar "new") (ELit LUnit))))
(DTypeSig true "shutdown" (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "shutdown" ((PCon "Connection" (PVar "fd")) (PVar "how")) (EApp (EApp (EVar "netShutdown") (EVar "fd")) (EVar "how")))
(DTypeSig true "close" (TyFun (TyCon "Connection") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "close" ((PCon "Connection" (PVar "fd"))) (EApp (EVar "netClose") (EVar "fd")))
(DTypeSig true "closeListener" (TyFun (TyCon "Listener") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "closeListener" ((PCon "Listener" (PVar "fd"))) (EApp (EVar "netClose") (EVar "fd")))
(DTypeSig true "setTimeout" (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "setTimeout" ((PCon "Connection" (PVar "fd")) (PVar "ms")) (EApp (EApp (EVar "netSetTimeout") (EVar "fd")) (EVar "ms")))
(DTypeSig true "withConnection" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Connection") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))))
(DFunDef false "withConnection" ((PVar "host") (PVar "port") (PVar "body")) (EMatch (EApp (EApp (EVar "connect") (EVar "host")) (EVar "port")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "conn")) () (EBlock (DoLet false false (PVar "r") (EApp (EVar "body") (EVar "conn"))) (DoLet false false PWild (EApp (EVar "close") (EVar "conn"))) (DoExpr (EVar "r"))))))
(DTypeSig true "withListener" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Listener") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))))
(DFunDef false "withListener" ((PVar "addr") (PVar "port") (PVar "body")) (EMatch (EApp (EApp (EVar "listen") (EVar "addr")) (EVar "port")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "lis")) () (EBlock (DoLet false false (PVar "r") (EApp (EVar "body") (EVar "lis"))) (DoLet false false PWild (EApp (EVar "closeListener") (EVar "lis"))) (DoExpr (EVar "r"))))))
(DTypeSig true "serveLoop" (TyFun (TyCon "Listener") (TyFun (TyFun (TyCon "Connection") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "serveLoop" ((PVar "lis") (PVar "handle")) (EMatch (EApp (EVar "accept") (EVar "lis")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "conn")) () (EBlock (DoLet false false PWild (EApp (EVar "handle") (EVar "conn"))) (DoLet false false PWild (EApp (EVar "close") (EVar "conn"))) (DoExpr (EApp (EApp (EVar "serveLoop") (EVar "lis")) (EVar "handle")))))))
# MARK
(DUse false (UseGroup ("array") ((mem "drop" false))))
(DUse false (UseGroup ("vector") ((mem "Vector" false) (mem "new" false) (mem "push" false) (mem "toArray" false))))
(DUse false (UseGroup ("string") ((mem "toUtf8" false) (mem "fromUtf8" false))))
(DData Abstract "Connection" () ((variant "Connection" (ConPos (TyCon "Int")))) ())
(DData Abstract "Listener" () ((variant "Listener" (ConPos (TyCon "Int")))) ())
(DTypeSig true "resolve" (TyFun (TyCon "String") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "resolve" ((PVar "host")) (EApp (EVar "netResolve") (EVar "host")))
(DTypeSig true "connect" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Connection"))))))
(DFunDef false "connect" ((PVar "host") (PVar "port")) (EApp (EApp (EMethodRef "map") (EVar "Connection")) (EApp (EApp (EVar "netTcpConnect") (EVar "host")) (EVar "port"))))
(DTypeSig true "listen" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Listener"))))))
(DFunDef false "listen" ((PVar "addr") (PVar "port")) (EApp (EApp (EMethodRef "map") (EVar "Listener")) (EApp (EApp (EVar "netTcpListen") (EVar "addr")) (EVar "port"))))
(DTypeSig true "listenPort" (TyFun (TyCon "Listener") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "listenPort" ((PCon "Listener" (PVar "fd"))) (EApp (EVar "netListenPort") (EVar "fd")))
(DTypeSig true "accept" (TyFun (TyCon "Listener") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Connection")))))
(DFunDef false "accept" ((PCon "Listener" (PVar "fd"))) (EApp (EApp (EMethodRef "map") (EVar "Connection")) (EApp (EVar "netTcpAccept") (EVar "fd"))))
(DTypeSig true "send" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "send" ((PCon "Connection" (PVar "fd")) (PVar "bs")) (EApp (EApp (EVar "netSend") (EVar "fd")) (EVar "bs")))
(DTypeSig true "recv" (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "recv" ((PCon "Connection" (PVar "fd")) (PVar "n")) (EApp (EApp (EVar "netRecv") (EVar "fd")) (EVar "n")))
(DTypeSig true "sendAll" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendAll" ((PVar "conn") (PVar "bs")) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "bs")) (ELit (LInt 0))) (EApp (EVar "Ok") (ELit LUnit)) (EMatch (EApp (EApp (EVar "send") (EVar "conn")) (EVar "bs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PLit (LInt 0))) () (EApp (EVar "Err") (ELit (LString "net.sendAll: 0 bytes written (connection stalled)")))) (arm (PCon "Ok" (PVar "n")) () (EApp (EApp (EVar "sendAll") (EVar "conn")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "bs")))))))
(DTypeSig false "recvAllLoop" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Vector") (TyCon "Int")) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "recvAllLoop" ((PVar "conn") (PVar "buf")) (EMatch (EApp (EApp (EVar "recv") (EVar "conn")) (ELit (LInt 4096))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "chunk")) () (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "chunk")) (ELit (LInt 0))) (EApp (EVar "Ok") (EApp (EVar "toArray") (EVar "buf"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "b")) (ELet false PWild (EApp (EApp (EVar "push") (EVar "b")) (EVar "buf")) (EVar "acc")))) (ELit LUnit)) (EVar "chunk"))) (DoExpr (EApp (EApp (EVar "recvAllLoop") (EVar "conn")) (EVar "buf"))))))))
(DTypeSig true "recvAll" (TyFun (TyCon "Connection") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))
(DFunDef false "recvAll" ((PVar "conn")) (EApp (EApp (EVar "recvAllLoop") (EVar "conn")) (EApp (EVar "new") (ELit LUnit))))
(DTypeSig true "sendString" (TyFun (TyCon "Connection") (TyFun (TyCon "String") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendString" ((PVar "conn") (PVar "s")) (EApp (EApp (EVar "sendAll") (EVar "conn")) (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig true "recvString" (TyFun (TyCon "Connection") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "recvString" ((PVar "conn")) (EApp (EApp (EMethodRef "map") (EVar "fromUtf8")) (EApp (EVar "recvAll") (EVar "conn"))))
(DTypeSig true "sendLine" (TyFun (TyCon "Connection") (TyFun (TyCon "String") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "sendLine" ((PVar "conn") (PVar "s")) (EApp (EApp (EVar "sendString") (EVar "conn")) (EBinOp "++" (EVar "s") (ELit (LString "\n")))))
(DTypeSig false "recvLineLoop" (TyFun (TyCon "Connection") (TyFun (TyApp (TyCon "Vector") (TyCon "Int")) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "recvLineLoop" ((PVar "conn") (PVar "buf")) (EMatch (EApp (EApp (EVar "recv") (EVar "conn")) (ELit (LInt 1))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "chunk")) () (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "chunk")) (ELit (LInt 0))) (EIf (EApp (EMethodRef "isEmpty") (EVar "buf")) (EApp (EVar "Ok") (EVar "None")) (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EVar "fromUtf8") (EApp (EVar "toArray") (EVar "buf")))))) (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "chunk"))) (DoExpr (EIf (EBinOp "==" (EVar "b") (ELit (LInt 10))) (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EVar "fromUtf8") (EApp (EVar "toArray") (EVar "buf"))))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "push") (EVar "b")) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "recvLineLoop") (EVar "conn")) (EVar "buf")))))))))))
(DTypeSig true "recvLine" (TyFun (TyCon "Connection") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "recvLine" ((PVar "conn")) (EApp (EApp (EVar "recvLineLoop") (EVar "conn")) (EApp (EVar "new") (ELit LUnit))))
(DTypeSig true "shutdown" (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "shutdown" ((PCon "Connection" (PVar "fd")) (PVar "how")) (EApp (EApp (EVar "netShutdown") (EVar "fd")) (EVar "how")))
(DTypeSig true "close" (TyFun (TyCon "Connection") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "close" ((PCon "Connection" (PVar "fd"))) (EApp (EVar "netClose") (EVar "fd")))
(DTypeSig true "closeListener" (TyFun (TyCon "Listener") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "closeListener" ((PCon "Listener" (PVar "fd"))) (EApp (EVar "netClose") (EVar "fd")))
(DTypeSig true "setTimeout" (TyFun (TyCon "Connection") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "setTimeout" ((PCon "Connection" (PVar "fd")) (PVar "ms")) (EApp (EApp (EVar "netSetTimeout") (EVar "fd")) (EVar "ms")))
(DTypeSig true "withConnection" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Connection") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))))
(DFunDef false "withConnection" ((PVar "host") (PVar "port") (PVar "body")) (EMatch (EApp (EApp (EVar "connect") (EVar "host")) (EVar "port")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "conn")) () (EBlock (DoLet false false (PVar "r") (EApp (EVar "body") (EVar "conn"))) (DoLet false false PWild (EApp (EVar "close") (EVar "conn"))) (DoExpr (EVar "r"))))))
(DTypeSig true "withListener" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Listener") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))))
(DFunDef false "withListener" ((PVar "addr") (PVar "port") (PVar "body")) (EMatch (EApp (EApp (EVar "listen") (EVar "addr")) (EVar "port")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "lis")) () (EBlock (DoLet false false (PVar "r") (EApp (EVar "body") (EVar "lis"))) (DoLet false false PWild (EApp (EVar "closeListener") (EVar "lis"))) (DoExpr (EVar "r"))))))
(DTypeSig true "serveLoop" (TyFun (TyCon "Listener") (TyFun (TyFun (TyCon "Connection") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "serveLoop" ((PVar "lis") (PVar "handle")) (EMatch (EApp (EVar "accept") (EVar "lis")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "conn")) () (EBlock (DoLet false false PWild (EApp (EVar "handle") (EVar "conn"))) (DoLet false false PWild (EApp (EVar "close") (EVar "conn"))) (DoExpr (EApp (EApp (EVar "serveLoop") (EVar "lis")) (EVar "handle")))))))
