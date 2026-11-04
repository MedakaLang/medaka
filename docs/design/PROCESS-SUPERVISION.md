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

At preflight, require the SIGCHLD disposition to be SIG_DFL and require SA_NOCLDWAIT to be absent; do not change process-global state. An external thread/signal handler that starts reaping after preflight can still violate ownership; detect ECHILD and fail closed. The cooperative scheduler does not by itself grant exclusive native thread/signal ownership.

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
| Wait ownership | Repeated terminal poll is cached; unrelated child remains waitable with exit 23 | SIGCHLD ignore and SIG_DFL with SA_NOCLDWAIT refuse before fork; an external reaper causes ECHILD and pid invalidation |
| Lifetime | Running owner stays explicitly rooted across GC; finalizer calls=0; explicit disposal empties registry | Running disposal returns StillRunning; retaining aliases retains tombstone payload |
| cwd/env | Child prints /tmp\|explicit\|unset from explicit cwd/env | Missing cwd produces Chdir ENOENT; bare sh fails execve instead of searching PATH |

The C model asserts its outcomes and refuses to compile with NDEBUG. Its allocation comparison reports measured GC allocation separately from requested native table bytes; allocator overhead and exact collection timing differ. The observed 100000-owner allocation above is a receipt, not a fixed expected count. It does not exercise a working opaque producer, thread safety, full stdio plumbing, syscall fault injection, executable identity or descendant containment.

## Remaining prerequisites and failure controls

1. Re-inspect #4811/V0 at implementation base. At the measured base runtime/ contains only README.md and medaka_rt.c; there is no landed shared medaka_abi header or VM extern table. [INTERPRETER-DESIGN §4](INTERPRETER-DESIGN.md#4-the-abi-is-a-contract-v0) mandates that shared ABI next. Confirm an extern owner word's rooting/layout with the real VM and generic dispatch; the opaque-signature probe only proves type erasure and compiling unused handle operations. Consume the shared header/helpers when landed, or explicitly coordinate their extraction before runtime split. Do not invent a second ABI/header constant set.
2. Add catalog, typed wrapper, real producer and native lifecycle tests together under add-primitive. The spike cannot pass an inhabited opaque Process through a real catalog call; foreign-forge is deliberately refused. Require native end-to-end production tests of aliasing under allocation, closures/containers, cached status and shutdown. Keep the legacy runCommand/runCommandBatch semantics and tests unchanged: they still return synthetic 127 / 128+signal. No tree-wide existing test must move for this additive surface. If a later packet changes legacy behavior or grants, it needs its own whole-tree census; this spike does not license it.
3. The readiness/containment spike below measures pipe nonblocking behavior, descriptor reuse, cancellation and escaped-descendant failures. Native close-on-exec of unrelated descriptors, standard-fd collisions 0/1/2, bounded I/O integration, launch handshake deadlines and protected host containment remain prerequisites. The earlier C lifecycle model proves none of those; it has only stdin/stdout pipes and writes tiny outputs.
4. Additional discriminating production controls: fault-inject pipe/dup2/fork/exec/write/close failures and assert exact stage+errno plus zero leaked fds/pids; signal child before exec; force EINTR and ECHILD; retain stale alias while closing/reusing fd; stub kill syscall to verify no attempt after terminal/lost-wait/disposed state and a reused pid never targeted; force GC during a scoped child lifetime and verify explicit termination/reap/disposal plus no finalizer dependence. The model already measures missing image vs exit 127, exit 143 vs SIGTERM, fd reuse, ECHILD from an external reaper and unrelated-child wait survival.
5. Linux only for these receipts. Atomic pipe creation, WCOREDUMP portability and real macOS lifecycle receipts remain #4820. #4413 owns eval/cwd/env policy, #4626 the high-level runner; neither closes from these primitives. D7 in INTERPRETER-DESIGN explicitly keeps Exec posture with #4414. No production supervisor implemented in Python; Python here only runs and records native probes.

## Readiness and containment spike

Measured on Linux at `2fbb18b2594b7c8a8a229132766c3386822a2d16`, 2026-11-03.
The [readiness replay](../../scripts/mcp_bench/prototypes/process_readiness_probe.py)
uses the unchanged Medaka scheduler and independent
[POSIX/Linux reference](../../scripts/mcp_bench/prototypes/process_readiness_reference.py).
Replay after `make medaka`:

```sh
python3 scripts/mcp_bench/prototypes/process_readiness_probe.py --out /tmp/medaka-readiness
```

Python 3, clang (or `--cc`) and a fresh native `medaka` are required. Linux
descendant controls additionally need Python pidfd support and permitted
`PR_SET_CHILD_SUBREAPER`. `--root /absolute/checkout` selects another built tree.
All generated fixtures/binaries/JSON go outside the checkout; assertions must be
enabled. Every compiler invocation and native probe has `MEDAKA_STRICT=1`.
`results.json` saves commands, exit codes, stdout and stderr; `readiness.json`
saves independent control outcomes and capability blockers incrementally.

Exit 0 means the available reference assertions held, **not** that strong
containment works. The replay always records `strong_containment: BLOCKED`:
there is no implemented protected broker to test. Missing Linux facilities are
explicit `BLOCKED` rows. POSIX pipe/native scheduler controls can be replayed on
macOS, but no macOS receipt is claimed; Linux prctl/pidfd and the
[sigtimedwait reference](../../scripts/mcp_bench/prototypes/process_sigpipe.c)
are not portable containment/signal implementations.

| Control | Observed positive | Discriminating negative |
|---|---|---|
| Saturated pipe | Nonblocking short write; 20 heartbeat ticks in about 100ms, capacity 65536 bytes on this host | Blocking write makes no progress for 120ms |
| Duplex service | Concurrently send 131072 input bytes, drain matching stderr and stdout count | Input-first service stalls while child stderr is full |
| Exit/drain | Empty open pipe gives EAGAIN; HUP drains `last` before EOF | Direct-child death leaves a descendant-held pipe open |
| Descriptor reuse | Owner-generation model returns Closed before using reused fd | Raw retry consumes `UNRELATED` from replacement pipe |
| External cancellation | Self-pipe wakes idle data wait in about 41ms | No wake descriptor delays observation through 120ms poll |
| Native `ioPoll` | Idle/readable/HUP print `[0]`/`[1]`/`[3]` | HUP is a retry hint, not an EOF result |
| Native Async cancellation | `waitFlag` returns `cancelled` at 44ms | Omitting flag wait returns the same text at 229ms, only after deadline |
| Pipe SIGPIPE | Thread-local block/consume/restore returns EPIPE, preserves handler and preexisting pending SIGPIPE | Default-disposition write terminates with signal 13 |
| Stdio flags | Changing a dup's O_NONBLOCK changes the original | Dup does not isolate inherited open-file-description flags |
| Detached descendant | Explicit known pidfd cleanup succeeds; unrelated child remains waitable with exit 23 | Group kill and subreaper leave a setsid descendant alive |
| Caller death | Direct child dies under PDEATHSIG | Detached grandchild survives; signal setting is not inherited at fork |
| Authority | Missing-broker dispatch model refuses before callback; fake-token control reaches callback | Real protected-broker deployment proof remains blocked |

The generation model is not a real Process ABI test. The fake-token dispatch
control is not an OS containment positive. The ownership experiments retain
known unreaped children and use exact pidfds; they never scan all PIDs, reap
unrelated children or write a populated host cgroup's kill/procs files. Child
cleanup runs before the reference exits. Production owner/GC/ABI integration,
fault injection and native signal races remain unproven.

### Pipe adapters and scheduler integration

Keep `async.mdk` and runtime `ioPoll` as the sole scheduler/poller. Add bounded
try-read/write operations to the future `medaka_process.c`/`medaka_process.h` owner in runtime/,
with core-only signatures in `stdlib/runtime.mdk`:

```medaka-nocheck: proposed catalog additions, not registered extern declarations
processTryReadRaw : Process p -> Int -> Int -> <Exec p> Result (Int, Int, String) (Option ByteBlock)
processTryWriteRaw : Process p -> ByteBlock -> Int -> Int -> <Exec p> Result (Int, Int, String) (Option Int)
processStreamFdRaw : Process p -> Int -> <Exec p> Result (Int, Int, String) Int
```

Read stream code 1=stdout, 2=stderr; wait lookup additionally allows 0=stdin.
Write targets only stdin. Reject invalid stream codes, read limits outside
1..65536, and windows outside the actual ByteBlock before pointer arithmetic.
Each syscall transfers at most 65536 bytes. `None` means would-block; read
`Some` empty block means EOF; write `Some n` means partial or full progress.
A nonempty write returning zero is an error. Raw externs independently check
owner state and all input bounds; no primitive accepts a caller fd/pid.
Extend ProcessOperation with read/write/stream lookup operations and
ProcessError with invalid-I/O and stream-failure cases when implementing these
additions; do not report an I/O error as SpawnFailed. Allocate their raw codes
through the shared ABI contract rather than a second local constant set.

Only parent pipe ends become nonblocking; child standard streams remain
blocking. Linux pipe creation uses atomic close-on-exec setup. Standard-fd
collisions require relocation before dup2, and unrelated inherited descriptors
must close before exec. Neither this Python reference nor the earlier C model
proves those native launch mechanics. Pipe writes must surface EPIPE without
permanently replacing the host SIGPIPE handler. The Linux C reference validates
one thread's mask/pending-signal discipline, not every concurrent signal race.

An adapter checks cancellation and an absolute deadline before each bounded
syscall, yields between chunks even under continuous readiness, and retains
partial write offsets on every stop. Service input, output and stderr
concurrently with bounded consumer queues. Child exit and output EOF are
independent; neither EOF nor child exit alone proves owned-tree cleanup.

Park on stream readiness, cancellation flag, absolute deadline and a short
owner-recheck timer (proposed 10ms). After every wake, reacquire the fd through
the shared owner; a closed/disposed alias returns ProcessClosed before I/O.
The timer handles close/reuse where a replacement fd never becomes ready and
supports nonblocking direct-child polls without installing a global SIGCHLD
handler. Poll HUP/ERR/NVAL and EINTR remain retry hints. Concurrent native close
needs synchronization beyond this single-caller design.

Cancellation initially uses a monotonic cooperative Ref Bool plus `waitFlag`.
No task is dropped: `runAsync` drains spawned tasks, including cleanup. External
signals/threads require a durable flag plus nonblocking wake descriptor, like
the existing pds signal wake pattern, or an explicit bounded polling contract;
they cannot mutate an ordinary Medaka Ref from signal context.

### Proposed module boundaries

The following are proposed public exports, not implemented/typechecked APIs.
Deadline and CancelToken constructors are private. A Deadline wraps a real
`Wait e` produced by `after`, not an arbitrary caller-supplied wait whose
`expired` result could never become true.

```text
process_async.mdk (planned stdlib module)
  types: OutputStream = ChildStdout | ChildStderr
         Deadline (e : Effect), CancelToken
         ReadResult = Read Bytes | EndOfStream | ReadTimedOut | ReadCancelled
         WriteResult = Written Int | WriteTimedOut Int | WriteCancelled Int
  newCancelToken : Unit -> CancelToken
  cancel : CancelToken -> Unit
  cancelled : CancelToken -> Bool
  cancelWait : CancelToken -> Wait e
  after : Duration -> Async <Clock | e> (Deadline <Clock | e>)
  deadlineWait : Deadline e -> Wait e
  readUntil : Process p -> OutputStream -> Int ->
    Deadline <Clock, Exec p | e> -> CancelToken ->
    Async <Clock, Exec p | e> (Result ProcessError ReadResult)
  writeUntil : Process p -> Bytes -> Deadline <Clock, Exec p | e> -> CancelToken ->
    Async <Clock, Exec p | e> (Result (ProcessError, Int) WriteResult)

process_scope.mdk (planned stdlib module)
  types: Grace { terminate : Duration, killWait : Duration }
         CleanupResult = OwnedEmpty ExitStatus | CleanupTimedOut | CleanupFailed ProcessError
  startOwned : (program : String) -> SpawnOptions ->
    Deadline <Clock, Exec program | e> -> CancelToken ->
    Async <Clock, Exec program | e> (Result ProcessError (Process program))
  terminateOwned : Process p -> Grace -> Async <Clock, Exec p | e> CleanupResult

stdio_async.mdk (planned stdlib module)
  types: Stdio, StdioError
         ReadResult = Read Bytes | EndOfStream | ReadTimedOut | ReadCancelled
         WriteResult = Written Int | WriteTimedOut Int | WriteCancelled Int
  open : Unit -> <Stdin, Stdout> Result StdioError Stdio
  readUntil : Stdio -> Int -> Deadline <Clock, Stdin | e> -> CancelToken ->
    Async <Clock, Stdin | e> (Result StdioError ReadResult)
  writeUntil : Stdio -> Bytes -> Deadline <Clock, Stdout | e> -> CancelToken ->
    Async <Clock, Stdout | e> (Result (StdioError, Int) WriteResult)
  release : Stdio -> <Stdin, Stdout> Result StdioError Unit
```

`readUntil` returns one bounded chunk, not a frame or all output. Timeout/cancel
consumes no bytes in that read call. `writeUntil` attempts the entire Bytes
value and reports the committed prefix on timeout, cancel and real error;
retry never replays that prefix. MCP framing, JSON and UTF-8 limits belong to
the consumer. StdioError distinguishes unsupported endpoints/flags,
lease/buffering conflicts, closed leases and errno.

Import limits are acyclic and explicit: process_async imports process, async,
bytes and time; process_scope imports process, async, time and only Deadline,
CancelToken/cancelled/cancelWait/deadlineWait from process_async; stdio_async
imports async, bytes, time and those same shared token/deadline exports. No
compiler/tools imports, wildcard imports, or scope/stdio import from
process_async. Stdlib raw externs remain in the auto-prelude catalog. Stdio
operations require Stdin/Stdout, never an unrelated Exec grant.

### Launch and stdio prerequisites

`startOwned` needs a nonblocking launch handshake. A synchronous error-pipe read
inside `process.start` can indefinitely block a cooperative step. Before
implementing this adapter, amend the owner with a Launching state and explicit
begin/check/abort operations, or settle broker launch tickets. The concrete
ticket representation and broker/direct-child wait ownership remain
SPIKE-FIRST. Timeout/cancel must reap failed launch stubs and close all acquired
resources. This spike does not silently change the earlier synchronous API.

The first stdio boundary is an exclusive lease over already-nonblocking native
pipes intentionally supplied by a launcher, before buffered stdio begins.
Validate type/identity/flags; reject unsupported endpoints, regular files,
terminals, conflicting leases and prior buffered input. Never toggle arbitrary
inherited fd 0/1 flags: dup shares their open-file description. Release
invalidates all aliases without closing borrowed host descriptors or changing
their flags. The launcher must stop using its copies. A portable independent
stdio owner/relay is a separate unresolved design, not an implicit helper
thread or Python production supervisor.

An enforceable lease must cover legacy buffered paths: `mdk_read_line`,
`mdk_read_line_opt`, `mdk_read_exactly`, `mdk_read_all`, `mdk_putstr`,
`mdk_putstrln`, `mdk_flushstdout`, `mdk_byteblock_write_stdout`,
`mdk_print_str`/automatic main output and abort stdout flushing in
runtime/medaka_rt.c. Native output lowering is in llvm_emit.mdk/llvm_preamble.mdk.
Prevent read-ahead loss, mixed output and descriptor replacement; silent legacy
success/data loss after EAGAIN is unacceptable. Until that interlock or an
enforceable MCP-entry restriction is designed, stdio integration is blocked.

### Candidate Linux containment and blocked proof

The candidate is a Linux cgroup-v2 per-worker scope managed by a trusted
external broker/service. It is **not an established deployment**. Exec p gives
no cgroup/namespace privilege. Ordinary users need a host-provided protected
broker; an arbitrary login user's ability to create it is not assumed.

The measured host exposes cgroup2 read-only; creating a child of its own scope
fails EROFS=30. Attempting an ordinary-user receipt by dropping uid fails
EPERM=1 in this sandbox, so ordinary-user availability remains blocked. A
writable cgroup alone would not suffice: worker access to a destination
cgroup.procs, inherited management fd, broker memory/ptrace or namespace/mount
authority can permit escape. Require inaccessible broker management authority,
including protection from `/proc` fd theft and ambient capabilities; a separate
service identity and controlled namespaces are a candidate deployment to test.

Validate the broker/protocol/delegation, private empty domain, required
kill/events operations and anti-migration policy **before target spawn**.
Attach a trusted gated stub before it can exec/fork, or validate an atomic
clone-into-cgroup mechanism. No arbitrary caller pid/cgroup path is accepted.
Basic process.start handles have no strong scope; terminateOwned must refuse
them without signaling. Missing/unsupported containment returns Unsupported
before the target executes; it must not fall back to process groups.

Cleanup closes admission, requests cooperative shutdown and/or signals only
the pinned owned leader for grace, then uses the owned subtree's cgroup.kill
when necessary. Wait under a deadline for cgroup.events populated=0 and direct
child reap/status before OwnedEmpty. No unbounded PID enumeration is proposed.
Retain ownership on error/timeout; do not dispose or report success. Even
SIGKILL can be delayed by uninterruptible kernel I/O, so bounded completion is
not promised; CleanupTimedOut is a real result. Cleanup ignores user
cancellation after admission stops and uses its own finite deadlines.

Cgroup membership alone does nothing when Medaka dies. The broker must outlive
its caller, observe loss of an authenticated lease/connection and clean the
scope; its service manager must cover broker death. PDEATHSIG and a subreaper
do not replace this. If broker and service manager both die, the machine fails
or kernel exit stalls, bounded cleanup cannot be promised.

Required positive follow-up on an actual protected delegated host: fork/setsid/
double-fork/repeated-fork target; denied migration and management-fd theft;
unrelated sibling child surviving with exit 23; admission/kill race; caller
SIGKILL followed by broker cleanup; broker SIGKILL followed by manager cleanup;
populated=0 and no orphaned target. Refused preflight must also have an external
target-not-executed marker. Every missing authority row remains blocked or
Unsupported, never a successful lifecycle row.

macOS has no cgroup-v2 boundary. A distinct host-provided service/sandbox design
and real #4820 receipts are required; POSIX process groups are not a substitute.
Until then, strong startOwned/terminateOwned must refuse before target spawn.
Ordinary direct-child operations may be separate but carry no owned-tree claim.

### Implementation order

1. Consume the real shared VM/runtime ABI and settle Launching/begin/check/abort
   representation and wait ownership; amend the process contract explicitly.
2. Implement the lifecycle owner plus nonblocking parent pipes and bounded I/O
   together; enroll catalog, raw signatures, preamble/lowering, refusal engines,
   runtime linking and source-fingerprint inputs as one coherent addition.
3. Add process_async over the existing scheduler; prove native alias-close/fd
   reuse after wake, sustained-ready deadlines/cancel, partial progress,
   EINTR/EPIPE, bounds and GC between wake and retry.
4. Settle/enforce the launcher/stdio lease discipline and legacy interlock before
   stdio_async; test read-ahead, output mixing, fd replacement and signal coexistence.
5. Obtain the protected broker deployment and pass the positive containment/
   death/migration matrix before process_scope production acceptance.

No new runtime primitive, opaque carrier or production supervisor is implemented
by these experiments. None of the old lifecycle, VM ABI, eval or macOS
obligations closes from these Linux readiness controls.
