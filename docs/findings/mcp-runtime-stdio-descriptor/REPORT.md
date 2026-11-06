# Descriptor-first experiment: shared type policy blocks Null streams

The experimental shared content-open hook is **unqualified**. It preserves the
measured regular source/config reads, telemetry, scratch contents and piped
worker submission, but its type restriction also reaches the real process
owner's `/dev/null` opens. Null-mode worker creation fails with `SpawnFailed
Pipe`, errno 22. Disabling only that restriction restores worker execution,
the external marker and successful reap/disposal. This is a placement and
type-policy incompatibility of this candidate; it does not establish that a
narrower stdio boundary is impossible. No production runtime or compiler entry
was changed, and no parent issue or stdio milestone is closed by this receipt.

Replay with Linux, Python, clang and Boehm development files, using absolute
paths and a new external output directory:

```sh
python3 /absolute/checkout/scripts/mcp_bench/prototypes/stdio_descriptor_probe.py --root /absolute/checkout --out /new/external/descriptor-receipt
```

Expected exit is **77**, with `qualification: BLOCKED`. Exit 1 is an assertion,
build or observer failure. Other platforms return unavailable before compiling.
A successful build or file-family control is not a qualified authority boundary.
The [summary](summary.json) pins the observed source, generated runtime patches,
commands, environment, raw results and selected independent controls.

## What was exercised

The observer generates copies of `runtime/medaka_rt.c` and
`runtime/medaka_process.c` in external scratch. It redirects their lexical
`open`/`fopen` calls to the native fixture's descriptor hooks. Production runtime
sources remain unchanged; the generated unified patches and their SHA-256s are
retained. The runtime includes 3 executable `open` sites and 6 executable
`fopen` sites; lexical replacement counts also include comments. The owner has
one executable `open` site, in `construct_native` at
`runtime/medaka_process.c:242`. Existing `MDK_CONFINE` calls remain in the
transformed runtime; this does not establish stronger path confinement or
resolve #4223.

The test launcher supplies distinct nonblocking anonymous pipes and separate
stderr. Acquisition checks pipefs identity, directions and flags, and pins both
endpoints with close-on-exec duplicates. Those checks have no independent
mutation matrix here and are not qualified. The content hook opens nonblocking
without `O_TRUNC`, checks the opened descriptor against both pinned endpoint
identities, then applies truncation and uses that same descriptor. It permits
regular files and unrelated FIFOs and rejects other types. General special-file
semantics and FIFO/no-progress behavior remain unsupported.

The fixture calls the transformed runtime functions, including all nine file
families: string read, hash, byte read, string write, append, telemetry append,
byte write, mode-setting write and fsync. This exercises actual experimental
runtime hooks rather than advisory policy checking. It is still a C entry:
**compiled Medaka entry enforcement was not exercised and is unqualified**.

| Observation | Independent bytes or effect |
|---|---|
| Real `stdlib/core.mdk` and `compiler/medaka.toml` reads | Returned bytes exactly equal the current files (82,767 and 716 bytes) |
| Scratch creation/write, byte write and mode write | Exact `BYTES\n`, raw `ff0052`, and mode 0600 |
| Append and telemetry append | Exact `EVENT\nBYTES\n` |
| Both endpoints × proc/dev/symlink aliases × nine families | 72 refusals; original output empty; all input `00ff41c3285a` remains |
| Only identity check disabled, output append | Original output `42595445530a` (`BYTES\n`) |
| Only identity check disabled, input hash | All six original input bytes consumed |
| Real owner, Piped streams | External empty marker exists, exit 0, disposed, worker PID absent |
| Real owner, Null streams | External marker absent, type refusal for character device, Pipe errno 22, no owner roots remain |
| Only type restriction disabled, Null streams | External empty marker exists, exit 0, disposed, worker PID absent |

The type mutation leaves endpoint identity checks enabled. It demonstrates the
cause of the compatibility failure, not a complete security mutation suite.
The observer does not infer effects from `Ok` alone: it reads original pipe
endpoints and external marker/content files. The non-UTF-8 input was fully queued before launch; this does not demonstrate fragmented arrival. The launch-error report identifies
the failing runtime operation. Failed Null construction creates no child; the
owner's failed ticket leaves zero roots. Successful workers exit 0, are disposed
and leave zero roots; their recorded PIDs are absent after the fixture exits.
All 85 fixture processes were waited. Observer fds and fixture endpoint pins
were closed, and private request/telemetry/marker files were removed. Raw
receipts, patches and symlinks remain in external scratch. Error/time-out paths
report incomplete ownership rather than claiming cleanup; they do not qualify
owned-tree cleanup.

Measured identity was uid/euid 0, effective capabilities zero, NoNewPrivs 1.
The candidate does not establish non-dumpability. Parent-fd reopening,
privileged tracers and hostile external descriptor holders remain unqualified;
the identity receipt is not an ordinary-user deployment claim.

## Matrix rows still unsupported

| Required row | Disposition |
|---|---|
| Path swaps; fd replacement/reuse and lifetimes | No concurrent barrier/race test |
| Wrong endpoint types/flags/shared identities/stderr | No negative endpoint matrix or individual disabling mutations |
| Open/stat/identity failure injection and truncation ordering | No injected failure/order control; source ordering alone is insufficient |
| Directory fsync and other special files | Not qualified; the shared type restriction also excludes directories |
| Acquisition, release/reacquisition, prior/in-flight use | No admission/history synchronization implemented |
| Resolver/NSS, HOSTALIASES on Err and resolver races | All four routes remain uninterlocked |
| Legacy launch and buffered/raw/automatic/abort/stash/flush output | Remain uninterlocked |
| Parent-fd reopen and dumpability | No enforcement or disabling control |
| Fragmented arrival across consumer reads | Input was queued before process launch; staggered arrival is unqualified |
| Backpressure, blocking/no-progress, deadline/cancellation, prefix/no replay | No transport implementation/control |
| Compiled Medaka entry; whole-tree semantic compatibility | Unqualified; survey lexical candidates remain unknown |

Every unsupported row blocks positive qualification. The script always reports
77 for this measured candidate; it cannot return 0 as a qualified boundary.
The old blanket content seal remains a separate rejected experiment in
`docs/findings/mcp-runtime-authority/STDIO.md`.

The next experimental cut should define provenance for trusted process-owner
stream setup, separately from caller-controlled file-content opens, and measure
that distinction through real owner launches. A pathname exception for
`/dev/null` in the caller's content policy would not establish that distinction.
It must then implement and attack the unsupported rows above before any
production Stdio extern, compiler admission path or protocol-owner split is
proposed as an accepted implementation.

## Durable replay and handoff

`test/process_authority_test.mdk` runs the independent descriptor observer alongside
the separate 03a broad-seal and ownership receipts. It requires the independently specified endpoint/alias/operation identity set
without duplicates, the Null blocker, the Piped control, and both identity and type
mutation effects. It exercises non-Linux refusal and rejects an empty matrix.
These controls do not fill the unsupported rows above. The census receipt in the summary pins the fresh lexical inventory and its C1–C7 counts; these are not semantic compatibility counts. Dynamic uses remain unknown. The report and summary are excluded from the inventory to avoid a self-referential receipt; all other Git-visible carriers are scanned. The gate compares the complete fresh census digest, including unknown classifications, with that receipt.

A future production cut must define acquisition and release, aliases, and errors
that retain ownership; share the existing Async, Deadline and CancelToken types
with process_async; and establish compiler/runtime enforcement. Owned-tree
deployment still requires an operator-supplied protected manager and delegated
disposable cgroup. Parent issues #4854, #4855 and #4856 remain open.
