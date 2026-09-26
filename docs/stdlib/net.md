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
type Connection (h : Authority Net) = Socket h
```

A connected TCP socket, from `connect` or `accept`, at the authority of
the host it reaches.

### `Listener`

```
type Listener (a : Authority Net) = ListenSocket a
```

A listening TCP socket, from `listen`, at the authority of its address.

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
connect : (host : String) -> Int -> <Net host> Result String (Connection host)
connect host port
```

A connection to `host` on `port`.

The host name is resolved first. `withConnection` is the form that
closes the connection for you.

## Servers

### `listen`

```
listen : (addr : String) -> Int -> <Net addr> Result String (Listener addr)
listen addr port
```

A listener bound to `addr` on `port`.

Port `0` lets the system pick a free port; `listenPort` reports which.

### `listenPort`

```
listenPort : Listener a -> <Net a> Result String Int
listenPort lis
```

The port a listener is bound to.

### `accept`

```
accept : Listener a -> <Net a> Result String (Connection a)
accept lis
```

Waits for the next connection to a listener.

The connection is at the listener's authority: it is reached through the
address the listener was granted.

## Transfer

### `send`

```
send : Connection h -> Array Int -> <Net h> Result String Int
send conn bs
```

Sends bytes in one call. The result is the number of bytes written,
which may be fewer than given.

`sendAll` is the form that sends everything.

### `recv`

```
recv : Connection h -> Int -> <Net h> Result String (Array Int)
recv conn n
```

Receives up to `n` bytes in one call.

An empty array means the peer has closed the connection. `recvAll` is the
form that reads to the end.

### `sendAll`

```
sendAll : Connection h -> Array Int -> <Net h> Result String Unit
sendAll conn bs
```

Sends every byte, looping over `send` as needed.

`Err` on the first failed send, or when a send writes nothing, which is
treated as a stalled connection.

### `recvAll`

```
recvAll : Connection h -> <Net h> Result String (Array Int)
recvAll conn
```

Receives everything until the peer closes the connection.

`Err` on the first failed receive; whatever was read before it is
discarded.

## Text

### `sendString`

```
sendString : Connection h -> String -> <Net h> Result String Unit
sendString conn s
```

Sends a string as UTF-8, every byte of it.

### `recvString`

```
recvString : Connection h -> <Net h> Result String String
recvString conn
```

Receives everything until the peer closes the connection, decoded as
UTF-8.

For a connection that stays open, read a line at a time with `recvLine`
or a bounded amount with `recv`.

### `sendLine`

```
sendLine : Connection h -> String -> <Net h> Result String Unit
sendLine conn s
```

Sends a string as UTF-8 followed by a newline.

### `recvLine`

```
recvLine : Connection h -> <Net h> Result String (Option String)
recvLine conn
```

Receives one line, without its newline.

`None` when the peer has closed the connection and nothing was pending.
A final line with no newline is still returned. Reads one byte per call,
so it suits small line-based messages, not bulk transfer.

## Lifecycle

### `shutdown`

```
shutdown : Connection h -> Shutdown -> <Net h> Result String Unit
shutdown conn how
```

Shuts down one or both directions of a connection without closing it.

### `close`

```
close : Connection h -> <Net h> Result String Unit
close conn
```

Closes a connection.

Closing twice is not an error. `withConnection` closes for you.

### `closeListener`

```
closeListener : Listener a -> <Net a> Result String Unit
closeListener lis
```

Closes a listener.

### `setTimeout`

```
setTimeout : Connection h -> Duration -> <Net h> Result String Unit
setTimeout conn d
```

Sets a connection's send and receive timeout.

A zero duration means no timeout. Set one on any long-lived connection
so a stalled peer cannot block forever.

### `withConnection`

```
withConnection : (host : String) -> Int -> (Connection host -> <Net host | e> Result String a) -> <Net host | e> Result String a
withConnection host port body
```

Connects to `host` on `port`, runs `body` on the connection, and closes
it whatever `body` returns.

The result is `body`'s result, or the connection error when connecting
fails, in which case `body` does not run.

`withConnection "127.0.0.1" 9000 (conn => sendString conn "hi")`

### `withListener`

```
withListener : (addr : String) -> Int -> (Listener addr -> <Net addr | e> Result String a) -> <Net addr | e> Result String a
withListener addr port body
```

Listens on `addr` and `port`, runs `body` on the listener, and closes
it whatever `body` returns.

The result is `body`'s result, or the error when listening fails.

### `serveLoop`

```
serveLoop : Listener a -> (Connection a -> <Net a | e> Result String Unit) -> <Net a | e> Result String Unit
serveLoop lis handle
```

Accepts connections forever, running `handle` on each and closing it
afterwards.

A failure in `handle` closes that connection and the loop continues. A
failure in `accept` ends the loop with the error. Pair it with
`withListener` to close the listener when the loop ends.

