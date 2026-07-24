# MCP.md — `medaka mcp`, the LSP-for-agents

**Status:** IMPLEMENTED — 58d050a7, 2026-07-16 (7 tools); `medaka_references`
added #870/#912. All 8 tools shipped and merged (#246/#247/#249/#250/#251/
#252/#255/#870/#912), protocol-version negotiation in place, verified READY
against the real MCP SDK. This doc covers wiring it into the Medaka repo for
coding agents (`.mcp.json` + `.claude/settings.json` +
`scripts/medaka-mcp-wrapper.sh`) and how to use it.

---

## 1. What it is

`medaka mcp` is an MCP (Model Context Protocol) server that talks JSON-RPC 2.0
over stdio — one newline-delimited JSON object per message, exactly the shape
`compiler/tools/mcp.mdk` implements. It exposes the compiler's own
checks/queries to coding agents: think of it as an LSP, but shaped for an
agent's tool-call loop instead of an editor's request/notification loop. It
negotiates the client's requested protocol version (falling back to the
newest it knows) and advertises 8 tools via `tools/list`.

**Prefer these over grep/Bash for the jobs they cover.** Each tool's own
`description` (visible over `tools/list`) is written DIRECTIVELY — it says
*when* this tool is the first choice, not just what it computes — because the
default failure mode is reaching for `Grep`/Bash even with a working
semantic tool present (industry-wide; see
[anthropics/claude-code#32599](https://github.com/anthropics/claude-code/issues/32599)
and #847).

## 2. The 8 tools

Each appears to an agent as `mcp__medaka__<tool>` once the server is wired in.
Full argument schemas are self-described over `tools/list`; this is the
one-line version (positions are 0-based, LSP-style).

| Tool | Args | What it does |
|------|------|---------------|
| `medaka_check` | `file` \| `source` | Type-check and return structured diagnostics — same JSON as `medaka check --json` |
| `medaka_type_at` | `file`, `line`, `col` | Infer the type/scheme at a position (stateless hover) |
| `medaka_symbols` | `file` | List top-level declarations with source ranges (document outline) |
| `medaka_definition` | `file`, `line`, `col` | Find the declaration defining the identifier at a position (intra-file only) |
| `medaka_references` | `file`, `line`, `col`, `includeDeclaration?` | Find every use of the identifier at a position, project-wide — resolves by binder identity, not spelling |
| `medaka_fmt` | `file` \| `source`, `check?` | Format source with the canonical formatter; never writes to disk |
| `medaka_lint` | `paths`, `deny?`, `only?`, `disable?` | Run the style linter over one or more files |
| `medaka_test` | `file` | Run a file's doctests (and property tests, if any) |

## 3. How to enable it

Two files are already committed at the repo root and pre-wire the server for
every agent working in this tree:

- **`.mcp.json`** (repo root) — declares the `medaka` server, launched via
  `scripts/medaka-mcp-wrapper.sh`. Auto-loads at session start; no per-agent
  setup.
- **`.claude/settings.json`** — carries `"enabledMcpjsonServers": ["medaka"]`,
  pre-approving that one server so there's no interactive prompt.

**One-time step on a fresh clone:** Claude Code only honors that
pre-approval in a *trusted* folder — the very first `claude` session in a
freshly cloned checkout still needs the one-time workspace-trust acceptance
before the server auto-starts. After that, it is automatic for every session
in that checkout, and subagents inherit the parent session's MCP tools by
default (no extra wiring needed for agent-spawned agents).

**Prerequisite:** `make medaka` — the wrapper `exec`s the built `./medaka`
binary at the resolved repo root (`scripts/medaka-mcp-wrapper.sh` reads
`CLAUDE_PROJECT_DIR`, set by Claude Code in the spawned server's environment,
falling back to its own script location so it's robust to whatever cwd the
server is launched from).

If that binary is missing (a fresh worktree, or a checkout you haven't built
yet), the server can't start and the wrapper exits with a specific stderr line
— `medaka mcp: no built binary at <root>/medaka — run 'make medaka' …` — rather
than an opaque "Failed to connect". The fix is always the same: `make medaka` in
that checkout, then reconnect the server (`/mcp`) so the running session picks
up the now-live tools. The wrapper deliberately does **not** auto-build (a
multi-minute build would time out the MCP handshake) or fall back to another
checkout's binary (the tools *are* the compiler's behavior, so a worktree must
answer with its own binary).

## 4. Subagents inherit the parent's tools

A subagent spawned in a fresh **isolated worktree** does NOT start its own
server — it inherits the parent (orchestrator) session's `medaka` MCP tools and
routes calls through the parent's already-running server. (Verified 2026-07-16:
a daughter with no local `medaka` binary successfully *called* `medaka_check`
and got a real diagnostic.) So an orchestrator guarantees working MCP for its
**whole fleet** by holding two things on ITS OWN checkout: (1) a current built
`medaka`, and (2) a connected server (one `/mcp` reconnect if it started before
the binary existed). No per-daughter build or reconnect.

Two traps this creates:

- ⚠️ **`claude mcp list` LIES inside a subagent.** Its health probe connects
  fresh from the binary-less worktree and reports `✘ Failed to connect` *even
  while real tool calls succeed*. Gate daughter-MCP readiness on an actual tool
  call, never on `claude mcp list`.
- ⚠️ **Inherited tools run the PARENT's binary — the parent's compiler
  semantics, frozen at server-launch.** A daughter editing `compiler/*.mdk` or
  `stdlib/core.mdk` and calling inherited `medaka_check`/`medaka_type_at` gets
  the orchestrator's typechecker, not its own edits — a silent wrong answer.
  Such a daughter must verify with its OWN freshly-built `./medaka`; inherited
  tools are for non-compiler work and querying unchanged-semantics code. (The
  same trap hits the parent after it rebuilds mid-session — `/mcp` reconnect to
  refresh the server onto the new binary.)

  **A per-worktree server (the real fix) is a harness feature outside this
  repo's control** — not something a Medaka PR can deliver (#846). The
  repo-controllable minimum shipped instead: every `tools/call` result carries
  a compact `staleBinary` field **when, and only when,** the live compiler
  source at this server's `MEDAKA_ROOT` has diverged from what the running
  binary was actually built from — the same fingerprint check
  `checkSourceStaleness` uses for the CLI's own startup warning
  (`compiler/driver/medaka_cli.mdk`'s `sourceStalenessVerdict`), recomputed on
  every call so a mid-session rebuild-without-reconnect (the trap right above)
  is caught on the NEXT tool call, not just at server launch. A fresh binary
  gets nothing extra — the field costs zero tokens in the common case. **This
  does not by itself detect a daughter's OWN worktree drifting from the
  orchestrator's** (the root being fingerprinted is still the orchestrator's
  `MEDAKA_ROOT`, per the trap above) — `/mcp` reconnect after `make medaka`
  remains the correct fix for that case.

## 5. Honesty caveats — read before trusting a result

- ⚠️ **`medaka_test` runs under the INTERPRETER (eval), not the native
  backend.** A native-only miscompile is invisible to it (#81) — treat a
  green result as "passes under eval," never an unqualified "passes."
- ⚠️ **`medaka_symbols`/`medaka_definition` ranges are LINE-granular** —
  `character` is always 0 (#331 tracks true name-column fidelity).
- ⚠️ **`medaka_definition` is INTRA-FILE ONLY.** A use of a name defined in
  another file returns an empty result, not a wrong location.

## 5. The dogfooding ask

These tools exist for agents to USE during Medaka work — and to
STRESS-TEST. If any tool crashes, returns a wrong or misleading answer, leaks
a path, or is just awkward to call, file a GitHub issue with `ws:tooling`.
This is exactly how the tools got hardened so far — a dogfood soak already
found and fixed #298/#299/#300/#301/#331/#332. Keep the flywheel turning.
