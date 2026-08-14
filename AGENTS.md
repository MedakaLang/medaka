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
> `/root/.claude/projects/-root-medaka/memory/MEMORY.md`. Consult that index when durable
> project decisions, historical context, or prior-session learnings are relevant; do not load it
> automatically for every task.

> ### ⚡ Editing `compiler/`? Read [`compiler/AGENTS.md`](compiler/AGENTS.md) first.
> **How not to make the compiler slow.** It exists because *the agents who introduce
> performance bugs here are not the ones hunting them* — every quadratic in this tree was
> added by someone doing reasonable feature work who never thought about perf at all.
> **Thirteen quadratics, all the same shape: a `List` used as a set or a map.** It also
> records the two bottlenecks (`check` is **GC-bound**; `build`/CI is **clang-bound** — do not
> conflate them) and the measurement traps that produce confidently wrong answers.

`compiler/` is ONE Medaka project (`compiler/medaka.toml`); each stage is one `.mdk` file
under a subfolder: `frontend/` (lex/parse/AST/desugar/resolve/marker/exhaust), `types/`
(typecheck + annotate), `ir/` (Core IR, DCE, S-expr), `backend/` (LLVM + WasmGC emit, TRMC,
mangling), `eval/` (tree-walk interpreter), `driver/` (loader, diagnostics, build, CLI),
`tools/` (fmt/printer/LSP/test/repl/doc/new/lint), `support/` (compiler-private
mini-stdlib), `entries/` (per-stage probe entry points), `seed/` (checked-in LLVM IR seed
for cold bootstrap).

## Pipeline — where each stage lives

**Execution order** (driven by `compiler/driver/medaka_cli.mdk` — *not* the order files are
listed):

```
lexer.mdk → parser.mdk → ast.mdk → desugar.mdk → resolve.mdk → marker.mdk
  → typecheck.mdk (runs exhaust.mdk internally) → eval.mdk
  [all in compiler/frontend/ except typecheck.mdk (types/) and eval.mdk (eval/)]
```

Two non-obvious facts that bite when deciding *where* a check belongs:

- **`desugar.mdk` runs FIRST**, before resolve/typecheck. Surface-sugar nodes (`EGuards`,
  `ESection`, `EStringInterp`, `EDo`) are **already lowered to core** by the time
  typecheck/exhaust/eval see the tree. A check that needs the sugar shape (e.g. guard
  *coverage* on `EGuards`) cannot live in typecheck/exhaust — it must run pre-desugar (see
  `checkGuardExhaustiveness` in `compiler/frontend/exhaust.mdk`, a standalone pass on the
  raw AST).
- **`exhaust.mdk` is not a standalone later stage** — `checkMatchExhaustive` is *called
  from inside* `compiler/types/typecheck.mdk` (once per `EMatch`, with the scrutinee type
  known). It only ever sees core patterns.

| Stage | File | Role |
|-------|------|------|
| Lex | `compiler/frontend/lexer.mdk` | Indentation-sensitive; emits INDENT/DEDENT/NEWLINE |
| Parse | `compiler/frontend/parser.mdk` | Recursive-descent grammar |
| AST | `compiler/frontend/ast.mdk` | Node types + source locations |
| Desugar | `compiler/frontend/desugar.mdk` | Runs FIRST. Lowers `deriving`, record puns, `EGuards`/`ESection`/`EStringInterp`, `EDo` (→ nested `andThen`/`pure`), default-method specialization |
| Resolve | `compiler/frontend/resolve.mdk` | Name binding, single- and multi-module |
| Mark | `compiler/frontend/marker.mdk` | After desugar+resolve, before typecheck. Rewrites interface-method `EVar`→`EMethodRef` so typecheck can stamp the resolved impl key per call site |
| Typecheck | `compiler/types/typecheck.mdk` | Hindley-Milner + interfaces + effects; invokes Exhaust per `EMatch` |
| Exhaust | `compiler/frontend/exhaust.mdk` | Maranget pattern-matrix algorithm; called *from* typecheck |
| Eval | `compiler/eval/eval.mdk` | Tree-walking interpreter; dict-passing typeclass dispatch |

Support files:

| File | Role |
|------|------|
| `compiler/driver/loader.mdk` | Multi-file dependency walk, topo sort, cycle detection; `medaka.toml` project-root walk-up |
| `compiler/driver/diagnostics.mdk` | Accumulating error pipeline — phases collect errors, no exit-on-error |
| `compiler/driver/build_cmd.mdk` | `medaka build` — Core IR lower → LLVM emit → clang |
| `compiler/driver/medaka_cli.mdk` | CLI entry: `check`/`fmt`/`new`/`build`/`run`/`test`/`doc`/`lint`/`manifest`/`repl`/`lsp` |
| `compiler/ir/core_ir.mdk` + siblings | Core IR types, lowering (`core_ir_lower.mdk`), S-expr (`core_ir_sexp.mdk`), DCE (`dce.mdk`), interpreter (`core_ir_eval.mdk`) |
| `compiler/backend/llvm_emit.mdk` | LLVM text IR emitter |
| `compiler/backend/wasm_emit.mdk` | WasmGC text IR emitter (2nd backend) |
| `compiler/backend/private_mangle.mdk` | Universal constructor name mangling |
| `compiler/backend/trmc_analysis.mdk` | Tail-recursion-modulo-cons analysis |
| `compiler/types/annotate.mdk` | Type annotation helpers |
| `compiler/tools/printer.mdk` / `fmt.mdk` | AST→source round-trip / comment-preserving formatter |
| `compiler/tools/lsp.mdk` | LSP over stdio: diagnostics, formatting, symbols, hover, definition, highlight, completion, inlay hints |
| `compiler/tools/mcp.mdk` | `medaka mcp` — MCP stdio server, the LSP-for-agents: 8 tools (check/type_at/symbols/definition/references/fmt/lint/test), auto-wired via committed `.mcp.json`. **Prefer these over grep/Bash for the jobs they cover** — each tool's own `description` says when it's the first choice (e.g. `medaka_references` over grep: resolves by binder identity, correct under shadowing/aliasing). See `docs/ops/MCP.md`; use the tools during your own work and file friction as `ws:tooling` |
| `compiler/tools/lint.mdk` | `medaka lint` — modular AST linter on the RAW pre-desugar AST. Per-file `Rule` + cross-file `CrossFileRule` registries (add a rule = one fn + one list entry); `--fix`; `--deny`/`--disable`/`--only` |
| `compiler/tools/doctest.mdk` | Doctest extraction for `medaka test`. ⚠️ **NOT two drivers** — this row said "prelude-only → single-file" until 2026-07-30, which reads as a second elaboration path and is false: `runSingle` routes a no-import file *"through the SAME multi-module path as an import-bearing one — the 1-module wrappers"* (its own comment), and both arms of `runChosen` reach `elaborateModules`. What the no-import arm carries is a residual **flatten** — the prelude is concatenated into the user's decl list rather than being a node — which is why it must first compute `livePrelude = dropShadowedExp userNames coreDecls` and needs a `programIsCore` guard so `medaka test stdlib/core.mdk` doesn't double-declare everything. Both are workarounds for the flatten; under DICT §7.1 U1 (prelude is a node) a genuine 2-node graph needs neither, since SHADOW S1's per-module scoping already answers them. ⚠️ **A third residual existed here, not of the flatten, and it is now PARTIALLY fixed (ARCH E-5, #1521, owns but does not close #1223):** `runSingle` used to stamp its one node under a synthetic id, `"__user__"`, hardcoded at four sites, while `loadProgram` stamped the same file under its loader-derived id — one declaration, two identities in a single `medaka test <dir>` process (#1223, S2). `runSingle`/`runPropsSingle`/`runTestDeclsSingle`/`propsReportSingle` now compute `canonicalPathId` (`driver/loader.mdk`) — the SAME last-containing-root, round-trip-guarded convention a sibling's import canonicalizes through — over roots derived from the target's own directory. ⚠️ A first pass at this fix used plain `moduleIdOfPath` (first-root) instead, which agrees with the loader only when a project has ONE root and still diverged the moment a target sat below its own `medaka.toml` — caught in adversarial review before merge (#1526); see `test/origin_fixtures/nested` for the discriminating fixture. Orthogonal to the flatten: `runSingle` was already on the Module path; only the node's NAME was wrong. **This closes only the NO-IMPORT case.** `driver/loader.mdk:662-669` documents a separate, still-open residual for IMPORT-BEARING files (`runMulti`, untouched by this fix): an entry's own id is first-root while the same file reached as another target's dependency is last-root — MEASURED still reproducing (`test/origin_entry_residual_fixture`, pinned as `diff_compiler_origin_agreement.sh`'s `entry_residual` section). #1223 stays OPEN. Derive rather than trust this row: `grep -n 'SAME multi-module path' compiler/tools/test_cmd.mdk` |
| `compiler/tools/check.mdk` / `check_policy.mdk` | `medaka check` entry + policy checker |
| `compiler/tools/test_cmd.mdk` / `prop_runner.mdk` | `medaka test` — doctests + property tests |
| `compiler/tools/doc.mdk` / `new_cmd.mdk` / `repl.mdk` | `medaka doc` / `medaka new` / `medaka repl` |
| `compiler/support/util.mdk` + siblings | Compiler-private helpers + thin wrappers over `stdlib/` (e.g. `ordmap` wraps stdlib `Map`). Stdlib imports ARE allowed — weigh per module, see Traps |

`stdlib/`: `runtime.mdk` (extern primitive catalog, read from disk at runtime), `core.mdk`
(implicit prelude — `Eq`/`Ord`/`Debug`/`Num`/…), plus `list`/`string`/`array`/`map`/`set`/
`io`/`hash_map`/`hash_set`/`mut_array`/`json`/`byteparser`/`bytebuilder`. `map`/`set` are
weight-balanced ordered trees; `hash_map`/`hash_set` are mutable hash tables; `mut_array` is
a growable vector (amortized-O(1) `push`); `json` is a recursive-descent parser/serializer;
`byteparser`/`bytebuilder` are a binary parser-combinator library and its symmetric output
builder. **Only `core.mdk` is auto-prelude.** For the rest, **an import must say what it
binds**: `import map.{Map, get}` (selective — the common form), `import map.*` (everything
exported), or `import map as M` → `M.get` (**values only** — an alias-qualified name in
*type* position is a parse error, so import types by name). Combinations (`import m.{f} as
A`, `import m.* as A`) are rejected with a diagnostic that names the fix.
⚠️ **A bare `import map` binds NO names** — not values, not types, not `map.get` (qualified
access exists *only* via `as`). But it is **not** a no-op: **any** import of a module brings
that module's `impl`s into scope for dispatch, which is the whole job of the bare form (e.g.
`stdlib/json.mdk`'s bare `import array` — without it, `map (+ 1) [|1,2,3|]` is *"No impl of
Mappable for Array"*).
⚠️ **A `(..)` constructor import needs the DEFINING module to write `public export data`,
not plain `export data`** — three agents lost probe rounds to this in one session, because
the paragraph above never mentions the qualifier. Plain `export data` exports the type
ABSTRACTLY: the type NAME is importable, its constructors are not, and the importer is
rejected at exit 1 with *"'X' exports no constructors from module 'm' (exported
abstractly). Remove '(..)' or export with 'public export'"*. Derive it on any binary — two
`check` runs over the SAME importer, changing only the defining module's qualifier:
```sh
printf 'import m.{X(..)}\n\nmain = println 1\n' > /tmp/p/main.mdk
printf 'export data X = X Int\n'        > /tmp/p/m.mdk; ./medaka check /tmp/p/main.mdk; echo "abstract -> $?"  # 1
printf 'public export data X = X Int\n' > /tmp/p/m.mdk; ./medaka check /tmp/p/main.mdk; echo "public   -> $?"  # 0
```
`io.mdk` is the ergonomic layer over the `runtime.mdk` IO externs.

## 🚦 How work lands: `main` is PROTECTED — you cannot push to it

**Every change goes through a PR.** `git push origin main` fails with `GH013: Repository
rule violations`. There is **no admin bypass**, for anyone. A rejected push is the rule
working, not a credentials problem: open a PR.

```sh
git checkout -b <topic>              # never commit on main
# ... work; verify with `make preflight` ...
git push -u origin <topic>
gh pr create --fill
gh pr merge --auto --merge           # merges itself the moment every required check goes green
```

🛠️ **For the write/verify half of that lifecycle, prefer the verified helper
`scripts/pr.sh`** (`body` / `watch` / `enqueue` / `complete`) — see
`docs/ops/PR-HELPER.md`. Hand-rolled `gh` writes and `gh pr merge` exit codes
carry no signal for the shapes #1212/#1213 record (see the MERGE QUEUE bullet
below), so the helper verifies resulting state instead of return codes: it
byte-compares a body readback, prints only check transitions, confirms queue
membership via GraphQL, and proves the head SHA landed on `main`. Each
subcommand is independent — a body edit needs no full lifecycle. The raw
commands remain documented below because the failure explanation still matters;
the helper just makes the verified-correct sequence one command instead of a
hand-rebuilt ritual.

**Required checks are derived from the active ruleset.** They include the `gates (…)` shards plus
soundness/product contexts. ⚠️ **A gate matching
`test/diff_compiler_*.sh` but no shard pattern in `ci.yml` SILENTLY NEVER RUNS** —
`diff_compiler_ci_shard_coverage.sh` catches it, and the merge queue will bounce you for it.
🚨 **That check's input is the TREE, not `test/`, so a `.sh` you add ANYWHERE trips it** — measured
2026-08-14, a repro harness committed under `.claude/` reddened `gates (tools)` as *"matches NO CI
shard and would SILENTLY NEVER RUN"*. If the script is not a gate, the fix is a
`test/CI-COVERAGE-EXCEPTIONS.txt` row **with a reason**, not a rename: say what it is, and why
running it in CI would be wrong (a harness whose arms are *expected* to fail would red the suite on
findings that are correctly still open).
⚠️ **Derive the current set** (this used to claim "Ten" while `wasm` was already required, #597):
```sh
gh api repos/MedakaLang/medaka/rulesets --jq '.[]|select(.enforcement=="active")|.id' | while read -r id; do
  gh api "repos/MedakaLang/medaka/rulesets/$id" \
    --jq '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context'
done
```
🚨 **NOT `…/branches/main/protection…` — that endpoint 404s `"Branch not protected"`, which reads
exactly like "nothing is required here".** Required checks live in a repo **RULESET**, not classic
branch protection. That 404 is also why `git push origin main` fails with `GH013: Repository rule
violations` — a *rules* message. **That single 404 is why `ci.yml` (x2) and this file all said
`wasm` was advisory for two days while it was required**, and it misrouted #597's whole design.
Shards are scheduled by **cost, not theme**: put a new gate where there is ROOM. 🚨 **DO NOT
trust any shard-cost ranking written here — including the ones this paragraph used to give.
DERIVE it, every time, with the command below.** This sentence has now been wrong **three
times**, each time in a way that misrouted real work: `~5.8 min` for `engines` rotted when that
shard was given the whole runner (`full_cores`, `ci.yml`) and misrouted #597's design; the
replacement claim — *"`gates (types)` was the pole and `engines` the cheapest heavy shard"*,
from three July 2026 runs — **was measurably false by 2026-08-13**, and a Stage B orchestrator
repeated it out of this file into an implementer's brief instead of running the command two
lines below. Measured on two consecutive green `merge_group` runs (`31655422530`,
`31653614351`): **`engines` is the POLE (373s/364s) and `eval` the CHEAPEST (149s/151s)**;
`types` 322/324 · `frontend` 289/291 · `tools` 202/213 · `sqlite` 185/191 · `backend` 165/160.
**Those numbers are recorded to show the ranking INVERTED, not for you to reuse** — a ranking
is an encoded fact with no derivation and no expiry, and the derivation is one command:
`gh run view <id> --json jobs --jq '.jobs[]|select(.name|startswith("gates"))|{name,s:((.completedAt|fromdate)-(.startedAt|fromdate))}'`
**Zero approvals required** — the *checks* are the gate, not a human, so an agent can
self-merge on green. The repo is org-owned (MedakaLang), so a **merge queue is live** — see above; `--auto` enqueues.

Two things that are easy to get wrong:

- **`soundness` is required on purpose.** It runs `typecheck_compiler_source.sh` + the
  self-compile fixpoint + the doc gates. **All gates pass on an ill-typed compiler** — `make medaka` does
  not gate on type errors — which is exactly how a compiler with unbound constructors once
  shipped to `main` with every gate green. The gate shards cannot catch that; `soundness` can.
- **There is a MERGE QUEUE (2026-07-13).** `gh pr merge --auto --merge` **enqueues** your PR;
  the queue does the rest. It builds a temp branch of *your PR merged onto current `main`, plus
  everything queued ahead of you*, runs every required check **on that**, and merges only if green —
  so what CI validates is the **merged result**, not your branch in isolation. That is not a
  formality: two green branches have merged cleanly into a **crashing** tree (git auto-merged a
  break it could not see — one branch had added a caller into machinery the other was re-signing,
  on different lines, so no conflict marker). It is also why the queue, not the `pull_request`
  run, is the real authority on gate coverage — see the `preflight`-is-a-filter warning below.

  **You do NOT need to keep your branch up to date with `main`.** "Strict" mode is OFF and
  `update-branch` kicks are obsolete — the queue handles staleness. If a doc tells you to babysit
  a `BEHIND` branch, that doc is stale.

  ⚠️ **`gh pr merge --auto --merge` prints `! The merge strategy for main is set by the merge
  queue` on success — but its EXIT CODE carries no signal either way, so read back the state,
  never the return code.** Observed on two separate successful calls: one exited **1** (an
  orchestrator read that as a failed action, re-ran the command, and got back "already queued
  to merge" for the PR it had just declared failed); another exited **0** (auto-merge armed,
  PR not yet queue-eligible because required checks were still running). Same warning both
  times, opposite exit codes, both successes — don't infer anything from which one you get.
  Don't trust `autoMergeRequest` either — it reads `null` while queued, indistinguishable from
  "never armed". The real signal is `isInMergeQueue` via GraphQL (not in this `gh`'s `--json` fields):
  ```sh
  gh api graphql -f query='{repository(owner:"MedakaLang",name:"medaka"){pullRequest(number:N){isInMergeQueue state}}}' --jq '.data.repository.pullRequest'
  ```
  This repo has hit both directions in one session — a tool reporting *success* while nothing
  happened (a silently no-op'd `gh` write, a blanked message body), and here a tool reporting
  *failure* while the action happened. The fix for both is the same: verify the resulting
  state, not the return code.

**Where the backlog and the orchestration rules live** — none of this is reachable from
anywhere else, so it is listed here:

### 🎯 "What should I work on?" → **GitHub Issues.** Not a doc.

```sh
gh issue list --label "S0: silent wrongness"      # always start here — silent wrongness beats everything
gh issue list --label "ws:soundness" --state open # one workstream (ws:soundness|language|tooling|wasm|
                                                  #   diagnostics|testing|release|perf|stdlib|typecheck)
gh issue list --label "needs-repro"               # inherited claims NOBODY has reproduced
gh issue list --milestone "0.1.0 public preview"  # the release floor
```

**Severity:** `S0: silent wrongness` (a wrong answer or destroyed source, **with no error**) →
`S1: loud breakage` → `S2: misleading` → `S3: friction & debt`. **Soundness outranks release.**

> ### ⚠️ A fix that makes a defect QUIETER is a severity INCREASE — even when the old behaviour was also broken.
>
> The ladder above orders states. Its corollary orders *changes*, and that is the half people miss:
> **loud → silent is a regression**, and it will look like progress because the crash went away.
> Three instances in one session (2026-07-24/25), each caught by a reviewer noticing rather than
> by any gate:
>
> - **#1072** — a fix replaced an `unreachable` crash with a **wrong answer at exit 0**. Strictly
>   worse: it removed the only loud signal that shape ever produced.
> - **PR #1007** (fixing #1002) — an index fix turned *"returns nothing, so the rename driver
>   refuses"* into *"returns a confidently wrong edit set the driver applies."*
> - **PR #996** — the same transition, one PR earlier, in the same subsystem.
>
> **The reviewer's question:** *does this fix turn a path that returned NOTHING into one that
> returns SOMETHING?* If so, **the new something is untested by construction** — every
> pre-existing test covered the empty case, so no existing fixture can fail. The test that would
> catch it cannot be derived from the diff or from coverage; it has to be built from the spec.
>
> Applying this to a green PR caught a language regression before it merged.

⚠️ **`verified` vs `needs-repro` is load-bearing. REPRODUCE BEFORE YOU FIX.** When the backlog was
re-derived against the binary on 2026-07-14, **six entries were already fixed** — including two
"silent build miscompiles", a duplicate-definition segfault, and a `newtype` bug billed as "the best
value-to-risk item on the board". **Closing an issue as already-fixed is a good outcome; say so.**

| Path | What it is |
|------|-----------|
| `.claude/workstreams/` | Per-workstream **domain knowledge**: the traps, the collision map, and *why each bug class recurs*. **Not the backlog** (that is the issue tracker) — read the one matching your labels **before** you start. |
| `.claude/ORCHESTRATING.md` | Orchestration playbook. Its #1 lesson: *the gap docs lie — reproduce before you trust them.* |
| `.claude/HANDOFF.md` | **Known-red gates.** Read BEFORE diagnosing a failing gate — it is usually not your break. |
| `.claude/skills/` | Task playbooks (table at the bottom of this file). |

## Build & test

```sh
make medaka          # WARM (./medaka_emitter present): 2-stage rebuild from current source
                     # COLD (fresh clone): bootstraps from compiler/seed/emitter.ll.gz first
./medaka run yourfile.mdk
```

**Staleness guard.** Every `./medaka` invocation recomputes a live source fingerprint over
`<root>/compiler/*.mdk` and compares it to the one baked in at build time — a mismatch means
you're running a binary built from OLDER compiler source than what's on disk. Default is a
warning; **`MEDAKA_STRICT=1`** promotes it to a hard `exit 1`, useful when you need certainty
you're not debugging or verifying against a stale binary (`checkSourceStaleness`,
`compiler/driver/medaka_cli.mdk`).

🚨 **`MEDAKA_STRICT=1` CANNOT BE USED ON BOTH ARMS OF A TWO-ARM DIFFERENTIAL — it turns the
base arm into `exit 1` on EVERY case and the run reports "everything differs".** Staleness is
computed against `<exeDir>/compiler`, and a two-arm comparison shares one compiler tree by
construction, so the older arm's baked fingerprint can never match the source beside it. That
is not a stale binary; it is the guard doing its job on a layout it was not designed for.
Measured 2026-08-15 on PR #1645, where the first differential run reported a total divergence
for exactly this reason. ⇒ **Assert freshness ONCE, on the arm where it can be true**, and run
the comparison itself without it — or give each arm its own `compiler/` tree.

🚨 **THE WARNING GOES TO STDERR, NEVER STDOUT — so `2>/dev/null` HIDES IT and a probe that
reads stdout will never see it.** `checkSourceStaleness` emits it with `ePutStrLn` and
nothing else prints it (`grep -rn 'may be stale; rebuild' compiler/` finds one site,
inside that function). Measured on a stale `medaka run`: **stdout is the program's value
alone, exit 0**, and `head -1` on stdout returns that value, not the warning. This is
load-bearing in both directions:
- **Do not** design a freshness probe around stdout, or around a nonzero exit — without
  `MEDAKA_STRICT=1` a stale binary still exits 0 and still prints the right-looking answer.
  Set `MEDAKA_STRICT=1` and read the exit code, or read stderr.
- **Do** suspect it when a gate asserting an EMPTY stderr goes red for no semantic reason
  (#1421 — that is build freshness, not a regression), and when an MCP tool result grows a
  `staleBinary` field: `sourceStalenessVerdict` is threaded into `runMcpServer` and
  `attachStaleness` (`compiler/tools/mcp.mdk`) splices that field onto every tool result,
  which is a second graded channel the same warning reaches.

Forcing the stale state without editing compiler source — point `MEDAKA_ROOT` at a
throwaway root whose `compiler/` differs from the one baked in (give it a `stdlib` symlink
so the run still reaches the program):
```sh
mkdir -p /tmp/fake/compiler; printf 'x = 1\n' > /tmp/fake/compiler/bogus.mdk; ln -s "$PWD/stdlib" /tmp/fake/stdlib
printf 'main = println 12345\n' > /tmp/hello.mdk
MEDAKA_ROOT=/tmp/fake ./medaka run /tmp/hello.mdk 2>/dev/null   # 12345 — warning invisible, exit 0
MEDAKA_ROOT=/tmp/fake ./medaka run /tmp/hello.mdk >/dev/null    # the warning, on stderr
```

**In a worktree:** the shell cwd resets between calls, so use
`make -C /absolute/path/to/worktree medaka`. The `./medaka` binary lands in the worktree.

🚨 **DO NOT EDIT COMPILER SOURCE WHILE A BUILD IS IN FLIGHT — the fingerprint is baked at STAGE A
START, not at the end.** A `.mdk` edit made after `make medaka` begins — *a comment is enough* —
produces a binary that silently lacks it and whose baked stamp no longer matches the tree, so every
subsequent probe trips the staleness guard (or, without `MEDAKA_STRICT=1`, quietly measures the old
arm). Measured 2026-08-14: one full rebuild lost. Finish the edit, then build.

**Borrowing an emitter (`cp <other-tree>/medaka_emitter .` then `make medaka`) is SAFE, but it
does NOT warm-start the build — say so plainly, since a prior wording sold it as a warm start
and then stated the mechanism that defeats one in its own next clause.** `cp` copies the
emitter binary but not the separate `.medaka_emitter.srcstamp` provenance stamp beside it, so
`build_native_medaka.sh` always sees "provenance unknown" for a borrowed emitter and rebuilds
it from current source anyway — **stages A and B run in the borrow path exactly as they do
cold** (`test/build_native_medaka.sh:212-221`; the *"fresh bootstrap, or copied in from another
tree"* branch covers both cases identically). **The only thing borrowing actually skips is the
~31 s seed-bootstrap step** (measured: `time sh test/bootstrap_from_seed.sh` → `real
0m31.003s`, exit 0). It used to decide staleness by **mtime**, which `cp` inverts — that is
where the spurious "lagging seed" scares came from.

> ### 🚨 If you are a WORKTREE-ISOLATED SUBAGENT, do NOT borrow it. Cold-bootstrap.
>
> **For an isolated subagent, borrowing can cost you your whole session — and the failure is not
> reliable enough to predict.** `cp <other-tree>/medaka_emitter .` *reads* from a tree that is not
> yours, which can trip the auto-mode isolation classifier — and the denial is **stateful**: it
> carries forward and blocks every later `make` you attempt, *including a clean cold-bootstrap
> entirely inside your own worktree*. In the same 2026-07-16 session, one subagent tripped the
> classifier on this exact `cp` and **never built again** (its stated reasons for the successive
> denials even contradicted each other — "you are in another agent's worktree" → "bare `make`
> risks the shared main checkout"), while another borrowed the emitter with no issue.
> **Don't gamble the session on a coin-flip to save ~31 seconds — that is all borrowing buys
> (see above).**
>
> **Just run `make -C <your-absolute-worktree-path> medaka`.** A fresh worktree has NO
> `./medaka_emitter` and **that is FINE** — it cold-bootstraps from `compiler/seed/emitter.ll.gz`
> and works, at the same ~31 s cost either way. This paragraph's cost figure said **~4 s** until
> 2026-07-16, an ~8× understatement that propagated into new code verbatim — re-derive it with
> the `time` command above rather than trust a number here. **Never read from another tree; the
> speedup is not worth the session.**

**Environment.** opam/dune are NOT needed. The native build uses only **clang + Boehm GC**
(Debian: `clang` + system `libgc-dev`, found via plain `-lgc`; macOS: Apple clang + `brew
install bdw-gc`). `node` ≥ 24 is needed only for the wasm/sqlite/playground gates. If clang
or libgc is missing, install from the system package manager — don't vendor it.

**Where you're running.** Primary dev is a dedicated **x86_64 Linux box** (Debian 13, 12
cores / 32 GB; repo at `/root/medaka`). Build natively — no container, no VM, no wrapper.
`scripts/docker-dev.sh` + `docker/` (see `docker/README.md`) exist only for the old macOS
laptop's DLP scanner problem, which **does not exist here — do not reach for the Docker
wrapper.**

⚠️ **The dual-platform invariant still holds: every build/test script must run on BOTH
Linux and macOS** (the Mac is retained for macOS smoke-testing; there is no alternative).
When you touch a script, keep both arms alive — `stat -c %Y` *or* `stat -f %m`,
`pkg-config`/`-lgc` *or* `brew --prefix bdw-gc`, no Mach-O-only link flags.

⚠️ **That invariant is upheld by convention, not by a gate — CI is 100% `ubuntu-latest`**
(`grep -rn runs-on .github/workflows/*.yml`: 11/11 hits across `ci.yml` and `nightly.yml`
are `ubuntu-latest`; zero `macos`/`darwin` mentions in either file). A macOS-only break —
a missed `stat -f %m` arm, a `brew --prefix bdw-gc` path, a Mach-O-only link flag — ships
with every required check green; nothing mechanical would catch it before a release. Until
a macOS job exists, the mitigation is a manual macOS smoke test before tagging a release
(#549).

Two platform facts worth not rediscovering: the emitted LLVM IR carries **no target
triple**, so the checked-in seed cold-bootstraps on x86 *or* arm from the same bytes; and
the deeply-recursive compiler gets its stack from a **256 MB GC-aware worker pthread**
spawned in `runtime/medaka_rt.c`, not a link flag — so it runs fine under Linux's default
8 MB `ulimit -s`.

### ⚡ THE AGENT LOOP: `make preflight`. Do NOT run the full suite locally.

**The full suite is CI's job.** Run the gates your change touches; push; let CI run the
other 80 across six parallel hosted runners.

**Order the cheap checks first:** after editing a `.mdk`, run targeted `medaka fmt --write` and
`medaka lint` on the touched source **before** `make medaka`, oracle builds, or gates. Re-add any
formatter change, inspect comment-bearing record declarations as required by the formatter warning
below, then rebuild once from the formatted/linted source. When the change affects formatter/linter
behavior or accepted syntax, repeat the relevant check with the freshly built binary and apply any owed
reflow before trusting it.

```sh
PREFLIGHT_DRY=1 sh test/preflight.sh                 # ✅ FIRST STEP if unsure — derives the
                                                      #    gate set for free: builds/runs nothing
make preflight       # ✅ THE LOOP — derives the gate set from YOUR diff, and the oracle
                     #    set from those gates. Touching parser.mdk: 9 oracles, 11 gates.
sh test/run_gates.sh 'diff_compiler_parse*'          # ✅ targeted, by name
sh test/build_oracles.sh --for 'diff_compiler_*'     # ✅ fresh-worktree recipe: 52 oracles, ~2 min
sh test/build_oracles.sh --for --list '<pattern>'    # ✅ DERIVE ONLY — which oracle names a
                                                      #    pattern resolves to, builds nothing
FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one <name>   # ✅ exactly one
sh test/build_oracles.sh --for '<pattern>' --list    # ❌ NOT derive-only — this BUILDS
sh test/run_gates.sh                                 # ❌ all 83
FORCE=1 sh test/build_oracles.sh                     # ❌ all 54 oracles. Almost never right.
```

⚠️ **`--list` must come IMMEDIATELY after `--for`, and the reversed order fails SILENTLY
into the expensive path.** The derive-only mode is a positional test on the first two args
(`[ "$1" = "--for" ] && [ "$2" = "--list" ]`, `test/build_oracles.sh`); write `--for
'<pattern>' --list` and that test is false, `--list` is consumed as *another gate pattern*
(it resolves to no gate and contributes nothing), the real pattern still resolves — so the
script proceeds to **compile the whole derived oracle set** while you are waiting for a
list. There is no diagnostic, because nothing is malformed. Derive the rule rather than
trusting this paragraph: `grep -n '"--for"' test/build_oracles.sh`.

🚨 **On a `compiler/backend/*` diff, `make preflight` forces the self-compile fixpoint and the
loop can exceed the 10-minute foreground tool ceiling — killed at 600s with `exit 143`
(SIGTERM). That is the CEILING, not your change hanging — do not go debug a phantom.** Same
risk running `test/diff_compiler_perf_scaling.sh` directly (measured 654-748 s, ~11-12 min) —
it's one of the slowest gates in the tree and just as foreground-unsafe as a single blocking
call. **`PERF_N=<n>` shrinks its input size for faster local iteration (default 250); quick
mode is the default scope, `PERF_DEEP=1` restores the full nightly scope** (`test/diff_compiler_perf_scaling.sh`).
Same trap: `test/diff_compiler_engines.sh` (the 3-engine differential) is ~5-7 min — its
own `ENGINE_JOBS` table reads `JOBS=3 ~5min`, and `MEDAKA_REQUIRE_WASM=1` (the CI wasm arm) pushes
it to ~7. **`ENGINE_JOBS=<n>` is a settable knob, not just a measurement** — override it (e.g.
`ENGINE_JOBS=2`) to throttle the fan-out on a shared/loaded box, or scope to a subset with
`ONLY=<glob>` while iterating (#723).

**Remedy: run either one detached/backgrounded and poll for completion, not in a single
foreground turn** (`run_in_background` in this harness, not a blocking call). Before
committing to a run that long, reach for `PREFLIGHT_DRY=1` (fence above) — `test/preflight.sh`
is the source of truth for it and its sibling `PREFLIGHT_CHANGED_FILE=<path-to-a-file-listing-
changed-paths>` (hands preflight a changed-file list directly instead of deriving one from
`git diff`). ⚠️ `PREFLIGHT_DRY` does NOT surface a forced fixpoint — that decision fires *after*
the DRY exit — so a short dry-run gate list does not by itself mean the real run will finish
inside the ceiling. (#520, #540)

**This is a real cost, not an aesthetic preference.** Several agents share this box. One
agent running the whole suite + a full oracle build takes the load average past 10 and
**turns a 30-second gate run into several minutes for everyone else.** Worse, bare
`FORCE=1 build_oracles.sh` spawns an `xargs -P` pool that **outlives the agent's turn and
gets RESPAWNED by the harness** — it has killed several agents. Use the targeted forms.

⚠️ **`preflight` is a FILTER, NOT AN AUTHORITY.** It runs a subset and prints what it
skipped. **The MERGE QUEUE is the authority — not a green `pull_request` check — and
nothing merges on a green preflight.** That distinction matters because a green PR check
does not by itself mean that shard ran anything: `ci.yml`'s "Plan this shard" step
(`.github/workflows/ci.yml`, the `gates (…)` job) NARROWS each shard on a `pull_request`
event to the intersection of that shard's patterns with the diff-derived gate set — its
own `why=` string says so verbatim: *"pull_request — narrowed to the gates this diff
touches (merge_group runs ALL of them)"*. A shard whose intersection is empty still
reports SUCCESS having run nothing. **That is NOT a hole** — the planner fails closed
(`::error::` + `exit 1`, same step) if a shard's *pattern* matches no gates in the whole
tree, which is the actual "a gate silently never runs" hazard
`diff_compiler_ci_shard_coverage.sh` (above) exists to catch; an empty per-PR
*intersection* is the designed-for common case, not that failure. Real coverage for a
narrowed-away gate runs later, in the merge queue's `merge_group` run, which is
unnarrowed and tests the PR merged onto `main` (see the MERGE QUEUE bullet above) — that
run is the authority, not the `pull_request` run.

Measured instance: PR #1289 (a `compiler/frontend/resolve.mdk` change) reported all 12
required checks green, but `gates (engines)`, `gates (sqlite)` and `gates (tools)` each
had BOTH their `Build medaka` and `Gate shard — …` steps `skipped` — `engines` went green
in 7 seconds having run nothing. Check whether a specific shard actually executed, rather
than trusting the checkmark:
```sh
gh api repos/MedakaLang/medaka/actions/runs/<id>/jobs --paginate \
  --jq '.jobs[] | "\(.name)\t" + ([.steps[]?|"\(.name)=\(.conclusion)"]|join(" | "))'
```
⚠️ **"CI green" is not corroboration of a PR-body claim about a specific gate's numbers.**
Reading a green rollup as proof that a cited gate ran with the cited result is an invalid
inference made — and caught only in review — during the 2026-08-05 A-2 session; verify
with the command above, never with the checkmark.

⚠️ **On a BLAST-RADIUS path, `make preflight` IS the full suite — the two rules above
collide, and this carve-out is the resolution** (#492). For `stdlib/*`, `compiler/support/*`,
`compiler/entries/*` and friends, preflight's own `mark_full` adds the `diff_compiler_*`
catch-all, so "the loop" silently becomes the ~84-gate run this section forbids. **The
widening is CORRECT** — a prelude change moves essentially every golden, and a narrow
preflight would report green having run lexer + snapshot + doctests. So on those paths:

- preflight now **announces this loudly before it spends the box**, and prints the exact
  `run_gates.sh` line it is about to become;
- **`PREFLIGHT_NO_FULL=1 sh test/preflight.sh`** declines it. It runs **NOTHING** and says
  so — deliberately *not* a narrower subset, because a green that tested less than it
  appears to is the hazard this whole suite exists to prevent;
- **preferred: push and let CI run it** across its parallel runners.

⚠️ **`PREFLIGHT_NO_FULL` does NOT reach the `compiler/backend/*` fixpoint case above it in this
section.** It only guards `full_suite` (the blast-radius path just described); a
`compiler/backend/*` diff instead sets a separate `need_fixpoint` flag
(`grep -n need_fixpoint test/preflight.sh`), which prints no banner and has no opt-out — the
fixpoint runs unconditionally whether or not `PREFLIGHT_NO_FULL` is set. If the 10-minute
ceiling above is what you're trying to dodge, background the run; `PREFLIGHT_NO_FULL` will not
skip the fixpoint for you. (#520, #545)

**Two agents were killed for obeying `make preflight` here** before it said any of this.
If you took the loop at its word on a prelude change, that was the tooling's bug, not
yours. An instruction that silently expands into what another instruction forbids is worse
than either alone: the one who obeys pays.

**A full local run IS justified when:** you changed `compiler/backend/*` (run
`selfcompile_fixpoint.sh` — preflight forces this); you changed `compiler/support/*` or
`stdlib/core.mdk` (blast radius genuinely is everything); you are merging two branches that
touched the same subsystem (pre-merge greens do not carry over); or CI says something you
cannot reproduce. Outside those: **push and let CI answer.**

If `run_gates.sh` reports gates FAILED with *"phantom skip: oracle/binary not built"* —
that is **not a regression**, you just have no oracles. (They count as FAILED, not skipped,
on purpose: a gate that ran nothing must never report green.)

🚨 **ONE CARVE-OUT, and it has bitten twice: a phantom-skipped `diff_compiler_selfproc` on a
compiler-source change is NOT dismissible.** The rule above is right in general and wrong
here, and the combination is a genuine blind spot rather than an oversight:
`test/preflight.sh` *correctly* selects `diff_compiler_selfproc` for any `compiler/*/*.mdk`
diff — but in a fresh worktree it has no `test/bin/check_all_main`, so it exits 2, becomes
`FAIL* (phantom skip)`, and the paragraph above tells you to ignore it. **A correct gate plus
a correct-in-general dismissal rule = shipping the break.** That gate is the *only* local
signal for the moved selfproc **LEG A** scheme golden (see the snapshot/LEG A trap under
Traps), and it reds in the CI `backend` shard when you skip it. Two PRs have burned a CI
round-trip this way; on #1005 the deterministic red was then misread as a shared-runner
flake and blind-retried.

So when your diff touches a LEG A module — `frontend.{ast,desugar,exhaust,lexer,marker,parser,resolve}`,
`types.{annotate,typecheck}`, `driver.loader`, `eval.eval`, `ir.sexp`, `tools.check` — make
it actually grade instead of dismissing it:

```sh
for o in check_all_main eval_modules_main eval_typed_modules_main; do
  FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one "$o"
done
sh test/diff_compiler_selfproc.sh        # must read "N ok, 0 failing" — not exit 2
```

**Cheapest possible discriminator, no build at all** — if you added or renamed a top-level
binding, it must already be in the golden:

```sh
grep '<newBinding>' test/selfproc_goldens/legA/<module>.golden || echo "STALE — re-bless"
```

### The gates

```sh
make preflight                         # ⚡ the loop (above)
make test                              # IN-LANGUAGE suite (doctests, props, `test "…"`). No oracles.
make gates                             # the FULL 84-gate differential suite
sh test/run_gates.sh 'pat*' 'pat2*'    # multiple patterns (deduped). NOT brace expansion.
make docs-links                        # doc-link rot: every cited path must exist. No compiler.
make agent-doc-symbols                 # doc-symbol rot: every backticked symbol must resolve. No compiler.
make docs-index                        # regenerate docs/README.md (GENERATED — never hand-edit)
```

| Gate | What it proves |
|------|----------------|
| `test/diff_compiler_*.sh` | Differential: native stage output vs captured goldens |
| `test/selfcompile_fixpoint.sh` | Emitter self-compile fixpoint (C3a/C3b) — **THE decisive gate for any compiler-source change** |
| `test/typecheck_compiler_source.sh` | Strict-typechecks the WHOLE compiler source. Run alongside the fixpoint for any compiler `.mdk` change — the bootstrap emit path does NOT gate on type errors, so an ill-typed compiler builds green without this. ⚠️ It (and `diff_compiler_selfproc.sh`) needs its slow oracle (`diagnostics_project_main`, `check_all_main`, …) BUILT FIRST in a fresh worktree — `FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one <name>` — and REBUILT after every compiler-source edit; a missing/stale oracle exits 2, which reads like a skip, not a failure. **For a fast first-line local check with no oracle build/staleness coupling, reach for `make check-self` instead** — sub-minute (~20s), runs `./medaka check` over the already-built binary's own `medaka_cli.mdk` closure; `typecheck_compiler_source.sh` remains the fuller authority (also covers `compiler/entries/*.mdk`) |
| `test/diff_compiler_engines.sh` | **The 3-engine differential**: eval == native == wasm on the SAME programs. Found 4 bug classes on its first run. Ledger: `test/engine_divergence.txt` |
| `test/diff_compiler_perf_scaling.sh` | **The O(n²) detector.** Inputs at N and 2N; grades the *allocation* growth ratio (linear ≈2.0×, quadratic ≈4.0×). Allocation, not wall-clock — GC bytes are deterministic, so it is machine-independent and noise-free |
| `test/diff_compiler_capability_matrix.sh` | Every extern in `stdlib/runtime.mdk` vs what each engine actually implements (EXISTENCE). Its absence let 37 externs drift for six weeks. Ledger: `test/CAPABILITY-EXCEPTIONS.txt`. **Also (#476) the DOMAIN requirement:** every *pure* extern (no `<Cap>` annotation — derived, not hand-listed) must carry a verdict in `test/EXTERN-DOMAIN-LEDGER.txt` — `TOTAL` / `BOUNDARY` (edge cells pinned across all 3 engines) / `PENDING` (edge domain, cells owed, `#NNN`) / `EXEMPT`. A new pure extern with no row FAILS (self-drains). This is what would have caught the `floatToInt` 3-way edge divergence (#346) structurally |
| `test/diff_compiler_tmc_parity.sh` | Both backends TMC the same functions (needs `sh test/wasm/build_wasm_oracle.sh`) |
| `test/bootstrap_*.sh` | Each native pipeline stage == interpreter output |
| `test/diff_compiler_must_fail.sh` | **The MUST-FAIL suite — the TRACKER's self-drain.** Each `test/must_fail_fixtures/*/` asserts one OPEN issue's bug **still reproduces**; when a fix lands the fixture flips green and **FAILS the gate**, naming the issue to close. **A RED here is usually a GOOD failure, not your break.** Runs in `soundness`, not a shard |

⚠️ **When a pin DRAINS, the gate offers two remedies — prefer RE-POINTING it at a regression gate
over deleting it.** Deleting removes the only executable memory that the shape was ever broken, and
a drained fixture is not a drained *class*: on 2026-08-14 both #1617 and #1618 drained while
**#1630** — the same arm, one type constructor over — stayed live. Re-pointing also tends to
*recover* coverage, because the must-fail harness runs one `cmd:` plus one `control:`, so any
second dimension a fixture carried (a permutation twin, a build-vs-run cell) was sitting there
**ungraded**; moved into a differential gate it starts executing. Derive the destination — look for
an existing gate that already owns siblings of that bug class — rather than inventing one.

🚨 **A drain is invisible to the local loop.** `test/preflight.sh` does not map `soundness` at all
(`grep -n must_fail test/preflight.sh` returns nothing), so neither `make preflight` nor
`PREFLIGHT_DRY=1` will tell you a pin is about to flip. It surfaces only in CI. **And when the
must-fail step fails, the steps AFTER it in that job are `skipped`** — including
`typecheck_compiler_source.sh` and the C3b fixpoint, i.e. the two that catch an ill-typed compiler
and a broken emitter. A red `soundness` you have "explained" as a licensed drain is therefore also
a `soundness` that **ran neither of them**; read the step list, not the rollup:
```sh
gh api repos/MedakaLang/medaka/actions/jobs/<job-id> --jq '[.steps[] | "\(.conclusion) :: \(.name)"]'
```
| `test/check_removed_constructs.sh` | Tree-wide scan for stale uses of removed constructs (~2-3 min, `JOBS=` knob) |

**Stale oracles:** `run_gates.sh` already derives which `test/bin/*` probes the SELECTED gates
read, compares their mtimes against `compiler/`/`stdlib/`/`runtime/` source, and REFUSES to run
(exit 1, printing the exact narrow `--build-one`/`--for` rebuild command) rather than report a
false pass/fail — so for any gate you run through it, staleness is already handled for you.
Override with `NO_STALE_CHECK=1` only if you know exactly why. `diff_native_cli` and the
bootstrap suites are especially stale-prone when invoked OUTSIDE `run_gates.sh` (e.g. bare
`sh test/diff_native_cli.sh`) — force-rebuild before trusting a pass/fail from those.

🚨 **THE GOLDEN-CAPTURE PATH READS THE SAME ORACLES AND HAS NO GUARD AT ALL — so a stale
oracle does not just mis-report a gate, it can BLESS A WRONG GOLDEN, which is permanent.**
`sh test/capture_goldens.sh --frozen selfproc_legA` and `sh test/diff_compiler_selfproc.sh`
both read `test/bin/check_all_main`; `run_gates.sh` would refuse on its mtime, and neither of
those invoked directly will. Measured 2026-08-15 on PR #1640: after merging `main`, the
LEG A golden was re-derived against an oracle built **before** the merge — the gate read
`16 ok, 0 failing` and the bless looked clean. Rebuilding the oracles and re-deriving from
scratch produced a byte-identical golden, **so the artifact was right and the evidence for it
was not.** ⇒ **After ANY merge or rebase, rebuild the oracles BEFORE capturing a golden**, and
prefer routing the check through `run_gates.sh` afterwards so the guard is in the loop. A
wrong gate verdict is loud on the next run; a wrong golden becomes the expected output.

**Parallelism.** The oracle build, `run_gates.sh`, the heavy compiler gates, and every wasm
gate fan out across an `xargs -P` pool — cap with `JOBS=n`, or `INNER_JOBS=n` for per-gate
fan-out inside `run_gates.sh`. Opt-level knobs (`EMITTER_OPT` -O2, `ORACLE_OPT` -O0,
`CLI_OPT` -O2, `WASM_ORACLE_OPT` -O2 — **-O0 overflows the deep-TCO fixtures**) and
`GC_INITIAL_HEAP_SIZE` **all preserve byte-identical emitted IR**: the text IR is produced
before `clang` runs, so an opt level can never change it. Details:
`compiler/PERF-RESULTS.md`.

**Concurrent `medaka build` is scratch-path safe.** `build_cmd.mdk` stages every scratch
file inside ONE `mktemp -d` unique to that build *process*. ⚠️ Until 2026-07-13 the IR path
was keyed on the OUTPUT BASENAME in global `/tmp`, so two concurrent builds writing
`-o <somedir>/out` — different worktrees, different repos — clobbered each other's IR and
produced a **stable-looking WRONG binary** (19/20 iterations). Anything that "keys the temp
file on something distinctive" is a trap; only a per-process temp dir is correct. Still run
a newly-parallelized gate several times — a temp-collision flake shows ~1 in N.

⚠️ **That guarantee is about `medaka build`. It does NOT cover two full `make medaka`
invocations in the SAME worktree (#1141)** — `test/build_native_medaka.sh` used to write
`./medaka_emitter` and `./medaka` directly to their final paths with no lock, so a reader
could reasonably (and wrongly) generalize the scratch-path safety above to the whole build
path. Fixed the same way the codebase already fixed `EMITTER` in stage A: every output
(`$EMITTER`, `$OUT`, `.medaka_emitter.srcstamp`) is now built under a `*.new.$$` name
**beside its own final path** (not under `$WORK`/`mktemp -d`, which can be a different
filesystem — e.g. tmpfs `/tmp` vs the repo's real disk — making `mv` a non-atomic EXDEV copy)
and promoted with a same-filesystem `mv`. Two concurrent `make medaka` runs now race only for
*last write wins on a complete artifact*; neither can observe or leave behind a
partially-written binary. No lock, so no stale-lock case to strand a killed agent behind.

### Pre-commit hook (ACTIVE) — fmt + lint + snapshot + lextok

`.githooks/pre-commit` runs FOUR checks (fmt + lint always; snapshot + lextok gated on what's
staged) over each staged `.mdk` (`test/` fixtures excluded from fmt/lint — they violate style
on purpose). Re-install after a fresh clone:
`cp .githooks/pre-commit "$(git rev-parse --git-common-dir)/hooks/pre-commit"`.

- **Format** — `medaka fmt --check` rejects any staged unformatted `.mdk`. **Run `medaka fmt --write
  <changed.mdk>` and re-`git add` before committing any `.mdk` edit.** A bare `medaka fmt <file>`
  (no flag) is READ-ONLY — it never writes, and behaves like `--check` (reports files that aren't
  formatted, exit 1 if any). **`--write` is the only mode that mutates**, and it always prints a
  one-line summary (`formatted N file(s)` / `already formatted`) so a write is never silent (#1348 —
  the bare form used to default to writing, silently, with no output). `medaka fmt --help` (and
  `--help`/`-h` on every other subcommand) prints that subcommand's flags.
  ⚠️ **The tree is NOT fmt-clean** (verified 2026-07-14): `sqlite/lib/varint.mdk` and
  `stdlib/byteparser.mdk` both fail `fmt --check`, so touching either drags an unrelated
  `.[`→`[` normalization into your diff. (This file claimed "the whole tree is clean". It isn't.)
  **`fmt --write` on a file holding a float literal ≥ 1e15 is FIXED** (#51, CLOSED
  2026-07-15; re-probed 2026-07-16 per #361): it still writes `9e+15`, but the lexer now
  reads that back correctly (`main = println 9000000000000000.0` → `fmt --write` →
  `main = println 9e+15` → `check`/`run` both round-trip to the same `9e+15`, verified
  on the current binary). No longer a destructive operation.
- **Lint** — the tree is at **0 findings and the hook is a MAX RATCHET: all ~20 rules gated**,
  so any NEW finding of any rule fails the commit. The cross-file `rule-duplicate-body` can't
  be checked per-staged-file, so the hook also runs one whole-project scan (`medaka lint
  compiler stdlib sqlite`). **Run `medaka lint` on files you touch.** Silence a genuine
  exception inline: `-- lint-disable-next-line <rule>` (also `-- lint-disable-line`,
  `-- lint-disable-file`; omit the rule to disable all). ⚠️ `medaka lint --fix` **bails on any
  decl containing an interior comment** (it would otherwise drop them) — safe, but it leaves
  comment-bearing sites unfixed.
- **Snapshot** — CHECK ONLY (this hook can never bless): gates on `test/diff_compiler_snapshot_frontend.sh`
  over ANY staged `.mdk` (test/ fixtures included — they're in the corpus) plus `test/snapshots/*.md`
  itself, since a compiler-source change or even a pure `medaka fmt` reflow can move a snapshot.
  A stale snapshot fails the commit rather than reading as tooling breakage. **Run `make
  snapshot-check` first**; to bless a moved snapshot, `sh test/diff_compiler_snapshot_frontend.sh
  --bless <file.mdk>` then re-stage `test/snapshots/` and read the diff (that diff is the real
  ⚠️ **A NEW compiler source file needs `--new`, and `--new` is NOT `--bless`'s sibling — it is
  SUITE-WIDE.** It never overwrites (so existing goldens are safe), but it **skips** everything it
  did not create and says so honestly: *"0 compared, 201 skipped: NOTHING COMPARED (this is not a
  pass)"*. ⇒ **run `--new`, verify it created exactly what you expected (`diff -rq` against a
  before-copy), then RE-RUN the plain check** — the re-check is what makes it a pass. Measured
  2026-08-14 creating `test/snapshots/compiler/route_key.md`: 1 new, 0 blessed, 201 skipped, and the
  subsequent check read 202/202.
  review gate).
  ⚠️ **This check reads the WORKING TREE, not the index** — a `--bless` you forgot to
  `git add` used to be invisible to it (it "passed" because the disk looked current, while the
  commit about to be made still carried the OLD golden — a SILENT version of the exact hazard
  "bless in the same commit" exists to prevent). Fixed (#1179): an unstaged snapshot diff now
  fails check 4 outright, unconditionally, before the suite runs — `git add` it and re-commit.
  ⚠️ **"bless in the same commit" and "goldens are re-cut in their own terminal commit" are
  only in tension for a source-only commit whose golden isn't blessed yet** — that legitimately
  fails check 4, since the golden for the staged source is by construction not staged. That's
  correct: the property check 4 protects (main never observes a moved source with a stale
  golden) is a **per-push**, not per-commit, property — the merge queue tests the PR's merged
  result, not each intermediate commit (§ merge queue above) — so a source commit followed by a
  separate terminal golden-recut commit *within the same PR* already satisfies it.
  **`PRECOMMIT_SNAPSHOT_DEFER=1 git commit ...`** opts that one commit alone out of check 4 (fmt/
  lint/lextok stay live — unlike `--no-verify`, which drops all four) for exactly that shape;
  CI's snapshot shard still enforces the real gate against the merged tree, so a forgotten golden
  still reds the PR. Do not reach for `--no-verify` for this case anymore.
  🚨 **`PRECOMMIT_SNAPSHOT_DEFER=1` does NOT reach the UNSTAGED-snapshot guard, so "goldens in
  their own terminal commit" and any LATER `.mdk`-staging commit are MUTUALLY EXCLUSIVE.** The
  guard (the `git add` it forces, above) fails any commit that stages a `.mdk` while a blessed
  snapshot sits unstaged on disk — and `PRECOMMIT_SNAPSHOT_DEFER=1` opts out of check 4's *suite*,
  not out of that guard. Measured 2026-08-14 on PR #1638, where the intended order was source →
  pin (a `.mdk`) → goldens. **Remedy: bless and stage the goldens LAST, after every `.mdk`-staging
  commit is already in** — or stash them across the intervening commit. Neither `--no-verify` nor
  `core.hooksPath=/dev/null` is the answer; both drop all four checks.
- **Lextok** — OPPORTUNISTIC: only runs when `test/bin/lex_main` already exists (this hook
  never builds an oracle), scoped to staged `.mdk` files that already have a sibling
  `.lextok.golden`. Gates on `test/diff_compiler_lex_files.sh`. Remedy for a stale golden:
  `CAPTURE=1 sh test/diff_compiler_lex_files.sh <files>`, then re-stage the `.lextok.golden` file(s).

Emergency bypass for any of these: `git commit --no-verify`. If `medaka` isn't built, the hook
warns and allows.

### Debugging a `.mdk` program

`medaka check <file>` prints human `file:L:C:` diagnostics. **`medaka check --json <file>`**
(note: `--json`, not `--format=json`) emits one JSON object per diagnostic carrying a stable
**`code`** (`T-*` type · `R-*` resolve · `P-*` parse · `L-*` lex · `W-*` warning), a `kind`,
a real `range` (0-based LSP line/char), `severity` (1=error, 2=warning), the `message`, and —
for suggestion-bearing errors — a `help` string plus a machine-applicable
`fix { range, replacement }` you can apply verbatim. **When reacting to compile errors
programmatically, prefer `--json` and key off `code`** — it is the stable handle and doesn't
move when wording changes.

🚨 **BUT `check --json` HAS A SILENT-ACCEPT HOLE ON MULTI-MODULE PROJECTS (#1362, OPEN S0), AND
`medaka mcp`'s `medaka_check` INHERITS IT.** On a multi-module project an internal-extern
restriction violation is dropped entirely: **exit 0, empty diagnostics**, where the human
`check` arm correctly rejects at exit 1. Confirmed over a real JSON-RPC call to the MCP tool
(`isError: false`). Cause: `analyzeProject`'s `resolvePass` calls the unguarded `resolveModule`
instead of the guarded `resolveModulesErrorsG` variant. **A green from the machine-readable arm
is therefore not proof a project checks clean** — this is the one place the advice above bites
you, and it is silent wrongness in the tool used to detect wrongness. Scope, derived rather
than assumed: `env.internalGuard` has exactly one read site, so it is *this* restriction and not
the whole diagnostic channel; a single file is unaffected (different code path); `run --json`
does not share the omission. Pinned at `test/must_fail_fixtures/1362-*` — when that row drains,
delete this paragraph. **Until then, corroborate an important `--json`/MCP green with human
`check`.**

**`medaka run --json` and `medaka lint --json` emit the SAME `Diag` JSON envelope** (same
`code`/`kind`/`range`/`severity`/`message` schema as `check --json`) — so a RUNTIME panic, not
just a compile-time error, is machine-parseable the same way.

**Bare `medaka check` filters its scheme dump to the user's OWN top-level bindings** (0.1.0
beginner-UX change — it used to dump the whole ~120-line prelude `=== TYPES ===` corpus ahead
of your own). **`--types` restores the full dump**, prelude schemes included — reach for it
when you need to see what a prelude method (e.g. `pure`/`when`) actually infers to.

When **writing** a diagnostic, follow `compiler/ERROR-QUALITY.md` (the rubric) and add the
code to `compiler/DIAGNOSTIC-CODES-DESIGN.md`.

**To see the TYPED, DICT-PASSED Core IR — the routes and `$dict` params themselves — run
`compiler/entries/core_ir_typed_modules_dump_main.mdk`.** This is the probe for *any* dispatch,
dict-routing, or `requires` bug, and it is the one that answers "which impl did it actually pick,
and what dicts did it actually pass?" It mirrors `llvm_emit_modules_main.mdk` exactly
(`driveModules → runEmitWith → mangle → elaborateModules → dceFilter → lowerProgramEmit`) but
prints `cprogramToSexp` instead of emitting LLVM. An agent chasing a run-path dict bug on
2026-07-16 called it *"the single highest-value tool here — it turned three days of plausible
speculation into a 10-minute proof"*, and it is what disproved a wrong root cause I had briefed.
**Reach for it BEFORE reasoning about routes from the source.**
⚠️ **Do NOT reach for `core_ir_dump_main.mdk` instead — the obvious name is a TRAP.** It is
**prelude-free and typecheck-free**, so it never shows a `$dict` param or a `CDict`/`CMethod`
route: it will show you a clean tree and "confirm" there is no bug. (Its typed sibling's own
header says exactly this — it just wasn't reachable from here.)

**To see the emitted LLVM IR — `medaka build --keep-ir <file>` (or `MEDAKA_KEEP_IR=1`)**, which
writes the IR to **`<output>.ll`** — beside the `-o` target, or beside the default output name if
you passed none — and prints **only that path** (`kept IR: <path>`), *not* the IR itself. On a write
failure it prints `warning: could not keep IR at <path>: <err>` and the build still succeeds — the
note is best-effort either way (`effectiveKeepIr` / `keepIrNote`,
`compiler/driver/build_cmd.mdk:311-319`). **So: `cat` the `.ll`; never expect IR on stdout.**
⚠️ This line said "prints it" until 2026-07-17, which cost an agent a grep cycle looking for IR
that was never going to arrive. `MEDAKA_KEEP_IR=1` is equivalent to the flag; `MEDAKA_KEEP_IR=""`
correctly reads as **unset** (`envOr` maps `Some ""` to the default), so it is *not* an instance of
the empty-env-var-reads-as-set trap. Reach for this the moment a bug is "check/run are green but
the built binary is wrong": it is the only way to see what the backend *actually* emitted, and it
settles dispatch/arity/calling-convention questions that are pure speculation from the source. An
agent debugging a dict-routing S0 on 2026-07-16 called it the single highest-value tool in the
investigation — it turned "I think the wrong impl is selected" into `call
@mdk_impl_S__List_a___s` on the screen, which disproved the filed root cause outright.
⚠️ **`./medaka_emitter <file>` is still NOT the way to get IR** — its CLI is
`<runtime.mdk> <core.mdk> <entry.mdk> [root ...]`, so a bare `./medaka_emitter <file>` is a usage
error, not a build. It no longer LIES about it: every error path of the shared probe scaffolding
now exits **1** with a stderr diagnostic (#440 — `failWith`,
`compiler/entries/entry_support.mdk`), so
`./medaka_emitter … > out.ll || die` fires. Until 2026-07-17 all of them exited **0** with **empty
stdout**, which handed a redirecting harness an empty artifact + apparent success — the same for a
**nonexistent input file** or a **real typecheck error**, not just a wrong arity. `medaka build
--keep-ir` remains the supported route.

🚨 **`medaka build`'s EXIT CODE DOES NOT SURVIVE A PIPE — `... | tail`/`| head`/`| grep`
reports the LAST stage's status, so a failing build reads as exit 0.** Two reviewers in one
session nearly reported *"build fails at exit 0"* as a defect after piping the output to
keep it short; the compiler was exiting 1 correctly the whole time. Same trap the must-fail
suite's own header calls out for `run` (`test/diff_compiler_must_fail.sh`) — it applies to
every verb, and it bites hardest on `build`, whose interesting output is on **stderr** and
therefore invites a `2>&1 | tail`. **Redirect to a file and read `$?`, then read the file.**
Derive it on the spot with any program that fails to build:
```sh
./medaka build broken.mdk -o /tmp/x > /tmp/x.log 2>&1; echo "direct: $?"   # 1
./medaka build broken.mdk -o /tmp/x 2>&1 | tail -1;    echo "piped:  $?"   # 0 — tail's status
```

**`medaka run` and `medaka build` share the whole front end** — both typecheck with the
**same binary**; they differ only in the execution engine (interpreter vs emitted native +
runtime). So comparing `run` against `build` is a genuine test of **codegen and runtime**
behavior (it is how several miscompiles were caught), but it is **NOT** two independent
observations of anything at or before typecheck — a claim about resolve/typecheck-stage
behavior gets exactly **one** observation from that pair, not two.

⭐ **TWO-ARM DIFFERENTIAL REVIEW (base binary vs branch binary): a `medaka` binary resolves
its emitter AND its stdlib from `exeDir` — the directory the BINARY sits in — not from the
project root of the file it is compiling, and not from cwd.** `exeDir = dirOf
(executablePath ())`, `defaultMedakaRoot = exeDir`, `defaultMedakaEmitter = joinPath exeDir
"medaka_emitter"` (`compiler/driver/build_cmd.mdk`, the *"exe-relative install-layout
defaults"* block); every `<root>/stdlib/...` read goes through `envOr "MEDAKA_ROOT"
defaultMedakaRoot`. This is documented nowhere else and it is what makes a two-worktree
comparison sound: **a base-arm binary invoked on files in a branch worktree still uses
base's stdlib and base's emitter**, so the only variable is the compiler under test. It
also means `MEDAKA_EMITTER`/`MEDAKA_ROOT`, if either is exported in your shell, silently
CROSSES the arms — check for them before believing a differential. Verify from the
consequence, not the source: copy `./medaka` alone into an empty directory and run it from
inside a real checkout — it reports `cannot read the stdlib prelude at
"<that-empty-dir>/stdlib/runtime.mdk"`, naming the binary's own directory, with cwd and the
source file both elsewhere.
```sh
mkdir -p /tmp/alt && cp ./medaka /tmp/alt/            # cwd stays the repo root
printf 'main = println 12345\n' > /tmp/hello.mdk
/tmp/alt/medaka run /tmp/hello.mdk                    # exit 1: looks in /tmp/alt/stdlib
MEDAKA_ROOT="$PWD" /tmp/alt/medaka run /tmp/hello.mdk # exit 0: 12345
```
⚠️ The miss diagnostic offers *"run from the project root"* as a remedy; measured, cwd
being a directory that HAS `stdlib/` did **not** rescue it — only `MEDAKA_ROOT` or an
exe-adjacent `stdlib/` did.
🚨 **THE SAME PROPERTY MAKES A TWO-ARM DIFFERENTIAL UNSOUND WHEN THE TARGET IS ITSELF A
`stdlib/*` FILE — and it fails in the direction that manufactures FINDINGS.** The
internal-extern guard trusts a stdlib file only when it sits under the *binary's own*
`MEDAKA_ROOT` (= `exeDir`). So a base binary living in one worktree, pointed at the branch
worktree's `stdlib/array.mdk`, sees that file as **outside its stdlib** and rejects it with
`R-INTERNAL-EXTERN` — while the branch binary on its own tree accepts. That reads exactly
like *"the branch fixed 14 stdlib files"*. Measured 2026-08-15 on PR #1640: a reviewer
reported 14 `base=1 → pr=0` stdlib divergences, then **retracted all 14** after swapping the
file's tree reversed the direction — the variable was the file's location relative to the
binary, not the compiler. Re-run with **each binary against its OWN tree's `stdlib/`** (and
the tree prefix normalized before diffing): **0 divergences across all 29 modules.**
⇒ For `stdlib/*` targets, either give each arm its own tree or set `MEDAKA_ROOT` per arm —
never point one binary at the other's stdlib.
🚨 **`stdlib/` is NOT the whole exe-adjacent layout — `medaka build` also needs `runtime/`
there, and the gap bites only on the FIRST `build`.** The complete set beside the binary is
`medaka` + `medaka_emitter` + `stdlib/` + **`runtime/`**: `runBuildNativeRoots`
(`compiler/driver/build_cmd.mdk`) computes `rtC = joinPath root "runtime/medaka_rt.c"` off
that same `root`, and hands it to `clangLink` as a **clang input**, so a binary with only
`stdlib/` beside it *checks and runs perfectly* and then dies at the link step. Derive the
mechanism rather than trusting this paragraph — `grep -n 'medaka_rt.c' compiler/driver/build_cmd.mdk`
shows the `joinPath root` site and the `clangLink cc rtC …` call. **The timing is the trap:**
`check` and `run` succeeding "prove" the alt-dir arm is wired up, and the first `build` — which
is usually where a two-arm differential gets interesting — is where it isn't. Two reviewers hit
this in one 2026-08-11 session. Extending the probe above, one symlink at a time (measured):
```sh
mkdir -p /tmp/alt && cp ./medaka ./medaka_emitter /tmp/alt/ && ln -s "$PWD/stdlib" /tmp/alt/stdlib
/tmp/alt/medaka run   /tmp/hello.mdk                                   # exit 0: 12345 — looks complete
/tmp/alt/medaka build /tmp/hello.mdk -o /tmp/alt/hello > /tmp/alt/b.log 2>&1; echo "build: $?"
cat /tmp/alt/b.log   # exit 1 — clang: error: no such file or directory: '/tmp/alt/runtime/medaka_rt.c'
ln -s "$PWD/runtime" /tmp/alt/runtime
/tmp/alt/medaka build /tmp/hello.mdk -o /tmp/alt/hello > /tmp/alt/b.log 2>&1; echo "build: $?"   # 0
```
⚠️ Note the redirect-then-read: `medaka build`'s exit code does **not** survive a pipe (the
`build`-piped-exit-code trap above), so do not shorten that to `| tail`.
⚠️ **Not every gate lets you point it at a second binary.** Some honour an override; most
hardcode `$ROOT/medaka`, so a two-arm run means a second worktree.
**DERIVE the set, do not trust a count — including this sentence's:**
```sh
grep -rln 'MEDAKA="${MEDAKA:-' test/*.sh     # the gates you CAN point at a second binary
```
⚠️ Run that through a script file, not inline: this harness mangles a `${…}` inside a
quoted inline argument and returns zero matches for a pattern that is really there.
`test/diff_compiler_shadow_semantics.sh` is the notable hardcoded one and is filed as
**#1431** — check the gate before planning a differential around it.
🚨 This paragraph said **"Four honour an override"** until 2026-08-09, *while citing the
very command that returns more than twice that*. Nobody ran it — the number came from a
report, was repeated into #1431, and reached this file unverified. **A claim that ships its
own derivation is only honest if someone executed it**; that is the whole point of the rule
and it failed at the last inch here.

**Playground e2e:** `playground/e2e/` is a Playwright harness driving a real browser against
the built CM6 playground (`cd playground/e2e && ./run.sh`). Needs **node v24+** and a
pre-built `playground/dist/playground.wasm`; uses the **system** Chrome. See
`playground/e2e/README.md`.

## Traps

Each of these was paid for in an incident. **They are pointers, not post-mortems** — the
narrative lives at the link.

- ⚠️ **Changing the emitter? Read the `benchmark-emitter` skill BEFORE measuring anything.**
  A binary's *behavior* comes from its source but its *speed* comes from the emitter that
  compiled it, so you need **two** rebuilds to get a single-generation binary. One rebuild
  crosses the arms and makes an optimization look like a regression (a real 2.2× win once
  measured as a 2.5× slowdown). Same skill covers seed re-mints — `test/refresh_seed.sh` is
  **not idempotent after a codegen change; run it TWICE** — and why a **stale seed can
  SEGFAULT the fixpoint on a perfectly correct change**.
- ⚠️ **Chasing a slow stage or a red `perf_scaling`? Read the `perf-hunt` skill.** Profile
  **allocation** (deterministic) over wall-clock (noisy); use **DWARF** call graphs; and note
  `whenL False (expensiveCall …)` is **NOT a stub** — Medaka is strict, so the argument still
  evaluates (this produced a false "hypothesis disproved" on a *correct* hypothesis).
- ⚠️ **A dispatch bug that reproduces through the loader but is green single-file is
  *usually* the EVAL DRIVER, not dict-passing** (recurred at Phases 96/103/121/125). **But
  verify — Phase 134 was the documented inverse**, and the two-probe comparison did *not*
  flag it. Full method, both probes, and the instrument-the-resolution-arms technique:
  **`debug-pipeline` skill**. Regression tests for this class must exercise the multi-module
  path (`test/diff_compiler_eval_modules.sh`), not a single-file doctest.
- ⚠️ **`evalModules` (`eval/eval.mdk`) and `cevalModules` (`ir/core_ir_eval.mdk`) are PARALLEL
  module drivers — fix module-frame semantics in LOCKSTEP.** `cevalModules` deliberately
  mirrors `evalModules` (same frame layout, same `importFrameOf`/`pubReexports`/`installConsts`
  helpers), so a fix to one is **silently absent from the other**. That is how the P0-9
  cross-module ctor-collision fix shipped patching only `eval.mdk`, leaving `core_ir_eval.mdk`
  broken for months. Underlying hazard: **`installConsts` + `findCell` is last-write-wins on
  duplicate names**, so any flat frame keyed by *bare name* across modules inherits it (e.g.
  `map`'s arity-5 `Bin` vs `set`'s arity-4 `Bin` collapse into one cell). The fix shape is a
  per-module **local** ctor frame that shadows the global.
- 🚨 **ADDING A PROGRAM-GLOBAL TABLE OR A NEW AST CONSTRUCTOR? The required fixture is
  "feature + UNRELATED code still behaves", NOT "feature works".** This is the single most
  expensive shape in this tree, and it is invisible to every gate: on **2026-07-24 alone it
  was the root cause of an S0, an S1, and a def-site regression across four different PRs —
  every one of them 12/12 green.**

  Two forms, one failure:
  - **A new AST constructor** is silently swallowed by every `_ =>` wildcard arm in every
    pass that does not yet know about it. Exhaustiveness checking is a *floor*, not a
    guarantee — a wildcard is exhaustive and wrong. Audit the arms as a **SET**.
  - **A program-global table** (a universe accumulator, a kind/type registry, a rename map)
    is keyed by something, and if that key has **no scope**, entries collide across modules
    that have no import relationship at all. Real example: a graded-interface kind table
    keyed on a bare type-param name re-kinded *every* arity-matching application in the whole
    module graph, so `f Int a -> f String a` was **silently accepted** (`meowmeow` for
    `meowwoof`, exit 0, no diagnostic), and one 4-line file turned 1 clean diagnostic into 45.

  **Why the gates cannot help you.** A fixture that exercises your feature passes. The
  goldens you blessed pin the output you expected. Nothing in the suite asks *"is the code
  that has nothing to do with this change still correct?"* — so the failure mode is
  specifically that **your feature works perfectly and something unrelated breaks.**

  **What to write instead:** a fixture where the new construct is present but the assertion
  is about code that does not use it. A module that never imports your feature. A binding
  whose type mentions none of your new machinery. The prelude. If your change adds a table,
  ask *what happens to a program that never touches it* — and if the answer is "nothing, it
  is keyed per-X", **prove the key is scoped** rather than asserting it (`<iface>@<slot>`,
  never a program-global bare name).
- ⚠️ **A FIXTURE'S LINE COUNT IS LOAD-BEARING — a COMMENT-only edit can move its own
  golden.** Many `test/*_fixtures/*.mdk` have a golden pinning `file:LINE:COL`. Replacing a
  5-line comment header with a 6-line one shifts every line below it and moves the golden,
  on a change that touched no code. Two agents hit this on 2026-07-31; one caught it only
  because a STOP guardrail made them suspicious. **Keep fixture comment edits
  line-count-neutral** (`git diff --numstat` should read `N N`), or re-derive the golden
  and say why it moved. The shared-corpus bullet below covers adding/moving/deleting a
  fixture; it does not cover editing one in place, which is the quieter hazard.
- ⚠️ **In `PerRun` (`compiler/types/typecheck.mdk`), a trailing side comment may describe
  the field ABOVE it — check before believing one.** The record's side comments are a
  column-wise prose *river*: a sentence starts beside one field and continues beside the
  next several, so `effvarCounter`'s comment finishes a clause begun on `inRigidityBodyRef`.
  This is a READING hazard baked into the committed source, not something `fmt` still does
  to you.
  🚨 **The WRITING hazard is NOT fixed. #829 is REOPENED (2026-08-05) — this bullet's
  "FIXED, retired 2026-08-01" claim was itself wrong, and it sent an agent's mandatory
  `fmt --write` into corrupting their own comment.** Re-verified first-hand on a fresh cold
  `make medaka` of `origin/main` @ `f9db4fd2` (2026-08-05); both halves the retraction
  claimed were fixed were re-tested independently and **both still reproduce**:
  - **Standalone `--` block** (the issue's own two-line repro, `data Cfg =\n  | Cfg { … }`):
    `fmt --write` collapses the header to `data Cfg = Cfg {` and drags the block onto the
    field **two past** the one it described, with the block's second line dangling onto the
    closing `}`.
  - **Long trailing comment**: on the same header shape, a trailing comment on `alpha`
    lands on `beta` after `fmt --write` — moved one field down.
  - **On the real `PerRun` record**, with its header artificially put into the two-line
    `data PerRun =\n | PerRun { … }` shape (the shape `DriverState`, in this same file, is
    actually in today) and given ONE new field with a trailing comment plus one standalone
    two-line block elsewhere in the body: `fmt --write` shifted **every one of the record's
    ~60 trailing comments down by one field**, piling the last two onto the closing `}` line
    — the whole-record cascade the reader-hazard paragraph above is a residue of.
  - **In every case, `fmt --check` on the corrupted output exits 0** — it reports the damage
    as already formatted, so the pre-commit hook (which gates on `fmt --check`, not a diff
    against intent) lets it through. The corruption is a stable fixed point, not a slow leak:
    a second `--write` reproduces the damaged file byte-for-byte, so it doesn't get worse,
    but it also never self-heals.

  **The trigger is the header shape, not the comment kind.** Both halves reproduce only when
  the record's on-disk header is still the two-line `data X =\n  | X { … }` form (e.g.
  `DriverState`, this file, today) — confirmed on that exact record: adding one field with a
  trailing comment moved the comment onto the *next* field. Three things are safe, each
  measured on this binary, not assumed:
  - Adding a field with **no comment at all** is safe on either header shape — `fmt --write`
    produces a byte-identical diff (only the added field line).
  - Adding a comment to a record whose header is **already** the single-line `data X = X {
    … }` form (PerRun's current shape) is safe — verified directly on `PerRun` as it stands
    today: a new trailing-commented field and a new standalone two-line block each produced a
    diff containing only the intended edit, and a second `fmt --write` was a no-op.
  - If the header is still two-line, don't put the comment in the record at all — the
    real-world workaround (PR #1296, still open, adding a new `Ref`-typed field to
    `DriverState`): add the field bare and put the explanatory prose on the nearby function
    that derives/populates it instead of as an interior record comment.

  Check the shape before you decide: `grep -n '^data <Name> =$' -A1 compiler/types/typecheck.mdk`
  — a hit followed by `  | <Name> {` is the unsafe two-line form; `data <Name> = <Name> {`
  on one line is the safe collapsed form. Either way, don't trust `fmt --check` to catch a
  misattached comment — diff the decl by eye after any comment-bearing record edit.
- ⚠️ **A FIXTURE DIRECTORY IS A SHARED CORPUS.** Adding, moving, or deleting a fixture
  silently enrolls (or de-enrolls) you in gates you never named. Before touching one,
  **ENUMERATE every consumer, then run all of them.**
  ⚠️ **Do not trust any count — including this sentence — and WORD-BOUND your grep.** Both
  halves of that matter, and this bullet has been wrong in both directions:
  - It used to say `test/wasm/fixtures/` had *"four"* consumers. That was wrong (it missed
    `diff_compiler_prelude_obj.sh`). A **"correction" to eight was also wrong** — a naive
    `grep -rl 'wasm/fixtures' test/` matches the **real sibling corpora**
    `test/wasm/fixtures_typed/` (9 files) and `test/wasm/fixtures_modules/` (36), which
    `diff_wasm_typed.sh`/`diff_wasm_modules.sh`/`build_wasm_cmd.sh` read *instead* of this
    directory. **The true count is five.** ⚠️ `test/preflight.sh` (grep `Word-boundaries`)
    already solves this — *"Word-boundaries on both sides so `llvm_fixtures` cannot match
    `llvm_fixtures_modules`/`llvm_fixtures_typed` (real sibling corpora in this tree)"* — so
    bound your pattern the same way, or the recipe this bullet hands you lies to you.
  - **That two successive "verified" recounts each produced a different wrong number is the
    point**, not an embarrassing footnote: a count is an encoded fact with no derivation and no
    expiry, while the enumeration is one command away. Write the command, never the number. An
    agent obeying a count literally runs a subset and believes it was exhaustive — the count
    manufactures the very confidence this warning exists to prevent. It is *"check the SET, not
    one member"* failing inside the sentence that teaches it.

  Cautionary example, not a list to trust: `test/eval_modules_fixtures/*/` feeds
  `diff_compiler_eval_modules.sh` **and** `diff_compiler_core_ir_modules.sh` — **P0-9 shipped
  "green" having run only the first.** ⚠️ Also note `test/wasm/diff_wasm.sh` and its `test/wasm/`
  siblings (`diff_wasm_typed.sh`, `diff_wasm_modules.sh`, `diff_sqlite.sh` — all wired directly in
  `ci.yml`) live in the `wasm/` subdir, **not** beside the other gates; assuming the flat path cost
  an agent two failed invocations on 2026-07-16.
- ⚠️ **The compiler's own sources are IN the snapshot corpus, so a source change MOVES ITS
  OWN GOLDEN. Land the golden in the SAME PR, before the merge queue runs — same commit is
  the default, but a separate terminal golden-recut commit is also fine** (that's the
  `PRECOMMIT_SNAPSHOT_DEFER=1` shape, #1179 — see the pre-commit hook section below). What
  must never happen is `main` observing a moved source with no golden at all: push the
  source with no golden anywhere in the PR and `main` goes red, and the hook then forces the
  *next* agent to bless a file they never touched — the exact "rubber-stamp someone else's
  regression" hazard blessing exists to prevent. Bless by NAMING the path; `--bless` refuses
  to rubber-stamp a whole corpus.
  ⚠️ **Bless via the GATE, not the CLI:** `sh test/diff_compiler_snapshot_<suite>.sh --bless <path>`
  (e.g. `…_frontend.sh`, `…_eval.sh`, `…_types.sh`). **`medaka snapshot --bless <compiler source>`
  is a dead end** — it looks for the `.md` next to the source and fails with *"no snapshot …
  `--bless` never creates one — run `medaka snapshot --new` first"* (exit 1). Two agents lost time
  to this on 2026-07-16 because this bullet said *what* to do and never *which command*.
  ⚠️ **A SECOND, easily-missed golden moves too: the selfproc LEG A *scheme* golden.** A
  compiler-source change that adds/renames/re-types a top-level binding also moves
  `test/selfproc_goldens/legA/<module>.golden` (that module's inferred schemes), diffed by
  `test/diff_compiler_selfproc.sh` **in the CI `backend` shard** — NOT the snapshot/check
  gates, so it stays green locally and reds only in CI. Re-capture: `sh test/capture_goldens.sh
  --frozen selfproc_legA`, then read the diff — it must be **additive-only** (no *existing*
  binding's inferred type may change; if one did, the "fix" changed types). LEG A corpus:
  `frontend.{ast,desugar,exhaust,lexer,marker,parser,resolve}`, `types.{annotate,typecheck}`,
  `driver.loader`, `eval.eval`, `ir.sexp`, `tools.check` — **not** `ir.core_ir_lower`, **not**
  `backend/*`. Three perf PRs reddened only this shard on 2026-07-24 by blessing the snapshot
  but forgetting this golden.
  🚨 **A REBASE WILL AUTO-MERGE THAT GOLDEN CLEANLY — a clean apply is NOT evidence the
  golden is right.** It is an ordinary ~1700-line text file with no merge driver
  (`git check-attr merge -- test/selfproc_goldens/legA/types.typecheck.golden` → `merge:
  unspecified`), so two agents' re-cuts that land in different regions three-way-merge with
  **no conflict marker at all**. That happened **three times in one 2026-08-11 session, to
  three different agents, on that exact file**. The result is a *blend of two derivations*,
  and **no gate can flag it**: the golden IS the oracle, so a plausible-looking blend simply
  becomes the new expected output — the same rubber-stamp hazard as blessing a red gate, but
  arriving with no red gate and no prompt to bless. **Remedy on any rebase: never hand-resolve
  a golden and never accept the clean auto-merge — take the base's version of BOTH moved
  golden families and RE-DERIVE from the rebuilt binary**, then read both diffs:
  ```sh
  BASE=$(git rev-parse origin/main)        # pin it — origin/main moves under you (see worktree traps)
  git checkout "$BASE" -- test/selfproc_goldens/legA test/snapshots
  make -C "$PWD" medaka                    # the golden must come from the REBASED source
  sh test/capture_goldens.sh --frozen selfproc_legA
  sh test/diff_compiler_snapshot_frontend.sh --bless <the source file you moved>
  git diff -- test/selfproc_goldens/legA test/snapshots   # additive-only, as above
  ```
- **The compiler MAY import `stdlib/`** — deliberately, per module (policy changed
  2026-06-29; the old blanket ban is retired). **Weigh it per module, don't import
  reflexively.** Measured:
  - Importing a module whose types' instances live in `core` (the always-present prelude) is
    **near-free** — `import list`/`import string` drag no new instance surface, so DCE trims
    to the referenced standalone fns (**−256 B, +2% ≈ noise**).
  - Importing a module that defines a **NEW type** is not: DCE keeps every `DImpl`/`DInterface`
    *whole* (runtime dict-passing → pruning an impl would be a silent miscompile), so
    `import map` drags `Map`'s entire Eq/Ord/Debug/Display/Mappable/Monoid surface in
    (**+34 KB binary, +4.8% self-compile**).
  - ⚠️ **Anti-pattern (measured): do NOT delegate the compiler's hot monomorphic helpers to
    prelude Foldable methods** (`elem`/`any`/`all`/`length`). They lose `||`/`&&`
    short-circuiting and become dict-passed fold+closure — doing this to `util.mdk`'s hottest
    helpers cost **+56% self-compile.** Keep hot inner-loop helpers monomorphic and
    short-circuiting.
  - Also: the imported module is re-typechecked on every compile *and* every fixpoint
    iteration; and once the compiler imports a stdlib module, any change there that perturbs
    emitted IR **forces a seed re-mint + fixpoint re-validation** (a feature — it converts
    silent `support/`-vs-`stdlib/` divergence into a build-time gate — but it is churn).
  - Migrating a `support/` structure to stdlib: a **polymorphic empty must be a nullary
    constructor** (a constructor *application* like `OMap Tip` is NOT generalized → it
    monomorphises → "Scheme vs Unit" cascades). Any harness running the emitter/probes over
    compiler source must pass `$STDLIB` as well as the compiler root.
- **Tuples are internally `__tupleN__`-headed `TApp` spines, not a `TTuple` node.**
  `(,)`/`(,,)`/`(,,,)`/`(,,,,)` in TYPE position names the bare *unsaturated* tuple
  constructor — that is what lets a higher-kinded typeclass bind to it (`impl Bimappable (,)`
  in `core.mdk`). A saturated `(a, b)` head is kind-inconsistent and deliberately unsupported.
  See `compiler/TUPLE-TYPE-CONSTRUCTOR-DESIGN.md`.
- **Errors accumulate.** Phases push into `compiler/driver/diagnostics.mdk` rather than
  raising on the first error. **Don't add early-exit/raise paths.**
- **To run a whole program, `main` must be a zero-arg value** (`main = …`, not `main () = …`).
  `medaka run` evaluates top-level bindings and checks `main` exists but never *applies* it,
  so `main () = …` is a silent no-op (exit 0, no output). Use `main = println …` for probes.
- **Medaka multi-arg lambdas are `x y => body`**, not curried `x => y => body`. Curried forms
  predating Phase 59.6 are legacy artifacts — match `x y => body` in new code.
- **The prelude is marked + dict-passed in the typed pipeline** (`markWithPrelude`,
  `compiler/frontend/marker.mdk`), so elaboration reaches prelude methods like
  `pure`/`when`/`unless`. **Untyped eval** (no marker/typecheck — e.g. quick eval tests)
  falls back to arg-tag "first impl wins" for return-position methods. `pure` needs types to
  dispatch, so **route it through the typed pipeline.**
- **Match-arm guards and refutable pattern-guards (`Pat <- e`) both lower natively and work
  in both forms.** Historically neither did; the multi-clause refutable-guard case was a
  run≠build **miscompile** until 2026-07-13 (the `__fallthrough__` sentinel read its jump
  target from a mutable Ref that `emitDecision` nulls across a body-level match — and a
  refutable guard desugars to exactly such a match, so "try the next clause" became
  `@mdk_oob`). It now carries its target in the node (`labelFallthrough`,
  `backend/emit_support.mdk`) — the design the **WasmGC backend already had, which is why
  wasm was never wrong.** Full write-up: `compiler/EMITTER-GAPS.md`.
- **In a worktree, edit the worktree's files — use the full absolute path.** The shell cwd
  resets to the main checkout each call, so a relative `grep -n compiler/foo.mdk` runs
  *there*; Read/Edit that bare path and you have silently changed the **main checkout**,
  which your worktree build never sees. If you slip: `cp` the edited files into the worktree,
  then `git -C <main> checkout -- <files>`.
- **Every worktree shares ONE `.git`, so `origin/main`/`main` move under you** — a sibling's
  `git fetch` advances the ref mid-task with no signal to you. Pin `BASE=$(git rev-parse HEAD)`
  at the start of a task and diff/checkout against `$BASE`, never a moving ref. Full failure
  modes + the pinned-`$BASE` recipe: `.claude/workstreams/HARNESS.md` (H-2).
- **For layout questions** (legal indentation shapes, leading-op set, then/else, tabs,
  let…in wrapping), `docs/spec/LAYOUT-SEMANTICS.md` is ground truth. Its §12 conformance
  contract is scoped to the **lexer's token stream only**: a lexer-vs-spec divergence is a
  lexer bug; a SYNTAX/PLAN-vs-spec divergence is a doc bug. A construct the spec licenses
  that the lexer heralds correctly but the **parser** still can't consume is a parser bug,
  not a lexer bug — don't generalize the rule that far (§12 item 5).
- Development is organized by numbered **Phases**. Open work: `PLAN.md`. Completed Phases
  1–97 with implementation notes: `archive/PLAN-ARCHIVE.md`. Commits reference phase numbers.

## Dogfooding the language

The stdlib and `compiler/` are written *in* Medaka, so prefer its idioms — but **only where
they genuinely improve readability**. Don't force-fit: most candidate sites aren't
improvements, and a rewrite that doesn't typecheck or that changes semantics is worse than
the original. **Verify the rewrite on the binary** (`medaka test <file>`).

Under-used but working: **operator sections** — `(==)`, `(+ 1)`, `(2 * _)` (left needs an
explicit `_`) instead of lambdas; pipe `|>`; compose `>> <<`; inclusive ranges `[lo..=hi]`;
record update `{ r | f = v }`; unary `!`.

⚠️ **Do NOT reach for these — they are REMOVED and are hard parse errors**, each with a
dedicated removal diagnostic in `compiler/frontend/parser.mdk`: the **`function` keyword**
(use `x => match x` with indented arms, or a multi-clause definition), **`let mut`** (use a `Ref`:
`let x = Ref 0`, `x := v`, read `x.value`), **backtick infix** `` `f` `` (use prefix
application), the **`record` keyword**, **`let-else`**, **named impls**, and **`default
impl`**. `test/check_removed_constructs.sh` is the tree-wide gate that keeps them out.

`docs/spec/SYNTAX.md` is the ground-truth list of what parses (⚠️ with one known lie: it
still lists backtick infix, which the parser rejects). `test/parse_fixtures/rare_constructs.mdk`
has minimal examples. The self-hosted parser doesn't cover everything — see PLAN.md "Known
parser gaps" before assuming `compiler/` can parse a construct.

## Writing tests

Tests are shell-based golden-diff harnesses: each `test/diff_compiler_*.sh` runs a native
pipeline stage against goldens in `test/*_fixtures/` or `test/*_goldens/`.

1. Add a fixture to the appropriate `test/` fixture directory (⚠️ first read the
   shared-corpus trap above).
2. Capture a golden: `bash test/capture_goldens.sh`, or the specific gate with `CAPTURE=1`.
   Narrower forms: `sh test/capture_goldens.sh <suffix-tag>` (e.g. `eval`) recaptures only
   that family; `sh test/capture_goldens.sh --check` dry-runs — re-derives and diffs against
   the committed goldens without writing anything.
3. Verify: `bash test/diff_compiler_<name>.sh` passes.

🚨 **A CAPTURED GOLDEN RECORDS WHAT THE ENGINE DID, NOT WHAT IS CORRECT. If the engine is
wrong for your shape, capturing ENSHRINES THE BUG as the expected answer** — and the gate then
defends it forever, going red on the eventual *fix*.

This is not hypothetical and it is not rare. **178 `*.eval.golden` files** are generated from
the interpreter (`test/eval_fixtures/`, `eval_dict_fixtures/`, `eval_list_fixtures/`,
`eval_modules_fixtures/*`, …), and **eval is currently a known-wrong oracle in at least five
open S0s** — #1034, #1037, #1040, #1047, #1062. Two separate PRs in one day nearly pinned a
shape whose eval golden would have baked in a wrong value; both were caught only because a
reviewer computed the correct answer **by hand** first.

**So before you `CAPTURE=1` anything:**

- **Work out the right answer independently** — from the language semantics, not from the tool.
  Then compare. A golden that merely matches today's output has tested nothing.
- **Cross-check the engines.** `eval` vs native vs wasm disagreeing means at most one of them
  can be the oracle. **All three agreeing does NOT prove correctness** — several known S0s have
  every engine equally wrong (e.g. #1047), which is exactly why `diff_compiler_engines` cannot
  see them.
- **If your shape is anywhere near a known-wrong area** (interface defaults, dict routing,
  method-less impls, head-tycon collisions, local bindings that forward a dict), assume the
  oracle is suspect and say in the fixture's own comment how you established the expected value.
- **If the engine is wrong and you cannot get a trustworthy golden, do NOT capture one.** Pick a
  neighbouring shape that *is* correct, or pin the bug in `test/must_fail_fixtures/` instead —
  that harness asserts a bug **still reproduces**, which is the honest thing to record when the
  engine is broken. See `test/MUST-FAIL-NOT-PINNABLE.txt` for how to declare a shape out of
  scope with a reason.

⚠️ The same caution applies to the **snapshot** and **selfproc LEG A** corpora, which render the
compiler's own source and inferred schemes: blessing them records what the current compiler
believes. A `--bless` that "fixes" a red gate without your having independently decided the new
output is correct is a rubber stamp, and the gate exists to prevent exactly that.

Add cases to the gate matching the stage you changed (parser change →
`test/diff_compiler_parse*.sh` or `diff_compiler_check*.sh`).

### ⚠️ Writing the SHELL half of a gate — two traps that make it pass for the wrong reason

`/bin/sh` on this box is **dash**, not bash (`readlink -f /bin/sh`), and gates are run as
`sh test/…`. Two consequences bite specifically when a gate manipulates **bytes** or
**time** — i.e. exactly when it is testing a binary format or a hang.

- **`printf '\xNN'` DOES NOT WORK IN DASH.** It emits the *literal characters*
  `\xde\xad\xbe\xef`, not four bytes. Measured: appending that to a 219-byte file produced
  **235** bytes, not 223. **Use octal — `printf '\336\255\276\357'`** — which POSIX
  `printf` does interpret.
  🚨 The failure mode is not a broken gate, it is a **gate that passes for the wrong
  reason**. A `gzip/` oracle case meant to corrupt a 4-byte CRC field was instead appending
  16 junk bytes and shifting the whole trailer; it still produced a CRC error, so it read
  green, and only surfaced when a *sibling* ISIZE case failed with a CRC message that made
  no sense. **If a gate rewrites a fixed-width field, assert the file LENGTH is unchanged
  afterwards** — that one line converts this from silent to loud.
- **`timeout` is coreutils and does NOT exist on macOS.** Every build/test script here must
  run on both platforms, and nothing enforces it (all 11 CI jobs are `ubuntu-latest`, so a
  macOS-only break ships with every check green). Use the shim already in
  `test/diff_compiler_engines.sh`, labelled there *"portable timeout (no coreutils on mac)"*:
  ```sh
  run_t() { perl -e 'alarm shift; exec @ARGV' "$@"; }
  ```
  ⚠️ **Not a drop-in substitution** — the shim is killed by `SIGALRM` so the shell reports
  **142** (128+14) where `timeout` reports **124**; real exit codes pass through unchanged.
  Move every guard with it, or the guard silently stops detecting the thing it was added
  for. Verify both, don't assume: `run_t 1 sleep 5; echo $?`.

Both are worth checking in review rather than trusting: `grep -n "printf '\\\\x\|[^a-z]timeout " <gate>`.

## Task playbooks (skills)

**Skills are planning inputs, not just implementation aids.** At task triage — including
during plan-mode exploration, *before* writing the plan — match the task against this table
and load the matching skill rather than re-deriving the workflow. (A `UserPromptSubmit` hook,
`.claude/hooks/skill-triage.py`, nudges this on PLAN.md/Phase prompts.)

| Skill | When |
|-------|------|
| **add-language-feature** | Thread a new construct through the whole pipeline. **Also the right skill for most cross-cutting work that *looks* like typechecking** — see below. |
| **add-primitive** | Add/modify a stdlib `extern` primitive (native, in `compiler/eval/eval.mdk`). |
| **extend-stdlib** | Implement/extend a *pure-Medaka* stdlib function, impl, doctest, or prop. Not for externs. Normally user-reserved; load when asked. |
| **debug-pipeline** | Diagnose a parse/typecheck/eval failure. **Reach here first for a dispatch bug that reproduces through the loader but works single-file.** |
| **harden-typechecker** | Typechecker-*internal* work: add a `type_error`, tighten constraint/coherence/unification logic. |
| **perf-hunt** | A stage is slow, or `diff_compiler_perf_scaling.sh` is red. Find the O(n²). |
| **benchmark-emitter** | ANY change to `compiler/backend/*` you intend to measure, or a fixpoint failure on a change that looks correct. |
| **add-lsp-capability** | Add/extend an LSP feature. |
| **pr-review** | Review an agent-authored PR diff for craft. Read-only; run AFTER CI is green. |
| **bug-hunt** | Adversarially hunt lurking S0/S1 bugs: derive hot veins from the tracker, fan out isolated-worktree subagents by subsystem, verify first-hand, file deduped issues with self-draining pins. Best run right after a batch of S0/S1s is closed. |

⚠️ **`harden-typechecker` is narrower than it looks.** Adding a `type_error` does NOT by
itself make a task typechecker-internal. If the fix threads through resolve/eval/desugar/AST
*as well*, it is **add-language-feature** — that was true of Phase 69 (dispatch), Phase 63
(`deriving`, desugar-rooted), Phase 72 (field-name reuse: added a type_error, but the bulk was
a multimap threaded through resolve *and* typecheck), Phase 73 (bidirectional checking), and
Phases 83/84 (dict-threading through AST + typecheck + dict_pass + eval). **Check where the fix
actually lands before loading it.** Either way, a typechecker bug fix first answers the
standing questions in `.claude/workstreams/TYPECHECK.md` — keyed to the `ws:typecheck` label, not
to whichever skill you loaded, so the routing hazard above can't cause it to be missed.

## Doc index

**`docs/README.md` is THE doc index** — generated from every doc's own `**Status:**` banner
(`make docs-index`), so it cannot drift. Go there for the full catalog. The rows below are
only the ones an agent reaches for constantly.

| Doc | What's in it |
|-----|--------------|
| `README.md` | Full build/test/CLI usage, editor setup, layout |
| `docs/spec/SYNTAX.md` | Cheat-sheet of every construct the **current binary** accepts. Reach here first for "does X parse" — faster than reading `parser.mdk`. Ground truth over `language-design.md` |
| `docs/spec/LAYOUT-SEMANTICS.md` | Offside-rule layout spec — formal ground truth for layout work |
| `docs/spec/language-design.md` | Design & semantics (intent/rationale — may describe unimplemented features) |
| `PLAN.md` / `archive/PLAN-ARCHIVE.md` | Open roadmap / completed Phases 1–97 + notes |
| `compiler/BOOTSTRAP.md` | Self-compile log: B1–B7 (each stage native==interpreter) + C1–C3 (fixpoint) |
| `compiler/EMITTER-GAPS.md` | Native emitter gap census (E-series), closed + residual |
| `compiler/ERROR-QUALITY.md` | Error-message rubric. Read before writing/changing a diagnostic |
| `compiler/DIAGNOSTIC-CODES-DESIGN.md` | Stable diagnostic code taxonomy + the `Diag` JSON contract. Add new codes here |
| `compiler/PERF-RESULTS.md` / `PERF-SCOPE.md` | Measured perf log (+ every dead end) / ranked hot paths. Harness: `test/bench.sh` |
| `compiler/STAGE2-DESIGN.md` / `RUNTIME-DESIGN.md` | Native backend design: Core IR seam, value rep, GC, per-extern disposition |
| `docs/stdlib/STDLIB.md` / `stdlib/README.md` | Stdlib module plan / conventions for adding externs |
