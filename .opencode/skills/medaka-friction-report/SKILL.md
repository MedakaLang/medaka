---
name: medaka-friction-report
description: Defines the required friction report contract for Medaka compiler workflow subagents. Use when a Medaka subagent reports results to its conductor.
---

# Medaka Friction Report

Always return a `Friction` section, even when it contains `None`.

Friction is unexpected difficulty in tooling, documentation, environment, permissions, workflow, performance, worktrees, builds, tests/oracles, or the harness. Keep it separate from compiler and task findings.

For each item report:

- `severity`: `high`, `medium`, or `low`, based on impact on reliable work.
- `blocker`: `true` only when the friction prevents trustworthy completion. Stop rather than fabricate progress when blocked.
- `summary`: what happened.
- `evidence`: how it was observed.
- `impact`: what it cost or prevented.
- `suggested_disposition`: `fix_now`, `file_issue`, or `discard`.

Do not fix or file friction unless the assigned task grants that authority. The conductor owns duplicate search and final disposition.

Expected assignment boundaries are not durable friction: a read-only agent
lacking build artifacts, a verifier omitting checks explicitly assigned to a
sibling, or an implementer returning for conductor-owned compile feedback should
normally be `discard`, not `file_issue`. Report friction only when the boundary
is undocumented, contradictory, or prevents the intended workflow from making
progress.
