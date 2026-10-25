# types/ — type inference, interfaces, effects and the facts downstream stages read

**Status:** CURRENT — re-derived from source at e6ed1546a6ab399d084f40fb118c294fc36dfdef on 2026-10-15. When it drifts, re-derive; do not patch.

## What this directory is
Stage five of the pipeline (`ARCHITECTURE.md` section 1), layer `types` in A1: above `frontend/`,
below `ir/`. It consumes the resolved AST and produces the dict-passing-elaborated program plus
the side tables `ir/`, `eval/` and `backend/` read (dispositions, runtime types, route words).
One module, `typecheck.mdk`, still holds the inference core; the rest are the modules extracted from it.

## Parts
| Module | Owns | Entry points |
|---|---|---|
| `tc_types.mdk` | The typechecker's data declarations and state records (`ModuleCtx`, `GroupCtx`, `GraphCtx`, `GraphRun`, `CrossRun`, `DynCtx`, `SiteCtx`) | none |
| `typecheck.mdk` | Hindley-Milner inference, constraint solving, dict-passing elaboration, coherence, the effect-row checker's wiring; described in `TYPECHECK-ARCHITECTURE.md` | `elaborateOne`, `grantWholeDomain` |
| `publish.mdk` | The published shapes (`TcReport`, `CheckedProgram`, `PubScheme`, `TcDiag`, `ModDiags`), the deep zonk and freeze-by-copy over them, and the live-cell validator; imports no typechecker state | `freezePub`, `liveCells` |
| `entry_outcome.mdk` | The checked `main` shape facts and `EntryOutcome` construction published at graph-drive completion | `entryOutcomeNow`, `mainIsUnitNow` |
| `prelude_interface.mdk` | The prelude interface value (`PreludeInterface`: what a drive needs from the prelude's core pass), its process cache (`preludeCacheRef`, one entry per compiler generation), freeze and thaw, and the on-disk key (`InterfaceKey`) | `seedPreludeInterface`, `currentPreludeInterface`, `preludeCacheHit`, `freezeInterface`, `thawInterface`, `interfaceKeyOf` |
| `prelude_elab.mdk` | The prelude's elaborated trees as a value (`PreludeElab`: dict-passed declarations, the evidence rows they reference, binder rows, id counters), its file (`core.mdke`, digest checked before decode) and its one process cache (`preludeElabCacheRef`); imports `prelude_interface`, `interface_sexp`, `runtime_types`, `evidence_coverage` and `frontend.ast_codec`, never `typecheck`; its header, digest and binder-span framing (`framedHeader`, `checkedFramed`, `binderSpan`) is shared with `prelude_decls` | `preludeElabOf`, `encodeElabFile`, `readElabFile`, `seedPreludeElab`, `preludeElabHit`, `elabKeyOf` |
| `prelude_decls.mdk` | The prelude's desugared declarations as a value (`PreludeDecls`: the runtime and core trees with the binder run each mints) and its file (`core.mdkd`, digest checked before decode); imports `frontend.ast_codec`, `interface_sexp`, `prelude_elab`'s framing and `prelude_interface`, never `typecheck` | `preludeDeclsOf`, `encodeDeclsFile`, `readDeclsFile`, `readDeclsKey`, `decodeDeclsBody`, `declsKeyOf` |
| `interface_sexp.mdk` | The interface codec: the s-expression form of the prelude interface and of every scheme-level type it holds, and the file around it (header with format version, sources and compiler, then the sections, each a join list and an interface); decoding fails closed | `encodeInterface`, `decodeInterface`, `mergeSections`, `sectionsOfCache`, `formatVersion` |
| `interface_frame.mdk` | The framing every on-disk interface file shares (`.mdki`, `.mdke`, `.mdkd` and module files): one header line with tag, version, key fields and digest, then the body the SHA-256 digest covers; the key is read and gated before the body is hashed or decoded | `framedFile`, `openFramed`, `checkedFramed`, `verifyDigest`, `InterfaceFault` |
| `module_interface.mdk` | One module's checked diagnostics-arm contribution as a frozen, Decl-free value (`ModuleInterface`), its key (`ModuleKey`: module, source, import identities, graph key), its replay into a graph (`applyModuleInterface`) and the one process cache, one interface per module id | `freezeModuleInterface`, `applyModuleInterface`, `moduleCacheHit`, `recordModuleInterface`, `moduleInterfaceIdentity` |
| `module_interface_sexp.mdk` | `ModuleInterface` as a file: a framed header carrying the whole `ModuleKey`, then join-tagged sections; the reader refuses a stale key before the digest and fails closed on a lying digest, torn text or other version; not yet wired to a CLI verb | `encodeModuleSections`, `decodeModuleSections`, `decodeModuleInterface`, `readModuleKey`, `moduleFormatVersion` |
| `evidence_coverage.mdk` | The evidence coverage validator: every minted site in a program's trees answered once, in the shape its reader accepts, and no ordinal published twice; a pure walk over `Decl`s and an `EvTable` | `evidenceFaults`, `EvidenceFault` |
| `repr.mdk` | The type representation (`Mono`, union-find `Tyvar`, `Scheme`) and every renderer over it; reads no typechecker state cell | `normalize`, `ppMono` |
| `registry.mdk` | Identity and registry substrate the per-table re-keying units build on | `identKey`, `tabKeys` |
| `evidence.mdk` | Request-owned nominal identities for goals, scopes, binders, instances, destinations | `EvidenceBinderId`, `ScopeId` |
| `scopes.mdk` | Nominal lexical scope storage for one typechecking graph | `DefaultBodyIdentity` |
| `solver_contract.mdk` | Request-local contracts for scoped class solving and scheme instantiation; no inference state | `InstantiationServices` |
| `superclass.mdk` | The superclass closure over declared `requires` clauses, parameterised by reader | superclass walk |
| `evidence_complete.mdk` | The completeness judgment: does every dispatch destination name an instance or a given | `EvidenceRow` predicate |
| `disposition.mdk` | Whole-graph table of which method each impl supplies or inherits from the default; importable by `ir/`, `eval/`, `backend/` without `typecheck.mdk` | `dispositionLookup`, `buildDispositionTable` |
| `route_key.mdk` | The only mint of an impl route word | `evMethodRoutesIn`, `numIntWord` |
| `program_facts.mdk` | Leaf: the evidence index, dispositions and binder table of one typechecked program as a value, and the run-owned cell a bracket sets | `withFacts`, `factsNow` |
| `chain_key.mdk` | The part of the module-chain memo key a step reads from modules outside its prefix: instance heads, interface declarations and constrained signature names | `chainGraphKey` |
| `runtime_types.mdk` | What each source binder holds at run time, keyed by `BinderId`, materialized after the drain | `RuntimeType`, `BinderRow` |
| `annotate.mdk` | Lexical-addressing emission pass: variable references to addressed references, right before eval | `annotateProgram` |
| `private_mangle.mdk` | Universal per-module name mangling for the flat multi-module emit path | `mangledName`, `hashName`, `injectiveIdent` |
| `target_profile.mdk` | The one table of target profiles: backend, host ABI, effect grant set | `lookupProfile` |
| `effect_domain.mdk` | Concrete authority domains: the lattice each effect label's parameter is drawn from | `Param` |
| `effect_authority.mdk` | Authority terms: concrete element, scoped variable, or join | `Authority`, `authJoin` |
| `effect_rows.mdk` | Effect atoms and rows: label map plus optional tail | `EffRow` |
| `effect_values.mdk` | Produced values joining at positive positions | effect value joins |
| `effect_bindings.mdk` | Per-binding effect ownership by syntactic arity | `BindingSummary` |
| `effect_infer.mdk` | Scoped collection of performed rows; no solving | `collectRows` consumers |
| `effect_solver.mdk` | Binding-owned effect equations solved by worklist | effect solver |
| `effect_invocation.mdk` | The effects a host can make an entry perform | invocation summary |
| `effect_policy.mdk` | Does an entry's invocation summary fit a policy | `policyRefusals`, `viaChain` |

## Cell lifetimes
`CELL-LIFETIMES.md` lists every typechecker cell (the 3 module-level cells of `types.typecheck`: `interners` and the two memos, and the 197 fields of
`ModuleCtx` 3 (`mcCells`, `mcGraph`, `mcLoc`), `ModuleCells` 91, `GroupCtx` 2, `GraphCtx` 19, `GraphRun` 30, `CrossRun` 14, `Interners` 2, `Lineage` 3, `TcConfig` 5, `DriveInputs` 7, `TraceSink` 8, `DynCtx` 10, `SiteCtx` 3) with its measured lifetime, target home and whether
an interface load would have to fill it. Lifetimes (208 rows, the 200 in the first table and the 8 outside it): process 18, config 16, graph 65, module 83, group 3, run 23. The prelude interface cache (`preludeCacheRef`, `types.prelude_interface`) is one of the eight outside rows, as are `preludeElabCacheRef` (`types.prelude_elab`) and the evidence segment `preludeEvidenceRef` (`types.route_key`); each is process-lifetime and reset never. `ModuleCtx.mcLoc` is a scoped value, not a cell: a construct hands its sub-walk an updated copy of the record, and the diagnostic location is the span of the innermost enclosing construct. Its "Interface fills" section names the producer and kind of each row playbook C1 restores.
The per-module cell counts are in `test/arch_goldens/cells.golden`.

## The prelude interface
The prelude's core pass is a value, `PreludeInterface` (`prelude_interface.mdk`), cached once per compiler generation. `interface_sexp.mdk` encodes it to `stdlib/core.mdki`; `medaka interface write|show|verify` writes, prints and checks the file, and `make medaka` and CI's `setup-medaka` rewrite it. The check family, `doc`, `lsp`, `mcp` and `test` read it through `loadPreludeInterface` (`driver/build_cmd.mdk`) when the file's header (format version, source hashes, compiler fingerprint) matches, and seed the cache instead of running the core pass. A stale or undecodable file falls back to the core pass; `check` and the servers say so on stderr (`check --json` prints the line on stderr too, not in the envelope; `run --json` is silent), and `MEDAKA_STRICT=1` makes that exit 1. `MEDAKA_NO_INTERFACE=1` turns the load off.

## The prelude's elaborated trees
The tree arm (`GOutTrees`; `run`, the emitter child, `medaka test`'s eval drives) needs core's dict-passed `Decl`s, which an interface does not hold. `prelude_elab.mdk` holds them as a value (`PreludeElab`), cached once per compiler generation, and `interface write` writes them to `stdlib/core.mdke` beside `core.mdki` (same key components, its own format tag and digest). `graphPreamble` hits when the drive carries a prelude key (`DriveInputs.diPreludeKey`), and both the interface for its join and the elaborated value are cached for that key: it then skips `elabModuleStamp` on core, continues from `continueFromInterface`, and publishes core's evidence and binder rows merged with the drive's. Otherwise it elaborates core as before. The diags arm never reads the file. Ids cross the file by rule: `EvId` ordinals and `$k$lb` names restore the writer's counters before any mint, `BinderId` ordinals relocate by one offset at load, and the evidence index keeps a process-wide prelude segment (`types/route_key.mdk`) so a drive's dense array spans only its own ordinals. `loadPreludeElab` (`driver/build_cmd.mdk`) judges the file; the verb's own process prints `prelude trees stale: …` once (an emitter child never does), and `MEDAKA_NO_INTERFACE=1` disables both files.

## Laws that bind it
- **A1** — types imports `frontend/` and `support/`; `ir/` and `eval/` must reach its facts through `disposition`, `runtime_types` and `route_key`, not `typecheck.mdk`.
- **A2, A3** — `typecheck.mdk` still writes routes into cells and keeps module-level state; extracted modules should publish values and own no global cell.
- **A5** — diagnostics are data; errors accumulate and inference does not read the accumulator as control.
- **A6** — `support.hooks` is never imported inside inference; `test/arch_boundaries_test.mdk` holds an allowlist.
- **A8 and D1** — a new concern is a new module here. `typecheck.mdk` may not grow in any PR, unless a commit carries the trailer `Arch-Growth-Override:`. The current floor is informational, read from the ratchet, not a law.
- **A4** — route words come from `route_key.mdk` only.

## Boundaries and checks
- `test/arch_boundaries_test.mdk`: layering, cells, hooks allowlist, import closures.
- `test/arch_goldens/closure.types.repr.golden` (closure of `repr.mdk`), `cells.golden`, `layering.golden`, `hooks.golden`.
- `test/arch_ratchet.sh`: growth ratchet for `typecheck.mdk` and the may-only-fall pins.
- `test/stage_counts_test.mdk`: per-stage work counts.

## Where the design lives
- `compiler/TYPECHECK-ARCHITECTURE.md` (current shape), `TYPECHECK-TARGET-ARCHITECTURE.md` and `TYPECHECK-CONTRACTS.md` (destination), `TYPECHECK-ARCH-BUG-FIT.md`.
- `EFFECTS-ARCHITECTURE.md` for the effect modules; `docs/design/TARGETS-DESIGN.md` for profiles.
- `ARCHITECTURE-PLAYBOOK.md` phases 1 to 4 for the split; issue #2586 sequences it.

## Traps
- `[P-EXHAUST-IN-TYPECHECK]` — `checkMatchExhaustive` is defined and called in `typecheck.mdk`, once per `EMatch`; it sees only core patterns.
- `[T-TUPLES]` — tuples are `__tupleN__`-headed `TApp` spines.
- `[T-ERRORS-ACCUM]` — no early exits.
- `[T-GLOBAL-TABLE]` — key new tables by scope.
- `[W-SOUNDNESS]` — `make medaka` does not gate on type errors.
