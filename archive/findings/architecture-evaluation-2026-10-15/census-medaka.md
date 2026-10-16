# Medaka compiler structural census

**Status:** CLOSED RECORD. Structural census of this tree at `48e36f797` (2026-10-14); re-derive with the scripts in `census/` rather than citing these numbers.

Tree: worktree `/root/medaka/.claude/worktrees/agent-ac37943b3d2016cf3` at `48e36f797` (= `origin/main` at measurement time, 2026-10-14). Scope unless stated: non-test `compiler/**/*.mdk` (`*_test.mdk` excluded), 170 modules. Read-only; nothing built. Helper scripts (re-runnable, `python3 -I <script> <repo-root> [section]`) are in `/var/tmp/medaka-scratch/claude-0/-root-medaka/ac871d0c-5bf1-4c5a-8b59-41fa6e5a0c32/scratchpad/`: `census.py` (sections A B C D F G), `impnames.py`, `d1b.py`, `d2.py`, `d3.py`, `ident.py`, `misc.py`, `docs.py` (E), `ent.py` (H), `growth.py` (I), `appendix.py`.

## Headline numbers

1. 170 non-test compiler modules, 207,683 lines; median file 230 lines, p90 2,217, max 57,032. The 20 files over 2,000 lines hold 151,290 lines (72.8%).
2. `types/typecheck.mdk` is 57,032 lines (27.5% of the compiler), 3,412 distinct top-level names, 150 `data` decls; 22,695 of its lines (39.8%) are comments.
3. Growth of typecheck.mdk: 10,925 (2026-07-01), 19,885 (08-01), 38,963 (09-01), 53,048 (10-01), 57,032 (now): 5.2x in 3.5 months, +3,984 in the first 14 days of October. Whole compiler: 60,222 to 207,683 lines over the same span.
4. Functions are small, files are wide: typecheck median declaration 6 lines, only 3 declarations over 200 lines and 1 over 500 (`checkBodyImpl`, 707 lines, 416 of them comment). No declaration in llvm_emit, resolve or eval exceeds 200 lines.
5. Import graph: 994 module edges, 0 cycles, longest chain 19 modules. Hubs by in-degree: `frontend.ast` 107, `support.util` 93, `frontend.parser` 55, `frontend.desugar` 48, `support.ordmap` 35, `types.typecheck` 35.
6. Layering: 7 violating edges against the stated order. 4 of the 7 are imports of `backend.private_mangle` (from types.typecheck, ir.core_ir_lower, ir.core_ir_eval, eval.eval); 2 are ir -> eval.eval; 1 is eval.eval -> driver.diagnostics.
7. The types/ extractions are real downward dependencies: 19 of the 21 other `types/*` modules are imported by typecheck.mdk; exactly 1 (`effect_policy`) imports typecheck back; `annotate` and nothing else is unconnected to it.
8. llvm_emit vs wasm_emit: 95 name twins (30 identical names, 34 `W`-suffixed, 30 `Ref`-suffixed, 1 `wasm`-prefixed) out of 869 llvm names; only 2 of the 30 same-name pairs are textually identical.
9. eval/eval.mdk vs ir/core_ir_eval.mdk: 0 exact shared names, but 23 of core_ir_eval's 55 names are `c`/`ceval`-prefixed twins of eval.mdk names.
10. 214 top-level names are defined in 2+ modules (476 definitions; 119 span two or more directories); 36 of them have 2+ whitespace-normalized identical bodies. `letBindName` is defined in 10 modules (7 identical).
11. `lookupAssoc` (List-as-map): 194 call sites in 25 modules; typecheck.mdk alone has 85.
12. Mutable module state: 106 module-level `= Ref` cells in 27 modules (typecheck 26, eval 16); typecheck additionally bundles 147 `Ref` fields in 4 state records (PerRun 82, DriverState 27, GraphRun 24, CrossRun 14).
13. Docs: 66 `compiler/*.md` totalling 40,015 lines, plus 23 `docs/design` (10,693) and 10 `docs/spec` (12,292). 96 status lines use about 30 distinct leading status words; 35 begin IMPLEMENTED. No doc is unreferenced outside the generated index; 14 are referenced by at most one other file.
14. Archaeology: typecheck.mdk has 1,445 comment lines citing an issue/PR number (304 distinct numbers), 25.3 per 1k lines vs 10.5 per 1k in the rest of the compiler; the word "retired" appears on 101 of its lines.
15. Encapsulation: 2,004 exported names across non-entries modules; typecheck exports 96 of 3,562 names (3%). 479 exports are imported by no non-test module (303 by no module at all, tests included). 67 entries, all referenced; 207 gate rows (113 marked `migration = "done"`).

### Flagged as surprising (measured, not judged)

- `support/ordmap.mdk`'s header says the `om*` helpers "are kept for the existing call sites in types/typecheck.mdk, backend/llvm_emit.mdk, and support/util.mdk"; the module has 35 importers. `compiler/HELPER-CENSUS.md` reports OrdMap -> stdlib `Map` as shipped; `OrdMap` survives as an alias with that fan-in.
- `backend.private_mangle` (a backend module) is imported by the typechecker, both ir modules and the evaluator: it is the single node behind 4 of the 7 layering violations.
- `driver` and `tools` import each other heavily in both directions (driver -> tools 21 edges, tools -> driver 25 edges).
- `types.typecheck` (a non-test module) contains `observeMethodSchemeRowsForTest`, 134 lines, its 5th-largest declaration. 14 `test`/`prop` blocks live in non-test modules (`tools.gate_cost` 8, `tools.gate_registry` 4, `frontend.resolve` 2).
- typecheck.mdk has 3,566 merged declaration extents but 3,412 distinct names: 154 names have definitions that are not adjacent (signature/clauses split by other declarations, or a name re-defined).
- `test/gates.toml`'s header says "The 2026-09-03 seeding classified all 256 entries"; the file now has 207 `[[gate]]` rows.
- `compiler/` did not exist on 2026-06-01: the self-hosted tree was created as `selfhost/` after that date and renamed to `compiler/` on 2026-06-26 (`aee605641`). On 2026-06-01 the reference typechecker was OCaml `lib/typecheck.ml`, 3,956 lines.
- llvm_emit.mdk and wasm_emit.mdk both shrank since 2026-10-01 (-608 and -568 lines); typecheck, resolve and lint grew.
- typecheck.mdk has proportionally fewer section banners than the rest of the compiler (156 banner lines in 57k vs 947 in 151k).

---

## A. Size distribution

Commands: `python3 -I census.py <root> A`. Per-file equivalents (approximate, same regexes):

```sh
F=compiler/types/typecheck.mdk
wc -l < $F
grep -cE '^\s*--' $F                                   # comment lines
grep -cE '^(public export |export )?data ' $F          # data decls
grep -cE '^(export )?import ' $F                       # import statements
grep -cE '^export$|^export (type|data|import) |^public export data ' $F   # exported decls
grep -cE "^[a-z][A-Za-z0-9_']* *= *(Ref|newRef)\b" $F  # module-level Ref cells
```

"top-level names" = distinct identifiers that start a column-0 line, excluding `import`/`data`/`type`/`interface`/`impl`/`export`/`public`/`test`/`prop`/stray `else`, and comments. "col-0 decl lines" counts every such line (signature plus each clause), so it is roughly 2.7x the name count.

### A1 size distribution (non-test compiler/**/*.mdk)

| files | total lines | median | p90 | max |
|---|---|---|---|---|
| 170 | 207683 | 230 | 2217 | 57032 |

- backend: 12 files, 38859 lines, median 1334, max 15283
- driver: 5 files, 11888 lines, median 2098, max 4759
- entries: 67 files, 8326 lines, median 41, max 1698
- eval: 2 files, 5750 lines, median 2875, max 5523
- frontend: 9 files, 22851 lines, median 1297, max 7075
- ir: 7 files, 7079 lines, median 585, max 3983
- support: 9 files, 1482 lines, median 83, max 670
- tools: 37 files, 44634 lines, median 524, max 7227
- types: 22 files, 66814 lines, median 311, max 57032

### A2 files over 2,000 lines

| module | lines | comment | code | blank | top-level names | col-0 decl lines | data | imports | exported | Ref cells |
|---|---|---|---|---|---|---|---|---|---|---|
| types.typecheck | 57032 | 22695 | 30601 | 3736 | 3412 | 9258 | 150 | 35 | 96 | 26 |
| backend.llvm_emit | 15283 | 4651 | 9694 | 938 | 869 | 2744 | 16 | 16 | 10 | 0 |
| backend.wasm_emit | 12286 | 3128 | 8411 | 747 | 687 | 2373 | 18 | 15 | 12 | 0 |
| tools.lint | 7227 | 1851 | 4580 | 796 | 766 | 2060 | 10 | 16 | 48 | 0 |
| frontend.resolve | 7075 | 2610 | 3934 | 531 | 504 | 1650 | 10 | 5 | 41 | 3 |
| frontend.parser | 6783 | 1530 | 4520 | 733 | 713 | 1955 | 8 | 5 | 36 | 8 |
| eval.eval | 5523 | 1603 | 3359 | 561 | 570 | 1811 | 5 | 11 | 105 | 16 |
| driver.medaka_cli | 4759 | 1710 | 2849 | 200 | 190 | 466 | 0 | 44 | 0 | 0 |
| tools.test_cmd | 4225 | 854 | 3139 | 232 | 220 | 578 | 4 | 34 | 23 | 1 |
| ir.core_ir_lower | 3983 | 920 | 2692 | 371 | 354 | 1304 | 7 | 13 | 41 | 0 |
| tools.gate_cmd | 3769 | 706 | 2666 | 397 | 312 | 756 | 13 | 11 | 18 | 0 |
| frontend.lexer | 3146 | 718 | 2188 | 240 | 232 | 886 | 4 | 2 | 17 | 0 |
| driver.diagnostics | 3126 | 1123 | 1804 | 199 | 171 | 399 | 7 | 19 | 96 | 3 |
| tools.gate_pack | 2817 | 568 | 1969 | 280 | 185 | 482 | 6 | 3 | 4 | 0 |
| tools.printer | 2681 | 430 | 1962 | 289 | 272 | 944 | 6 | 4 | 18 | 8 |
| frontend.ast | 2622 | 1418 | 1062 | 142 | 99 | 356 | 45 | 1 | 118 | 0 |
| backend.wasm_preamble | 2537 | 448 | 2004 | 85 | 80 | 170 | 1 | 0 | 54 | 0 |
| tools.lsp | 2182 | 649 | 1338 | 195 | 158 | 428 | 7 | 17 | 12 | 2 |
| tools.native_props | 2136 | 38 | 1913 | 185 | 178 | 573 | 5 | 13 | 3 | 0 |
| driver.build_cmd | 2098 | 859 | 1134 | 105 | 97 | 210 | 3 | 10 | 26 | 0 |

20 files over 2,000 lines hold 151290 of 207683 lines.
Comment lines across all non-test modules: 62805 (30.2% of lines).

Module-level Ref cells (col-0 `name = Ref ...`/`newRef`), all non-test modules: 106 in 27 modules.
Top: types.typecheck 26, eval.eval 16, frontend.parser 8, tools.printer 8, support.scc 6, tools.repl 6, tools.prop_runner 5, driver.diagnostics 3, frontend.resolve 3, support.timer 3, frontend.desugar_cache 2, support.opcount 2

### A3 `sh test/arch_census.sh` (note: its corpus includes `*_test.mdk` and `stdlib/`)

```
arch_census: 296 tracked .mdk files under compiler/ and stdlib/ (excl. test/), 267004 total lines

-- largest files (top 20) --
     57032  compiler/types/typecheck.mdk
     15283  compiler/backend/llvm_emit.mdk
     12286  compiler/backend/wasm_emit.mdk
      7227  compiler/tools/lint.mdk
      7075  compiler/frontend/resolve.mdk
      6783  compiler/frontend/parser.mdk
      5655  compiler/types/typecheck_test.mdk
      5523  compiler/eval/eval.mdk
      4759  compiler/driver/medaka_cli.mdk
      4225  compiler/tools/test_cmd.mdk
      3983  compiler/ir/core_ir_lower.mdk
      3769  compiler/tools/gate_cmd.mdk
      3146  compiler/frontend/lexer.mdk
      3126  compiler/driver/diagnostics.mdk
      2817  compiler/tools/gate_pack.mdk
      2681  compiler/tools/printer.mdk
      2622  compiler/frontend/ast.mdk
      2537  compiler/backend/wasm_preamble.mdk
      2476  stdlib/http.mdk
      2391  stdlib/core.mdk

-- per-directory totals (immediate subdir of compiler/, plus stdlib/) --
  compiler/types              52 files     85675 lines
  compiler/tools              60 files     50588 lines
  compiler/backend            24 files     43629 lines
  stdlib                      49 files     27572 lines
  compiler/frontend           12 files     23506 lines
  compiler/driver              7 files     12030 lines
  compiler/entries            67 files      8326 lines
  compiler/ir                 10 files      7822 lines
  compiler/eval                3 files      5867 lines
  compiler/support            12 files      1989 lines
```

## B. Declaration size distribution

Command: `python3 -I census.py <root> B`. A declaration's extent runs from its column-0 start to the last non-blank, non-comment line before the next column-0 declaration; consecutive same-name column-0 lines (signature + clauses) are merged; `export` lines attach to the next declaration; comment lines inside the extent are counted (shown separately); comments immediately preceding the next declaration are excluded from both. `data` declarations are included and shown as `data X`. Approximate: a column-0 continuation line inside an expression would split an extent.


#### types.typecheck.mdk (57032 lines, 3566 merged declarations)

median 6 lines, p90 19; >100: 11; >200: 3; >500: 1; lines in decls >200: 1171

| rank | declaration | start-end | lines | of which comment |
|---|---|---|---|---|
| 1 | `checkBodyImpl` | 36414-37120 | 707 | 416 |
| 2 | `inferMethodBody` | 40763-41021 | 259 | 99 |
| 3 | `processSCC` | 45367-45571 | 205 | 58 |
| 4 | `inferDefinerShadowAppAt` | 23260-23458 | 199 | 96 |
| 5 | `observeMethodSchemeRowsForTest` | 47890-48023 | 134 | 0 |
| 6 | `graphPreamble` | 53269-53402 | 134 | 96 |
| 7 | `data PerRun` | 12112-12239 | 128 | 38 |
| 8 | `entailInst` | 34341-34466 | 126 | 49 |
| 9 | `rewriteArgScoped` | 28330-28446 | 117 | 12 |
| 10 | `checkModuleFullDiags` | 53590-53697 | 108 | 71 |
| 11 | `driveGraphK` | 54326-54433 | 108 | 50 |
| 12 | `methodMarkCtx` | 55751-55849 | 99 | 41 |
| 13 | `recordImplObligation` | 21837-21930 | 94 | 80 |
| 14 | `data GraphRun` | 11527-11619 | 93 | 64 |
| 15 | `checkOneCallObligation` | 38375-38467 | 93 | 66 |

#### backend.llvm_emit.mdk (15283 lines, 887 merged declarations)

median 6 lines, p90 26; >100: 4; >200: 0; >500: 0; lines in decls >200: 0

| rank | declaration | start-end | lines | of which comment |
|---|---|---|---|---|
| 1 | `emitNetExtern` | 3056-3248 | 193 | 5 |
| 2 | `emitFileExtern` | 2873-3050 | 178 | 0 |
| 3 | `emitNumExtern` | 2291-2398 | 108 | 22 |
| 4 | `ffiEmitCall` | 4990-5092 | 103 | 54 |
| 5 | `buildEmitState` | 14749-14841 | 93 | 12 |
| 6 | `emitApp` | 7025-7111 | 87 | 17 |
| 7 | `data Emit` | 920-1004 | 85 | 31 |
| 8 | `emitMethod` | 7325-7401 | 77 | 25 |
| 9 | `emitArraySlice` | 14175-14251 | 77 | 0 |
| 10 | `emitStrExtern` | 2181-2256 | 76 | 2 |
| 11 | `emitRefutMatch` | 10937-11012 | 76 | 15 |
| 12 | `satOnlyUses` | 6578-6652 | 75 | 2 |
| 13 | `emitTree` | 10548-10622 | 75 | 27 |
| 14 | `emitByteBlockExtern` | 2597-2666 | 70 | 0 |
| 15 | `emitDispatchArmBody` | 8436-8499 | 64 | 23 |

#### backend.wasm_emit.mdk (12286 lines, 706 merged declarations)

median 5 lines, p90 30; >100: 8; >200: 4; >500: 0; lines in decls >200: 1227

| rank | declaration | start-end | lines | of which comment |
|---|---|---|---|---|
| 1 | `emitLeafExternRef` | 7201-7675 | 475 | 92 |
| 2 | `emitRefProgram` | 3129-3408 | 280 | 89 |
| 3 | `emitArrayExternRef` | 7693-7956 | 264 | 25 |
| 4 | `emitStrExternRef` | 6962-7169 | 208 | 28 |
| 5 | `externArityW` | 1774-1964 | 191 | 24 |
| 6 | `patTestBind` | 4301-4437 | 137 | 33 |
| 7 | `emitLitSwitchRef` | 10921-11038 | 118 | 23 |
| 8 | `emitMethodRef` | 4604-4711 | 108 | 29 |
| 9 | `emitBinRef` | 5938-6034 | 97 | 44 |
| 10 | `emitVarRefPlain` | 5738-5832 | 95 | 47 |
| 11 | `emitByteBlockExternRef` | 7973-8060 | 88 | 11 |
| 12 | `scanExprValueUses` | 2376-2462 | 87 | 13 |
| 13 | `data WasmEmit` | 419-504 | 86 | 23 |
| 14 | `emitWasmTrmcCore` | 8763-8847 | 85 | 7 |
| 15 | `emitSliceRef` | 10336-10414 | 79 | 7 |

#### frontend.resolve.mdk (7075 lines, 514 merged declarations)

median 5 lines, p90 17; >100: 4; >200: 0; >500: 0; lines in decls >200: 0

| rank | declaration | start-end | lines | of which comment |
|---|---|---|---|---|
| 1 | `data ResError` | 106-284 | 179 | 137 |
| 2 | `ppResError` | 2934-3073 | 140 | 36 |
| 3 | `fillDeclOrigin` | 6498-6612 | 115 | 107 |
| 4 | `stampModulesGo` | 6833-6933 | 101 | 88 |
| 5 | `checkExpr` | 876-967 | 92 | 13 |
| 6 | `checkTypeGo` | 507-580 | 74 | 24 |
| 7 | `resErrorSexp` | 2790-2859 | 70 | 4 |
| 8 | `buildEnvMM` | 4385-4453 | 69 | 8 |
| 9 | `resolveModulesToLines` | 5185-5249 | 65 | 50 |
| 10 | `unqualSection` | 6399-6460 | 62 | 56 |
| 11 | `importedNamesMM` | 3350-3410 | 61 | 29 |
| 12 | `unqualExpr` | 6296-6356 | 61 | 0 |
| 13 | `stampExpr` | 5344-5399 | 56 | 0 |
| 14 | `data ModuleExports` | 3158-3212 | 55 | 34 |
| 15 | `flatTyOriginScope` | 6945-6999 | 55 | 45 |

#### eval.eval.mdk (5523 lines, 576 merged declarations)

median 4 lines, p90 14; >100: 2; >200: 0; >500: 0; lines in decls >200: 0

| rank | declaration | start-end | lines | of which comment |
|---|---|---|---|---|
| 1 | `externBindings` | 3529-3683 | 155 | 0 |
| 2 | `modExportCells` | 4835-4944 | 110 | 106 |
| 3 | `eval` | 1635-1727 | 93 | 26 |
| 4 | `receiverParam` | 2538-2619 | 82 | 77 |
| 5 | `data Value` | 119-177 | 59 | 35 |
| 6 | `evalModules` | 4397-4453 | 57 | 51 |
| 7 | `evalModulesWith` | 4499-4554 | 56 | 10 |
| 8 | `tyvarsInArgs` | 584-637 | 54 | 50 |
| 9 | `ioHostExterns` | 5397-5449 | 53 | 16 |
| 10 | `evalArith` | 2281-2332 | 52 | 7 |
| 11 | `buildRootModuleStateWith` | 4743-4790 | 48 | 2 |
| 12 | `methodAtNarrow` | 1484-1528 | 45 | 23 |
| 13 | `buildModInfos` | 4566-4610 | 45 | 14 |
| 14 | `matchPat` | 1010-1050 | 41 | 5 |
| 15 | `declImplEntries` | 2697-2730 | 34 | 22 |

## C. Import graph

Command: `python3 -I census.py <root> C`. Module id = path under `compiler/` with `/` -> `.`. Edge = a `import <mod>...` line (incl. `export import`) whose module is a non-test compiler module; distinct (importer, target) pairs. Import style across non-test modules: 1,098 selective `.{...}`, 18 qualified `as`, 0 wildcard `.*`, 0 bare. Layering rule applied: `support(0) < frontend(1) < types(2) < ir(3) < backend(4)` with no upward edges; eval may import support/frontend/types; nothing outside driver/tools/entries may import driver/tools/entries; imports of eval from the ordered chain are flagged separately because the stated layering does not place eval in the chain.

### C1 degree summary

170 modules, 994 intra-compiler import edges (distinct module pairs). Out-degree median 4, max 47; in-degree median 1, max 107. Modules with in-degree 0: 20 (of which entries: 19).

Hubs (top 20 by in-degree):

| module | in-degree | out-degree | lines |
|---|---|---|---|
| frontend.ast | 107 | 0 | 2622 |
| support.util | 93 | 3 | 670 |
| frontend.parser | 55 | 4 | 6783 |
| frontend.desugar | 48 | 3 | 1297 |
| support.ordmap | 35 | 0 | 71 |
| types.typecheck | 35 | 29 | 57032 |
| entries.entry_support | 32 | 17 | 673 |
| eval.eval | 27 | 9 | 5523 |
| driver.loader | 25 | 3 | 1542 |
| ir.core_ir_lower | 24 | 11 | 3983 |
| support.path | 19 | 0 | 73 |
| types.repr | 19 | 5 | 829 |
| backend.private_mangle | 18 | 4 | 1933 |
| frontend.lexer | 17 | 2 | 3146 |
| driver.diagnostics | 16 | 17 | 3126 |
| ir.core_ir | 16 | 3 | 677 |
| frontend.resolve | 14 | 4 | 7075 |
| backend.core_validate | 13 | 10 | 1331 |
| backend.emit_plan | 13 | 8 | 256 |
| types.effect_rows | 11 | 6 | 437 |

Highest out-degree (top 12):

| module | out-degree | in-degree |
|---|---|---|
| entries.oracle_multicall | 47 | 0 |
| driver.medaka_cli | 39 | 0 |
| tools.test_cmd | 29 | 3 |
| types.typecheck | 29 | 35 |
| entries.playground_main | 22 | 0 |
| entries.profile_main | 21 | 0 |
| tools.snapshot | 20 | 1 |
| driver.diagnostics | 17 | 16 |
| entries.entry_support | 17 | 32 |
| backend.llvm_emit | 15 | 6 |
| entries.all_modules_entry | 15 | 0 |
| backend.wasm_emit | 14 | 8 |

### C2 directory-level edge matrix (row imports column; count of module edges)

| from \ to | support | frontend | types | ir | backend | eval | driver | tools | entries |
|---|---|---|---|---|---|---|---|---|---|
| support | 6 | . | . | . | . | . | . | . | . |
| frontend | 15 | 12 | . | . | . | . | . | . | . |
| types | 28 | 19 | 55 | . | 1 | . | . | . | . |
| ir | 8 | 10 | 7 | 6 | 2 | 2 | . | . | . |
| backend | 19 | 10 | 10 | 11 | 22 | . | . | . | . |
| eval | 3 | 1 | 2 | . | 1 | 1 | 1 | . | . |
| driver | 14 | 19 | 6 | . | . | 1 | 8 | 21 | . |
| tools | 58 | 74 | 22 | 5 | 8 | 6 | 25 | 62 | . |
| entries | 27 | 123 | 39 | 45 | 39 | 18 | 21 | 22 | 79 |

### C3 layering violations (every edge)

7 violating edges.

- ir -> backend (upward): 2
- ir -> eval (eval sits outside the support<frontend<types<ir<backend chain): 2
- eval -> backend (eval should depend on frontend/types only): 1
- eval -> driver (non-top imports top): 1
- types -> backend (upward): 1

| from | to | kind |
|---|---|---|
| eval.eval | backend.private_mangle | eval -> backend (eval should depend on frontend/types only) |
| eval.eval | driver.diagnostics | eval -> driver (non-top imports top) |
| ir.core_ir_eval | backend.private_mangle | ir -> backend (upward) |
| ir.core_ir_lower | backend.private_mangle | ir -> backend (upward) |
| ir.core_ir_eval | eval.eval | ir -> eval (eval sits outside the support<frontend<types<ir<backend chain) |
| ir.core_ir_lower | eval.eval | ir -> eval (eval sits outside the support<frontend<types<ir<backend chain) |
| types.typecheck | backend.private_mangle | types -> backend (upward) |

### C4 stdlib modules imported by the compiler

| stdlib module | # compiler modules importing (non-test) |
|---|---|
| string | 27 |
| list | 21 |
| json | 14 |
| map | 13 |
| regex | 8 |
| toml | 5 |
| hash_map | 5 |
| u64 | 4 |
| args | 3 |
| io | 3 |
| path | 1 |
| array | 1 |
| fs | 1 |
| test_process | 1 |
| test | 1 |

### C5 types/* vs typecheck

typecheck.mdk imports 29 compiler modules (19 in types/), and is imported by 35 modules (1 in types/).

| types/ module | lines | imported BY typecheck | IMPORTS typecheck | imports other types/* |
|---|---|---|---|---|
| annotate | 328 |  |  |  |
| disposition | 294 | yes |  | repr |
| effect_authority | 533 | yes |  | effect_domain |
| effect_bindings | 57 | yes |  | effect_rows, repr |
| effect_domain | 887 | yes |  |  |
| effect_infer | 332 | yes |  | effect_authority, effect_domain, effect_rows, repr |
| effect_invocation | 153 | yes |  | effect_rows, repr |
| effect_policy | 345 |  | YES | effect_authority, effect_rows, repr, target_profile |
| effect_rows | 437 | yes |  | effect_authority, effect_domain |
| effect_solver | 1668 | yes |  | effect_authority, effect_rows |
| effect_values | 266 | yes |  | effect_authority, effect_domain, effect_rows, repr |
| evidence | 62 | yes |  | repr |
| evidence_complete | 273 | yes |  |  |
| registry | 1662 | yes |  | route_key |
| repr | 829 | yes |  | effect_authority, effect_domain, effect_rows |
| route_key | 631 | yes |  | runtime_types |
| runtime_types | 252 | yes |  | repr |
| scopes | 197 | yes |  | evidence, repr |
| solver_contract | 197 | yes |  | effect_rows, evidence, repr |
| superclass | 139 | yes |  | repr |
| target_profile | 240 | yes |  |  |

Importers of types.typecheck (all dirs): backend.wasm_file_grants, driver.diagnostics, driver.main_autoprint, driver.medaka_cli, entries.check_all_main, entries.check_batch, entries.check_match_main, entries.check_modules_main, entries.check_one_diags_main, entries.core_ir_dict_pp_main, entries.core_ir_typed_main, entries.core_ir_typed_modules_main, entries.entry_support, entries.eval_autoprint_main, entries.eval_typed_modules_main, entries.llvm_bootstrap_lex_main, entries.llvm_emit_main, entries.llvm_emit_modules_main, entries.llvm_emit_typed_main, entries.playground_main, entries.profile_main, entries.profile_modules_main, entries.selfproc_tc_probe, entries.typecheck_main, entries.wasm_emit_gaps_main, entries.wasm_emit_main, entries.wasm_emit_modules_main, entries.wasm_emit_typed_main, tools.check, tools.check_policy, tools.lsp, tools.repl, tools.snapshot, tools.test_cmd, types.effect_policy

Import cycles (SCCs of size >1): 0

Longest import chain length (modules): 19 (from driver.medaka_cli).

The full per-module out/in-degree table is merged into the appendix.

## D. Duplication signals

### D1 llvm_emit.mdk vs wasm_emit.mdk

Command: `python3 -I census.py <root> D` and `python3 -I d1b.py <root>` (other suffix conventions), `python3 -I ident.py <root>` (body identity).

llvm_emit top-level names: 869; wasm_emit: 687.
Same name in both: 30. llvm name with a `W`-suffixed twin in wasm: 34.

Same-name (first 40): `conHeadInfo`, `ctag`, `ctorArity`, `ctorOrdinal`, `ctorsOfType`, `distinctImplKeys`, `emitCtorApp`, `emitCtorEtaClosure`, `emitCtorEtaDefine`, `emitDispatchChain`, `emitDivZeroGuard`, `emitExternEtaClosure`, `emitExternEtaDefine`, `emitLamDefine`, `emitProgram`, `emitProgramGaps`, `emitProgramRecord`, `isArithOp`, `isCmpOp`, `isCtor`, `isFnBind`, `nthArm`, `paramEnv`, `ptag`, `reservedCtorArity`, `reservedCtorsOfType`, `topoValGo`, `topoValVisit`, `topoValVisitDeps`, `valueRelName`

W-twins (first 40): `definedArity`/`definedArityW`, `emitFnsGaps`/`emitFnsGapsW`, `emitImplsGaps`/`emitImplsGapsW`, `entrySuperCount`/`entrySuperCountW`, `externArity`/`externArityW`, `ffiSigOf`/`ffiSigOfW`, `foldImplsByMethod`/`foldImplsByMethodW`, `groupImplsByMethod`/`groupImplsByMethodW`, `headTagForKey`/`headTagForKeyW`, `hex2`/`hex2W`, `hexDigit`/`hexDigitW`, `implEntryAnswers`/`implEntryAnswersW`, `implEntryIfaceWord`/`implEntryIfaceWordW`, `implEntryKey`/`implEntryKeyW`, `implEntrySymTag`/`implEntrySymTagW`, `implEntryTag`/`implEntryTagW`, `isFfiExtern`/`isFfiExternW`, `isInheritedEntry`/`isInheritedEntryW`, `isLazyGlobal`/`isLazyGlobalW`, `methodEntries`/`methodEntriesW`, `methodValueArity`/`methodValueArityW`, `narrowImplsByArity`/`narrowImplsByArityW`, `noteGap`/`noteGapW`, `noteGapAt`/`noteGapAtW`, `orEmptyEntries`/`orEmptyEntriesW`, `sitePacked`/`sitePackedW`, `staticEntryDictRoutes`/`staticEntryDictRoutesW`, `strBytes`/`strBytesW`, `strBytesGo`/`strBytesGoW`, `takeRoutes`/`takeRoutesW`, `unboxU64`/`unboxU64W`, `unprovidedExtern`/`unprovidedExternW`, `utf8Bytes`/`utf8BytesW`, `withRuntimeExterns`/`withRuntimeExternsW`

Additional convention found by probing: 30 llvm names have a `Ref`-suffixed twin in wasm_emit (`emitApp`/`emitAppRef`, `emitArrayCreate`, `emitBin`, `emitBlock`, `emitByteBlockExtern`, `emitDecision`, `emitDictValue`, `emitFieldAccess`, `emitGuardChain`, `emitIf`, `emitLeaf`, `emitList`, `emitLit`, `emitMethod`, `emitMethodDispatch`, `emitMethodValue`, `emitRangeArray`, `emitRangeList`, `emitRecordUpdate`, `emitStrExtern`, `emitSwitch`, `emitTree`, `emitTuple`, `emitU64Bin`, `emitU64Kernel`, `emitU64Shift`, `emitUn`, `emitValueCmp`, `emitVar`, `emitVariantUpdate`) and 1 a `wasm`-prefixed twin (`u64Op`). Total twins summed over the four conventions: 95 of 869 llvm names (10.9%; counted per convention, overlap between conventions not deduplicated). Of the 30 identical-name pairs, 2 have whitespace/comment-normalized identical bodies (`topoValGo`, `topoValVisitDeps`). Other backend modules sharing names with either emitter: `trmc_analysis` 4 (`bindName`, `freeVarsClauses`, `freeVarsStmts`, `patVars`), `core_validate` 1, `private_mangle` 1, `wasm_reach` 1.

### D2 eval/eval.mdk vs ir/core_ir_eval.mdk

eval.mdk: 570 names; core_ir_eval.mdk: 796 lines, 55 names; exact shared names: 0. Stripping a `c`/`ceval` prefix and comparing case-insensitively (`python3 -I d2.py <root>`), 23 of the 55 are twins: `cBlockLet`/`blockLet`, `cBlockLetLast`, `cBuildModInfos`, `cClauseClosure`, `cGroupValue`, `cImplMethodNames`, `cImplMethodValue`, `cInstallGroup`, `cInstallModGroups`, `cRootLocals`, `cRunMainForEffect`, `cTopGroupValue`, `ceval`/`eval`, `cevalBlock`, `cevalField`, `cevalIf`, `cevalLet`, `cevalLetGroup`, `cevalMain`, `cevalMatch`, `cevalModules`, `cevalModulesOutput`, `cevalRecLet`. (core_ir_eval also imports eval.eval, see C3.)

### D3 Same top-level name in 2+ modules (non-test, excluding entries/)

214 names, 476 definitions. By module count: 2 modules 184, 3 modules 20, 4 modules 7, 5 modules 2, 10 modules 1. 119 of the 214 span two or more directories. This is a name match only; `ident.py` compares bodies (comment-stripped, whitespace-collapsed): 36 names have 2+ identical definitions:

`eqStr` (wasm_emit/typecheck); `fieldName` (eval/exhaust/lsp); `fieldOr` (lsp/mcp); `fieldStr` (lsp/mcp); `forEachU` (wasm_emit/wasm_reach); `ifaceMethodName` (marker/lsp); `implMethodName` (eval/lsp/typecheck); `isCommaTok` (lexer/parser); `isElseTok` (lexer/parser); `isEmptyL` (llvm_emit/resolve/doctest); `isEmptyList` (wasm_emit/effect_domain); `isHint` (resolve/annotate); `isThenTok` (lexer/parser); `isWildPat` (llvm_emit/core_ir_lower); `letBindName` (private_mangle/medaka_cli/resolve/lint/lsp/refindex/annotate); `methodOf` (lsp/mcp); `nthArm` (llvm_emit/core_ir_eval); `patBindings` (resolve/annotate); `probeNameNonce` (native_doctest/native_props/native_test_decls); `propParamName` (resolve/annotate); `pureRow` (effect_bindings/typecheck); `quadToParseTriple` (lint_cmd/mcp); `quadToSrc` (lint_cmd/mcp); `recFieldBindings` (marker/resolve/annotate); `responseMsg` (lsp/mcp); `runtimeAlias` (native_doctest/native_props/native_test_decls); `selfBinding` (resolve/typecheck); `sentinelFor` (native_doctest/native_props/native_test_decls); `sentinelPrefix` (eval_props/native_doctest/native_props/native_test_decls); `startTag` (native_props/native_test_decls); `startsWithAt` (resolve/annotate); `stripLocE` (desugar/printer); `topoValGo` (llvm_emit/wasm_emit); `topoValVisitDeps` (llvm_emit/wasm_emit); `unit` (lsp/mcp); `variantName` (exhaust/resolve/typecheck)

Module pairs sharing the most names: llvm_emit/wasm_emit 30; native_doctest/native_test_decls 17; native_props/native_test_decls 11; native_doctest/native_props 10; eval/typecheck 9; resolve/typecheck 7; lsp/mcp 7; desugar/resolve 7; resolve/annotate 6; core_validate/refindex 5; lexer/parser 4; trmc_analysis/wasm_emit 4.

Names in 3+ modules:

| name | # modules | modules |
|---|---|---|
| `letBindName` | 10 | backend.private_mangle, driver.medaka_cli, frontend.resolve, ir.core_ir_lower, tools.lint, tools.lsp, tools.refindex, types.annotate, types.effect_infer, types.typecheck |
| `emit` | 5 | backend.llvm_emit, frontend.lexer, frontend.parser, tools.gate_cmd, tools.native_test_decls |
| `variantName` | 5 | eval.eval, frontend.exhaust, frontend.resolve, tools.refindex, types.typecheck |
| `expectedTags` | 4 | tools.eval_props, tools.native_doctest, tools.native_props, tools.native_test_decls |
| `ifaceMethodName` | 4 | eval.eval, frontend.marker, tools.lsp, types.typecheck |
| `isEmptyL` | 4 | backend.llvm_emit, frontend.resolve, support.util, tools.doctest |
| `isIdentChar` | 4 | support.char, tools.gate_cmd, tools.lint, tools.repl |
| `sentinelBase` | 4 | tools.eval_props, tools.native_doctest, tools.native_props, tools.native_test_decls |
| `sentinelPrefix` | 4 | tools.eval_props, tools.native_doctest, tools.native_props, tools.native_test_decls |
| `startsWithAt` | 4 | eval.eval, frontend.resolve, tools.repl, types.annotate |
| `abortNote` | 3 | tools.native_doctest, tools.native_props, tools.native_test_decls |
| `checkLetBind` | 3 | frontend.exhaust, frontend.resolve, types.typecheck |
| `chunksOf` | 3 | tools.gate_cmd, tools.probe_transcript, tools.snapshot |
| `fieldName` | 3 | eval.eval, frontend.exhaust, tools.lsp |
| `fieldOr` | 3 | eval.eval, tools.lsp, tools.mcp |
| `implMethodName` | 3 | eval.eval, tools.lsp, types.typecheck |
| `nthArm` | 3 | backend.llvm_emit, backend.wasm_emit, ir.core_ir_eval |
| `patBindings` | 3 | frontend.marker, frontend.resolve, types.annotate |
| `probeNameNonce` | 3 | tools.native_doctest, tools.native_props, tools.native_test_decls |
| `probeNamespacePrefixes` | 3 | tools.native_doctest, tools.native_props, tools.native_test_decls |
| `propParamName` | 3 | frontend.resolve, types.annotate, types.typecheck |
| `recFieldBindings` | 3 | frontend.marker, frontend.resolve, types.annotate |
| `renderAll` | 3 | tools.native_doctest, tools.native_props, tools.native_test_decls |
| `renderOne` | 3 | tools.native_doctest, tools.native_test_decls, tools.snapshot |
| `runtimeAlias` | 3 | tools.native_doctest, tools.native_props, tools.native_test_decls |
| `scratchEntryName` | 3 | tools.native_doctest, tools.native_props, tools.native_test_decls |
| `sentinelFor` | 3 | tools.native_doctest, tools.native_props, tools.native_test_decls |
| `tyHeadName` | 3 | ir.core_ir_lower, tools.doc, tools.lint |
| `underDir` | 3 | driver.loader, tools.gate_cmd, types.effect_domain |
| `unquote` | 3 | driver.loader, ir.core_ir_sexp_parse, tools.check_policy |

Names in exactly 2 modules (184; module short names in parentheses):

`addEdges` (effect_solver/wasm_reach); `allDigitsFrom` (typecheck/wasm_emit); `anyIn` (gate_cmd/typecheck); `anyList` (util/wasm_emit); `anyListM` (trmc_analysis/typecheck); `anyMember` (emit_support/typecheck); `appHead` (lint/wasm_emit); `appSpine` (eval/wasm_file_grants); `appSpineHead` (lint/typecheck); `applyAll` (core_ir_lower/parser); `armHasGuard` (core_ir_lower/lint); `atomKey` (codemod/effect_rows); `backendName` (core_validate/target_profile); `bindEach` (llvm_emit/typecheck); `bindName` (trmc_analysis/wasm_emit); `bindNames` (eval/trmc_analysis); `binderAt` (refindex/scopes); `blockLet` (eval/typecheck); `blockRecLet` (eval/typecheck); `buildAndRun` (native_doctest/native_test_decls); `carrierArgs` (native_props/prop_runner); `checkProp` (prop_runner/resolve); `clausesOf` (lint/typecheck); `closure` (dce/wasm_reach); `conHeadInfo` (llvm_emit/wasm_emit); `concatMapC` (doctest/parser); `containsInt` (eval/wasm_emit); `ctag` (llvm_emit/wasm_emit); `ctorArity` (llvm_emit/wasm_emit); `ctorOrdinal` (llvm_emit/wasm_emit); `ctorsOfType` (llvm_emit/wasm_emit); `declDefines` (marker/wasm_file_grants); `dedupPairs` (core_ir_lower/wasm_emit); `defRow` (core_ir_lower/exhaust); `defaultMatrix` (core_ir_lower/exhaust); `digitVal` (exhaust/lexer); `dirGo` (lsp/path); `distinctImplKeys` (llvm_emit/wasm_emit); `dropAssoc` (llvm_emit/util); `dropFirst` (parser/typecheck); `dropPrefix` (loader/wasm_emit); `dropQuadParse` (lint_cmd/mcp); `dsub` (doc/effect_domain); `emitCtorApp` (llvm_emit/wasm_emit); `emitCtorEtaClosure` (llvm_emit/wasm_emit); `emitCtorEtaDefine` (llvm_emit/wasm_emit); `emitDispatchChain` (llvm_emit/wasm_emit); `emitDivZeroGuard` (llvm_emit/wasm_emit); `emitExternEtaClosure` (llvm_emit/wasm_emit); `emitExternEtaDefine` (llvm_emit/wasm_emit); `emitLamDefine` (llvm_emit/wasm_emit); `emitProgram` (llvm_emit/wasm_emit); `emitProgramGaps` (llvm_emit/wasm_emit); `emitProgramRecord` (llvm_emit/wasm_emit); `endTag` (eval_props/probe_transcript); `entryCovers` (effect_domain/typecheck); `eqStr` (typecheck/wasm_emit); `exprLoc` (desugar/typecheck); `externName` (parser/snapshot); `fieldNames` (prop_runner/test_pins); `fieldStr` (lsp/mcp); `fieldTyOf` (resolve/typecheck); `findRecField` (core_ir_lower/exhaust); `firstOr` (resolve/target_check); `forEachU` (wasm_emit/wasm_reach); `forgedTranscript` (native_doctest/native_test_decls); `freeVarsClauses` (trmc_analysis/wasm_emit); `freeVarsStmts` (trmc_analysis/wasm_emit); `funClauseToClause` (eval/exhaust); `funDefs` (eval/typecheck); `groupArity` (exhaust/llvm_emit); `headBucketKey` (registry/typecheck); `headOr` (effect_authority/lsp); `identEnd` (lexer/lint); `implBody` (llvm_emit/parser); `implHead` (parser/printer); `initializeResultFor` (lsp/mcp); `instantiateFields` (prop_plan/typecheck); `isArithOp` (llvm_emit/wasm_emit); `isCmpOp` (llvm_emit/wasm_emit); `isCommaTok` (lexer/parser); `isCtor` (llvm_emit/wasm_emit); `isElseTok` (lexer/parser); `isEmptyList` (effect_domain/wasm_emit); `isFnBind` (llvm_emit/wasm_emit); `isHint` (annotate/resolve); `isInheritedEntry` (eval/llvm_emit); `isReservedCtor` (private_mangle/wasm_emit); `isSome` (util/wasm_emit); `isThenTok` (lexer/parser); `isUnitLit` (lint/printer); `isWildPat` (core_ir_lower/llvm_emit); `joinSp` (eval/sexp); `lastOf` (effect_domain/resolve); `letBindBodies` (marker/wasm_file_grants); `letBindSites` (core_ir_lower/typecheck); `letGroupDefs` (eval/typecheck); `listLength` (prop_plan/refindex); `locKey` (resolve/typecheck); `localBinding` (resolve/wasm_file_grants); `lookupBinding` (eval/typecheck); `lookupScheme` (doc/repl); `lookupValue` (check_policy/resolve); `mainLines` (native_doctest/native_test_decls); `methodOf` (lsp/mcp); `nativeRendered` (native_doctest/native_test_decls); `notIn` (snapshot/wasm_emit); `numberFrom` (llvm_emit/resolve); `occurrencesOf` (lint_baseline/llvm_emit); `paramEnv` (llvm_emit/wasm_emit); `patBinders` (refindex/wasm_emit); `patVars` (trmc_analysis/wasm_emit); `positionsOf` (core_ir_lower/snapshot); `ppTy` (printer/repr); `probeSource` (native_doctest/native_test_decls); `productAxes` (effect_domain/parser); `programIsCore` (resolve/test_cmd); `ptag` (llvm_emit/wasm_emit); `pureRow` (effect_bindings/typecheck); `quadToParseTriple` (lint_cmd/mcp); `quadToSrc` (lint_cmd/mcp); `qualifiedKey` (check_policy/effect_policy); `rawTestPassed` (test_cmd/test_pins_report); `reachableNames` (dce/lint); `reexportCtorMember` (private_mangle/typecheck); `refGraph` (test_runner/wasm_reach); `refsOf` (dce/lint); `relDiagTriple` (diagnostics/medaka_cli); `renameDecl` (marker/private_mangle); `requiredInt` (eval_props/test_pins); `requiredString` (eval_props/test_pins); `reservedCtorArity` (llvm_emit/wasm_emit); `reservedCtorsOfType` (llvm_emit/wasm_emit); `responseMsg` (lsp/mcp); `runArgSpec` (gate_cmd/medaka_cli); `runInTmp` (native_doctest/native_test_decls); `sameShape` (effect_domain/effect_values); `sanitizeGo` (lint_cache/private_mangle); `scopeFrameStats` (scopes/typecheck); `scopeTraceContext` (scopes/typecheck); `selfBinding` (resolve/typecheck); `sortByKey` (effect_domain/repl); `spaces` (diagnostics/printer); `spineHead` (parser/typecheck); `splitOnChar` (loader/util); `stampArm` (desugar/resolve); `stampBinders` (core_ir_lower/resolve); `stampDecl` (desugar/resolve); `stampExpr` (desugar/resolve); `stampGuardArm` (desugar/resolve); `stampIfaceMethod` (desugar/resolve); `stampImplMethod` (desugar/resolve); `stampLetBind` (desugar/resolve); `startTag` (native_props/native_test_decls); `stmtExprs` (lint/llvm_emit); `stripLine` (gate_cmd/lexer); `stripLines` (gate_cmd/lexer); `stripLocE` (desugar/printer); `substringMatch` (prop_runner/test_cmd); `summaryLine` (gate_cmd/snapshot); `tailList` (core_validate/wasm_emit); `tailStmt` (core_ir_lower/core_validate); `tailStmts` (core_ir_lower/core_validate); `takeFirst` (loader/typecheck); `tokenize` (core_ir_sexp_parse/lexer); `topoValGo` (llvm_emit/wasm_emit); `topoValVisit` (llvm_emit/wasm_emit); `topoValVisitDeps` (llvm_emit/wasm_emit); `tupleCtorName` (exhaust/wasm_emit); `tyAppSpine` (parser/typecheck); `unit` (lsp/mcp); `unitStartsRef` (parser/printer); `unresolvedWhy` (check_policy/effect_policy); `useModuleId` (eval/typecheck); `userValueNames` (marker/resolve); `valueRelName` (llvm_emit/wasm_emit); `variantArity` (core_ir_lower/exhaust); `walkArms` (core_validate/refindex); `walkBinds` (core_validate/refindex); `walkClauses` (core_validate/refindex); `walkDecls` (fmt/refindex); `walkFields` (core_validate/refindex); `walkStmts` (core_validate/refindex); `writeMessage` (lsp/mcp)

### D4 `lookupAssoc` call sites

Command: per file, `grep -vE '^\s*--' F | grep -vE '^lookupAssoc\b' | grep -oE '\blookupAssoc\b' | wc -l` (trailing `--` comments also stripped in the script).

Defined in: support.util. Total call sites (non-comment, excluding definition lines): 194 in 25 modules.

| module | call sites |
|---|---|
| types.typecheck | 85 |
| frontend.resolve | 28 |
| eval.eval | 18 |
| backend.llvm_emit | 8 |
| tools.gate_pack | 7 |
| driver.diagnostics | 5 |
| tools.prop_runner | 4 |
| tools.check_policy | 4 |
| driver.loader | 4 |
| tools.prop_plan | 3 |
| tools.codemod | 3 |
| entries.playground_main | 3 |
| backend.wasm_emit | 3 |
| tools.target_check | 2 |
| tools.lint | 2 |
| tools.doc | 2 |
| ir.core_ir_lower | 2 |
| frontend.parse_cache | 2 |
| frontend.desugar_cache | 2 |
| driver.medaka_cli | 2 |
| types.effect_infer | 1 |
| tools.native_props | 1 |
| support.util | 1 |
| backend.private_mangle | 1 |
| backend.emit_support | 1 |

### D5 `compiler/HELPER-CENSUS.md` headline (240 lines, last touched 2026-09-05)

Its summary table: ~38 generic-helper clusters, 23 duplicated across 2+ files, 6 whose canonical already lives in `support/` but still has local copies, 5 drifted, 28 files defining at least one (from 706 type-filtered candidates).
Status line: PARTIAL; steps 1-2 (OrdMap -> stdlib `Map`, util `reverseL`/`zipL`/`joinWith` -> stdlib) shipped, the section 6 file-by-file dedup plan shows no completion markers, and the headline quadratic `joinWith` finding was re-checked fixed on 2026-07-13.

## E. Design-document sprawl

Command: `python3 -I docs.py <root>`. "status line" = first line matching `**Status:**`/`Status:`. Tags are keyword hits in that line only (approximate: e.g. D3-DEFAULTING's "Nothing ... is implemented" registers as IMPLEMENTED). "refs" = number of other git-tracked files (any extension) whose text contains the filename; `docs/README.md` is the generated doc index and links every doc, so the middle column excludes it. Em-dashes in quoted status lines were replaced with hyphens.

Leading status word tally over the 96 status lines found (99 docs; 3 have none: `JEV-LEDGER.md`, `STYLE.md`, `SYNTAX.md`): IMPLEMENTED 35, PARTIAL 15, OPEN 7, DESIGN 5, SPECIFICATION 4, CURRENT 3, SUPERSEDED 2, SHIPPED 2, and one each of TARGET, REVISED, REVIEWED, RE-DERIVED, PROPOSED, PROPOSAL, PARTLY, PARTIALLY, PARTIAL/IMPLEMENTED, LIVE, FIXED, ENFORCED, DRAFT, DECISION, DECIDED, COMPLETE, CLOSED, ACTIVE, ACCEPTED, plus 4 free-text openings.


#### compiler/*.md (66 files)

| file | lines | status line (first 110 chars) | tags | refs (all) | refs excl. docs/README.md index | refs from non-.md files |
|---|---|---|---|---|---|---|
| AGENTS.md | 264 | **Status:** LIVE. Required reading before editing compiler/; routed to from the root AGENTS.md. | LIVE | 245 | 244 | 131 |
| ARCH-REVIEW.md | 360 | **Status:** PARTIAL - several PASS1/PASS3 recommendations shipped (OCaml `lib/` removal | PARTIAL | 6 | 5 | 0 |
| ARGSTAMP-UNIFY-PLAN.md | 197 | **Status:** IMPLEMENTED - `d01a411a`, 2026-06-14. All phases (0-5) done; eval-vs-emit | IMPLEMENTED | 11 | 10 | 3 |
| BOOTSTRAP.md | 817 | **Status:** IMPLEMENTED - the bootstrap capability this doc describes is real and | IMPLEMENTED | 13 | 12 | 1 |
| COMPOSITE-MAIN-AUTOPRINT-DESIGN.md | 275 | **Status:** IMPLEMENTED on every verb. `build` path (`5cc879dc`/`a92c5a6c`/`cd789d40`, | IMPLEMENTED | 3 | 2 | 1 |
| CONSTRUCT-COVERAGE.md | 969 | **Status:** PARTIAL - actively maintained (last substantive update 2026-07-15). Per its | PARTIAL | 6 | 5 | 2 |
| DIAGNOSTIC-CODES-DESIGN.md | 643 | **Status:** IMPLEMENTED - Stage 1 `ab61283c`, Stage 2 `761516e6`. Both stages landed: | IMPLEMENTED | 36 | 35 | 10 |
| DIAGNOSTICS-SURFACING-PLAN.md | 164 | **Status:** IMPLEMENTED - Stage A `1cbe1e16`, Stage B `dd050106`, Stage C `395a2760` | IMPLEMENTED | 7 | 6 | 0 |
| DISPATCH-GAPS-SCOPE.md | 524 | **Status:** IMPLEMENTED - all four gaps closed, `c1f31ce5` (#55 eval path) / | IMPLEMENTED | 8 | 7 | 1 |
| DISPATCH-INVENTORY.md | 376 | **Status:** PARTIAL - the D0-D3b routing work it documents shipped (consistent with | PARTIAL | 7 | 6 | 1 |
| DRIVER-COLLAPSE-PLAN.md | 139 | **Status:** PARTIALLY IMPLEMENTED - the ENTRY POINTS collapsed (`6874c3f6`, | IMPLEMENTED | 8 | 7 | 1 |
| EAGER-INIT-DESIGN.md | 911 | **Status:** COMPLETE - the shared eager-init hole (#553) and the decided lazy-nullary invariant (#561) are bot |  | 7 | 6 | 2 |
| EFFECTS-ARCHITECTURE.md | 1009 | **Status:** PARTIAL - delivery reconciled 2026-09-29. The data half merged in PR #3445 | PARTIAL | 5 | 4 | 0 |
| EMITTER-ARCH-BUG-FIT.md | 542 | **Status:** RE-DERIVED 2026-09-03 (section 0; F-rows re-derived 2026-10-10 and 2026-10-11) over the 2026-08-07 |  | 5 | 4 | 1 |
| EMITTER-ARCHITECTURE.md | 368 | **Status:** CURRENT - source-derived LLVM/WasmGC emitter map, re-derived 2026-09-03 at `7132909b7` | CURRENT | 2 | 1 | 0 |
| EMITTER-GAPS.md | 1102 | **Status:** PARTIAL - the vast majority of enumerated gaps are marked CLOSED with | PARTIAL | 40 | 39 | 7 |
| EMITTER-TARGET-ARCHITECTURE.md | 1193 | **Status:** REVISED 2026-09-03. The design laws (section 1) are in force; the |  | 7 | 6 | 0 |
| EQ-DISPATCH-DESIGN.md | 365 | **Status:** OPEN - `==`/`/=` are still a builtin structural compare that bypasses the |  | 5 | 4 | 3 |
| ERROR-QUALITY.md | 494 | **Status:** IMPLEMENTED (as a live spec - the rubric/exemplar/copy-standard content is | IMPLEMENTED,LIVE | 40 | 39 | 11 |
| FFI-ABI.md | 489 | **Status:** DECISION, and now LOWERED. This document fixes the value-crossing |  | 32 | 31 | 24 |
| FMT-COMMENT-INTERLEAVING-DESIGN.md | 68 | **Status:** the design below replaced the 2026-07-01 line-index splice |  | 2 | 1 | 0 |
| HELPER-CENSUS.md | 240 | **Status:** PARTIAL - steps 1-2 of the centralization plan shipped (OrdMap→stdlib `Map`; | PARTIAL | 5 | 4 | 2 |
| MESSAGE-AUDIT.md | 434 | **Status:** PARTIAL - this is a read-only proposal, not a tracked plan ("proposes copy | PROPOSAL,PARTIAL | 5 | 4 | 2 |
| MULTICLAUSE-EXHAUST-DESIGN.md | 375 | **Status:** IMPLEMENTED - `f317fef6`, after 2026-07-07. **This header originally said | IMPLEMENTED | 2 | 1 | 0 |
| PARSE-ERROR-LOCATION-DESIGN.md | 343 | **Status:** PARTIAL/IMPLEMENTED - the location half (furthest-failure heuristic) shipped | IMPLEMENTED,PARTIAL | 4 | 3 | 0 |
| PERF-BASELINE.md | 559 | **Status:** the `## Table` section is GENERATED - its content is the stdout of |  | 3 | 2 | 2 |
| PERF-CI-COVERAGE.md | 304 | **Status:** DESIGN - 2026-07-23, tracked in #880 (sub-issues #881-#887). A coverage-gap |  | 2 | 1 | 1 |
| PERF-NOTES.md | 1009 | **Status:** SUPERSEDED BY `compiler/PERF-RESULTS.md` / `archive/design/PERF-SCOPE.md`. This is | SUPERSEDED | 13 | 12 | 4 |
| PERF-RESULTS.md | 1872 | **Status:** PARTIAL - live, actively-updated log, but its own numbers have drifted | PARTIAL,LIVE | 25 | 24 | 7 |
| PERF-RUNTIME.md | 721 | **Status:** IMPLEMENTED - 11 fixpoint-gated native-codegen wins (float unboxing, | IMPLEMENTED | 7 | 6 | 3 |
| PERF-SCOPE.md | 478 | **Status:** IMPLEMENTED - bar-4 executed 2026-06-11; results in `compiler/PERF-RESULTS.md`. | IMPLEMENTED | 16 | 15 | 5 |
| PRE-FLIP-GAPS.md | 193 | **Status:** IMPLEMENTED - all 9 items closed `0836d1e`, 2026-06-12; milestone flip done | IMPLEMENTED | 4 | 3 | 1 |
| PRELUDE-OBJ-DESIGN.md | 398 | **Status:** SHIPPED. Issue #118. `medaka build --emit-prelude-obj <path>` + |  | 2 | 1 | 0 |
| README.md | 1468 | **Status:** IMPLEMENTED / SUPERSEDED-FRAMING - the compiler is fully self-hosting, | SUPERSEDED,IMPLEMENTED | 103 | 102 | 53 |
| REFERENCES-RENAME-DESIGN.md | 427 | **Status:** DESIGN - 87ea0120, 2026-07-23. Forks F1-F6 locked by Val (below); Stage 0 (index-builder) in progr |  | 3 | 2 | 1 |
| REROOT-PLAN.md | 388 | **Status:** IMPLEMENTED - all gates re-rooted off the OCaml oracle by 2026-06-13 | IMPLEMENTED | 11 | 10 | 8 |
| RESOLVER-DIAG-LOCATION-DESIGN.md | 105 | **Status:** IMPLEMENTED - Chunk A `9d6398ad` (R-UNKNOWN-TYPE), Chunk B `2d9138fb` | IMPLEMENTED | 6 | 5 | 1 |
| RUNTIME-DESIGN.md | 839 | **Status:** IMPLEMENTED, with 2 items still deferred. Value representation + calling | IMPLEMENTED | 105 | 104 | 75 |
| RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN.md | 426 | **Status:** IMPLEMENTED - `8f446ff6` (located, coded runtime error text) + | IMPLEMENTED | 7 | 6 | 2 |
| RUNTIME-TRAP-UNIFY-DESIGN.md | 122 | **Status:** OPEN, but the `Array.set`/`Vector.set` OOB row is discharged: `setInPlace` |  | 6 | 5 | 0 |
| S1-CONSTRAINED-SHADOW-DESIGN.md | 560 | **Status:** IMPLEMENTED - `ee0593bd`, 2026-07-14. The fix ships in the same PR as this | IMPLEMENTED | 2 | 1 | 1 |
| SHADOW-INVERSION-DESIGN.md | 628 | **Status:** SHIPPED 2026-07-14 - the inversion is IMPLEMENTED and GATED. The normative | IMPLEMENTED | 5 | 4 | 1 |
| SHARED-FLOAT-RESIDUAL-DESIGN.md | 281 | **Status:** IMPLEMENTED - approach C shipped `f3d4f71d` (C-core) + `27969e7f` (C3 wasm | IMPLEMENTED | 6 | 5 | 0 |
| SOURCE-POSITION-DESIGN.md | 780 | **Status:** DESIGN - 9bda822a, 2026-07-22 (forks F1/F2/F3 locked, see "Decisions" below; F4/F5 default to RECs |  | 3 | 2 | 1 |
| STAGE2-DESIGN.md | 1491 | **Status:** IMPLEMENTED - see the doc's own accurate as-built banner immediately below | IMPLEMENTED | 27 | 26 | 10 |
| TRMC-DESIGN.md | 664 | **Status:** IMPLEMENTED - Phase 1 `#56` (2026-06-11), Phase 3 (dispatch-graph TMC parity | IMPLEMENTED | 23 | 22 | 8 |
| TUPLE-TYPE-CONSTRUCTOR-DESIGN.md | 399 | **Status:** IMPLEMENTED - `a642a43e`/`c00ee2bf`, 2026-07-02 (verified both SHAs exist). | IMPLEMENTED | 6 | 5 | 1 |
| TYPE-ALIAS-EXPANSION-DESIGN.md | 331 | **Status:** IMPLEMENTED - `aa57e3c1`, 2026-06-30 (§10 "AS-BUILT"). Verified live: | IMPLEMENTED,LIVE | 4 | 3 | 1 |
| TYPE-AWARE-LINT-DESIGN.md | 662 | **Status:** PARTLY SHIPPED and RE-COSTED; TIER 1 UNBLOCKED, TIER 2 STILL BLOCKED. Re-derived 2026-08-30 |  | 4 | 3 | 1 |
| TYPE-ERROR-SPAN-DESIGN.md | 108 | **Status:** IMPLEMENTED - Bite 1 `893d9f20` (string-literal span), Bites 2+3 `01f4ee9e` | IMPLEMENTED | 5 | 4 | 1 |
| TYPECHECK-ARCH-BUG-FIT.md | 2407 | **Status:** CURRENT - one row per open `verified` `ws:typecheck` S0/S1 bug, plus an | CURRENT | 2 | 1 | 1 |
| TYPECHECK-ARCHITECTURE.md | 850 | **Status:** CURRENT - derived first-hand from `compiler/types/typecheck.mdk` at `main` | CURRENT | 5 | 4 | 0 |
| TYPECHECK-AUDIT.md | 805 | **Status:** IMPLEMENTED - essentially everything enumerated is marked CLOSED with a date | IMPLEMENTED | 11 | 10 | 2 |
| TYPECHECK-CONTRACTS.md | 236 | **Status:** target architecture, implementation incomplete. Adopted through epic |  | 6 | 5 | 0 |
| TYPECHECK-ERROR-FRAMING-DESIGN.md | 181 | **Status:** IMPLEMENTED - Chunk A `f1705a7f`, Chunk C `29d1644a`, Chunk D `00ca0bfa` | IMPLEMENTED | 3 | 2 | 1 |
| TYPECHECK-SIGNATURE-CONSTRAINT-DESIGN.md | 349 | **Status:** IMPLEMENTED - `9fddb349`, after 2026-07-03. **This header originally said | IMPLEMENTED | 2 | 1 | 0 |
| TYPECHECK-TARGET-ARCHITECTURE.md | 4387 | **Status:** PROPOSAL - the idealized architecture for the full type-system pipeline | PROPOSAL | 36 | 35 | 15 |
| VALUE-RESTRICTION-DESIGN.md | 352 | **Status:** IMPLEMENTED, then AMENDED - do not read §D1/§D3 below as the shipped | IMPLEMENTED | 3 | 2 | 1 |
| WASM-FLOAT-TYPING-DESIGN.md | 280 | **Status:** IMPLEMENTED - stage 1 `b5eb9606`, stage 2 `2d321af6`, 2026-06-30. | IMPLEMENTED | 3 | 2 | 0 |
| WASM-POLY-NUM-DESIGN.md | 280 | **Status:** IMPLEMENTED - approach A, `8afc6137`, 2026-06-30. Verified live in | IMPLEMENTED,LIVE | 2 | 1 | 0 |
| WASM-SELFHOST-GAPS.md | 142 | **Status:** IMPLEMENTED - see the doc's own accurate banner immediately below (gap | IMPLEMENTED | 2 | 1 | 0 |
| WASM-SELFHOST-ROADMAP.md | 216 | **Status:** IMPLEMENTED - census progress 1428 → 0, every category ✅ DONE, in-browser | IMPLEMENTED | 6 | 5 | 1 |
| WASM-TMC-GAP-DESIGN.md | 390 | **Status:** FIXED (Stages 0-2 + 4 landed 2026-07-14; Stage 3 - the (b′) group dict |  | 8 | 7 | 5 |
| WASMGC-DESIGN.md | 505 | **Status:** IMPLEMENTED - compute+print MVP MET (2026-06-19). Slices W1-W9b are done and | IMPLEMENTED | 14 | 13 | 5 |
| WASMGC-TRMC-DESIGN.md | 564 | **Status:** IMPLEMENTED - Stages 0-2 COMPLETE, layer-5 CLOSED (2026-06-22); TMC-parity | IMPLEMENTED | 12 | 11 | 3 |
| WS2-REKEY-DIAGNOSIS.md | 197 | **Status:** PARTIAL - every OBSERVABLE bug found along the way is fixed (fn-level | PARTIAL | 6 | 5 | 1 |

compiler: 66 docs, 40015 lines; status line present in 66 checked; docs referenced by no file other than the generated index: 0; referenced by at most one such file: 10 (EMITTER-ARCHITECTURE.md, FMT-COMMENT-INTERLEAVING-DESIGN.md, MULTICLAUSE-EXHAUST-DESIGN.md, PERF-CI-COVERAGE.md, PRELUDE-OBJ-DESIGN.md, S1-CONSTRAINED-SHADOW-DESIGN.md, TYPECHECK-ARCH-BUG-FIT.md, TYPECHECK-SIGNATURE-CONSTRAINT-DESIGN.md, WASM-POLY-NUM-DESIGN.md, WASM-SELFHOST-GAPS.md). Tag counts (status line only): {'LIVE': 5, 'PARTIAL': 10, 'IMPLEMENTED': 36, 'CURRENT': 3, 'PROPOSAL': 2, 'SUPERSEDED': 2}

#### docs/design/*.md (23 files)

| file | lines | status line (first 110 chars) | tags | refs (all) | refs excl. docs/README.md index | refs from non-.md files |
|---|---|---|---|---|---|---|
| ARGS-DESIGN.md | 262 | **Status:** DECIDED (2026-08-31, reviewed and approved at the `argv-one-parser` phase-1 |  | 11 | 10 | 3 |
| ASYNC-RUNTIME-DESIGN.md | 308 | **Status:** IMPLEMENTED 2026-09-02 (design locked 2026-07-16, amended §0a) - all four stages landed; the stagi | IMPLEMENTED | 12 | 11 | 5 |
| AT-IMPL-PORT-DESIGN.md | 265 | **Status:** SUPERSEDED - **MOOT, do not implement (2026-07-14).** This design selects between | SUPERSEDED | 2 | 1 | 0 |
| ATPROTO-PDS-CONSTANT-TIME.md | 482 | **Status:** implemented and landed for #1724. The successor whole-signing | IMPLEMENTED | 12 | 11 | 6 |
| ATPROTO-PDS-DESIGN.md | 1370 | **Status:** ACTIVE (2026-09-09) - Phases 0-3 are complete in the current tree. | CURRENT | 26 | 25 | 18 |
| ATPROTO-PDS-SIGNING-CONTRACT.md | 483 | **Status:** accepted implementation contract for #1700, prerequisite #1877. No |  | 5 | 4 | 0 |
| BYTES-DESIGN.md | 405 | **Status:** B1, B2 and B3 have all shipped. `stdlib/bytes.mdk` is a `newtype` |  | 3 | 2 | 0 |
| CAPABILITY-EFFECTS.md | 465 | **Status:** PARTIAL - core effect tracking/manifest emission shipped (see below); | PARTIAL | 12 | 11 | 1 |
| CAPABILITY-PLATFORM.md | 769 | **Status:** OPEN - direction / architecture sketch, no code written. What remains: |  | 17 | 16 | 3 |
| D3-DEFAULTING-DESIGN.md | 714 | **Status:** design pass, 2026-10-03/04. Nothing in this document is implemented in | IMPLEMENTED | 2 | 1 | 0 |
| EFFECTS-CONFORMANCE-ROADMAP.md | 354 | **Status:** PARTIAL - WS-1 through WS-4 DONE (see entries below); WS-5 "standing | PARTIAL | 14 | 13 | 3 |
| EFFECTS-ISSUE-ARCHITECTURE-REVIEW.md | 213 | **Status:** REVIEWED - dated architectural assessment, 2026-09-29. |  | 3 | 2 | 0 |
| GAP3-SLICE7-DESIGN.md | 287 | **Status:** OPEN - decided WON'T-SCHEDULE. Both re-diagnosed FACE 1/FACE 2 bugs |  | 4 | 3 | 0 |
| GZIP-DESIGN.md | 532 | **Status:** PARTIAL - Phases 1-4 shipped (`gzip/`): stored + fixed-Huffman + | PARTIAL | 12 | 11 | 9 |
| INTEGER-TYPES-DESIGN.md | 595 | Status: N1 BUILT (the tagged tier: `U8`/`U16`/`U32`, their modules, the literal |  | 19 | 18 | 6 |
| INTERFACE-CANDIDATES.md | 230 | **Status:** PARTIAL - `++`→`Semigroup` (§1, "do first") shipped `05c517b1`, | PARTIAL | 2 | 1 | 0 |
| JEV-DESIGN.md | 782 | **Status:** PROPOSED, 2026-09-16. The census half is built (`scripts/jev/`); |  | 9 | 8 | 3 |
| JEV-LEDGER.md | 164 |  |  | 4 | 3 | 0 |
| LANGUAGE-SURFACE-AUDIT.md | 151 | **Status:** OPEN - recommends; nothing here has been executed. The one "clean |  | 2 | 1 | 0 |
| MUT-SCOPING-DESIGN.md | 241 | **Status:** CLOSED - superseded 2026-07-14. The `mut` masking-block proposal below | SUPERSEDED,PROPOSAL | 4 | 3 | 0 |
| REGEX-DESIGN.md | 415 | Status: DESIGN, 2026-09-11. Nothing built. Tracking: #435 lists `regex` as a |  | 4 | 3 | 3 |
| TARGETS-DESIGN.md | 566 | **Status:** OPEN - ratified 2026-10-01, nothing built. Epic #3661; milestones |  | 9 | 8 | 4 |
| WASM-ASYNC-DESIGN.md | 640 | **Status:** PARTIAL - WA-1 to WA-4 are implemented by sprint the-browser-can-wait | IMPLEMENTED,PARTIAL | 3 | 2 | 1 |

docs/design: 23 docs, 10693 lines; status line present in 23 checked; docs referenced by no file other than the generated index: 0; referenced by at most one such file: 4 (AT-IMPL-PORT-DESIGN.md, D3-DEFAULTING-DESIGN.md, INTERFACE-CANDIDATES.md, LANGUAGE-SURFACE-AUDIT.md). Tag counts (status line only): {'IMPLEMENTED': 4, 'SUPERSEDED': 2, 'CURRENT': 1, 'PARTIAL': 5, 'PROPOSAL': 1}

#### docs/spec/*.md (10 files)

| file | lines | status line (first 110 chars) | tags | refs (all) | refs excl. docs/README.md index | refs from non-.md files |
|---|---|---|---|---|---|---|
| DICT-SEMANTICS.md | 3340 | **Status:** specification (theory-first). **Scope:** the elaboration of |  | 52 | 51 | 21 |
| EFFECTS-SEMANTICS.md | 1627 | **Status:** specification (theory-first, *idealized*). **Scope:** the typing, |  | 83 | 82 | 47 |
| EMITTER-SEMANTICS.md | 498 | **Status:** specification (theory-first). **Scope:** what it means for the LLVM |  | 14 | 13 | 3 |
| HM-CORE-SEMANTICS.md | 142 | **Status:** DRAFT - §1 is normative and enforced (2026-09-02); §2-§6 are owed by | DRAFT | 4 | 3 | 0 |
| LAYOUT-SEMANTICS.md | 618 | **Status:** OPEN (living spec) - idealized formal specification + conformance |  | 22 | 21 | 6 |
| SHADOW-SEMANTICS.md | 2468 | **Status:** ENFORCED - the decision matrix is a GATE |  | 61 | 60 | 38 |
| STYLE.md | 379 |  |  | 6 | 5 | 2 |
| SYNTAX.md | 1451 |  |  | 69 | 68 | 14 |
| WASM-SEMANTICS.md | 530 | **Status:** specification (supplement). **Scope:** the two things |  | 18 | 17 | 8 |
| language-design.md | 1239 | **Status:** PARTIAL - design rationale/philosophy (mostly current), plus an | CURRENT,PARTIAL | 23 | 22 | 7 |

docs/spec: 10 docs, 12292 lines; status line present in 10 checked; docs referenced by no file other than the generated index: 0; referenced by at most one such file: 0 (). Tag counts (status line only): {'DRAFT': 1, 'CURRENT': 1, 'PARTIAL': 1}

Totals: compiler/*.md 66 files, 40,015 lines (includes `AGENTS.md` and `README.md`); docs/design 23 files, 10,693 lines; docs/spec 10 files, 12,292 lines; all three 99 files, 63,000 lines. compiler/*.md docs referenced by no file other than the generated index: 0; by at most one: 10 (listed above), plus 4 in docs/design.

## F. Commit archaeology in source

Command: `python3 -I census.py <root> F`. Equivalents for one file:

```sh
grep -cE '^\s*--.*#[0-9]{2,5}\b' F                      # comment lines citing an issue/PR
grep -E '^\s*--' F | grep -oE '#[0-9]{2,5}\b' | sort -u | wc -l   # distinct numbers
grep -cE '[─━═]{3,}' F                                   # banner lines
grep -cE '^\s*--.*20[0-9][0-9]-[0-9][0-9]' F             # dated comment lines
grep -ciE '\b(legacy|compat|compatibility|deprecated|retired|historical)\b|\bTODO\b|\bFIXME\b|\bHACK\b' F
```

`any_word` counts lines with at least one of the listed words (case-insensitive); the `w_*` rows count each word separately (`compat` excludes `compatib...`; TODO/FIXME/HACK case-sensitive). Word counts are over all lines, not only comments.

| measure | typecheck.mdk | all other non-test modules |
|---|---|---|
| lines | 57032 | 150651 |
| comment | 22695 | 40110 |
| issue_comment_lines | 1445 | 1583 |
| banners | 156 | 947 |
| dated | 40 | 42 |
| any_word | 157 | 94 |
| w_legacy | 18 | 4 |
| w_compat | 0 | 5 |
| w_compatibility | 21 | 6 |
| w_deprecated | 0 | 14 |
| w_retired | 101 | 40 |
| w_historical | 16 | 21 |
| w_TODO | 1 | 3 |
| w_FIXME | 0 | 0 |
| w_HACK | 0 | 0 |
| distinct issue numbers in comments | 304 | 492 |
| issue-ref comment lines per 1k lines | 25.3 | 10.5 |

## G. Encapsulation

Command: `python3 -I census.py <root> G`. Export detection was validated against every selective import list in the compiler: 1,588 of 1,590 imported (target, name) pairs are found in the target's detected export set (the 2 misses are an `export import` re-export). "names (+data)" = distinct top-level names plus `data` types; exported = `export` + following declaration, `export type`, `export data`, `public export data`.

Total exported names (values + types + data, non-test): 2076 of 14986 top-level names+data (13.9%).

Excluding entries/: 2004 exported of 14428.

Top 10 by exported count:

| module | top-level names (+data) | exported | fraction | importers |
|---|---|---|---|---|
| frontend.ast | 144 | 118 | 0.82 | 107 |
| eval.eval | 575 | 105 | 0.18 | 27 |
| driver.diagnostics | 178 | 96 | 0.54 | 16 |
| types.typecheck | 3562 | 96 | 0.03 | 35 |
| backend.trmc_analysis | 117 | 70 | 0.60 | 4 |
| types.registry | 125 | 70 | 0.56 | 1 |
| tools.prop_plan | 182 | 59 | 0.32 | 4 |
| backend.wasm_preamble | 81 | 54 | 0.67 | 1 |
| tools.lint | 776 | 48 | 0.06 | 9 |
| types.repr | 55 | 48 | 0.87 | 19 |

Exported fraction over modules with >=10 names: median 0.22; modules with fraction >= 0.9: 3 of 98; with fraction <= 0.2: 48.

Modules whose exports are imported by the most other modules (= in-degree):
- frontend.ast: 107 importers, 118 exports
- support.util: 93 importers, 47 exports
- frontend.parser: 55 importers, 36 exports
- frontend.desugar: 48 importers, 13 exports
- support.ordmap: 35 importers, 11 exports

Exports never imported (`python3 -I impnames.py <root>`; selective import lists only, so names reached through the 18 qualified `import X as M` lines are undercounted as used): of 2,004 exports in non-entries modules, 479 are imported by no non-test module and 303 by no module at all including `*_test.mdk`. Largest counts of never-imported exports (incl. tests): backend.trmc_analysis 35 of 70, eval.eval 20 of 105, eval.u64_halves 19 of 19, driver.diagnostics 17 of 96, ir.core_ir_sexp 16 of 20, types.registry 13 of 70, tools.gate_cmd 11 of 18, tools.lint 11 of 48, types.typecheck 8 of 96, driver.build_cmd 8 of 26.

Most-imported individual names (number of importing non-test modules): `frontend.ast.Decl` 84, `support.util.reverseL` 42, `frontend.desugar.desugar` 41, `support.util.listLen` 39, `frontend.parser.parse` 38, `support.util.joinWith` 36, `support.util.filterList` 36, `frontend.ast.Pat` 36, `frontend.ast.Loc` 36, `support.ordmap.OrdMap` 35, `support.ordmap.omEmpty` 34.

## H. Entries and gates

Command: `python3 -I ent.py <root>`; plus `grep -c '^\[\[gate\]\]' test/gates.toml`.

| measure | count |
|---|---|
| `compiler/entries/*.mdk` (non-test) | 67 (0 `_test` siblings) |
| `test/gates.toml` `[[gate]]` rows | 207 (plus 8 `[[shard]]` rows) |
| gate rows by `migration` | done 113, native-rewrite 27, shell:trust-anchor 26, split-first 11, shell:instrumentation 11, inverted-polarity 7, shell:external-harness 7, blocked:detached-process 2, native-wrap 1, blocked:concurrent-spawn 1, blocked:interactive-handle 1 |
| `test/*.sh` (top level) | 108 |
| `test/**/*.sh` | 128 |
| `test/**/*_test.mdk` | 77 |
| `compiler/**/*_test.mdk` | 77 |
| entries whose base name appears nowhere in `test/`, `Makefile`, `scripts/`, `.github/` | 0 |

Entries import graph: 67 entry modules have 413 outgoing edges; 79 incoming edges, all from other entries (`entries.entry_support` alone has 32 importers). 19 entries have in-degree 0 (top-level programs).

## I. Growth

Command: `python3 -I growth.py <root>` (runs `git rev-list -1 --before=<date> origin/main`, `git show <sha>:<path>`, `git ls-tree`, `git cat-file --batch`; all read-only). Note: on two runs, `rev-list -1 --before` returned different SHAs for 2026-07-01 (`178632867` then `cb648fc2a`) and 2026-09-01 (`bcea01bfb` then `4881bd3e1`) with identical line counts; the table is from the second run. Before 2026-06-26 the tree was `selfhost/` (flat until about 2026-06-10, then with subdirectories); on 2026-06-01 neither existed.

| date | sha | typecheck.mdk | llvm_emit.mdk | wasm_emit.mdk | resolve.mdk | lint.mdk | compiler/*.md docs | non-test compiler .mdk files | non-test compiler .mdk lines |
|---|---|---|---|---|---|---|---|---|---|
| 2026-06-01 | c7c6d5782 | absent | absent | absent | absent | absent | 0 | 0 | 0 |
| 2026-07-01 | cb648fc2a | 10925 | 8854 | 7603 | 1708 | 1049 | 33 | 114 | 60222 |
| 2026-08-01 | df5d53c11 | 19885 | 11134 | 9321 | 3570 | 4133 | 59 | 121 | 95705 |
| 2026-09-01 | 4881bd3e1 | 38963 | 12370 | 9745 | 4564 | 4811 | 64 | 139 | 139076 |
| 2026-10-01 | 8de9bef1f | 53048 | 15891 | 12854 | 6624 | 6954 | 66 | 160 | 186374 |
| HEAD (origin/main) | 48e36f797 | 57032 | 15283 | 12286 | 7075 | 7227 | 66 | 170 | 207683 |
| worktree HEAD | 48e36f797 | 57032 | 15283 | 12286 | 7075 | 7227 | 66 | 170 | 207683 |

Pre-rename data points (`selfhost/`, probed with `mid.py`): 2026-06-10 (`8a4ab3e6d`, 96 `.mdk` files): typecheck 5,948, llvm_emit 5,471, resolve 1,215, wasm_emit absent. 2026-06-20 (`1dcd17ea3`, 107 files): typecheck 8,539, llvm_emit 8,400, wasm_emit 3,939, resolve 1,381. On 2026-06-01 the OCaml `lib/typecheck.ml` was 3,956 lines.

## Appendix: per-module table (non-entries; lines, import degree, exports, Ref cells)

`export type` aliases count as exports but not as names, so the fraction can exceed 1 (`support.ordmap`).

| module | lines | out-deg | in-deg | top-level names (+data) | exported | exp. fraction | Ref cells |
|---|---|---|---|---|---|---|---|
| backend.core_validate | 1331 | 10 | 13 | 121 | 34 | 0.28 | 1 |
| backend.emit_plan | 256 | 8 | 13 | 24 | 8 | 0.33 | 0 |
| backend.emit_support | 687 | 6 | 3 | 53 | 14 | 0.26 | 0 |
| backend.extern_catalog | 1337 | 1 | 3 | 28 | 22 | 0.79 | 0 |
| backend.llvm_emit | 15283 | 15 | 6 | 885 | 10 | 0.01 | 0 |
| backend.llvm_preamble | 240 | 0 | 1 | 1 | 1 | 1.00 | 0 |
| backend.private_mangle | 1933 | 4 | 18 | 135 | 12 | 0.09 | 0 |
| backend.trmc_analysis | 1709 | 4 | 4 | 117 | 70 | 0.60 | 0 |
| backend.wasm_emit | 12286 | 14 | 8 | 705 | 12 | 0.02 | 0 |
| backend.wasm_file_grants | 979 | 7 | 2 | 61 | 1 | 0.02 | 0 |
| backend.wasm_preamble | 2537 | 0 | 1 | 81 | 54 | 0.67 | 0 |
| backend.wasm_reach | 281 | 3 | 1 | 22 | 1 | 0.05 | 0 |
| driver.build_cmd | 2098 | 8 | 7 | 100 | 26 | 0.26 | 0 |
| driver.diagnostics | 3126 | 17 | 16 | 178 | 96 | 0.54 | 3 |
| driver.loader | 1542 | 3 | 25 | 96 | 33 | 0.34 | 1 |
| driver.main_autoprint | 363 | 2 | 7 | 25 | 9 | 0.36 | 0 |
| driver.medaka_cli | 4759 | 39 | 0 | 190 | 0 | 0.00 | 0 |
| eval.eval | 5523 | 9 | 27 | 575 | 105 | 0.18 | 16 |
| eval.u64_halves | 227 | 0 | 1 | 29 | 19 | 0.66 | 0 |
| frontend.ast | 2622 | 0 | 107 | 144 | 118 | 0.82 | 0 |
| frontend.desugar | 1297 | 3 | 48 | 146 | 13 | 0.09 | 1 |
| frontend.desugar_cache | 73 | 4 | 6 | 7 | 2 | 0.29 | 2 |
| frontend.exhaust | 1180 | 3 | 7 | 131 | 16 | 0.12 | 0 |
| frontend.lexer | 3146 | 2 | 17 | 236 | 17 | 0.07 | 0 |
| frontend.marker | 586 | 4 | 10 | 65 | 8 | 0.12 | 0 |
| frontend.parse_cache | 89 | 3 | 4 | 6 | 3 | 0.50 | 1 |
| frontend.parser | 6783 | 4 | 55 | 721 | 36 | 0.05 | 8 |
| frontend.resolve | 7075 | 4 | 14 | 514 | 41 | 0.08 | 3 |
| ir.core_ir | 677 | 3 | 16 | 48 | 35 | 0.73 | 0 |
| ir.core_ir_eval | 796 | 8 | 9 | 56 | 8 | 0.14 | 0 |
| ir.core_ir_lower | 3983 | 11 | 24 | 361 | 41 | 0.11 | 0 |
| ir.core_ir_sexp | 439 | 5 | 5 | 32 | 20 | 0.62 | 0 |
| ir.core_ir_sexp_parse | 585 | 4 | 1 | 54 | 3 | 0.06 | 0 |
| ir.dce | 192 | 2 | 6 | 12 | 1 | 0.08 | 0 |
| ir.sexp | 407 | 2 | 6 | 42 | 8 | 0.19 | 0 |
| support.char | 65 | 0 | 9 | 15 | 15 | 1.00 | 0 |
| support.cli_targets | 83 | 1 | 2 | 8 | 3 | 0.38 | 0 |
| support.manifest | 123 | 0 | 1 | 7 | 6 | 0.86 | 0 |
| support.opcount | 64 | 0 | 7 | 5 | 3 | 0.60 | 2 |
| support.ordmap | 71 | 0 | 35 | 10 | 11 | 1.10 | 0 |
| support.path | 73 | 0 | 19 | 10 | 7 | 0.70 | 0 |
| support.scc | 88 | 2 | 3 | 15 | 1 | 0.07 | 6 |
| support.timer | 245 | 0 | 9 | 23 | 17 | 0.74 | 3 |
| support.util | 670 | 3 | 93 | 72 | 47 | 0.65 | 0 |
| tools.check | 205 | 9 | 3 | 10 | 5 | 0.50 | 0 |
| tools.check_policy | 623 | 14 | 4 | 54 | 12 | 0.22 | 0 |
| tools.codemod | 316 | 5 | 2 | 31 | 11 | 0.35 | 0 |
| tools.doc | 1855 | 10 | 1 | 168 | 11 | 0.07 | 0 |
| tools.doctest | 524 | 5 | 10 | 62 | 23 | 0.37 | 0 |
| tools.eval_props | 234 | 3 | 2 | 25 | 9 | 0.36 | 0 |
| tools.fmt | 786 | 5 | 6 | 72 | 5 | 0.07 | 0 |
| tools.gate_cmd | 3769 | 7 | 1 | 325 | 18 | 0.06 | 0 |
| tools.gate_cost | 724 | 1 | 3 | 44 | 15 | 0.34 | 0 |
| tools.gate_pack | 2817 | 3 | 1 | 191 | 4 | 0.02 | 0 |
| tools.gate_registry | 644 | 2 | 2 | 40 | 17 | 0.42 | 0 |
| tools.lint | 7227 | 12 | 9 | 776 | 48 | 0.06 | 0 |
| tools.lint_baseline | 284 | 3 | 2 | 32 | 18 | 0.56 | 0 |
| tools.lint_cache | 480 | 5 | 2 | 45 | 9 | 0.20 | 0 |
| tools.lint_cmd | 610 | 9 | 1 | 29 | 10 | 0.34 | 0 |
| tools.lsp | 2182 | 13 | 3 | 165 | 12 | 0.07 | 2 |
| tools.lsp_harness | 463 | 1 | 1 | 49 | 29 | 0.59 | 1 |
| tools.mcp | 1860 | 14 | 1 | 107 | 3 | 0.03 | 0 |
| tools.native_doctest | 466 | 7 | 2 | 25 | 1 | 0.04 | 0 |
| tools.native_props | 2136 | 11 | 1 | 183 | 3 | 0.02 | 0 |
| tools.native_test_decls | 443 | 8 | 1 | 34 | 1 | 0.03 | 0 |
| tools.new_cmd | 67 | 0 | 2 | 8 | 1 | 0.12 | 0 |
| tools.printer | 2681 | 3 | 7 | 278 | 18 | 0.06 | 8 |
| tools.probe_transcript | 360 | 3 | 5 | 32 | 20 | 0.62 | 1 |
| tools.prop_helpers | 120 | 5 | 1 | 11 | 2 | 0.18 | 0 |
| tools.prop_plan | 1691 | 4 | 4 | 182 | 59 | 0.32 | 0 |
| tools.prop_runner | 1756 | 5 | 7 | 161 | 35 | 0.22 | 5 |
| tools.refindex | 1896 | 6 | 2 | 176 | 12 | 0.07 | 2 |
| tools.repl | 465 | 10 | 2 | 47 | 4 | 0.09 | 6 |
| tools.snapshot | 1476 | 20 | 1 | 131 | 8 | 0.06 | 0 |
| tools.target_check | 138 | 8 | 3 | 11 | 2 | 0.18 | 0 |
| tools.target_parse | 73 | 5 | 3 | 7 | 4 | 0.57 | 2 |
| tools.test_cmd | 4225 | 29 | 3 | 224 | 22 | 0.10 | 1 |
| tools.test_pins | 523 | 2 | 3 | 61 | 14 | 0.23 | 0 |
| tools.test_pins_io | 101 | 4 | 1 | 7 | 2 | 0.29 | 0 |
| tools.test_pins_report | 178 | 3 | 2 | 28 | 20 | 0.71 | 0 |
| tools.test_runner | 236 | 6 | 1 | 20 | 7 | 0.35 | 0 |
| types.annotate | 328 | 2 | 10 | 27 | 1 | 0.04 | 0 |
| types.disposition | 294 | 4 | 6 | 31 | 25 | 0.81 | 1 |
| types.effect_authority | 533 | 2 | 8 | 59 | 33 | 0.56 | 0 |
| types.effect_bindings | 57 | 2 | 1 | 6 | 4 | 0.67 | 0 |
| types.effect_domain | 887 | 1 | 7 | 98 | 34 | 0.35 | 0 |
| types.effect_infer | 332 | 6 | 1 | 29 | 5 | 0.17 | 0 |
| types.effect_invocation | 153 | 3 | 3 | 15 | 3 | 0.20 | 0 |
| types.effect_policy | 345 | 8 | 2 | 36 | 12 | 0.33 | 0 |
| types.effect_rows | 437 | 6 | 11 | 62 | 36 | 0.58 | 0 |
| types.effect_solver | 1668 | 4 | 1 | 99 | 19 | 0.19 | 0 |
| types.effect_values | 266 | 5 | 1 | 32 | 5 | 0.16 | 0 |
| types.evidence | 62 | 2 | 3 | 8 | 8 | 1.00 | 0 |
| types.evidence_complete | 273 | 2 | 1 | 32 | 11 | 0.34 | 0 |
| types.registry | 1662 | 4 | 1 | 125 | 70 | 0.56 | 0 |
| types.repr | 829 | 5 | 19 | 55 | 48 | 0.87 | 0 |
| types.route_key | 631 | 3 | 9 | 34 | 13 | 0.38 | 1 |
| types.runtime_types | 252 | 2 | 10 | 19 | 15 | 0.79 | 1 |
| types.scopes | 197 | 3 | 2 | 24 | 22 | 0.92 | 0 |
| types.solver_contract | 197 | 4 | 1 | 18 | 15 | 0.83 | 0 |
| types.superclass | 139 | 3 | 1 | 11 | 6 | 0.55 | 0 |
| types.target_profile | 240 | 3 | 8 | 29 | 22 | 0.76 | 1 |
| types.typecheck | 57032 | 29 | 35 | 3562 | 96 | 0.03 | 26 |
