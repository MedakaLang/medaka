# Medaka OpenCode Workflows

The project agents in `agents/` are an OpenCode adaptation of Medaka's complex-compiler Polytoken workflow.

- `medaka-compiler` is the primary conductor for complex compiler work.
- `compiler-designer` and `compiler-reviewer` use Sol at high reasoning effort for semantic and architectural judgment.
- `compiler-scout`, `compiler-reproducer`, and `compiler-verifier` use Qwen for bounded evidence work.
- `bug-capture` uses DeepSeek for isolated issue and pin mechanics.
- `medaka-friction-report` keeps a shared return contract for workflow friction.

OpenCode does not provide Polytoken facet phases, fallback model lists, transclusion, or schema-enforced subagent exits. The primary agent therefore tracks phases in its correctness ledger, while each subagent prompt specifies a structured Markdown response contract.

OpenCode loads agent and skill definitions at startup. Quit and restart it after changing these files.
