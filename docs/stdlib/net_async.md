# net_async

## `accept`

```
accept : Listener -> Async <Net _ | e> (Result String Connection)
```

Accepts the next connection, parking until one arrives. The listener
and the accepted socket are switched to non-blocking mode.

## `recv`

```
recv : Connection -> Int -> Async <Net _ | e> (Result String (Array Int))
```

Receives up to `n` bytes, parking until some arrive. An empty array is
end of stream.

## `recvWithin`

```
recvWithin : Duration -> Connection -> Int -> Async <Clock, Net _ | e> (Result String (Array Int))
```

`recv` that gives up after `d` with `Err "timed out"`.

## `send`

```
send : Connection -> Array Int -> Async <Net _ | e> (Result String Int)
```

Sends what the socket will take now, parking until it takes some.
The count may be short; `sendAll` loops.

## `sendAll`

```
sendAll : Connection -> Array Int -> Async <Net _ | e> (Result String Unit)
```

Sends every byte, parking as needed.

## `sendAllWithin`

```
sendAllWithin : Duration -> Connection -> Array Int -> Async <Clock, Net _ | e> (Result String Unit)
```

`sendAll` that gives up after `d` with `Err "timed out"`.

## `sendString`

```
sendString : Connection -> String -> Async <Net _ | e> (Result String Unit)
```

Sends a string as UTF-8, parking as needed.

## `close`

```
close : Connection -> Async <Net _ | e> (Result String Unit)
```

Closes a connection.

## `closeListener`

```
closeListener : Listener -> Async <Net _ | e> (Result String Unit)
```

Closes a listener. A task parked in `accept` on it wakes with an error,
which ends a `serve` loop.

## `serve`

```
serve : Listener -> (Connection -> Async <Net _ | e> (Result String Unit)) -> Async <Net _ | e> (Result String Unit)
```

Accepts connections until `accept` fails, running `handle` on each in
a task of its own and closing the connection when the handler finishes.

A failure in `handle` closes that connection and the loop continues. A
failure in `accept`, including the listener being closed, ends the loop
with the error.

