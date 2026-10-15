# The compiler's target architecture

**Status:** ADOPTED 2026-10-15 (Val ratified the direction and ruled the six decisions
beneath it in one session; tracking epic #4206). This is the compiler-wide destination:
the laws every subsystem's design must satisfy and the shape the whole pipeline converges
on. A law is amended only by a PR Val ratifies. It does not replace the per-subsystem destinations, which it
sits above: [`TYPECHECK-CONTRACTS.md`](TYPECHECK-CONTRACTS.md) for the typechecker and
[`EMITTER-TARGET-ARCHITECTURE.md`](EMITTER-TARGET-ARCHITECTURE.md) (REVISION block)
for lowering and the backends. The route from the current tree to this one is
[`ARCHITECTURE-PLAYBOOK.md`](ARCHITECTURE-PLAYBOOK.md). The language specifications in
`docs/spec/` remain authoritative over all three.

**Why this document exists.** The compiler grew from 60k to 208k lines between July and
October 2026, almost entirely through agent sprints, each of which solved its own problem
well and placed its code where the previous sprint had placed theirs. The result is sound
in the small (small functions, no import cycles, selective imports) and unsound in the
large (one file holds 27.5% of the compiler and grows about 10k lines a month; two
backends re-derive the same facts; nothing one process computes survives to the next).
An evaluation against the OCaml, GHC and rustc compilers (2026-10-15, summarised in §6)
found that the three agree on a small set of structural properties Medaka lacks. Those
properties are the laws below. A sprint contract, a review, or a placement decision that
conflicts with a law needs a stated reason in the PR body or a ruling that amends this
file.

---

## 1. The shape

One pipeline, and every arrow carries a **value** the next stage reads and never writes:

```text
source text
  -> tokens                          frontend/lexer
  -> surface AST                     frontend/parser
  -> desugared AST                   frontend/desugar
  -> resolved AST (identities)       frontend/resolve
  -> CheckedProgram                  types/        typed program + schemes + evidence table
                                                   + downstream facts; or a diagnostics-only
                                                   TcReport when checking fails
       |-> interpreter               eval/         reads CheckedProgram; the pure oracle
       |-> Core IR (CProgram)        ir/           target-neutral; one fact, one producer
             + Plan                  backend/      whole-program analyses, computed once
                 |-> LLVM text       backend/llvm_emit   physical only
                 |-> WAT             backend/wasm_emit   physical only

ModuleInterface                      driver/       the serialized export surface of a
                                                   CheckedProgram, keyed by fingerprint;
                                                   what an importer loads instead of
                                                   re-checking the module
```

Two things in this picture do not exist today and are the destination's load-bearing
additions: `CheckedProgram` as an immutable published value (today the typechecker's
result is the input tree with cells filled in), and `ModuleInterface` (today every process
re-parses and re-typechecks the prelude and every import).

---

## 2. The laws

Each law states the rule, what is true today, and the check that holds it. A law without
a check is a wish; the playbook's Phase 0 adds the checks that are missing.

### A1. Layers, and the direction of dependency

`support` < `frontend` < `types` < `ir` < `backend`. `eval` depends on `frontend`,
`types` and a shared data module only. `driver`, `tools` and `entries` sit on top and
nothing below them imports them. Import cycles stay forbidden by the loader.

- *Today:* 7 violating edges in 994. Four are imports of `backend.private_mangle` from
  `types`, `ir` and `eval`; two are `ir -> eval`; one is `eval -> driver`.
- *Check:* a pinned count of violating edges that may only fall (Phase 0, G3).

### A2. Every stage's output is a value

A stage returns a new value or a side table keyed by stable ids. It never mutates the
tree it was given. The one permitted mutable representation is the type algebra's
inference variables, and they are resolved (zonked) before a result is published: no
live cell escapes `CheckedProgram`, and no later request can change the meaning of a
published one.

- *Today:* the typechecker writes dispatch routes into 9 `Ref` cells carried by 8
  constructors of `frontend/ast.mdk` from a post-inference stamper whose 9-step order is
  semantic; `checkOneSchemeFullK` returns live cells; `run` and `build` typecheck twice
  because the evaluator and the lowering read a tree that may be half-stamped.
- *Check:* `frontend/ast.mdk` declares no `Ref` field (Phase 1); a published scheme
  contains no unresolved cell (Phase 1 validator).

### A3. State has a declared lifetime

Every mutable cell belongs to exactly one scope: per process (interners, caches), per
module graph, per module, per binding group, or per solver run. The scope that owns a
cell creates it on entry and drops it on exit, and the cell is unreachable afterwards.
No module-level cell holds per-module or per-group state. Configuration is an immutable
record the driver builds once.

- *Today:* `types/typecheck.mdk` holds 26 module-level cells plus 147 `Ref` fields in
  four bundle records (`PerRun`, `DriverState`, `GraphRun`, `CrossRun`), all reachable
  from anywhere; one function reads or writes 93% of them.
- *Check:* module-level `= Ref` cells per module, pinned and falling (Phase 0, G3);
  Phase 2 ends with zero in the typechecker outside interners.

### A4. One fact, one producer

A fact two consumers need (arity, runtime kind, field ordinal, dispatch target, tail
position, reachability, linkage) is computed once by a named producer, carried as a field
of the value (Core IR or the Plan), and checked by a validator arm. Consumers transcribe
it. No consumer re-derives a fact from a spelling or a declaration scan.

- *Today:* the fact ledger F1 to F6 has landed and both emitters shrank; 95 named twin
  functions remain between `llvm_emit.mdk` and `wasm_emit.mdk`; the Plan record (R5) is
  cut but not run.
- *Check:* the twin count, pinned and falling (Phase 0, G3); `core_validate` runs before
  either emitter writes text, on every test.

### A5. Diagnostics are data

An error or warning is a value of a closed type, constructed where it is detected, with
its context. Rendering lives in a module that depends on the data and never on the
checker. Inference does not read the error accumulator as a control signal; the only
permitted reads are phase-boundary gates, and a proof-that-an-error-was-reported token
is how a later phase justifies skipping work.

- *Today:* the diagnostics code inside `typecheck.mdk` computes while it renders, which
  is why its extraction (#1120) needed 36 of 61 functions back-imported and was
  withdrawn.
- *Check:* `types/tc_diag.mdk`'s import closure contains no inference module
  (dependency-closure golden, Phase 4).

### A6. Dependency inversion goes through one registry

When a lower module genuinely needs a higher module's behaviour, it reads a field of the
one hooks record in `support/`, which the driver fills at startup. The record is
permitted for rendering, tooling and backend-fact lookups, and never inside inference.
Every field is named in one place and counted. This is OCaml's forward-declaration
convention (18 hooks in its typechecker) and rustc's `Providers` record, and it is what
Medaka has never had: today an inversion can only be expressed as an import, so it
becomes a layering violation or a withdrawn extraction.

- *Check:* the hooks record's field count, pinned; a lint arm that refuses a hook read
  from `types/` inference modules (Phase 0, G2).

### A7. Compute once is structural, not a discipline

Within a process, each expensive derivation (parse, desugar, resolve, typecheck, lower)
has one memoized entry per key, and every verb, the REPL and the LSP go through it.
Across processes, a module's typechecked export surface is a serialized
`ModuleInterface` keyed by source fingerprint, compiler fingerprint, the instance
environment it depends on and the selected target profile's IO join (D7); the prelude
ships pre-checked. Cache validity is a contract
(`TYPECHECK-CONTRACTS.md` §5), not a prefix hash.

- *Today:* the prelude is re-typechecked in every process (about 90% of a hello-world
  `check`); a value `main` is typechecked 3 to 4 times per verb; `build`'s child redoes
  the parent's front end; the O1 call-count wins are pinned by no gate (#4189).
- *Check:* callgrind call-count pins per verb (Phase 0, G6); prelude typechecks per
  process equals zero (Phase 3).

### A8. Modules are concerns, and the typechecker splits by layer

A new subsystem is a new module. The typechecker's modules follow the axis every mature
compiler uses: data types, type algebra (unify, levels, generalize, instantiate),
inference per language layer, solving, global checks, diagnostics, drivers. Not HM core
versus dispatch, which cuts through the `infer` recursion and was rightly rejected.

A module over 3,000 code lines carries a stated reason in its header comment. The
compiler's largest file may not grow: `types/typecheck.mdk` shrinks on every PR that
touches it, or the PR body says why not. The ceiling is rustc's (3,000 non-comment lines,
explicit opt-out); the growth rule is the one mechanism in any of the three reference
compilers that stops a hot file from becoming the compiler.

- *Today:* 57,032 lines, 30,601 of them code; growth of about 10k lines a month against
  about 9.8k lines extracted into sibling modules since August.
- *Check:* the growth ratchet (Phase 0, G1; owner decision D1).

### A9. Boundaries are checked by goldens, not prose

Each leaf module's sorted transitive import closure is a committed golden that fails when
it grows (GHC's `CountDeps` tests). The layering count (A1), the cell count (A3), the twin
count (A4) and the hook count (A6) are pinned numbers that may only fall. IR validators
run at every phase transition on every test, not in a separate gate.

### A10. Documentation is three piles

1. **The current map:** one short `ARCHITECTURE.md` per compiler directory (what the
   parts are, what each owns, which laws bind it), re-derived from source, with no line
   numbers.
2. **The agreed backlog:** this file's playbook and GitHub issues. One `TODO.md` per
   directory may hold the small agreed cleanups that do not merit an issue.
3. **The record:** a design document whose status becomes IMPLEMENTED moves to
   `compiler/archive/` in the PR that lands it. The docs index is generated and keeps it
   findable.

Rationale that explains why code is the way it is lives beside the code, as it already
does in this tree. A design document is a proposal; once landed it is history.

- *Today:* 66 files and 40,015 lines flat in `compiler/`, 36 of them tagged IMPLEMENTED,
  beside the three current maps.

---

## 3. The component map

| Directory | Components at the destination | Destination document | Owner |
|---|---|---|---|
| `frontend/` | lexer, parser, desugar, resolve (identity: every name resolved to its declaration before typechecking) | `docs/spec/SYNTAX.md`, `docs/spec/LAYOUT-SEMANTICS.md`, M-IDENTITY | #1122 |
| `types/` | K declaration analysis, I inference, Sh shadow resolution, S one solver, E elaboration, G global checks, Dg diagnostics data, X state lifetime; published as `CheckedProgram` | `TYPECHECK-CONTRACTS.md` | #1122, #2549, #2547, #2586 |
| `ir/` | Core IR as the contract (one fact, one producer), `core_validate`, the Plan record | `EMITTER-TARGET-ARCHITECTURE.md` R3 to R6 | #1398 |
| `backend/` | two physical lowerings over Core plus Plan, nothing semantic | `EMITTER-TARGET-ARCHITECTURE.md` | #1398 |
| `eval/` | the interpreter as a consumer of `CheckedProgram`; the pure deterministic oracle | `RUNTIME-DESIGN.md`, [T-EVAL-LOCKSTEP] | #1122 |
| `driver/` | the session: module graph, `ModuleInterface` cache, verb dispatch, no implementation | `TYPECHECK-CONTRACTS.md` §5, #4141 | #2732, #4141 |
| `tools/` | one file per user-facing tool, all reading the same memoized entries | `docs/ops/CLI-CONFORMANCE.md` | #4141 |
| `support/` | the compiler-private mini-stdlib and the one hooks record | this file, A6 | #4201, #4202 |
| `entries/` | thin probes, one stage each, for the differential gates | `.claude/skills/architecture/SKILL.md` | unchanged |

---

## 4. The owner decisions beneath the laws

Six decisions sat under these laws when they were drafted. Val ruled all six on
2026-10-15; the rulings and their reasoning are in `ARCHITECTURE-PLAYBOOK.md` §9 and on
#4206. In one line each:

- D1 `types/typecheck.mdk` may not grow (A8): adopted, as a one-file growth stop with a
  reviewed override; the tree-wide refusal in #2289 stands.
- D2 the hooks record (A6) serves rendering, tooling and backend-fact lookups and is never
  read from inference: accepted.
- D3 landed design docs move to `compiler/archive/`; each directory gets a map under 100
  lines with no line numbers (A10): accepted.
- D4 `build`'s emitter child runs the whole pipeline until the interface artifact exists,
  then receives the artifact from the parent (A7): accepted.
- D5 a value `main`'s auto-print obligation is an ordinary wanted solved against the
  unmodified prelude (A7): accepted.
- D6 the prelude's and the stdlib's interfaces ship as files beside the sources, produced
  by `make medaka` and loaded lazily, as OCaml's `.cmi`, GHC's `.hi` and rustc's `.rmeta`
  are (A7): accepted; not baked into the binary.
- D7 the target profile's IO join is read inside inference, so a published type may
  depend on it; every interface key includes the join, and interfaces are stored
  content-addressed so identical ones share a file (A7): accepted, ruled later the same
  day.

---

## 5. Settled, and not reopened here

- The HM core is standard and good; it is not redesigned (TYPECHECK-ARCHITECTURE.md).
- Separate physical backends; no shared instruction builder (EMITTER-TARGET-ARCHITECTURE
  L4; rustc's Cranelift shares facts, not the builder).
- The file split is in the refactor and is sequenced behind the state-lifetime split
  (ruling 8, #2586).
- `RNone` stays a pinned refining optimisation until its owning evidence work replaces it.
- The interpreter stays a pure deterministic oracle.
- No tree-wide size gate (#2289). A8's growth rule is a different instrument, ruled
  separately as D1.

---

## 6. Precedents

The three reference compilers were measured on 2026-10-14 from fresh clones. The full
evaluation, the three studies, the census of this tree and the re-runnable census
scripts are the closed record at
[`archive/findings/architecture-evaluation-2026-10-15/FINDINGS.md`](../archive/findings/architecture-evaluation-2026-10-15/FINDINGS.md).
The numbers below are the ones the laws rest on.

| | Medaka | OCaml | GHC | rustc |
|---|---|---|---|---|
| Largest file (lines) | 57,032 | 8,913 | 8,053 | 7,380 |
| Largest file, share of compiler | 27.5% | 5.5% | 1.4% | 0.8% |
| Typecheck output | cells patched into the input AST | new Typedtree, types as fields | new typed tree plus evidence bindings | `TypeckResults` side table |
| Typechecker state | 26 cells + 147 bundle fields, reachable anywhere | registered cells, snapshot and backtrack | about 30 cells scoped per module, implication or solver run | one context per body, nothing global |
| Interface artifact | none | `.cmi` | `.hi` | `.rmeta` |
| Inversion mechanism | none | 18 forward hooks | types/logic split, `.hs-boot` | `Providers` record |
| Diagnostics | computed while rendered, inside the checker | closed error variants, renderers registered downstream | leaf data types, leaf renderer | leaf derive structs, reporting behind a context |
| File-size norm | soft census | none; one `.mli` per module | none; median 311 | 3,000 non-comment lines, explicit opt-out |

What the laws deliberately do not copy: GHC's rewriting solver and System FC, rustc's
red/green dependency graph, `.hs-boot` files, Trees That Grow, a separate language-server
frontend, and any committee process.
