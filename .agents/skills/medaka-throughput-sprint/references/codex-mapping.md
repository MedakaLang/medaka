# Claude → Codex mapping

## Preserved directly

| Claude construct | Codex equivalent |
|---|---|
| `sprint-orchestrator` front seat | root conductor using this skill |
| `sprint-brain` persistent daughter | `sprint_brain` custom agent; continue with `followup_task`/`send_message` |
| `sprint-implementer` | `sprint_implementer` custom agent in isolated harness worktree |
| `sprint-planner` | `sprint_planner` custom agent, phasewise |
| `sprint-scout` | `sprint_scout` custom agent, read-only |
| `sprint-verifier` | `sprint_verifier` custom agent |
| `domain-adversary` | `domain_adversary` custom agent |
| `sprint-retro` | `sprint_retro` custom agent after terminal merge-queue evidence |
| `sprint-rear` review/finding/CI pipeline | persistent `sprint_rear`; root conductor relays brain consults and owns final state |
| `SendMessage` | `send_message` for advisory delivery; `followup_task` to wake idle persistent seat |
| `TaskStop` | `interrupt_agent` |
| task roster | `list_agents` |
| file reports | caller-named paths under `/var/tmp/medaka-sprints/<stage>/` |

## Intentional adaptations

- Repository config requests seven concurrent child threads, permitting root + rear + brain + writer + planner/reviewer/verifier lanes. Runtime service may clamp configured concurrency; when it does, preserve writer and brain first, then absorb rear mechanics into root.
- Codex role configuration uses `.codex/agents/*.toml`; model names map Opus judgment/review seats to `gpt-5.6-sol`, Sonnet mechanical/writer seats to `gpt-5.6-terra`, and cheap verification to `gpt-5.6-luna`.
- Codex agents cannot be assumed to own stable Claude harness worktree paths. Dispatch packet names mode/branch/base; agent derives actual root. Root conductor owns commits/integration unless role permissions explicitly allow push.
- Codex commentary/final responses are not durable sprint state. Persist packets, reports, rulings, ledgers, and GitHub readbacks before relying on them.
- Claude `EnterWorktree`, hooks, and agent-frontmatter tool allowlists have no direct Codex equivalent. Use sandbox mode, explicit role instructions, isolated agent harness, and repository hooks.

Do not weaken workflow rule merely because transport differs. Preserve property, evidence, refusal, report, ruling, and exit contracts; change only mechanism named above.
