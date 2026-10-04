## [P-DOCTEST-RESIDUAL] `compiler/tools/doctest.mdk` module-identity residual (#1223)

⚠️ **NOT two drivers.** This row said "prelude-only → single-file" until 2026-07-30, which
reads as a second elaboration path and is false: the prelude-only arm routes a no-import
file through the degenerate 1-module list `[(rootId, decls)]`, and every arm of
`runChosen` reaches `elaborateModules` — the doctest arm through the 1-module wrapper
`elaborateOne`, the prop and `test "…"` arms through `prepareSingle`.

What the no-import arm actually carries is a residual **flatten** — the prelude is
concatenated into the user's decl list rather than being a node — which is why it must
first compute `livePrelude = dropShadowedExp userNames coreDecls` and needs a
`programIsCore` guard so `medaka test stdlib/core.mdk` doesn't double-declare everything.
Both are workarounds for the flatten; under DICT §7.1 U1 (prelude is a node) a genuine
2-node graph needs neither, since SHADOW S1's per-module scoping already answers them.

⚠️ **A third residual existed here, not of the flatten, and it is now PARTIALLY fixed**
(ARCH E-5, #1521, owns but does not close #1223): the prelude-only doctest path used to
stamp its one node under a synthetic id, `"__user__"`, hardcoded at four sites, while the
loader stamped the same file under its loader-derived id — one declaration, two identities
in a single `medaka test <dir>` process (#1223, S2). Every prelude-only arm — `runChosen`'s
`DtSingle` clause for doctests, `prepareSingle` for the prop and `test "…"` phases — now
computes `canonicalPathId` (`driver/loader.mdk`) through the shared `singleRootId`: the SAME
last-containing-root, round-trip-guarded convention a sibling's import canonicalizes
through, over roots derived from the target's own directory.

⚠️ A first pass at this fix used plain `moduleIdOfPath` (first-root) instead, which agrees
with the loader only when a project has ONE root and still diverged the moment a target sat
below its own `medaka.toml` — caught in adversarial review before merge (#1526); see
the now-retired nested-origin fixture for the discriminating witness.

Orthogonal to the flatten: the prelude-only arm was already on the Module path; only the
node's NAME was wrong. **This closes only the NO-IMPORT case.** `driver/loader.mdk:662-669`
documents a separate, still-open residual for IMPORT-BEARING files (`prepareMulti`'s
`loadProgramFilesLocatedE`, untouched by this fix):
an entry's own id is first-root while the same file reached as another target's dependency
is last-root — MEASURED still reproducing in the residual-origin fixture. The dedicated
origin-agreement control has since been retired; #1223 stays OPEN.

Derive rather than trust this row: `grep -n 'SAME multi-module path' compiler/tools/test_cmd.mdk`

## [P-IMPORT-BINDS] Bare `import` detail + example

A bare `import map` binds NO names — not values, not types, not `map.get` (qualified access
exists *only* via `as`). It is not a no-op: **any** import of a module brings that module's
`impl`s into scope for dispatch, which is the whole job of the bare form. Example:
`stdlib/json.mdk`'s bare `import array` — without it, `map (+ 1) [|1,2,3|]` is *"No impl of
Mappable for Array"*.

Also for the record on import forms: an alias-qualified name (`import map as M`) reaches
`M.get` AND `M.Map` in type position (#2412). The two take different routes for a reason
worth knowing: the value form is lowered to a flat `EVar "M.get"` by desugar and stays
dotted through inference, while the type form is SHORTENED back to `Map` by resolve in the
same step that attributes it to `map`, because a type's identity is the pair (name,
declaring module) and a head left spelled `M.Map` would be a different type from the one
`import map.{Map}` denotes. Constructors are reachable through neither: `M.Tip` is not a
spelling the grammar has, so `import map.{Map(..)}` is still the only way to a ctor.

## Retired origin-agreement entry — F1/F2, two S0s through 12/12 green CI (#1110)

The `Ty` constructor `TyCon` carries a `TyConOrigin` stamped by resolve, in its
`tyConOrigin` field, and so do the four type-declaration nodes — `DData`, `DNewtype`,
`DTypeAlias` and `DInterface`, through `dataOrigin`, `newtypeOrigin`, `tyAliasOrigin`
and `ifaceOrigin`. Nothing in the compiler read any of them before #1110, which made
every identity fact the compiler minted unobservable — and two defects shipped through
12/12 green CI on exactly that:

- **F1** — the flat driver stamped `mod:__user__` for a file's own declarations while the
  emitter's graph path stamped the real loader id, inside one process.
- **F2** — on prelude-flattened paths the prelude's own types (`Option`, `Result`,
  `Ordering`) were attributed to the user's module.

Neither is catchable by a probe that calls the stampers directly — `stampFlatTyOrigins` was
correct for its own arguments in both cases; the bug was a caller (a hardcoded literal at one
of three call sites for F1, an empty prelude list for F2). A repro: `data A = A { p, k }`
SIGSEGVs on `Module`, prints `5` on `Flat`, with byte-identical IR between the two — the
disagreement is invisible unless something reads the origin stamps back and compares arms.
The retired origin-agreement probe was that something: it drove the three real elaboration entry
points (flat/single/graph) rather than hand-picking arguments, and reports an agreement
table rather than the origins themselves, because a golden of the origins would churn on
every module added and would not have caught F1 (each arm's claim was individually
plausible; only the disagreement was wrong).

## [P-NO-MARK-PASS] — full Mark-row text

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

| Mark | `compiler/frontend/marker.mdk` | ⚠️ **[P-NO-MARK-PASS]** NOT on `check`/`run`/`build`. `markWithPrelude` — the `EVar`→`EMethodRef` pass — is reached only from `tools/snapshot.mdk` and two `entries/` probes, so **no production verb ever sees an `EMethodRef`**. Every Module-arm driver (`check`, `run`, `build`, the LSP) marks inside typecheck itself, per binding group on the inference schedule (`checkBodyImpl` → `processSCC` → `markGroupClauses`, minting `EMethodAt`/`EDictAt`; ARCH §E), so there is no whole-tree mark pass and no promotion fixpoint, and no driver pre-marks a whole program before inference. The FILE is still live, for `preludeStandaloneShadows` (`driver/diagnostics.mdk`), `declRefs` (`ir/dce.mdk`) and `localBoundNames` (typecheck) |

## [P-TEST-SIBLING] — full rule text

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

⚠️ **[P-TEST-SIBLING] A compiler-internal test lives in a `*_test.mdk` sibling beside its
subject** — `compiler/types/registry_test.mdk` tests `compiler/types/registry.mdk`. The
suffix is load-bearing, not cosmetic: it is what three computations subtract on. The two
`find compiler -name '*.mdk'` fingerprints (`src_fingerprint_compiler`/`src_fingerprint_full`
in `test/build_native_medaka.sh`, mirrored byte-for-byte by `liveSourceFingerprint` in
`compiler/driver/medaka_cli.mdk`) exclude it, so editing a test never rebuilds the emitter and
never makes every `./medaka` run warn stale ([B-STALENESS], [B-STDERR]); the `compiler` family
in `test/diff_compiler_snapshot_frontend_test.mdk` excludes it, so a test owes no blessed snapshot
and `--bless` on one is refused. `test/preflight.sh` needs no exclusion — its `compiler/<dir>/*`
arms are path globs, so a sibling derives its SUBJECT's gate set. Run one with
`medaka test <file>`; a module outside every entry's import closure is otherwise unwalked
([W-MODULE-BLIND]), so name it in Makefile's `test:` target.

⚠️ Only `foo_test.mdk` loads — `foo.test.mdk` is not a resolvable module name.

## `stdlib/` module map and import forms — full text

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

`stdlib/` modules: `runtime.mdk` (extern catalog), `core.mdk` (**only auto-prelude**),
`list`/`string`/`array`, `map`/`set` (ordered trees), `hash_map`/`hash_set` (mutable hash),
`vector` (growable array), `u8`/`u16`/`u32` (the fixed-width unsigned types' operations; the
types themselves are builtin — `docs/design/INTEGER-TYPES-DESIGN.md`), `json`, `crypto/` (`crypto.sha256`, `crypto.hmac` — the one nested
namespace; a stdlib subdirectory's modules import dotted), `byteparser`/`bytebuilder` (parser-combinator libraries
for hand-rolled binary/text parsing and building — `parsec` is a separate, more general
parser-combinator project under its own manifest, not part of `stdlib/`), `io.mdk` (ergonomic
layer over `runtime.mdk` IO), `args` (one CLI argument parser — a verb's flag vocabulary is a
VALUE that the `(known: …)` roster and the parser are unified renderings of;
`docs/design/ARGS-DESIGN.md`). **For "does the stdlib have X" ask the generated reference,
[`docs/stdlib/index.md`](../../docs/stdlib/index.md)** (`./medaka doc --out docs/stdlib stdlib/*.mdk stdlib/*/*.mdk`)
— name-by-name, regenerated from source, never hand-maintained. **Writing or
editing a stdlib doc comment? The register is `stdlib/README.md` § "Writing
documentation"** — what renders (marked blocks only), what a doc comment
contains, and what stays out (history, issue numbers, implementation notes).

Import forms: `import map.{Map, get}` (selective), `import map.*` (all exported), `import
map as M` → `M.get`, `M.Map` in *type* position (#2412 — the alias-qualified type is the
SAME type the by-name import gives), `M.Tip` for a constructor (expression and pattern
position) and an interface the same way (#3294) — an alias qualifies the module's whole
export namespace. A constructor is reachable, bare or aliased, only when its module writes
`public export data` ([P-PUBLIC-EXPORT]). `import m.{f} as A` / `import m.* as A` rejected,
diagnostic names the fix.

## Stage and support-file tables — full text

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

| Stage | File | Role |
|-------|------|------|
| Lex | `compiler/frontend/lexer.mdk` | Indentation-sensitive; INDENT/DEDENT/NEWLINE |
| Parse | `compiler/frontend/parser.mdk` | Recursive-descent grammar |
| AST | `compiler/frontend/ast.mdk` | Node types + source locations |
| Desugar | `compiler/frontend/desugar.mdk` | `deriving`, record puns, `EGuards`/`ESection`/`EStringInterp`/`EDo`, default-method specialization |
| Resolve | `compiler/frontend/resolve.mdk` | Name binding, single/multi-module |
| Mark | `compiler/frontend/marker.mdk` | ⚠️ **[P-NO-MARK-PASS]** NOT on `check`/`run`/`build`. `markWithPrelude` — the `EVar`→`EMethodRef` pass — is reached only from `tools/snapshot.mdk` and two `entries/` probes, so **no production verb ever sees an `EMethodRef`**. Every Module-arm driver (`check`, `run`, `build`, the LSP) marks inside typecheck itself, per binding group on the inference schedule (`checkBodyImpl` → `processSCC` → `markGroupClauses`, minting `EMethodAt`/`EDictAt`; ARCH §E), so there is no whole-tree mark pass and no promotion fixpoint, and no driver pre-marks a whole program before inference. The FILE is still live, for `preludeStandaloneShadows` (`driver/diagnostics.mdk`), `declRefs` (`ir/dce.mdk`) and `localBoundNames` (typecheck) |
| Typecheck | `compiler/types/typecheck.mdk` | Hindley-Milner + interfaces + effects; invokes Exhaust per `EMatch` |
| Exhaust | `compiler/frontend/exhaust.mdk` | Maranget pattern-matrix; called *from* typecheck |
| Eval | `compiler/eval/eval.mdk` | Tree-walking interpreter; dict-passing dispatch |

Support files:

| File | Role |
|------|------|
| `compiler/driver/loader.mdk` | Multi-file dep walk, topo sort, cycle detection; `medaka.toml` root walk-up |
| `compiler/driver/diagnostics.mdk` | Accumulating error pipeline — no exit-on-error |
| `compiler/driver/build_cmd.mdk` | `medaka build` — Core IR → LLVM emit → clang |
| `compiler/driver/medaka_cli.mdk` | CLI: `check`/`fmt`/`new`/`build`/`run`/`test`/`doc`/`lint`/`manifest`/`repl`/`lsp`. Argument-handling conventions (unknown-flag rejection, exit codes, stream discipline, `--json`) are ratified in `docs/ops/CLI-CONFORMANCE.md` — the single normative source, re-derivable with `make cli-conformance-census` |
| `compiler/ir/core_ir.mdk` + siblings | Core IR types; lowering `core_ir_lower.mdk`, S-expr `core_ir_sexp.mdk`, DCE `dce.mdk`, interpreter `core_ir_eval.mdk` |
| `compiler/backend/llvm_emit.mdk` | LLVM text IR emitter |
| `compiler/backend/wasm_emit.mdk` | WasmGC text IR emitter (2nd backend) |
| `compiler/backend/private_mangle.mdk` | Universal constructor mangling |
| `compiler/backend/trmc_analysis.mdk` | Tail-recursion-modulo-cons analysis |
| `compiler/types/annotate.mdk` | Type annotation helpers |
| `compiler/types/repr.mdk` | The type representation (`Mono`/`Tyvar`/`EffRow`/`Scheme`/`IfaceRef`), `normalize`, the row-atom algebra and every renderer (`ppMono`/`ppScheme`/`ppTy`) — reads no typechecker state; the first extraction under #2586 |
| `compiler/tools/printer.mdk` / `fmt.mdk` | AST→source round-trip / comment-preserving formatter |
| `compiler/tools/lsp.mdk` | LSP/stdio: diagnostics/fmt/symbols/hover/definition/highlight/completion/inlay |
| `compiler/tools/mcp.mdk` | `medaka mcp` — MCP stdio, 8 tools (check/type_at/symbols/definition/references/fmt/lint/test). **Prefer over grep/Bash.** `docs/ops/MCP.md` |
| `compiler/tools/lint.mdk` | `medaka lint` — AST linter, RAW pre-desugar AST; `Rule`/`CrossFileRule`; `--fix`/`--deny`/`--disable`/`--only` |
| `compiler/tools/doctest.mdk` | Doctest extraction. **[P-DOCTEST-RESIDUAL]** #1223 OPEN: no-import FIXED (`singleRootId` → `canonicalPathId`, last-root), import-bearing NOT — `prepareMulti` loads through `loadProgramFilesLocatedE`, which stamps the entry first-root. Unpinned; listed in `test/MUST-FAIL-NOT-PINNABLE.txt`. Derive: `grep -n 'FIRST containing root' compiler/driver/loader.mdk` |
| `compiler/tools/check.mdk` / `check_policy.mdk` | `medaka check` entry + policy checker |
| `compiler/tools/test_cmd.mdk` / `prop_runner.mdk` | `medaka test` — doctests + property tests |
| `compiler/tools/doc.mdk` / `new_cmd.mdk` / `repl.mdk` | `medaka doc` / `new` / `repl` |
| `compiler/support/util.mdk` + siblings | Compiler-private helpers, thin `stdlib/` wrappers. Weigh imports per module — [T-STDLIB-IMPORT] |
