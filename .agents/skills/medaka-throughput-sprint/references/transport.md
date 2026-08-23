# Codex transport for v8

Codex collaboration does not provide Claude's `isolation:"worktree"` harness.
Agents share the default workspace unless the conductor explicitly creates a
writer/reviewer worktree and names its absolute path in the brief. Do not claim
isolation merely because an agent is a separate conversation.

## Dispatch

The conductor creates a distinct worktree and branch when the environment's
sandbox permits it, gives the agent its absolute path, and keeps the
integration checkout separate. The packet supplies only licensed `git -C`
sync commands and its exact base SHA; the agent verifies `HEAD` before edits.
It commits and pushes only the explicitly named writer ref. The conductor
verifies the reported SHA, merges that SHA in the integration checkout, and
does all GitHub writes.

If an explicit writable worktree cannot be used, dispatch one writer only in
an exclusive shared checkout: no conductor edits, no other writer, and no
parallel review in that checkout. Wait for its commit/report before any next
mutation. This is a transport fallback, not evidence for parallelism.

Read-only reviewer/retro roles cannot reliably persist reports or build a
compiler. The retained reviewer is therefore workspace-write solely to build
and probe its dedicated review tree; it must not edit source, commit, push, or
write GitHub. The retro remains read-only and returns text for the conductor to
persist.

## Registry reload and fixed role models

Codex loads custom-agent registry entries when the session begins. Editing a
TOML does not change roles already visible in this session: reload the session
before relying on the retained `sprint_implementer` configuration. After that
reload, its one fixed conservative Sol mapping serves every ordinary
behavior-changing slice and fix packet; callers cannot select Terra versus Sol
per dispatch through the existing role mechanism.

Until reload, inspect the roles actually available. Do **not** call a
currently Terra-backed `sprint_implementer` Sol, and do not route through a
retired role whose developer contract still requires the old reports and
transport. Either start a new session so the retained v8 roles are loaded, or
use an explicit default `worker` brief that embeds the complete v8 packet and
report contract while acknowledging that this fallback drops the Sol-model
guarantee. Packet difficulty remains visible to the conductor but does not
imply an unsupported model override. `sprint_reviewer` uses Sol and the
lightweight `sprint_retro` uses Terra only after registry reload.

## Report and permission boundary

An implementer writes its report in the shared sprint directory only when its
assigned sandbox permits it. On any write restriction, it returns report text;
the conductor persists it verbatim before acting. No agent opens, edits,
merges, labels, or closes GitHub items. The conductor verifies all remote
writes and queue transitions by readback.
