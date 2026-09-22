# META
source_lines=526
stages=DESUGAR,MARK
# SOURCE
-- async.mdk — Medaka's cooperative-concurrency layer: the `Async` type, its
-- deferred instances, and the scheduler that drives them.
--
-- ASYNC-DESIGN.md (archive/design) locked the type and the contract:
-- `Async e a` is a value-level description of deferred work; tasks interleave
-- only at yield boundaries, on one OS thread, with no observable parallelism.
-- Errors ride `Result` inside `Async`; there is no rejected-promise channel and
-- `panic` still aborts the process.  docs/design/ASYNC-RUNTIME-DESIGN.md adds
-- the runtime behind that contract: a single-threaded scheduler with a run
-- queue and a park table, driven by `runAsync`.
--
-- EFFECT POLYMORPHISM.  `Async` is parametric in an effect ROW `e` as well as
-- its value `a`: every stored continuation performs `<e>`, so the type carries
-- exactly the capabilities the deferred work needs, and the one driver performs
-- exactly that row — `runAsync : Async e a -> <e> a`.  The scheduler calls no
-- clock and no poll extern of its own: a `Wait` carries the capability the code
-- that built it already performs, and the scheduler calls that.  A program that
-- never sleeps and never waits on a descriptor therefore drives at its own row,
-- down to `<>`.
--
-- Every scheduler queue is ordinary GC-visible Medaka data held in `Ref`s local
-- to one `runAsync` call; the runtime owns no descriptors and no C-side state.

import array.{fromList}
import list.{partition, reverse}
import time.{Duration, millis, toMillis}

{- | Cooperative concurrency: build a description of deferred work with
   `defer` blocks, then run it with `runAsync`.

   `Async e a` is a value: nothing in it runs until the driver forces it. The
   row `e` records the effects the stored work performs. `sleep` parks a
   task until a deadline, `spawn` and `spawnTask` hand a child task to the
   scheduler, `await` waits for a spawned task's value, and `concurrent`
   runs a list of tasks and collects their results in input order.

   `runAsync` is the scheduler: it interleaves tasks round-robin at every
   yield, sleeps until the earliest deadline when every task is parked, and
   returns once the program and every task it spawned have finished. It
   performs the program's own row `e` and nothing wider, because a timer or
   descriptor wait carries the capability whoever built it already performs.
   A `main : Async e Unit` is driven through `runAsyncMain`, on every
   target. -}

-- Reading "now" and sleeping for a number of milliseconds, both performed in
-- the row of the code that built the deadline.
data Timer (e : Effect) = Timer (Unit -> <e> Float) (Int -> <e> Unit)

-- Waiting for readiness over a set of descriptors, performed in the row of the
-- code that built the descriptor wait.
data Poller (e : Effect) =
  | Poller (Array Int -> Array Int -> Int -> <e> Result String (Array Int))

-- | What a parked task is waiting on.  A task woken by any one of its waits
-- simply retries, so a spurious wake is harmless.  `waitRead` and `waitWrite`
-- name a file descriptor, `deadlineAfter` gives a monotonic deadline, and a
-- task flag is set when a spawned task finishes.
--
-- A descriptor or deadline wait carries the capability its builder already
-- performs.  That is what keeps the driver's row down to the program's own:
-- the clock read, the sleep and the poll all happen through a parked wait,
-- never through an extern the scheduler names itself.
export data Wait (e : Effect) =
  | WaitRead Int (Poller e)
  | WaitWrite Int (Poller e)
  | WaitUntil Float (Timer e)
  | WaitFlag (Ref Bool)

-- | A deferred computation.  `Done` holds a finished value; the other arms
-- hold the next step under a thunk that performs `<e>`.  `Suspend` is a plain
-- yield point, `Await` parks the task until any of its waits is satisfied, and
-- `Spawn` hands a child task to the scheduler before continuing.
export data Async (e : Effect) a =
  | Done a
  | Suspend (Unit -> <e> Async e a)
  | Await (List (Wait e)) (Unit -> <e> Async e a)
  | Spawn (Async e Unit) (Unit -> <e> Async e a)

-- | A handle to a task started with `spawnTask`.  `await` reads its value.
export data Task a = Task (Ref Bool) (Ref (Option a))

-- The interface instances are the DEFERRED family (core.mdk `Deferred*`):
-- the instance head is the bare constructor `Async : Effect -> Type -> Type`,
-- and the effect of a callback rides the INDEX, not the method's arrow.  Every
-- arm STORES its callback under a thunk — an eager `Done (f a)` would perform
-- the callback's row at construction, from a call typed pure, and is rejected
-- (`T-EFFECT-INDEX-EAGER`).  Cost accepted with that ruling: a map/bind on an
-- already-`Done` value allocates one `Suspend` and pays one extra step.
export impl DeferredMappable Async where
  deferMap f (Done a) = Suspend (u => Done (f a))
  deferMap f (Suspend t) = Suspend (u => deferMap f (t u))
  deferMap f (Await ws t) = Await ws (u => deferMap f (t u))
  deferMap f (Spawn c t) = Spawn c (u => deferMap f (t u))

export impl DeferredApplicative Async where
  deferPure a = Done a
  deferAp mf ma = deferThen mf (f => deferMap f ma)

export impl DeferredThenable Async where
  deferThen (Done a) k = Suspend (u => k a)
  deferThen (Suspend t) k = Suspend (u => deferThen (t u) k)
  deferThen (Await ws t) k = Await ws (u => deferThen (t u) k)
  deferThen (Spawn c t) k = Spawn c (u => deferThen (t u) k)

{- | Lifts a thunk into `Async`, deferring it behind one yield boundary.

   `liftIO (u => putStrLn "hi") : Async <Stdout> Unit`; a pure thunk yields
   `Async <> a`. -}
export
liftIO : (Unit -> <e> a) -> Async e a
liftIO act = Suspend (u => Done (act u))

{- | A yield point: hands control back to the scheduler, then resumes.

   Inert for a single task; observable once other tasks are runnable. -}
export
yield : Async e Unit
yield = Suspend (_ => Done ())

{- | Parks the task for `d`, letting other tasks run meanwhile.

   Reads the clock, so `<Clock>` joins `e`; the deadline it parks on carries
   that clock on to the scheduler. -}
export
sleep : Duration -> Async <Clock | e> Unit
sleep d = Suspend (u => sleepFrom (monotonicSec ()) d)

sleepFrom : Float -> Duration -> Async <Clock | e> Unit
sleepFrom now d =
  let deadline = now + intToFloat (toMillis d) / 1000.0
  Await [systemDeadline deadline] (u => Done ())

{- | Starts `child` as a task of its own and continues at once.

   The driver returns only after every spawned task has finished. -}
export
spawn : Async e Unit -> Async e Unit
spawn child = Spawn child (u => Done ())

{- | Starts `act` as a task of its own and returns a handle to its value.

   `await` the handle to read the value once the task finishes. -}
export
spawnTask : Async e a -> Async e (Task a)
spawnTask act = Suspend (u => spawnWith (Ref False) (Ref None) act)

spawnWith : Ref Bool -> Ref (Option a) -> Async e a -> Async e (Task a)
spawnWith done cell act = Spawn (deferThen act (a => Suspend (u =>
  finish done cell a))) (u =>
  Done (Task done cell))

finish : Ref Bool -> Ref (Option a) -> a -> Async e Unit
finish done cell a =
  cell := Some a
  done := True
  Done ()

{- | Parks the task until any one of `waits` is satisfied.

   The building block for descriptor waits and deadlines: `net_async` parks
   on `[waitRead fd]`, or on `[waitRead fd, deadline]` to give up after a
   `Duration`. A woken task retries, so a spurious wake is harmless. -}
export
awaitAny : List (Wait e) -> Async e Unit
awaitAny waits = Await waits (u => Done ())

{- | A wait for `fd` to become readable, as a wait for `awaitAny`.

   Polls the descriptor, so `<Net>` joins `e`. -}
export
waitRead : Int -> Wait <Net "_" | e>
waitRead fd = WaitRead fd systemPoller

{- | A wait for `fd` to become writable, as a wait for `awaitAny`.

   Polls the descriptor, so `<Net>` joins `e`. -}
export
waitWrite : Int -> Wait <Net "_" | e>
waitWrite fd = WaitWrite fd systemPoller

systemPoller : Poller <Net "_" | e>
systemPoller = Poller (fds interests timeout => ioPoll fds interests timeout)

{- | A deadline `d` from now, as a wait for `awaitAny`.

   Reads the clock, so `<Clock>` joins `e`. -}
export
deadlineAfter : Duration -> Async <Clock | e> (Wait <Clock | e>)
deadlineAfter d = Suspend (u =>
  Done (systemDeadline (monotonicSec () + intToFloat (toMillis d) / 1000.0)))

systemDeadline : Float -> Wait <Clock | e>
systemDeadline t = WaitUntil t (Timer (u => monotonicSec ()) (ms => sleepMs ms))

{- | Whether a deadline from `deadlineAfter` has passed.

   Any other wait is never expired. Reads the clock the wait carries. -}
export
expired : Wait e -> Async e Bool
expired w = Suspend (u => Done (expiredNow w))

expiredNow : Wait e -> <e> Bool
expiredNow (WaitUntil t (Timer now _)) = t <= now ()
expiredNow _ = False

{- | Waits for a spawned task and yields its value.

   Parks until the task finishes; awaiting a finished task yields at once. -}
export
await : Task a -> Async e a
await t = Await [WaitFlag (taskDone t)] (u => awaitResume t)

taskDone : Task a -> Ref Bool
taskDone (Task done _) = done

awaitResume : Task a -> Async e a
awaitResume (Task done cell) = match !cell
  Some a => Done a
  None => await (Task done cell)

{- | Runs every task in the list and collects their values in input order.

   Each task is spawned, so they interleave under `runAsync`; the result
   arrives once all of them have finished. -}
export
concurrent : List (Async e a) -> Async e (List a)
concurrent asyncs = deferThen (spawnAll [] asyncs) (ts => awaitAll [] ts)

-- Both loops carry an accumulator and recurse in tail position, so a list of
-- N tasks costs N steps — a `deferMap` around each recursive call would nest N
-- deep and cost N steps per step.
spawnAll : List (Task a) -> List (Async e a) -> Async e (List (Task a))
spawnAll acc [] = Done (reverse acc)
spawnAll acc (a :: rest) =
  deferThen (spawnTask a) (t => spawnAll (t :: acc) rest)

awaitAll : List a -> List (Task a) -> Async e (List a)
awaitAll acc [] = Done (reverse acc)
awaitAll acc (t :: rest) = deferThen (await t) (a => awaitAll (a :: acc) rest)

{- | Runs a task to its value under the scheduler, performing exactly its
   row `e`.

   Runnable tasks take turns at every yield, so `concurrent` interleaves its
   children round-robin and the order is deterministic. After every round
   over the run queue the scheduler gives parked tasks whose timer has
   expired, whose descriptor is ready, or whose awaited task has finished
   their turn, so a task that never parks cannot starve the others. When
   every task is parked it sleeps until the earliest deadline or the next
   descriptor event. It returns the program's value once the program and
   every spawned task have finished, and panics if the remaining tasks can
   never be woken. -}
export
runAsync : Async e a -> <e> a
runAsync prog =
  let cell = Ref None
  let front = Ref [deferThen prog (a => Suspend (u => storeResult cell a))]
  let back = Ref []
  let parked = Ref []
  let _ = schedule front back parked 1
  match !cell
    Some a => a
    None => panic "async: the program finished without producing a value"

{- | `runAsync` for a program whose value is `Unit`.

   A `main : Async e Unit` is driven through this, on every target. -}
export
runAsyncMain : Async e Unit -> <e> Unit
runAsyncMain prog = runAsync prog

storeResult : Ref (Option a) -> a -> Async e Unit
storeResult cell a =
  cell := Some a
  Done ()

-- The run queue is two lists: tasks are popped from `front` and pushed onto
-- `back` (newest first); when `front` runs dry, `back` is reversed into it.
popTask : Ref (List (Async e Unit)) ->
  Ref (List (Async e Unit)) ->
  Option (Async e Unit)
popTask front back = match !front
  t :: rest =>
    front := rest
    Some t
  [] => match reverse !back
    [] => None
    t :: rest =>
      front := rest
      back := []
      Some t

pushBack : Ref (List (Async e Unit)) -> Async e Unit -> Unit
pushBack back t = back := t :: !back

queueLength : Ref (List (Async e Unit)) -> Ref (List (Async e Unit)) -> Int
queueLength front back = length !front + length !back

-- One scheduler step, with `budget` tasks left in the current round.  A round
-- is one pass over the queue as it stood when the round began; at the end of
-- each round every parked task gets a non-blocking chance to wake, which is
-- what keeps a task that never parks from starving the rest.
schedule : Ref (List (Async e Unit)) ->
  Ref (List (Async e Unit)) ->
  Ref (List (List (Wait e), Unit -> <e> Async e Unit)) ->
  Int ->
  <e> Unit
schedule front back parked budget =
  if budget <= 0 then
    let _ = wakeParked back parked False
    schedule front back parked (max 1 (queueLength front back))
  else match popTask front back
    Some t =>
      let _ = dispatch back parked (stepTask t)
      schedule front back parked (budget - 1)
    None => match !parked
      [] => ()
      _ =>
        let _ = wakeParked back parked True
        schedule front back parked (max 1 (queueLength front back))

stepTask : Async e Unit -> <e> Async e Unit
stepTask (Suspend k) = k ()
stepTask other = other

dispatch : Ref (List (Async e Unit)) ->
  Ref (List (List (Wait e), Unit -> <e> Async e Unit)) ->
  Async e Unit ->
  Unit
dispatch _ _ (Done _) = ()
dispatch back _ (Suspend k) = pushBack back (Suspend k)
dispatch _ parked (Await ws k) = parked := (ws, k) :: !parked
dispatch back _ (Spawn child k) =
  let _ = pushBack back child
  pushBack back (Suspend k)

-- Move every parked task whose wait is satisfied back to the queue, oldest
-- first.  When `block` is set nothing is runnable: sleep through the earliest
-- deadline or wait in the poller, and report a deadlock if neither can wake
-- anything.  When it is clear, only a zero-timeout poll is made.
--
-- "Now" is read, and the poller called, only through a wait that is parked
-- right now: a park table holding nothing but task flags — or nothing at all —
-- costs no clock read and no poll, which is why driving a program that never
-- sleeps performs nothing the program does not perform itself.
wakeParked : Ref (List (Async e Unit)) ->
  Ref (List (List (Wait e), Unit -> <e> Async e Unit)) ->
  Bool ->
  <e> Unit
wakeParked back parked block =
  let soonest = earliestDeadline !parked
  let now = readNow soonest
  let (ready, waiting) = partition (p => isReady now p) !parked
  match ready
    _ :: _ =>
      parked := waiting
      requeue back ready
    [] => match fdWaitsOf waiting
      None => if not block then () else sleepThrough now soonest
      Some (Poller poll, fdWaits) =>
        match (poll
          (fromList (map pollFd fdWaits))
          (fromList (map pollInterest fdWaits))
          (pollTimeout block now soonest))
          Err e => panic ("async: poll failed: " ++ e)
          Ok readiness =>
            let satisfied = satisfiedWaits fdWaits (toList readiness)
            let (woke, still) =
              partition
                (p => any (w => waitSatisfied satisfied w) (fst p))
                waiting
            parked := still
            requeue back woke

-- The clock a parked deadline carries is the scheduler's only source of "now".
readNow : Option (Float, Timer e) -> <e> Option Float
readNow None = None
readNow (Some (_, Timer now _)) = Some (now ())

-- Nothing is runnable and no descriptor is being watched: sleep through the
-- nearest deadline, or report the deadlock when there is no deadline either.
sleepThrough : Option Float -> Option (Float, Timer e) -> <e> Unit
sleepThrough (Some now) (Some (t, Timer _ sleepFor)) =
  sleepFor (millisUntil now t)
sleepThrough _ _ =
  panic
    "async: every remaining task is waiting on a task that can never finish (deadlock)"

-- A zero timeout while something is still runnable; otherwise wait for the
-- nearest deadline, or indefinitely when nothing parked is waiting on time.
pollTimeout : Bool -> Option Float -> Option (Float, Timer e) -> Int
pollTimeout False _ _ = 0
pollTimeout True (Some now) (Some (t, _)) = millisUntil now t
pollTimeout True _ _ = -1

millisUntil : Float -> Float -> Int
millisUntil now t = max 0 (floatToInt ((t - now) * 1000.0) + 1)

-- `parked` holds newest first; requeue oldest first so waking is FIFO.
requeue : Ref (List (Async e Unit)) ->
  List (List (Wait e), Unit -> <e> Async e Unit) ->
  Unit
requeue back ready = requeueOldestFirst back (reverse ready)

requeueOldestFirst : Ref (List (Async e Unit)) ->
  List (List (Wait e), Unit -> <e> Async e Unit) ->
  Unit
requeueOldestFirst _ [] = ()
requeueOldestFirst back ((_, k) :: rest) =
  let _ = pushBack back (Suspend k)
  requeueOldestFirst back rest

isReady : Option Float -> (List (Wait e), Unit -> <e> Async e Unit) -> Bool
isReady now (ws, _) = any (w => waitReady now w) ws

waitReady : Option Float -> Wait e -> Bool
waitReady (Some now) (WaitUntil t _) = t <= now
waitReady _ (WaitFlag r) = !r
waitReady _ _ = False

isFdWait : Wait e -> Bool
isFdWait (WaitRead _ _) = True
isFdWait (WaitWrite _ _) = True
isFdWait _ = False

-- The nearest deadline across the park table, with the clock that very wait
-- carries — so the reader of "now" is a capability the program already has.
earliestDeadline : List (List (Wait e), Unit -> <e> Async e Unit) ->
  Option (Float, Timer e)
earliestDeadline [] = None
earliestDeadline ((ws, _) :: rest) =
  minDeadline (deadlinesOf ws) (earliestDeadline rest)

deadlinesOf : List (Wait e) -> Option (Float, Timer e)
deadlinesOf [] = None
deadlinesOf ((WaitUntil t c) :: rest) =
  minDeadline (Some (t, c)) (deadlinesOf rest)
deadlinesOf (_ :: rest) = deadlinesOf rest

minDeadline : Option (Float, Timer e) ->
  Option (Float, Timer e) ->
  Option (Float, Timer e)
minDeadline None b = b
minDeadline a None = a
minDeadline (Some (x, cx)) (Some (y, cy)) =
  if x <= y then Some (x, cx) else Some (y, cy)

-- Every descriptor wait across the park table, one poll entry each, with the
-- poller they carry; `None` when nothing is waiting on a descriptor at all.
fdWaitsOf : List (List (Wait e), Unit -> <e> Async e Unit) ->
  Option (Poller e, List (Wait e))
fdWaitsOf ps =
  let ws = fdWaitsIn ps
  map (p => (p, ws)) (pollerOf ws)

fdWaitsIn : List (List (Wait e), Unit -> <e> Async e Unit) -> List (Wait e)
fdWaitsIn [] = []
fdWaitsIn ((ws, _) :: rest) = filter isFdWait ws ++ fdWaitsIn rest

pollerOf : List (Wait e) -> Option (Poller e)
pollerOf [] = None
pollerOf ((WaitRead _ p) :: _) = Some p
pollerOf ((WaitWrite _ p) :: _) = Some p
pollerOf (_ :: rest) = pollerOf rest

pollFd : Wait e -> Int
pollFd (WaitRead fd _) = fd
pollFd (WaitWrite fd _) = fd
pollFd _ = -1

pollInterest : Wait e -> Int
pollInterest (WaitRead _ _) = 1
pollInterest (WaitWrite _ _) = 2
pollInterest _ = 0

-- The waits whose parallel readiness word is non-zero.
satisfiedWaits : List (Wait e) -> List Int -> List (Wait e)
satisfiedWaits (w :: ws) (r :: rs) =
  if r == 0 then satisfiedWaits ws rs else w :: satisfiedWaits ws rs
satisfiedWaits _ _ = []

waitSatisfied : List (Wait e) -> Wait e -> Bool
waitSatisfied sat (WaitRead fd _) = any (w => isReadOf fd w) sat
waitSatisfied sat (WaitWrite fd _) = any (w => isWriteOf fd w) sat
waitSatisfied _ _ = False

isReadOf : Int -> Wait e -> Bool
isReadOf fd (WaitRead x _) = x == fd
isReadOf _ _ = False

isWriteOf : Int -> Wait e -> Bool
isWriteOf fd (WaitWrite x _) = x == fd
isWriteOf _ _ = False

{- Doctests.

   > runAsync (Done 5)
   5

   > runAsync (deferMap (x => x + 1) (Done 4))
   5

   > runAsync (deferAp (Done (x => x * 2)) (Done 21))
   42

   > runAsync (deferThen (Done 10) (x => Done (x + 5)))
   15

   > runAsync (deferThen yield (_ => Done 99))
   99

   > runAsync (liftIO (u => 21 + 21))
   42

   > runAsync (concurrent [Done 1, Done 2, Done 3])
   [1, 2, 3]

   > runAsync (deferThen (spawnTask (Done 7)) await)
   7

   > runAsync (deferThen (spawnTask (deferThen (sleep (millis 5)) (_ => Done 8))) await)
   8

   > runAsync (deferMap length (concurrent [sleep (millis 5), sleep (millis 5), sleep (millis 5)]))
   3
-}
# DESUGAR
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "partition" false) (mem "reverse" false))))
(DUse false (UseGroup ("time") ((mem "Duration" false) (mem "millis" false) (mem "toMillis" false))))
(DData Private "Timer" ("e") ((variant "Timer" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyCon "Float"))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))) ())
(DData Private "Poller" ("e") ((variant "Poller" (ConPos (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))))) ())
(DData Abstract "Wait" ("e") ((variant "WaitRead" (ConPos (TyCon "Int") (TyApp (TyCon "Poller") (TyVar "e")))) (variant "WaitWrite" (ConPos (TyCon "Int") (TyApp (TyCon "Poller") (TyVar "e")))) (variant "WaitUntil" (ConPos (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))) (variant "WaitFlag" (ConPos (TyApp (TyCon "Ref") (TyCon "Bool"))))) ())
(DData Abstract "Async" ("e" "a") ((variant "Done" (ConPos (TyVar "a"))) (variant "Suspend" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))) (variant "Await" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))) (variant "Spawn" (ConPos (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))))) ())
(DData Abstract "Task" ("a") ((variant "Task" (ConPos (TyApp (TyCon "Ref") (TyCon "Bool")) (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a")))))) ())
(DImpl true "DeferredMappable" ((TyCon "Async")) () ((im "deferMap" ((PVar "f") (PCon "Done" (PVar "a"))) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "f") (EVar "a")))))) (im "deferMap" ((PVar "f") (PCon "Suspend" (PVar "t"))) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u")))))) (im "deferMap" ((PVar "f") (PCon "Await" (PVar "ws") (PVar "t"))) (EApp (EApp (EVar "Await") (EVar "ws")) (ELam ((PVar "u")) (EApp (EApp (EVar "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u")))))) (im "deferMap" ((PVar "f") (PCon "Spawn" (PVar "c") (PVar "t"))) (EApp (EApp (EVar "Spawn") (EVar "c")) (ELam ((PVar "u")) (EApp (EApp (EVar "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u"))))))))
(DImpl true "DeferredApplicative" ((TyCon "Async")) () ((im "deferPure" ((PVar "a")) (EApp (EVar "Done") (EVar "a"))) (im "deferAp" ((PVar "mf") (PVar "ma")) (EApp (EApp (EVar "deferThen") (EVar "mf")) (ELam ((PVar "f")) (EApp (EApp (EVar "deferMap") (EVar "f")) (EVar "ma")))))))
(DImpl true "DeferredThenable" ((TyCon "Async")) () ((im "deferThen" ((PCon "Done" (PVar "a")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "k") (EVar "a"))))) (im "deferThen" ((PCon "Suspend" (PVar "t")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k"))))) (im "deferThen" ((PCon "Await" (PVar "ws") (PVar "t")) (PVar "k")) (EApp (EApp (EVar "Await") (EVar "ws")) (ELam ((PVar "u")) (EApp (EApp (EVar "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k"))))) (im "deferThen" ((PCon "Spawn" (PVar "c") (PVar "t")) (PVar "k")) (EApp (EApp (EVar "Spawn") (EVar "c")) (ELam ((PVar "u")) (EApp (EApp (EVar "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k")))))))
(DTypeSig true "liftIO" (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "liftIO" ((PVar "act")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "act") (EVar "u"))))))
(DTypeSig true "yield" (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))
(DFunDef false "yield" () (EApp (EVar "Suspend") (ELam (PWild) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "sleep" (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock") (Some "e"))) (TyCon "Unit"))))
(DFunDef false "sleep" ((PVar "d")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "sleepFrom") (EApp (EVar "monotonicSec") (ELit LUnit))) (EVar "d")))))
(DTypeSig false "sleepFrom" (TyFun (TyCon "Float") (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock") (Some "e"))) (TyCon "Unit")))))
(DFunDef false "sleepFrom" ((PVar "now") (PVar "d")) (EBlock (DoLet false false (PVar "deadline") (EBinOp "+" (EVar "now") (EBinOp "/" (EApp (EVar "intToFloat") (EApp (EVar "toMillis") (EVar "d"))) (ELit (LFloat 1000.0))))) (DoExpr (EApp (EApp (EVar "Await") (EListLit (EApp (EVar "systemDeadline") (EVar "deadline")))) (ELam ((PVar "u")) (EApp (EVar "Done") (ELit LUnit)))))))
(DTypeSig true "spawn" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "spawn" ((PVar "child")) (EApp (EApp (EVar "Spawn") (EVar "child")) (ELam ((PVar "u")) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "spawnTask" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "Task") (TyVar "a")))))
(DFunDef false "spawnTask" ((PVar "act")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EApp (EVar "spawnWith") (EApp (EVar "Ref") (EVar "False"))) (EApp (EVar "Ref") (EVar "None"))) (EVar "act")))))
(DTypeSig false "spawnWith" (TyFun (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "Task") (TyVar "a")))))))
(DFunDef false "spawnWith" ((PVar "done") (PVar "cell") (PVar "act")) (EApp (EApp (EVar "Spawn") (EApp (EApp (EVar "deferThen") (EVar "act")) (ELam ((PVar "a")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EApp (EVar "finish") (EVar "done")) (EVar "cell")) (EVar "a"))))))) (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EApp (EVar "Task") (EVar "done")) (EVar "cell"))))))
(DTypeSig false "finish" (TyFun (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))
(DFunDef false "finish" ((PVar "done") (PVar "cell") (PVar "a")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "a")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "done")) (EVar "True"))) (DoExpr (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "awaitAny" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "awaitAny" ((PVar "waits")) (EApp (EApp (EVar "Await") (EVar "waits")) (ELam ((PVar "u")) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "waitRead" (TyFun (TyCon "Int") (TyApp (TyCon "Wait") (TyRow ((hole "Net")) (Some "e")))))
(DFunDef false "waitRead" ((PVar "fd")) (EApp (EApp (EVar "WaitRead") (EVar "fd")) (EVar "systemPoller")))
(DTypeSig true "waitWrite" (TyFun (TyCon "Int") (TyApp (TyCon "Wait") (TyRow ((hole "Net")) (Some "e")))))
(DFunDef false "waitWrite" ((PVar "fd")) (EApp (EApp (EVar "WaitWrite") (EVar "fd")) (EVar "systemPoller")))
(DTypeSig false "systemPoller" (TyApp (TyCon "Poller") (TyRow ((hole "Net")) (Some "e"))))
(DFunDef false "systemPoller" () (EApp (EVar "Poller") (ELam ((PVar "fds") (PVar "interests") (PVar "timeout")) (EApp (EApp (EApp (EVar "ioPoll") (EVar "fds")) (EVar "interests")) (EVar "timeout")))))
(DTypeSig true "deadlineAfter" (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock") (Some "e"))) (TyApp (TyCon "Wait") (TyRow ("Clock") (Some "e"))))))
(DFunDef false "deadlineAfter" ((PVar "d")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "systemDeadline") (EBinOp "+" (EApp (EVar "monotonicSec") (ELit LUnit)) (EBinOp "/" (EApp (EVar "intToFloat") (EApp (EVar "toMillis") (EVar "d"))) (ELit (LFloat 1000.0)))))))))
(DTypeSig false "systemDeadline" (TyFun (TyCon "Float") (TyApp (TyCon "Wait") (TyRow ("Clock") (Some "e")))))
(DFunDef false "systemDeadline" ((PVar "t")) (EApp (EApp (EVar "WaitUntil") (EVar "t")) (EApp (EApp (EVar "Timer") (ELam ((PVar "u")) (EApp (EVar "monotonicSec") (ELit LUnit)))) (ELam ((PVar "ms")) (EApp (EVar "sleepMs") (EVar "ms"))))))
(DTypeSig true "expired" (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "expired" ((PVar "w")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "expiredNow") (EVar "w"))))))
(DTypeSig false "expiredNow" (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyEffect () (Some "e") (TyCon "Bool"))))
(DFunDef false "expiredNow" ((PCon "WaitUntil" (PVar "t") (PCon "Timer" (PVar "now") PWild))) (EBinOp "<=" (EVar "t") (EApp (EVar "now") (ELit LUnit))))
(DFunDef false "expiredNow" (PWild) (EVar "False"))
(DTypeSig true "await" (TyFun (TyApp (TyCon "Task") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "await" ((PVar "t")) (EApp (EApp (EVar "Await") (EListLit (EApp (EVar "WaitFlag") (EApp (EVar "taskDone") (EVar "t"))))) (ELam ((PVar "u")) (EApp (EVar "awaitResume") (EVar "t")))))
(DTypeSig false "taskDone" (TyFun (TyApp (TyCon "Task") (TyVar "a")) (TyApp (TyCon "Ref") (TyCon "Bool"))))
(DFunDef false "taskDone" ((PCon "Task" (PVar "done") PWild)) (EVar "done"))
(DTypeSig false "awaitResume" (TyFun (TyApp (TyCon "Task") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "awaitResume" ((PCon "Task" (PVar "done") (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "a")) () (EApp (EVar "Done") (EVar "a"))) (arm (PCon "None") () (EApp (EVar "await") (EApp (EApp (EVar "Task") (EVar "done")) (EVar "cell"))))))
(DTypeSig true "concurrent" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "concurrent" ((PVar "asyncs")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "spawnAll") (EListLit)) (EVar "asyncs"))) (ELam ((PVar "ts")) (EApp (EApp (EVar "awaitAll") (EListLit)) (EVar "ts")))))
(DTypeSig false "spawnAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Task") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Task") (TyVar "a")))))))
(DFunDef false "spawnAll" ((PVar "acc") (PList)) (EApp (EVar "Done") (EApp (EVar "reverse") (EVar "acc"))))
(DFunDef false "spawnAll" ((PVar "acc") (PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "spawnTask") (EVar "a"))) (ELam ((PVar "t")) (EApp (EApp (EVar "spawnAll") (EBinOp "::" (EVar "t") (EVar "acc"))) (EVar "rest")))))
(DTypeSig false "awaitAll" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Task") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "awaitAll" ((PVar "acc") (PList)) (EApp (EVar "Done") (EApp (EVar "reverse") (EVar "acc"))))
(DFunDef false "awaitAll" ((PVar "acc") (PCons (PVar "t") (PVar "rest"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "await") (EVar "t"))) (ELam ((PVar "a")) (EApp (EApp (EVar "awaitAll") (EBinOp "::" (EVar "a") (EVar "acc"))) (EVar "rest")))))
(DTypeSig true "runAsync" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyEffect () (Some "e") (TyVar "a"))))
(DFunDef false "runAsync" ((PVar "prog")) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false (PVar "front") (EApp (EVar "Ref") (EListLit (EApp (EApp (EVar "deferThen") (EVar "prog")) (ELam ((PVar "a")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "storeResult") (EVar "cell")) (EVar "a"))))))))) (DoLet false false (PVar "back") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parked") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "schedule") (EVar "front")) (EVar "back")) (EVar "parked")) (ELit (LInt 1)))) (DoExpr (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "async: the program finished without producing a value"))))))))
(DTypeSig true "runAsyncMain" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyEffect () (Some "e") (TyCon "Unit"))))
(DFunDef false "runAsyncMain" ((PVar "prog")) (EApp (EVar "runAsync") (EVar "prog")))
(DTypeSig false "storeResult" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))
(DFunDef false "storeResult" ((PVar "cell") (PVar "a")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "a")))) (DoExpr (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig false "popTask" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyApp (TyCon "Option") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))
(DFunDef false "popTask" ((PVar "front") (PVar "back")) (EMatch (EUnOp "!" (EVar "front")) (arm (PCons (PVar "t") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "front")) (EVar "rest"))) (DoExpr (EApp (EVar "Some") (EVar "t"))))) (arm (PList) () (EMatch (EApp (EVar "reverse") (EUnOp "!" (EVar "back"))) (arm (PList) () (EVar "None")) (arm (PCons (PVar "t") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "front")) (EVar "rest"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "back")) (EListLit))) (DoExpr (EApp (EVar "Some") (EVar "t")))))))))
(DTypeSig false "pushBack" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "pushBack" ((PVar "back") (PVar "t")) (EApp (EApp (EVar "setRef") (EVar "back")) (EBinOp "::" (EVar "t") (EUnOp "!" (EVar "back")))))
(DTypeSig false "queueLength" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyCon "Int"))))
(DFunDef false "queueLength" ((PVar "front") (PVar "back")) (EBinOp "+" (EApp (EVar "length") (EUnOp "!" (EVar "front"))) (EApp (EVar "length") (EUnOp "!" (EVar "back")))))
(DTypeSig false "schedule" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))
(DFunDef false "schedule" ((PVar "front") (PVar "back") (PVar "parked") (PVar "budget")) (EIf (EBinOp "<=" (EVar "budget") (ELit (LInt 0))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "wakeParked") (EVar "back")) (EVar "parked")) (EVar "False"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "schedule") (EVar "front")) (EVar "back")) (EVar "parked")) (EApp (EApp (EVar "max") (ELit (LInt 1))) (EApp (EApp (EVar "queueLength") (EVar "front")) (EVar "back")))))) (EMatch (EApp (EApp (EVar "popTask") (EVar "front")) (EVar "back")) (arm (PCon "Some" (PVar "t")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "dispatch") (EVar "back")) (EVar "parked")) (EApp (EVar "stepTask") (EVar "t")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "schedule") (EVar "front")) (EVar "back")) (EVar "parked")) (EBinOp "-" (EVar "budget") (ELit (LInt 1))))))) (arm (PCon "None") () (EMatch (EUnOp "!" (EVar "parked")) (arm (PList) () (ELit LUnit)) (arm PWild () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "wakeParked") (EVar "back")) (EVar "parked")) (EVar "True"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "schedule") (EVar "front")) (EVar "back")) (EVar "parked")) (EApp (EApp (EVar "max") (ELit (LInt 1))) (EApp (EApp (EVar "queueLength") (EVar "front")) (EVar "back"))))))))))))
(DTypeSig false "stepTask" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))
(DFunDef false "stepTask" ((PCon "Suspend" (PVar "k"))) (EApp (EVar "k") (ELit LUnit)))
(DFunDef false "stepTask" ((PVar "other")) (EVar "other"))
(DTypeSig false "dispatch" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))) (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyCon "Unit")))))
(DFunDef false "dispatch" (PWild PWild (PCon "Done" PWild)) (ELit LUnit))
(DFunDef false "dispatch" ((PVar "back") PWild (PCon "Suspend" (PVar "k"))) (EApp (EApp (EVar "pushBack") (EVar "back")) (EApp (EVar "Suspend") (EVar "k"))))
(DFunDef false "dispatch" (PWild (PVar "parked") (PCon "Await" (PVar "ws") (PVar "k"))) (EApp (EApp (EVar "setRef") (EVar "parked")) (EBinOp "::" (ETuple (EVar "ws") (EVar "k")) (EUnOp "!" (EVar "parked")))))
(DFunDef false "dispatch" ((PVar "back") PWild (PCon "Spawn" (PVar "child") (PVar "k"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "pushBack") (EVar "back")) (EVar "child"))) (DoExpr (EApp (EApp (EVar "pushBack") (EVar "back")) (EApp (EVar "Suspend") (EVar "k"))))))
(DTypeSig false "wakeParked" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))) (TyFun (TyCon "Bool") (TyEffect () (Some "e") (TyCon "Unit"))))))
(DFunDef false "wakeParked" ((PVar "back") (PVar "parked") (PVar "block")) (EBlock (DoLet false false (PVar "soonest") (EApp (EVar "earliestDeadline") (EUnOp "!" (EVar "parked")))) (DoLet false false (PVar "now") (EApp (EVar "readNow") (EVar "soonest"))) (DoLet false false (PTuple (PVar "ready") (PVar "waiting")) (EApp (EApp (EVar "partition") (ELam ((PVar "p")) (EApp (EApp (EVar "isReady") (EVar "now")) (EVar "p")))) (EUnOp "!" (EVar "parked")))) (DoExpr (EMatch (EVar "ready") (arm (PCons PWild PWild) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "parked")) (EVar "waiting"))) (DoExpr (EApp (EApp (EVar "requeue") (EVar "back")) (EVar "ready"))))) (arm (PList) () (EMatch (EApp (EVar "fdWaitsOf") (EVar "waiting")) (arm (PCon "None") () (EIf (EApp (EVar "not") (EVar "block")) (ELit LUnit) (EApp (EApp (EVar "sleepThrough") (EVar "now")) (EVar "soonest")))) (arm (PCon "Some" (PTuple (PCon "Poller" (PVar "poll")) (PVar "fdWaits"))) () (EMatch (EApp (EApp (EApp (EVar "poll") (EApp (EVar "fromList") (EApp (EApp (EVar "map") (EVar "pollFd")) (EVar "fdWaits")))) (EApp (EVar "fromList") (EApp (EApp (EVar "map") (EVar "pollInterest")) (EVar "fdWaits")))) (EApp (EApp (EApp (EVar "pollTimeout") (EVar "block")) (EVar "now")) (EVar "soonest"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "async: poll failed: ")) (EVar "e")))) (arm (PCon "Ok" (PVar "readiness")) () (EBlock (DoLet false false (PVar "satisfied") (EApp (EApp (EVar "satisfiedWaits") (EVar "fdWaits")) (EApp (EVar "toList") (EVar "readiness")))) (DoLet false false (PTuple (PVar "woke") (PVar "still")) (EApp (EApp (EVar "partition") (ELam ((PVar "p")) (EApp (EApp (EVar "any") (ELam ((PVar "w")) (EApp (EApp (EVar "waitSatisfied") (EVar "satisfied")) (EVar "w")))) (EApp (EVar "fst") (EVar "p"))))) (EVar "waiting"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "parked")) (EVar "still"))) (DoExpr (EApp (EApp (EVar "requeue") (EVar "back")) (EVar "woke")))))))))))))
(DTypeSig false "readNow" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Float")))))
(DFunDef false "readNow" ((PCon "None")) (EVar "None"))
(DFunDef false "readNow" ((PCon "Some" (PTuple PWild (PCon "Timer" (PVar "now") PWild)))) (EApp (EVar "Some") (EApp (EVar "now") (ELit LUnit))))
(DTypeSig false "sleepThrough" (TyFun (TyApp (TyCon "Option") (TyCon "Float")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "sleepThrough" ((PCon "Some" (PVar "now")) (PCon "Some" (PTuple (PVar "t") (PCon "Timer" PWild (PVar "sleepFor"))))) (EApp (EVar "sleepFor") (EApp (EApp (EVar "millisUntil") (EVar "now")) (EVar "t"))))
(DFunDef false "sleepThrough" (PWild PWild) (EApp (EVar "panic") (ELit (LString "async: every remaining task is waiting on a task that can never finish (deadlock)"))))
(DTypeSig false "pollTimeout" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Float")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))) (TyCon "Int")))))
(DFunDef false "pollTimeout" ((PCon "False") PWild PWild) (ELit (LInt 0)))
(DFunDef false "pollTimeout" ((PCon "True") (PCon "Some" (PVar "now")) (PCon "Some" (PTuple (PVar "t") PWild))) (EApp (EApp (EVar "millisUntil") (EVar "now")) (EVar "t")))
(DFunDef false "pollTimeout" ((PCon "True") PWild PWild) (EUnOp "-" (ELit (LInt 1))))
(DTypeSig false "millisUntil" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Int"))))
(DFunDef false "millisUntil" ((PVar "now") (PVar "t")) (EApp (EApp (EVar "max") (ELit (LInt 0))) (EBinOp "+" (EApp (EVar "floatToInt") (EBinOp "*" (EBinOp "-" (EVar "t") (EVar "now")) (ELit (LFloat 1000.0)))) (ELit (LInt 1)))))
(DTypeSig false "requeue" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyCon "Unit"))))
(DFunDef false "requeue" ((PVar "back") (PVar "ready")) (EApp (EApp (EVar "requeueOldestFirst") (EVar "back")) (EApp (EVar "reverse") (EVar "ready"))))
(DTypeSig false "requeueOldestFirst" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyCon "Unit"))))
(DFunDef false "requeueOldestFirst" (PWild (PList)) (ELit LUnit))
(DFunDef false "requeueOldestFirst" ((PVar "back") (PCons (PTuple PWild (PVar "k")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "pushBack") (EVar "back")) (EApp (EVar "Suspend") (EVar "k")))) (DoExpr (EApp (EApp (EVar "requeueOldestFirst") (EVar "back")) (EVar "rest")))))
(DTypeSig false "isReady" (TyFun (TyApp (TyCon "Option") (TyCon "Float")) (TyFun (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))) (TyCon "Bool"))))
(DFunDef false "isReady" ((PVar "now") (PTuple (PVar "ws") PWild)) (EApp (EApp (EVar "any") (ELam ((PVar "w")) (EApp (EApp (EVar "waitReady") (EVar "now")) (EVar "w")))) (EVar "ws")))
(DTypeSig false "waitReady" (TyFun (TyApp (TyCon "Option") (TyCon "Float")) (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "waitReady" ((PCon "Some" (PVar "now")) (PCon "WaitUntil" (PVar "t") PWild)) (EBinOp "<=" (EVar "t") (EVar "now")))
(DFunDef false "waitReady" (PWild (PCon "WaitFlag" (PVar "r"))) (EUnOp "!" (EVar "r")))
(DFunDef false "waitReady" (PWild PWild) (EVar "False"))
(DTypeSig false "isFdWait" (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Bool")))
(DFunDef false "isFdWait" ((PCon "WaitRead" PWild PWild)) (EVar "True"))
(DFunDef false "isFdWait" ((PCon "WaitWrite" PWild PWild)) (EVar "True"))
(DFunDef false "isFdWait" (PWild) (EVar "False"))
(DTypeSig false "earliestDeadline" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e"))))))
(DFunDef false "earliestDeadline" ((PList)) (EVar "None"))
(DFunDef false "earliestDeadline" ((PCons (PTuple (PVar "ws") PWild) (PVar "rest"))) (EApp (EApp (EVar "minDeadline") (EApp (EVar "deadlinesOf") (EVar "ws"))) (EApp (EVar "earliestDeadline") (EVar "rest"))))
(DTypeSig false "deadlinesOf" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e"))))))
(DFunDef false "deadlinesOf" ((PList)) (EVar "None"))
(DFunDef false "deadlinesOf" ((PCons (PCon "WaitUntil" (PVar "t") (PVar "c")) (PVar "rest"))) (EApp (EApp (EVar "minDeadline") (EApp (EVar "Some") (ETuple (EVar "t") (EVar "c")))) (EApp (EVar "deadlinesOf") (EVar "rest"))))
(DFunDef false "deadlinesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "deadlinesOf") (EVar "rest")))
(DTypeSig false "minDeadline" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))) (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))))))
(DFunDef false "minDeadline" ((PCon "None") (PVar "b")) (EVar "b"))
(DFunDef false "minDeadline" ((PVar "a") (PCon "None")) (EVar "a"))
(DFunDef false "minDeadline" ((PCon "Some" (PTuple (PVar "x") (PVar "cx"))) (PCon "Some" (PTuple (PVar "y") (PVar "cy")))) (EIf (EBinOp "<=" (EVar "x") (EVar "y")) (EApp (EVar "Some") (ETuple (EVar "x") (EVar "cx"))) (EApp (EVar "Some") (ETuple (EVar "y") (EVar "cy")))))
(DTypeSig false "fdWaitsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "Poller") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e")))))))
(DFunDef false "fdWaitsOf" ((PVar "ps")) (EBlock (DoLet false false (PVar "ws") (EApp (EVar "fdWaitsIn") (EVar "ps"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EVar "p") (EVar "ws")))) (EApp (EVar "pollerOf") (EVar "ws"))))))
(DTypeSig false "fdWaitsIn" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e")))))
(DFunDef false "fdWaitsIn" ((PList)) (EListLit))
(DFunDef false "fdWaitsIn" ((PCons (PTuple (PVar "ws") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "filter") (EVar "isFdWait")) (EVar "ws")) (EApp (EVar "fdWaitsIn") (EVar "rest"))))
(DTypeSig false "pollerOf" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyApp (TyCon "Option") (TyApp (TyCon "Poller") (TyVar "e")))))
(DFunDef false "pollerOf" ((PList)) (EVar "None"))
(DFunDef false "pollerOf" ((PCons (PCon "WaitRead" PWild (PVar "p")) PWild)) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "pollerOf" ((PCons (PCon "WaitWrite" PWild (PVar "p")) PWild)) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "pollerOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "pollerOf") (EVar "rest")))
(DTypeSig false "pollFd" (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Int")))
(DFunDef false "pollFd" ((PCon "WaitRead" (PVar "fd") PWild)) (EVar "fd"))
(DFunDef false "pollFd" ((PCon "WaitWrite" (PVar "fd") PWild)) (EVar "fd"))
(DFunDef false "pollFd" (PWild) (EUnOp "-" (ELit (LInt 1))))
(DTypeSig false "pollInterest" (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Int")))
(DFunDef false "pollInterest" ((PCon "WaitRead" PWild PWild)) (ELit (LInt 1)))
(DFunDef false "pollInterest" ((PCon "WaitWrite" PWild PWild)) (ELit (LInt 2)))
(DFunDef false "pollInterest" (PWild) (ELit (LInt 0)))
(DTypeSig false "satisfiedWaits" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))))))
(DFunDef false "satisfiedWaits" ((PCons (PVar "w") (PVar "ws")) (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EVar "r") (ELit (LInt 0))) (EApp (EApp (EVar "satisfiedWaits") (EVar "ws")) (EVar "rs")) (EBinOp "::" (EVar "w") (EApp (EApp (EVar "satisfiedWaits") (EVar "ws")) (EVar "rs")))))
(DFunDef false "satisfiedWaits" (PWild PWild) (EListLit))
(DTypeSig false "waitSatisfied" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "waitSatisfied" ((PVar "sat") (PCon "WaitRead" (PVar "fd") PWild)) (EApp (EApp (EVar "any") (ELam ((PVar "w")) (EApp (EApp (EVar "isReadOf") (EVar "fd")) (EVar "w")))) (EVar "sat")))
(DFunDef false "waitSatisfied" ((PVar "sat") (PCon "WaitWrite" (PVar "fd") PWild)) (EApp (EApp (EVar "any") (ELam ((PVar "w")) (EApp (EApp (EVar "isWriteOf") (EVar "fd")) (EVar "w")))) (EVar "sat")))
(DFunDef false "waitSatisfied" (PWild PWild) (EVar "False"))
(DTypeSig false "isReadOf" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "isReadOf" ((PVar "fd") (PCon "WaitRead" (PVar "x") PWild)) (EBinOp "==" (EVar "x") (EVar "fd")))
(DFunDef false "isReadOf" (PWild PWild) (EVar "False"))
(DTypeSig false "isWriteOf" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "isWriteOf" ((PVar "fd") (PCon "WaitWrite" (PVar "x") PWild)) (EBinOp "==" (EVar "x") (EVar "fd")))
(DFunDef false "isWriteOf" (PWild PWild) (EVar "False"))
# MARK
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "partition" false) (mem "reverse" false))))
(DUse false (UseGroup ("time") ((mem "Duration" false) (mem "millis" false) (mem "toMillis" false))))
(DData Private "Timer" ("e") ((variant "Timer" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyCon "Float"))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))) ())
(DData Private "Poller" ("e") ((variant "Poller" (ConPos (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))))) ())
(DData Abstract "Wait" ("e") ((variant "WaitRead" (ConPos (TyCon "Int") (TyApp (TyCon "Poller") (TyVar "e")))) (variant "WaitWrite" (ConPos (TyCon "Int") (TyApp (TyCon "Poller") (TyVar "e")))) (variant "WaitUntil" (ConPos (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))) (variant "WaitFlag" (ConPos (TyApp (TyCon "Ref") (TyCon "Bool"))))) ())
(DData Abstract "Async" ("e" "a") ((variant "Done" (ConPos (TyVar "a"))) (variant "Suspend" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))) (variant "Await" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))) (variant "Spawn" (ConPos (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))))) ())
(DData Abstract "Task" ("a") ((variant "Task" (ConPos (TyApp (TyCon "Ref") (TyCon "Bool")) (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a")))))) ())
(DImpl true "DeferredMappable" ((TyCon "Async")) () ((im "deferMap" ((PVar "f") (PCon "Done" (PVar "a"))) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "f") (EVar "a")))))) (im "deferMap" ((PVar "f") (PCon "Suspend" (PVar "t"))) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u")))))) (im "deferMap" ((PVar "f") (PCon "Await" (PVar "ws") (PVar "t"))) (EApp (EApp (EVar "Await") (EVar "ws")) (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u")))))) (im "deferMap" ((PVar "f") (PCon "Spawn" (PVar "c") (PVar "t"))) (EApp (EApp (EVar "Spawn") (EVar "c")) (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u"))))))))
(DImpl true "DeferredApplicative" ((TyCon "Async")) () ((im "deferPure" ((PVar "a")) (EApp (EVar "Done") (EVar "a"))) (im "deferAp" ((PVar "mf") (PVar "ma")) (EApp (EApp (EMethodRef "deferThen") (EVar "mf")) (ELam ((PVar "f")) (EApp (EApp (EMethodRef "deferMap") (EVar "f")) (EVar "ma")))))))
(DImpl true "DeferredThenable" ((TyCon "Async")) () ((im "deferThen" ((PCon "Done" (PVar "a")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "k") (EVar "a"))))) (im "deferThen" ((PCon "Suspend" (PVar "t")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k"))))) (im "deferThen" ((PCon "Await" (PVar "ws") (PVar "t")) (PVar "k")) (EApp (EApp (EVar "Await") (EVar "ws")) (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k"))))) (im "deferThen" ((PCon "Spawn" (PVar "c") (PVar "t")) (PVar "k")) (EApp (EApp (EVar "Spawn") (EVar "c")) (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k")))))))
(DTypeSig true "liftIO" (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "liftIO" ((PVar "act")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "act") (EVar "u"))))))
(DTypeSig true "yield" (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))
(DFunDef false "yield" () (EApp (EVar "Suspend") (ELam (PWild) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "sleep" (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock") (Some "e"))) (TyCon "Unit"))))
(DFunDef false "sleep" ((PVar "d")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "sleepFrom") (EApp (EVar "monotonicSec") (ELit LUnit))) (EVar "d")))))
(DTypeSig false "sleepFrom" (TyFun (TyCon "Float") (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock") (Some "e"))) (TyCon "Unit")))))
(DFunDef false "sleepFrom" ((PVar "now") (PVar "d")) (EBlock (DoLet false false (PVar "deadline") (EBinOp "+" (EVar "now") (EBinOp "/" (EApp (EVar "intToFloat") (EApp (EVar "toMillis") (EVar "d"))) (ELit (LFloat 1000.0))))) (DoExpr (EApp (EApp (EVar "Await") (EListLit (EApp (EVar "systemDeadline") (EVar "deadline")))) (ELam ((PVar "u")) (EApp (EVar "Done") (ELit LUnit)))))))
(DTypeSig true "spawn" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "spawn" ((PVar "child")) (EApp (EApp (EVar "Spawn") (EVar "child")) (ELam ((PVar "u")) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "spawnTask" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "Task") (TyVar "a")))))
(DFunDef false "spawnTask" ((PVar "act")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EApp (EVar "spawnWith") (EApp (EVar "Ref") (EVar "False"))) (EApp (EVar "Ref") (EVar "None"))) (EVar "act")))))
(DTypeSig false "spawnWith" (TyFun (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "Task") (TyVar "a")))))))
(DFunDef false "spawnWith" ((PVar "done") (PVar "cell") (PVar "act")) (EApp (EApp (EVar "Spawn") (EApp (EApp (EMethodRef "deferThen") (EVar "act")) (ELam ((PVar "a")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EApp (EVar "finish") (EVar "done")) (EVar "cell")) (EVar "a"))))))) (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EApp (EVar "Task") (EVar "done")) (EVar "cell"))))))
(DTypeSig false "finish" (TyFun (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))
(DFunDef false "finish" ((PVar "done") (PVar "cell") (PVar "a")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "a")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "done")) (EVar "True"))) (DoExpr (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "awaitAny" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "awaitAny" ((PVar "waits")) (EApp (EApp (EVar "Await") (EVar "waits")) (ELam ((PVar "u")) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "waitRead" (TyFun (TyCon "Int") (TyApp (TyCon "Wait") (TyRow ((hole "Net")) (Some "e")))))
(DFunDef false "waitRead" ((PVar "fd")) (EApp (EApp (EVar "WaitRead") (EVar "fd")) (EVar "systemPoller")))
(DTypeSig true "waitWrite" (TyFun (TyCon "Int") (TyApp (TyCon "Wait") (TyRow ((hole "Net")) (Some "e")))))
(DFunDef false "waitWrite" ((PVar "fd")) (EApp (EApp (EVar "WaitWrite") (EVar "fd")) (EVar "systemPoller")))
(DTypeSig false "systemPoller" (TyApp (TyCon "Poller") (TyRow ((hole "Net")) (Some "e"))))
(DFunDef false "systemPoller" () (EApp (EVar "Poller") (ELam ((PVar "fds") (PVar "interests") (PVar "timeout")) (EApp (EApp (EApp (EVar "ioPoll") (EVar "fds")) (EVar "interests")) (EVar "timeout")))))
(DTypeSig true "deadlineAfter" (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyRow ("Clock") (Some "e"))) (TyApp (TyCon "Wait") (TyRow ("Clock") (Some "e"))))))
(DFunDef false "deadlineAfter" ((PVar "d")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "systemDeadline") (EBinOp "+" (EApp (EVar "monotonicSec") (ELit LUnit)) (EBinOp "/" (EApp (EVar "intToFloat") (EApp (EVar "toMillis") (EVar "d"))) (ELit (LFloat 1000.0)))))))))
(DTypeSig false "systemDeadline" (TyFun (TyCon "Float") (TyApp (TyCon "Wait") (TyRow ("Clock") (Some "e")))))
(DFunDef false "systemDeadline" ((PVar "t")) (EApp (EApp (EVar "WaitUntil") (EVar "t")) (EApp (EApp (EVar "Timer") (ELam ((PVar "u")) (EApp (EVar "monotonicSec") (ELit LUnit)))) (ELam ((PVar "ms")) (EApp (EVar "sleepMs") (EVar "ms"))))))
(DTypeSig true "expired" (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "expired" ((PVar "w")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "expiredNow") (EVar "w"))))))
(DTypeSig false "expiredNow" (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyEffect () (Some "e") (TyCon "Bool"))))
(DFunDef false "expiredNow" ((PCon "WaitUntil" (PVar "t") (PCon "Timer" (PVar "now") PWild))) (EBinOp "<=" (EVar "t") (EApp (EVar "now") (ELit LUnit))))
(DFunDef false "expiredNow" (PWild) (EVar "False"))
(DTypeSig true "await" (TyFun (TyApp (TyCon "Task") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "await" ((PVar "t")) (EApp (EApp (EVar "Await") (EListLit (EApp (EVar "WaitFlag") (EApp (EVar "taskDone") (EVar "t"))))) (ELam ((PVar "u")) (EApp (EVar "awaitResume") (EVar "t")))))
(DTypeSig false "taskDone" (TyFun (TyApp (TyCon "Task") (TyVar "a")) (TyApp (TyCon "Ref") (TyCon "Bool"))))
(DFunDef false "taskDone" ((PCon "Task" (PVar "done") PWild)) (EVar "done"))
(DTypeSig false "awaitResume" (TyFun (TyApp (TyCon "Task") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "awaitResume" ((PCon "Task" (PVar "done") (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "a")) () (EApp (EVar "Done") (EVar "a"))) (arm (PCon "None") () (EApp (EVar "await") (EApp (EApp (EVar "Task") (EVar "done")) (EVar "cell"))))))
(DTypeSig true "concurrent" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "concurrent" ((PVar "asyncs")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "spawnAll") (EListLit)) (EVar "asyncs"))) (ELam ((PVar "ts")) (EApp (EApp (EVar "awaitAll") (EListLit)) (EVar "ts")))))
(DTypeSig false "spawnAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Task") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Task") (TyVar "a")))))))
(DFunDef false "spawnAll" ((PVar "acc") (PList)) (EApp (EVar "Done") (EApp (EVar "reverse") (EVar "acc"))))
(DFunDef false "spawnAll" ((PVar "acc") (PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "spawnTask") (EVar "a"))) (ELam ((PVar "t")) (EApp (EApp (EVar "spawnAll") (EBinOp "::" (EVar "t") (EVar "acc"))) (EVar "rest")))))
(DTypeSig false "awaitAll" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Task") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "awaitAll" ((PVar "acc") (PList)) (EApp (EVar "Done") (EApp (EVar "reverse") (EVar "acc"))))
(DFunDef false "awaitAll" ((PVar "acc") (PCons (PVar "t") (PVar "rest"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "await") (EVar "t"))) (ELam ((PVar "a")) (EApp (EApp (EVar "awaitAll") (EBinOp "::" (EVar "a") (EVar "acc"))) (EVar "rest")))))
(DTypeSig true "runAsync" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyEffect () (Some "e") (TyVar "a"))))
(DFunDef false "runAsync" ((PVar "prog")) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false (PVar "front") (EApp (EVar "Ref") (EListLit (EApp (EApp (EMethodRef "deferThen") (EVar "prog")) (ELam ((PVar "a")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "storeResult") (EVar "cell")) (EVar "a"))))))))) (DoLet false false (PVar "back") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parked") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "schedule") (EVar "front")) (EVar "back")) (EVar "parked")) (ELit (LInt 1)))) (DoExpr (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "async: the program finished without producing a value"))))))))
(DTypeSig true "runAsyncMain" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyEffect () (Some "e") (TyCon "Unit"))))
(DFunDef false "runAsyncMain" ((PVar "prog")) (EApp (EVar "runAsync") (EVar "prog")))
(DTypeSig false "storeResult" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))
(DFunDef false "storeResult" ((PVar "cell") (PVar "a")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "a")))) (DoExpr (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig false "popTask" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyApp (TyCon "Option") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))
(DFunDef false "popTask" ((PVar "front") (PVar "back")) (EMatch (EUnOp "!" (EVar "front")) (arm (PCons (PVar "t") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "front")) (EVar "rest"))) (DoExpr (EApp (EVar "Some") (EVar "t"))))) (arm (PList) () (EMatch (EApp (EVar "reverse") (EUnOp "!" (EVar "back"))) (arm (PList) () (EVar "None")) (arm (PCons (PVar "t") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "front")) (EVar "rest"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "back")) (EListLit))) (DoExpr (EApp (EVar "Some") (EVar "t")))))))))
(DTypeSig false "pushBack" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "pushBack" ((PVar "back") (PVar "t")) (EApp (EApp (EVar "setRef") (EVar "back")) (EBinOp "::" (EVar "t") (EUnOp "!" (EVar "back")))))
(DTypeSig false "queueLength" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyCon "Int"))))
(DFunDef false "queueLength" ((PVar "front") (PVar "back")) (EBinOp "+" (EApp (EMethodRef "length") (EUnOp "!" (EVar "front"))) (EApp (EMethodRef "length") (EUnOp "!" (EVar "back")))))
(DTypeSig false "schedule" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))))
(DFunDef false "schedule" ((PVar "front") (PVar "back") (PVar "parked") (PVar "budget")) (EIf (EBinOp "<=" (EVar "budget") (ELit (LInt 0))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "wakeParked") (EVar "back")) (EVar "parked")) (EVar "False"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "schedule") (EVar "front")) (EVar "back")) (EVar "parked")) (EApp (EApp (EMethodRef "max") (ELit (LInt 1))) (EApp (EApp (EVar "queueLength") (EVar "front")) (EVar "back")))))) (EMatch (EApp (EApp (EVar "popTask") (EVar "front")) (EVar "back")) (arm (PCon "Some" (PVar "t")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "dispatch") (EVar "back")) (EVar "parked")) (EApp (EVar "stepTask") (EVar "t")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "schedule") (EVar "front")) (EVar "back")) (EVar "parked")) (EBinOp "-" (EVar "budget") (ELit (LInt 1))))))) (arm (PCon "None") () (EMatch (EUnOp "!" (EVar "parked")) (arm (PList) () (ELit LUnit)) (arm PWild () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "wakeParked") (EVar "back")) (EVar "parked")) (EVar "True"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "schedule") (EVar "front")) (EVar "back")) (EVar "parked")) (EApp (EApp (EMethodRef "max") (ELit (LInt 1))) (EApp (EApp (EVar "queueLength") (EVar "front")) (EVar "back"))))))))))))
(DTypeSig false "stepTask" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))
(DFunDef false "stepTask" ((PCon "Suspend" (PVar "k"))) (EApp (EVar "k") (ELit LUnit)))
(DFunDef false "stepTask" ((PVar "other")) (EVar "other"))
(DTypeSig false "dispatch" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))) (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyCon "Unit")))))
(DFunDef false "dispatch" (PWild PWild (PCon "Done" PWild)) (ELit LUnit))
(DFunDef false "dispatch" ((PVar "back") PWild (PCon "Suspend" (PVar "k"))) (EApp (EApp (EVar "pushBack") (EVar "back")) (EApp (EVar "Suspend") (EVar "k"))))
(DFunDef false "dispatch" (PWild (PVar "parked") (PCon "Await" (PVar "ws") (PVar "k"))) (EApp (EApp (EVar "setRef") (EVar "parked")) (EBinOp "::" (ETuple (EVar "ws") (EVar "k")) (EUnOp "!" (EVar "parked")))))
(DFunDef false "dispatch" ((PVar "back") PWild (PCon "Spawn" (PVar "child") (PVar "k"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "pushBack") (EVar "back")) (EVar "child"))) (DoExpr (EApp (EApp (EVar "pushBack") (EVar "back")) (EApp (EVar "Suspend") (EVar "k"))))))
(DTypeSig false "wakeParked" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))) (TyFun (TyCon "Bool") (TyEffect () (Some "e") (TyCon "Unit"))))))
(DFunDef false "wakeParked" ((PVar "back") (PVar "parked") (PVar "block")) (EBlock (DoLet false false (PVar "soonest") (EApp (EVar "earliestDeadline") (EUnOp "!" (EVar "parked")))) (DoLet false false (PVar "now") (EApp (EVar "readNow") (EVar "soonest"))) (DoLet false false (PTuple (PVar "ready") (PVar "waiting")) (EApp (EApp (EVar "partition") (ELam ((PVar "p")) (EApp (EApp (EVar "isReady") (EVar "now")) (EVar "p")))) (EUnOp "!" (EVar "parked")))) (DoExpr (EMatch (EVar "ready") (arm (PCons PWild PWild) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "parked")) (EVar "waiting"))) (DoExpr (EApp (EApp (EVar "requeue") (EVar "back")) (EVar "ready"))))) (arm (PList) () (EMatch (EApp (EVar "fdWaitsOf") (EVar "waiting")) (arm (PCon "None") () (EIf (EApp (EVar "not") (EVar "block")) (ELit LUnit) (EApp (EApp (EVar "sleepThrough") (EVar "now")) (EVar "soonest")))) (arm (PCon "Some" (PTuple (PCon "Poller" (PVar "poll")) (PVar "fdWaits"))) () (EMatch (EApp (EApp (EApp (EVar "poll") (EApp (EVar "fromList") (EApp (EApp (EMethodRef "map") (EVar "pollFd")) (EVar "fdWaits")))) (EApp (EVar "fromList") (EApp (EApp (EMethodRef "map") (EVar "pollInterest")) (EVar "fdWaits")))) (EApp (EApp (EApp (EVar "pollTimeout") (EVar "block")) (EVar "now")) (EVar "soonest"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "async: poll failed: ")) (EVar "e")))) (arm (PCon "Ok" (PVar "readiness")) () (EBlock (DoLet false false (PVar "satisfied") (EApp (EApp (EVar "satisfiedWaits") (EVar "fdWaits")) (EApp (EMethodRef "toList") (EVar "readiness")))) (DoLet false false (PTuple (PVar "woke") (PVar "still")) (EApp (EApp (EVar "partition") (ELam ((PVar "p")) (EApp (EApp (EDictApp "any") (ELam ((PVar "w")) (EApp (EApp (EVar "waitSatisfied") (EVar "satisfied")) (EVar "w")))) (EApp (EVar "fst") (EVar "p"))))) (EVar "waiting"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "parked")) (EVar "still"))) (DoExpr (EApp (EApp (EVar "requeue") (EVar "back")) (EVar "woke")))))))))))))
(DTypeSig false "readNow" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Float")))))
(DFunDef false "readNow" ((PCon "None")) (EVar "None"))
(DFunDef false "readNow" ((PCon "Some" (PTuple PWild (PCon "Timer" (PVar "now") PWild)))) (EApp (EVar "Some") (EApp (EVar "now") (ELit LUnit))))
(DTypeSig false "sleepThrough" (TyFun (TyApp (TyCon "Option") (TyCon "Float")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "sleepThrough" ((PCon "Some" (PVar "now")) (PCon "Some" (PTuple (PVar "t") (PCon "Timer" PWild (PVar "sleepFor"))))) (EApp (EVar "sleepFor") (EApp (EApp (EVar "millisUntil") (EVar "now")) (EVar "t"))))
(DFunDef false "sleepThrough" (PWild PWild) (EApp (EVar "panic") (ELit (LString "async: every remaining task is waiting on a task that can never finish (deadlock)"))))
(DTypeSig false "pollTimeout" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Float")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))) (TyCon "Int")))))
(DFunDef false "pollTimeout" ((PCon "False") PWild PWild) (ELit (LInt 0)))
(DFunDef false "pollTimeout" ((PCon "True") (PCon "Some" (PVar "now")) (PCon "Some" (PTuple (PVar "t") PWild))) (EApp (EApp (EVar "millisUntil") (EVar "now")) (EVar "t")))
(DFunDef false "pollTimeout" ((PCon "True") PWild PWild) (EUnOp "-" (ELit (LInt 1))))
(DTypeSig false "millisUntil" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Int"))))
(DFunDef false "millisUntil" ((PVar "now") (PVar "t")) (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EBinOp "+" (EApp (EVar "floatToInt") (EBinOp "*" (EBinOp "-" (EVar "t") (EVar "now")) (ELit (LFloat 1000.0)))) (ELit (LInt 1)))))
(DTypeSig false "requeue" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyCon "Unit"))))
(DFunDef false "requeue" ((PVar "back") (PVar "ready")) (EApp (EApp (EVar "requeueOldestFirst") (EVar "back")) (EApp (EVar "reverse") (EVar "ready"))))
(DTypeSig false "requeueOldestFirst" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyCon "Unit"))))
(DFunDef false "requeueOldestFirst" (PWild (PList)) (ELit LUnit))
(DFunDef false "requeueOldestFirst" ((PVar "back") (PCons (PTuple PWild (PVar "k")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "pushBack") (EVar "back")) (EApp (EVar "Suspend") (EVar "k")))) (DoExpr (EApp (EApp (EVar "requeueOldestFirst") (EVar "back")) (EVar "rest")))))
(DTypeSig false "isReady" (TyFun (TyApp (TyCon "Option") (TyCon "Float")) (TyFun (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))) (TyCon "Bool"))))
(DFunDef false "isReady" ((PVar "now") (PTuple (PVar "ws") PWild)) (EApp (EApp (EDictApp "any") (ELam ((PVar "w")) (EApp (EApp (EVar "waitReady") (EVar "now")) (EVar "w")))) (EVar "ws")))
(DTypeSig false "waitReady" (TyFun (TyApp (TyCon "Option") (TyCon "Float")) (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "waitReady" ((PCon "Some" (PVar "now")) (PCon "WaitUntil" (PVar "t") PWild)) (EBinOp "<=" (EVar "t") (EVar "now")))
(DFunDef false "waitReady" (PWild (PCon "WaitFlag" (PVar "r"))) (EUnOp "!" (EVar "r")))
(DFunDef false "waitReady" (PWild PWild) (EVar "False"))
(DTypeSig false "isFdWait" (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Bool")))
(DFunDef false "isFdWait" ((PCon "WaitRead" PWild PWild)) (EVar "True"))
(DFunDef false "isFdWait" ((PCon "WaitWrite" PWild PWild)) (EVar "True"))
(DFunDef false "isFdWait" (PWild) (EVar "False"))
(DTypeSig false "earliestDeadline" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e"))))))
(DFunDef false "earliestDeadline" ((PList)) (EVar "None"))
(DFunDef false "earliestDeadline" ((PCons (PTuple (PVar "ws") PWild) (PVar "rest"))) (EApp (EApp (EVar "minDeadline") (EApp (EVar "deadlinesOf") (EVar "ws"))) (EApp (EVar "earliestDeadline") (EVar "rest"))))
(DTypeSig false "deadlinesOf" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e"))))))
(DFunDef false "deadlinesOf" ((PList)) (EVar "None"))
(DFunDef false "deadlinesOf" ((PCons (PCon "WaitUntil" (PVar "t") (PVar "c")) (PVar "rest"))) (EApp (EApp (EVar "minDeadline") (EApp (EVar "Some") (ETuple (EVar "t") (EVar "c")))) (EApp (EVar "deadlinesOf") (EVar "rest"))))
(DFunDef false "deadlinesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "deadlinesOf") (EVar "rest")))
(DTypeSig false "minDeadline" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))) (TyApp (TyCon "Option") (TyTuple (TyCon "Float") (TyApp (TyCon "Timer") (TyVar "e")))))))
(DFunDef false "minDeadline" ((PCon "None") (PVar "b")) (EVar "b"))
(DFunDef false "minDeadline" ((PVar "a") (PCon "None")) (EVar "a"))
(DFunDef false "minDeadline" ((PCon "Some" (PTuple (PVar "x") (PVar "cx"))) (PCon "Some" (PTuple (PVar "y") (PVar "cy")))) (EIf (EBinOp "<=" (EVar "x") (EVar "y")) (EApp (EVar "Some") (ETuple (EVar "x") (EVar "cx"))) (EApp (EVar "Some") (ETuple (EVar "y") (EVar "cy")))))
(DTypeSig false "fdWaitsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "Poller") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e")))))))
(DFunDef false "fdWaitsOf" ((PVar "ps")) (EBlock (DoLet false false (PVar "ws") (EApp (EVar "fdWaitsIn") (EVar "ps"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EVar "p") (EVar "ws")))) (EApp (EVar "pollerOf") (EVar "ws"))))))
(DTypeSig false "fdWaitsIn" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e")))))
(DFunDef false "fdWaitsIn" ((PList)) (EListLit))
(DFunDef false "fdWaitsIn" ((PCons (PTuple (PVar "ws") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "filter") (EVar "isFdWait")) (EVar "ws")) (EApp (EVar "fdWaitsIn") (EVar "rest"))))
(DTypeSig false "pollerOf" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyApp (TyCon "Option") (TyApp (TyCon "Poller") (TyVar "e")))))
(DFunDef false "pollerOf" ((PList)) (EVar "None"))
(DFunDef false "pollerOf" ((PCons (PCon "WaitRead" PWild (PVar "p")) PWild)) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "pollerOf" ((PCons (PCon "WaitWrite" PWild (PVar "p")) PWild)) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "pollerOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "pollerOf") (EVar "rest")))
(DTypeSig false "pollFd" (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Int")))
(DFunDef false "pollFd" ((PCon "WaitRead" (PVar "fd") PWild)) (EVar "fd"))
(DFunDef false "pollFd" ((PCon "WaitWrite" (PVar "fd") PWild)) (EVar "fd"))
(DFunDef false "pollFd" (PWild) (EUnOp "-" (ELit (LInt 1))))
(DTypeSig false "pollInterest" (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Int")))
(DFunDef false "pollInterest" ((PCon "WaitRead" PWild PWild)) (ELit (LInt 1)))
(DFunDef false "pollInterest" ((PCon "WaitWrite" PWild PWild)) (ELit (LInt 2)))
(DFunDef false "pollInterest" (PWild) (ELit (LInt 0)))
(DTypeSig false "satisfiedWaits" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))))))
(DFunDef false "satisfiedWaits" ((PCons (PVar "w") (PVar "ws")) (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EVar "r") (ELit (LInt 0))) (EApp (EApp (EVar "satisfiedWaits") (EVar "ws")) (EVar "rs")) (EBinOp "::" (EVar "w") (EApp (EApp (EVar "satisfiedWaits") (EVar "ws")) (EVar "rs")))))
(DFunDef false "satisfiedWaits" (PWild PWild) (EListLit))
(DTypeSig false "waitSatisfied" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Wait") (TyVar "e"))) (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "waitSatisfied" ((PVar "sat") (PCon "WaitRead" (PVar "fd") PWild)) (EApp (EApp (EDictApp "any") (ELam ((PVar "w")) (EApp (EApp (EVar "isReadOf") (EVar "fd")) (EVar "w")))) (EVar "sat")))
(DFunDef false "waitSatisfied" ((PVar "sat") (PCon "WaitWrite" (PVar "fd") PWild)) (EApp (EApp (EDictApp "any") (ELam ((PVar "w")) (EApp (EApp (EVar "isWriteOf") (EVar "fd")) (EVar "w")))) (EVar "sat")))
(DFunDef false "waitSatisfied" (PWild PWild) (EVar "False"))
(DTypeSig false "isReadOf" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "isReadOf" ((PVar "fd") (PCon "WaitRead" (PVar "x") PWild)) (EBinOp "==" (EVar "x") (EVar "fd")))
(DFunDef false "isReadOf" (PWild PWild) (EVar "False"))
(DTypeSig false "isWriteOf" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Wait") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "isWriteOf" ((PVar "fd") (PCon "WaitWrite" (PVar "x") PWild)) (EBinOp "==" (EVar "x") (EVar "fd")))
(DFunDef false "isWriteOf" (PWild PWild) (EVar "False"))
