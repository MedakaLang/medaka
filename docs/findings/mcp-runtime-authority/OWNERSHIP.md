# Ownership authority experiment

Measured 2026-11-05 against base `fa83e1594a01210a17d771fb71105bedc03e1055`.
The [compact receipt](ownership-summary.json) pins both experiment source hashes.
This is a blocked deployment result. No production ownership API is authorized.

## Replay and result

Build the tree with `make medaka`, then use an absolute checkout root and a new
output directory outside that checkout:

```sh
python3 /absolute/checkout/scripts/mcp_bench/prototypes/ownership_probe.py --root /absolute/checkout --out /tmp/ownership-new
python3 /absolute/checkout/scripts/mcp_bench/prototypes/ownership_probe.py --root /absolute/checkout --out /tmp/ownership-local-new --refusal-only
```

Requirements: Python 3, clang or `--cc`, a C11/POSIX build environment and a
writable external output directory. Linux adds `/proc`, Unix seqpacket sockets,
fork/exec/wait and `/dev/urandom` for local wire controls. Sender authentication
additionally requires permitted `SO_PASSCRED`/`SCM_CREDENTIALS`. Other platforms
can exercise the explicit refusal/marker control; their Linux protocol rows
are unavailable. No macOS receipt is claimed.

Each invocation writes commands, exit codes, exact stdout/stderr, effective
identity, namespaces, cgroup membership/mount and source hashes to
`ownership.json`. No generated binary or raw receipt goes in the checkout.
The CLI exits **77** when deployment is unavailable and **1** for a failed
control. It has no positive deployment backend: it cannot currently return 0.
A future backend may return 0 only after every deployment qualification row
has actually executed and passed. Existing output directories are rejected to
prevent stale execution markers from satisfying controls.

| Prerequisite | Measurement | Consequence |
|---|---|---|
| Disposable cgroup domain | cgroup2 mount `/sys/fs/cgroup` is read-only; unique child `mkdir` returns EROFS=30 | No scope created, attachment/kill/events proof unavailable |
| Ordinary supervisor identity | uid/euid/gid 0; effective/permitted/ambient/bounding capabilities all zero; NoNewPrivs=1; seccomp mode 2 | Root identity supplies no ordinary-client receipt |
| Separate target identity | Child `setresuid(65534,65534,65534)` returns -1/EINVAL=22 | Identity separation could not be exercised; exact syscall result is retained without attributing its cause |
| Credential-authenticated channel | `setsockopt(SO_PASSCRED)` returns EPERM=1 | Foreign-peer rejection is unavailable; token-only model is not authenticated authority |
| Protected external manager | No manager/delegated-parent configuration supplied | No caller/broker death recovery or launch ownership transfer exists to test |

The mount/namespace inventory describes the probe's namespace, not a claim
about the machine outside it. The probe attempts only one unique child mkdir
under a read-only mount. On a writable mount it refuses without an explicitly
delegated parent. It writes no existing cgroup control file, installs no host
service and grants no privilege.

## What the local controls prove

The native fixture is an independent OS experiment with one external interface,
`main`. Its broker is a forked local wire-state model. Its manager role is the
fixture parent, which waits only on exact children it created. It imports no
Medaka compiler implementation and implements no scheduler.

| Control | Observed external effect / assertion |
|---|---|
| Pre-spawn refusal | Fixture returns 77; external `refused-target.marker` is absent |
| Marker negative control | Explicit target invocation writes exactly `65786563757465640a` (`executed` plus newline) |
| Missing authority | RESERVE rejected; no target marker |
| Stale generation / foreign token | RESERVE and COMMIT rejected; no markers |
| Foreign sender | UNAVAILABLE on this host because credential setup fails; no authentication success claimed |
| Token replay | First commit execs target once; repeated commit rejected; marker bytes remain exactly one execution |
| Exhausted capacity | Second reservation rejected while first reservation is retained; no target marker |
| Admission/stop ordering | Inject STOP after RESERVE and before COMMIT; commit rejected and no target marker |
| Channel loss | Close channel after RESERVE; broker exits and is reaped; no target marker |
| Cleanup timeout/error state | After a committed target, injected TIMEOUT retains model ownership; RELEASE rejected and capacity stays occupied |
| Admitted control | Accepted local reservation/commit execs the same target marker path |
| Unrelated child | Exact separate child remains waitable with exit 23 |
| Local cleanup | Every fixture-created child reaped; all local channels closed by process exit; no scope created |

The admission/stop control is a deterministic protocol ordering, not a measured
kernel admission/kill race. TIMEOUT is an injected wire-state result after the
local direct target has already been reaped, not an uninterruptible-kernel or
cgroup cleanup experiment. Token material comes from `/dev/urandom`; a token is
bound to one broker instance and one generation. The model neither survives
manager death nor implements restart persistence. Same-uid memory/fd isolation
is unproved even on a host that permits credential delivery.

Two exploratory fixture attempts stopped on denied credential/socket syscalls
before the complete local protocol ran. Their original parent did not record
broker reap, so their cleanup status is incomplete/unknown. They created no
cgroup and are excluded from the successful replay receipt. The final full,
refusal-only and independent replays each recorded exact child reap.

The independent Python observer checks marker bytes/absence after native exit,
as well as the complete named local row list. A token-only fallback runs only
these explicitly local controls. It leaves credential authentication and every
deployment row unqualified. All 19 deployment rows are emitted individually:
ordinary client, pre-exec attachment, fork/setsid/double-fork/repeated-fork,
migration/fd theft, unrelated child under containment, caller/broker death,
manager recovery, admission race, channel loss, stale/foreign token, replay,
capacity, populated-zero plus direct reap, and retained cleanup authority.

## Boundary decision and next prerequisite

No executable protected ownership/death boundary is available in this
environment. A writable delegated cgroup alone would not settle target
migration, management-fd theft, same-identity broker access or manager death.
No production `Scope`/`Process` extern or launch transfer is specified by this
experiment. #4855 retains its full cleanup acceptance.

The next deployment experiment needs a host operator to supply an explicitly
delegated disposable cgroup-v2 parent and a protected long-lived manager under
an identity/namespace boundary inaccessible to the worker. That manager must
retain scope creation, pre-exec attachment, kill/events descriptors and launch
ownership before acknowledging admission. A broker may mediate authenticated
client leases, but must not be the only keeper of cleanup authority. Manager
recovery after broker death must execute on the real deployment; restart
ownership recovery remains SPIKE-FIRST. No installation or privilege grant is
part of this replay.

The manager would be the direct parent of a target it forks. A wire lease from
that arrangement cannot become an existing native `Process` whose wait owner
is the Medaka caller. The next implementation cut must keep broker ownership
and direct-child `Process` status/reap separate, preserve the existing runtime
owner, and define their transfer only after the deployment experiment passes.
Cleanup success still requires both `cgroup.events populated=0` and the actual
direct parent's terminal status/reap. Timeout/error must retain authority.

Before a positive receipt, run the full deployment matrix under an ordinary
client, including denied migration/fd theft and caller/broker death, with an
unrelated child exiting 23. Supply independent external effects for each row.
Until then production owned-tree launch must refuse before target execution.
