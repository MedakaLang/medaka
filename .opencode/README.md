# Medaka OpenCode Workflows

The project agents in `agents/` are an OpenCode adaptation of Medaka's complex-compiler Polytoken workflow.

- `medaka-compiler` is the primary conductor for complex compiler work.
- `compiler-designer` and `compiler-reviewer` use Sol at high reasoning effort for semantic and architectural judgment.
- `compiler-implementer` uses Terra for an accepted, bounded implementation packet in an isolated daughter worktree; it does not choose semantics or own broad verification.
- `compiler-scout`, `compiler-reproducer`, and `compiler-verifier` use Qwen for bounded evidence work.
- `bug-capture` uses DeepSeek for isolated issue and pin mechanics.
- `medaka-friction-report` keeps a shared return contract for workflow friction.
- `medaka-verification-scope` selects the smallest trustworthy local signal and records broad checks deferred to authoritative merge-queue CI.

OpenCode does not provide Polytoken facet phases, fallback model lists, transclusion, or schema-enforced subagent exits. The primary agent therefore tracks phases in its correctness ledger, while each subagent prompt specifies a structured Markdown response contract.

OpenCode loads agent and skill definitions at startup. Quit and restart it after changing these files.
