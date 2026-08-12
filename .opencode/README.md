# Medaka OpenCode Workflows

The project agents in `agents/` are an OpenCode adaptation of Medaka's complex-compiler Polytoken workflow.

- `medaka-compiler` is the primary conductor for complex compiler work.
- `compiler-designer` and `compiler-reviewer` use Sol at high reasoning effort for semantic and architectural judgment.
- `compiler-implementer` uses Terra for an accepted, bounded implementation packet in an isolated daughter worktree; it does not choose semantics or own broad verification.
- `compiler-scout` uses Terra at medium reasoning for evidence-sensitive readiness and exhaustive inventories; `compiler-reproducer` uses Terra at high reasoning for discriminating behavior matrices.
- `compiler-verifier` uses Qwen for bounded command execution and log reduction.
- `compiler-mutation-verifier` uses Qwen to execute an already-designed, reversible expected-red mutant matrix in a fixed isolated worktree.
- `bug-capture` uses DeepSeek for isolated issue and pin mechanics.
- `medaka-friction-report` keeps a shared return contract for workflow friction.
- `medaka-verification-scope` selects the smallest trustworthy local signal and records broad checks deferred to authoritative merge-queue CI.
- `medaka-epic-intake` derives the next staged-architecture milestone from tracker state, merged history, and current source without conflating readiness with a broad implementation census.
- `medaka-pr-lifecycle` provides the phase-specific verified PR, CI,
  merge-queue, tracker-handoff, and cleanup sequence without keeping all of that
  mechanics in every child brief.
- `medaka-structural-migration-tests` defines per-field same-process controls,
  structural ratchets, and observed-red mutation matrices for ambient-state and
registry ownership migrations.

Designer packets must pass an implementer-sized-slice test before Terra receives
them. Implementers remain build-free; the conductor supplies exact isolation
proof up front and runs stateless source checks on coherent daughter diffs before
integration. Verification daughters should share cold prerequisites unless a
measured wall-clock reason justifies duplicate builds.

Reproducers receive a unique conductor-owned scratch directory outside every
worktree. Mutation rows are caller-designed transactional shell commands:
normal-exit and trappable-signal handlers restore and hash-check source inside
the same command that applies and grades the mutant. Hard interruptions such as
`SIGKILL` or host loss require the conductor to discard and recreate the isolated
daughter before reuse.

The model split is deliberate: Sol owns semantic design and adversarial review;
Terra receives implementation-ready edits and evidence-sensitive
readiness/reproduction work; Qwen handles caller-designed verification execution
and log reduction. Model choice does not excuse broad packets: split the work,
preserve exact receipts, and keep child returns delta-oriented rather than
repeating issue history and command transcripts.

OpenCode does not provide Polytoken facet phases, fallback model lists, transclusion, or schema-enforced subagent exits. The primary agent therefore tracks phases in its correctness ledger, while each subagent prompt specifies a structured Markdown response contract.

For configuration validation, prefer `opencode debug agent <name>` for each
touched agent. `opencode agent list` and `opencode debug skill` expand every
resolved permission or full skill body and create a large, mostly redundant
transcript; use them only when validating the complete discovered set.

OpenCode loads agent and skill definitions at startup. Quit and restart it after changing these files.
