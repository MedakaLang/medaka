## [T-EMITTER-BENCH] Emitter benchmarking two-rebuild rule

A binary's *behavior* comes from its source but its *speed* comes from the emitter that compiled
it, so measuring an emitter change needs **two** rebuilds to get a single-generation binary. One
rebuild crosses the arms and makes an optimization look like a regression — a real 2.2× win was
once measured as a 2.5× slowdown this way. Seed re-mints (`test/refresh_seed.sh`) are **not
idempotent after a codegen change; it must be run TWICE**, and a stale seed can **SEGFAULT the
fixpoint** on a perfectly correct change. Full method in the `benchmark-emitter` skill.

## [T-PERF-HUNT] Perf-hunt method notes

Profile **allocation** (deterministic) over wall-clock (noisy); use **DWARF** call graphs. Note
`whenL False (expensiveCall …)` is **NOT a stub** — Medaka is strict, so the argument still
evaluates; this produced a false "hypothesis disproved" verdict on a hypothesis that was actually
correct. Full method in the `perf-hunt` skill.

## [T-DISPATCH-LOADER] Loader-vs-single-file dispatch bugs

A dispatch bug that reproduces through the loader but is green single-file is *usually* the EVAL
DRIVER, not dict-passing — this pattern recurred at Phases 96, 103, 121, and 125. But verify:
Phase 134 was the documented inverse case, and the standard two-probe comparison did *not* flag
it. Full method, both probes, and the instrument-the-resolution-arms technique live in the
`debug-pipeline` skill. Regression tests for this class must exercise the multi-module path
(the `eval_modules_main` rows of `test/diff_compiler_eval_test.mdk`), not a single-file doctest.

## [T-EVAL-LOCKSTEP] evalModules / cevalModules lockstep

`evalModules` (`eval/eval.mdk`) and `cevalModules` (`ir/core_ir_eval.mdk`) are parallel module
drivers — `cevalModules` deliberately mirrors `evalModules` (same frame layout, same
`importFrameOf`/`pubReexports`/`installConsts` helpers), so a fix to one is silently absent from
the other. This is exactly how the P0-9 cross-module ctor-collision fix shipped patching only
`eval.mdk`, leaving `core_ir_eval.mdk` broken for months. Underlying hazard: `installConsts` +
`findCell` is last-write-wins on duplicate names, so any flat frame keyed by bare name across
modules inherits it (e.g. `map`'s arity-5 `Bin` vs `set`'s arity-4 `Bin` collapse into one cell).
The fix shape is a per-module **local** ctor frame that shadows the global.

**A specific instance of this hazard: sharing an implementation does not share the
state it reads.** `ceval`'s `CMethod`/`CDict` arms (`ir/core_ir_eval.mdk`) call
`eval.mdk`'s `applyMethodDicts`, the single shared implementation for dict-forwarding
on an impl method that declares no `requires` of its own. Calling the same function
from both drivers was not sufficient on its own: `applyMethodDicts` also consults
`methodReqCountRef`, a table that only `eval.mdk`'s own drivers used to fill, so a
lookup from the `core_ir_eval.mdk` side always found it empty and took the wrong
branch — an impl method with a `requires` clause dispatched correctly under `medaka
run` and panicked under the Core IR interpreter, with the shared function unchanged
either way. `installDispatchTables` is what makes the two agree: it derives both
dispatch tables from one decl list and installs them together, so no driver can
populate one table and leave the other's reader empty.

## [T-GLOBAL-TABLE] 2026-07-24 program-global-table incident

On 2026-07-24 alone, this shape was the root cause of an S0, an S1, and a def-site regression
across four different PRs — every one of them 12/12 green. Real example: a graded-interface kind
table keyed on a bare type-param name re-kinded *every* arity-matching application in the whole
module graph, so `f Int a -> f String a` was silently accepted (`meowmeow` for `meowwoof`, exit 0,
no diagnostic), and one 4-line file turned 1 clean diagnostic into 45.

## [T-FIXTURE-LINES] Fixture line-count incident

Two agents hit the line-count-shift trap on 2026-07-31; one caught it only because a STOP
guardrail made them suspicious of their own comment-only edit.

## [T-PERRUN-COMMENTS] #829 reopened — fmt --write comment corruption

Re-verified first-hand on a fresh cold `make medaka` of `origin/main` @ `f9db4fd2` (2026-08-05).
The issue had previously been marked "FIXED, retired 2026-08-01" — that retraction claim was
itself wrong, and it sent an agent's mandatory `fmt --write` into corrupting their own comment.
Both halves the retraction claimed were fixed were re-tested independently and **both still
reproduce**:

- **Standalone `--` block** (the issue's own two-line repro, `data Cfg =\n  | Cfg { … }`):
  `fmt --write` collapses the header to `data Cfg = Cfg {` and drags the block onto the field
  **two past** the one it described, with the block's second line dangling onto the closing `}`.
- **Long trailing comment**: on the same header shape, a trailing comment on `alpha` lands on
  `beta` after `fmt --write` — moved one field down.
- **On the real `PerRun` record**, with its header artificially put into the two-line
  `data PerRun =\n | PerRun { … }` shape (the shape `DriverState`, in this same file, is actually
  in today) and given ONE new field with a trailing comment plus one standalone two-line block
  elsewhere in the body: `fmt --write` shifted **every one of the record's ~60 trailing
  comments** down by one field, piling the last two onto the closing `}` line — the whole-record
  cascade the reading-hazard paragraph (side comments as a column-wise prose river, where
  `effvarCounter`'s comment finishes a clause begun on `inRigidityBodyRef`) is a residue of.
- In every case, `fmt --check` on the corrupted output exits 0 — it reports the damage as already
  formatted, so the pre-commit hook (which gates on `fmt --check`, not a diff against intent) lets
  it through. The corruption is a stable fixed point, not a slow leak: a second `--write`
  reproduces the damaged file byte-for-byte, so it doesn't get worse, but it also never
  self-heals.

Three things measured safe: adding a field with no comment at all (either header shape, byte-
identical diff except the added line); adding a comment to a record whose header is already the
single-line `data X = X { … }` form (verified directly on `PerRun` as it stands today — a new
trailing-commented field and a new standalone two-line block each produced a diff containing only
the intended edit, second `fmt --write` a no-op). The real-world workaround for the unsafe case is
PR #1296 (still open, adding a new `Ref`-typed field to `DriverState`): add the field bare, put
the explanatory prose on the nearby function that derives/populates it instead of as an interior
record comment.

## [T-SHARED-CORPUS] The four/eight/five recount

This bullet has been wrong in both directions, twice. It used to say `test/wasm/fixtures/` had
"four" consumers — wrong, it missed `diff_compiler_prelude_obj.sh`. A "correction" to eight was
*also* wrong — a naive `grep -rl 'wasm/fixtures' test/` matches the real sibling corpora
`test/wasm/fixtures_typed/` (9 files) and `test/wasm/fixtures_modules/` (36), which
`diff_wasm_typed.sh`/`diff_wasm_modules.sh`/`build_wasm_cmd.sh` read *instead of* this directory.
The true count is five. `test/preflight.sh` already solves the word-boundary problem — "Word-
boundaries on both sides so `llvm_fixtures` cannot match `llvm_fixtures_modules`/`llvm_fixtures_
typed` (real sibling corpora in this tree)."

That two successive "verified" recounts each produced a *different wrong* number is the point,
not an embarrassing footnote: a count is an encoded fact with no derivation and no expiry, while
the enumeration is one command away. An agent obeying a count literally runs a subset and believes
it was exhaustive — the count manufactures the very confidence this warning exists to prevent.
It's "check the SET, not one member" failing inside the sentence that teaches it.

Assuming the flat `test/` path for the wasm gates (rather than `test/wasm/`) cost an agent two
failed invocations on 2026-07-16.

## [T-SNAPSHOT-SELF] Snapshot bless-command confusion

Two agents lost time on 2026-07-16 because the bullet said *what* to do (bless via the gate) and
never *which command* — they reached for `medaka snapshot --bless <compiler source>`, which is a
dead end (fails: "no snapshot … `--bless` never creates one — run `medaka snapshot --new` first",
exit 1).

## [T-LEGA-GOLDEN] LegA golden drift

Three perf PRs reddened only the `backend` shard on 2026-07-24 by blessing the snapshot corpus
but forgetting the selfproc LEG A scheme golden — because the LEG A diff runs in CI's `backend`
shard specifically, not the snapshot/check gates, so it stays green locally.

## [T-LEGA-REBASE] Three-way blend incident, 2026-08-11

This happened three times in one 2026-08-11 session, to three different agents, on the exact same
file (`test/selfproc_goldens/legA/types.typecheck.golden`, an ordinary ~1700-line text file with
no merge driver — `git check-attr merge` reports "merge: unspecified"). Two agents' re-cuts
landing in different regions three-way-merged with no conflict marker at all. The result is a
blend of two derivations, and no gate can flag it: the golden IS the oracle, so a plausible-
looking blend simply becomes the new expected output — the same rubber-stamp hazard as blessing a
red gate, but arriving with no red gate and no prompt to bless.

## [T-STDLIB-IMPORT] Per-module stdlib import cost measurements

- Importing a module whose types' instances live in `core` (the always-present prelude) is
  near-free — `import list`/`import string` drag no new instance surface, DCE trims to the
  referenced standalone fns (−256 B, +2% ≈ noise).
- Importing a module that defines a NEW type is not: DCE keeps every `DImpl`/`DInterface` whole
  (runtime dict-passing → pruning an impl would be a silent miscompile), so `import map` drags
  `Map`'s entire Eq/Ord/Debug/Display/Mappable/Monoid surface in (+34 KB binary, +4.8%
  self-compile).
- Anti-pattern, measured: delegating the compiler's hot monomorphic helpers (`elem`/`any`/`all`/
  `length`) to prelude Foldable methods loses `||`/`&&` short-circuiting and becomes dict-passed
  fold+closure — doing this to `util.mdk`'s hottest helpers cost +56% self-compile.
- The imported module is re-typechecked on every compile and every fixpoint iteration; once the
  compiler imports a stdlib module, any change there that perturbs emitted IR forces a seed
  re-mint + fixpoint re-validation (a feature — converts silent `support/`-vs-`stdlib/` divergence
  into a build-time gate — but it is churn).

## [T-GUARDS] Refutable-guard miscompile, fixed 2026-07-13

The multi-clause refutable-guard case was a run≠build miscompile until 2026-07-13: the
`__fallthrough__` sentinel read its jump target from a mutable Ref that `emitDecision` nulls
across a body-level match, and a refutable guard desugars to exactly such a match, so "try the
next clause" became `@mdk_oob`. It now carries its target in the node (`labelFallthrough`,
`backend/emit_support.mdk`) — the design the WasmGC backend already had, which is why wasm was
never wrong. Full write-up: `compiler/EMITTER-GAPS.md`.

## [WT-GOLDEN-ENSHRINES] Eval-oracle near-misses

Two separate PRs in one day nearly pinned a shape whose eval golden would have baked in a wrong
value; both were caught only because a reviewer computed the correct answer by hand first. 178
`*.eval.golden` files are generated from the interpreter across `test/eval_fixtures/`,
`eval_dict_fixtures/`, `eval_list_fixtures/`, `eval_modules_fixtures/*`, and eval is a known-wrong
oracle in at least five open S0s (#1034, #1037, #1040, #1047, #1062).

## [WT-DASH-PRINTF] Gzip CRC corruption incident

A `gzip/` oracle test case meant to corrupt a 4-byte CRC field used `printf '\xNN'` under dash,
which appended 16 junk *literal-character* bytes instead of 4 real bytes and shifted the whole
trailer. It still produced a CRC error, so the gate read green, and the bug only surfaced when a
sibling ISIZE test case failed with a CRC message that made no sense. Measured: appending the
literal-character form to a 219-byte file produced 235 bytes, not 223.

## [T-PERRUN-COMMENTS] — full rule text

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

- ⚠️ **[T-PERRUN-COMMENTS]** `fmt --write` USED TO corrupt comments on a two-line `data X =\n
  | X { … }` header (#829, reopened 2026-08-05 after a prior "fixed" claim proved wrong on
  re-verification — that history is why this bullet still says "diff by eye", not "trust it").
  Root cause: `spliceInterior`'s source→output line mapping anchored to the decl's overall
  start line (the `data X =` line) instead of the variant's own line (`| X {`), and its
  standalone-vs-trailing comment classification compared a SOURCE column against the
  RENDERED output's field indent instead of the comment's own source line — both broke once
  the header's two source lines collapsed to the render's one. Fixed in `compiler/tools/fmt.mdk`
  (`spliceInterior`/`classifyIdxs`/`isStandaloneSrc`); regression fixtures cover BOTH header
  shapes: `test/fmt_fixtures/record_standalone_comment.mdk` (single-line, the original repro)
  and `test/fmt_fixtures/record_standalone_comment_twoline_header.mdk` (two-line, the shape
  that stayed broken through the reopening) — gated by `diff_compiler_fmt.sh` and
  `diff_native_cli.sh`. Given this bullet's own history of a false "fixed" retraction, still
  diff a comment-bearing record decl by eye after `fmt --write` rather than trusting this note
  alone.

## [T-COMMENT-REGISTER] — full rule text

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

- ⚠️ **[T-COMMENT-REGISTER]** A source comment should state a constraint the
  code itself cannot show — not narrate its own history. Provenance and
  litigation (why a decision was made, who ruled on what, what a PR debated)
  belong on the issue or in `.claude/dossier/`, linked by reference, not
  written into the source; a comment that reads as reviewer-addressed prose
  (`refuted`, `ratified`, `"ruling"`) or a draft's self-narration (`earlier
  cut`, `this PR`) is describing the PR, not the code, and rots the moment
  the PR merges. No emoji shouts (🚨/⚠️/🔒) in source comments. A dead-path
  citation — a repo-relative path the comment names that no longer exists,
  the OCaml reference compiler under `lib/` removed 2026-06-26 being the
  biggest instance — is this same register: provably wrong regardless of
  what it says. When relocating a paragraph out of source rather than
  deleting it outright, the pointer left behind MUST name the destination as
  a **repo-relative path** (e.g. `compiler/STAGE2-DESIGN.md` §4), never a
  bare prose description — this is currently unverified by any gate for a
  RELOCATED paragraph specifically: `test/check_doc_links.sh`'s citing
  corpus is `git ls-files '*.md' '*.sh' '*.mdk' '*.txt'` (so a pointer left
  in an `.mdk` source comment IS scanned, and a truly dead path there does
  red the gate), but `test/check_agent_doc_symbols.sh` treats `.md` files as
  the citing corpus and `.mdk`/`.c` source only as the resolution target,
  not as a source of citations to check — so a pointer that names a real
  file but the WRONG one (e.g. a superseded regenerator, a retired sibling)
  is caught by neither gate. A stale-but-live-path relocation pointer is
  caught only by a human, enforced by review, not by a gate.
  `make comment-census` (`test/comment_register_census.sh`, #2281) derives a
  current on-demand report of these registers. The report itself asserts
  nothing, but the same script's `--check` mode IS gated: eight of the classes
  carry a per-(file, class) count baseline that may only fall
  (`test/comment_register_baseline.toml`, `[H-COMMENT-REGISTER]`), enforced by
  `.githooks/pre-commit` check 6b and by
  `test/diff_compiler_comment_shout_diff.sh` in CI.

## [T-STDLIB-IMPORT] — full rule text

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

- **[T-STDLIB-IMPORT]** The compiler MAY import `stdlib/`, per module — MEASURED (#2352, on
  `medaka check compiler/driver/medaka_cli.mdk`, median of 5 warm runs + cachegrind Ir,
  `GC_INITIAL_HEAP_SIZE` pinned): a **selective** `list`/`string` import
  (7-8 real, non-vestigial names) into `typecheck.mdk`/`llvm_emit.mdk`/`parser.mdk` moves wall
  time by -1% to +9% and Ir by -0.6% to +1.1% vs. an 89.1B-Ir/16.6s baseline (two identical-
  source `make medaka` rebuilds on this shared box varied 34% with zero code changes, so
  self-compile wall time is NOT a usable signal for this; `check` wall-time + Ir is). The
  **near-free license rests on the Ir figures** (-0.6% to +1.1%, genuinely flat) — the +9%
  check-wall delta is measurement variance the methodology hasn't shown to be signal, not
  evidence treated as noise. **DECISION: license `core`-instance modules (`list`/`string`) as
  near-free, but SELECTIVE ONLY (`import mod.{names}`) — never `.*`-import two modules that
  export colliding names into the same scope.** The general hazard is any two wildcard-imported
  modules with overlapping export names (e.g. `import list.*` + `import string.*` both export
  `startsWith` → `Ambiguous occurrence` compile error); `list`/`string` vs.
  `support.util`/`support.char` (colliding on `contains`, `startsWith`, `isUpper`) is the
  compiler's own concrete instance of this general rule, not the whole rule. This is not a
  bootstrap-generation-specific failure mode: `compiler/entries/llvm_emit_modules_main.mdk`
  (the exact program `test/build_native_medaka.sh` runs) applies no diagnostic gate of any
  class — it emits IR at exit 0 for an ambiguous import exactly as it does for a plain type
  error. That's the already-documented `[W-SOUNDNESS]` gap ("`make medaka` does not gate on
  type errors"), already covered by CI's `compiler-soundness` job — not a new defect, and no
  code fix was needed here. Separately, a module with a NEW type (e.g.
  `map`) IS measurably costly relative to its own baseline: a bare `import map` (zero usage)
  roughly DOUBLED both wall time (0.11s→0.21s) and Ir (608M→1.25B) on a trivial throwaway
  program — real fixed overhead from `map`'s type + impls entering dispatch scope
  ([P-IMPORT-BINDS]), though in absolute terms ~0.1s/~640M Ir is a small fraction of the
  compiler's own ~16.6s/89B-Ir self-check, so a single `map` import into a hot module is
  licensed too, just don't assume it's free on a small/fast-path module. ⚠️ Don't delegate
  hot monomorphic helpers to prelude Foldable methods (`elem`/`any`/`all`/`length`). Migrating
  `support/`→stdlib: a polymorphic empty must be a **nullary constructor**; harnesses need
  `$STDLIB` too.

## [DG-REMOVED] / [WT-VEHICLE] / [WT-SKILL] — full text

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

⚠️ **[DG-REMOVED]** Eight constructs were REMOVED and are now hard parse errors
(`function`, `let mut`, backtick infix, `record`, let-else, named impls, `default impl`, and
the `@Name` impl-hint), gated by `test/check_removed_constructs.sh`. Six have a dedicated
located parser diagnostic naming the replacement; ⚠️ **`let-else` does NOT** — it fails with a
generic *"unexpected `else`; expected a dedent"* that unrelated broken code also produces, so
don't read that message as a parser bug. `@Name` has no replacement (named instances are gone).
**The table is
`docs/spec/SYNTAX.md` § "Removed — do not use"**, which is also the accepted-construct list.
`test/parse_fixtures/rare_constructs.mdk` has examples. Check PLAN.md "Known parser gaps" first.

## Writing tests

🛠️ **[WT-VEHICLE] Pick the vehicle BEFORE you write the test — load the `write-tests`
skill.** The default is native Medaka: a doctest, a `prop`, or a `test` block in a
`*_test.mdk` sibling. When the subject is the compiled binary rather than interpreter
behaviour, the vehicle is still a `*_test.mdk` — registered in `test/gates.toml` with
`kind = "native"` — not a new shell script. Shell is for a trust anchor, external harness,
or instrumentation, and then the script carries a `shell-because:` header that
`medaka gate verify` pairs against its registry row. A shell gate written because the
vehicle cannot yet express the check is debt with a name, `migration = "native-wrap"`, not
a free choice. Epic #2600; design `docs/ops/TESTING-ARCHITECTURE.md`.

🛠️ **[WT-SKILL] Once `write-tests` has said a gate is the right vehicle, load the `gates`
skill** for the authoring half — fixture/golden steps (`[WT-STEPS]`), the CI shard
registration rule, and the dash-not-bash shell half (`[WT-DASH-PRINTF]`, `[WT-TIMEOUT]`).
Add cases to the gate matching the stage changed (parser → `diff_compiler_parse*.sh`) —
that is where a case goes, never the answer to which vehicle to use.

The two that must reach you before you load it — both silent:

- **[T-SHARED-CORPUS]** (below) — a fixture directory is a SHARED CORPUS; adding one enrols
  you in gates you never named.
- 🚨 **[WT-GOLDEN-ENSHRINES]** — a captured golden records what the engine DID, not what's
  CORRECT. Decide the right answer from semantics BEFORE `CAPTURE=1` or `--bless`, snapshot
  and selfproc LEG A included.

## [SK-HARDEN-NARROW] — full text

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

⚠️ **[SK-HARDEN-NARROW]** A `type_error` alone isn't typechecker-internal — if it also threads
through resolve/eval/desugar/AST, it's **add-language-feature** — true of Phases 69 (dispatch),
63 (`deriving`), 72 (field-name reuse), 73 (bidirectional), 83/84 (dict-threading). Check where
the fix lands first.
Typechecker bugs also answer `.claude/workstreams/TYPECHECK.md` (`ws:typecheck`).

## [SK-TABLE] / [DOC-INDEX] — full tables

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

## Task playbooks (skills)

**[SK-TABLE]** Match the task against this table *before* writing a plan
(`.claude/hooks/skill-triage.py` nudges this).

| Skill | When |
|-------|------|
| **add-language-feature** | New construct, whole pipeline; also typechecking-looking cross-cutting work — see [SK-HARDEN-NARROW]. |
| **add-primitive** | Add/modify a stdlib `extern` (`compiler/eval/eval.mdk`). |
| **extend-stdlib** | Pure-Medaka stdlib fn/impl/doctest/prop, not externs. User-reserved. |
| **debug-pipeline** | Parse/typecheck/eval failure or a wrong value; first choice for [T-DISPATCH-LOADER]. Also carries the probe/flag catalogue and the two-arm differential recipe. |
| **gates** | A gate or CI shard went red and you need to know what it proved; or you're adding a fixture, a golden, or a gate. |
| **write-tests** | Asked to "write tests"/"add unit tests" for a module, or about to add ANY check — picks the vehicle (doctest / prop / `*_test.mdk` sibling / `kind = "native"` gate-test / shell) before you write one. Read it before `gates`, not after — see [WT-VEHICLE]. |
| **jev-judgments** | Testing Jev (TypeSafe) against a class of fix candidates, adding or changing a question in `scripts/jev/`, or building a Jev-backed tool from `docs/design/JEV-DESIGN.md`'s roadmap — the enumerate / sample / label / ask / measure / iterate loop, and how to move a question's signal. Never a gate. |
| **harden-typechecker** | Typechecker-*internal*: `type_error`, constraint/coherence/unification. |
| **perf-hunt** | Stage slow, or `diff_compiler_perf_scaling.sh` red. |
| **benchmark-emitter** | `compiler/backend/*` change to measure, or a suspicious fixpoint failure. |
| **add-lsp-capability** | Add/extend an LSP feature. |
| **architecture** | Where a new file/subcommand/subsystem/helper BELONGS, and the standing DECLINED register a planner must not relitigate. Read before adding a file or writing a contract's Surface row. Drift detector: `make arch-census`. |
| **style-review** | The end-of-sprint craft pass (duplication, comment register, test vehicle, placement, diagnostics, docs, CLI shape) — every section a pointer, plus the demands it must NOT make. Once per sprint, never per-PR. |
| **pr-review** | Review an agent-authored PR diff for craft. Read-only, after CI green. |
| **bug-hunt** | Adversarial S0/S1 hunt. Best right after a batch closes. |

⚠️ **[SK-HARDEN-NARROW]** A `type_error` alone isn't typechecker-internal — if it also threads
through resolve/eval/desugar/AST, it's **add-language-feature** — true of Phases 69 (dispatch),
63 (`deriving`), 72 (field-name reuse), 73 (bidirectional), 83/84 (dict-threading). Check where
the fix lands first.
Typechecker bugs also answer `.claude/workstreams/TYPECHECK.md` (`ws:typecheck`).

## Doc index

**[DOC-INDEX]** `docs/README.md` is THE doc index (`make docs-index`, generated). Rows below are
reached for constantly.

| Doc | What's in it |
|-----|--------------|
| `README.md` | Build/test/CLI usage, editor setup, layout |
| `docs/spec/SYNTAX.md` | What the current binary accepts. Ground truth over `language-design.md` |
| `docs/spec/LAYOUT-SEMANTICS.md` | Offside-rule layout spec, formal ground truth |
| `docs/spec/language-design.md` | Design & semantics (may describe unimplemented features) |
| `PLAN.md` / `archive/PLAN-ARCHIVE.md` | Open roadmap / completed Phases 1–97 |
| `compiler/BOOTSTRAP.md` | Self-compile log: B1–B7 + C1–C3 (fixpoint) |
| `compiler/EMITTER-GAPS.md` | Native emitter gap census (E-series) |
| `compiler/ERROR-QUALITY.md` | Error-message rubric — read before writing a diagnostic |
| `compiler/DIAGNOSTIC-CODES-DESIGN.md` | Diagnostic code taxonomy + `Diag` JSON contract |
| `compiler/PERF-RESULTS.md` / `PERF-SCOPE.md` | Perf log / ranked hot paths (`test/bench.sh`) |
| `compiler/STAGE2-DESIGN.md` / `RUNTIME-DESIGN.md` | Backend design: Core IR seam, value rep, GC, per-extern disposition |
| `docs/stdlib/index.md` | **THE stdlib reference** — generated, name-by-name, per-module signatures/docs/impls for every `stdlib/*.mdk` (`./medaka doc --out docs/stdlib stdlib/*.mdk stdlib/*/*.mdk`). Answer "does the stdlib have X" here, not in `STDLIB.md`. |
| `docs/stdlib/STDLIB.md` / `stdlib/README.md` | Stdlib design rationale, history, and open roadmap (demoted from reference — see `docs/stdlib/index.md`) / conventions for externs |
