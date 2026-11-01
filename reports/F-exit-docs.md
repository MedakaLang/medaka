LANDED @pending

## Evidence

- Worktree: `/var/tmp/medaka-scratch/sprints/arch-p5-finish/15-phase-exit/wt-docfix`; branch `slice-p515-docfix-seed`; base verified as `a69318773137e5494fd00089904c9ba357f49ad9`; clean before edits.
- `make medaka`: PASS; built `/var/tmp/medaka-scratch/sprints/arch-p5-finish/15-phase-exit/wt-docfix/medaka` (68 seconds emit + link).
- `make docs-links`: PASS; checked 12,031 references across 7,202 citing files; 0 dead.
- `make agent-doc-symbols`: PASS; checked 1,882 symbol claims (1,044 distinct) across 241 agent-facing docs; 0 dead.
- `./medaka gate explain compiler/backend/emit_plan_test.mdk`: lists `diff_compiler_build`, `diff_compiler_selfproc`, `diff_compiler_wasm_single_traversal`, `arch_boundaries`, `stage_counts`, and other affected backend gates.
- `git diff --check`: PASS (exit 0, no output).
- `make docs-index`: not run; no new docs files or index references were added.

## Notes

- Updated active R9.1 to record checked extern propagation and bounded local Node shipping-artifact proof; clarified R9.5 F6 is landed, #993 is closed, and #2549 remains open for separate upstream evidence-as-bindings work.
- Documented the structural retirement guard as seven complete historical families, identifier erasure, original/renamed restoration controls, lawful physical-adapter neighbors, and explicit rewrite blind spots. Updated the scratch final draft with those bounds and provisional #1408/phase status; #4604, #1951, and #4722 remain explicitly open as applicable. Phase closure remains pending independent review, CI, merge, and readbacks.
- No code, tests, or generated index changed. No additional source-linked stale workstream/spec reference was needed for this bounded doc correction.
- Self-check 1: no new helper written; no stdlib/support helper search was needed.
- Self-check 2: edits are in the assigned compiler architecture docs, matching packet placement; no exports changed.
- Self-check 3: no existing compiler module grew; only documentation files changed.
- Self-check 4: no code comments added; prose states current evidence and its limits.
- Self-check 5: existing native vehicle is `compiler/backend/emit_plan_test.mdk`; no test vehicle was added. `medaka gate explain` output is summarized above.
