# net

TCP connections and name resolution.

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
resolve : String -> <Net _> Result String (List String)
```

The numeric addresses a host name resolves to.

`resolve "localhost"` gives `Ok ["127.0.0.1"]` or similar.

### `connect`

```
connect : String -> Int -> <Net _> Result String Connection
```

A connection to `host` on `port`.

The host name is resolved first. `withConnection` is the form that
closes the connection for you.

## Servers

### `listen`

```
listen : String -> Int -> <Net _> Result String Listener
```

A listener bound to `addr` on `port`.

Port `0` lets the system pick a free port; `listenPort` reports which.

### `listenPort`

```
listenPort : Listener -> <Net _> Result String Int
```

The port a listener is bound to.

### `accept`

```
accept : Listener -> <Net _> Result String Connection
```

Waits for the next connection to a listener.

## Transfer

### `send`

```
send : Connection -> Array Int -> <Net _> Result String Int
```

Sends bytes in one call. The result is the number of bytes written,
which may be fewer than given.

`sendAll` is the form that sends everything.

### `recv`

```
recv : Connection -> Int -> <Net _> Result String (Array Int)
```

Receives up to `n` bytes in one call.

An empty array means the peer has closed the connection. `recvAll` is the
form that reads to the end.

### `sendAll`

```
sendAll : Connection -> Array Int -> <Net _> Result String Unit
```

Sends every byte, looping over `send` as needed.

`Err` on the first failed send, or when a send writes nothing, which is
treated as a stalled connection.

### `recvAll`

```
recvAll : Connection -> <Net _> Result String (Array Int)
```

Receives everything until the peer closes the connection.

`Err` on the first failed receive; whatever was read before it is
discarded.

## Text

### `sendString`

```
sendString : Connection -> String -> <Net _> Result String Unit
```

Sends a string as UTF-8, every byte of it.

### `recvString`

```
recvString : Connection -> <Net _> Result String String
```

Receives everything until the peer closes the connection, decoded as
UTF-8.

For a connection that stays open, read a line at a time with `recvLine`
or a bounded amount with `recv`.

### `sendLine`

```
sendLine : Connection -> String -> <Net _> Result String Unit
```

Sends a string as UTF-8 followed by a newline.

### `recvLine`

```
recvLine : Connection -> <Net _> Result String (Option String)
```

Receives one line, without its newline.

`None` when the peer has closed the connection and nothing was pending.
A final line with no newline is still returned. Reads one byte per call,
so it suits small line-based messages, not bulk transfer.

## Lifecycle

### `shutdown`

```
shutdown : Connection -> Shutdown -> <Net _> Result String Unit
```

Shuts down one or both directions of a connection without closing it.

### `close`

```
close : Connection -> <Net _> Result String Unit
```

Closes a connection.

Closing twice is not an error. `withConnection` closes for you.

### `closeListener`

```
closeListener : Listener -> <Net _> Result String Unit
```

Closes a listener.

### `setTimeout`

```
setTimeout : Connection -> Duration -> <Net _> Result String Unit
```

Sets a connection's send and receive timeout.

A zero duration means no timeout. Set one on any long-lived connection
so a stalled peer cannot block forever.

### `withConnection`

```
withConnection : String -> Int -> (Connection -> <Net _> Result String a) -> <Net _> Result String a
```

Connects to `host` on `port`, runs `body` on the connection, and closes
it whatever `body` returns.

The result is `body`'s result, or the connection error when connecting
fails, in which case `body` does not run.

`withConnection "127.0.0.1" 9000 (conn => sendString conn "hi")`

### `withListener`

```
withListener : String -> Int -> (Listener -> <Net _> Result String a) -> <Net _> Result String a
```

Listens on `addr` and `port`, runs `body` on the listener, and closes
it whatever `body` returns.

The result is `body`'s result, or the error when listening fails.

### `serveLoop`

```
serveLoop : Listener -> (Connection -> <Net _> Result String Unit) -> <Net _> Result String Unit
```

Accepts connections forever, running `handle` on each and closing it
afterwards.

A failure in `handle` closes that connection and the loop continues. A
failure in `accept` ends the loop with the error. Pair it with
`withListener` to close the listener when the loop ends.

