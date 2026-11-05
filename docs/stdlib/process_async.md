# process_async

## `Deadline`

```
data Deadline (e : Effect)  -- abstract: the constructors are not exported
```

An absolute monotonic deadline, created by `after`.

## `CancelToken`

```
data CancelToken  -- abstract: the constructors are not exported
```

A cooperative cancellation token shared by operations.

## `ReadResult`

```
data ReadResult
  = Read Bytes
  | EndOfStream
  | ReadTimedOut
  | ReadCancelled
```

Read bytes, end of stream, or the reason the operation stopped.

## `WriteResult`

```
data WriteResult
  = Written Int
  | WriteTimedOut Int
  | WriteCancelled Int
```

The committed byte count on completion, timeout, or cancellation.

## `WaitResult`

```
data WaitResult
  = ChildExited ExitStatus
  | WaitTimedOut
  | WaitCancelled
```

Direct-child exit status or the reason observation stopped.

## `newCancelToken`

```
newCancelToken : Unit -> CancelToken
```

Creates an uncancelled token.

## `cancel`

```
cancel : CancelToken -> Unit
```

Cancels the token and wakes tasks waiting on it.

## `cancelled`

```
cancelled : CancelToken -> Bool
```

Reports whether the token has been cancelled.

## `cancelWait`

```
cancelWait : CancelToken -> Wait e
```

A wait satisfied when the token is cancelled.

## `after`

```
after : Duration -> Async <Clock | e> (Deadline <Clock | e>)
after duration
```

Creates a deadline relative to when this deferred computation runs.

## `deadlineWait`

```
deadlineWait : Deadline e -> Wait e
```

The wait for this deadline; it does not reset on reuse.

## `readUntil`

```
readUntil : Process p -> OutputStream -> Int -> Deadline <Clock, Exec p | e> -> CancelToken -> Async <Clock, Exec p | e> (Result ProcessError ReadResult)
readUntil p stream limit deadline token
```

Reads a bounded chunk, stopping on cancellation or deadline.

## `writeUntil`

```
writeUntil : Process p -> Bytes -> Deadline <Clock, Exec p | e> -> CancelToken -> Async <Clock, Exec p | e> (Result (ProcessError, Int) WriteResult)
writeUntil p bytes deadline token
```

Writes bytes until completion or stop; errors retain the committed count.

## `waitUntil`

```
waitUntil : Process p -> Deadline <Clock, Exec p | e> -> CancelToken -> Async <Clock, Exec p | e> (Result ProcessError WaitResult)
waitUntil p deadline token
```

Observes direct-child exit until cancellation or deadline.

## `LaunchStop`

```
data LaunchStop ticket
  = LaunchStopped
  | LaunchCleanupPending ticket (Option ProcessError)
  | LaunchCleanupFailed ProcessError
```

Cleanup outcome; a pending ticket must be retained and drained.

## `StartResult`

```
data StartResult process ticket
  = Started process
  | StartTimedOut (LaunchStop ticket)
  | StartCancelled (LaunchStop ticket)
```

Launch transfer or a stop with its cleanup outcome.

## `startUntil`

```
startUntil : (program : String) -> SpawnOptions -> Deadline <Clock, Exec program | e> -> CancelToken -> Async <Clock, Exec program | e> (Result (StartError (LaunchTicket program)) (StartResult (Process program) (LaunchTicket program)))
startUntil program opts deadline token
```

Submits launch cooperatively and retains cleanup ownership on stop.

