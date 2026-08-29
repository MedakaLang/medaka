# AGENTS.md

Orientation for AI agents working on **Medaka**, a pragmatic functional language that
**self-hosts to a reproducing fixpoint**: the whole pipeline is written in Medaka
(`compiler/*.mdk`) and compiles via a native LLVM backend
(`compiler/backend/llvm_emit.mdk` → text IR → `clang`; C runtime `runtime/medaka_rt.c` +
Boehm GC) to an OCaml-free `medaka` binary. Native is the **sole** compiler — the OCaml
reference compiler was removed 2026-06-26 (tag `oracle-frozen` preserves the last
`lib/`-present commit).

**This file is a *router*: maps, traps, and links.** It does not teach. For prose,
rationale, and post-mortems, follow the links — and don't assume detail that isn't here.

> **Claude project memories are available on this machine:**
> `/root/.claude/projects/-root-medaka/memory/MEMORY.md`. Consult when durable project
> decisions or prior-session learnings are relevant; do not load automatically.

> ### ⚡ Editing `compiler/`? Read [`compiler/AGENTS.md`](compiler/AGENTS.md) first.
> Thirteen quadratics found so far, all the same shape: a `List` used as a set or a map.
> `check` is **GC-bound**; `build`/CI is **clang-bound** — don't conflate them.

`compiler/` is ONE Medaka project (`compiler/medaka.toml`):

| Subfolder | Contents |
|---|---|
| `frontend/`, `types/`, `ir/`, `backend/`, `eval/`, `driver/`, `tools/` | see stage/support tables below |
| `support/` | compiler-private mini-stdlib |
| `entries/` | per-stage probe entry points |
| `seed/` | checked-in LLVM IR seed, cold bootstrap |

## Pipeline — where each stage lives

*Incident narrative, where an item below has any: `.claude/dossier/pipeline.md`.*

**Order** (`compiler/driver/medaka_cli.mdk` — *not* file listing order):

```
lexer.mdk → parser.mdk → ast.mdk → desugar.mdk → resolve.mdk → marker.mdk
  → typecheck.mdk (runs exhaust.mdk internally) → eval.mdk
  [all compiler/frontend/ except typecheck.mdk (types/), eval.mdk (eval/)]
```

⚠️ **[P-DESUGAR-FIRST]** `desugar.mdk` runs FIRST, before resolve/typecheck — surface-sugar
already core by typecheck/exhaust/eval. Sugar-shape checks must run pre-desugar, on the raw
AST (`checkGuardExhaustiveness`, `compiler/frontend/exhaust.mdk`).

⚠️ **[P-EXHAUST-IN-TYPECHECK]** `exhaust.mdk` isn't standalone — `checkMatchExhaustive` is
*called from* `compiler/types/typecheck.mdk` (once per `EMatch`). Only ever sees core
patterns.

| Stage | File | Role |
|-------|------|------|
| Lex | `compiler/frontend/lexer.mdk` | Indentation-sensitive; INDENT/DEDENT/NEWLINE |
| Parse | `compiler/frontend/parser.mdk` | Recursive-descent grammar |
| AST | `compiler/frontend/ast.mdk` | Node types + source locations |
| Desugar | `compiler/frontend/desugar.mdk` | `deriving`, record puns, `EGuards`/`ESection`/`EStringInterp`/`EDo`, default-method specialization |
| Resolve | `compiler/frontend/resolve.mdk` | Name binding, single/multi-module |
| Mark | `compiler/frontend/marker.mdk` | Post desugar+resolve, pre typecheck. `EVar`→`EMethodRef` (impl key per call site) |
| Typecheck | `compiler/types/typecheck.mdk` | Hindley-Milner + interfaces + effects; invokes Exhaust per `EMatch` |
| Exhaust | `compiler/frontend/exhaust.mdk` | Maranget pattern-matrix; called *from* typecheck |
| Eval | `compiler/eval/eval.mdk` | Tree-walking interpreter; dict-passing dispatch |

Support files:

| File | Role |
|------|------|
| `compiler/driver/loader.mdk` | Multi-file dep walk, topo sort, cycle detection; `medaka.toml` root walk-up |
| `compiler/driver/diagnostics.mdk` | Accumulating error pipeline — no exit-on-error |
| `compiler/driver/build_cmd.mdk` | `medaka build` — Core IR → LLVM emit → clang |
| `compiler/driver/medaka_cli.mdk` | CLI: `check`/`fmt`/`new`/`build`/`run`/`test`/`doc`/`lint`/`manifest`/`repl`/`lsp` |
| `compiler/ir/core_ir.mdk` + siblings | Core IR types; lowering `core_ir_lower.mdk`, S-expr `core_ir_sexp.mdk`, DCE `dce.mdk`, interpreter `core_ir_eval.mdk` |
| `compiler/backend/llvm_emit.mdk` | LLVM text IR emitter |
| `compiler/backend/wasm_emit.mdk` | WasmGC text IR emitter (2nd backend) |
| `compiler/backend/private_mangle.mdk` | Universal constructor mangling |
| `compiler/backend/trmc_analysis.mdk` | Tail-recursion-modulo-cons analysis |
| `compiler/types/annotate.mdk` | Type annotation helpers |
| `compiler/tools/printer.mdk` / `fmt.mdk` | AST→source round-trip / comment-preserving formatter |
| `compiler/tools/lsp.mdk` | LSP/stdio: diagnostics/fmt/symbols/hover/definition/highlight/completion/inlay |
| `compiler/tools/mcp.mdk` | `medaka mcp` — MCP stdio, 8 tools (check/type_at/symbols/definition/references/fmt/lint/test). **Prefer over grep/Bash.** `docs/ops/MCP.md` |
| `compiler/tools/lint.mdk` | `medaka lint` — AST linter, RAW pre-desugar AST; `Rule`/`CrossFileRule`; `--fix`/`--deny`/`--disable`/`--only` |
| `compiler/tools/doctest.mdk` | Doctest extraction. **[P-DOCTEST-RESIDUAL]** #1223 OPEN: no-import FIXED, `runMulti` (import-bearing) not — pinned `diff_compiler_origin_agreement.sh`. Derive: `grep -n 'SAME multi-module path' compiler/tools/test_cmd.mdk` |
| `compiler/tools/check.mdk` / `check_policy.mdk` | `medaka check` entry + policy checker |
| `compiler/tools/test_cmd.mdk` / `prop_runner.mdk` | `medaka test` — doctests + property tests |
| `compiler/tools/doc.mdk` / `new_cmd.mdk` / `repl.mdk` | `medaka doc` / `new` / `repl` |
| `compiler/support/util.mdk` + siblings | Compiler-private helpers, thin `stdlib/` wrappers. Weigh imports per module — [T-STDLIB-IMPORT] |

`stdlib/` modules: `runtime.mdk` (extern catalog), `core.mdk` (**only auto-prelude**),
`list`/`string`/`array`, `map`/`set` (ordered trees), `hash_map`/`hash_set` (mutable hash),
`mut_array` (growable vector), `json`, `byteparser`/`bytebuilder`, `io.mdk` (ergonomic layer
over `runtime.mdk` IO).

Import forms: `import map.{Map, get}` (selective), `import map.*` (all exported), `import
map as M` → `M.get` (**values only** — an alias-qualified name in *type* position is a parse
error, so import types by name). `import
m.{f} as A` / `import m.* as A` rejected, diagnostic names the fix.

⚠️ **[P-IMPORT-BINDS]** Bare `import map` binds NO names but is **not** a no-op — any import
brings that module's `impl`s into dispatch scope. Example → dossier.

⚠️ **[P-PUBLIC-EXPORT]** `(..)` constructor import needs the DEFINING module to write
`public export data`, not plain `export data`. Trigger: exit 1, *"'X' exports no
constructors from module 'm' (exported abstractly). Remove '(..)' or export with 'public
export'"*.
```sh
printf 'import m.{X(..)}\n\nmain = println 1\n' > /tmp/p/main.mdk
printf 'export data X = X Int\n'        > /tmp/p/m.mdk; ./medaka check /tmp/p/main.mdk; echo "abstract -> $?"  # 1
printf 'public export data X = X Int\n' > /tmp/p/m.mdk; ./medaka check /tmp/p/main.mdk; echo "public   -> $?"  # 0
```

## 🚦 How work lands: `main` is PROTECTED — you cannot push to it

*Incident narrative, where an item below has any: `.claude/dossier/workflow.md`.* For
`ci.yml` shard-cost derivation, build-once/fan-out, and per-shard job-guard mechanisms
specifically, see `.claude/dossier/ci.md`.

**[W-PR-FLOW] Every change goes through a PR.** `git push origin main` fails with `GH013:
Repository rule violations` — no admin bypass.

```sh
git checkout -b <topic>              # never commit on main
# ... work; verify with `make preflight` ...
git push -u origin <topic>
gh pr create --fill
gh pr merge --auto --merge           # merges itself the moment every required check goes green
```

🛠️ **[W-PR-HELPER] Prefer `scripts/pr.sh`** (`body` / `watch` / `enqueue` / `complete`) over
hand-rolled `gh` writes — see `docs/ops/PR-HELPER.md`.

**[W-REQUIRED-CHECKS] Required checks live in a repo RULESET, not classic branch protection.**
🚨 **NOT `…/branches/main/protection…` — that endpoint 404s `"Branch not protected"`, which
reads exactly like "nothing is required here".** (Same rules engine is why `git push origin
main` fails with `GH013`.) Derive the current set, never trust a list in this file:
```sh
gh api repos/MedakaLang/medaka/rulesets --jq '.[]|select(.enforcement=="active")|.id' | while read -r id; do
  gh api "repos/MedakaLang/medaka/rulesets/$id" \
    --jq '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context'
done
```
🚨 **Adding ANY `.sh` anywhere in the tree — not just under `test/` — can redden a shard**
(`diff_compiler_ci_shard_coverage.sh`; a repro harness under `.claude/` has done it). A gate
not enrolled in `test/gates.toml` (with a `shard` field) SILENTLY NEVER RUNS — enrol it there
and run `make gen-ci` to regenerate `ci.yml`'s shard matrix. Registration rules, the
`test/CI-COVERAGE-EXCEPTIONS.txt` escape hatch, and `[W-SHARD-COST]` (shards are scheduled by
cost, not theme): the `gates` skill.

⚠️ **[W-THIRD-CONSUMER] `ci.yml` shard patterns are TWO classifications, not the whole
list.** `test/preflight.sh` independently derives its own gate set from the diff (its
`changed path → gate patterns` case block, [L-PREFLIGHT]) — a THIRD consumer any new
subproject's files/patterns must also be visible to, or `make preflight` silently widens or
narrows scope with no error.

⚠️ **[W-PROJECT-BY-MANIFEST] A directory with a `medaka.toml` outside `compiler/` and
`test/` IS a project, and CI knows it by that manifest — not by anyone remembering.** Such
a project needs a floor gate under `<project>/test/` (a `pattern:` matching no gate is a
hard `::error::`, so the gate must exist before the enrolment does), a `shard` field in
`test/gates.toml` placed by measured cost (then `make gen-ci` to regenerate `ci.yml`'s shard
matrix), and nothing at all in `test/preflight.sh` — preflight's generic arm
derives the project set from `git ls-files '*medaka.toml'` and maps any changed path under
`<project>/` to `<project>/test/*` on its own. All three legs are re-derived and compared on
every run by `test/diff_compiler_project_enrolment.sh`, so enrolment drift reds a gate rather
than going quiet. ⚠️ **An unenrolled project is not merely untested — an UNMAPPED non-prose
path widens every PR run to the FULL suite** ([W-THIRD-CONSUMER]), so the map gap costs the
most expensive possible answer while proving nothing. `demo/` and `playground/` have no
manifest and are NOT projects; preflight derives their gates per-path instead
(`_gates_for_path`), from which gate scripts actually reference them.

**Zero approvals required** — the checks are the gate; an agent can self-merge on green.
`--auto` enqueues into the merge queue ([W-MERGE-QUEUE]).

- **[W-SOUNDNESS] `soundness` is required because no gate shard catches an ill-typed
  compiler** — `make medaka` does not gate on type errors.
- **[W-MERGE-QUEUE] `gh pr merge --auto --merge` enqueues** — the queue tests your PR merged
  onto current `main` plus everything queued ahead of you, and merges only if that's green.
  **You do NOT need to keep your branch up to date with `main`.**

  ⚠️ **[W-MERGE-EXIT-CODE] Its exit code carries no signal either way — read back the state,
  never the return code.** Don't trust `autoMergeRequest` either. The real signal is
  `isInMergeQueue`:
  ```sh
  gh api graphql -f query='{repository(owner:"MedakaLang",name:"medaka"){pullRequest(number:N){isInMergeQueue state}}}' --jq '.data.repository.pullRequest'
  ```

🚨 **[W-GH-WRITE-VERIFY] A `gh` write can report success while writing nothing — always read
the result back, never the exit code.** Three concrete traps beyond [W-MERGE-EXIT-CODE], the
first two both hit in one session (#1212):
  - `gh pr edit --body-file <f>` can silently no-op (observed on a Projects-classic deprecation
    error) — the body is unchanged but the command exits 0. Verify by re-reading the body
    length, not the exit code. Workaround: `gh api -X PATCH repos/OWNER/REPO/pulls/N -f body="…"`.
  - **`-f body=@file` does NOT expand `@file`** — it writes the four literal characters `@file`
    as the body. Only `-F` expands `@file` into the file's contents. This is the workaround for
    the bullet above, so routing around one bug lands directly in the other.
  - **`gh issue edit --body-file <f>` REPLACES THE WHOLE BODY** — using it to append silently
    CLOBBERS prior content. Not a no-op and not a literal-string bug — it succeeds and destroys
    (#1824). For an append: read the existing body first (`gh issue view N --json body -q
    .body`), concatenate the new content locally, then write the full combined result back —
    never `--body-file` with just the new fragment.

⚠️ **[W-QUEUE-FROZEN] Once a PR is enqueued, treat its branch as frozen.** The queue merges the
branch as it stood at enqueue time — a commit pushed afterward can be left behind, landing on
the branch but not in what actually reaches `main` (#1213). Need a change after enqueue? Dequeue
first, or land it as a follow-up PR. Checking `origin/<branch>` is NOT sufficient once queued —
verify against `main` itself:
```sh
git merge-base --is-ancestor <sha> origin/main && echo "on main" || echo "NOT on main"
```
Same trap, adjacent: a stale check-run in `statusCheckRollup` looks identical to a fresh one.
Discriminate by `started_at` vs. your push time, not by conclusion alone:
```sh
gh api repos/MedakaLang/medaka/commits/$SHA/check-runs --jq '.check_runs[]|"\(.name) \(.conclusion) \(.started_at)"'
```

### 🎯 "What should I work on?" → **GitHub Issues.** Not a doc.

```sh
gh issue list --label "S0: silent wrongness"      # always start here — silent wrongness beats everything
gh issue list --label "ws:soundness" --state open # one workstream (ws:soundness|language|tooling|wasm|
                                                  #   diagnostics|testing|release|perf|stdlib|typecheck)
gh issue list --label "needs-repro"               # inherited claims NOBODY has reproduced
gh issue list --milestone "0.1.0 public preview"  # the release floor
```

**[W-SEVERITY] Severity:** `S0: silent wrongness` (a wrong answer or destroyed source, **with
no error**) → `S1: loud breakage` → `S2: misleading` → `S3: friction & debt`. **Soundness
outranks release.**

> ### ⚠️ [W-QUIETER] A fix that makes a defect QUIETER is a severity INCREASE — even when the old behaviour was also broken.
>
> **loud → silent is a regression.**
>
> **The reviewer's question:** *does this fix turn a path that returned NOTHING into one that
> returns SOMETHING?* If so, **the new something is untested by construction** — build the
> test from the spec, not from the diff or from coverage.

⚠️ **[W-VERIFIED-VS-REPRO] `verified` vs `needs-repro` is load-bearing. REPRODUCE BEFORE YOU
FIX.** Closing an issue as already-fixed is a good outcome; say so.

| Path | What it is |
|------|-----------|
| `.claude/workstreams/` | Per-workstream **domain knowledge**: the traps, the collision map, and *why each bug class recurs*. **Not the backlog** (that is the issue tracker) — read the one matching your labels **before** you start. |
| `.claude/ORCHESTRATING.md` | Orchestration playbook. Its #1 lesson: *the gap docs lie — reproduce before you trust them.* |
| `gh issue list --label known-red` | **Known-red gates.** Check BEFORE diagnosing a failing gate — it is usually not your break. One issue per expected-red gate, closed when the gate is green again. |
| `.claude/skills/` | Task playbooks (table at the bottom of this file). |

## Build & test

*Incident narrative, where an item below has any: `.claude/dossier/build.md`.*

```sh
make medaka          # WARM (./medaka_emitter present): 2-stage rebuild from current source
                     # COLD (fresh clone): bootstraps from compiler/seed/emitter.ll.gz first
./medaka run yourfile.mdk
```

🚨 **[B-STALENESS] Every `./medaka` run compares a baked-in source fingerprint
(`<root>/compiler/*.mdk`) to disk** (`checkSourceStaleness`, `compiler/driver/medaka_cli.mdk`).
Mismatch = binary built from older source. Default: warning only. **`MEDAKA_STRICT=1`** → hard
`exit 1`. One site emits it: `grep -rn 'may be stale; rebuild' compiler/`.

🚨 **[B-STDERR] The warning is STDERR-ONLY — `2>/dev/null` hides it, and a stale binary still
exits 0 with a right-looking stdout answer.** Never probe freshness via stdout/exit code without
`MEDAKA_STRICT=1`; read stderr or the exit code instead. Suspect this (not a regression) when an
empty-stderr gate goes red for no reason (#1421), or an MCP result grows `staleBinary`
(`attachStaleness`, `compiler/tools/mcp.mdk`). Remedy — force stale state via `MEDAKA_ROOT`:
```sh
mkdir -p /tmp/fake/compiler; printf 'x = 1\n' > /tmp/fake/compiler/bogus.mdk; ln -s "$PWD/stdlib" /tmp/fake/stdlib
printf 'main = println 12345\n' > /tmp/hello.mdk
MEDAKA_ROOT=/tmp/fake ./medaka run /tmp/hello.mdk 2>/dev/null   # 12345 — warning invisible, exit 0
MEDAKA_ROOT=/tmp/fake ./medaka run /tmp/hello.mdk >/dev/null    # the warning, on stderr
```

**In a worktree:** cwd resets between calls — use `make -C /absolute/path/to/worktree medaka`.

🚨 **[B-STRICT-TWO-ARM] `MEDAKA_STRICT=1` on BOTH ARMS of a two-arm differential breaks it** — a
shared compiler tree means the older arm's fingerprint can never match, reporting "everything
differs." ⇒ **Assert freshness ONCE, on the arm where it can be true**, or give each arm its own
`compiler/` tree. (PR #1645 incident → dossier.)

🚨 **[B-NO-EDIT-DURING-BUILD] DO NOT EDIT COMPILER SOURCE WHILE A BUILD IS IN FLIGHT** — the
fingerprint is baked at STAGE A START. A `.mdk` edit after `make medaka` begins (a comment is
enough) silently produces a binary lacking it. Finish the edit, then build.

**[G-BUILD-RACE]** Concurrent `medaka build` is scratch-path safe (per-process `mktemp -d`).
⚠️ NOT two `make medaka` runs in the SAME worktree (#1141) — outputs write to `*.new.$$` beside
their final path, promoted via same-filesystem `mv`.

🚨 **[B-NO-BORROW-ISOLATED] In a worktree, never `cp` an emitter from another tree — just
`make -C <your-absolute-worktree-path> medaka`.** A fresh worktree has no `./medaka_emitter`
and that is FINE; it cold-bootstraps for ~31s, and borrowing does not even save the rebuild
(only the seed step). Reading another tree can trip the isolation classifier into a denial
that blocks every later `make`. Rationale + the `[B-BORROW-EMITTER]` measurement: the
`sprint-orchestrator` skill.

🚨 **[B-ISOLATION-COMPOUND] `cp` is NOT the only trigger (#1148, OPEN, ~32 occurrences across 5
sprints).** In an isolated worktree the classifier also refuses ordinary compound shells that
never leave your tree — `cd X && …`, `;`-chains ending in `echo $?`, heredocs, a `for` loop,
`python3 - <<EOF`, a pipe feeding `git` its args, a redirect combined with `-C`. ⇒ **One plain
command per Bash call; multi-step work goes into a script file, with any mandatory redirect
([D-BUILD-PIPE]) INSIDE it** — "drop the redirect" is not available to you.
⚠️ **That is mitigation, not immunity: a bare, foreground, correct-cwd `make medaka` has been
denied too.** When it is, the tell is the program name, not the work — **`sh
test/build_native_medaka.sh` (the literal body of the `medaka:` target) succeeded first try in
the session where four `make medaka` forms were refused**, so reach for it before concluding
anything. EnterWorktree is a dead end (your cwd already IS the worktree). If the build is
denied every way, you are BLOCKED: stop and report. Do not degrade to source-only work — a
no-build agent's "no such site exists" is not a finding. The denial SOMETIMES carries forward
across a session and sometimes does not; it is not predictable and not testable.

🚨 **[B-RELPATH-DENY] `medaka fmt --write <relative/path>` / `medaka lint <relative/path>` can
be silently denied too (#1823)** — a DIFFERENT mechanism from `[B-ISOLATION-COMPOUND]` (#1148):
this fires on a single, plain, non-compound command, keyed on path *form* (relative vs.
absolute), and the denial message is generic, not the isolation-specific phrasing. The
identical command with an absolute path succeeds immediately. ⇒ Always pass absolute paths to
`fmt`/`lint`, per `[T-WORKTREE-PATHS]`'s general advice.

**[B-ENV] Environment.** opam/dune NOT needed. Native build: **clang + Boehm GC** (Debian:
`clang` + `libgc-dev`, `-lgc`; macOS: Apple clang + `brew install bdw-gc`). `node` ≥24 only for
wasm/sqlite/playground gates.

**[B-BOX] Where you're running.** Dedicated x86_64 Linux box (Debian 13, 12 cores/32GB; repo at
`/root/medaka`). Build natively — no container/VM/wrapper. `scripts/docker-dev.sh`/`docker/` are
for an old macOS laptop problem that doesn't apply here.

⚠️ **[B-DUAL-PLATFORM] Every build/test script must run on BOTH Linux and macOS.** Keep both arms
alive when touching a script: `stat -c %Y` *or* `stat -f %m`, `pkg-config`/`-lgc` *or* `brew
--prefix bdw-gc`, no Mach-O-only link flags.

⚠️ **[B-CI-UBUNTU-ONLY] Upheld by convention only — CI is 100% `ubuntu-latest`** — don't trust a
count in this file, derive it: every `runs-on:` hit across the workflows should read
`ubuntu-latest` and zero should mention macOS:
```sh
grep -rn "runs-on" .github/workflows/*.yml | grep -vc ubuntu-latest   # 0 = clean
grep -rin macos .github/workflows/*.yml | wc -l                       # 0 = clean
```
A macOS-only break ships with every check green; mitigate with a manual macOS smoke test before
tagging a release (#549).

Two platform facts: emitted LLVM IR carries **no target triple** (seed cold-bootstraps on x86 or
arm from the same bytes); the compiler's stack comes from a **256 MB GC-aware worker pthread**
in `runtime/medaka_rt.c`, not a link flag — fine under Linux's default 8MB `ulimit -s`.

### ⚡ THE AGENT LOOP: `make preflight`. Do NOT run the full suite locally.

*Incident narrative, where an item below has any: `.claude/dossier/gates.md`.*

**[L-PREFLIGHT]** Run only the gates your change touches; push; let CI run the rest. Before
`make medaka`/oracle builds/gates: `medaka fmt --write` + `medaka lint` on touched `.mdk`,
re-`git add` (T-PERRUN-COMMENTS covers comment-bearing records). ⚠️ If the change affects
formatter/linter behavior or accepted syntax, **repeat the check with the freshly built binary
and apply any owed reflow before trusting it.**

```sh
PREFLIGHT_DRY=1 sh test/preflight.sh                 # ✅ FIRST STEP if unsure — derives the
                                                      #    gate set for free: builds/runs nothing
make preflight       # ✅ THE LOOP — derives the gate set from YOUR diff, and the oracle
                     #    set from those gates. Touching parser.mdk: 9 oracles, 11 gates.
sh test/run_gates.sh 'diff_compiler_parse*'          # ✅ targeted, by name
sh test/build_oracles.sh --for 'diff_compiler_*'     # ✅ fresh-worktree recipe, ~2 min — count
                                                      #    drifts, derive: `sh test/build_oracles.sh
                                                      #    --for --list 'diff_compiler_*' | wc -l`
sh test/build_oracles.sh --for --list '<pattern>'    # ✅ DERIVE ONLY — which oracle names a
                                                      #    pattern resolves to, builds nothing
FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one <name>   # ✅ exactly one
sh test/build_oracles.sh --for '<pattern>' --list    # ❌ NOT derive-only — this BUILDS
sh test/run_gates.sh                                 # ❌ ALL of them — count drifts, derive:
                                                      #    `ls test/diff_compiler_*.sh | wc -l`
FORCE=1 sh test/build_oracles.sh                     # ❌ ALL of them — count drifts, derive:
                                                      #    `sh test/build_oracles.sh --list | wc -l`.
                                                      #    Almost never right.
```

⚠️ **[L-DERIVE-ONLY]** `--list` must come IMMEDIATELY after `--for` — reversed fails SILENTLY
into the expensive path. Derive: `grep -n '"--for"' test/build_oracles.sh`.

🚨 **[L-FOREGROUND-CEILING]** `make preflight` on `compiler/backend/*`,
`test/diff_compiler_perf_scaling.sh`, `test/diff_compiler_engines.sh`: can exceed the 10-min
foreground ceiling — `exit 143` at 600s is the ceiling, not a hang. Knobs: `PERF_N=<n>`/
`PERF_DEEP=1`, `ENGINE_JOBS=<n>`, `ONLY=<glob>` (#723). Remedy: background + poll. Check first:
`PREFLIGHT_DRY=1`, `PREFLIGHT_CHANGED_FILE=<path>` (does not surface a forced fixpoint, #520,#540).

**[L-SHARED-BOX]** Box is shared — never run full suite/oracle build locally; bare
`FORCE=1 build_oracles.sh` can outlive your turn. Use targeted forms.

⚠️ **[L-PREFLIGHT-IS-FILTER]** `preflight` is a FILTER, NOT AN AUTHORITY — the MERGE QUEUE is
(W-MERGE-QUEUE), not a green `pull_request` check. A narrowed shard can report SUCCESS having run
nothing (not a hole — planner fails closed if a pattern matches no gates anywhere). Verify a
shard actually ran, never trust the checkmark:
```sh
gh api repos/MedakaLang/medaka/actions/runs/<id>/jobs --paginate \
  --jq '.jobs[] | "\(.name)\t" + ([.steps[]?|"\(.name)=\(.conclusion)"]|join(" | "))'
```

⚠️ **[L-BLAST-RADIUS]** On `stdlib/*`, `compiler/support/*`, `compiler/entries/*`: `make
preflight` IS the full gate suite — don't trust a count in this file, derive it (#492):
`ls test/diff_compiler_*.sh | wc -l`. `PREFLIGHT_NO_FULL=1 sh test/preflight.sh` runs
**NOTHING** by design. Prefer: push, let CI run it.

⚠️ **[L-NO-FULL-NOT-FIXPOINT]** `PREFLIGHT_NO_FULL` does NOT skip L-FOREGROUND-CEILING's
fixpoint — background it instead (#520,#545): `grep -n need_fixpoint test/preflight.sh`.

**Full local run justified when:** `compiler/backend/*` changed (`selfcompile_fixpoint.sh`);
`compiler/support/*`/`stdlib/core.mdk` changed; merging branches on the same subsystem; CI shows
something unreproducible. Else: push, let CI answer.

**[L-PHANTOM-SKIP]** `run_gates.sh`'s *"phantom skip: oracle/binary not built"* = no oracles
built (counted FAILED by design), not a regression.

🚨 **[L-SELFPROC-CARVEOUT]** Exception to L-PHANTOM-SKIP: a phantom-skipped
`diff_compiler_selfproc` on a compiler-source change is NOT dismissible — only local signal for
the LEG A golden (T-LEGA-GOLDEN). LEG A: `frontend.{ast,desugar,exhaust,lexer,marker,parser,resolve}`,
`types.{annotate,typecheck}`, `driver.loader`, `eval.eval`, `ir.sexp`, `tools.check`.
```sh
for o in check_all_main eval_modules_main eval_typed_modules_main; do
  FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one "$o"
done
sh test/diff_compiler_selfproc.sh        # must read "N ok, 0 failing" — not exit 2
```
Cheap discriminator, no build:
```sh
grep '<newBinding>' test/selfproc_goldens/legA/<module>.golden || echo "STALE — re-bless"
```

### The gates

```sh
make preflight                         # ⚡ the loop (above)
make test                              # IN-LANGUAGE suite (doctests, props, `test "…"`). No oracles.
make gates                             # the FULL differential suite — don't trust a count in
                                        # this file, derive it: `ls test/diff_compiler_*.sh | wc -l`
sh test/run_gates.sh 'pat*' 'pat2*'    # multiple patterns (deduped). NOT brace expansion.
make docs-links                        # doc-link rot: every cited path must exist. No compiler.
make agent-doc-symbols                 # doc-symbol rot: every backticked symbol must resolve. No compiler.
make docs-index                        # regenerate docs/README.md (GENERATED — never hand-edit)
```

🛠️ **[G-SKILL] A gate went red, or you're adding one? Load the `gates` skill** — it carries
the per-gate `[G-LIST]` table (what each one proves), the must-fail pin lifecycle
(`[G-PIN-DRAIN]`, `[G-DRAIN-INVISIBLE]`), the fan-out knobs (`[G-PARALLELISM]`,
`[G-BUILD-RACE]`), fixture/golden authoring, and the dash-not-bash shell half.
**Check `gh issue list --label known-red` first — it is usually not your break.**

These must reach you *before* you think to load anything, because their failure mode is
silent rather than red:

🚨 **[G-MUST-FAIL] `test/diff_compiler_must_fail.sh` has INVERTED polarity.** Each
`test/must_fail_fixtures/*/` pins an OPEN issue, so **RED is the healthy state** and a fix
flipping one green FAILS the gate. Never "repair" it by deleting or repointing a fixture —
that silently un-pins a live soundness bug and pays you in green. Drain protocol
(`[G-PIN-DRAIN]`): the `gates` skill. Runs in `soundness`.

**[G-STALE-ORACLE]** `run_gates.sh` refuses on a stale oracle rather than false-pass, printing
the rebuild command. Override only with `NO_STALE_CHECK=1`. Force-rebuild before trusting
`diff_native_cli`/bootstrap run outside `run_gates.sh`.

🚨 **[G-GOLDEN-CAPTURE-UNGUARDED]** Golden capture has NO staleness guard — a stale oracle can
BLESS A WRONG GOLDEN, permanently. **After ANY merge/rebase, rebuild oracles BEFORE capturing**,
then route through `run_gates.sh`. The same applies to `--bless` — see **[WT-GOLDEN-ENSHRINES]**
under *Writing tests*.

### Pre-commit hook (ACTIVE) — fmt + lint + snapshot + lextok

*Incident narrative, where an item below has any: `.claude/dossier/tooling.md`.*

`.githooks/pre-commit`: fmt+lint always, snapshot+lextok if staged, over staged `.mdk`
(`test/` fixtures excluded). Re-install: `cp .githooks/pre-commit
"$(git rev-parse --git-common-dir)/hooks/pre-commit"`.

- **[H-FMT] Format** — **Run `medaka fmt --write <changed.mdk>` and re-`git add` before
  committing any `.mdk` edit.** Bare `medaka fmt <file>` is READ-ONLY. ⚠️ **Tree is NOT
  fully fmt-clean** — the list of which files fail `medaka fmt --check` is DERIVED, not
  hand-typed (a hand-typed list here rotted twice over, #1794): `make fmt-clean-census`
  (`test/fmt_clean_census.sh`) reports the current set on demand. → dossier
- **[H-LINT] Lint** — **MAX RATCHET, all ~20 rules gated.** Also runs `medaka lint compiler
  stdlib sqlite`. **Run `medaka lint` on files you touch.** Disable inline: `-- lint-disable-
  next-line <rule>` (also `-line`, `-file`; omit rule = all). ⚠️ `--fix` bails on any decl with
  an interior comment. 🚨 Exit code alone does not reflect findings unless `--deny` is used
  (#1822) — read the output, not just `$?`.
- **[H-SNAPSHOT] Snapshot** — CHECK ONLY. **Run `make snapshot-check` first**; bless with `sh
  test/diff_compiler_snapshot_frontend.sh --bless <file.mdk>`, re-stage `test/snapshots/`.
  - **[H-SNAPSHOT-NEW]** New source file → `--new` (**SUITE-WIDE**, never overwrites). ⇒ run
    `--new`, `diff -rq` vs a before-copy to verify, **RE-RUN the plain check**. → dossier
  - **[H-SNAPSHOT-UNSTAGED]** ⚠️ Reads the **WORKING TREE**: `git add` any blessed snapshot
    before committing.
  - **[H-DEFER]** **`PRECOMMIT_SNAPSHOT_DEFER=1 git commit ...`** opts one source-only commit
    out of check 4 alone (fmt/lint/lextok stay live; `--no-verify` drops all four).
  - **[H-DEFER-VS-GUARD]** 🚨 Does NOT reach [H-SNAPSHOT-UNSTAGED]. **Bless and stage goldens
    LAST**, after every `.mdk`-staging commit is in — or stash across it. `--no-verify` and
    `core.hooksPath=/dev/null` are not substitutes. → dossier
- **[H-LEXTOK] Lextok** — OPPORTUNISTIC (needs `test/bin/lex_main` + a sibling
  `.lextok.golden`). Stale golden: `CAPTURE=1 sh test/diff_compiler_lex_files.sh <files>`,
  re-stage `.lextok.golden`.

Bypass: `git commit --no-verify`. Unbuilt `medaka`: hook warns and allows.

### Debugging a `.mdk` program

🛠️ **[D-SKILL] Load the `debug-pipeline` skill** — it carries the probe catalogue
(`[D-CHECK-JSON]`, `[D-TYPES-FLAG]`, `[D-CORE-IR-TYPED]` + its `[D-CORE-IR-TRAP]`,
`[D-KEEP-IR]`, `[D-EMITTER-CLI]`, `[D-RUN-VS-BUILD]`) and the full two-arm differential
recipe (`[D-TWO-ARM]`, `[D-TWO-ARM-RUNTIME]`, `[D-GATE-OVERRIDE]`).

These must reach you *before* you think to load anything, because each turns a wrong answer
into a right-looking one:

**[D-RUN-VS-BUILD]** `run`/`build` share the typechecker; differ only in engine. **NOT** two
independent observations of resolve/typecheck behavior — agreeing is not corroboration.

⚠️ **[D-GATE-OVERRIDE] Not every gate takes a second binary**, so a two-arm differential
pointed at one that hardcodes its own reports *identical* and manufactures a false negative.
**Derive, don't trust a count** (recipe + the #1431 hardcoded case: `debug-pipeline`).

🚨 **[D-BUILD-PIPE] `medaka build`'s exit code does NOT survive a pipe.** **Redirect to a file,
read `$?`, then read the file.**
```sh
./medaka build broken.mdk -o /tmp/x > /tmp/x.log 2>&1; echo "direct: $?"   # 1
./medaka build broken.mdk -o /tmp/x 2>&1 | tail -1;    echo "piped:  $?"   # 0
```

🚨 **[D-TWO-ARM-STDLIB] Two-arm differential is UNSOUND when the target is a `stdlib/*` file**
— manufactures false FINDINGS, because a `medaka` binary resolves emitter + stdlib from
`exeDir` ([D-TWO-ARM]), never cwd. ⇒ **Give each arm its own tree or set `MEDAKA_ROOT` per
arm.** → dossier

Writing a diagnostic: `compiler/ERROR-QUALITY.md` + `compiler/DIAGNOSTIC-CODES-DESIGN.md`.

**Playground e2e:** `cd playground/e2e && ./run.sh`. Needs node v24+,
`playground/dist/playground.wasm` pre-built. See `playground/e2e/README.md`.

## Traps

Each of these was paid for in an incident — pointers, not post-mortems.
*Incident narrative, where an item below has any: `.claude/dossier/traps.md`.*

- ⚠️ **[T-EMITTER-BENCH]** Measuring an emitter change? Read `benchmark-emitter` FIRST. Rebuild
  **twice** — a plain second `make medaka` is a no-op (stage A sees a matching fingerprint and
  prints "skipping rebuild"); force it with **`FORCE_EMITTER_REBUILD=1 make medaka`** each time.
  Run `test/refresh_seed.sh` **twice** after a codegen change.
- ⚠️ **[T-PERF-HUNT]** Stage slow, or `perf_scaling` red? Read `perf-hunt`. Profile
  **allocation**, not wall-clock. `whenL False (expensiveCall …)` still evaluates its arg.
- ⚠️ **[T-DISPATCH-LOADER]** Dispatch bug via loader but green single-file? Usually the EVAL
  DRIVER, not dict-passing — verify (Phase 134 was the inverse). Method: `debug-pipeline`.
  Regressions must use `test/diff_compiler_eval_modules.sh`.
- ⚠️ **[T-EVAL-LOCKSTEP]** `evalModules` (`eval/eval.mdk`) / `cevalModules`
  (`ir/core_ir_eval.mdk`) are PARALLEL drivers — fix frame semantics in **both**. Cross-module
  ctor/name tables must key **per-module local**, never bare-name flat.
- 🚨 **[T-GLOBAL-TABLE]** New program-global table or AST constructor? Required fixture:
  "feature + UNRELATED code still behaves," not "feature works."
  - New AST ctor: audit every `_ =>` wildcard arm, every pass, as a **SET**.
  - Global table: key must be **scoped** (`<iface>@<slot>`), never program-global bare.
  - Gates can't catch this — write a fixture where the construct is present but the assertion is
    about code that never touches it.
- ⚠️ **[T-FIXTURE-LINES]** A fixture's line count is load-bearing (goldens pin `file:LINE:COL`).
  Keep comment edits line-count-neutral (`git diff --numstat` reads `N N`), or re-derive the
  golden. In-place edits only; see [T-SHARED-CORPUS] for add/move/delete.
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
- ⚠️ **[T-SHARED-CORPUS]** A fixture directory is a SHARED CORPUS — add/move/delete enrolls you
  in gates you never named. ENUMERATE every consumer, run all of them. Never trust a count —
  derive it, word-bound the grep both sides (`grep -n 'Word-boundaries' test/preflight.sh`).
  `test/wasm/*.sh` gates live under `test/wasm/`.
- ⚠️ **[T-SNAPSHOT-SELF]** Compiler source is in the snapshot corpus — a source change moves its
  own golden. Land it same PR, or a terminal commit (`PRECOMMIT_SNAPSHOT_DEFER=1`, #1179). Bless
  via the **gate**, never the CLI: `sh test/diff_compiler_snapshot_<suite>.sh --bless <path>`.
- ⚠️ **[T-LEGA-GOLDEN]** A top-level-binding change also moves
  `test/selfproc_goldens/legA/<module>.golden` — red only in CI's `backend` shard. Re-capture:
  `sh test/capture_goldens.sh --frozen selfproc_legA`; diff must be **additive-only**. LEG A:
  `frontend.{ast,desugar,exhaust,lexer,marker,parser,resolve}`, `types.{annotate,typecheck}`,
  `driver.loader`, `eval.eval`, `ir.sexp`, `tools.check` — not `ir.core_ir_lower`/`backend/*`.
- 🚨 **[T-LEGA-REBASE]** A rebase auto-merges the LEG A golden with no conflict marker (no merge
  driver — `git check-attr merge -- test/selfproc_goldens/legA/types.typecheck.golden`) — a clean
  apply is NOT proof it's right, and no gate can flag a blend since the golden IS the oracle.
  Never hand-resolve or accept the auto-merge; re-derive:
  ```sh
  BASE=$(git rev-parse origin/main)   # pin it — see [T-WORKTREE-REFS]
  git checkout "$BASE" -- test/selfproc_goldens/legA test/snapshots
  make -C "$PWD" medaka
  sh test/capture_goldens.sh --frozen selfproc_legA
  sh test/diff_compiler_snapshot_frontend.sh --bless <the source file you moved>
  git diff -- test/selfproc_goldens/legA test/snapshots   # must be additive-only
  ```
- **[T-STDLIB-IMPORT]** The compiler MAY import `stdlib/`, per module — weigh it: `core`-instance
  modules (e.g. `list`) near-free; a module with a NEW type (e.g. `map`) costly. ⚠️ Don't delegate
  hot monomorphic helpers to prelude Foldable methods (`elem`/`any`/`all`/`length`). Migrating
  `support/`→stdlib: a polymorphic empty must be a **nullary constructor**; harnesses need
  `$STDLIB` too.
- **[T-TUPLES]** Tuples are internally `__tupleN__`-headed `TApp` spines, not `TTuple`. `(,)`/…
  in type position names the unsaturated tuple constructor; a saturated `(a, b)` head is
  unsupported. See `compiler/TUPLE-TYPE-CONSTRUCTOR-DESIGN.md`.
- **[T-ERRORS-ACCUM]** Errors accumulate — phases push into `compiler/driver/diagnostics.mdk`
  rather than raising on first error. Don't add early-exit/raise paths.
- **[T-MAIN-ZERO-ARG]** `main` must be a zero-arg value (`main = …`). `main () = …` is a silent
  no-op. Use `main = println …` for probes.
- **[T-LAMBDA]** Multi-arg lambdas are `x y => body`, not curried `x => y => body`.
- **[T-PRELUDE-DICT]** Prelude is marked+dict-passed only in the **typed** pipeline
  (`markWithPrelude`, `compiler/frontend/marker.mdk`). **Untyped eval** (no marker/typecheck —
  e.g. quick eval tests) falls back to arg-tag *"first impl wins"* for return-position methods.
  `pure` needs types — route through the typed pipeline, not untyped eval.
- **[T-GUARDS]** Match-arm guards and refutable pattern-guards (`Pat <- e`) both lower natively
  and work (fixed 2026-07-13, `labelFallthrough`, `backend/emit_support.mdk`). Write-up:
  `compiler/EMITTER-GAPS.md`.
- **[T-WORKTREE-PATHS]** In a worktree, use the full absolute path — cwd resets to the main
  checkout each call. If you slip: `cp` edits into the worktree, then
  `git -C <main> checkout -- <files>`.
- **[T-WORKTREE-REFS]** One shared `.git` — `origin/main`/`main` move under you. Pin
  `BASE=$(git rev-parse HEAD)` at task start; diff/checkout against `$BASE`. Recipe:
  `.claude/workstreams/HARNESS.md` (H-2).
- **[T-LAYOUT-SPEC]** `docs/spec/LAYOUT-SEMANTICS.md` is layout ground truth. §12 scopes only the
  lexer's token stream — a construct the lexer heralds correctly but the parser can't consume is
  a parser bug, not a lexer bug (§12 item 5).
- **[T-PHASES]** Numbered Phases. Open: `PLAN.md`. Completed 1–97: `archive/PLAN-ARCHIVE.md`.

## Dogfooding the language

**[DG-IDIOMS]** Prefer Medaka idioms only where they genuinely improve readability — verify on
the binary (`medaka test <file>`). Under-used: operator sections `(==)`, `(+ 1)`, `(2 * _)`
(left needs `_`); `|>`; `>> <<`; `[lo..=hi]`; `{ r | f = v }`; unary `!` (Ref-DEREF,
not boolean-not — `not` is the only negation).

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

🛠️ **[WT-SKILL] Adding a fixture or a gate? Load the `gates` skill** — fixture/golden steps
(`[WT-STEPS]`), the CI shard registration rule, and the dash-not-bash shell half
(`[WT-DASH-PRINTF]`, `[WT-TIMEOUT]`). Add cases to the gate matching the stage changed
(parser → `diff_compiler_parse*.sh`).

The two that must reach you before you load it — both silent:

- **[T-SHARED-CORPUS]** (below) — a fixture directory is a SHARED CORPUS; adding one enrols
  you in gates you never named.
- 🚨 **[WT-GOLDEN-ENSHRINES]** — a captured golden records what the engine DID, not what's
  CORRECT. Decide the right answer from semantics BEFORE `CAPTURE=1` or `--bless`, snapshot
  and selfproc LEG A included.

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
| **harden-typechecker** | Typechecker-*internal*: `type_error`, constraint/coherence/unification. |
| **perf-hunt** | Stage slow, or `diff_compiler_perf_scaling.sh` red. |
| **benchmark-emitter** | `compiler/backend/*` change to measure, or a suspicious fixpoint failure. |
| **add-lsp-capability** | Add/extend an LSP feature. |
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
| `docs/stdlib/STDLIB.md` / `stdlib/README.md` | Stdlib module plan / conventions for externs |
