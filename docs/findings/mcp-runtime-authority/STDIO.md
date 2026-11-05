# Stdio authority: runtime-seal blocker

The narrow runtime-seal candidate is **refused for supervisor compatibility**.
It can reject the measured direct and indirect routes before their effects,
but also rejects required source/config reads, telemetry and scratch content.
No stdio policy qualifies from this experiment. #4854 remains open; this is
evidence for its next cut, not an implementation of a lease or MCP entry.

Replay from any cwd, with a fresh external output directory:

```sh
python3 /absolute/checkout/scripts/mcp_bench/prototypes/stdio_authority_probe.py --root /absolute/checkout --out /new/external/receipt-directory
```

Expected exit is **77**, with a final `qualification: BLOCKED` row. A missing
prerequisite or a failed control never means qualified. `results.json` records
every byte observation, command and source SHA256; `compatibility-census.json`
records every scanned path, source hash, numbered rule and line/token hit.
The committed [summary](stdio-summary.json) records the measured base and
source pins. Linux, clang, Python and Boehm development files are needed for
the full replay. Other platforms explicitly return unavailable before compiling
the Linux fixture. No shell harness or production Python relay is introduced.

## Candidate and measured compatibility

The independent C fixture includes the real `medaka_rt.c` and links the real
`medaka_process.c`; its private admission wrappers are a **model**, not runtime
hooks. It requires distinct anonymous pipefs input/output, correct directions
and nonblocking flags, distinct stderr and `NoNewPrivs=1`, then sets parent
dumpability to zero. The measured identity was uid/euid 0, effective capabilities
zero, NoNewPrivs 1. This is not an ordinary-user deployment receipt or protection
against CAP_SYS_PTRACE. The separate ownership experiment remains unqualified.

Before first acquisition, attempted content I/O, resolver calls and launches
record sticky prior use. In-flight work retains admission even after a model
cancellation request. After first acquisition, release/reacquisition retains
restrictions and non-dumpability. Native Process submissions after acquisition
remain available; they use the existing owner, fresh child stdio and real
submission worker. No scheduling or Process implementation is duplicated.

| Rule | Candidate restriction | Test carrier files with lexical candidates |
|---|---|---:|
| C1 | Reject pathname content I/O forever after first acquisition | 242 |
| C2 | Reject libc resolver entry forever after first acquisition | 33 |
| C3 | Reject legacy launch forever; prior launch attempts prevent acquisition | 44 |
| C4 | Reject legacy protocol input/output before buffering or transfer | 3291 |
| C5 | Native launch attempts before acquisition prevent acquisition | 12 |
| C6 | Audit automatic main output and abort paths separately from effects | 4181 |

The census was replayed at `f114a7a5223afc09b0bddcb3114521714b965e75`
with the byte-preserving probe readability edit pinned in the summary. It covers 6620 tracked `test/**` carriers, including 1024 host/prose/
template files scanned in full to include inline programs. The overlapping
counts are lexical candidates, including comments and strings; they are not
counts of executable programs or promised compatibility breaks. 2339 carriers
have no lexical trigger. Derived golden/oracle/config artifacts are excluded
by suffix and their counts are recorded. No test source or production behavior
changed. A production cut needs semantic classification of the affected uses;
this overapproximation must not be described as an admitted-program inventory.

| Representative supervisor operation | Sealed candidate | Unsealed control |
|---|---|---|
| Read real stdlib source and compiler config | Refused before open | Succeeds |
| Select an executable clang path using metadata | Succeeds | Succeeds |
| Append regular-file telemetry | Refused; no file created | Exact `EVENT\n` |
| Create scratch directory | Succeeds | Succeeds |
| Write scratch request content | Refused; request absent | Succeeds |
| Submit native worker, observe marker, reap/dispose | Succeeds | Succeeds |

These are representative operations, not an installed supervisor. Moving all
filesystem work into another authority would change the supervisor's design;
this experiment does not silently make that change.

## Byte and authority controls

The Python launcher supplies pipe bytes in two-byte writes, retains an observer
copy without using it during execution, and inspects remaining input and the
original output endpoint after the exact child has terminated. Test reports
use a separate inherited descriptor. No UTF-8 decoding or successful Result is
used as the oracle for protocol transfer.

| Control | Original endpoint / side effect |
|---|---|
| Proc/dev/symlink content writes, seal active | Empty output; input `00ff41c3285a` intact |
| Same guards disabled, parent still non-dumpable | Output `425950415353` (`BYPASS`) |
| Proc/dev/symlink input hash, seal active | Exact original raw bytes remain |
| Same guards disabled | All six raw bytes consumed |
| Descriptor replacement after acquisition | Identity mismatch; no endpoint/replacement bytes written |
| Replacement check disabled | Replacement file contains `REPLACED`; original endpoint stays empty |
| Fresh-stdio exec child opening parent fd1, parent dumpable=0 | Child exit 13; output empty |
| Parent protection disabled | Child exit 0; original endpoint `4348494c44` (`CHILD`) |
| HOSTALIASES absent, real resolver Err | All 21 bytes remain |
| HOSTALIASES=/proc/self/fd/0, real resolver Err | All 21 bytes consumed, including under non-dumpability when resolver guard is disabled |
| Resolver guard active | Original 21 bytes remain |
| Active/post-release legacy launch guard | External marker absent |
| Legacy guard disabled | External marker exact `launched` |
| Buffered line read guard / disabled | Both lines remain / both consumed by read-ahead |
| Buffered/raw/automatic/abort output guards | Empty original output |
| Those guards disabled | `BUFFERED` / `ff0052` / `370a` / `STASH`, respectively |

The fresh-stdio child replaces fd0/1/2 with `/dev/null` and execs before opening
the parent path. It does not merely inherit stdout. Parent non-dumpability
protects this worker route; it does not restrict supervisor self-access.
No cgroup membership is used to infer descriptor or same-process libc safety.
Named endpoints, privileged tracers and preexisting descriptor holders are not
qualified by these controls. The fixture does not implement lease generations,
catalog admission or backpressure.

History controls execute real file/resolver/legacy/native operations before
the first acquisition. File/resolver/legacy in-flight threads are held after
candidate admission and before calling the runtime; they do not prove kernel
syscall cancellation. The native row additionally holds a real accepted
submission in the runtime's existing test seam before process creation. Busy
persists after a model cancellation request, and completion yields sticky
PriorUse. Removing the history or active guard admits acquisition. Every child
in the completed runs was waited; native owners reached reap/dispose, gates and
threads joined, and private scratch directories were removed. Timeout/error
paths fail the experiment and must not be read as cleanup success.

## Entry admission and remaining prerequisite

A compiled Net-only source passes real `check-policy --allow Net=leasealias`,
then consumes all HOSTALIASES input under ordinary native build. Removing its
Net grant rejects in the policy checker. A pure `main = 7` passes policy analysis
and emits `7\n` automatically. Thus effects alone do not describe output lowering,
and the standalone policy command is not a native build/entry enforcement path.
No admission-only candidate is qualified here.

#4865 is reproduced with its actual primitives: ordinary check accepts both
`stashRunStdout` and `enableRunStdoutFlush`; `--allow-internal` also accepts.
The combined unprivileged program arms the stash, appends `EXPOSED`, then panics;
native exit 1 emits exact `4558504f534544` on stdout and E-PANIC on stderr.
By contrast, `byteBlockWriteStdout` is rejected as internal-only ordinarily,
accepted with the override and emits exact `RAW`. These observations preserve
the open defect rather than treating its current acceptance as a security rule.

The witnessed blocker is precise: **the all-content-openers runtime seal cannot
coexist with the supervisor's required filesystem work**. This does not prove
every narrower policy impossible. The next stdio cut must measure a shared
descriptor-first identity check for the complete file-content family while
preserving unrelated source/config/telemetry/scratch operations, separately
bound libc resolver/NSS input, interlock all buffering/automatic/abort routes,
and enforce any selected entry restriction through the actual launch path.
Alternatively it must explicitly recut the protocol-owner/workspace authority
split and measure that boundary. Neither alternative has a positive receipt
here, and neither authorizes placeholder externs or a production Stdio API.
