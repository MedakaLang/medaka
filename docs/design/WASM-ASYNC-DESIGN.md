# Async on the WasmGC target

**Status:** WA-1 to WA-4 are implemented by sprint the-browser-can-wait
(#3851); WA-5 remains open. Ruling 2's mechanism was reversed on 2026-10-05
(§10 item 2). Written 2026-10-05 for the
HN-readiness epic #3700 (item 8) against `main` at `b5fbcfbe`. Every claim
below is marked **measured** (with the command, on a binary built from that
commit in this worktree) or **read** (with the file). Companion to
`docs/design/ASYNC-RUNTIME-DESIGN.md` (the runtime, IMPLEMENTED) and
`docs/design/TARGETS-DESIGN.md` (profiles, ratified 2026-10-01, nothing built).

Today every program that imports `async` fails in the browser playground with
"module `time` is native-only and not available in the browser playground (the
`async` module depends on it)". This document says what the gap actually is,
how a wasm program waits, which labels each wasm profile grants, how the
semantics stay one semantics, and how the work slices.

## 1. Prior decisions this design sits under

None of these is reopened. Where a finding below bears on one, it is flagged
as a contradiction in §10, not resolved here.

- **The targets law** (`docs/design/TARGETS-DESIGN.md` §3.2, rulings 1–4): a
  target may lack a capability and may never change a meaning; the only
  permitted divergence is the binding of an extern, never a Medaka body; no
  `#ifdef`, no `@target`, no per-target stdlib file; availability is at
  **label** grain, so a backend claiming a label implements every catalog
  extern under it; `--target wasm` stays an alias for `wasmgc/node`.
- **Async v2 is locked** (`docs/design/ASYNC-RUNTIME-DESIGN.md` R1–R6, G1–G9,
  amendments M1–M4; #500 rulings of 2026-09-02): one driver `runAsync`
  performing exactly the program's row; a `Wait` carries the capability its
  builder performs; spawn, `Task`, wait sets are in; cancellation, `race`,
  `timeout` are out; a program whose remaining tasks can never be woken
  **panics**; `main : Async e Unit` is rewritten by
  `compiler/driver/main_autoprint.mdk` `asyncWrapModules` on every engine.
- **The eager arm is deferred** (`decided_async_v2_defers_the_eager_arm`):
  construction is pure; nothing here touches the `Deferred*` instances.
- **No catchable panics** (`no-catchable-panics-isolation`): a deadlock is a
  panic that ends the program; the host observes the corpse.
- **The interpreter is a pure deterministic oracle**
  (`decided_interpreter_is_a_pure_deterministic_oracle`): the pure extern
  table cans the clock. §6.3 states the consequence for gating; it does not
  ask for a change.
- **JS bindings are `<FFI "js/…">`**, one label with a host-qualified prefix
  (ruling 2). This document binds **catalog** externs (`sleepMs`,
  `monotonicSec`, `wallTimeSec`) under `<Clock>`; it adds no user-facing FFI
  surface and does not touch T4.
- **The async host binding is a non-goal of T1–T5** (`TARGETS-DESIGN.md` §7.6,
  §8.3, §9): "JSPI is the eventual path … neither is designed here". This
  document is that design, scoped to the clock.

## 2. Where the gap is — measured

Three probes, built from this worktree (`make -C <worktree> medaka`, then
`sh test/wasm/build_wasm_oracle.sh --modules-only`), each driven through all
three engines:

```sh
./medaka run p.mdk
MEDAKA_EMITTER=<worktree>/medaka_emitter ./medaka build p.mdk -o p.bin && ./p.bin
MEDAKA_WASM_EMITTER=<worktree>/test/bin/wasm_emit_modules_main ./medaka build --target wasm p.mdk -o p.wasm \
  && node test/wasm/run.js p.wasm
```

| Probe | `run` | native | wasm (`node test/wasm/run.js`) |
|---|---|---|---|
| **compute-only** `main : Async <Stdout> Unit` — `liftIO`, `concurrent [1,2,3]`, `spawnTask` + `await` | `start` / `[1, 2, 3]` / `46`, exit 0 | identical | **identical, exit 0.** Imports declared: `mdk_write_byte`, `mdk_write_err_byte`, `mdk_float_fmt`, `mdk_float_fmt_byte` only (`wasm-tools print … \| grep import`). |
| **sleep** — two tasks each `sleep (millis 20)` under `concurrent`, `main : Async <Clock, Stdout> Unit` | `a before` / `b before` / `a after` / `b after` / `done` | identical | **build fails, exit 1:** `runtime error [E-PANIC]: unbound variable 'sleepMs' (not a local, global value, constructor, or known function) [in async__systemDeadline]` |
| **deadlock** — `awaitAny [waitFlag (Ref False)]` after one print | `start`, then `runtime error [E-PANIC]: async: every remaining task is waiting on a task that can never finish (deadlock)`, exit 1 | identical, exit 1 | **identical, exit 1** (the coded line streams through `mdk_write_err_byte` before the `unreachable`; `run.js` surfaces it) |
| **clock only** — `import time.{monotonic}`, no async | `clock ok` | `clock ok` | build fails: `unbound variable 'monotonicSec' … [in time__monotonic]` |

So, **measured**: the scheduler (`stdlib/async.mdk` `schedule`, `wakeParked`,
`dispatch`), the `main : Async` driver rewrite (`asyncWrapModules`, applied in
`compiler/entries/entry_support.mdk` `runEmitWith` with the driver string
`"runAsyncMain"` from `compiler/entries/wasm_emit_modules_main.mdk`), the
graded `Deferred*` dispatch, `spawn`/`await`, input-order `concurrent`, and
the deadlock panic all reach wasm today and agree with native byte for byte.
The emitter prunes unreachable bindings, so a program that never sleeps never
mentions a clock extern.

The gap is exactly the three `<Clock>` externs of the catalog, **read** in
`stdlib/runtime.mdk`: `wallTimeSec`, `monotonicSec`, `sleepMs`. They are
reached from `stdlib/async.mdk` `systemDeadline` (`sleep`, `deadlineAfter`)
and from `stdlib/time.mdk` `now`, `nowDateTime`, `monotonic`,
`elapsedSince`, `sleep`. Their wasm disposition is `WASM-GAP` in
`test/CAPABILITY-EXCEPTIONS.txt` (**read**), tracked by #2426 and by the
label-grain ratchet #3666. The failure is the `unbound variable` fallthrough in
`compiler/backend/wasm_emit.mdk` (`gapUnboundLTy` and its ref-mode peer),
the #380/#3667 class.

Two more things stand between a visitor and a running async program, both on
the host side (**read**):

- `stdlib/time.mdk` is not in the playground's virtual filesystem. The shipped
  list is the hand-kept `EXTRA_MODULES` in `playground/main.js` and
  `playground/build_playground_wasm.sh` (identical lists; `time`, `math`,
  `fs`, `net`, `io`, `test` excluded). `async.mdk` imports `time`, so the
  playground compiler reports `unknown module: time`, which
  `playground/compile.mjs` `nativeOnlyModuleMessage` rewrites into the message
  quoted at the top. `time.mdk` in turn imports `math.{floorDiv}` and
  `regex.{Regex, mustCompile, find}`; `regex` is also absent from the list,
  and `math` is excluded by a stale rationale ("libm") although every libm
  import it can reach is already provided by `playground/worker.js`.
- No host provides a clock. `test/wasm/run.js`, `playground/worker.js` and
  `playground/compile.mjs` each carry an `env` object (the three drifting
  copies of `TARGETS-DESIGN.md` §1); none has `mdk_sleep_ms`,
  `mdk_monotonic_sec` or `mdk_wall_time_sec`.

Nothing else is missing. In particular the effect machinery is not involved:
`Async <Clock, Stdout> Unit` typechecks on every verb (the native build of the
sleep probe is green), and `compiler/tools/check_policy.mdk` has no profile
concept yet (T2, #3664/#3665, unbuilt).

## 3. The waiting model

WasmGC cannot block: a host import returns before the module continues, and
the module runs on the worker's one thread. `sleepMs` is the only catalog
extern under `<Clock>` that must pass wall time; the other two are reads.
`stdlib/async.mdk` `sleepThrough` calls the `Timer`'s sleep closure, which is
`sleepMs`, when every task is parked and the nearest deadline is in the
future. Three ways to make that call pass time on wasm:

### 3.1 The candidates

**(a) Return to the host loop.** The scheduler runs to quiescence, returns to
JavaScript with "wake me at t", and a timer callback re-enters the module.
This needs the scheduler's state (`front`, `back`, `parked`, the result cell —
all `Ref`s local to one `runAsync` call) to survive a return from `runAsync`,
and the loop to resume from where it left off. Two shapes exist, and both are
ruled out:

- A wasm-specific driver body (`runAsyncMain` that steps rounds and returns
  between them, re-entered through an export) is a per-target Medaka body,
  which the law forbids outright.
- A compiler transform that makes the one driver body resumable (the shape of
  Binaryen's Asyncify: every frame between the entry and the `sleepMs` call
  learns to unwind its locals to a side buffer and rewind them on re-entry)
  keeps one Medaka body but is an emitter rearchitecture of every function on
  the scheduler's reach, closures captured in `Suspend` thunks included. It is
  unrelated to anything the emitter is scheduled to do (#1398 and the X-*
  arc), and JSPI is the engine doing the same thing natively.

Dropped. The one property (a) offers that the others lack, a worker that stays
responsive to messages while the program sleeps, buys nothing: `worker.js`
receives no messages during a run, and the kill is `terminate()` from the
main thread (**read**: `playground/main.js` `killRunner`).

**(b) JSPI (JavaScript Promise Integration).** The host wraps `mdk_sleep_ms`
in `new WebAssembly.Suspending(ms => new Promise(r => setTimeout(r, ms)))`
and calls the program through `WebAssembly.promising(exports.mdk_main)`. The
engine switches the wasm stack out while the promise is pending; the Medaka
body is untouched and the binding is genuinely "pause for N ms".

Engine support (**read** from `features.json` of the webassembly.org feature
table, the proposal's `Overview.md`, MDN, and the vendor release pages, all
fetched 2026-10-05): proposal phase 5 (standardized). Chrome 137+, Firefox
153+, Safari 27+, Node 26+ by default. Current stable on 2026-10-05: Chrome
154, Firefox 157, Safari 27.0 (WebKit announced 2026-09-17), Node 24 is the
active LTS with 26 as Current. **Measured** on this box (Node 24.18.0):
`WebAssembly.Suspending` is `undefined` without a flag and a function with
`--experimental-wasm-jspi`; a `Suspending` sleep import called from a
`promising` export really waited (`guest wrote 29` after a 30 ms sleep,
elapsed ~30 ms); the same import reached from a `(start)` function during
instantiation throws `SuspendError: trying to suspend without
WebAssembly.promising`. The flag name is the V8 one, confirmed by
`node --v8-options`.

Costs:

- **Entry shape.** The emitted module runs `main` inside `(start $__init)`
  (**read**: `compiler/backend/wasm_emit.mdk` `emitRefInit` emits `$__init`
  = eager value inits + `call $__main`, exports `$__main` as `mdk_main`, and
  `(start $__init)`). A suspension inside `start` traps (measured above). So
  JSPI requires `$__init` to stop calling `$__main` and every host to call
  `exports.mdk_main` after instantiation. `playground/compile.mjs` already does
  that on re-entry for the compiler module (its persistent session; **read**),
  so the shape exists; the change is one emitter line and one line in each
  host, and it moves the WH1 inventory in `docs/spec/WASM-SEMANTICS.md` §3
  ("Emitted when … during instantiation" becomes "on `mdk_main`").
- **Engine baseline.** WH6 pins Node ≥ 24; every wasm gate runs `node
  test/wasm/run.js`. JSPI there needs `--experimental-wasm-jspi` in every
  invocation until the CI pin is Node 26, which is a CI decision outside this
  document.
- **Browser floor.** Safari 27 is three weeks old on the posting date. A Safari
  26 visitor has no `WebAssembly.Suspending`, so a JSPI-only host needs a
  feature test and a second binding to fall back on, which is (c).

**(c) A blocking wait in the worker.** `mdk_sleep_ms` binds to
`Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)`. The worker
thread is suspended by a futex for `ms`; no CPU is burned (G6 holds); no
emitter change; no entry change. `Atomics.wait` is permitted in a dedicated
worker and throws on a document's main thread (**read**, MDN); Node permits
it on the main thread (**measured**: `timed-out` after ~30 ms in
`node` with no flag). `SharedArrayBuffer` is hidden from a page that is not
cross-origin isolated (**read**, MDN), so the playground must serve `/` with
`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`. That is a path-scoped entry in
`playground/_headers` (Cloudflare Pages; the file already scopes a rule to
`/dist/*.mdk`, **read**). The playground page loads no cross-origin script,
style or font (**read**: `playground/index.html` has one same-origin
importmap and one same-origin module script), so COEP blocks nothing on that
route; the blog embeds a Bluesky script from `embed.bsky.app` (**read**:
`docs/blog/pds.md`), which is why the headers must be scoped to the
playground route and not the site. A busy-wait on `performance.now()` is the
degenerate form of (c) that needs no isolation; it violates G6 and is not
proposed.

### 3.2 Comparison

| | (a) host loop | (b) JSPI | (c) `Atomics.wait` in the worker |
|---|---|---|---|
| Medaka body change | per-target driver (forbidden) or Asyncify (rearchitecture) | none | none |
| Emitter change | large | `start` no longer runs `main`; hosts call `mdk_main` | none |
| Runtime/host change | re-entry protocol, state hoisting | wrap one import, wrap the entry | one import, COOP/COEP on `/` |
| Browser support today | n/a | Chrome 137+, Firefox 153+, Safari 27+ | every engine that exposes `SharedArrayBuffer` under cross-origin isolation |
| Node 24 (CI pin) | n/a | behind `--experimental-wasm-jspi` | yes |
| G6 (idle ≈ 0 CPU) | yes | yes | yes (futex) |
| Worker stays responsive during a sleep | yes | yes | no (nothing needs it) |
| 10 s kill (`RUN_TIMEOUT_MS`, `playground/main.js`) | fires | fires; worker is idle in `setTimeout` | fires; `terminate()` ends a blocked worker |
| Output streamed before the sleep | delivered | delivered | delivered (already posted to the main thread) |
| Generalizes to a promise-shaped host op (`fetch`) | yes | yes, the same mechanism | no (needs a relay worker) |

### 3.3 Recommendation

**Bind the clock with (c) now, and make (b) the designed binding for every
promise-shaped host operation, starting with the same `sleepMs` once the
engine floor allows it.** Concretely:

1. The `wasmgc/node` and `wasmgc/browser-worker` profiles claim `<Clock>` with
   three host imports: `mdk_wall_time_sec` (`Date.now() / 1000`),
   `mdk_monotonic_sec` (`performance.now() / 1000`), `mdk_sleep_ms`
   (`Atomics.wait` on a private 4-byte `SharedArrayBuffer`). These are extern
   bindings, the one divergence the law permits; `stdlib/time.mdk` and
   `stdlib/async.mdk` do not change.
2. The emitter's entry shape changes in the same arc so that `start` initializes
   and `mdk_main` runs the program, because that change is cheap, it is what
   `compile.mjs` already assumes on re-entry, and it is the only emitter
   prerequisite of (b). It lands with its WH1 inventory update.
3. When the host detects `WebAssembly.Suspending` (Node 26 in CI, Safari 27
   past its adoption curve), `mdk_sleep_ms` binds to the `Suspending`
   `setTimeout` and the entry is called through `promising`. The two bindings
   have one observable meaning, "pause for N ms", and the same program prints
   the same lines under either; the one host module of T3 (#3668) owns the
   choice.

Why not JSPI alone now: Safari 26 is a plausible HN reader's browser and the
CI pin is Node 24. Why not `Atomics.wait` forever: the edge profile's handler
is a promise and `fetch` is a promise; `TARGETS-DESIGN.md` §7.6 and §8.3
already name JSPI as that path, and `Atomics.wait` is refused on a main thread
and on hosts that forbid blocking. Keeping (c) as the fallback costs one
alternative binding in one slice of one host module.

## 4. Capabilities per profile, at label grain

`TARGETS-DESIGN.md` §8.1 fixes the grant sets (**read**). This section says
what each grant means for an async program, and what a program outside the
grant gets.

| Label | `wasmgc/node` | `wasmgc/browser-worker` | What an async program sees |
|---|---|---|---|
| `Stdout`, `Stderr` | granted (today) | granted (today) | `liftIO (u => putStrLn …)` works, measured |
| `Clock` | **this design** | **this design** | `sleep`, `deadlineAfter`, `expired`, `time.now`, `time.monotonic`, `elapsedSince`; `recvWithin`-style deadlines on anything that gains an async surface later |
| `Net` | not granted (raw sockets, `NotProvided` on every `env` profile) | not granted | see below |
| `Stdin` | granted (T2 ratchet row; unbuilt) | **not granted** (ruled) | see below |
| `Rand`, `FileRead`/`FileWrite`, `Env` | per §8.1; T2 ratchet | per §8.1 | unrelated to async; the ratchet #3666 owns them |

**A program that needs `<Net>`** (anything through `net_async`: `accept`,
`recv`, `serve`, …) is refused **before any emitter runs**, by `check` under
the selected profile, with the T2 diagnostic (`T-TARGET-CAPABILITY`, #3665):
the label, the profile, and the via-chain. On the playground the profile is
`wasmgc/browser-worker`, fixed by the host. Until T2 lands the playground's
refusal is the module one: `net_async` is not in the shipped list, so the
import fails as `unknown module: net_async` and is rewritten by
`nativeOnlyModuleMessage`. Both are check-time, located refusals. What must
never happen, and what the measured gap shows today for the clock, is an
emitter panic or a runtime "native-only" after a green check. §9 states which
slice moves the playground from the module refusal to the label refusal.

**`readLine` and the `<Stdin>` family.** `browser-worker` does not grant
`Stdin` (ruled). A program that calls `readLine ()` is a check-time
`T-TARGET-CAPABILITY` refusal under that profile once T2 lands; until then it
is the worker's named `CapabilityError` (`playground/worker.js`
`capabilityStub`) at call time, which #3691 item 4 asks to word as "`readLine`
is not available in the browser playground (no stdin)". Under `wasmgc/node` it
is granted and bound by the T2 ratchet. Neither is async work; `readLine` is a
blocking read and stays one on every target.

**`ioPoll`.** The catalog row is `extern ioPoll : Array Int -> Array Int -> Int
-> <Clock> Result String (Array Int)` (**read**, `stdlib/runtime.mdk`: "a wait
reaches no endpoint … charged as the clock", the #3320/#3323 ruling), while its
wasm disposition at `b5fbcfbe` was `PERMANENT` under the net family (**read**,
`test/CAPABILITY-EXCEPTIONS.txt`; `isNetExternW` in
`compiler/backend/wasm_emit.mdk`). Under label grain, a backend claiming
`<Clock>` implements `ioPoll`. This is §10 decision 2. Its first mechanism (every
descriptor reported invalid, readiness word 3, the `POLLNVAL` meaning
`runtime/medaka_rt.c` `mdk_io_poll` gives a closed descriptor) rested on the
premise that `ioPoll` is unreachable without a socket, which needs `<Net>`. The
premise is false: `async.waitRead : Int -> Wait <Clock | e>` takes a raw
descriptor, so a `<Clock, Stdout>` program reaches `ioPoll` through the
scheduler. The sprint review measured it: waiting on descriptor 0 with stdin an
idle pipe printed `stdin ready` on wasm and `timed out` natively.

Val reversed the mechanism on 2026-10-05, after the sprint review; the
`<Clock>` label decision stands. The wasm lowering of `ioPoll` is inline in
`compiler/backend/wasm_emit.mdk` (`emitLeafExternRef`), with no host import. It
evaluates its three arguments left to right, as native does, and then stops
with the coded runtime error `E-WASM-NO-BINDING` ("descriptor readiness has no
wasm binding"; the `Net` and `Stdin` bindings are #3666). It is a run-time trap,
not a build-time gap, because the scheduler's `systemPoller` names `ioPoll`:
a clock-only async program must still build, and it never calls `ioPoll`
without a descriptor wait. The ledger row is the wasm `ioPoll` row of
`test/CAPABILITY-EXCEPTIONS.txt`.

## 5. Semantics stay identical

The contract is `docs/spec/EMITTER-SEMANTICS.md` R2 (one meaning on every
engine) and `ASYNC-RUNTIME-DESIGN.md` G1/G2. What this design asserts, and
what it names as observable differences that are not meaning changes:

**Identical, and gated:**

- Compute-only scheduling, round-robin at every `Suspend`, input-order
  `concurrent`, `spawn`/`await`, the deadlock panic: **measured** identical on
  all three engines (§2) and already pinned by
  `test/engine_fixtures/async_main_dispatch.mdk` and
  `test/engine_fixtures/async_interleave.mdk` (**read**), which the engines
  gate runs on the wasm arm.
- Timer order among parked tasks: `wakeParked` wakes every expired deadline
  in park order (`requeue` is oldest-first, **read**), and `monotonicSec` is
  monotone, so two tasks that `sleep` the same duration wake in the order they
  parked on every engine, and a task that sleeps an order of magnitude longer
  wakes after one that sleeps shorter. Those are the only timer-order claims a
  fixture may pin, the `diff_async` convention (**read**:
  `test/diff_async_test.mdk`, "every ordering claim in an `.expected` rests
  on a sleep at least an order of magnitude longer").
- Deadlock: the same coded panic line on stderr, exit status 1, partial stdout
  delivered first (WH4), **measured** on wasm through `run.js`. In the
  playground the worker's catch handler surfaces the coded line
  (`playground/worker.js`, "B5", **read**).

**Different, and why it is not a meaning change:**

- Clock values. Browsers coarsen `performance.now()` as a timing-attack
  mitigation (the granularity is vendor policy and depends on isolation; not
  measured here) while native reads `CLOCK_MONOTONIC`, and the two clocks
  have different origins. The
  catalog promises "a monotonic clock reading in seconds, for measuring
  intervals" and nothing about origin or resolution; no golden may print a
  clock value (G2), and `elapsedSince` already differs run to run on one
  engine. `wallTimeSec` differs by the host's wall clock, as it does between
  two native machines.
- Sleep overshoot. `nanosleep` and `Atomics.wait`/`setTimeout` both sleep
  *at least* the requested time; `millisUntil` already rounds up by one
  millisecond (**read**). A fixture may assert an order-of-magnitude overlap
  (`overlap_sleeps.mdk`: three 100 ms sleeps in under 250 ms) and nothing
  tighter.
- The playground's 10 s budget counts time spent asleep. A program that sleeps
  15 s is stopped at 10 s with the existing message. That is a resource limit
  of one host, applied equally to compute; the native binary has no limit, as
  it has none for compute.
- Under the **pure** interpreter table (`compiler/eval/eval.mdk`
  `pMonotonicSec` returns a constant, `pSleepMs` is a no-op; **read**) a
  parked deadline never expires and `sleepThrough` loops without passing time.
  `medaka run` installs the real-clock table (`ioExternBindings`,
  `pMonotonicSecIO`/`pSleepMsIO`; **read**; the sleep probe ran correctly
  under `run`, **measured**). The engines gate's eval arm is the pure table
  (`compiler/entries/eval_autoprint_main.mdk` → `evalModulesOutput`, **read**),
  so a sleep-bearing fixture cannot live in `test/engine_fixtures/`; it goes
  in `test/async_fixtures/`, whose gate gains a wasm arm (§6.3). This is a
  consequence of the interpreter-purity ruling, stated, not a request to
  change it.

**What the design must preserve on the host side:** the three `Timer` and
`Poller` closures are built in Medaka and called by the scheduler; the host
sees only the three leaf imports. No scheduling decision moves into
JavaScript. A wasm host that implemented `mdk_sleep_ms` as "return at once"
would change a meaning (every deadline would spin until expiry, G6 broken,
order preserved); that is the one binding this design forbids, and the
`overlap_sleeps` fixture on the wasm arm is what detects it, since a spinning
scheduler still prints `overlapped`. §6.3 therefore adds a CPU-time assertion
to that arm.

## 6. Gating

### 6.1 The ratchet rows drain

`test/CAPABILITY-EXCEPTIONS.txt`: the three `Clock` `WASM-GAP` rows are
deleted; `test/diff_compiler_capability_matrix.sh` reds if a row is deleted
while the emitter still lacks the lowering. `test/engine_divergence.txt`: the
row `llvm/clock_monotonic_sleep … wasm:emitter-gap … unbound variable
'monotonicSec'` (**read**) is promoted (the gate says `PROMOTE` and refuses
to stay green with a passing ledgered row, **read**:
`test/diff_compiler_engines.sh`). #2426 closes.

### 6.2 WH1 and WH3

Each new import lands with a `docs/spec/WASM-SEMANTICS.md` §3 row and an
implementation in **every** host the shim-parity gate derives
(`test/diff_compiler_wasm_shim_parity.sh`; today `run.js`, `worker.js`,
`compile.mjs`), or, after T3 (#3668), as a `clock` slice of the one host
module. Until T3 the three copies drift by construction; the parity gate
covers only the marked blocks (#449), so the import-key-set half is checked by
hand in review. `wasm-tools print <module> | grep '(import "env"'` is the
probe.

### 6.3 Fixtures

- **`test/diff_async_test.mdk` gains a wasm arm** for the fixtures whose
  manifest the `wasmgc/node` profile admits: `overlap_sleeps`, `no_starvation`
  (no `Net`). The gate currently declares itself native-only and checks that
  declaration (its last test, **read**); the declaration narrows to "the
  net fixtures are native-only". The wasm arm builds with
  `MEDAKA_WASM_EMITTER` and runs `node test/wasm/run.js`; `.expected` is
  shared. For `overlap_sleeps` the wasm arm also asserts that the process's
  CPU time is an order of magnitude below its wall time (G6; the detector for
  the forbidden return-at-once binding). `test/gates.toml` row `diff_async`
  gains `"compiler/backend/wasm_emit.mdk"`, `"test/wasm/run.js"` in `sources`
  and `wasm-tools`, `node>=24` in `toolchain`; `shard` is re-derived by
  `medaka gate balance`, never hand-set.
- **`test/engine_fixtures/`** gains nothing that sleeps (§5). It may gain a
  compute-only `async_deadlock.mdk` pinning the coded panic line and exit
  status across the three engines, since the deadlock needs no clock.
- **The visitor battery.** Rows `49_async`, `64_async_defer`,
  `65_async_do_panic` (**read**, `test/visitor_battery/`) currently reach the
  live playground as one and the same "module `time` is native-only" line
  (#3841, **read**). After this design: `49_async` is a located type error on
  every engine (its `sleep 10` passes an `Int` where `sleep` takes a
  `Duration`, and `do` over `Async` is #3689); `64_async_defer` prints `3`;
  `65_async_do_panic` is the located `No impl of Thenable…` error that
  `check`/`run`/`build` give natively, not the module message. #3841's
  completion-detection defect must be fixed first for the browser battery to
  report 65/65; it is independent of this design.
- **The playground e2e suite** (`playground/e2e/`) gains one spec beside
  `runaway.spec.mjs`: a program that prints, sleeps 200 ms twice under
  `concurrent`, and prints again; the page must show all lines, in order,
  within the limit, with the "compiled & ran" footer. A second case sleeps 15 s
  and must show the existing `stopped after 10 s (the playground's time limit)`
  message with the pre-sleep output intact.

### 6.4 Derived parity

Once T3's §6.3 gate exists (module import key set ⊆ profile slice set), the
three clock imports are members of the `clock` slice and the gate is the
check. Nothing in this design should build a one-off parity check that T3
would delete.

## 7. The bindings, exactly

Declared in `compiler/backend/wasm_preamble.mdk` beside `mdk_exit`, emitted
when the program reaches a `<Clock>` extern (a `useClock` flag set in
`noteW8Extern`'s family, the pattern every other import group follows,
**read**):

```wat
(import "env" "mdk_wall_time_sec" (func $mdk_wall_time_sec (result f64)))
(import "env" "mdk_monotonic_sec" (func $mdk_monotonic_sec (result f64)))
(import "env" "mdk_sleep_ms"      (func $mdk_sleep_ms (param i64)))
```

Lowering (`compiler/backend/wasm_emit.mdk`, the leaf-extern ladder): the two
reads box the `f64` the way `mdk_float_fmt`'s operand is unboxed today;
`sleepMs` unboxes its `Int` to `i64` and returns Unit. The LLVM peer is
`emitPerfExtern` (**read**, `compiler/backend/llvm_emit.mdk`), whose C
bindings are `mdk_wall_time_sec` (`gettimeofday`), `mdk_monotonic_sec`
(`clock_gettime(CLOCK_MONOTONIC)`), `mdk_sleep_ms` (`nanosleep`; a
non-positive count returns at once) in `runtime/medaka_rt.c` (**read**). The
JavaScript bindings must match the last clause: `ms <= 0` returns without
waiting.

Host side, the `clock` slice:

```js
// playground/worker.js (and run.js, compile.mjs until T3)
const waitCell = new Int32Array(new SharedArrayBuffer(4));
mdk_wall_time_sec: () => Date.now() / 1000,
mdk_monotonic_sec: () => performance.now() / 1000,
mdk_sleep_ms: (ms) => { ms = Number(ms); if (ms > 0) Atomics.wait(waitCell, 0, 0, ms); },
```

When `typeof WebAssembly.Suspending === 'function'` and the entry is called
through `promising`, the same key binds
`new WebAssembly.Suspending((ms) => ms > 0 ? new Promise((r) => setTimeout(r, Number(ms))) : undefined)`.
A `Suspending` import that returns a non-promise does not suspend (**read**,
proposal overview), so the `ms <= 0` clause holds there too.

`compile.mjs` runs the **compiler**, which never sleeps; its copy of the slice
exists for WH3's LinkError ban, not for use. Under T3 it is the same slice
object.

The entry-shape change (`$__init` no longer calls `$__main`; hosts call
`exports.mdk_main()` after `instantiate`) is independent of the `Atomics.wait`
binding and is what the JSPI binding needs. `playground/compile.mjs`'s
persistent session (**read**) already treats `mdk_main` as the entry on
re-entry and documents that a guest ending through `mdk_exit` inside `start`
cannot be cached; after the change that caveat disappears.

## 8. The playground

- `playground/main.js` and `playground/build_playground_wasm.sh`
  `EXTRA_MODULES` gain `time`, `math`, `regex`. The exclusion comments that
  name `math` ("libm") and `time` ("`<Clock>`") are deleted: the libm host
  imports are real in every host (**read**, `docs/spec/WASM-SEMANTICS.md` §3
  rows for the 14 unary libm imports and `mdk_pow`/`mdk_atan2`/`mdk_hypot`),
  `regex` is pure Medaka (decided), and `time`'s own reach into `math` is
  `floorDiv`, pure integer arithmetic. The `stdlib/math.mdk` doc header that
  says its float functions "trap" on the WebAssembly backend is one of the
  two false statements `TARGETS-DESIGN.md` §4.3 already schedules for
  deletion (**read**); WA-3 deletes it, since a visitor who opens the `math`
  reference from the playground reads it. `playground/build_site.sh` and
  `test/wasm/diff_playground_input.sh` read `EXTRA_MODULES` out of `main.js`
  by regex (**read**), so they follow; the shell list in
  `build_playground_wasm.sh` is the second copy that must be edited by hand.
  T3's §6.4 replaces both with one list derived from the catalog; until then
  `build_site.sh`'s fail-closed asset check is what catches a dist that lacks
  a listed module (**read**, `AGENTS.md` [WEB-SITE-FILE-LIST]).
- `playground/_headers` gains, scoped to the playground route and
  `worker.js`: `Cross-Origin-Opener-Policy: same-origin`,
  `Cross-Origin-Embedder-Policy: require-corp`. The site's other routes keep
  embedding third-party scripts. `main.js` checks `crossOriginIsolated` once
  and, if false, binds `mdk_sleep_ms` to the JSPI form when available and
  otherwise to a named `CapabilityError` ("`sleep` needs cross-origin
  isolation, which this deployment does not provide"), so a misconfigured
  deploy fails loudly at the first sleep rather than hanging. Deploy
  verification (`AGENTS.md` [WEB-PREVIEW-SILENT]) gains one `curl -sI` of the
  two headers.
- `playground/compile.mjs` `NATIVE_ONLY_MODULES` loses `time` and `math`;
  `NATIVE_ONLY_EXTERNS` loses `wallTimeSec`, `monotonicSec`, `sleepMs`. The
  rewrite for `net`, `fs`, `io` stays until T2 gives the label refusal.
- `RUN_TIMEOUT_MS` and `killRunner` are unchanged. A worker blocked in
  `Atomics.wait` is ended by `terminate()`; `runaway.spec.mjs` already proves
  the page stays responsive while a worker runs, and the new spec (§6.3)
  proves it while one sleeps.

## 9. Slices

Sized for the sprint machinery (`.claude/skills/sprint-plan/SKILL.md`): each
is one packet, one PR, acceptance stated as a check.

| ID | Mission | Surface | Acceptance |
|---|---|---|---|
| **WA-1 the clock has a wasm binding** | Lower `wallTimeSec`, `monotonicSec`, `sleepMs` to three host imports; implement the `clock` slice in `run.js`, `worker.js`, `compile.mjs` (`Atomics.wait` form); delete the three `WASM-GAP` rows; promote `llvm/clock_monotonic_sleep`. | `compiler/backend/wasm_emit.mdk`, `compiler/backend/wasm_preamble.mdk`, the three hosts, `test/CAPABILITY-EXCEPTIONS.txt`, `test/engine_divergence.txt`, `docs/spec/WASM-SEMANTICS.md` §3. | The sleep probe of §2 builds and prints the native output under `node test/wasm/run.js`; `diff_compiler_capability_matrix`, `diff_compiler_engines`, `diff_compiler_wasm_shim_parity` green; #2426 closed. |
| **WA-2 the async gate has a wasm arm** | `diff_async` runs `overlap_sleeps` and `no_starvation` on wasm with the CPU-time assertion; `engine_fixtures/async_deadlock.mdk`; the gate's native-only declaration narrowed to the net fixtures. | `test/diff_async_test.mdk`, `test/async_fixtures/`, `test/engine_fixtures/`, `test/gates.toml` (then `medaka gate balance && make gen-ci`). | `diff_async` reports the wasm arm per fixture; a host whose `mdk_sleep_ms` returns at once reds it; `ci-gen-drift` green. |
| **WA-3 the playground runs async** | Ship `time`, `math`, `regex`; COOP/COEP on the playground route; `crossOriginIsolated` check with the named error; `compile.mjs` lists trimmed; the two e2e cases; deploy and verify on the live origin. | `playground/main.js`, `playground/build_playground_wasm.sh`, `playground/_headers`, `playground/compile.mjs`, `playground/worker.js`, `playground/e2e/`, `playground/README.md` § Deploying. | `64_async_defer` prints `3` on https://medaka-lang.dev; the 200 ms and 15 s e2e cases pass; `curl -sI https://medaka-lang.dev/` shows both headers; `/blog/` shows neither. |
| **WA-4 the entry is `mdk_main`** | `$__init` initializes only; every host calls `exports.mdk_main()`; the `compile.mjs` session caveat removed; WH1 text updated. | `compiler/backend/wasm_emit.mdk` `emitRefInit`, the three hosts (`test/visitor_battery/tools/pg_compile.mjs` and the e2e drivers enter through `compile.mjs`, **read**), `docs/spec/WASM-SEMANTICS.md`. | Every wasm gate green with no fixture change; a module instantiated without calling `mdk_main` prints nothing (pinned). |
| **WA-5 sleep suspends under JSPI** | Host feature-detects `WebAssembly.Suspending`; binds `mdk_sleep_ms` to the `Suspending` form and calls the entry through `promising`; `run.js` honours the flag; a gate row runs `diff_async`'s wasm arm under `node --experimental-wasm-jspi` on Node 24 (or without it on 26). | the hosts (or the T3 host module), `test/diff_async_test.mdk`, `.github/actions/setup-medaka/action.yml` if the pin moves. | Both bindings print the same `.expected`; the e2e cases pass in Chrome with and without isolation. |

WA-1 → WA-2 → WA-3 is the HN-week path; WA-3 is the slice a visitor sees.
WA-4 is independent of WA-1–3 and can run alongside. WA-5 needs WA-4 and
should wait for T3 (#3668) so the second binding is one slice object, not a
fourth copy. If T3 lands first, WA-1's three copies become one slice in
WA-1's review round rather than a follow-up.

**Out.** Any async host operation other than the clock (`fetch` on the edge,
T5 #3674; an async `readLine`); the `Stdin` family's wasm bindings (T2 ratchet
#3666, not async); `allocBytes` (its label is undecided, #3666); cancellation,
`race`, `timeout` (ruled out, #500); the interpreter's canned clock (ruled);
replacing `env` with WASI (ruling 4); a worker that stays responsive during a
sleep (nothing needs it); shared-memory threads (proposal phase 1).

## 10. Decisions for Val

Val accepted all five recommendations on 2026-10-05 (recorded on #3851).
Rulings 1-3 are built by the slices in section 9; rulings 4 and 5 are design
text only, with nothing built for them by WA-1. What follows is the question
and the recommendation as put to her.

1. **Waiting model for the clock.** Recommend §3.3: `Atomics.wait` in the
   worker now, JSPI as the designed binding for promise-shaped operations,
   `sleepMs` moving to it behind feature detection once the engine floor
   allows (WA-5). Alternatives: JSPI only (excludes Safari 26 and needs the
   Node 24 flag in every gate); `Atomics.wait` only (closes the door on
   `fetch` without a relay worker). The entry-shape change (WA-4) is
   recommended in either case.

2. **`ioPoll` under `<Clock>` versus label grain.** The catalog charges
   `ioPoll` as the clock (the #3323 ruling) and the ledger withholds it from
   wasm as `PERMANENT` under the net family. Ruling 1 makes those
   inconsistent the moment wasm claims `<Clock>`. Recommend: wasm binds
   `ioPoll` so that it reports every descriptor invalid (readiness word 3, the
   `POLLNVAL` meaning `mdk_io_poll` already gives a closed descriptor), and the
   `PERMANENT` row goes. It is unreachable without `<Net>`, so no program
   observes it, and the label claim is honest. Alternative: re-row `ioPoll` as
   `<Clock, Net _>`, which reopens #3320's "a wait reaches no endpoint" and
   widens every `waitRead` caller's manifest. Not recommended.

   **Reversed 2026-10-05 by Val, after the sprint review (mechanism only; the
   `<Clock>` label decision stands).** The premise was refuted: `waitRead`
   takes a raw descriptor, so a `<Clock, Stdout>` program reaches `ioPoll`, and
   the review's probe printed `stdin ready` on wasm against `timed out`
   natively. The built lowering was inline, never a host import. Wasm now
   evaluates the arguments left to right and stops at run time with
   `E-WASM-NO-BINDING` (§4).

3. **Cross-origin isolation on the playground route.** Recommend yes, scoped
   to `/` and `worker.js` in `playground/_headers`, with the
   `crossOriginIsolated` guard and named error in `main.js`. It is required
   by (c) and harmless to (b). Alternative: no isolation, JSPI only, with a
   named "your browser cannot sleep" error on Safari 26 and earlier.

4. **What the playground vfs carries once T2 lands.** `TARGETS-DESIGN.md`
   §6.4 derives the shipped module list from the catalog (ship iff granted),
   which makes an ungranted import an `unknown module` rewritten by
   `compile.mjs`. Recommend, as an amendment to the mechanism and not the
   ruling: the vfs carries every stdlib module and the refusal is T2's
   `T-TARGET-CAPABILITY` at check, which names the label and the via-chain and
   is the same diagnostic a native `--target wasmgc/browser-worker` check
   gives. The generated list then feeds `build_site.sh`'s asset check only.
   Alternative: keep §6.4 as written and accept two refusal shapes (module
   versus label) for the same cause.

5. **The CI engine pin.** WA-5 needs either `--experimental-wasm-jspi` on
   every `node` invocation of a wasm gate on Node 24 or a pin bump to Node
   26 in `.github/actions/setup-medaka/action.yml` (WH6). Recommend the flag
   until Node 26 is LTS, then the bump; not a blocker for WA-1–4.

## 11. Measurement log

Everything marked **measured** came from these commands, run 2026-10-05 in
`/root/medaka/.claude/worktrees/agent-a1bc6ac3d87a213f4` at `b5fbcfbe`:

```sh
make -C "$WT" medaka                                     # exit 0
sh "$WT/test/wasm/build_wasm_oracle.sh" --modules-only   # exit 0
# four probes × three engines: the script and its RESULTS.txt in the
# session scratchpad; probe sources are quoted in §2
sh run_probes.sh; sh run_p3.sh
wasm-tools print p1_async_stdout.wasm | grep -o '(import "env" "[a-z_0-9]*"' | sort -u
# JSPI and Atomics on Node 24.18.0 (WAT probes assembled with wasm-tools parse)
node --v8-options | grep -A1 jspi
node jspi_probe.mjs                                      # Suspending: undefined
node --experimental-wasm-jspi jspi_probe.mjs             # export path ok ~30 ms;
                                                         # start path: SuspendError;
                                                         # Atomics.wait: timed-out ~30 ms
```

Engine-support facts (§3.1) were fetched the same day from
`WebAssembly/website` `features.json`, the `js-promise-integration` proposal
overview, MDN's `Atomics.wait` and `SharedArrayBuffer` pages, Mozilla's
release calendar, the Chrome and Safari release pages, and
`nodejs.org/en/about/previous-releases`; `chromestatus.com` was unreadable
(JS-rendered). Nothing in this document was taken from memory of those
sources.
