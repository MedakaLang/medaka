---
name: architecture
description: Where a new function, type, subcommand, or module BELONGS in the Medaka tree — what each of compiler/{frontend,types,ir,backend,eval,driver,tools,support,entries} is for, the placement rules, the standing sequencing and DECLINED decisions no planner should relitigate, and `make arch-census` as the drift detector. Load when cutting a sprint contract (placement must be stated before code exists), when reviewing placement in a diff, or when you are about to add a file, a subcommand, or a helper and do not know which directory owns it.
---

# Placement — where the code goes

This skill is the **single source of placement ground truth**, shared by
`sprint-plan` (which must state placement in the contract, before code exists),
`style-review` (which checks it in a diff), and any agent about to add a file.

It answers *where does this belong* and *what must not be relitigated*. It does
**not** duplicate two things that already have owners:

- **Which stage lives in which file, and in what order they run** — `AGENTS.md`
  § "Pipeline — where each stage lives". That table is current; the Layout
  table in `compiler/README.md` predates the subfolder restructure and says so
  in its own header.
- **How not to make the compiler slow** — `compiler/AGENTS.md`. Placement never
  overrides its one rule (a `List` is not a set and not a map).

Cost asymmetry, which is the whole reason placement is decided up front:
**placement chosen before the code exists costs nothing; placement fixed
afterwards costs a snapshot re-bless (`[T-SNAPSHOT-SELF]`) and usually a LEG A
golden re-capture (`[T-LEGA-GOLDEN]`), on top of the move itself.**

## What each directory is FOR

`compiler/` is ONE Medaka project (`compiler/medaka.toml`). A directory outside
it with its own `medaka.toml` is a separate project with its own enrolment
obligations — `[W-PROJECT-BY-MANIFEST]` in `AGENTS.md`, not this skill.

| Directory | It owns | It must not |
|---|---|---|
| `compiler/frontend/` | Source text → resolved, marked AST: `lexer.mdk`, `parser.mdk`, `ast.mdk`, `desugar.mdk`, `resolve.mdk`, `marker.mdk`, `exhaust.mdk`. | Know about Core IR, LLVM, or any CLI verb. |
| `compiler/types/` | Type inference, interfaces, effects — `typecheck.mdk`, `annotate.mdk`. Exhaustiveness is *called from* here (`[P-EXHAUST-IN-TYPECHECK]`) but lives in `frontend/`. | Emit diagnostics by raising — errors accumulate (`[T-ERRORS-ACCUM]`). |
| `compiler/ir/` | Core IR: the types, lowering, S-expr form, DCE, and the Core IR interpreter. The seam between front and back (`compiler/STAGE2-DESIGN.md`). | Contain surface-AST knowledge, or backend target detail. |
| `compiler/backend/` | Target emission — `llvm_emit.mdk`, `wasm_emit.mdk`, mangling, TRMC analysis. Consumes Core IR only. | Re-derive anything the frontend or typechecker already computed. |
| `compiler/eval/` | The tree-walking interpreter and its dict-passing dispatch. Its module driver moves in lockstep with `compiler/ir/core_ir_eval.mdk`'s (`[T-EVAL-LOCKSTEP]`). | Drift from the Core IR interpreter's frame semantics. |
| `compiler/driver/` | **Dispatch, never implementation.** Verb routing (`medaka_cli.mdk`), the dependency walk (`loader.mdk`), the accumulating diagnostics pipeline (`diagnostics.mdk`), the build pipeline (`build_cmd.mdk`). | Hold a subcommand's *logic* or its command-local ADTs. That is the de-grab-bag work, #2282. |
| `compiler/tools/` | One file per user-facing tool: `fmt`, `lint`, `doc`, `doctest`, `test_cmd`, `lsp`, `mcp`, `repl`, `check`, `gate_cmd`, `printer`, `snapshot`. A new tool is a NEW FILE here. | Become a shared grab-bag; cross-tool helpers go to `support/`. |
| `compiler/support/` | The compiler-private mini-stdlib: `util`, `char`, `path`, `ordmap`, `scc`, `timer`, `opcount`, `manifest`. Thin wrappers over `stdlib/` are fine and expected. | Grow a second copy of something `stdlib/` exports — see the duplication rule below. |
| `compiler/entries/` | Per-stage probe entry points, one `main` each, **thin**: parse argv, call one pipeline function, print. They exist so gates and oracles can drive one stage. | Contain logic. If an entry needs a real algorithm, the algorithm belongs in the owning stage and the entry calls it. |
| `compiler/seed/` | The checked-in LLVM IR seed for cold bootstrap. Machine-managed (`test/refresh_seed.sh`). | Be hand-edited, ever. |
| `stdlib/` | The language's public library. `core.mdk` is the only auto-prelude. | — |

## The placement rules

1. **The driver dispatches; it never implements.** A new `medaka` verb adds a
   route in `compiler/driver/medaka_cli.mdk` and a file in `compiler/tools/`.
   Flag vocabulary and exit-code/stream discipline are ratified in
   `docs/ops/CLI-CONFORMANCE.md` — the normative source, re-derivable with
   `make cli-conformance-census`. A verb's flag roster is a VALUE
   (`docs/design/ARGS-DESIGN.md`), not two hand-synced lists.
2. **Entries stay thin.** An `entries/*_main.mdk` that grows past argv-parse →
   one call → print is a stage function wearing an entry's clothes. Move the
   body; keep the entry.
3. **A new subsystem is a NEW FILE, not a new section of an old one.** "It's
   only 200 lines, I'll append it" is how `medaka_cli.mdk` reached its current
   size (`make arch-census` for the number — do not hand-type it, that is the
   rot #2289 exists to kill).
4. **Past a size threshold, EXTENDING instead of extracting needs a stated
   reason.** The threshold is a judgment, not a gate: the epic
   **declined hard size ratchets** (see the register below), so nothing will
   red on you. Read `make arch-census`'s largest-files table; if the file you
   are about to grow is in it, the contract or PR body must say *why extending
   is right here* (e.g. the new code is inseparable from an existing seam, or
   the extraction is already scheduled as a named issue). An unexplained
   append to a top-of-table file is a `style-review` finding.
5. **Before writing a helper, look for it.** `stdlib/`'s generated reference
   `docs/stdlib/index.md` answers "does the stdlib have X" name-by-name;
   `compiler/support/` answers it for compiler-private helpers. The lint rule
   `rule-stdlib-reimpl` (`compiler/tools/lint.mdk`) catches part of this
   mechanically — it is a floor, not the check. Naming what you looked for is
   one of the `sprint-packet` report self-check questions.
6. **Import weight is per-module and measured, not free-by-assumption.** The
   compiler may import `stdlib/`, selectively — `[T-STDLIB-IMPORT]` in
   `AGENTS.md` carries the measurement and the wildcard-collision hazard.
7. **A directory with its own `medaka.toml` is a PROJECT** and owes CI a floor
   gate plus a `test/gates.toml` row (`[W-PROJECT-BY-MANIFEST]`). Placing new
   code in a new top-level directory is therefore an enrolment decision, not
   just a filing decision — decide it in the contract.

## Standing decisions — do NOT relitigate

A planner or reviewer who reopens one of these is spending the sprint's budget
on a question already answered. Each row: the decision, its issue and date, and
why it is not reopened here.

| Decision | Where | Why it is closed |
|---|---|---|
| Split `typecheck.mdk` along its six fenced seams — **SEQUENCED, do not schedule** | #2284 (open, title says so) | Sequenced behind the rearchitecture epic by that epic's own register. It is not "not worth doing"; it is *not next*. |
| De-grab-bag `driver/` and `tools/` (extract the gate scheduler, move inline subcommands and command-local ADTs, thin the entries) | #2282 (open) | This is the OWNER of driver/tools placement debt. Findings about `medaka_cli.mdk`'s size are **noted on #2282**, not acted on inline — `docs/ops/CLI-CONFORMANCE.md` says the same in its own §7. |
| Hard size ratchets (a gate that reds on a file exceeding N lines) — **DECLINED** | #2289, leg 4 of crusade #2276 | The chosen detector is **soft**: `make arch-census` (`test/arch_census.sh`) reports and ranks, encodes no threshold, asserts nothing, always exits 0. A ratchet with no baseline mechanism teaches avoidance, not architecture. |
| New lint rules as a placement/style enforcement mechanism — **DECLINED for now** | crusade #2276 | The max-ratchet lint model (`[H-LINT]`) has no baseline mechanism, so a new rule must be tuned to ≈zero findings, left ungated, or wait for a baseline. That is an OPEN Val decision. A repeated, syntactically-detectable finding becomes a **filed lint-rule issue**, not an implemented rule. |
| A comment **length** ratchet — **DECLINED on record** | #2281 | A length ratchet teaches agents to write short bad comments. The register norms are prose (`[T-COMMENT-REGISTER]` in `AGENTS.md`) plus a census (`make comment-census`), not a gate. |
| Mirroring `.claude/skills/` into `.agents/` and `.opencode/` — **OUT of placement scope** | #2313 (open) | No gate references either tree, and `.opencode/` is an independent adaptation, not a mirror. Parity is #2313's question; do not mirror a new skill reflexively. |
| The `compiler/types/` module map README — **PENDING, referenced not written** | #2283 (open) | It is leg 4 **R** and will land as a `README.md` under `compiler/types/`, carrying the per-module depth this skill deliberately does not: which of `typecheck.mdk`'s fenced regions does what. It does not exist yet (this skill functions without it); when it lands, link it from here rather than copying it. Not cited as a live path above precisely because it is not on disk. |

## Drift detection between sprints

```sh
make arch-census      # test/arch_census.sh — largest-files table + per-directory
                      # file/line totals over tracked compiler/ + stdlib/ .mdk
```

It is a **report, not a gate**: it asserts nothing, encodes no threshold, needs
no built `./medaka`, and always exits 0. Run it when cutting a sprint that
touches the compiler, and again at wrap-up; the diff between the two runs is
the sprint's architectural footprint. It is also composed as a row of
`make slop-census` (`test/slop_census.sh`), the crusade's one entry point.

🚨 **Never hand-type a line count from it into prose.** That is the exact rot
`test/fmt_clean_census.sh` (#1794) and this census (#2289) were written to
kill — `medaka_cli.mdk` carried three different hand-typed sizes inside one
epic. Cite the command; let the reader run it.
