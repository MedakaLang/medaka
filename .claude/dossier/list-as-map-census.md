# List-as-map/set census (`compiler/`)

Feeds #2733 (this census), #2724 (the fourteenth quadratic), and #2161 (the lint
detector). Fixes nothing — this is an inventory, not a patch. Every table below is
mechanically derived; regenerate with the commands in "Regeneration" and diff against
this file rather than hand-editing a row.

Scope: `compiler/**/*.mdk`, excluding `*_test.mdk`, comment lines excluded via
`grep -v '^\S*:\s*--'`.

## Cardinality classes

- **bounded** — arity-sized, roughly ≤10 elements: kinds, args, a clause's params, a
  record's fields, the compiler's own hardcoded Haskell-alias tables.
- **per-decl** — grows with one declaration's body (a type substitution, a local scope,
  a scheme's type variables).
- **per-module** — grows with a module: its decls, its impls, its resolve environment.
- **graph** — grows with the whole program or the run: the module list, a run-wide
  channel (`PerRun`/`DriverState`/`GraphRun` fields in `compiler/types/typecheck.mdk`),
  a "universe" accumulator.

## Drain order — graph-class collections first

Every row below is a `List`-typed run-wide channel scanned with `lookupAssoc`,
`lookupTab`, or `contains`/`elem`/`dedup`. Call-site counts are call sites found across
the `lookupAssoc` / `lookupTab` / `contains`-family / `Ref (List ` sweeps (below), not
independently re-verified beyond the naming convention (`perRun.value.*Ref.value`,
`driverState.value.*Ref.value`, `PerRun`/`DriverState`/`GraphRun` record fields). All
scans found are **first-wins** (linear cons-list scan; no last-wins run-wide table was
found) — an assoc-list to `OrdMap`/`HashMap` conversion on any of these preserves
semantics with no first/last-wins hazard, unlike the `typecheck.mdk`-internal
`importedCtorTypeDeclsFirstWins`/`…LastWins` pair noted under Keying below.

| Collection | Record | Call sites (lookupAssoc/lookupTab/contains) | Suggested container |
|---|---|---|---|
| `perRun.dataParamKindsRef` | PerRun | 8 (lookupTab) | `OrdMap` (String-keyed via `TabKey`) |
| `perRun.shadowStandaloneSchemesRef` | PerRun | 9 (lookupAssoc) + 1 field decl | `OrdMap` |
| `perRun.definerShadowNamesRef` | PerRun | 8 (contains) + 1 field decl | `HashSet` |
| `perRun.definerShadowSigsRef` | PerRun | 4 (lookupAssoc) + 1 field decl | `OrdMap` |
| `perRun.aliasTableRef` | PerRun | 5 (lookupTab) + 1 field decl | `OrdMap` |
| `driverState.standaloneValuesRef` | DriverState | 4 (contains) + 1 field decl | `HashSet` |
| `driverState.mangledShadowMapRef` | DriverState | 4 (lookupAssoc) + 1 field decl | `OrdMap` |
| `perRun.currentImportDefinersRef` | PerRun | 2 (lookupAssoc) + 1 field decl | `OrdMap` |
| `perRun.dataParamPolarityRef` | PerRun | 2 (lookupTab) + 1 field decl | `OrdMap` |
| `perRun.dataParamRowAtomsRef` | PerRun | 1 (lookupTab) + 1 field decl | `OrdMap` |
| `perRun.rigidEffvarsRef` | PerRun | 1 (contains) + 1 field decl | `HashSet` |
| `perRun.promotedRef` | PerRun | 1 (dedup) + 1 field decl | n/a — dedup, not lookup; `HashSet`-backed dedup if hot |
| `perRun.funConstraintDeclaredRef` | PerRun | 1 (lookupAssoc) + 1 field decl | `OrdMap` |
| `perRun.currentImportOriginsRef` | PerRun | 1 (lookupAssoc) + 1 field decl | `OrdMap` |
| `driverState.userIfaceNamesRef` | DriverState | 1 (contains) + 1 field decl | `HashSet` |
| `driverState.stdlibOwnedModsRef` | DriverState | 1 (contains) + 1 field decl | `HashSet` |
| `driverState.promotionHarvestRef` | DriverState | 1 (dedup) + 1 field decl | n/a — dedup |
| `driverState.abstractRecordTypesRef` | DriverState | 1 (contains) + 1 field decl | `HashSet` |
| module list (`modules`/`allModules`/`modPaths`) | (loader/typecheck/resolve param) | 4 (lookupAssoc-family) | `OrdMap` keyed by module id |
| **= #2724**: `graphRun.goals` via `moduleWindow`'s `listLen` | GraphRun | see below, not part of the lookupAssoc/contains/Ref(List sweeps — `listLen` shape | already fixed-shape (`takeFirst`); tracked separately by #2724 |
| **= #2724**: `allModules` in `dictPassModulesScoped` → `transitiveImporterDecls` | (typecheck.mdk param) | see below | `OrdMap`/precomputed importer index |

Remaining `DriverState`/`GraphRun`/`PerRun` fields that are `Ref (List …)`-typed but not
found scanned by `lookupAssoc`/`lookupTab`/`contains` in this sweep (47 total field
declarations in the three records — see the `Ref (List` table below, rows tagged
`graph`) are lower priority: a field with no scan call site found here costs allocation
on push but not a linear rescan.

### The already-fixed fourteenth quadratic (#2724), located

- `moduleWindow : Ref (List a) -> Int -> List a` (`compiler/types/typecheck.mdk:9304`)
  — `let now = cell.value in takeFirst (listLen now - mark) now`. Called on
  `graphRun.value.goals` (line 2984) and `graphRun.value.numlitRefs` (lines 19834, 30440,
  42378) — the run-wide goals/numlit channels.
- `transitiveImporterDecls : String -> List (String, List Decl) -> List Decl`
  (`compiler/types/typecheck.mdk:41791`), called from `dictPassModulesScoped`
  (`compiler/types/typecheck.mdk:41441`) as `transitiveImporterDecls mid allModules` per
  module in the program — the per-module walk that is quadratic in module count.

## Per-file × class summary

### `lookupAssoc` (184 sites)

| File | graph | per-module | bounded | per-decl (default) | n/a (import mention) |
|---|---|---|---|---|---|
| compiler/types/typecheck.mdk | 23 | 0 | 0 | 57 | 2 |
| compiler/frontend/resolve.mdk | 1 | 10 | 6 | 0 | 1 |
| compiler/eval/eval.mdk | 0 | 0 | 0 | 17 | 1 |
| compiler/backend/llvm_emit.mdk | 0 | 0 | 0 | 13 | 1 |
| compiler/tools/prop_runner.mdk | 0 | 0 | 0 | 9 | 0 |
| compiler/tools/check_policy.mdk | 0 | 0 | 0 | 6 | 0 |
| compiler/driver/diagnostics.mdk | 0 | 0 | 0 | 5 | 1 |
| compiler/types/repr.mdk | 0 | 0 | 0 | 5 | 0 |
| compiler/support/util.mdk | 0 | 0 | 0 | 4 | 0 |
| compiler/ir/core_ir_lower.mdk | 0 | 0 | 0 | 3 | 1 |
| compiler/driver/loader.mdk | 0 | 0 | 0 | 3 | 1 |
| compiler/backend/wasm_emit.mdk | 0 | 0 | 0 | 3 | 1 |
| compiler/tools/codemod.mdk | 0 | 0 | 0 | 2 | 1 |
| compiler/tools/lint.mdk | 0 | 0 | 0 | 1 | 1 |
| compiler/frontend/parse_cache.mdk | 0 | 0 | 0 | 1 | 1 |
| compiler/frontend/desugar_cache.mdk | 0 | 0 | 0 | 1 | 1 |
| compiler/backend/emit_support.mdk | 0 | 0 | 0 | 0 | 1 |
| **Total** | **24** | **10** | **6** | **130** | **14** |

`24 + 10 + 6 + 130 + 14 = 184` — matches the acceptance-check grep count (below).

### `Ref (List ` (203 sites)

| File | graph | per-decl (default) |
|---|---|---|
| compiler/types/typecheck.mdk | 47 | 49 |
| compiler/backend/llvm_emit.mdk | 0 | 24 |
| compiler/backend/wasm_emit.mdk | 0 | 11 |
| compiler/driver/diagnostics.mdk | 0 | 10 |
| compiler/tools/refindex.mdk | 0 | 11 |
| compiler/types/repr.mdk | 0 | 11 |
| compiler/eval/eval.mdk | 0 | 9 |
| compiler/tools/repl.mdk | 0 | 6 |
| compiler/driver/loader.mdk | 0 | 4 |
| compiler/entries/fuzz_gen_main.mdk | 0 | 4 |
| compiler/entries/origin_agreement_main.mdk | 0 | 3 |
| compiler/frontend/parser.mdk | 0 | 2 |
| compiler/support/scc.mdk | 0 | 2 |
| compiler/tools/lsp.mdk | 0 | 2 |
| compiler/frontend/ast.mdk | 0 | 1 |
| compiler/frontend/desugar_cache.mdk | 0 | 1 |
| compiler/frontend/parse_cache.mdk | 0 | 1 |
| compiler/frontend/resolve.mdk | 0 | 1 |
| compiler/ir/core_ir_lower.mdk | 0 | 1 |
| compiler/support/timer.mdk | 0 | 1 |
| compiler/tools/printer.mdk | 0 | 1 |
| compiler/entries/playground_main.mdk | 0 | 1 |
| **Total** | **47** | **156** |

`47 + 156 = 203` — matches the acceptance-check grep count (below). All 47 `graph` rows
are `DriverState`/`GraphRun`/`PerRun` field *declarations* (type occurrences), not call
sites — see the Drain order table above for which of those fields also has a live
`lookupAssoc`/`lookupTab`/`contains` scan against it.

### `contains`/`elem`/`containsI`/`dedup`/`dedupBy` (476 sites, word-boundary match)

Not part of §6's numeric acceptance checks. Per-file counts only; the `graph` rows
(20, all in `compiler/types/typecheck.mdk`) are the ones already folded into the Drain
order table above. Everything else defaults to `per-decl` — this shape's bulk (441
sites in `compiler/backend/{llvm_emit,wasm_emit}.mdk`, `compiler/frontend/resolve.mdk`,
`compiler/eval/eval.mdk`, etc.) was **not** individually hand-verified past the
name-pattern heuristic; see Methodology.

| File | graph | per-module | per-decl (default) | n/a |
|---|---|---|---|---|
| compiler/types/typecheck.mdk | 20 | 0 | 141 | 0 |
| compiler/backend/wasm_emit.mdk | 0 | 0 | 76 | 0 |
| compiler/backend/llvm_emit.mdk | 0 | 0 | 55 | 0 |
| compiler/frontend/resolve.mdk | 0 | 2 | 33 | 0 |
| compiler/tools/lint.mdk | 0 | 0 | 21 | 0 |
| compiler/ir/core_ir_lower.mdk | 0 | 0 | 12 | 0 |
| compiler/eval/eval.mdk | 0 | 0 | 12 | 0 |
| compiler/backend/trmc_analysis.mdk | 0 | 0 | 12 | 0 |
| compiler/backend/private_mangle.mdk | 0 | 0 | 12 | 0 |
| compiler/tools/gate_cmd.mdk | 0 | 0 | 11 | 0 |
| compiler/driver/medaka_cli.mdk | 0 | 0 | 10 | 0 |
| compiler/support/util.mdk | 0 | 0 | 8 | 0 |
| compiler/backend/emit_support.mdk | 0 | 0 | 6 | 0 |
| compiler/driver/loader.mdk | 0 | 0 | 6 | 0 |
| compiler/tools/doc.mdk | 0 | 0 | 5 | 1 |
| compiler/tools/check_policy.mdk | 0 | 0 | 4 | 0 |
| compiler/frontend/desugar.mdk | 0 | 0 | 4 | 0 |
| compiler/frontend/marker.mdk | 0 | 0 | 3 | 1 |
| compiler/ir/core_ir_eval.mdk | 0 | 0 | 3 | 1 |
| compiler/driver/diagnostics.mdk | 0 | 0 | 3 | 0 |
| compiler/tools/codemod.mdk | 0 | 0 | 2 | 0 |
| compiler/frontend/exhaust.mdk | 0 | 0 | 2 | 0 |
| compiler/tools/lint_baseline.mdk | 0 | 0 | 2 | 0 |
| compiler/tools/prop_runner.mdk | 0 | 0 | 2 | 0 |
| compiler/entries/llvm_emit_typed_main.mdk | 0 | 0 | 1 | 1 |
| compiler/tools/mcp.mdk | 0 | 0 | 1 | 0 |
| compiler/tools/repl.mdk | 0 | 0 | 1 | 1 |
| compiler/tools/snapshot.mdk | 0 | 0 | 1 | 0 |
| **Total** | **20** | **2** | **449** | **5** |

### `lookupTab` (`compiler/frontend/ast.mdk`'s hand-rolled assoc, 18 call sites)

17 of 18 are graph-class (`PerRun`'s alias/kind/polarity/row-atom tables); one
(`compiler/frontend/exhaust.mdk:263`) is per-module (`oracle.typeCtors`, one module's
exhaustiveness oracle).

## Keying

Every scan found across all four shapes above is **first-wins**: `lookupAssoc`,
`lookupTab`, and the hand-rolled `List` scans all fold from the head, and every
run-wide channel is prepended-to (`x.value := v :: x.value`, per the `PerRun` comment
at `compiler/types/typecheck.mdk:9316` on why fields stay `Ref`s), so "first match in
the list" means "most recently pushed." Converting one of these to `OrdMap.insert`
(last-wins on `insert`) would invert the answer — the replacement needs an
insert-if-absent (`omInsertWith` keeping the existing value, or push in reverse) to
preserve semantics.

The one place BOTH keying directions coexist in `typecheck.mdk` is unrelated to any
row above: `importedCtorTypeDeclsFirstWins`/`…LastWins`
(`compiler/types/typecheck.mdk:39157`/`39164`), each consumed by a different concat
order (`oracleMap` prepends so first wins; `dataEnv`'s overlay appends so last wins —
see the comment block at `compiler/types/typecheck.mdk:40283`). Neither function itself
appeared in the `lookupAssoc`/`contains`/`Ref (List` sweeps as a lookup call; they are
list-*building* helpers whose OUTPUT then gets `lookupAssoc`'d or `omFromPairs`'d
elsewhere. Flagged here because a future conversion of *their* output collection must
preserve whichever of the two orderings its own call site relies on — check the call
site, not this note, before changing either.

## Methodology and known gaps

- Every row's `class`/`collection`/`container` was assigned by a small shell classifier
  (kept out of the tree per the packet — not checked in) matching on: `perRun.value.*
  Ref.value` / `driverState.value.*Ref.value` / `graphRun.value.*` (→ graph), line
  ranges inside the `DriverState`/`GraphRun`/`PerRun` record bodies in
  `compiler/types/typecheck.mdk` (→ graph, for the `Ref (List` sweep), `env.*Ambiguous`
  / `exp.exp*Ctors` (→ per-module), the three `haskell*Aliases` tables (→ bounded), and
  otherwise **per-decl by default**. The `graph` and `per-module` rows above were
  additionally read in source to confirm the collection named; the `per-decl (default)`
  rows (730 of the ~865 total across all shapes) were **not** individually read — they
  are the majority-case default for a compiler whose `lookupAssoc`/`contains` calls are
  overwhelmingly over one declaration's substitution/scope/argument list, not
  individually verified line-by-line. Treat any specific `per-decl (default)` row as a
  hypothesis, not a fact, before relying on it for a per-site fix.
- `n/a` rows are import/export list mentions of the function name (e.g. `lookupAssoc,`
  inside an `import … .{...}` block) — not scan sites, included only because the
  acceptance check counts every grep hit as a row.
- **`listLen` used as a size/compare on an accumulator** (one of §5's named shapes) was
  not enumerated as individual rows: `grep -rn listLen compiler --include='*.mdk' | grep
  -v _test.mdk | grep -v '^\S*:\s*--' | wc -l` returns 377, and a full per-site read was
  out of scope for this slice given the two gated shapes already cover ~52,000 words of
  table. The one `listLen` site that matters most (`moduleWindow`, #2724) is called out
  above; a follow-up census pass on the remaining 373 is future work, not claimed done
  here.
- `Ref (List ` counts a *type occurrence* (a field, a parameter, or a local signature),
  not necessarily a scan — most rows are declarations. Cross-reference against the
  `lookupAssoc`/`lookupTab`/`contains` tables to see which declared channels are
  actually scanned (the Drain order table already does this for the graph-class ones).
- `ordmap`'s own compare cost: `compiler/support/ordmap.mdk` (`OrdMap`, 21 importing
  files) dispatches its comparator through `mdk_disp_compare_0_2` — 1.8% of `check`'s
  instructions (measured, cited in the packet's §4) — filed here as a "container cost"
  row, not a `List`-as-map site: any wholesale conversion above should expect this
  fixed dispatch overhead per lookup, not zero cost.

## Regeneration

```sh
grep -rn 'lookupAssoc' compiler --include='*.mdk' | grep -v '^\S*:\s*--' | grep -v _test.mdk | wc -l   # 184
grep -rn 'Ref (List ' compiler --include='*.mdk' | grep -v '^\S*:\s*--' | grep -v _test.mdk | wc -l    # 203
grep -rn -E '\b(contains|elem|containsI|dedup|dedupBy)\b' compiler --include='*.mdk' \
  | grep -v '^\S*:\s*--' | grep -v _test.mdk | wc -l                                                    # 476
grep -rn 'lookupTab ' compiler --include='*.mdk' | grep -v '^\S*:\s*--' | grep -v _test.mdk             # 18 call sites (excl. the definition itself)
grep -rn 'perRun\.value\.[A-Za-z]*Ref\.value\|driverState\.value\.[A-Za-z]*Ref\.value' compiler \
  --include='*.mdk' | grep -v _test.mdk | grep -E 'lookupAssoc|contains|elem|containsI|dedup|Ref \(List'
grep -n 'listLen' compiler -r --include='*.mdk' | grep -v _test.mdk | grep -v '^\S*:\s*--' | wc -l      # 377, not enumerated (see Methodology)
```

## Full site tables


### `lookupAssoc` sites (184)

| file:line | shape | collection | class | container | keying | note |
|---|---|---|---|---|---|---|
| compiler/tools/check_policy.mdk:65 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/check_policy.mdk:359 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/check_policy.mdk:382 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/check_policy.mdk:553 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/check_policy.mdk:694 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/check_policy.mdk:753 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/codemod.mdk:53 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/tools/codemod.mdk:265 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/codemod.mdk:307 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:84 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/tools/lint.mdk:717 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:75 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/ir/core_ir_lower.mdk:745 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:920 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:1147 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:80 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/driver/diagnostics.mdk:578 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:593 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1034 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1308 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:2058 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:55 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/eval/eval.mdk:532 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:603 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:1042 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:1068 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:1749 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:2135 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:2146 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:2170 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:2184 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:2191 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:2202 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:2907 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:4080 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:4363 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:4398 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:4442 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:4455 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/support/util.mdk:78 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/support/util.mdk:79 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/support/util.mdk:80 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/support/util.mdk:82 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/prop_runner.mdk:29 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/prop_runner.mdk:95 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/prop_runner.mdk:127 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/prop_runner.mdk:221 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/prop_runner.mdk:333 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/prop_runner.mdk:359 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/prop_runner.mdk:398 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/prop_runner.mdk:568 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/prop_runner.mdk:735 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:77 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/frontend/resolve.mdk:804 | lookupAssoc | resolve env table | per-module | persistent value | n/a | one module's resolve environment |
| compiler/frontend/resolve.mdk:809 | lookupAssoc | resolve env table | per-module | persistent value | n/a | one module's resolve environment |
| compiler/frontend/resolve.mdk:816 | lookupAssoc | resolve env table | per-module | persistent value | n/a | one module's resolve environment |
| compiler/frontend/resolve.mdk:821 | lookupAssoc | resolve env table | per-module | persistent value | n/a | one module's resolve environment |
| compiler/frontend/resolve.mdk:829 | lookupAssoc | resolve env table | per-module | persistent value | n/a | one module's resolve environment |
| compiler/frontend/resolve.mdk:834 | lookupAssoc | resolve env table | per-module | persistent value | n/a | one module's resolve environment |
| compiler/frontend/resolve.mdk:855 | lookupAssoc | resolve env table | per-module | persistent value | n/a | one module's resolve environment |
| compiler/frontend/resolve.mdk:860 | lookupAssoc | resolve env table | per-module | persistent value | n/a | one module's resolve environment |
| compiler/frontend/resolve.mdk:926 | lookupAssoc | haskell*Aliases | bounded | persistent value | n/a | fixed builtin alias table |
| compiler/frontend/resolve.mdk:927 | lookupAssoc | haskell*Aliases | bounded | persistent value | n/a | fixed builtin alias table |
| compiler/frontend/resolve.mdk:928 | lookupAssoc | haskell*Aliases | bounded | persistent value | n/a | fixed builtin alias table |
| compiler/frontend/resolve.mdk:956 | lookupAssoc | haskell*Aliases | bounded | persistent value | n/a | fixed builtin alias table |
| compiler/frontend/resolve.mdk:975 | lookupAssoc | haskell*Aliases | bounded | persistent value | n/a | fixed builtin alias table |
| compiler/frontend/resolve.mdk:988 | lookupAssoc | haskell*Aliases | bounded | persistent value | n/a | fixed builtin alias table |
| compiler/frontend/resolve.mdk:2498 | lookupAssoc | resolve env table | per-module | persistent value | n/a | one module's resolve environment |
| compiler/frontend/resolve.mdk:2502 | lookupAssoc | resolve env table | per-module | persistent value | n/a | one module's resolve environment |
| compiler/frontend/resolve.mdk:3675 | lookupAssoc | module list | graph | persistent value | n/a | whole-program module list |
| compiler/backend/emit_support.mdk:23 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/frontend/parse_cache.mdk:41 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/frontend/parse_cache.mdk:68 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:42 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/driver/loader.mdk:371 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:601 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:1307 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/desugar_cache.mdk:25 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/frontend/desugar_cache.mdk:68 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:594 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:595 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:596 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:598 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:715 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:210 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/backend/llvm_emit.mdk:631 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2103 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:4121 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:4126 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:5288 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:5294 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:5335 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:7819 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:8324 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:8842 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:12183 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:12306 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:12937 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:228 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/backend/wasm_emit.mdk:2828 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:6291 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:10665 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:158 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/types/typecheck.mdk:258 | lookupAssoc | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/types/typecheck.mdk:729 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:732 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:2084 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:2569 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:2581 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10228 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10256 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10445 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10599 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10607 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10643 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10838 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10903 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10999 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11079 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11259 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11615 | lookupAssoc | `perRun.value.shadowStandaloneSchemesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:11956 | lookupAssoc | `perRun.value.currentImportOriginsRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:11958 | lookupAssoc | `perRun.value.currentImportDefinersRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:12075 | lookupAssoc | `perRun.value.funConstraintDeclaredRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:12097 | lookupAssoc | `perRun.value.currentImportDefinersRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:12183 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:12258 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:12280 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:12483 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:12484 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:14799 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:14811 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:15007 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:15451 | lookupAssoc | `perRun.value.shadowStandaloneSchemesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:15566 | lookupAssoc | `perRun.value.shadowStandaloneSchemesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:15667 | lookupAssoc | `perRun.value.shadowStandaloneSchemesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:15693 | lookupAssoc | `perRun.value.shadowStandaloneSchemesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:15705 | lookupAssoc | `perRun.value.shadowStandaloneSchemesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:15723 | lookupAssoc | `perRun.value.shadowStandaloneSchemesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:15762 | lookupAssoc | `perRun.value.shadowStandaloneSchemesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:16264 | lookupAssoc | `perRun.value.definerShadowSigsRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:16416 | lookupAssoc | `perRun.value.shadowStandaloneSchemesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:16426 | lookupAssoc | `perRun.value.definerShadowSigsRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:16846 | lookupAssoc | `perRun.value.definerShadowSigsRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:16852 | lookupAssoc | `perRun.value.definerShadowSigsRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:20181 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:20493 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:20998 | lookupAssoc | `graphRun.value.activeDictVars.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:21639 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:24284 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:30538 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:30707 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:31026 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:31090 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:31712 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:32038 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:32227 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:33863 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:34521 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:34779 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:35342 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:36419 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37049 | lookupAssoc | `driverState.value.mangledShadowMapRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:37309 | lookupAssoc | `driverState.value.mangledShadowMapRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:37354 | lookupAssoc | `driverState.value.mangledShadowMapRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:37563 | lookupAssoc | `driverState.value.mangledShadowMapRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:37670 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37705 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37844 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37964 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38174 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38644 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38664 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38667 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38686 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38756 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38979 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:39794 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:40424 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:40790 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:41836 | lookupAssoc | module list | graph | persistent value | n/a | whole-program module list |
| compiler/types/typecheck.mdk:42097 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:42138 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:42247 | lookupAssoc | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |

### `Ref (List ` sites (203)

| file:line | shape | collection | class | container | keying | note |
|---|---|---|---|---|---|---|
| compiler/tools/repl.mdk:46 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/repl.mdk:49 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/repl.mdk:52 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/repl.mdk:55 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/repl.mdk:58 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/repl.mdk:61 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/refindex.mdk:181 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/refindex.mdk:182 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/refindex.mdk:183 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/refindex.mdk:194 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/refindex.mdk:195 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/refindex.mdk:196 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/refindex.mdk:1521 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/refindex.mdk:1526 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/refindex.mdk:1532 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/refindex.mdk:1600 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/refindex.mdk:1617 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/entries/fuzz_gen_main.mdk:134 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/entries/fuzz_gen_main.mdk:556 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/entries/fuzz_gen_main.mdk:562 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/entries/fuzz_gen_main.mdk:627 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/lsp.mdk:1721 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/lsp.mdk:1730 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/support/timer.mdk:36 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:1110 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/support/scc.mdk:18 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/support/scc.mdk:26 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/entries/origin_agreement_main.mdk:516 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/entries/origin_agreement_main.mdk:522 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/entries/origin_agreement_main.mdk:534 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/frontend/desugar_cache.mdk:36 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:588 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:1304 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:1334 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:1345 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/frontend/ast.mdk:1148 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/tools/printer.mdk:373 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/frontend/parser.mdk:357 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/frontend/parser.mdk:1614 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:285 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:310 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:328 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:341 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:352 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:382 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:2887 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:2953 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:4684 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/frontend/parse_cache.mdk:46 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/entries/playground_main.mdk:261 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:677 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:714 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:720 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:729 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:746 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:766 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:781 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:787 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:797 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:815 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/repr.mdk:917 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:4867 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:342 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:345 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:350 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:358 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:360 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:380 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:400 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:401 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:402 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:408 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:409 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1021 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1022 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1098 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1099 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1148 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1149 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1175 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1188 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1321 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1429 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:2808 | Ref (List | route-stamp carrier | per-decl (default) | Ref accumulator | n/a | per-obligation route carrier, heuristic |
| compiler/types/typecheck.mdk:2815 | Ref (List | route-stamp carrier | per-decl (default) | Ref accumulator | n/a | per-obligation route carrier, heuristic |
| compiler/types/typecheck.mdk:2884 | Ref (List | route-stamp carrier | per-decl (default) | Ref accumulator | n/a | per-obligation route carrier, heuristic |
| compiler/types/typecheck.mdk:5773 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:6730 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:7257 | Ref (List | `DriverState.effectDomains` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7262 | Ref (List | `DriverState.abstractRecordTypesRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7263 | Ref (List | `DriverState.argDispatchIdxByIdRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7264 | Ref (List | `DriverState.dictEligibleRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7266 | Ref (List | `DriverState.mangledShadowMapRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7268 | Ref (List | `DriverState.userIfaceNamesRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7269 | Ref (List | `DriverState.coherenceUserDecls` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7270 | Ref (List | `DriverState.stdlibOwnedModsRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7273 | Ref (List | `DriverState.superDeclsRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7274 | Ref (List | `DriverState.standaloneValuesRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7275 | Ref (List | `DriverState.methodDispatchIdxByIdRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7277 | Ref (List | `DriverState.matchWarnings` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7278 | Ref (List | `DriverState.promotionHarvestRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:7526 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8050 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8077 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8099 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8100 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8103 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8106 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8148 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8149 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8150 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8151 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8152 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8153 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8155 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8253 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8440 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8513 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8608 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:9136 | Ref (List | `GraphRun.goals` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9140 | Ref (List | `GraphRun.numlitRefs` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9141 | Ref (List | `GraphRun.activeDictVars` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9150 | Ref (List | `GraphRun.moduleRanges` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9154 | Ref (List | `GraphRun.stampCtxs` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9304 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:9328 | Ref (List | `PerRun.rigidEffvarsRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9331 | Ref (List | `PerRun.dataParamKindsRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9333 | Ref (List | `PerRun.dataParamPolarityRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9334 | Ref (List | `PerRun.dataParamRowAtomsRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9335 | Ref (List | `PerRun.aliasTableRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9336 | Ref (List | `PerRun.shadowStandaloneSchemesRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9337 | Ref (List | `PerRun.ifaceMethodSchemesByIdRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9340 | Ref (List | `PerRun.definerShadowNamesRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9341 | Ref (List | `PerRun.definerShadowSigsRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9348 | Ref (List | `PerRun.poisonedVars` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9349 | Ref (List | `PerRun.deferrableVarIds` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9350 | Ref (List | `PerRun.tupleCallCandidates` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9351 | Ref (List | `PerRun.numlitVarLocs` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9352 | Ref (List | `PerRun.numlitUntainted` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9353 | Ref (List | `PerRun.numlitOpLocs` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9354 | Ref (List | `PerRun.numlitCtxTags` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9355 | Ref (List | `PerRun.localBindRefs` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9356 | Ref (List | `PerRun.localSchemesOut` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9357 | Ref (List | `PerRun.seedSchemesOut` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9358 | Ref (List | `PerRun.funPredicateSlotsRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9359 | Ref (List | `PerRun.funConstraintDeclaredRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9360 | Ref (List | `PerRun.currentImportDefinersRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9361 | Ref (List | `PerRun.currentImportOriginsRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9368 | Ref (List | `PerRun.schemeObligationsRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9373 | Ref (List | `PerRun.methodPredicateSlotsRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9379 | Ref (List | `PerRun.promotedRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9383 | Ref (List | `PerRun.flatUserShadowNamesRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9384 | Ref (List | `PerRun.groupConstraintMonosRef` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:9400 | Ref (List | `PerRun.pinnedLocals` | graph | Ref accumulator (record field) | n/a | run-wide accumulator field |
| compiler/types/typecheck.mdk:10427 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10428 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10429 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10450 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10451 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10452 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10461 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10462 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10463 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11467 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11468 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11740 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11835 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:15803 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:15889 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:15905 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:16491 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:20449 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:21520 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:21630 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:21637 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:21644 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:21647 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:21678 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:21809 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:948 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:949 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:950 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:951 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:952 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:953 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:954 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:956 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:959 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:960 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:961 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:964 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:965 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:967 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:969 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:971 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:985 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:986 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:987 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:988 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:989 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:1078 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:1085 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:1871 | Ref (List | (type occurrence, see note) | per-decl (default) | Ref/persistent (see decl) | n/a | heuristic default, not individually verified |

### `contains`/`elem`/`containsI`/`dedup`/`dedupBy` sites (476)

| file:line | shape | collection | class | container | keying | note |
|---|---|---|---|---|---|---|
| compiler/tools/prop_runner.mdk:29 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/prop_runner.mdk:331 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/doc.mdk:51 | contains/elem/dedup | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/tools/doc.mdk:538 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/doc.mdk:540 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/doc.mdk:780 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/doc.mdk:836 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/doc.mdk:1239 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/check_policy.mdk:65 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/check_policy.mdk:282 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/check_policy.mdk:361 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/check_policy.mdk:390 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/repl.mdk:43 | contains/elem/dedup | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/tools/repl.mdk:204 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint_baseline.mdk:31 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint_baseline.mdk:228 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/codemod.mdk:57 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/codemod.mdk:285 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/snapshot.mdk:1300 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/mcp.mdk:121 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_eval.mdk:45 | contains/elem/dedup | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/ir/core_ir_eval.mdk:482 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_eval.mdk:640 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_eval.mdk:642 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:68 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:85 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:86 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:584 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:646 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:888 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:889 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:1017 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:1028 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:1040 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:1270 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:1701 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:1886 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:2163 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:2323 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:2777 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:2780 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:2783 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:5005 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:5669 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/lint.mdk:5670 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/gate_cmd.mdk:86 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/gate_cmd.mdk:856 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/gate_cmd.mdk:1569 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/gate_cmd.mdk:1788 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/gate_cmd.mdk:1789 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/gate_cmd.mdk:1829 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/gate_cmd.mdk:1979 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/gate_cmd.mdk:2665 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/gate_cmd.mdk:2756 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/gate_cmd.mdk:4384 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/tools/gate_cmd.mdk:5278 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:71 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:82 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:935 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:1029 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:1071 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:1200 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:1972 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:2094 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:2110 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:2257 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:2268 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/ir/core_ir_lower.mdk:2449 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/entries/llvm_emit_typed_main.mdk:43 | contains/elem/dedup | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/entries/llvm_emit_typed_main.mdk:86 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/support/util.mdk:33 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/support/util.mdk:34 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/support/util.mdk:35 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/support/util.mdk:37 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/support/util.mdk:171 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/support/util.mdk:172 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/support/util.mdk:185 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/support/util.mdk:186 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/marker.mdk:50 | contains/elem/dedup | (import/export mention) | n/a | n/a | n/a | not a scan site |
| compiler/frontend/marker.mdk:155 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/marker.mdk:176 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/marker.mdk:201 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/exhaust.mdk:61 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/exhaust.mdk:654 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/emit_support.mdk:22 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/emit_support.mdk:26 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/emit_support.mdk:182 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/emit_support.mdk:264 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/emit_support.mdk:270 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/emit_support.mdk:490 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/desugar.mdk:53 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/desugar.mdk:576 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/desugar.mdk:1052 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/desugar.mdk:1126 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:51 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:65 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:740 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:755 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:779 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:2462 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:2748 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:2776 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:3853 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:3948 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:3953 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/eval/eval.mdk:4088 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:33 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:962 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:1081 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:1138 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:1187 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/loader.mdk:1189 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:85 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:1226 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/diagnostics.mdk:2018 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:69 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:83 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:84 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:445 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:530 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:603 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:791 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:1233 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:1476 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:1521 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:1534 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:1548 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:1552 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:1827 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:1955 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:1962 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:2023 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:2029 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:2240 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:2468 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:2492 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:2493 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:2494 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:2495 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:2506 | contains/elem/dedup | resolve env table | per-module | persistent value | n/a | one module's resolve environment |
| compiler/frontend/resolve.mdk:2551 | contains/elem/dedup | resolve env table | per-module | persistent value | n/a | one module's resolve environment |
| compiler/frontend/resolve.mdk:2620 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:2692 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:2747 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:2996 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:3054 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:3383 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:3456 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:3545 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/frontend/resolve.mdk:3917 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/medaka_cli.mdk:55 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/medaka_cli.mdk:1037 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/medaka_cli.mdk:1448 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/medaka_cli.mdk:1853 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/medaka_cli.mdk:1854 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/medaka_cli.mdk:2175 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/medaka_cli.mdk:2478 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/medaka_cli.mdk:3077 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/medaka_cli.mdk:3526 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/driver/medaka_cli.mdk:4425 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/trmc_analysis.mdk:23 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/trmc_analysis.mdk:30 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/trmc_analysis.mdk:73 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/trmc_analysis.mdk:120 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/trmc_analysis.mdk:122 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/trmc_analysis.mdk:445 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/trmc_analysis.mdk:796 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/trmc_analysis.mdk:924 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/trmc_analysis.mdk:928 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/trmc_analysis.mdk:1114 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/trmc_analysis.mdk:1146 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/trmc_analysis.mdk:1227 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:225 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:232 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:1674 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:1720 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:1830 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:1855 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:1867 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:1891 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:1893 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:1993 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2029 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2048 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2257 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2264 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2273 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2277 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2313 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2320 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2327 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2334 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2340 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2361 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2384 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2392 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2397 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2403 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2407 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2537 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2764 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:2824 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:3053 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:3118 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:3120 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:3143 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:3275 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:3573 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:4099 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:4110 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:4112 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:4184 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:4208 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:5137 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:5169 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:5174 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:5409 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:6116 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:6503 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:6811 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:6987 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:6990 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:7016 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:7017 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:7022 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:7023 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:7040 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:7041 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:7057 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:7243 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:8286 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:8330 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:8723 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:9204 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:9691 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:9864 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:9893 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:9977 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:10069 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:10130 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:10131 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:10655 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:11534 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:11822 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:11832 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:11834 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:11836 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/wasm_emit.mdk:12149 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:212 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:218 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:219 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:706 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:721 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:1398 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:1643 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2251 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2290 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2305 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2329 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2446 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2509 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2557 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2586 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2633 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2653 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2707 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2787 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2825 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:2851 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:3023 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:3160 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:3215 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:3257 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:3296 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:3343 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:4211 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:4694 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:4755 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:4757 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:4765 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:4813 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:4815 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:4831 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:4849 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:4864 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:6287 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:6400 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:7143 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:7293 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:7298 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:8058 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:9457 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:9565 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:11397 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:11414 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:11562 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:11602 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:11685 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:13310 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:13317 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:13466 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:13467 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/llvm_emit.mdk:13474 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/private_mangle.mdk:120 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/private_mangle.mdk:126 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/private_mangle.mdk:127 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/private_mangle.mdk:159 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/private_mangle.mdk:248 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/private_mangle.mdk:381 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/private_mangle.mdk:390 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/private_mangle.mdk:438 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/private_mangle.mdk:478 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/private_mangle.mdk:575 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/private_mangle.mdk:708 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/backend/private_mangle.mdk:769 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:259 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:276 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:277 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:520 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:904 | contains/elem/dedup | `perRun.value.rigidEffvarsRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:1454 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:1468 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:1486 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:1699 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:2173 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:2174 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:2682 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:3059 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8632 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:8639 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:9507 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:9508 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:9509 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:9859 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10211 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10363 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10419 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10433 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10435 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10436 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10505 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10512 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10513 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:10540 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11332 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11334 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11335 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11444 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11445 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11446 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:11582 | contains/elem/dedup | `driverState.value.standaloneValuesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:12432 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:12458 | contains/elem/dedup | `driverState.value.userIfaceNamesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:12668 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:12998 | contains/elem/dedup | `driverState.value.abstractRecordTypesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:13813 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:14860 | contains/elem/dedup | `perRun.value.definerShadowNamesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:14861 | contains/elem/dedup | `driverState.value.standaloneValuesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:14973 | contains/elem/dedup | `perRun.value.definerShadowNamesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:14974 | contains/elem/dedup | `driverState.value.standaloneValuesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:15450 | contains/elem/dedup | `driverState.value.standaloneValuesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:16080 | contains/elem/dedup | `perRun.value.definerShadowNamesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:16147 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:16166 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:16297 | contains/elem/dedup | `perRun.value.definerShadowNamesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:16403 | contains/elem/dedup | `perRun.value.definerShadowNamesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:16438 | contains/elem/dedup | `perRun.value.definerShadowNamesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:16442 | contains/elem/dedup | `perRun.value.definerShadowNamesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:17483 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:17484 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:17485 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:18417 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:18430 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:19162 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:19184 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:19193 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:19359 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:19417 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:19431 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:19466 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:19597 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:19598 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:19876 | contains/elem/dedup | `perRun.value.promotedRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:19891 | contains/elem/dedup | module list | graph | persistent value | n/a | whole-program module list |
| compiler/types/typecheck.mdk:19941 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:19985 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:20467 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:20830 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:20979 | contains/elem/dedup | `perRun.value.definerShadowNamesRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:21149 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:21210 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:21435 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:21481 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:21562 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:22461 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:22633 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:23064 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:23223 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:23388 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:23731 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:25182 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:25556 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:25905 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:26926 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:27524 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:27539 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:28244 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:28854 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:29167 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:29172 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:30380 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:30854 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:31002 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:31137 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:31155 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:31230 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:31241 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:31837 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:31859 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:31866 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:31899 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:32045 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:32046 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:32073 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:32075 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:32292 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:32394 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:32598 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:32821 | contains/elem/dedup | `driverState.value.stdlibOwnedModsRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |
| compiler/types/typecheck.mdk:34130 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:34443 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:34483 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:35095 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:35309 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:35311 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:35323 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:35324 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:35361 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:35966 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:36223 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:36492 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:36544 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:36596 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:36662 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37041 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37053 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37305 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37313 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37350 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37355 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37358 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37494 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37497 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37555 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37556 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:37565 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38163 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38179 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38518 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38519 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38657 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38704 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38710 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38758 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:38765 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:41233 | contains/elem/dedup | module list | graph | persistent value | n/a | whole-program module list |
| compiler/types/typecheck.mdk:41255 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:41258 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:41819 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:41822 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:41971 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:42012 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:42103 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:42268 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:42487 | contains/elem/dedup | (unclassified, see note) | per-decl (default) | persistent value | n/a | heuristic default, not individually verified |
| compiler/types/typecheck.mdk:42567 | contains/elem/dedup | `driverState.value.promotionHarvestRef.value` | graph | Ref accumulator | n/a | run-wide accumulator |

### `lookupTab` sites (18)

| file:line | shape | collection | class | container | keying | note |
|---|---|---|---|---|---|---|
| compiler/frontend/exhaust.mdk:263 | lookupTab | `oracle.typeCtors` | per-module | persistent value | first-wins (linear scan) | one module's exhaustiveness oracle |
| compiler/types/typecheck.mdk:1505 | lookupTab | `PerRun.dataParamKindsRef` | graph | Ref accumulator | first-wins | run-wide kind table |
| compiler/types/typecheck.mdk:2057 | lookupTab | `PerRun.dataParamKindsRef` | graph | Ref accumulator | first-wins | run-wide kind table |
| compiler/types/typecheck.mdk:2386 | lookupTab | `PerRun.aliasTableRef` | graph | Ref accumulator | first-wins | run-wide alias table |
| compiler/types/typecheck.mdk:2390 | lookupTab | `PerRun.dataParamKindsRef` | graph | Ref accumulator | first-wins | run-wide kind table |
| compiler/types/typecheck.mdk:9734 | lookupTab | `PerRun.dataParamPolarityRef` (via `tab` param) | graph | persistent value (passed as arg) | first-wins | "graph-wide seed builder … per-run reader" per adjoining comment |
| compiler/types/typecheck.mdk:9740 | lookupTab | `PerRun.dataParamRowAtomsRef` | graph | Ref accumulator | first-wins | run-wide row-atom table |
| compiler/types/typecheck.mdk:10627 | lookupTab | `PerRun.aliasTableRef` | graph | Ref accumulator | first-wins | run-wide alias table |
| compiler/types/typecheck.mdk:10750 | lookupTab | `PerRun.aliasTableRef` | graph | Ref accumulator | first-wins | run-wide alias table |
| compiler/types/typecheck.mdk:10760 | lookupTab | `PerRun.dataParamKindsRef` | graph | Ref accumulator | first-wins | run-wide kind table |
| compiler/types/typecheck.mdk:10770 | lookupTab | `PerRun.dataParamKindsRef` | graph | Ref accumulator | first-wins | run-wide kind table |
| compiler/types/typecheck.mdk:10989 | lookupTab | `PerRun.dataParamKindsRef` | graph | Ref accumulator | first-wins | run-wide kind table |
| compiler/types/typecheck.mdk:11068 | lookupTab | `PerRun.dataParamKindsRef` | graph | Ref accumulator | first-wins | run-wide kind table |
| compiler/types/typecheck.mdk:17534 | lookupTab | `PerRun.dataParamKindsRef` | graph | Ref accumulator | first-wins | run-wide kind table |
| compiler/types/typecheck.mdk:17945 | lookupTab | `PerRun.dataParamPolarityRef` | graph | Ref accumulator | first-wins | run-wide polarity table |
| compiler/types/typecheck.mdk:32858 | lookupTab | `PerRun.aliasTableRef` (via `aliases` param) | graph | persistent value (passed as arg) | first-wins | comment at line ~32850 names the source as "the current module's `perRun.aliasTableRef`" |
| compiler/types/typecheck.mdk:32864 | lookupTab | `PerRun.aliasTableRef` (via `aliases` param) | graph | persistent value (passed as arg) | first-wins | see 32858 |
| compiler/types/typecheck.mdk:34009 | lookupTab | `PerRun.*` table (via `tab` param, unresolved to a single field without more reading) | graph (tentative) | persistent value (passed as arg) | first-wins | not individually verified past the naming convention |
