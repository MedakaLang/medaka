# async

## `Wait`

```
data Wait (e : Effect)  -- abstract: the constructors are not exported
```

What a parked task is waiting on.  A task woken by any one of its waits
simply retries, so a spurious wake is harmless.  `waitRead` and `waitWrite`
name a file descriptor, `deadlineAfter` gives a monotonic deadline, and a
task flag is set when a spawned task finishes.

A descriptor or deadline wait carries the capability its builder already
performs.  That is what keeps the driver's row down to the program's own:
the clock read, the sleep and the poll all happen through a parked wait,
never through an extern the scheduler names itself.

## `Async`

```
data Async (e : Effect) a  -- abstract: the constructors are not exported
```

A deferred computation.  `Done` holds a finished value; the other arms
hold the next step under a thunk that performs `<e>`.  `Suspend` is a plain
yield point, `Await` parks the task until any of its waits is satisfied, and
`Spawn` hands a child task to the scheduler before continuing.

Instances: `DeferredMappable`, `DeferredApplicative`, `DeferredThenable`

## `Task`

```
data Task a  -- abstract: the constructors are not exported
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
sleep : Duration -> Async <Clock | e> Unit
```

Parks the task for `d`, letting other tasks run meanwhile.

Reads the clock, so `<Clock>` joins `e`; the deadline it parks on carries
that clock on to the scheduler.

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
awaitAny : List (Wait e) -> Async e Unit
```

Parks the task until any one of `waits` is satisfied.

The building block for descriptor waits and deadlines: `net_async` parks
on `[waitRead fd]`, or on `[waitRead fd, deadline]` to give up after a
`Duration`. A woken task retries, so a spurious wake is harmless.

## `waitRead`

```
waitRead : Int -> Wait <Net _ | e>
```

A wait for `fd` to become readable, as a wait for `awaitAny`.

Polls the descriptor, so `<Net>` joins `e`.

## `waitWrite`

```
waitWrite : Int -> Wait <Net _ | e>
```

A wait for `fd` to become writable, as a wait for `awaitAny`.

Polls the descriptor, so `<Net>` joins `e`.

## `deadlineAfter`

```
deadlineAfter : Duration -> Async <Clock | e> (Wait <Clock | e>)
```

A deadline `d` from now, as a wait for `awaitAny`.

Reads the clock, so `<Clock>` joins `e`.

## `expired`

```
expired : Wait e -> Async e Bool
```

Whether a deadline from `deadlineAfter` has passed.

Any other wait is never expired. Reads the clock the wait carries.

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

Each task is spawned, so they interleave under `runAsync`; the result
arrives once all of them have finished.

## `runAsync`

```
runAsync : Async e a -> <e> a
```

Runs a task to its value under the scheduler, performing exactly its
row `e`.

Runnable tasks take turns at every yield, so `concurrent` interleaves its
children round-robin and the order is deterministic. After every round
over the run queue the scheduler gives parked tasks whose timer has
expired, whose descriptor is ready, or whose awaited task has finished
their turn, so a task that never parks cannot starve the others. When
every task is parked it sleeps until the earliest deadline or the next
descriptor event. It returns the program's value once the program and
every spawned task have finished, and panics if the remaining tasks can
never be woken.

## `runAsyncMain`

```
runAsyncMain : Async e Unit -> <e> Unit
```

`runAsync` for a program whose value is `Unit`.

A `main : Async e Unit` is driven through this, on every target.

