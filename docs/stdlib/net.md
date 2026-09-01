# net

net.mdk — an ergonomic TCP/DNS layer over the host `net*` externs.

The irreducible host primitives are `extern`s in stdlib/runtime.mdk:
`netResolve`/`netTcpConnect`/`netTcpListen`/`netListenPort`/`netTcpAccept`/
`netSend`/`netRecv`/`netShutdown`/`netClose`/`netSetTimeout`. They traffic raw
tagged `Int` fds and are global (no import needed). This module (`import net`)
wraps them in abstract `Connection`/`Listener` handles (unexported
constructors — a caller cannot fabricate a fd, mix up a listening socket with
a connected one, or do arithmetic on a handle), adds short-read/short-write
loops (`sendAll`/`recvAll`), text convenience (`sendString`/`recvString`/
`sendLine`/`recvLine`), and the leak-safety brackets `withConnection`/
`withListener`/`serveLoop` (see NET-DESIGN.md §4: Medaka has no RAII/`finally`,
so "always close on both the `Ok` and `Err` body path" is done here, not by
the language).

Conventions (mirroring stdlib/fs.mdk): every op returns `Result String _`
with the host error message (errno strerror) in `Err`. There is no IO
monad — an action runs when it is evaluated, so you can `match connect host
port` directly.

Scope: NATIVE/LLVM, build-only. Like every net extern, these execute only
through the compiled (`medaka build`) path — `net` externs are unbound under
the tree-walking interpreter (`medaka run`), exactly like `fs`/`io`'s file
externs (NET-DESIGN.md §6). Doctests here would try to run through the
interpreter and fail for that reason alone, so this module is verified by a
compiled loopback fixture instead of `medaka test` doctests (NET-DESIGN.md
§7's documented caveat) — doc-comments below show non-executing usage. Also
native-only for a second reason: WasmGC has no raw-socket equivalent, so
`medaka build --target wasm` rejects any program importing `net`.

## `Connection`

```
data Connection
  = Connection Int
```

A connected TCP socket (from `connect` or `accept`). Opaque — wraps the raw
fd, but the constructor is private so a `Connection` can't be fabricated or
confused with a `Listener`.

## `Listener`

```
data Listener
  = Listener Int
```

A listening TCP socket (from `listen`), not yet accepted.

## `resolve`

```
resolve : String -> <Net _> Result String (List String)
```

Resolve a hostname to its numeric IP address strings (`getaddrinfo`).

Non-executing example (net is unbound under `medaka run`; see module doc):
`resolve "localhost"` yields `Ok ["127.0.0.1", …]`.

## `connect`

```
connect : String -> Int -> <Net _> Result String Connection
```

Connect to `host`:`port` (DNS resolution happens internally). Prefer
`withConnection` over a bare `connect` unless you need to hold the
connection across a larger scope than one bracketed call.

## `listen`

```
listen : String -> Int -> <Net _> Result String Listener
```

Bind + listen on `addr`:`port` (port `0` picks an OS-assigned ephemeral
port — pair with `listenPort` to discover it; this is what makes a
single-process loopback self-test hermetic).

## `listenPort`

```
listenPort : Listener -> <Net _> Result String Int
```

The actual bound port of a `Listener` (useful after `listen addr 0`).

## `accept`

```
accept : Listener -> <Net _> Result String Connection
```

Block until a peer connects, then return the accepted `Connection`.

## `send`

```
send : Connection -> Array Int -> <Net _> Result String Int
```

One `send(2)` call. May write FEWER bytes than given (`Ok n` with
`n < length bs`) — use `sendAll` unless you are handling short writes
yourself.

## `recv`

```
recv : Connection -> Int -> <Net _> Result String (Array Int)
```

One `recv(2)` call, at most `n` bytes. `Ok []` (an empty `Array`) means the
peer closed the connection (EOF) — use `recvAll` to read to EOF.

## `shutdown`

```
shutdown : Connection -> Int -> <Net _> Result String Unit
```

Shut down `how` (0=read, 1=write, 2=both) of a connection without closing
the fd. Rarely needed directly — `close`/the brackets are the common path.

## `close`

```
close : Connection -> <Net _> Result String Unit
```

Close a connection's fd. Idempotent-safe (a double `close` is `Ok`, per the
C shim). Prefer `withConnection`, which calls this for you on every path.

## `closeListener`

```
closeListener : Listener -> <Net _> Result String Unit
```

Close a listener's fd (mirrors `close`, for the `Listener` handle).

## `setTimeout`

```
setTimeout : Connection -> Int -> <Net _> Result String Unit
```

Set the socket read/write timeout in milliseconds (`0` = blocking, no
timeout). Recommended on any long-lived connection — a blocking-only model
needs a timeout to avoid hanging forever on a stalled peer.

## `sendAll`

```
sendAll : Connection -> Array Int -> <Net _> Result String Unit
```

Write every byte of `bs`, looping over `send` as needed (BSD `send` may
write fewer bytes than asked — see `send`'s doc). `Err` on the first failed
`send`. A `send` that legitimately reports `0` written on a non-empty buffer
is treated as a stalled connection and reported as `Err`, so this loop is
guaranteed to terminate.

## `recvAll`

```
recvAll : Connection -> <Net _> Result String (Array Int)
```

Read until the peer closes the connection (EOF), accumulating every chunk.
`Err` on the first failed `recv` (whatever has been read so far is
discarded — a partial read is not distinguishable from a fresh failure).

## `sendString`

```
sendString : Connection -> String -> <Net _> Result String Unit
```

Encode `s` as UTF-8 and write every byte (`sendAll`).

## `recvString`

```
recvString : Connection -> <Net _> Result String String
```

Read to EOF and decode the bytes as UTF-8 (`recvAll` + `fromUtf8`). Use
`recvString` only when the peer is expected to close after writing (e.g. a
one-shot request/response); for a persistent connection, size a `recv`/
`recvN` read explicitly instead.

## `sendLine`

```
sendLine : Connection -> String -> <Net _> Result String Unit
```

Send `s` followed by `"\n"`, UTF-8 encoded (`sendAll`).

## `recvLine`

```
recvLine : Connection -> <Net _> Result String (Option String)
```

Read one line (up to and excluding `"\n"`), byte at a time. `Some line` on
a complete or EOF-terminated line with content; `None` at a clean EOF with
nothing buffered. Byte-at-a-time `recv` keeps this simple and correct
(no read-ahead buffer to manage across calls) at the cost of a syscall per
byte — fine for line-oriented protocols exchanging small messages, not
recommended for bulk transfer (use `recvAll`/`recv` there).

## `withConnection`

```
withConnection : String -> Int -> (Connection -> <Net _> Result String a) -> <Net _> Result String a
```

Connect to `host`:`port`, run `body` on the resulting `Connection`, and
close it afterward NO MATTER what `body` returns (`Ok` or `Err`). Returns
`body`'s result. If `connect` itself fails, `body` never runs and there is
nothing to close.

Non-executing example:
`withConnection "127.0.0.1" 9000 (conn => sendString conn "hi")`

## `withListener`

```
withListener : String -> Int -> (Listener -> <Net _> Result String a) -> <Net _> Result String a
```

Bind + listen on `addr`:`port`, run `body` on the resulting `Listener`, and
close it afterward NO MATTER what `body` returns. Returns `body`'s result.

## `serveLoop`

```
serveLoop : Listener -> (Connection -> <Net _> Result String Unit) -> <Net _> Result String Unit
```

Accept connections from `lis` in a loop, handing each to `handle` and
closing it afterward (the per-connection bracket keeps one handler's `Err`
from leaking that connection's fd or aborting the loop). Recurses forever —
a listener-level `accept` failure propagates up and ends the loop; a
per-connection `handle` failure does not (it's swallowed after closing, so
the server keeps serving). Pair with `withListener` to close the listener
itself when the loop does end.

