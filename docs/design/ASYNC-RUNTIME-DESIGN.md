# Async runtime v2 — the ASYNC-DESIGN §5 swap

**Status:** IMPLEMENTED 2026-09-02 (design locked 2026-07-16, amended §0a) — all four stages landed; the staging table marks each; implementation was staged as
tracking issue #500 (stages #496 A1 · #497 A2 · #498 A3 · #499 A4). Nothing below
is built yet; per-stage DONE markers land here as stages merge. Companion to
[`archive/design/ASYNC-DESIGN.md`](../../archive/design/ASYNC-DESIGN.md) (v1, IMPLEMENTED),
whose §0 decisions D1–D8 remain authoritative and are *inherited*, not reopened, here.

---

## 0. Locked decisions

| # | Decision | Rationale |
|---|---|---|
| **R1** | Runtime implementation language: **C**, extending `runtime/medaka_rt.c`. Reaffirms the 2026-06-16 decision. | What the runtime needs from native code is ~150–250 lines of syscall glue added to an existing 2,100-line C file; the scheduler *logic* stays pure Medaka (§4.3). Rust is wall-to-wall `unsafe` at the tagged-i64/Boehm boundary (the borrow checker buys nothing there); tokio-style runtimes both duplicate the scheduler Medaka owns in-language and keep task memory Boehm can't scan (use-after-collect). Revisit only if Medaka wants a real external library (TLS, HTTP) — crates beat hand-rolled C there. |
| **R2** | Model adoption: **OCaml Lwt for semantics, libuv/Node for architecture.** | Lwt is the existence proof that monadic promises + bind-as-yield-point + single-thread cooperative scales to real systems (MirageOS) — and it is what v1 already shipped. libuv is the decades-proven architecture for exactly our contract: one event-loop thread, readiness reactor, timer heap driving the poll timeout, blocking-only ops eventually offloaded to a pool. Rejected: **Go** (M:N parallel goroutines violate the locked D3 no-parallelism contract; preemption needs deep codegen support), **Tokio** (work-stealing multithread — same D3 violation, plus R1's GC conflict), **Erlang/BEAM** (preemptive process isolation is a different language's soul), **Python asyncio** (right model, but its exposed-event-loop API is the cautionary tale — Medaka's loop stays invisible behind the drivers). A bonus of the choice: the JS event loop is the same shape, so the WasmGC backend's eventual async story maps onto the host loop instead of fighting it (§6.5). |
| **R3** | Readiness syscall: **`poll(2)` only** in v2, wrapped by one extern. | POSIX — ONE code path satisfies the dual-platform (Linux + macOS) invariant; O(n) scan is irrelevant below ~1k fds. epoll/kqueue becomes a drop-in optimization behind the same extern later, zero API change (§6.4). |
| **R4** | v2 scope: **I/O overlap only.** `sleep`, `awaitReadable`/`awaitWritable`, async accept/recv/send, the real scheduler. **No `spawn`/`Task`, no cancellation — and therefore no `race`/`timeout`.** DNS (`getaddrinfo`), file I/O, and `netTcpConnect` (which resolves internally) stay blocking, documented. | Race without cancellation silently leaks the loser — exactly the trap D8's structured-first stance exists to prevent. Cancellation is the hardest open semantic question (fd/effect lifecycle of a dropped task) and must not block the overlap payoff; §6.1 names its seam. Blocking DNS/file matches libuv's own history (thread pool came later) — §6.3. |
| **R5** | Engine posture: **native-first, with capability-matrix ledger rows.** | The interpreter implements zero net externs today (the T7 family in `test/CAPABILITY-EXCEPTIONS.txt`); wasm rejects net as PERMANENT (`wasm_emit.mdk` gapL). The five new externs join those families with explicit rows — stated, never silent (G9). The A1 scheduler + `sleep` are pure Medaka over existing externs and work on **all three engines**. |
| **R6** | Effect-row honesty: **two drivers.** `runAsync : Async e a -> <e> a` stays exactly the v1 pure trampoline; new `runAsyncIO : Async e a -> <e, Clock, Net _> a` engages the scheduler; the `main : Async _` driver dispatch switches to `runAsyncIO`. | The scheduler statically performs `<Clock>` (timer sleep) and `<Net _>` (`ioPoll`) even when a given program never parks — widening `runAsync` itself would tax every pure async program's manifest with capabilities it never exercises. Driver-level application is not user source, so `main : Async` programs' manifests don't widen either. `runAsync` hitting an `Await` panics with a message naming `runAsyncIO` (§4.4). |

Inherited and **not reopened** (v1 D1–D8): value-level monad; no `<Async>` effect;
cooperative contract — interleave-at-yield, single thread, no observable parallelism;
errors ride `Result`, no rejection channel, `panic` aborts the process; `main : Async`
entrypoint; structured concurrency first.

---

## 0a. Amendments (ruled 2026-09-02, recorded on #500)

Re-derived after the graded-interfaces work (`Deferred*` family, `defer` blocks,
declared kinds). R1–R6 and G1–G9 stand. Four scope amendments make the result
usable for a real program (a TCP server), which the overlap-only scope could not
express: an accept loop cannot be written with `concurrent` (it waits for every
child), and a non-blocking socket ignores the `SO_RCVTIMEO` timeout the blocking
API relied on.

| # | Amendment | Replaces |
|---|---|---|
| **M1** | `Await` takes a **list** of waits (`Await (List Wait) k`), woken by any one. A deadline is the wait set `[WaitRead fd, WaitUntil t]`; the task itself decides what to do when the timer fires, so nothing is ever dropped. | §4.1's single `Wait` |
| **M2** | A `Spawn (Async e Unit) k` arm with `spawn`, `spawnTask : Async e a -> Async e (Task a)`, and `await`. `Task a` is two `Ref`s the child fills; `await` parks on `WaitFlag`. The driver returns only when every spawned task has finished (structured: the root is the scope). A program whose remaining tasks can never be woken panics rather than hangs. `concurrent` is built on spawn, so nested fan-out is free and every child is scheduled independently (G7). | R4's "no spawn/Task", D8's deferral |
| **M3** | Per-operation deadlines on the net surface (`recvWithin`, `sendAllWithin`: `Err` on expiry, the shape the blocking `setTimeout` produced). **General cancellation, `race`, and `timeout` of an arbitrary task stay out**: dropping a parked task needs a cleanup story (the language has no catchable exit) and gets its own design. | R4, unchanged in spirit |
| **M4** | `main : Async _` dispatch goes through the driver on **every** engine (#2506: `medaka build` used to force the inert value and print a heap pointer). The rewrite is `main_autoprint.asyncWrapModules`: the `async` module's driver is pinned under an unspellable name and imported into the entry module. Native and the interpreter apply `runAsyncIO`; the WasmGC target, which has no clock host-imports, applies the sequential `runAsync`. | §4.4's interpreter-only dispatch |

Also: `sleep` takes a `Duration` (`time.mdk`), matching `net.setTimeout`;
`concurrent : List (Async e a) -> Async e (List a)` has a pure arrow; the async net
surface lives in a sibling stdlib module named `net_async` (A3) over `net.mdk`'s handles, whose
constructors become `public export` (handles stay mutually unconfusable, become
forgeable from an `Int` — accepted).

Two facts the implementation learned, worth knowing before writing against the type:
an effect row written as a type ARGUMENT is invariant (#1094), so a `defer` block's
statements must share one index — write the labels (`Async <Clock, Stdout> Unit`), not
the `IO` alias, and prefer `putStrLn (display x)` (`<Stdout>`) over `println` (`<IO>`)
inside `liftIO`; and a NAMED pure function passed as a `deferThen` continuation closes
the index to `<>` (its arrow row is `<>`), so pass a lambda (`ts => awaitAll ts`).

Delivery: two PRs on one branch — S1 (A1 + M2 + M4, all-engine, compiler driver
touched), then A2 + A3 + A4 together.

## 1. The gap this closes

v1 (`stdlib/async.mdk`) delivered the type, the laws, the `do` DX, `concurrent`, and
`main : Async _` dispatch — and deliberately deferred "the swap" (v1 §5). Today every
I/O extern **blocks**, so `concurrent [fetchA, fetchB]` interleaves *semantically* but
gains zero wall-clock overlap, and a server can't service two connections at once. The
runtime designed here makes yield points *real*: a task parks on an fd or a deadline,
someone else runs meanwhile, one OS thread throughout.

The entire v1 contract is preserved by construction — that was the point of committing
to the cooperative *contract* while shipping the degenerate scheduler (v1 D3). The swap
changes wall-clock, never observable behavior (G1).

Facts of the ground the design leans on: Boehm already runs `GC_THREADS` with the
program on a `GC_pthread_create`'d worker thread; a complete *blocking* BSD-socket
extern family already exists (`netTcpConnect`/`netSend`/`netRecv`/`netTcpAccept`/…),
plus `sleepMs`/`monotonicSec`; and nothing outside `stdlib/async.mdk` matches on the
`Async` constructors yet, so the ADT is still cheap to extend — which stops being true
at 0.1.0.

---

## 2. What we're building (one paragraph)

A **single-threaded readiness reactor**: the scheduler (pure Medaka) keeps a run queue,
a timer heap, and an fd park table. It runs runnable tasks round-robin; when every task
is parked or done, it makes **one** `ioPoll` call over all parked fds with the earliest
timer deadline as the timeout; readied and expired tasks rejoin the queue. C contributes
exactly the syscalls Medaka cannot make: `poll(2)`, `O_NONBLOCK`, and would-block-aware
accept/recv/send variants. No second thread, no locks, no C-side state.

---

## 3. Guarantees

The contract the runtime must satisfy, numbered so gates and reviews can cite them:

- **G1 — Contract preservation.** Any v1 program behaves identically: interleaving only
  at `Suspend`/`Await` boundaries; all Medaka code executes on exactly one OS thread, so
  `Ref`s stay race-free with no locks; the swap changes wall-clock, never the observable
  order of a compute-only program. **Existing goldens must not move.**
- **G2 — Determinism where promised.** Compute-only scheduling is deterministic
  round-robin, v1-identical. I/O *completion order* is explicitly outside the contract —
  no gate may golden it. `concurrent` collects results **in input order** regardless of
  completion order (that part *is* contractual and golden-able).
- **G3 — Errors.** Result-canonical; no rejected-promise channel; `panic` in any task
  aborts the whole process (v1 D4, unchanged).
- **G4 — Structured concurrency.** `concurrent` returns only when every child is
  resolved; no task outlives its scope; the runtime itself owns no fds and orphans none
  (fds are user values; the runtime only ever *waits* on them).
- **G5 — GC safety.** All runtime state (queues, park table, timer heap, buffers) is
  ordinary GC-visible Medaka data. Any future helper thread is created via
  `GC_pthread_create`. No Boehm-invisible ownership, ever.
- **G6 — No busy-wait.** When nothing is runnable, the loop blocks in `poll` with the
  exact next-deadline timeout (or infinite if no timers). An idle async program consumes
  ~0 CPU.
- **G7 — Fairness.** A runnable task runs within one round; readied-I/O tasks rejoin the
  same round-robin queue as compute tasks — no priority lane, no starvation in either
  direction.
- **G8 — Stack safety.** The scheduler loop is tail-recursive; compiled `-O2` TCOs it
  (already validated for v1's `runAsync`). The `medaka run` interpreter's ~100–500k depth
  cap is inherited and unchanged.
- **G9 — Engine honesty.** Every new extern lands as the full multi-surface change or
  gets an explicit capability-matrix ledger row. "Async I/O is native-first" is *stated*
  (docs + ledger), never discovered.

---

## 4. Architecture

### 4.1 The type — one new arm

```
export data Async e a
  = Done a
  | Suspend (Unit -> <e> Async e a)          -- v1: a yield point
  | Await Wait (Unit -> <e> Async e a)       -- v2: a PARKED yield point

data Wait
  = WaitRead Int      -- park until fd readable
  | WaitWrite Int     -- park until fd writable
  | WaitUntil Float   -- park until monotonic deadline (seconds)
```

`Await` is the entire scheduler seam: it lets a task state *what* it is waiting on
without being run. The continuation takes `Unit` (not readiness data) because readiness
is level-triggered — the wake action is simply "retry the syscall", which makes spurious
wakeups harmless by construction. `WaitRead`/`WaitWrite` land in A1 with no producers
until A3 — one ADT change, staged producers. Doing this now is free (zero external
matchers); after 0.1.0 it is a breaking change to a public type.

`map`/`andThen` treat `Await` exactly as `Suspend` with the reason threaded through
(`andThen (Await w t) k = Await w (u => andThen (t u) k)`) — the monad laws are
untouched.

### 4.2 The C surface (all of it)

New externs — decl in `stdlib/runtime.mdk`, impl in `runtime/medaka_rt.c`, wiring in
`compiler/backend/llvm_emit.mdk`; interpreter arms deliberately skipped per R5:

```
extern ioPoll         : List (Int, Int) -> Int -> <Net _> Result String (List (Int, Int))
  -- (fd, interest) pairs, timeout-ms (-1 = infinite) -> readied (fd, revents). poll(2).
extern netSetNonblock : Int -> Bool -> <Net _> Result String Unit    -- fcntl O_NONBLOCK
extern netTryAccept   : Int -> <Net _> Result String (Option Int)
extern netTryRecv     : Int -> Int -> <Net _> Result String (Option (Array Int))
extern netTrySend     : Int -> Array Int -> <Net _> Result String (Option Int)
```

Conventions: `None` = would-block (`EAGAIN`/`EWOULDBLOCK`, and `EINPROGRESS` where
relevant); `Some` = the same payload the blocking sibling returns (so `netTryRecv`'s
`Some []` = EOF, matching `netRecv`); `Err` = real errno text. Encoding would-block as
`Result String (Option a)` needs **no new ADT and no new C-side constructor knowledge**
— the shims already build `Result`/`Option`. All returned buffers are GC-allocated as
today (G5). Timers need **zero C**: the scheduler computes deadlines with the existing
`monotonicSec` and passes the earliest as `ioPoll`'s timeout (or `sleepMs` when only
timers are parked — the A1 stage runs with no new externs at all).

`netTcpConnect` stays blocking in v2: it performs `getaddrinfo` internally, which blocks
anyway under R4's DNS cut. Async connect (the nonblocking-connect →
poll-writable → `SO_ERROR` dance) arrives together with the blocking-op pool (§6.3).

### 4.3 The scheduler (pure Medaka, `stdlib/async.mdk`)

State: a run queue (tasks that can step now), a timer heap (parked `WaitUntil`, ordered
by deadline — a sorted list is fine at v2 task counts; don't drag `import map` into
every async user program), and a park table (fd → parked task, with interest).

```
loop:
  while runQueue nonempty:
    pop task, force one step
      Done v      -> record result
      Suspend t   -> requeue at tail            (round-robin — G7)
      Await w t   -> park in table/heap by w
  if everything Done -> collect in input order (G2), return
  timeout := earliest timer deadline - now      (infinite if none — G6)
  readied := ioPoll (parked fds) timeout        (or sleepMs when fd-table empty)
  move readied + expired tasks back to runQueue
  goto loop
```

`concurrent` becomes "enqueue N children into this loop"; its public contract (input-
order collection, return-when-all-done) is unchanged. The v1 doctests must pass
byte-identically (G1) — for compute-only programs this loop *is* v1 round-robin.

### 4.4 The drivers (R6)

```
runAsync   : Async e a -> <e> a                 -- v1, unchanged: pure trampoline.
                                                -- Await -> panic naming runAsyncIO.
runAsyncIO : Async e a -> <e, Clock, Net _> a   -- the scheduler loop above
```

Why two: the scheduler *statically* performs `<Clock>`/`<Net _>` even for programs that
never park; folding that into `runAsync` would widen every pure async program's manifest.
The `main : Async _` dispatch (`evalModulesOutputAsync` / the CLI run arm) drives through
`runAsyncIO` — the driver's application is not user source, so user manifests still
reflect only what the *program* does. The `runAsync (sleep 5)` failure mode (typechecks —
`Clock` rides `e` — then panics at the `Await`) is accepted and documented; the panic
message names the fix. ⚠️ Validate the `runAsyncIO` row typing on the binary at A1 before
building on it — the v1 rule stands: decide empirically, not on paper.

### 4.5 The user surface (A1 + A3)

```
sleep         : Int -> Async e Unit                              -- ms; <Clock> in e
awaitReadable : Int -> Async e Unit                              -- <Net _> in e
awaitWritable : Int -> Async e Unit
asyncAccept   : Int -> Async e (Result String Int)
asyncRecv     : Int -> Int -> Async e (Result String (Array Int))
asyncSend     : Int -> Array Int -> Async e (Result String Int)  -- full-buffer loop
```

Each net wrapper: `netSetNonblock`, try the syscall; `None` → `Await (WaitRead/WaitWrite
fd)` → retry on wake. Existing blocking externs are untouched — `liftIO readFile` still
works; it just doesn't overlap, and the docs say so (R4/G9).

---

## 5. What v2 must NOT preclude (and where each seam is)

1. **Cancellation** (§6.1 of nothing — *the* deferred question). The `Await` arm already
   makes a parked task a first-class value the scheduler holds; cancel = drop it from
   table/heap and never resume. What blocks shipping that is *semantics*, not mechanism:
   a dropped task's open fds and half-done effects need a finalizer/`bracket` story,
   which Medaka does not have and which deserves its own design doc. Nothing in v2 makes
   that harder; the park table is exactly the registry a canceller needs.
2. **`race`/`timeout`** — trivially expressible once cancellation exists (`race` =
   park both, first `Done` cancels the other). Deliberately absent until then (R4).
3. **`spawn`/`Task` handles** — v1 D8's deferral stands; the run queue is the substrate.
4. **epoll/kqueue** — swap inside the `ioPoll` shim when fd counts justify two platform
   arms; the extern signature already speaks readiness-sets, so the API is unchanged.
5. **Blocking-op pool** (DNS, file I/O, async connect) — libuv's own answer: a small
   `GC_pthread_create`'d pool running *C shims only*, completing back to the loop via a
   self-pipe/eventfd the reactor already knows how to wait on. G5 is preserved because
   pool threads are GC-registered and results are GC-allocated before handoff.
6. **WasmGC / playground async** — the scheduler is pure Medaka, so A1 (`sleep`, compute
   concurrency) already runs wherever `sleepMs`/`monotonicSec` do. Real browser async
   (fetch) is a separate design that maps `Await` pumping onto the JS event loop
   (microtask per step) instead of `ioPoll` — same shape (R2), different reactor; net
   externs stay PERMANENT-gapped on wasm regardless.

---

## 6. Staging (tracking #500)

| Stage | Issue | Content | New C | Engines | Key gate |
|---|---|---|---|---|---|
| A1 ✅ DONE 2026-09-02 | #496 | `Await`/`Spawn` arms + `Wait`; run queue + park table; `sleep`; `spawn`/`spawnTask`/`await`; `concurrent` over spawn; `runAsyncIO`; `main : Async` dispatch on all three engines (#2506) | none | all 3 (wasm: sequential driver) | v1 doctests byte-identical; 3×`sleep 100ms` concurrent in 0.15s wall, 0.00s CPU; `test/engine_fixtures/async_main_dispatch.mdk` |
| A2 ✅ DONE 2026-09-02 | #497 | `ioPoll` (parallel fd/interest arrays, readiness word per fd) + `netSetNonblock` + `netTry{Accept,Recv,Send}` | ~110 lines (`runtime/medaka_rt.c`) | native (+ ledger rows) | capability matrix green; would-block, poll-timeout, readiness-bit and EOF paths exercised by a native probe |
| A3 ✅ DONE 2026-09-02 | #498 | fd parking (`ioPoll` from `wakeParked`); `awaitAny`/`deadlineAfter`/`expired` in `async.mdk`; `stdlib/net_async.mdk` (`accept`/`recv`/`send`/`sendAll`/`recvWithin`/`sendAllWithin`/`sendString`/`close`/`closeListener`/`serve`) | none | native | `test/async_fixtures/echo_overlap.mdk`: a slow client does not stall a fast one, a deadline fires, closing the listener ends `serve` — 0.40 s wall, 0.00 s CPU |
| A4 ✅ DONE 2026-09-02 | #499 | `test/diff_async.sh` build-and-run gate over `test/async_fixtures/` (self-timed overlap fixture, order-of-magnitude margin); v1 determinism = the byte-identical v1 doctests + `engine_fixtures/async_main_dispatch.mdk`; doc sweep; this doc → IMPLEMENTED | none | — | CI green across the board |

A1 ∥ A2 (independent); A3 needs both; A4 sweeps. A1 and A2 each touch compiler source
(driver dispatch; `llvm_emit.mdk`) → fixpoint-gated, goldens blessed in the same commit,
`benchmark-emitter` skill before measuring anything, seed re-mint deferred unless forced.
