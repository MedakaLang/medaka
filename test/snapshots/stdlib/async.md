# META
source_lines=437
stages=DESUGAR,MARK
# SOURCE
-- async.mdk — Medaka's cooperative-concurrency layer: the `Async` type, its
-- deferred instances, and the two drivers.
--
-- ASYNC-DESIGN.md (archive/design) locked the type and the contract:
-- `Async e a` is a value-level description of deferred work; tasks interleave
-- only at yield boundaries, on one OS thread, with no observable parallelism.
-- Errors ride `Result` inside `Async`; there is no rejected-promise channel and
-- `panic` still aborts the process.  docs/design/ASYNC-RUNTIME-DESIGN.md adds
-- the runtime behind that contract: a single-threaded scheduler with a run
-- queue and a park table, driven by `runAsyncIO`.
--
-- EFFECT POLYMORPHISM.  `Async` is parametric in an effect ROW `e` as well as
-- its value `a`: every stored continuation performs `<e>`, so the type carries
-- exactly the capabilities the deferred work needs, and a driver performs
-- exactly that row.  `runAsync` runs the pure trampoline (`Async e a -> <e> a`);
-- `runAsyncIO` also performs the scheduler's own `<Clock>` (timers) and
-- `<Net "_">` (readiness polling, once the network stage lands).
--
-- Every scheduler queue is ordinary GC-visible Medaka data held in `Ref`s local
-- to one `runAsyncIO` call; the runtime owns no descriptors and no C-side state.

import array.{fromList}
import list.{partition}
import time.{Duration, millis, toMillis}

{- | Cooperative concurrency: build a description of deferred work with
   `defer` blocks, then run it with `runAsync` or `runAsyncIO`.

   `Async e a` is a value: nothing in it runs until a driver forces it. The
   row `e` records the effects the stored work performs. `sleep` parks a
   task until a deadline, `spawn` and `spawnTask` hand a child task to the
   scheduler, `await` waits for a spawned task's value, and `concurrent`
   runs a list of tasks and collects their results in input order.

   `runAsync` runs one task sequentially and cannot wait on a timer; it is
   the driver for pure, deterministic programs and for doctests.
   `runAsyncIO` is the scheduler: it interleaves tasks round-robin at every
   yield, sleeps until the earliest deadline when every task is parked, and
   returns once the program and every task it spawned have finished.
   A `main : Async e Unit` is driven by `runAsyncIO` on the native target
   and by `runAsync` under the WebAssembly target, which has no clock. -}

-- | A deferred computation.  `Done` holds a finished value; the other arms
-- hold the next step under a thunk that performs `<e>`.  `Suspend` is a plain
-- yield point, `Await` parks the task until any of its waits is satisfied, and
-- `Spawn` hands a child task to the scheduler before continuing.
export data Async (e : Effect) a =
  | Done a
  | Suspend (Unit -> <e> Async e a)
  | Await (List Wait) (Unit -> <e> Async e a)
  | Spawn (Async e Unit) (Unit -> <e> Async e a)

-- | What a parked task is waiting on.  A task woken by any one of its waits
-- simply retries, so a spurious wake is harmless.  `WaitRead` and `WaitWrite`
-- name a file descriptor; `WaitUntil` is a monotonic deadline in seconds;
-- `WaitFlag` is set when a spawned task finishes.
public export data Wait =
  | WaitRead Int
  | WaitWrite Int
  | WaitUntil Float
  | WaitFlag (Ref Bool)

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

   Reads the clock, so `<Clock>` joins `e`. Needs `runAsyncIO`. -}
export
sleep : Duration -> Async e Unit
sleep d = Suspend (u => sleepFrom (monotonicSec ()) d)

sleepFrom : Float -> Duration -> Async e Unit
sleepFrom now d =
  let deadline = now + intToFloat (toMillis d) / 1000.0
  Await [WaitUntil deadline] (u => Done ())

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
spawnWith done cell act = Spawn
  (deferThen act (a => Suspend (u => finish done cell a)))
  (u => Done (Task done cell))

finish : Ref Bool -> Ref (Option a) -> a -> Async e Unit
finish done cell a =
  cell := Some a
  done := True
  Done ()

{- | Parks the task until any one of `waits` is satisfied.

   The building block for descriptor waits and deadlines: `net_async` parks
   on `[WaitRead fd]`, or on `[WaitRead fd, deadline]` to give up after a
   `Duration`. A woken task retries, so a spurious wake is harmless. Needs
   `runAsyncIO`. -}
export
awaitAny : List Wait -> Async e Unit
awaitAny waits = Await waits (u => Done ())

{- | A deadline `d` from now, as a wait for `awaitAny`.

   Reads the clock, so `<Clock>` joins `e`. -}
export
deadlineAfter : Duration -> Async e Wait
deadlineAfter d = Suspend (u =>
  Done (WaitUntil (monotonicSec () + intToFloat (toMillis d) / 1000.0)))

{- | Whether a deadline from `deadlineAfter` has passed.

   Any other wait is never expired. Reads the clock. -}
export
expired : Wait -> Async e Bool
expired w = Suspend (u => Done (expiredAt (monotonicSec ()) w))

expiredAt : Float -> Wait -> Bool
expiredAt now (WaitUntil t) = t <= now
expiredAt _ _ = False

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

   Each task is spawned, so they interleave under `runAsyncIO`; the result
   arrives once all of them have finished. -}
export
concurrent : List (Async e a) -> Async e (List a)
concurrent asyncs = deferThen (spawnAll asyncs) (ts => awaitAll ts)

spawnAll : List (Async e a) -> Async e (List (Task a))
spawnAll [] = Done []
spawnAll (a::rest) =
  deferThen (spawnTask a) (t => deferMap (t :: _) (spawnAll rest))

awaitAll : List (Task a) -> Async e (List a)
awaitAll [] = Done []
awaitAll (t::rest) =
  deferThen (await t) (a => deferMap (a :: _) (awaitAll rest))

{- | Runs a task to its value sequentially, performing exactly its row `e`.

   A spawned child runs to completion before its parent continues, so the
   result is deterministic. A task that waits on a timer or a descriptor
   panics: use `runAsyncIO` for those. -}
export
runAsync : Async e a -> <e> a
runAsync prog =
  let cell = Ref None
  let _ = runSeq (deferThen prog (a => Suspend (u => storeResult cell a)))
  match !cell
    Some a => a
    None => panic "async: the program finished without producing a value"

-- The sequential driver over Unit-typed tasks: a task's recursion stays at one
-- type, so a spawned child can be run inline by the same loop.
runSeq : Async e Unit -> <e> Unit
runSeq (Done _) = ()
runSeq (Suspend t) = runSeq (t ())
runSeq (Spawn child k) =
  let _ = runSeq child
  runSeq (k ())
runSeq (Await ws k) =
  if any flagSet ws then
    runSeq (k ())
  else
    panic "async: runAsync cannot wait on a timer or a file descriptor; drive this program with runAsyncIO"

flagSet : Wait -> Bool
flagSet (WaitFlag r) = !r
flagSet _ = False

{- | Runs a task under the scheduler, performing its row `e` plus the
   scheduler's own `<Clock>` and `<Net "_">`.

   Runnable tasks take turns at every yield. When every task is parked, the
   scheduler sleeps until the earliest deadline. It returns the program's
   value once the program and every spawned task have finished, and panics
   if the remaining tasks can never be woken. -}
export
runAsyncIO : Async e a -> <Clock, Net "_" | e> a
runAsyncIO prog =
  let cell = Ref None
  let queue = Ref [deferThen prog (a => Suspend (u => storeResult cell a))]
  let parked = Ref []
  let _ = schedule queue parked
  match !cell
    Some a => a
    None => panic "async: the program finished without producing a value"

{- | `runAsyncIO` for a program whose value is `Unit`.

   A `main : Async e Unit` is driven through this on the native target and
   under `medaka run`. -}
export
runAsyncIOMain : Async e Unit -> <Clock, Net "_" | e> Unit
runAsyncIOMain prog = runAsyncIO prog

{- | `runAsync` for a program whose value is `Unit`.

   A `main : Async e Unit` is driven through this on the WebAssembly target,
   which has no clock. -}
export
runAsyncMain : Async e Unit -> <e> Unit
runAsyncMain prog = runAsync prog

storeResult : Ref (Option a) -> a -> Async e Unit
storeResult cell a =
  cell := Some a
  Done ()

-- One scheduler round: step the head of the run queue, or wake parked tasks
-- when the queue is empty.  Tail-recursive so compiled code loops.
schedule : Ref (List (Async e Unit)) -> Ref (List (List Wait, Unit -> <e> Async e Unit)) -> <Clock, Net "_" | e> Unit
schedule queue parked = match !queue
  t::rest =>
    queue := rest
    let _ = dispatch queue parked (stepTask t)
    schedule queue parked
  [] => match !parked
    [] => ()
    _ =>
      let _ = wakeParked queue parked
      schedule queue parked

stepTask : Async e Unit -> <e> Async e Unit
stepTask (Suspend k) = k ()
stepTask other = other

dispatch : Ref (List (Async e Unit)) -> Ref (List (List Wait, Unit -> <e> Async e Unit)) -> Async e Unit -> Unit
dispatch _ _ (Done _) = ()
dispatch queue _ (Suspend k) = pushBack queue (Suspend k)
dispatch _ parked (Await ws k) = parked := (ws, k) :: !parked
dispatch queue _ (Spawn child k) =
  let _ = pushBack queue child
  pushBack queue (Suspend k)

pushBack : Ref (List (Async e Unit)) -> Async e Unit -> Unit
pushBack queue t = queue := !queue ++ [t]

-- Nothing is runnable: move every task whose wait is satisfied back to the
-- queue, or sleep until the earliest deadline, or report a deadlock.
wakeParked : Ref (List (Async e Unit)) -> Ref (List (List Wait, Unit -> <e> Async e Unit)) -> <Clock, Net "_"> Unit
wakeParked queue parked =
  let now = monotonicSec ()
  let (ready, waiting) = partition (p => isReady now p) !parked
  match ready
    _::_ =>
      parked := waiting
      requeue queue ready
    [] => match fdWaitsOf waiting
      [] => match earliestDeadline waiting
        Some t => sleepMs (millisUntil now t)
        None => panic "async: every remaining task is waiting on a task that can never finish (deadlock)"
      fdWaits =>
        let timeout = match earliestDeadline waiting
          Some t => millisUntil now t
          None => -1
        match ioPoll (fromList (map pollFd fdWaits)) (fromList (map pollInterest fdWaits)) timeout
          Err e => panic ("async: poll failed: " ++ e)
          Ok readiness =>
            let satisfied = satisfiedWaits fdWaits (toList readiness)
            let (woke, still) = partition (p => any (w => waitSatisfied satisfied w) (fst p)) waiting
            parked := still
            requeue queue woke

millisUntil : Float -> Float -> Int
millisUntil now t = max 0 (floatToInt ((t - now) * 1000.0) + 1)

-- Every descriptor wait across the park table, one poll entry each.
fdWaitsOf : List (List Wait, Unit -> <e> Async e Unit) -> List Wait
fdWaitsOf [] = []
fdWaitsOf ((ws, _)::rest) = filter isFdWait ws ++ fdWaitsOf rest

pollFd : Wait -> Int
pollFd (WaitRead fd) = fd
pollFd (WaitWrite fd) = fd
pollFd _ = -1

pollInterest : Wait -> Int
pollInterest (WaitRead _) = 1
pollInterest (WaitWrite _) = 2
pollInterest _ = 0

-- The waits whose parallel readiness word is non-zero.
satisfiedWaits : List Wait -> List Int -> List Wait
satisfiedWaits (w::ws) (r::rs) =
  if r == 0 then
    satisfiedWaits ws rs
  else
    w :: satisfiedWaits ws rs
satisfiedWaits _ _ = []

waitSatisfied : List Wait -> Wait -> Bool
waitSatisfied sat (WaitRead fd) = any (w => isReadOf fd w) sat
waitSatisfied sat (WaitWrite fd) = any (w => isWriteOf fd w) sat
waitSatisfied _ _ = False

isReadOf : Int -> Wait -> Bool
isReadOf fd (WaitRead x) = x == fd
isReadOf _ _ = False

isWriteOf : Int -> Wait -> Bool
isWriteOf fd (WaitWrite x) = x == fd
isWriteOf _ _ = False

requeue : Ref (List (Async e Unit)) -> List (List Wait, Unit -> <e> Async e Unit) -> Unit
requeue _ [] = ()
requeue queue ((_, k)::rest) =
  let _ = pushBack queue (Suspend k)
  requeue queue rest

isReady : Float -> (List Wait, Unit -> <e> Async e Unit) -> Bool
isReady now (ws, _) = any (w => waitReady now w) ws

waitReady : Float -> Wait -> Bool
waitReady now (WaitUntil t) = t <= now
waitReady _ (WaitFlag r) = !r
waitReady _ _ = False

isFdWait : Wait -> Bool
isFdWait (WaitRead _) = True
isFdWait (WaitWrite _) = True
isFdWait _ = False

earliestDeadline : List (List Wait, Unit -> <e> Async e Unit) -> Option Float
earliestDeadline [] = None
earliestDeadline ((ws, _)::rest) =
  minDeadline (deadlinesOf ws) (earliestDeadline rest)

deadlinesOf : List Wait -> Option Float
deadlinesOf [] = None
deadlinesOf ((WaitUntil t)::rest) = minDeadline (Some t) (deadlinesOf rest)
deadlinesOf (_::rest) = deadlinesOf rest

minDeadline : Option Float -> Option Float -> Option Float
minDeadline None b = b
minDeadline a None = a
minDeadline (Some x) (Some y) = Some (min x y)

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

   > runAsyncIO (concurrent [Done 1, Done 2, Done 3])
   [1, 2, 3]

   > runAsyncIO (deferThen (spawnTask (deferThen (sleep (millis 5)) (_ => Done 8))) await)
   8

   > runAsyncIO (deferMap length (concurrent [sleep (millis 5), sleep (millis 5), sleep (millis 5)]))
   3
-}
# DESUGAR
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "partition" false))))
(DUse false (UseGroup ("time") ((mem "Duration" false) (mem "millis" false) (mem "toMillis" false))))
(DData Abstract "Async" ("e" "a") ((variant "Done" (ConPos (TyVar "a"))) (variant "Suspend" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))) (variant "Await" (ConPos (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))) (variant "Spawn" (ConPos (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))))) ())
(DData Public "Wait" () ((variant "WaitRead" (ConPos (TyCon "Int"))) (variant "WaitWrite" (ConPos (TyCon "Int"))) (variant "WaitUntil" (ConPos (TyCon "Float"))) (variant "WaitFlag" (ConPos (TyApp (TyCon "Ref") (TyCon "Bool"))))) ())
(DData Abstract "Task" ("a") ((variant "Task" (ConPos (TyApp (TyCon "Ref") (TyCon "Bool")) (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a")))))) ())
(DImpl true "DeferredMappable" ((TyCon "Async")) () ((im "deferMap" ((PVar "f") (PCon "Done" (PVar "a"))) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "f") (EVar "a")))))) (im "deferMap" ((PVar "f") (PCon "Suspend" (PVar "t"))) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u")))))) (im "deferMap" ((PVar "f") (PCon "Await" (PVar "ws") (PVar "t"))) (EApp (EApp (EVar "Await") (EVar "ws")) (ELam ((PVar "u")) (EApp (EApp (EVar "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u")))))) (im "deferMap" ((PVar "f") (PCon "Spawn" (PVar "c") (PVar "t"))) (EApp (EApp (EVar "Spawn") (EVar "c")) (ELam ((PVar "u")) (EApp (EApp (EVar "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u"))))))))
(DImpl true "DeferredApplicative" ((TyCon "Async")) () ((im "deferPure" ((PVar "a")) (EApp (EVar "Done") (EVar "a"))) (im "deferAp" ((PVar "mf") (PVar "ma")) (EApp (EApp (EVar "deferThen") (EVar "mf")) (ELam ((PVar "f")) (EApp (EApp (EVar "deferMap") (EVar "f")) (EVar "ma")))))))
(DImpl true "DeferredThenable" ((TyCon "Async")) () ((im "deferThen" ((PCon "Done" (PVar "a")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "k") (EVar "a"))))) (im "deferThen" ((PCon "Suspend" (PVar "t")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k"))))) (im "deferThen" ((PCon "Await" (PVar "ws") (PVar "t")) (PVar "k")) (EApp (EApp (EVar "Await") (EVar "ws")) (ELam ((PVar "u")) (EApp (EApp (EVar "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k"))))) (im "deferThen" ((PCon "Spawn" (PVar "c") (PVar "t")) (PVar "k")) (EApp (EApp (EVar "Spawn") (EVar "c")) (ELam ((PVar "u")) (EApp (EApp (EVar "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k")))))))
(DTypeSig true "liftIO" (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "liftIO" ((PVar "act")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "act") (EVar "u"))))))
(DTypeSig true "yield" (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))
(DFunDef false "yield" () (EApp (EVar "Suspend") (ELam (PWild) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "sleep" (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "sleep" ((PVar "d")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "sleepFrom") (EApp (EVar "monotonicSec") (ELit LUnit))) (EVar "d")))))
(DTypeSig false "sleepFrom" (TyFun (TyCon "Float") (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))
(DFunDef false "sleepFrom" ((PVar "now") (PVar "d")) (EBlock (DoLet false false (PVar "deadline") (EBinOp "+" (EVar "now") (EBinOp "/" (EApp (EVar "intToFloat") (EApp (EVar "toMillis") (EVar "d"))) (ELit (LFloat 1000.0))))) (DoExpr (EApp (EApp (EVar "Await") (EListLit (EApp (EVar "WaitUntil") (EVar "deadline")))) (ELam ((PVar "u")) (EApp (EVar "Done") (ELit LUnit)))))))
(DTypeSig true "spawn" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "spawn" ((PVar "child")) (EApp (EApp (EVar "Spawn") (EVar "child")) (ELam ((PVar "u")) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "spawnTask" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "Task") (TyVar "a")))))
(DFunDef false "spawnTask" ((PVar "act")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EApp (EVar "spawnWith") (EApp (EVar "Ref") (EVar "False"))) (EApp (EVar "Ref") (EVar "None"))) (EVar "act")))))
(DTypeSig false "spawnWith" (TyFun (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "Task") (TyVar "a")))))))
(DFunDef false "spawnWith" ((PVar "done") (PVar "cell") (PVar "act")) (EApp (EApp (EVar "Spawn") (EApp (EApp (EVar "deferThen") (EVar "act")) (ELam ((PVar "a")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EApp (EVar "finish") (EVar "done")) (EVar "cell")) (EVar "a"))))))) (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EApp (EVar "Task") (EVar "done")) (EVar "cell"))))))
(DTypeSig false "finish" (TyFun (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))
(DFunDef false "finish" ((PVar "done") (PVar "cell") (PVar "a")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "a")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "done")) (EVar "True"))) (DoExpr (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "awaitAny" (TyFun (TyApp (TyCon "List") (TyCon "Wait")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "awaitAny" ((PVar "waits")) (EApp (EApp (EVar "Await") (EVar "waits")) (ELam ((PVar "u")) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "deadlineAfter" (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Wait"))))
(DFunDef false "deadlineAfter" ((PVar "d")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "WaitUntil") (EBinOp "+" (EApp (EVar "monotonicSec") (ELit LUnit)) (EBinOp "/" (EApp (EVar "intToFloat") (EApp (EVar "toMillis") (EVar "d"))) (ELit (LFloat 1000.0)))))))))
(DTypeSig true "expired" (TyFun (TyCon "Wait") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "expired" ((PVar "w")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EApp (EVar "expiredAt") (EApp (EVar "monotonicSec") (ELit LUnit))) (EVar "w"))))))
(DTypeSig false "expiredAt" (TyFun (TyCon "Float") (TyFun (TyCon "Wait") (TyCon "Bool"))))
(DFunDef false "expiredAt" ((PVar "now") (PCon "WaitUntil" (PVar "t"))) (EBinOp "<=" (EVar "t") (EVar "now")))
(DFunDef false "expiredAt" (PWild PWild) (EVar "False"))
(DTypeSig true "await" (TyFun (TyApp (TyCon "Task") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "await" ((PVar "t")) (EApp (EApp (EVar "Await") (EListLit (EApp (EVar "WaitFlag") (EApp (EVar "taskDone") (EVar "t"))))) (ELam ((PVar "u")) (EApp (EVar "awaitResume") (EVar "t")))))
(DTypeSig false "taskDone" (TyFun (TyApp (TyCon "Task") (TyVar "a")) (TyApp (TyCon "Ref") (TyCon "Bool"))))
(DFunDef false "taskDone" ((PCon "Task" (PVar "done") PWild)) (EVar "done"))
(DTypeSig false "awaitResume" (TyFun (TyApp (TyCon "Task") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "awaitResume" ((PCon "Task" (PVar "done") (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "a")) () (EApp (EVar "Done") (EVar "a"))) (arm (PCon "None") () (EApp (EVar "await") (EApp (EApp (EVar "Task") (EVar "done")) (EVar "cell"))))))
(DTypeSig true "concurrent" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "concurrent" ((PVar "asyncs")) (EApp (EApp (EVar "deferThen") (EApp (EVar "spawnAll") (EVar "asyncs"))) (ELam ((PVar "ts")) (EApp (EVar "awaitAll") (EVar "ts")))))
(DTypeSig false "spawnAll" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Task") (TyVar "a"))))))
(DFunDef false "spawnAll" ((PList)) (EApp (EVar "Done") (EListLit)))
(DFunDef false "spawnAll" ((PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "spawnTask") (EVar "a"))) (ELam ((PVar "t")) (EApp (EApp (EVar "deferMap") (ELam ((PVar "_s")) (EBinOp "::" (EVar "t") (EVar "_s")))) (EApp (EVar "spawnAll") (EVar "rest"))))))
(DTypeSig false "awaitAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Task") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "awaitAll" ((PList)) (EApp (EVar "Done") (EListLit)))
(DFunDef false "awaitAll" ((PCons (PVar "t") (PVar "rest"))) (EApp (EApp (EVar "deferThen") (EApp (EVar "await") (EVar "t"))) (ELam ((PVar "a")) (EApp (EApp (EVar "deferMap") (ELam ((PVar "_s")) (EBinOp "::" (EVar "a") (EVar "_s")))) (EApp (EVar "awaitAll") (EVar "rest"))))))
(DTypeSig true "runAsync" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyEffect () (Some "e") (TyVar "a"))))
(DFunDef false "runAsync" ((PVar "prog")) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false PWild (EApp (EVar "runSeq") (EApp (EApp (EVar "deferThen") (EVar "prog")) (ELam ((PVar "a")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "storeResult") (EVar "cell")) (EVar "a")))))))) (DoExpr (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "async: the program finished without producing a value"))))))))
(DTypeSig false "runSeq" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyEffect () (Some "e") (TyCon "Unit"))))
(DFunDef false "runSeq" ((PCon "Done" PWild)) (ELit LUnit))
(DFunDef false "runSeq" ((PCon "Suspend" (PVar "t"))) (EApp (EVar "runSeq") (EApp (EVar "t") (ELit LUnit))))
(DFunDef false "runSeq" ((PCon "Spawn" (PVar "child") (PVar "k"))) (EBlock (DoLet false false PWild (EApp (EVar "runSeq") (EVar "child"))) (DoExpr (EApp (EVar "runSeq") (EApp (EVar "k") (ELit LUnit))))))
(DFunDef false "runSeq" ((PCon "Await" (PVar "ws") (PVar "k"))) (EIf (EApp (EApp (EVar "any") (EVar "flagSet")) (EVar "ws")) (EApp (EVar "runSeq") (EApp (EVar "k") (ELit LUnit))) (EApp (EVar "panic") (ELit (LString "async: runAsync cannot wait on a timer or a file descriptor; drive this program with runAsyncIO")))))
(DTypeSig false "flagSet" (TyFun (TyCon "Wait") (TyCon "Bool")))
(DFunDef false "flagSet" ((PCon "WaitFlag" (PVar "r"))) (EUnOp "!" (EVar "r")))
(DFunDef false "flagSet" (PWild) (EVar "False"))
(DTypeSig true "runAsyncIO" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyEffect ("Clock" (hole "Net")) (Some "e") (TyVar "a"))))
(DFunDef false "runAsyncIO" ((PVar "prog")) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false (PVar "queue") (EApp (EVar "Ref") (EListLit (EApp (EApp (EVar "deferThen") (EVar "prog")) (ELam ((PVar "a")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "storeResult") (EVar "cell")) (EVar "a"))))))))) (DoLet false false (PVar "parked") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "schedule") (EVar "queue")) (EVar "parked"))) (DoExpr (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "async: the program finished without producing a value"))))))))
(DTypeSig true "runAsyncIOMain" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyEffect ("Clock" (hole "Net")) (Some "e") (TyCon "Unit"))))
(DFunDef false "runAsyncIOMain" ((PVar "prog")) (EApp (EVar "runAsyncIO") (EVar "prog")))
(DTypeSig true "runAsyncMain" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyEffect () (Some "e") (TyCon "Unit"))))
(DFunDef false "runAsyncMain" ((PVar "prog")) (EApp (EVar "runAsync") (EVar "prog")))
(DTypeSig false "storeResult" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))
(DFunDef false "storeResult" ((PVar "cell") (PVar "a")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "a")))) (DoExpr (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig false "schedule" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))) (TyEffect ("Clock" (hole "Net")) (Some "e") (TyCon "Unit")))))
(DFunDef false "schedule" ((PVar "queue") (PVar "parked")) (EMatch (EUnOp "!" (EVar "queue")) (arm (PCons (PVar "t") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "queue")) (EVar "rest"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "dispatch") (EVar "queue")) (EVar "parked")) (EApp (EVar "stepTask") (EVar "t")))) (DoExpr (EApp (EApp (EVar "schedule") (EVar "queue")) (EVar "parked"))))) (arm (PList) () (EMatch (EUnOp "!" (EVar "parked")) (arm (PList) () (ELit LUnit)) (arm PWild () (EBlock (DoLet false false PWild (EApp (EApp (EVar "wakeParked") (EVar "queue")) (EVar "parked"))) (DoExpr (EApp (EApp (EVar "schedule") (EVar "queue")) (EVar "parked")))))))))
(DTypeSig false "stepTask" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))
(DFunDef false "stepTask" ((PCon "Suspend" (PVar "k"))) (EApp (EVar "k") (ELit LUnit)))
(DFunDef false "stepTask" ((PVar "other")) (EVar "other"))
(DTypeSig false "dispatch" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))) (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyCon "Unit")))))
(DFunDef false "dispatch" (PWild PWild (PCon "Done" PWild)) (ELit LUnit))
(DFunDef false "dispatch" ((PVar "queue") PWild (PCon "Suspend" (PVar "k"))) (EApp (EApp (EVar "pushBack") (EVar "queue")) (EApp (EVar "Suspend") (EVar "k"))))
(DFunDef false "dispatch" (PWild (PVar "parked") (PCon "Await" (PVar "ws") (PVar "k"))) (EApp (EApp (EVar "setRef") (EVar "parked")) (EBinOp "::" (ETuple (EVar "ws") (EVar "k")) (EUnOp "!" (EVar "parked")))))
(DFunDef false "dispatch" ((PVar "queue") PWild (PCon "Spawn" (PVar "child") (PVar "k"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "pushBack") (EVar "queue")) (EVar "child"))) (DoExpr (EApp (EApp (EVar "pushBack") (EVar "queue")) (EApp (EVar "Suspend") (EVar "k"))))))
(DTypeSig false "pushBack" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "pushBack" ((PVar "queue") (PVar "t")) (EApp (EApp (EVar "setRef") (EVar "queue")) (EBinOp "++" (EUnOp "!" (EVar "queue")) (EListLit (EVar "t")))))
(DTypeSig false "wakeParked" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))) (TyEffect ("Clock" (hole "Net")) None (TyCon "Unit")))))
(DFunDef false "wakeParked" ((PVar "queue") (PVar "parked")) (EBlock (DoLet false false (PVar "now") (EApp (EVar "monotonicSec") (ELit LUnit))) (DoLet false false (PTuple (PVar "ready") (PVar "waiting")) (EApp (EApp (EVar "partition") (ELam ((PVar "p")) (EApp (EApp (EVar "isReady") (EVar "now")) (EVar "p")))) (EUnOp "!" (EVar "parked")))) (DoExpr (EMatch (EVar "ready") (arm (PCons PWild PWild) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "parked")) (EVar "waiting"))) (DoExpr (EApp (EApp (EVar "requeue") (EVar "queue")) (EVar "ready"))))) (arm (PList) () (EMatch (EApp (EVar "fdWaitsOf") (EVar "waiting")) (arm (PList) () (EMatch (EApp (EVar "earliestDeadline") (EVar "waiting")) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "sleepMs") (EApp (EApp (EVar "millisUntil") (EVar "now")) (EVar "t")))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "async: every remaining task is waiting on a task that can never finish (deadlock)")))))) (arm (PVar "fdWaits") () (EBlock (DoLet false false (PVar "timeout") (EMatch (EApp (EVar "earliestDeadline") (EVar "waiting")) (arm (PCon "Some" (PVar "t")) () (EApp (EApp (EVar "millisUntil") (EVar "now")) (EVar "t"))) (arm (PCon "None") () (EUnOp "-" (ELit (LInt 1)))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "ioPoll") (EApp (EVar "fromList") (EApp (EApp (EVar "map") (EVar "pollFd")) (EVar "fdWaits")))) (EApp (EVar "fromList") (EApp (EApp (EVar "map") (EVar "pollInterest")) (EVar "fdWaits")))) (EVar "timeout")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "async: poll failed: ")) (EVar "e")))) (arm (PCon "Ok" (PVar "readiness")) () (EBlock (DoLet false false (PVar "satisfied") (EApp (EApp (EVar "satisfiedWaits") (EVar "fdWaits")) (EApp (EVar "toList") (EVar "readiness")))) (DoLet false false (PTuple (PVar "woke") (PVar "still")) (EApp (EApp (EVar "partition") (ELam ((PVar "p")) (EApp (EApp (EVar "any") (ELam ((PVar "w")) (EApp (EApp (EVar "waitSatisfied") (EVar "satisfied")) (EVar "w")))) (EApp (EVar "fst") (EVar "p"))))) (EVar "waiting"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "parked")) (EVar "still"))) (DoExpr (EApp (EApp (EVar "requeue") (EVar "queue")) (EVar "woke")))))))))))))))
(DTypeSig false "millisUntil" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Int"))))
(DFunDef false "millisUntil" ((PVar "now") (PVar "t")) (EApp (EApp (EVar "max") (ELit (LInt 0))) (EBinOp "+" (EApp (EVar "floatToInt") (EBinOp "*" (EBinOp "-" (EVar "t") (EVar "now")) (ELit (LFloat 1000.0)))) (ELit (LInt 1)))))
(DTypeSig false "fdWaitsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyApp (TyCon "List") (TyCon "Wait"))))
(DFunDef false "fdWaitsOf" ((PList)) (EListLit))
(DFunDef false "fdWaitsOf" ((PCons (PTuple (PVar "ws") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "filter") (EVar "isFdWait")) (EVar "ws")) (EApp (EVar "fdWaitsOf") (EVar "rest"))))
(DTypeSig false "pollFd" (TyFun (TyCon "Wait") (TyCon "Int")))
(DFunDef false "pollFd" ((PCon "WaitRead" (PVar "fd"))) (EVar "fd"))
(DFunDef false "pollFd" ((PCon "WaitWrite" (PVar "fd"))) (EVar "fd"))
(DFunDef false "pollFd" (PWild) (EUnOp "-" (ELit (LInt 1))))
(DTypeSig false "pollInterest" (TyFun (TyCon "Wait") (TyCon "Int")))
(DFunDef false "pollInterest" ((PCon "WaitRead" PWild)) (ELit (LInt 1)))
(DFunDef false "pollInterest" ((PCon "WaitWrite" PWild)) (ELit (LInt 2)))
(DFunDef false "pollInterest" (PWild) (ELit (LInt 0)))
(DTypeSig false "satisfiedWaits" (TyFun (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Wait")))))
(DFunDef false "satisfiedWaits" ((PCons (PVar "w") (PVar "ws")) (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EVar "r") (ELit (LInt 0))) (EApp (EApp (EVar "satisfiedWaits") (EVar "ws")) (EVar "rs")) (EBinOp "::" (EVar "w") (EApp (EApp (EVar "satisfiedWaits") (EVar "ws")) (EVar "rs")))))
(DFunDef false "satisfiedWaits" (PWild PWild) (EListLit))
(DTypeSig false "waitSatisfied" (TyFun (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Wait") (TyCon "Bool"))))
(DFunDef false "waitSatisfied" ((PVar "sat") (PCon "WaitRead" (PVar "fd"))) (EApp (EApp (EVar "any") (ELam ((PVar "w")) (EApp (EApp (EVar "isReadOf") (EVar "fd")) (EVar "w")))) (EVar "sat")))
(DFunDef false "waitSatisfied" ((PVar "sat") (PCon "WaitWrite" (PVar "fd"))) (EApp (EApp (EVar "any") (ELam ((PVar "w")) (EApp (EApp (EVar "isWriteOf") (EVar "fd")) (EVar "w")))) (EVar "sat")))
(DFunDef false "waitSatisfied" (PWild PWild) (EVar "False"))
(DTypeSig false "isReadOf" (TyFun (TyCon "Int") (TyFun (TyCon "Wait") (TyCon "Bool"))))
(DFunDef false "isReadOf" ((PVar "fd") (PCon "WaitRead" (PVar "x"))) (EBinOp "==" (EVar "x") (EVar "fd")))
(DFunDef false "isReadOf" (PWild PWild) (EVar "False"))
(DTypeSig false "isWriteOf" (TyFun (TyCon "Int") (TyFun (TyCon "Wait") (TyCon "Bool"))))
(DFunDef false "isWriteOf" ((PVar "fd") (PCon "WaitWrite" (PVar "x"))) (EBinOp "==" (EVar "x") (EVar "fd")))
(DFunDef false "isWriteOf" (PWild PWild) (EVar "False"))
(DTypeSig false "requeue" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyCon "Unit"))))
(DFunDef false "requeue" (PWild (PList)) (ELit LUnit))
(DFunDef false "requeue" ((PVar "queue") (PCons (PTuple PWild (PVar "k")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "pushBack") (EVar "queue")) (EApp (EVar "Suspend") (EVar "k")))) (DoExpr (EApp (EApp (EVar "requeue") (EVar "queue")) (EVar "rest")))))
(DTypeSig false "isReady" (TyFun (TyCon "Float") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))) (TyCon "Bool"))))
(DFunDef false "isReady" ((PVar "now") (PTuple (PVar "ws") PWild)) (EApp (EApp (EVar "any") (ELam ((PVar "w")) (EApp (EApp (EVar "waitReady") (EVar "now")) (EVar "w")))) (EVar "ws")))
(DTypeSig false "waitReady" (TyFun (TyCon "Float") (TyFun (TyCon "Wait") (TyCon "Bool"))))
(DFunDef false "waitReady" ((PVar "now") (PCon "WaitUntil" (PVar "t"))) (EBinOp "<=" (EVar "t") (EVar "now")))
(DFunDef false "waitReady" (PWild (PCon "WaitFlag" (PVar "r"))) (EUnOp "!" (EVar "r")))
(DFunDef false "waitReady" (PWild PWild) (EVar "False"))
(DTypeSig false "isFdWait" (TyFun (TyCon "Wait") (TyCon "Bool")))
(DFunDef false "isFdWait" ((PCon "WaitRead" PWild)) (EVar "True"))
(DFunDef false "isFdWait" ((PCon "WaitWrite" PWild)) (EVar "True"))
(DFunDef false "isFdWait" (PWild) (EVar "False"))
(DTypeSig false "earliestDeadline" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "earliestDeadline" ((PList)) (EVar "None"))
(DFunDef false "earliestDeadline" ((PCons (PTuple (PVar "ws") PWild) (PVar "rest"))) (EApp (EApp (EVar "minDeadline") (EApp (EVar "deadlinesOf") (EVar "ws"))) (EApp (EVar "earliestDeadline") (EVar "rest"))))
(DTypeSig false "deadlinesOf" (TyFun (TyApp (TyCon "List") (TyCon "Wait")) (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "deadlinesOf" ((PList)) (EVar "None"))
(DFunDef false "deadlinesOf" ((PCons (PCon "WaitUntil" (PVar "t")) (PVar "rest"))) (EApp (EApp (EVar "minDeadline") (EApp (EVar "Some") (EVar "t"))) (EApp (EVar "deadlinesOf") (EVar "rest"))))
(DFunDef false "deadlinesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "deadlinesOf") (EVar "rest")))
(DTypeSig false "minDeadline" (TyFun (TyApp (TyCon "Option") (TyCon "Float")) (TyFun (TyApp (TyCon "Option") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float")))))
(DFunDef false "minDeadline" ((PCon "None") (PVar "b")) (EVar "b"))
(DFunDef false "minDeadline" ((PVar "a") (PCon "None")) (EVar "a"))
(DFunDef false "minDeadline" ((PCon "Some" (PVar "x")) (PCon "Some" (PVar "y"))) (EApp (EVar "Some") (EApp (EApp (EVar "min") (EVar "x")) (EVar "y"))))
# MARK
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "partition" false))))
(DUse false (UseGroup ("time") ((mem "Duration" false) (mem "millis" false) (mem "toMillis" false))))
(DData Abstract "Async" ("e" "a") ((variant "Done" (ConPos (TyVar "a"))) (variant "Suspend" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))) (variant "Await" (ConPos (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))) (variant "Spawn" (ConPos (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))))) ())
(DData Public "Wait" () ((variant "WaitRead" (ConPos (TyCon "Int"))) (variant "WaitWrite" (ConPos (TyCon "Int"))) (variant "WaitUntil" (ConPos (TyCon "Float"))) (variant "WaitFlag" (ConPos (TyApp (TyCon "Ref") (TyCon "Bool"))))) ())
(DData Abstract "Task" ("a") ((variant "Task" (ConPos (TyApp (TyCon "Ref") (TyCon "Bool")) (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a")))))) ())
(DImpl true "DeferredMappable" ((TyCon "Async")) () ((im "deferMap" ((PVar "f") (PCon "Done" (PVar "a"))) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "f") (EVar "a")))))) (im "deferMap" ((PVar "f") (PCon "Suspend" (PVar "t"))) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u")))))) (im "deferMap" ((PVar "f") (PCon "Await" (PVar "ws") (PVar "t"))) (EApp (EApp (EVar "Await") (EVar "ws")) (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u")))))) (im "deferMap" ((PVar "f") (PCon "Spawn" (PVar "c") (PVar "t"))) (EApp (EApp (EVar "Spawn") (EVar "c")) (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u"))))))))
(DImpl true "DeferredApplicative" ((TyCon "Async")) () ((im "deferPure" ((PVar "a")) (EApp (EVar "Done") (EVar "a"))) (im "deferAp" ((PVar "mf") (PVar "ma")) (EApp (EApp (EMethodRef "deferThen") (EVar "mf")) (ELam ((PVar "f")) (EApp (EApp (EMethodRef "deferMap") (EVar "f")) (EVar "ma")))))))
(DImpl true "DeferredThenable" ((TyCon "Async")) () ((im "deferThen" ((PCon "Done" (PVar "a")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "k") (EVar "a"))))) (im "deferThen" ((PCon "Suspend" (PVar "t")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k"))))) (im "deferThen" ((PCon "Await" (PVar "ws") (PVar "t")) (PVar "k")) (EApp (EApp (EVar "Await") (EVar "ws")) (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k"))))) (im "deferThen" ((PCon "Spawn" (PVar "c") (PVar "t")) (PVar "k")) (EApp (EApp (EVar "Spawn") (EVar "c")) (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k")))))))
(DTypeSig true "liftIO" (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "liftIO" ((PVar "act")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "act") (EVar "u"))))))
(DTypeSig true "yield" (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))
(DFunDef false "yield" () (EApp (EVar "Suspend") (ELam (PWild) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "sleep" (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "sleep" ((PVar "d")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "sleepFrom") (EApp (EVar "monotonicSec") (ELit LUnit))) (EVar "d")))))
(DTypeSig false "sleepFrom" (TyFun (TyCon "Float") (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))
(DFunDef false "sleepFrom" ((PVar "now") (PVar "d")) (EBlock (DoLet false false (PVar "deadline") (EBinOp "+" (EVar "now") (EBinOp "/" (EApp (EVar "intToFloat") (EApp (EVar "toMillis") (EVar "d"))) (ELit (LFloat 1000.0))))) (DoExpr (EApp (EApp (EVar "Await") (EListLit (EApp (EVar "WaitUntil") (EVar "deadline")))) (ELam ((PVar "u")) (EApp (EVar "Done") (ELit LUnit)))))))
(DTypeSig true "spawn" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "spawn" ((PVar "child")) (EApp (EApp (EVar "Spawn") (EVar "child")) (ELam ((PVar "u")) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "spawnTask" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "Task") (TyVar "a")))))
(DFunDef false "spawnTask" ((PVar "act")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EApp (EVar "spawnWith") (EApp (EVar "Ref") (EVar "False"))) (EApp (EVar "Ref") (EVar "None"))) (EVar "act")))))
(DTypeSig false "spawnWith" (TyFun (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "Task") (TyVar "a")))))))
(DFunDef false "spawnWith" ((PVar "done") (PVar "cell") (PVar "act")) (EApp (EApp (EVar "Spawn") (EApp (EApp (EMethodRef "deferThen") (EVar "act")) (ELam ((PVar "a")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EApp (EVar "finish") (EVar "done")) (EVar "cell")) (EVar "a"))))))) (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EApp (EVar "Task") (EVar "done")) (EVar "cell"))))))
(DTypeSig false "finish" (TyFun (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))
(DFunDef false "finish" ((PVar "done") (PVar "cell") (PVar "a")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "a")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "done")) (EVar "True"))) (DoExpr (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "awaitAny" (TyFun (TyApp (TyCon "List") (TyCon "Wait")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "awaitAny" ((PVar "waits")) (EApp (EApp (EVar "Await") (EVar "waits")) (ELam ((PVar "u")) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "deadlineAfter" (TyFun (TyCon "Duration") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Wait"))))
(DFunDef false "deadlineAfter" ((PVar "d")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "WaitUntil") (EBinOp "+" (EApp (EVar "monotonicSec") (ELit LUnit)) (EBinOp "/" (EApp (EVar "intToFloat") (EApp (EVar "toMillis") (EVar "d"))) (ELit (LFloat 1000.0)))))))))
(DTypeSig true "expired" (TyFun (TyCon "Wait") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "expired" ((PVar "w")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EApp (EVar "expiredAt") (EApp (EVar "monotonicSec") (ELit LUnit))) (EVar "w"))))))
(DTypeSig false "expiredAt" (TyFun (TyCon "Float") (TyFun (TyCon "Wait") (TyCon "Bool"))))
(DFunDef false "expiredAt" ((PVar "now") (PCon "WaitUntil" (PVar "t"))) (EBinOp "<=" (EVar "t") (EVar "now")))
(DFunDef false "expiredAt" (PWild PWild) (EVar "False"))
(DTypeSig true "await" (TyFun (TyApp (TyCon "Task") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "await" ((PVar "t")) (EApp (EApp (EVar "Await") (EListLit (EApp (EVar "WaitFlag") (EApp (EVar "taskDone") (EVar "t"))))) (ELam ((PVar "u")) (EApp (EVar "awaitResume") (EVar "t")))))
(DTypeSig false "taskDone" (TyFun (TyApp (TyCon "Task") (TyVar "a")) (TyApp (TyCon "Ref") (TyCon "Bool"))))
(DFunDef false "taskDone" ((PCon "Task" (PVar "done") PWild)) (EVar "done"))
(DTypeSig false "awaitResume" (TyFun (TyApp (TyCon "Task") (TyVar "a")) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "awaitResume" ((PCon "Task" (PVar "done") (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "a")) () (EApp (EVar "Done") (EVar "a"))) (arm (PCon "None") () (EApp (EVar "await") (EApp (EApp (EVar "Task") (EVar "done")) (EVar "cell"))))))
(DTypeSig true "concurrent" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "concurrent" ((PVar "asyncs")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "spawnAll") (EVar "asyncs"))) (ELam ((PVar "ts")) (EApp (EVar "awaitAll") (EVar "ts")))))
(DTypeSig false "spawnAll" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Task") (TyVar "a"))))))
(DFunDef false "spawnAll" ((PList)) (EApp (EVar "Done") (EListLit)))
(DFunDef false "spawnAll" ((PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "spawnTask") (EVar "a"))) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferMap") (ELam ((PVar "_s")) (EBinOp "::" (EVar "t") (EVar "_s")))) (EApp (EVar "spawnAll") (EVar "rest"))))))
(DTypeSig false "awaitAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Task") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "awaitAll" ((PList)) (EApp (EVar "Done") (EListLit)))
(DFunDef false "awaitAll" ((PCons (PVar "t") (PVar "rest"))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "await") (EVar "t"))) (ELam ((PVar "a")) (EApp (EApp (EMethodRef "deferMap") (ELam ((PVar "_s")) (EBinOp "::" (EVar "a") (EVar "_s")))) (EApp (EVar "awaitAll") (EVar "rest"))))))
(DTypeSig true "runAsync" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyEffect () (Some "e") (TyVar "a"))))
(DFunDef false "runAsync" ((PVar "prog")) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false PWild (EApp (EVar "runSeq") (EApp (EApp (EMethodRef "deferThen") (EVar "prog")) (ELam ((PVar "a")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "storeResult") (EVar "cell")) (EVar "a")))))))) (DoExpr (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "async: the program finished without producing a value"))))))))
(DTypeSig false "runSeq" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyEffect () (Some "e") (TyCon "Unit"))))
(DFunDef false "runSeq" ((PCon "Done" PWild)) (ELit LUnit))
(DFunDef false "runSeq" ((PCon "Suspend" (PVar "t"))) (EApp (EVar "runSeq") (EApp (EVar "t") (ELit LUnit))))
(DFunDef false "runSeq" ((PCon "Spawn" (PVar "child") (PVar "k"))) (EBlock (DoLet false false PWild (EApp (EVar "runSeq") (EVar "child"))) (DoExpr (EApp (EVar "runSeq") (EApp (EVar "k") (ELit LUnit))))))
(DFunDef false "runSeq" ((PCon "Await" (PVar "ws") (PVar "k"))) (EIf (EApp (EApp (EDictApp "any") (EVar "flagSet")) (EVar "ws")) (EApp (EVar "runSeq") (EApp (EVar "k") (ELit LUnit))) (EApp (EVar "panic") (ELit (LString "async: runAsync cannot wait on a timer or a file descriptor; drive this program with runAsyncIO")))))
(DTypeSig false "flagSet" (TyFun (TyCon "Wait") (TyCon "Bool")))
(DFunDef false "flagSet" ((PCon "WaitFlag" (PVar "r"))) (EUnOp "!" (EVar "r")))
(DFunDef false "flagSet" (PWild) (EVar "False"))
(DTypeSig true "runAsyncIO" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyEffect ("Clock" (hole "Net")) (Some "e") (TyVar "a"))))
(DFunDef false "runAsyncIO" ((PVar "prog")) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false (PVar "queue") (EApp (EVar "Ref") (EListLit (EApp (EApp (EMethodRef "deferThen") (EVar "prog")) (ELam ((PVar "a")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "storeResult") (EVar "cell")) (EVar "a"))))))))) (DoLet false false (PVar "parked") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "schedule") (EVar "queue")) (EVar "parked"))) (DoExpr (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "async: the program finished without producing a value"))))))))
(DTypeSig true "runAsyncIOMain" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyEffect ("Clock" (hole "Net")) (Some "e") (TyCon "Unit"))))
(DFunDef false "runAsyncIOMain" ((PVar "prog")) (EApp (EVar "runAsyncIO") (EVar "prog")))
(DTypeSig true "runAsyncMain" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyEffect () (Some "e") (TyCon "Unit"))))
(DFunDef false "runAsyncMain" ((PVar "prog")) (EApp (EVar "runAsync") (EVar "prog")))
(DTypeSig false "storeResult" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))
(DFunDef false "storeResult" ((PVar "cell") (PVar "a")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "a")))) (DoExpr (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig false "schedule" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))) (TyEffect ("Clock" (hole "Net")) (Some "e") (TyCon "Unit")))))
(DFunDef false "schedule" ((PVar "queue") (PVar "parked")) (EMatch (EUnOp "!" (EVar "queue")) (arm (PCons (PVar "t") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "queue")) (EVar "rest"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "dispatch") (EVar "queue")) (EVar "parked")) (EApp (EVar "stepTask") (EVar "t")))) (DoExpr (EApp (EApp (EVar "schedule") (EVar "queue")) (EVar "parked"))))) (arm (PList) () (EMatch (EUnOp "!" (EVar "parked")) (arm (PList) () (ELit LUnit)) (arm PWild () (EBlock (DoLet false false PWild (EApp (EApp (EVar "wakeParked") (EVar "queue")) (EVar "parked"))) (DoExpr (EApp (EApp (EVar "schedule") (EVar "queue")) (EVar "parked")))))))))
(DTypeSig false "stepTask" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))
(DFunDef false "stepTask" ((PCon "Suspend" (PVar "k"))) (EApp (EVar "k") (ELit LUnit)))
(DFunDef false "stepTask" ((PVar "other")) (EVar "other"))
(DTypeSig false "dispatch" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))) (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyCon "Unit")))))
(DFunDef false "dispatch" (PWild PWild (PCon "Done" PWild)) (ELit LUnit))
(DFunDef false "dispatch" ((PVar "queue") PWild (PCon "Suspend" (PVar "k"))) (EApp (EApp (EVar "pushBack") (EVar "queue")) (EApp (EVar "Suspend") (EVar "k"))))
(DFunDef false "dispatch" (PWild (PVar "parked") (PCon "Await" (PVar "ws") (PVar "k"))) (EApp (EApp (EVar "setRef") (EVar "parked")) (EBinOp "::" (ETuple (EVar "ws") (EVar "k")) (EUnOp "!" (EVar "parked")))))
(DFunDef false "dispatch" ((PVar "queue") PWild (PCon "Spawn" (PVar "child") (PVar "k"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "pushBack") (EVar "queue")) (EVar "child"))) (DoExpr (EApp (EApp (EVar "pushBack") (EVar "queue")) (EApp (EVar "Suspend") (EVar "k"))))))
(DTypeSig false "pushBack" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "pushBack" ((PVar "queue") (PVar "t")) (EApp (EApp (EVar "setRef") (EVar "queue")) (EBinOp "++" (EUnOp "!" (EVar "queue")) (EListLit (EVar "t")))))
(DTypeSig false "wakeParked" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))))) (TyEffect ("Clock" (hole "Net")) None (TyCon "Unit")))))
(DFunDef false "wakeParked" ((PVar "queue") (PVar "parked")) (EBlock (DoLet false false (PVar "now") (EApp (EVar "monotonicSec") (ELit LUnit))) (DoLet false false (PTuple (PVar "ready") (PVar "waiting")) (EApp (EApp (EVar "partition") (ELam ((PVar "p")) (EApp (EApp (EVar "isReady") (EVar "now")) (EVar "p")))) (EUnOp "!" (EVar "parked")))) (DoExpr (EMatch (EVar "ready") (arm (PCons PWild PWild) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "parked")) (EVar "waiting"))) (DoExpr (EApp (EApp (EVar "requeue") (EVar "queue")) (EVar "ready"))))) (arm (PList) () (EMatch (EApp (EVar "fdWaitsOf") (EVar "waiting")) (arm (PList) () (EMatch (EApp (EVar "earliestDeadline") (EVar "waiting")) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "sleepMs") (EApp (EApp (EVar "millisUntil") (EVar "now")) (EVar "t")))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "async: every remaining task is waiting on a task that can never finish (deadlock)")))))) (arm (PVar "fdWaits") () (EBlock (DoLet false false (PVar "timeout") (EMatch (EApp (EVar "earliestDeadline") (EVar "waiting")) (arm (PCon "Some" (PVar "t")) () (EApp (EApp (EVar "millisUntil") (EVar "now")) (EVar "t"))) (arm (PCon "None") () (EUnOp "-" (ELit (LInt 1)))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "ioPoll") (EApp (EVar "fromList") (EApp (EApp (EMethodRef "map") (EVar "pollFd")) (EVar "fdWaits")))) (EApp (EVar "fromList") (EApp (EApp (EMethodRef "map") (EVar "pollInterest")) (EVar "fdWaits")))) (EVar "timeout")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "async: poll failed: ")) (EVar "e")))) (arm (PCon "Ok" (PVar "readiness")) () (EBlock (DoLet false false (PVar "satisfied") (EApp (EApp (EVar "satisfiedWaits") (EVar "fdWaits")) (EApp (EMethodRef "toList") (EVar "readiness")))) (DoLet false false (PTuple (PVar "woke") (PVar "still")) (EApp (EApp (EVar "partition") (ELam ((PVar "p")) (EApp (EApp (EDictApp "any") (ELam ((PVar "w")) (EApp (EApp (EVar "waitSatisfied") (EVar "satisfied")) (EVar "w")))) (EApp (EVar "fst") (EVar "p"))))) (EVar "waiting"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "parked")) (EVar "still"))) (DoExpr (EApp (EApp (EVar "requeue") (EVar "queue")) (EVar "woke")))))))))))))))
(DTypeSig false "millisUntil" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Int"))))
(DFunDef false "millisUntil" ((PVar "now") (PVar "t")) (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EBinOp "+" (EApp (EVar "floatToInt") (EBinOp "*" (EBinOp "-" (EVar "t") (EVar "now")) (ELit (LFloat 1000.0)))) (ELit (LInt 1)))))
(DTypeSig false "fdWaitsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyApp (TyCon "List") (TyCon "Wait"))))
(DFunDef false "fdWaitsOf" ((PList)) (EListLit))
(DFunDef false "fdWaitsOf" ((PCons (PTuple (PVar "ws") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "filter") (EVar "isFdWait")) (EVar "ws")) (EApp (EVar "fdWaitsOf") (EVar "rest"))))
(DTypeSig false "pollFd" (TyFun (TyCon "Wait") (TyCon "Int")))
(DFunDef false "pollFd" ((PCon "WaitRead" (PVar "fd"))) (EVar "fd"))
(DFunDef false "pollFd" ((PCon "WaitWrite" (PVar "fd"))) (EVar "fd"))
(DFunDef false "pollFd" (PWild) (EUnOp "-" (ELit (LInt 1))))
(DTypeSig false "pollInterest" (TyFun (TyCon "Wait") (TyCon "Int")))
(DFunDef false "pollInterest" ((PCon "WaitRead" PWild)) (ELit (LInt 1)))
(DFunDef false "pollInterest" ((PCon "WaitWrite" PWild)) (ELit (LInt 2)))
(DFunDef false "pollInterest" (PWild) (ELit (LInt 0)))
(DTypeSig false "satisfiedWaits" (TyFun (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Wait")))))
(DFunDef false "satisfiedWaits" ((PCons (PVar "w") (PVar "ws")) (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EVar "r") (ELit (LInt 0))) (EApp (EApp (EVar "satisfiedWaits") (EVar "ws")) (EVar "rs")) (EBinOp "::" (EVar "w") (EApp (EApp (EVar "satisfiedWaits") (EVar "ws")) (EVar "rs")))))
(DFunDef false "satisfiedWaits" (PWild PWild) (EListLit))
(DTypeSig false "waitSatisfied" (TyFun (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Wait") (TyCon "Bool"))))
(DFunDef false "waitSatisfied" ((PVar "sat") (PCon "WaitRead" (PVar "fd"))) (EApp (EApp (EDictApp "any") (ELam ((PVar "w")) (EApp (EApp (EVar "isReadOf") (EVar "fd")) (EVar "w")))) (EVar "sat")))
(DFunDef false "waitSatisfied" ((PVar "sat") (PCon "WaitWrite" (PVar "fd"))) (EApp (EApp (EDictApp "any") (ELam ((PVar "w")) (EApp (EApp (EVar "isWriteOf") (EVar "fd")) (EVar "w")))) (EVar "sat")))
(DFunDef false "waitSatisfied" (PWild PWild) (EVar "False"))
(DTypeSig false "isReadOf" (TyFun (TyCon "Int") (TyFun (TyCon "Wait") (TyCon "Bool"))))
(DFunDef false "isReadOf" ((PVar "fd") (PCon "WaitRead" (PVar "x"))) (EBinOp "==" (EVar "x") (EVar "fd")))
(DFunDef false "isReadOf" (PWild PWild) (EVar "False"))
(DTypeSig false "isWriteOf" (TyFun (TyCon "Int") (TyFun (TyCon "Wait") (TyCon "Bool"))))
(DFunDef false "isWriteOf" ((PVar "fd") (PCon "WaitWrite" (PVar "x"))) (EBinOp "==" (EVar "x") (EVar "fd")))
(DFunDef false "isWriteOf" (PWild PWild) (EVar "False"))
(DTypeSig false "requeue" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyCon "Unit"))))
(DFunDef false "requeue" (PWild (PList)) (ELit LUnit))
(DFunDef false "requeue" ((PVar "queue") (PCons (PTuple PWild (PVar "k")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "pushBack") (EVar "queue")) (EApp (EVar "Suspend") (EVar "k")))) (DoExpr (EApp (EApp (EVar "requeue") (EVar "queue")) (EVar "rest")))))
(DTypeSig false "isReady" (TyFun (TyCon "Float") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit"))))) (TyCon "Bool"))))
(DFunDef false "isReady" ((PVar "now") (PTuple (PVar "ws") PWild)) (EApp (EApp (EDictApp "any") (ELam ((PVar "w")) (EApp (EApp (EVar "waitReady") (EVar "now")) (EVar "w")))) (EVar "ws")))
(DTypeSig false "waitReady" (TyFun (TyCon "Float") (TyFun (TyCon "Wait") (TyCon "Bool"))))
(DFunDef false "waitReady" ((PVar "now") (PCon "WaitUntil" (PVar "t"))) (EBinOp "<=" (EVar "t") (EVar "now")))
(DFunDef false "waitReady" (PWild (PCon "WaitFlag" (PVar "r"))) (EUnOp "!" (EVar "r")))
(DFunDef false "waitReady" (PWild PWild) (EVar "False"))
(DTypeSig false "isFdWait" (TyFun (TyCon "Wait") (TyCon "Bool")))
(DFunDef false "isFdWait" ((PCon "WaitRead" PWild)) (EVar "True"))
(DFunDef false "isFdWait" ((PCon "WaitWrite" PWild)) (EVar "True"))
(DFunDef false "isFdWait" (PWild) (EVar "False"))
(DTypeSig false "earliestDeadline" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Wait")) (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))))) (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "earliestDeadline" ((PList)) (EVar "None"))
(DFunDef false "earliestDeadline" ((PCons (PTuple (PVar "ws") PWild) (PVar "rest"))) (EApp (EApp (EVar "minDeadline") (EApp (EVar "deadlinesOf") (EVar "ws"))) (EApp (EVar "earliestDeadline") (EVar "rest"))))
(DTypeSig false "deadlinesOf" (TyFun (TyApp (TyCon "List") (TyCon "Wait")) (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "deadlinesOf" ((PList)) (EVar "None"))
(DFunDef false "deadlinesOf" ((PCons (PCon "WaitUntil" (PVar "t")) (PVar "rest"))) (EApp (EApp (EVar "minDeadline") (EApp (EVar "Some") (EVar "t"))) (EApp (EVar "deadlinesOf") (EVar "rest"))))
(DFunDef false "deadlinesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "deadlinesOf") (EVar "rest")))
(DTypeSig false "minDeadline" (TyFun (TyApp (TyCon "Option") (TyCon "Float")) (TyFun (TyApp (TyCon "Option") (TyCon "Float")) (TyApp (TyCon "Option") (TyCon "Float")))))
(DFunDef false "minDeadline" ((PCon "None") (PVar "b")) (EVar "b"))
(DFunDef false "minDeadline" ((PVar "a") (PCon "None")) (EVar "a"))
(DFunDef false "minDeadline" ((PCon "Some" (PVar "x")) (PCon "Some" (PVar "y"))) (EApp (EVar "Some") (EApp (EApp (EMethodRef "min") (EVar "x")) (EVar "y"))))
