# Private worker boundary, version 1

This is a prototype contract, not a production service or an implementation of
MCP. `scripts/mcp_bench/prototypes/protocol.json` is its vocabulary and
`protocol.py` validates complete serial transcripts. Messages are UTF-8 JSON
objects, one per line. A private version is independent of the MCP version
negotiated by an adapter; neither can substitute for the other.

The supervisor exports these conceptual operations:

- `openWorkspace(Config)->WorkspaceId` creates an opaque workspace handle bound
  to the requested root and configuration. Distinct workspaces must not alias;
  path strings alone are not a snapshot or proof of identity.
- `status(id)->Status` reports readiness, capabilities, identity provenance,
  active worker and failures, including unavailable identity.
- `request(Context,Operation)->Result` sends a serial request against the
  indicated workspace, snapshot, profile and toolchain. The result is explicitly
  complete, partial, or error; partial is never silently promoted to complete.
- `replaceWorker(id,Artifact)->Status` stages a candidate, verifies its artifact
  and starts and negotiates it before switching. The current in-flight request
  finishes before switching. A failed verification, start or negotiation retains
  the old worker and reports failure. After a successful atomic switch, later
  requests use the new worker; the old worker is closed and reaped. If the old
  worker itself has failed, report unavailable rather than claim it is usable.

## Messages and identities

The supervisor starts with `{"type":"initialize","versions":[1]}`. The
worker replies `initialized` with `version`, a list of capability names,
`worker` identifier and null `error`. The selected private version must occur
in the offer and be supported by both sides. No intersection requires an
`initialized` refusal with null version and worker, empty capabilities and a
nonempty error; the session ends. No operation may precede initialization.

A `request` carries a nonempty session-unique string `id`, a `context`, and an
`operation` object with `name` and object `arguments`. Context has exactly
`workspace`, `toolchain`, `snapshot`, and `profile`. Each is an object with
`value` and `provenance`: `attested`, `inferred`, or `unavailable`. Unavailable
requires null value; other values are nonempty strings. The `response` echoes
`id`, includes `status` (`complete`, `partial`, or `error`), and has a non-null
`result` and null `error` for complete/partial, or null `result` and a nonempty
error for error. Partial is a terminal response for that request; subsequent
work needs a new ID. IDs are never reused in a session, including replacements.

A successful `openWorkspace` request establishes a workspace in the session;
failed opens do not. Its complete result contains the active `worker` identifier. A `replace` has `id`, an explicit existing `workspace`, and `artifact` with nonempty `id` and `digest` strings.
The terminal `replacement` echoes the request ID and workspace and has `status` `switched`
with the candidate worker ID and null error, or `failed` with the old worker ID
and nonempty error. These are lifecycle assertions; the pure transcript validator
cannot verify file bytes, process state or atomicity. `shutdown` closes an idle
session. Malformed, unexpected, duplicate or out-of-order messages are refused;
a worker crash makes an outstanding request an error at the supervisor, never a
successful result. A session may have at most one request or replacement in
flight.

An attested value must originate from the running worker through a trustworthy
identity mechanism, with the mechanism and trust assumptions established by
its implementation. Merely labeling a value attested does not make it so: the
pure validator validates shape, not provenance truth. The current `medaka mcp`
initialize response contains a generic product version, not an attested compiler
fingerprint (`compiler/tools/mcp.mdk:340-353`). A supervisor's artifact hash or
source revision is inferred, not attested, and a pre-execution hash alone does
not prove which bytes ran. Matching-mode claims require actual worker attestation
and are unavailable with the current worker. Baseline semantic delegation must
be labeled as such; it does not validate edits against a matching compiler.
Snapshot and profile identity must change when their relevant inputs change;
the prototype must define and test the concrete representation before caching.

## Initial Linux feasibility spike

The 2026-11-03 spike at base `3887869bb140c000ed184beb7af2f000af4bbd86`
used `python3 /var/tmp/medaka-scratch/sprints/mcp-m0-20261102/03-packaging/evidence/boundary/probe.py`.
Python `subprocess.Popen` drove the real worktree binary through live pipes in
a temporary working directory with no local binary: MCP initialize returned
`2024-11-05`, a valid arithmetic check had no diagnostics, and a string-plus-int
check returned `T-NO-IMPL`. Missing and corrupt executables produced errno 2 and
8, a failing child exited 7, and a SHA-256 changed after file contents changed.
These are primitive controls, not a test of installed bundles, offline isolation,
identity, or live replacement.

A native Medaka probe called `runCommand "sh" ["-c", "printf ready; sleep 2"]`;
`timeout 1` exited 124 without output. `stdlib/runtime.mdk:206` exposes a
synchronous result and `runtime/medaka_rt.c:3323-3446` waits before reading
captured output. This API alone cannot supervise a live bidirectional worker.
If the installed Medaka candidate cannot satisfy mandatory live lifecycle
without a host shim, disqualify it; this observation does not rule out every
possible OS technique. No shim is authorized by this contract.

The following table records the initial spike only; the later installed-candidate
results and decision are in the [Linux decision report](../findings/mcp-m0-packaging/REPORT.md).

| Checklist | Python stdlib candidate | Installed Medaka candidate |
| --- | --- | --- |
| Handshake without local binary | Worktree worker probe succeeded; installed/offline case unmeasured | Unmeasured |
| Installed docs/status | Unmeasured | Unmeasured |
| Baseline semantic delegation | Worktree worker diagnostic controls succeeded; installed baseline unmeasured | Unmeasured |
| Workspace identity | Unmeasured | Unmeasured |
| Artifact change and replacement | Hash-change primitive only; replacement unmeasured | Unmeasured |
| Missing/corrupt artifact and failed worker | Process primitives observed; candidate handling unmeasured | Unmeasured |

The subsequent installed-candidate experiment exercised A/B/A routing, connected
replacement, failure controls, cleanup and offline isolation; its limits and
remaining checks are in the decision report. The earlier baseline budgets and provenance are in
`scripts/mcp_bench/budgets.json` and `docs/findings/mcp-m0-baseline/OPERATIONS.md`;
they are not installed-candidate results. macOS is deferred to #4820 and has
not passed this experiment.

## Decision status

The [Linux decision report](../findings/mcp-m0-packaging/REPORT.md) disqualifies
both measured prototypes under the mandatory lifecycle and correctness criteria.
This version 1 vocabulary remains an experimental contract, not a selected M1
interface or proof of implementation. The report specifies a bounded follow-up;
#4770 remains open and actual macOS evidence is deferred to #4820. Existing MCP
clients and wrapper behavior remain in place until a documented compatible
migration is implemented.

The Python prototype validates JSON-RPC envelopes and MCP tool-result shape, but a protocol-conformant worker can still lie about semantics. It terminates the worker process group on replacement or shutdown, including when the direct worker has exited. Detached descendants and process-group escape remain unresolved; this is not total containment. Duplicate canonical roots are rejected, but complete workspace identity remains unavailable.
