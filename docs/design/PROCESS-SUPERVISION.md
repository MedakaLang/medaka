# Owned-process supervision boundary

**Status:** PROPOSED. Native authority and independent ownership controls measured; production primitives and containment are not implemented.

This contract serves #4852 and the Medaka MCP runtime work. The supervisor is intended to be Medaka; Python below only drives experiments. Reuse `Async`, `awaitAny`, `waitRead`, `waitWrite` and `ioPoll`; no second event loop is proposed. Linux receipts are recorded below. Actual macOS acceptance remains #4820.

Replay from the repository root after `make medaka`:

```sh
python3 scripts/mcp_bench/prototypes/process_contract_probe.py --out /tmp/medaka-process-contract
```

Python 3, clang (or `--cc`), and Boehm GC development headers/library are required. The driver locates the checkout from its own path, sets `MEDAKA_STRICT=1`, grades native outputs and negative diagnostics, and writes generated fixtures, binaries and `results.json` outside the checkout. `--root /absolute/checkout` selects another built tree. pkg-config or Homebrew supplies GC flags when available. The C source uses POSIX pipe/fcntl; this does not substitute for real macOS receipts.

The driver contains the executable public type spelling and its signature-only operations return `Unsupported "signature probe only"`. Its inhabited Model carries `String @p` and executes legacy runCommand; it is not an opaque Process producer. The independent [C model](../../scripts/mcp_bench/prototypes/process_lifecycle.c) tests OS ownership, not Medaka catalog integration. Full [replay source](../../scripts/mcp_bench/prototypes/process_contract_probe.py).

## Public Medaka surface

`stdlib/core.mdk` gains only `export extern data Process (p : Authority Exec)`. The extern catalog needs a prelude-visible nominal carrier, as it already does for Socket. No public constructor, fd, pid, Eq, Debug or deriving instance.

`process.mdk` in `stdlib/` owns the following exported types and operations, importing stdlib only, with no compiler dependency:

```medaka-nocheck: proposed public declarations; executable signature fixtures are in the replay driver
data PipeChoice = Piped | Null
data SpawnOptions = SpawnOptions {
  argv : List String, cwd : String, env : List (String, String),
  stdin : PipeChoice, stdout : PipeChoice, stderr : PipeChoice
}
data ProcessOperation = Validate | Pipe | Fork | Chdir | ExecImage | Wait | Close
data ProcessError =
  | InvalidSpawn String
  | SpawnFailed ProcessOperation Int String
  | ProcessClosed
  | StillRunning
  | WaitFailed Int String
  | CloseFailed Int String
  | Unsupported String
data ExitStatus = Exited Int | Signalled Int Bool
start : (program : String) -> SpawnOptions -> <Exec program> Result ProcessError (Process program)
pollExit : Process p -> <Exec p> Result ProcessError (Option ExitStatus)
closeStdin : Process p -> <Exec p> Result ProcessError Unit
dispose : Process p -> <Exec p> Result ProcessError Unit
```

Use `public export data` for the public constructor-bearing types in production. `start` constructs no normal Medaka handle; only the catalog producer creates the opaque owner word. Authority erases at runtime. Authority type arguments are invariant, including under Ref; no semantic rule change is needed. Homogeneous containers retain p; an existential collection can only be operated under bare Exec. Policy cannot treat an unresolved p as a concrete path grant.

## Invocation authority and options

Exec p authorizes the native invocation and operations on that owned child, including its I/O and future owned-child termination. It does not authorize signaling an arbitrary numeric pid. Retain the separate Signal label for host signal handlers. Do not change existing native/eval/wasm profile grants in this implementation.

Literal argv/cwd/env are data, not a read of the host environment. The start row is exactly Exec program. Reading `getEnv "NAME"` to fill env separately performs Env {NAME}; the probe rejects dropping that grant or replacing it with another name. Explicit literal cwd is not a FileRead operation or filesystem confinement grant. There is no cwd getter or inherited cwd mode in this first API. Supplying a cwd must not modify the supervisor cwd or its FileRead/FileWrite bound state.

Require nonempty absolute program and cwd strings; reject NUL anywhere in program, argv, cwd, env keys or env values; reject empty/duplicate env keys and `=` in keys. `argv` excludes argv[0], which is program. No PATH search, shell expansion/interpolation, ambient env inheritance, inherited stdin/stdout/stderr, user-selected pid, daemonization flag or arbitrary fd mapping. `env=[]` means empty environment. `Null` redirects that stream to /dev/null. Any supported launch of a shell is explicit invocation of that shell with argv, still an Exec grant. These validation rules are proposed requirements, not all tested by the current C model.

The native image may access anything the OS user can access. docs/design/CAPABILITY-PLATFORM.md §7f/§8 explicitly assigns actual containment to the host proxy. An indexed handle is not a sandbox or executable attestation. Executable pathname symlink replacement, argv-mediated shell behavior and loader variables are not prevented by the type index. #4223 is not closed or bypassed: no new claim of path-based child confinement is made. Any future host proxy restricting cwd/env must validate the whole SpawnOptions object before calling start. Do not interpret passing these type/policy probes as implementing #4413/#4414.

## Native ownership and state

Choose one stable, even, Boehm-scanned owner pointer as the external word. The C layout stays private to `medaka_process.c` in `runtime/`; `medaka_process.h` in that directory exposes the prototypes and opaque owner declaration only. References/closures/containers carry that same word; copying a handle creates an alias, never ownership duplication. Active/unreleased owners are strongly rooted in a native registry, so GC cannot close a live fd or orphan a child. Explicit scope cleanup enumerates owned handles. No finalizer-only path and no finalizer that sends a signal. Production must unregister an owner and sever native links on release; an alias keeps a small tombstone alive until GC.

The probe owner payload is 40 bytes (not a reserved VM object header). 100000 disposed owners held by aliases allocated 4802112 GC bytes plus 800000 bytes of alias slots; payload retained=4000000 bytes. A peak-sized generation slot table retained 4800000 native bytes after close, requiring generation exhaustion/reuse and an extra lookup. This small comparison supports stable owner pointers; it does not measure throughput, production pipe buffers, VM headers or exact conservative-GC reclaim time. The model shows root retention explicitly, not eventual automatic cleanup of leaked user handles.

States: Running(pid, open-stream bits) -> Reaped(cached ExitStatus, pid invalid) -> Disposed(tombstone). A wait-ownership failure transitions to LostWait(cached errno, pid invalid), never back to Running. `pollExit` returns Ok None only for waitpid(pid,WNOHANG)==0, and returns cached Ok (Some status) after reap. EINTR retries. ECHILD is WaitFailed, not success or StillRunning, and removes the ability to send a signal. No waitpid(-1), global SIGCHLD rewrite, kill(0), or negative pid/group kill in this layer.

`closeStdin` invalidates the shared fd before close; repetition while undisposed is Ok. The check and invalidation must not yield; concurrent native callers would require synchronization beyond this single-caller model. Never retry a failed close by numeric fd, since its number can already have been reused. A disposed handle returns ProcessClosed from poll/close/read/write. `dispose` is idempotent after release; while Running it returns StillRunning and keeps ownership intact. After Reaped it closes all local streams, releases native registry links and retains the cached status/tombstone. After LostWait it closes local streams and reports WaitFailed once; repetition is Ok. Do not equate direct-child exit with owned-tree cleanup: descendants may hold pipes or outlive this child. `process_scope` must perform the next spike's terminateOwned protocol before disposing if it promises tree cleanup.

Launch uses a close-on-exec error pipe and async-signal-safe child setup. Parent receives a stage+errno for known setup/exec failures, reaps the failed child, closes every acquired fd, and returns SpawnFailed. Missing executable is Err, while a real program exit 127 is Ok (Some (Exited 127)). wait macros preserve exit 143 vs signal 15. Signalled's Bool is the platform WCOREDUMP flag, not a guessed exit-code translation. EOF on the exec error pipe is not worker-origin identity or application readiness: the child may already have exited or been signaled. Successful start produces an owned pid, not an attested ready worker. The portable experiment uses pipe/fcntl, which has no atomic close-on-exec creation guarantee against another native thread spawning concurrently; production must settle that race.

At preflight, reject SIGCHLD dispositions other than SIG_DFL and SA_NOCLDWAIT; do not change process-global state. An external thread/signal handler that starts reaping after preflight can still violate ownership; detect ECHILD and fail closed. The cooperative scheduler does not by itself grant exclusive native thread/signal ownership.

## Extern/ABI proposal

`stdlib/runtime.mdk` contains syscall signatures using core-only types, not ProcessError/SpawnOptions imports that create cycles:

```medaka-nocheck: future catalog signatures, not currently registered foreign declarations
extern processStartRaw : (program : String) -> List String -> String -> List (String, String) -> Int -> Int -> Int -> <Exec program> Result (Int, Int, String) (Process program)
extern processPollExitRaw : Process p -> <Exec p> Result (Int, Int, String) (Option (Int, Int, Bool))
extern processCloseStdinRaw : Process p -> <Exec p> Result (Int, Int, String) Unit
extern processDisposeRaw : Process p -> <Exec p> Result (Int, Int, String) Unit
```

Pipe flags: 0=Piped, 1=Null; reject any other value. Raw error tuple is (operation, errno-or-zero, diagnostic). Operation codes: 0=Validate, 1=Pipe, 2=Fork, 3=Chdir, 4=ExecImage, 5=Wait, 6=Close, 7=unsupported wait ownership, 8=closed, 9=still running, 10=unsupported engine. Raw exit tuple kind 0=Exited(code), 1=Signalled(signal, coreDumped); reject unknown status tags loudly in the wrapper. These are proposed production encodings; the scratch C error-pipe stage numbers are experimental and are not this ABI.

Native C symbols, each returning one Medaka word (Result containing the opaque word or boxed primitive tuples), with no foreign-call marshaling or public C FFI pointer exposure:

```c
int64_t mdk_process_start(int64_t program, int64_t argv, int64_t cwd,
                          int64_t env, int64_t in_mode, int64_t out_mode, int64_t err_mode);
int64_t mdk_process_poll_exit(int64_t process);
int64_t mdk_process_close_stdin(int64_t process);
int64_t mdk_process_dispose(int64_t process);
```

Use the shared runtime ABI's tagged scalar/Result/Option/tuple helpers; no duplicated ADT tag constants in medaka_process.c. Copy launch strings/argv/env into native-owned storage before retaining them; do not keep borrowed Medaka String interior pointers past the call. Error boxing occurs in the parent only. Raw extern options must validate independently of typed wrappers, because raw catalog functions are prelude-visible. No fd-accepting endpoint primitive is proposed. Readiness accessors and typed stream operations belong in the next I/O packet, with alias-close/reuse checks after every wake.

Native catalogs and lowering must enroll these four names together: extern_catalog, llvm_preamble, llvm lowering/disposition, tc runtime ABI generated rows and native runtime build/link/source-fingerprint/cache inputs. Existing unknown/unsupported eval, run and wasm engines must refuse capabilities explicitly. No stubs that return success. No claim that today's `medaka run` supports the operations.

## Measured controls

Linux spike at base `7a1d5e3fc02adbfd91102761bfc2a5c102783170`, 2026-11-03. The replay checks these outcomes and saves commands, actual stdout/stderr and return codes in its output directory. No binary or scratch-path transcript is required in the checkout.

| Experiment | Positive outcome | Discriminating control |
|---|---|---|
| Authority model | Wrapper, alias, list, Ref and existential each execute /bin/true and return 0 natively | Incompatible Exec bound, Ref reindexing, existential narrowing and foreign-forged opaque handle each reject with its diagnostic |
| Exec policy | Concrete entry accepted under Exec=/bin/true or Exec=/bin/* | Exec=/usr/bin/* and Stdout-only policies reject; generic p manifests remain unresolved, not narrowed |
| Explicit options | Literal cwd/env need Exec; sourcing SPIKE_ONLY additionally needs Env {SPIKE_ONLY} | Missing/different Env grant and an Env-erasing function annotation reject |
| Spawn status | Missing executable is SpawnFailed Exec ENOENT | Real exit 127 remains Exited 127; real exit 143 is distinct from Signalled 15 |
| Legacy comparison | runCommand still returns Ok 127 for missing executable and exit 127 | Exit 143 and SIGTERM both return Ok 143; no legacy behavior is silently changed |
| Aliasing | Repeated close shares closed state; disposed alias returns Closed; repeated dispose is Ok | Force a replacement fd into the old number; alias close leaves it open, while a stale raw close closes it |
| Wait ownership | Repeated terminal poll is cached; unrelated child remains waitable with exit 23 | SIGCHLD ignore refuses before fork; an external reaper causes ECHILD and pid invalidation |
| Lifetime | Running owner stays explicitly rooted across GC; finalizer calls=0; explicit disposal empties registry | Running disposal returns StillRunning; retaining aliases retains tombstone payload |
| cwd/env | Child prints /tmp\|explicit\|unset from explicit cwd/env | Missing cwd produces Chdir ENOENT; bare sh fails execve instead of searching PATH |

The C model asserts its outcomes and refuses to compile with NDEBUG. Its allocation comparison reports measured GC allocation separately from requested native table bytes; allocator overhead and exact collection timing differ. The observed 100000-owner allocation above is a receipt, not a fixed expected count. It does not exercise a working opaque producer, thread safety, full stdio plumbing, syscall fault injection, executable identity or descendant containment.

## Remaining prerequisites and failure controls

1. Re-inspect #4811/V0 at implementation base. At the measured base runtime/ contains only README.md and medaka_rt.c; there is no landed shared medaka_abi header or VM extern table. [INTERPRETER-DESIGN §4](INTERPRETER-DESIGN.md#4-the-abi-is-a-contract-v0) mandates that shared ABI next. Confirm an extern owner word's rooting/layout with the real VM and generic dispatch; the opaque-signature probe only proves type erasure and compiling unused handle operations. Consume the shared header/helpers when landed, or explicitly coordinate their extraction before runtime split. Do not invent a second ABI/header constant set.
2. Add catalog, typed wrapper, real producer and native lifecycle tests together under add-primitive. The spike cannot pass an inhabited opaque Process through a real catalog call; foreign-forge is deliberately refused. Require native end-to-end production tests of aliasing under allocation, closures/containers, cached status and shutdown. Keep the legacy runCommand/runCommandBatch semantics and tests unchanged: they still return synthetic 127 / 128+signal. No tree-wide existing test must move for this additive surface. If a later packet changes legacy behavior or grants, it needs its own whole-tree census; this spike does not license it.
3. Next readiness/containment spike must settle close-on-exec of all unrelated descriptors, standard-fd collision 0/1/2, pipe nonblocking behavior, descriptor wake reuse, bounded input sizes and spawn handshake deadlines, escaped descendants, cancellation and host containment authority. The C model proves none of those. It deliberately has only stdin/stdout pipes and writes tiny outputs.
4. Additional discriminating production controls: fault-inject pipe/dup2/fork/exec/write/close failures and assert exact stage+errno plus zero leaked fds/pids; signal child before exec; force EINTR and ECHILD; retain stale alias while closing/reusing fd; stub kill syscall to verify no attempt after terminal/lost-wait/disposed state and a reused pid never targeted; force GC during a scoped child lifetime and verify explicit termination/reap/disposal plus no finalizer dependence. The model already measures missing image vs exit 127, exit 143 vs SIGTERM, fd reuse, ECHILD from an external reaper and unrelated-child wait survival.
5. Linux only for these receipts. Atomic pipe creation, WCOREDUMP portability and real macOS lifecycle receipts remain #4820. #4413 owns eval/cwd/env policy, #4626 the high-level runner; neither closes from these primitives. D7 in INTERPRETER-DESIGN explicitly keeps Exec posture with #4414. No production supervisor implemented in Python; Python here only runs and records native probes.
