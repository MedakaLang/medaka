# net

TCP connections and name resolution.

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
WebAssembly backend rejects a program that imports this module.

## Handles

### `Connection`

```
data Connection
  = Connection Int
```

A connected TCP socket, from `connect` or `accept`.

### `Listener`

```
data Listener
  = Listener Int
```

A listening TCP socket, from `listen`.

### `Shutdown`

```
data Shutdown
  = ShutdownRead
  | ShutdownWrite
  | ShutdownBoth
```

Which direction of a connection `shutdown` closes.

## Clients

### `resolve`

```
resolve : (host : String) -> <Net host> Result String (List String)
resolve host
```

The numeric addresses a host name resolves to.

`resolve "localhost"` gives `Ok ["127.0.0.1"]` or similar.

### `connect`

```
connect : (host : String) -> Int -> <Net host> Result String Connection
connect host port
```

A connection to `host` on `port`.

The host name is resolved first. `withConnection` is the form that
closes the connection for you.

## Servers

### `listen`

```
listen : (addr : String) -> Int -> <Net addr> Result String Listener
listen addr port
```

A listener bound to `addr` on `port`.

Port `0` lets the system pick a free port; `listenPort` reports which.

### `listenPort`

```
listenPort : Listener -> <Net> Result String Int
```

The port a listener is bound to.

### `accept`

```
accept : Listener -> <Net> Result String Connection
```

Waits for the next connection to a listener.

## Transfer

### `send`

```
send : Connection -> Array Int -> <Net> Result String Int
send _ bs
```

Sends bytes in one call. The result is the number of bytes written,
which may be fewer than given.

`sendAll` is the form that sends everything.

### `recv`

```
recv : Connection -> Int -> <Net> Result String (Array Int)
recv _ n
```

Receives up to `n` bytes in one call.

An empty array means the peer has closed the connection. `recvAll` is the
form that reads to the end.

### `sendAll`

```
sendAll : Connection -> Array Int -> <Net> Result String Unit
sendAll _ bs
```

Sends every byte, looping over `send` as needed.

`Err` on the first failed send, or when a send writes nothing, which is
treated as a stalled connection.

### `recvAll`

```
recvAll : Connection -> <Net> Result String (Array Int)
recvAll conn
```

Receives everything until the peer closes the connection.

`Err` on the first failed receive; whatever was read before it is
discarded.

## Text

### `sendString`

```
sendString : Connection -> String -> <Net> Result String Unit
sendString conn s
```

Sends a string as UTF-8, every byte of it.

### `recvString`

```
recvString : Connection -> <Net> Result String String
recvString conn
```

Receives everything until the peer closes the connection, decoded as
UTF-8.

For a connection that stays open, read a line at a time with `recvLine`
or a bounded amount with `recv`.

### `sendLine`

```
sendLine : Connection -> String -> <Net> Result String Unit
sendLine conn s
```

Sends a string as UTF-8 followed by a newline.

### `recvLine`

```
recvLine : Connection -> <Net> Result String (Option String)
recvLine conn
```

Receives one line, without its newline.

`None` when the peer has closed the connection and nothing was pending.
A final line with no newline is still returned. Reads one byte per call,
so it suits small line-based messages, not bulk transfer.

## Lifecycle

### `shutdown`

```
shutdown : Connection -> Shutdown -> <Net> Result String Unit
shutdown _ how
```

Shuts down one or both directions of a connection without closing it.

### `close`

```
close : Connection -> <Net> Result String Unit
```

Closes a connection.

Closing twice is not an error. `withConnection` closes for you.

### `closeListener`

```
closeListener : Listener -> <Net> Result String Unit
```

Closes a listener.

### `setTimeout`

```
setTimeout : Connection -> Duration -> <Net> Result String Unit
setTimeout _ d
```

Sets a connection's send and receive timeout.

A zero duration means no timeout. Set one on any long-lived connection
so a stalled peer cannot block forever.

### `withConnection`

```
withConnection : String -> Int -> (Connection -> <Net> Result String a) -> <Net> Result String a
withConnection host port body
```

Connects to `host` on `port`, runs `body` on the connection, and closes
it whatever `body` returns.

The result is `body`'s result, or the connection error when connecting
fails, in which case `body` does not run.

`withConnection "127.0.0.1" 9000 (conn => sendString conn "hi")`

### `withListener`

```
withListener : String -> Int -> (Listener -> <Net> Result String a) -> <Net> Result String a
withListener addr port body
```

Listens on `addr` and `port`, runs `body` on the listener, and closes
it whatever `body` returns.

The result is `body`'s result, or the error when listening fails.

### `serveLoop`

```
serveLoop : Listener -> (Connection -> <Net> Result String Unit) -> <Net> Result String Unit
serveLoop lis handle
```

Accepts connections forever, running `handle` on each and closing it
afterwards.

A failure in `handle` closes that connection and the loop continues. A
failure in `accept` ends the loop with the error. Pair it with
`withListener` to close the listener when the loop ends.

