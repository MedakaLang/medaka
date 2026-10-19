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
| `tc_types.mdk` | The typechecker's data declarations and state records | none |
| `typecheck.mdk` | Hindley-Milner inference, constraint solving, dict-passing elaboration, coherence, the effect-row checker's wiring; described in `TYPECHECK-ARCHITECTURE.md` | `elaborateOne`, `grantWholeDomain` |
| `publish.mdk` | The published shapes (`TcReport`, `CheckedProgram`, `PubScheme`, `TcDiag`, `ModDiags`), the deep zonk and freeze-by-copy over them, and the live-cell validator; imports no typechecker state | `freezePub`, `liveCells` |
| `evidence_coverage.mdk` | The evidence coverage validator: every minted site in a program's trees answered once, in the shape its reader accepts, and no ordinal published twice; a pure walk over `Decl`s and an `EvTable` | `evidenceFaults`, `EvidenceFault` |
| `repr.mdk` | The type representation (`Mono`, union-find `Tyvar`, `Scheme`) and every renderer over it; reads no typechecker state cell | `normalize`, `ppMono` |
| `registry.mdk` | Identity and registry substrate the per-table re-keying units build on | `identKey`, `tabKeys` |
| `evidence.mdk` | Request-owned nominal identities for goals, scopes, binders, instances, destinations | `EvidenceBinderId`, `ScopeId` |
| `scopes.mdk` | Nominal lexical scope storage for one typechecking graph | `DefaultBodyIdentity` |
| `solver_contract.mdk` | Request-local contracts for scoped class solving and scheme instantiation; no inference state | `InstantiationServices` |
| `superclass.mdk` | The superclass closure over declared `requires` clauses, parameterised by reader | superclass walk |
| `evidence_complete.mdk` | The completeness judgment: does every dispatch destination name an instance or a given | `EvidenceRow` predicate |
| `disposition.mdk` | Whole-graph table of which method each impl supplies or inherits from the default; importable by `ir/`, `eval/`, `backend/` without `typecheck.mdk` | `installedDispositionsOpt` |
| `route_key.mdk` | The only mint of an impl route word | `evMethodRoutes`, `numIntWord` |
| `chain_key.mdk` | The part of the module-chain memo key a step reads from modules outside its prefix: instance heads and constrained signature names | `chainGraphKey` |
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
Filled by playbook S1 (A3). Until then the per-module counts of module-level `Ref` cells are
`test/arch_goldens/cells.golden`.

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
