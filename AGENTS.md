# AGENTS.md

Orientation for AI agents working on **Medaka**, a pragmatic functional language that
**self-hosts to a reproducing fixpoint**: the whole pipeline is written in Medaka
(`compiler/*.mdk`) and compiles via a native LLVM backend
(`compiler/backend/llvm_emit.mdk` → text IR → `clang`; C runtime `runtime/medaka_rt.c` +
Boehm GC) to an OCaml-free `medaka` binary. The OCaml reference compiler was removed
2026-06-26 (tag `oracle-frozen`).

**This file is a *router*: trigger → rule → command.** It is loaded into every session, so
every byte is a per-session cost. Rationale, measurements and incident history live in
`.claude/dossier/` (index: `.claude/dossier/README.md`), keyed by the same `[TAG]`s. **Adding
here? Add the rule and the command; put the story in the dossier.**

**Sprints:** `.claude/skills/sprint-plan/SKILL.md` → `.claude/skills/sprint-orchestrator/SKILL.md`
→ `.claude/skills/sprint-packet/SKILL.md`. Codex: [.codex/SPRINT.md](.codex/SPRINT.md). Pi:
[.pi/SPRINT.md](.pi/SPRINT.md). Claude project memories:
`/root/.claude/projects/-root-medaka/memory/MEMORY.md` (consult when relevant).

> ### ⚡ Editing `compiler/`? Read [`compiler/AGENTS.md`](compiler/AGENTS.md) first.
> Thirteen quadratics so far, all one shape: a `List` used as a set or a map.
> `check` is **GC-bound**; `build`/CI is **clang-bound** — don't conflate them.

## Pipeline

*Dossier: `.claude/dossier/pipeline.md`.* `compiler/` is ONE project (`compiler/medaka.toml`):
`frontend/ types/ ir/ backend/ eval/ driver/ tools/`, plus `support/` (compiler-private
mini-stdlib), `entries/` (per-stage probes), `seed/` (LLVM IR seed for cold bootstrap).

Order (`compiler/driver/medaka_cli.mdk`): `lexer → parser → ast → desugar → resolve →
typecheck (calls exhaust per EMatch) → eval`. All in `compiler/frontend/` except
`types/typecheck.mdk` and `eval/eval.mdk`.

- ⚠️ **[P-DESUGAR-FIRST]** `desugar.mdk` runs before resolve/typecheck. Sugar-shape checks must
  run on the raw AST (`checkGuardExhaustiveness`, `compiler/frontend/exhaust.mdk`).
- ⚠️ **[P-EXHAUST-IN-TYPECHECK]** `checkMatchExhaustive` is called from
  `compiler/types/typecheck.mdk`, once per `EMatch`; it sees only core patterns.
- ⚠️ **[P-NO-MARK-PASS]** `markWithPrelude` (`compiler/frontend/marker.mdk`) is NOT on
  `check`/`run`/`build`/LSP — those mark inside typecheck per binding group
  (`markGroupClauses`), so no production verb sees an `EMethodRef`. The file stays live for
  `preludeStandaloneShadows`, `declRefs`, `localBoundNames`.
- **[P-DOCTEST-RESIDUAL]** #1223 (doctest module identity) is still OPEN for import-bearing
  doctests. It is unpinned and listed in `test/MUST-FAIL-NOT-PINNABLE.txt`.
- ⚠️ **[P-TEST-SIBLING]** A compiler-internal test is a `foo_test.mdk` sibling of `foo.mdk`
  (`foo.test.mdk` does not load). The suffix is excluded from the source fingerprints and the
  snapshot corpus. Run with `medaka test <file>`; if no entry imports it, name it in the
  Makefile's `test:` target ([W-MODULE-BLIND]).

Key support files: `compiler/driver/loader.mdk` (dep walk, `medaka.toml` walk-up),
`compiler/driver/diagnostics.mdk` (accumulating errors), `compiler/driver/build_cmd.mdk`,
`compiler/ir/core_ir_lower.mdk`, `compiler/backend/wasm_emit.mdk`,
`compiler/types/repr.mdk` (type representation and renderers),
`compiler/tools/{fmt,lint,lsp,doctest,test_cmd}.mdk`. CLI conventions:
`docs/ops/CLI-CONFORMANCE.md`. `compiler/tools/mcp.mdk` = `medaka mcp`, 8 tools — **prefer it
over grep/Bash** (`docs/ops/MCP.md`).

**Stdlib:** `core.mdk` is the **only auto-prelude**; `runtime.mdk` is the extern catalog.
**"Does the stdlib have X" → [`docs/stdlib/index.md`](docs/stdlib/index.md)** (generated).
Doc-comment register: `stdlib/README.md` § "Writing documentation".

Imports: `import map.{Map, get}` · `import map.*` · `import map as M` (then `M.get`, `M.Map`,
`M.Tip`). `import m.{f} as A` is rejected.
- ⚠️ **[P-IMPORT-BINDS]** Bare `import map` binds no names, but it brings `map`'s `impl`s into
  dispatch scope.
- ⚠️ **[P-PUBLIC-EXPORT]** `import m.{X(..)}` needs `public export data X` in `m`. Plain
  `export data` exports the type abstractly ("exports no constructors … exported abstractly").

## How work lands: `main` is PROTECTED

*Dossier: `.claude/dossier/workflow.md`, `.claude/dossier/ci.md`.*

**[W-PR-FLOW]** Every change goes through a PR (`git push origin main` → `GH013`). Zero
approvals; checks are the gate.
```sh
git checkout -b <topic>; git push -u origin <topic>; gh pr create --fill
gh pr merge --auto --merge           # enqueues into the merge queue
```
🛠️ **[W-PR-HELPER]** Prefer `scripts/pr.sh` (`body`/`watch`/`enqueue`/`complete`), see
`docs/ops/PR-HELPER.md`.

- **[W-REQUIRED-CHECKS]** Required checks live in a repo **ruleset**. The
  `…/branches/main/protection` endpoint 404s "Branch not protected", which is misleading.
  Derive the list:
  ```sh
  gh api repos/MedakaLang/medaka/rulesets --jq '.[]|select(.enforcement=="active")|.id' | while read -r id; do
    gh api "repos/MedakaLang/medaka/rulesets/$id" --jq '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context'; done
  ```
- 🚨 **Any new `.sh` anywhere in the tree can red a shard.** An unenrolled gate silently never
  runs. Enrol it in `test/gates.toml`. ⚠️ **[W-SHARD-DERIVED]** `shard` is derived by
  `medaka gate balance`, not chosen by you. A hand-edited `shard` reds the required
  `ci-gen-drift`. A brand-new gate has no cost row, so `balance` refuses and that check reds,
  and you **cannot defer it**. Before merge: enrol with any open row, take a cost sample, run
  `medaka gate balance && make gen-ci`, commit both. Carry a
  `Gate-Budget-Override: uncosted:<name>` trailer. If the CI run concludes `failure`, run
  `test/gate_cost_ingest.sh` on the shard's timing artifact directly. Details: the `gates`
  skill and the dossier ([W-SHARD-COST]).
- 🚨 **[W-MODULE-BLIND]** A module outside every entry's import closure is invisible to
  `make medaka`, `make check-self`, `test/typecheck_compiler_source.sh`. Name it in the Makefile's `test:`.
- **[W-SHARD-NEUTRAL]** Executor rows `gates_1`…`gates_8` mean nothing. Read a failure's
  registry `area`, not its row name. Thematic row names are retired.
- ⚠️ **[W-THIRD-CONSUMER]** `test/preflight.sh` derives its own gate set from the diff. Any new
  subproject's paths must be visible to it, or preflight silently widens or narrows.
- ⚠️ **[W-PROJECT-BY-MANIFEST]** A dir with `medaka.toml` outside `compiler/`/`test/` is a
  project. It needs a floor gate under `<project>/test/` and a `test/gates.toml` entry, and
  nothing in preflight. `test/diff_compiler_project_enrolment.sh` checks all three. An
  unmapped path widens every PR to the full suite.
- **[W-SOUNDNESS]** `soundness` is required because `make medaka` does not gate on type errors.
- **[W-MERGE-QUEUE]** The queue tests your PR on top of `main` plus everything ahead of it.
  You don't need to keep your branch up to date. ⚠️ **[W-MERGE-EXIT-CODE]** Exit codes and
  `autoMergeRequest` carry no signal; read `isInMergeQueue`:
  ```sh
  gh api graphql -f query='{repository(owner:"MedakaLang",name:"medaka"){pullRequest(number:N){isInMergeQueue state}}}' --jq '.data.repository.pullRequest'
  ```
- 🚨 **[W-GH-WRITE-VERIFY]** A `gh` write can succeed while writing nothing; read it back.
  `-f body=@file` writes the literal text `@file`, so use `-F`. `gh issue edit --body-file`
  **replaces** the whole body, so to append, read the body, concatenate, then write. A
  `--jq .body` read adds one trailing newline (`head -c -1`). Safe body write:
  `gh api -X PATCH repos/OWNER/REPO/pulls/N -F body=@file`.
- ⚠️ **[W-QUEUE-FROZEN]** An enqueued branch is frozen; later pushes can miss `main` (#1213).
  Verify with `git merge-base --is-ancestor <sha> origin/main`. Stale vs fresh check-runs in
  `statusCheckRollup`: compare `started_at` with your push time.

**What to work on → GitHub Issues**, not a doc:
```sh
gh issue list --label "S0: silent wrongness"      # always start here
gh issue list --label "ws:soundness" --state open # ws:soundness|language|tooling|wasm|diagnostics|testing|release|perf|stdlib|typecheck
gh issue list --label "needs-repro"
gh issue list --label known-red                   # check BEFORE diagnosing a red gate — usually not your break
```
- **[W-SEVERITY]** `S0: silent wrongness` → `S1: loud breakage` → `S2: misleading` →
  `S3: friction & debt`. Soundness outranks release.
- ⚠️ **[W-QUIETER]** A fix that makes a defect **quieter** (loud → silent) is a severity
  INCREASE. If a fix turns "returned nothing" into "returns something", that something is
  untested by construction, so test it from the spec.
- ⚠️ **[W-VERIFIED-VS-REPRO]** Reproduce before you fix. Closing an issue as already-fixed is a
  good outcome.
- `.claude/workstreams/` holds per-workstream domain knowledge; read the one for your labels
  first. `.claude/ORCHESTRATING.md` is the orchestration playbook.

## Build & test

*Dossier: `.claude/dossier/build.md`.*
```sh
make medaka                 # warm: 2-stage rebuild; cold: bootstraps from compiler/seed/ first
./medaka run yourfile.mdk
make -C /abs/worktree medaka   # in a worktree (cwd resets between calls)
```
- 🚨 **[B-STALENESS]** Every `./medaka` run compares a baked source fingerprint
  (`compiler/**.mdk` + `stdlib/**.mdk`, minus `*_test.mdk`) with disk
  (`checkSourceStaleness`). Default is a warning; `MEDAKA_STRICT=1` makes it `exit 1`.
- 🚨 **[B-STDERR]** That warning goes to **stderr only**, and a stale binary still exits 0 with
  a plausible stdout. Never probe freshness via stdout without `MEDAKA_STRICT=1`. Suspect it
  when an empty-stderr gate reds for no reason, or when MCP returns `staleBinary`.
- 🚨 **[B-STRICT-TWO-ARM]** Don't set `MEDAKA_STRICT=1` on both arms of a two-arm differential
  over a shared tree. Assert freshness once, or give each arm its own tree.
- 🚨 **[B-NO-EDIT-DURING-BUILD]** The fingerprint is baked when stage A starts. Edits made
  during `make medaka` are silently missing from the binary.
- **[G-BUILD-RACE]** Concurrent `medaka build` is safe. Two `make medaka` runs in the same
  worktree are NOT (#1141).
- 🚨 **[B-NO-BORROW-ISOLATED]** Never `cp` an emitter from another tree; just
  `make -C <abs-worktree> medaka`. A fresh worktree is usually cache-served (~1s). A forced or
  cold rebuild costs ~1.5 min. Timings: dossier. [B-BORROW-EMITTER]: `sprint-orchestrator` skill.
- 🚨 **[B-ISOLATION-COMPOUND]** (#1148) In an isolated worktree the classifier refuses compound
  shells (`cd X && …`, `;`-chains, heredocs, `for`, pipes into `git`, redirect + `-C`). **One
  plain command per Bash call**; multi-step work goes into a script file. If `make medaka` is
  denied, try `sh test/build_native_medaka.sh`. If every form is denied, stop and report. Don't
  degrade to source-only work.
- 🚨 **[B-RELPATH-DENY]** (#1823) `medaka fmt --write`/`lint` on a relative path can be denied.
  Always pass absolute paths.
- **[B-ENV]** clang + Boehm GC (`libgc-dev` / `brew install bdw-gc`); `node` ≥24 for
  wasm/sqlite/playground; `gh` 2.101+ from `cli.github.com/packages`. No opam/dune.
  **[B-BOX]** Dedicated Debian 13 x86_64 box, 12 cores/32GB, repo at `/root/medaka`; build
  natively (ignore `scripts/docker-dev.sh`).
- ⚠️ **[B-DUAL-PLATFORM]** Every script must run on Linux AND macOS (`stat -c %Y`/`stat -f %m`,
  `pkg-config`/`brew --prefix bdw-gc`). ⚠️ **[B-CI-UBUNTU-ONLY]** Required checks are
  Linux-only (#2533). The macOS smoke runs nightly and on `runtime/`/build/release PRs, so a
  macOS-only break elsewhere ships green. Smoke-test macOS by hand before a release (#549).

### ⚡ THE AGENT LOOP: `make preflight` — never the full suite locally

*Dossier: `.claude/dossier/gates.md`.*

**[L-PREFLIGHT]** Before building or running gates: `medaka fmt --write` + `medaka lint` on
touched `.mdk`, then re-`git add`. If you changed fmt/lint/syntax, redo that with the new
binary. Then:
```sh
PREFLIGHT_DRY=1 sh test/preflight.sh               # derive the gate set; runs nothing
make preflight                                     # gates + oracles derived from YOUR diff
sh test/run_gates.sh 'diff_compiler_parse*'        # targeted (multiple patterns OK; no braces)
sh test/build_oracles.sh --for --list '<pattern>'  # derive oracle names only
sh test/build_oracles.sh --for 'diff_compiler_*'   # fresh-worktree oracle build, ~2 min
FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one <name>
```
- ⚠️ **[L-DERIVE-ONLY]** `--list` must come immediately after `--for`. Reversed, it silently
  BUILDS.
- **[L-SHARED-BOX]** The box is shared. ❌ No bare `sh test/run_gates.sh` or
  `FORCE=1 sh test/build_oracles.sh`.
- 🚨 **[L-FOREGROUND-CEILING]** preflight on `compiler/backend/*`, perf_scaling or engines can
  pass the 600s ceiling (`exit 143` is the ceiling, not a hang). Knobs: `PERF_N`,
  `ENGINE_JOBS`, `ONLY=<glob>`. Background it and poll.
  ⚠️ **[L-NO-FULL-NOT-FIXPOINT]** `PREFLIGHT_NO_FULL` doesn't skip the fixpoint. **As a
  subagent, wait on a background job within your turn**, because its notification goes to
  your dispatcher.
- ⚠️ **[L-BLAST-RADIUS]** On `stdlib/*`, `compiler/support/*`, `compiler/entries/*`, preflight
  IS the full suite. Push and let CI run it. A full local run is justified only for backend,
  support or `core.mdk` changes, a same-subsystem merge, or a CI failure you can't reproduce.
- ⚠️ **[L-PREFLIGHT-IS-FILTER]** The merge queue is the authority. A narrowed shard can be green
  having run nothing. To check what actually ran:
  `gh api repos/MedakaLang/medaka/actions/runs/<id>/jobs --paginate --jq '.jobs[]|"\(.name)\t"+([.steps[]?|"\(.name)=\(.conclusion)"]|join(" | "))'`.
- **[L-PHANTOM-SKIP]** "phantom skip: oracle/binary not built" means nothing was built (it
  counts as FAILED), not a regression. 🚨 **[L-SELFPROC-CARVEOUT]** Except for
  `diff_compiler_selfproc` on a compiler-source change: build `check_all_main`,
  `eval_modules_main`, `eval_typed_modules_main` with `--build-one`, then require
  `sh test/diff_compiler_selfproc.sh` to say "N ok, 0 failing" ([T-LEGA-GOLDEN]).

### Gates
```sh
make test               # in-language suite (doctests, props, `test` blocks)
make gates              # full differential suite — CI's job, not yours
make docs-links         # every cited path exists
make agent-doc-symbols  # every backticked symbol in agent docs resolves
make docs-index         # regenerate docs/README.md (generated — never hand-edit)
```
- 🛠️ **[G-SKILL]** A gate is red, or you're adding one? Load the **`gates` skill**
  ([G-LIST], [G-PIN-DRAIN], [G-DRAIN-INVISIBLE], [G-PARALLELISM], authoring). Check
  `known-red` first.
- 🚨 **[G-MUST-FAIL]** `test/diff_compiler_must_fail.sh` has **inverted polarity**: each
  fixture pins an OPEN bug, so RED is healthy. Never delete or repoint a fixture to make it green.
- **[G-STALE-ORACLE]** `run_gates.sh` refuses stale oracles (`NO_STALE_CHECK=1` overrides).
- 🚨 **[G-GOLDEN-CAPTURE-UNGUARDED]** Golden capture and `--bless` have no staleness guard.
  After any merge or rebase, rebuild oracles before capturing ([WT-GOLDEN-ENSHRINES]).

### Pre-commit hook (`.githooks/pre-commit`)

*Dossier: `.claude/dossier/tooling.md`.* It runs over staged `.mdk`, excluding `test/`.
Reinstall: `cp .githooks/pre-commit "$(git rev-parse --git-common-dir)/hooks/pre-commit"`.
`--no-verify` bypasses it. With `medaka` unbuilt, it warns and allows.
- **[H-FMT]** `medaka fmt --write <abs path>` then re-`git add` (bare `fmt` is read-only). The
  tree is not fully fmt-clean; to see the current set: `make fmt-clean-census`.
- **[H-LINT]** All rules gated. Run `medaka lint` on what you touch; read the output, because
  the exit code lies without `--deny` (#1822). Suppress with `-- lint-disable-next-line
  <rule>`. `--fix` bails on decls with interior comments.
- **[H-SNAPSHOT]** Check only: `make snapshot-check`. Bless with
  `sh test/snapshot_bless.sh --bless <file>` and stage `test/snapshots/`.
  **[H-SNAPSHOT-NEW]** For a new source file use `--new` (suite-wide), then re-run the check.
  **[H-SNAPSHOT-UNSTAGED]** It reads the working tree. **[H-DEFER]**
  `PRECOMMIT_SNAPSHOT_DEFER=1 git commit` skips the snapshot check only.
  🚨 **[H-DEFER-VS-GUARD]** Bless and stage goldens LAST.
- **[H-LEXTOK]** Stale `.lextok.golden` → `sh test/capture_goldens.sh --frozen lextok`.
- **[H-LINT-BASELINE]** / **[H-COMMENT-REGISTER]** Per-file count ratchets that may only fall.
  Regenerate with `sh test/diff_compiler_lint_baseline.sh --write` /
  `sh test/comment_register_census.sh --write test/comment_register_baseline.toml`, never by hand.
- **[H-EMOJI-SHOUT]** A commit may not ADD a 🚨/⚠️/🔒 line, or a run of 3+ ALL-CAPS words in a
  comment, to `.mdk`. Rewriting a sigil line counts as adding one, so drop the sigil.

### Debugging

🛠️ **[D-SKILL]** Load **`debug-pipeline`** for probes ([D-CHECK-JSON], [D-TYPES-FLAG],
[D-CORE-IR-TYPED], [D-CORE-IR-TRAP], [D-KEEP-IR], [D-EMITTER-CLI]) and the two-arm recipe
([D-TWO-ARM], [D-TWO-ARM-RUNTIME]). Silent traps:
- **[D-RUN-VS-BUILD]** `run` and `build` share the typechecker, so their agreeing is not
  corroboration.
- ⚠️ **[D-GATE-OVERRIDE]** Some gates hardcode their binary, so a two-arm run reports
  "identical". Derive which ones take an override (`debug-pipeline`).
- 🚨 **[D-BUILD-PIPE]** `medaka build`'s exit code doesn't survive a pipe. Redirect to a file,
  read `$?`, then read the file.
- 🚨 **[D-TWO-ARM-STDLIB]** A binary resolves stdlib from `exeDir`, not cwd. For a `stdlib/*`
  target, give each arm its own tree or its own `MEDAKA_ROOT`.

Writing a diagnostic: `compiler/ERROR-QUALITY.md` + `compiler/DIAGNOSTIC-CODES-DESIGN.md`.

## The website — <https://medaka-lang.dev>

*Dossier: `.claude/dossier/website.md`; procedure: `playground/README.md` § Deploying.* The
playground is the site: static Cloudflare Pages, compiler in WasmGC. Deploy:
`bash playground/deploy_cloudflare.sh`.
- 🚨 **[WEB-PREVIEW-SILENT]** The deploy must pass `--branch`. Without it, it publishes a
  preview and exits 0. Verify the origin:
  `curl -sS -o /dev/null -w '%{http_code}\n' https://medaka-lang.dev/dist/array.mdk`.
- 🚨 **[WEB-SITE-FILE-LIST]** `build_site.sh` copies an explicit file list. Keep its
  fail-closed check against `main.js`.
- 🚨 **[WEB-STALE-DIST]** It ships whatever `playground/dist/` holds. Before deploying: run
  `bash playground/build_playground_wasm.sh`, `rm -rf playground/site`, deploy, then compile
  a probe against the live wasm.
- ⚠️ **[WEB-OG-ABSOLUTE]** `og:image` is absolute, so preview origins show no card. That's
  expected.
- ⚠️ **[WEB-SH-IS-A-GATE]** preflight executes any new `.sh` under `playground/` unless it is
  listed in `test/CI-COVERAGE-TOOLS.txt`. Unlisted, it once ran a live deploy.

## Traps

*Dossier: `.claude/dossier/traps.md`.*

- ⚠️ **[T-EMITTER-BENCH]** Measuring an emitter change? Read `benchmark-emitter` first.
  Rebuild twice with `FORCE_EMITTER_REBUILD=1 make medaka`; run `test/refresh_seed.sh` twice
  after a codegen change.
- ⚠️ **[T-PERF-HUNT]** Slow stage or red `perf_scaling`: read `perf-hunt` and profile
  **allocation**. `whenL False (expensiveCall …)` still evaluates its argument.
- ⚠️ **[T-DISPATCH-LOADER]** A dispatch bug that shows only via the loader is usually the
  EVAL DRIVER. Regressions go in the `eval_modules_fixtures` rows of
  `test/diff_compiler_eval_test.mdk`.
- ⚠️ **[T-EVAL-LOCKSTEP]** `evalModules` and `cevalModules` are parallel drivers; fix both.
  Cross-module tables key per module, never by bare name.
- 🚨 **[T-GLOBAL-TABLE]** For a new global table or AST ctor, add a fixture showing that
  unrelated code still behaves. Audit every `_ =>` arm. Key tables by scope (`<iface>@<slot>`).
- ⚠️ **[T-FIXTURE-LINES]** Goldens pin `file:LINE:COL`, so keep fixture edits
  line-count-neutral or re-derive the golden.
- ⚠️ **[T-PERRUN-COMMENTS]** #829: after `fmt --write` on a comment-bearing record decl, diff
  the result by eye.
- ⚠️ **[T-COMMENT-REGISTER]** A comment states a constraint the code can't show. No history,
  PR litigation or emoji shouts in source. A relocation pointer names a repo-relative path.
  Census: `make comment-census`.
- ⚠️ **[T-SHARED-CORPUS]** Adding, moving or deleting a fixture enrols you in every gate that
  reads that directory. Enumerate them all (`test/wasm/*.sh` included).
- ⚠️ **[T-SNAPSHOT-SELF]** Compiler source is in the snapshot corpus; bless it in the same PR
  with `sh test/snapshot_bless.sh --bless <path>`.
- ⚠️ **[T-LEGA-GOLDEN]** A top-level-binding change in a LEG A module
  (`frontend.{ast,desugar,exhaust,lexer,marker,parser,resolve}`, `types.{annotate,typecheck}`,
  `driver.loader`, `eval.eval`, `ir.sexp`, `tools.check`) moves
  `test/selfproc_goldens/legA/<module>.golden`. Re-capture with
  `sh test/capture_goldens.sh --frozen selfproc_legA`; the diff must be additive-only.
- 🚨 **[T-LEGA-REBASE]** A rebase silently blends the LEG A golden. Never hand-resolve; re-derive:
  ```sh
  BASE=$(git rev-parse origin/main); git checkout "$BASE" -- test/selfproc_goldens/legA test/snapshots
  make -C "$PWD" medaka && sh test/capture_goldens.sh --frozen selfproc_legA
  sh test/snapshot_bless.sh --bless <moved source file>; git diff -- test/selfproc_goldens/legA test/snapshots  # additive-only
  ```
- **[T-STDLIB-IMPORT]** The compiler may import `list`/`string` **selectively** (near-free).
  Never `.*`-import two modules with colliding names. A new-type module like `map` has real
  fixed cost. Don't route hot helpers through Foldable (`elem`/`any`/`length`).
- **[T-TUPLES]** Tuples are `__tupleN__`-headed `TApp` spines, not `TTuple` (`compiler/TUPLE-TYPE-CONSTRUCTOR-DESIGN.md`).
- **[T-ERRORS-ACCUM]** Errors accumulate in `compiler/driver/diagnostics.mdk`. No early exits.
- **[T-MAIN-ZERO-ARG]** `main = …` is a value; `main () = …` is an error on `run`/`build`.
  `main = 1 + 2` is a valid probe.
- **[T-LAMBDA]** Multi-arg lambdas are `x y => body`.
- **[T-PRELUDE-DICT]** Only the typed pipeline dict-passes the prelude. Untyped eval is "first
  impl wins", so `pure` needs types.
- **[T-GUARDS]** Match guards and `Pat <- e` guards lower natively (`compiler/EMITTER-GAPS.md`).
- **[T-WORKTREE-PATHS]** In a worktree, always use absolute paths.
  **[T-WORKTREE-REFS]** `.git` is shared, so pin `BASE=$(git rev-parse HEAD)` at task start
  (`.claude/workstreams/HARNESS.md` H-2).
- **[T-LAYOUT-SPEC]** `docs/spec/LAYOUT-SEMANTICS.md` is layout ground truth. A token stream
  the parser can't consume is a parser bug.
- **[T-PHASES]** Open phases are in `PLAN.md`; completed 1–97 are in `archive/PLAN-ARCHIVE.md`.

## Language, tests, skills, docs

- **[DG-IDIOMS]** Use idioms where they read better: sections `(+ 1)`, `(2 * _)`, `|>`,
  `[lo..=hi]`, `{ r | f = v }`. Unary `!` is Ref-deref; `not` negates.
- ⚠️ **[DG-REMOVED]** `function`, `let mut`, backtick infix, `record`, let-else, named impls,
  `default impl` and `@Name` are hard parse errors. let-else gives a generic "unexpected
  `else`". Full table: `docs/spec/SYNTAX.md` § "Removed — do not use".
- 🛠️ **[WT-VEHICLE]** Before writing a test, load **`write-tests`** to pick the vehicle. The
  default is native: a doctest, `prop`, or `test` in a `*_test.mdk`. A shell gate needs a
  `shell-because:` header. 🛠️ **[WT-SKILL]** Then load **`gates`** for authoring ([WT-STEPS],
  [WT-DASH-PRINTF], [WT-TIMEOUT]).
- 🚨 **[WT-GOLDEN-ENSHRINES]** A golden records what the engine DID. Decide the correct answer
  from semantics before `CAPTURE=1`/`--bless`.
- **[SK-TABLE]** Match the task to a `.claude/skills/` playbook before planning
  (`.claude/hooks/skill-triage.py` nudges this). Each skill's description says when it applies.
  ⚠️ **[SK-HARDEN-NARROW]** A `type_error` that also threads through
  resolve/eval/desugar/AST is **add-language-feature**, not **harden-typechecker**
  (`.claude/workstreams/TYPECHECK.md`).
- **[DOC-INDEX]** `docs/README.md` is the generated doc index. Most used: `docs/spec/SYNTAX.md`
  (ground truth for syntax), `docs/spec/language-design.md` (may describe unimplemented
  features), `compiler/BOOTSTRAP.md`, `compiler/EMITTER-GAPS.md`,
  `compiler/STAGE2-DESIGN.md`, `compiler/RUNTIME-DESIGN.md`, `compiler/PERF-RESULTS.md`.
