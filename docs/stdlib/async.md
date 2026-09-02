# async

## `Async`

```
data Async (e : Effect) a
  = Done a
  | Suspend (Unit -> <e> Async e a)
  | Await (List Wait) (Unit -> <e> Async e a)
  | Spawn (Async e Unit) (Unit -> <e> Async e a)
```

A deferred computation.  `Done` holds a finished value; the other arms
hold the next step under a thunk that performs `<e>`.  `Suspend` is a plain
yield point, `Await` parks the task until any of its waits is satisfied, and
`Spawn` hands a child task to the scheduler before continuing.

Instances: `DeferredMappable`, `DeferredApplicative`, `DeferredThenable`

## `Wait`

```
data Wait
  = WaitRead Int
  | WaitWrite Int
  | WaitUntil Float
  | WaitFlag (Ref Bool)
```

What a parked task is waiting on.  A task woken by any one of its waits
simply retries, so a spurious wake is harmless.  `WaitRead` and `WaitWrite`
name a file descriptor; `WaitUntil` is a monotonic deadline in seconds;
`WaitFlag` is set when a spawned task finishes.

## `Task`

```
data Task a
  = Task (Ref Bool) (Ref (Option a))
```

A handle to a task started with `spawnTask`.  `await` reads its value.

## `liftIO`

```
liftIO : (Unit -> <e> a) -> Async e a
```

Lifts a thunk into `Async`, deferring it behind one yield boundary.

`liftIO (u => putStrLn "hi") : Async <Stdout> Unit`; a pure thunk yields
`Async <> a`.

## `yield`

```
yield : Async e Unit
```

A yield point: hands control back to the scheduler, then resumes.

Inert for a single task; observable once other tasks are runnable.

## `sleep`

```
sleep : Duration -> Async e Unit
```

Parks the task for `d`, letting other tasks run meanwhile.

Reads the clock, so `<Clock>` joins `e`. Needs `runAsyncIO`.

## `spawn`

```
spawn : Async e Unit -> Async e Unit
```

Starts `child` as a task of its own and continues at once.

The driver returns only after every spawned task has finished.

## `spawnTask`

```
spawnTask : Async e a -> Async e (Task a)
```

Starts `act` as a task of its own and returns a handle to its value.

`await` the handle to read the value once the task finishes.

## `awaitAny`

```
awaitAny : List Wait -> Async e Unit
```

Parks the task until any one of `waits` is satisfied.

The building block for descriptor waits and deadlines: `net_async` parks
on `[WaitRead fd]`, or on `[WaitRead fd, deadline]` to give up after a
`Duration`. A woken task retries, so a spurious wake is harmless. Needs
`runAsyncIO`.

## `deadlineAfter`

```
deadlineAfter : Duration -> Async e Wait
```

A deadline `d` from now, as a wait for `awaitAny`.

Reads the clock, so `<Clock>` joins `e`.

## `expired`

```
expired : Wait -> Async e Bool
```

Whether a deadline from `deadlineAfter` has passed.

Any other wait is never expired. Reads the clock.

## `await`

```
await : Task a -> Async e a
```

Waits for a spawned task and yields its value.

Parks until the task finishes; awaiting a finished task yields at once.

## `concurrent`

```
concurrent : List (Async e a) -> Async e (List a)
```

Runs every task in the list and collects their values in input order.

Each task is spawned, so they interleave under `runAsyncIO`; the result
arrives once all of them have finished.

## `runAsync`

```
runAsync : Async e a -> <e> a
```

Runs a task to its value sequentially, performing exactly its row `e`.

Spawned tasks take turns at every yield, so `concurrent` interleaves its
children round-robin and the order is deterministic. A task that waits on
a timer or a descriptor panics: use `runAsyncIO` for those.

## `runAsyncIO`

```
runAsyncIO : Async e a -> <Clock, Net _ | e> a
```

Runs a task under the scheduler, performing its row `e` plus the
scheduler's own `<Clock>` and `<Net "_">`.

Runnable tasks take turns at every yield. After every round over the run
queue the scheduler gives parked tasks whose timer has expired, whose
descriptor is ready, or whose awaited task has finished their turn, so a
task that never parks cannot starve the others. When every task is parked
it sleeps until the earliest deadline or the next descriptor event. It
returns the program's value once the program and every spawned task have
finished, and panics if the remaining tasks can never be woken.

## `runAsyncIOMain`

```
runAsyncIOMain : Async e Unit -> <Clock, Net _ | e> Unit
```

`runAsyncIO` for a program whose value is `Unit`.

A `main : Async e Unit` is driven through this on the native target and
under `medaka run`.

## `runAsyncMain`

```
runAsyncMain : Async e Unit -> <e> Unit
```

`runAsync` for a program whose value is `Unit`.

A `main : Async e Unit` is driven through this on the WebAssembly target,
which has no clock.

## Instances

