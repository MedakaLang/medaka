# Test siblings see their subject's private names

**Status:** DECIDED 2026-10-18 — semantics ruled (follow Rust unless there is a good reason not to); implemented: F1 #4314, F2 #4703, F3 #4717, migration #4616 (PR #4724).

A `foo_test.mdk` beside `foo.mdk` may import any of `foo`'s top-level names, exported or not,
the way a Rust `#[cfg(test)] mod tests` sees its parent's private items. This document records
the semantics, the measured problem, the implementation strategies considered and rejected,
how the work fits around the planned architecture refactors, and the slice plan.

---

## 1. The problem

Style ruling R35 (2026-10-17, from the review-benchmark style evaluation) found that the
`*_test.mdk` sibling convention (AGENTS.md `[P-TEST-SIBLING]`) asks for tests of internal
machinery, while a sibling can reach only exported names. The workarounds are visible in the
tree:

- **Duplicated fixtures.** `compiler/types/registry_test.mdk` declares its fixtures twice, once
  in the sibling and once in `compiler/types/registry.mdk`, because exporting them would put
  doctest fixtures on the module's public surface. The file disables `rule-duplicate-body` to
  carry the copy.
- **Test-only exports.** A census at `c98fa3894` (word-match, so approximate) found about 121
  exported values whose only cross-file user is the subject's own sibling. That is an upper
  bound: it includes real API with no second caller yet (most of `registry.mdk`'s `reg*`
  family). It also includes clear test-only exports, such as roughly 22 probe and trace
  functions in `compiler/types/typecheck.mdk` (`methodReturnMemoFenceMutationProbe`,
  `beginAssumptionTrace`, …).
- **Tests left behind as doctests.** R34 moves assertion-shaped doctests into siblings. Some
  cannot move because they name unexported functions (`regex.findSteps`).

Medaka already has Rust's in-file half. A `test "…"` block inside a module sees the module's
private names (94 such blocks across 10 non-test files, e.g. `stdlib/net.mdk`), and a test
body never emits code (`compiler/ir/dce.mdk`: `DProp`/`DTest` are not emitting roots). What is
missing is the out-of-file half.

## 2. What Rust does

- Visibility follows the module tree. A private item is visible in its defining module and in
  that module's descendants.
- `#[cfg(test)] mod tests { use super::*; }` is a child module, so it sees everything. It may
  live in its own file through `#[cfg(test)] mod tests;`.
- `#[cfg(test)]` removes the module from non-test builds, so non-test code cannot reach it.
- `pub use` of a private item is an error (E0364/E0365).
- A function used only by tests is reported dead in a normal build. The remedy is
  `#[cfg(test)]` on it, or moving it into `mod tests`.
- Integration tests under `tests/` are separate crates and see only `pub` items.
- `.rmeta` records private items as well as public ones.

## 3. The rulings

Val, 2026-10-18: follow Rust's decisions, and deviate only with a good reason.

### 3.1 Taken from Rust

| Question | Medaka answer | Rust precedent |
|---|---|---|
| What the sibling sees | The subject's whole top-level scope: values, types, the constructors of abstract (`export data`) and private types, newtype constructors, private interfaces and their methods, non-exported impls, effect labels, and the names the subject itself imports | `use super::*` in a child module, including the parent's private `use` imports |
| How access is granted | By position. Ordinary `import` syntax, no new keyword | Visibility follows the tree; the `use` line is ordinary |
| Whose private names | Its own subject only, not other files in the directory | A child sees its ancestors, not its siblings |
| Re-exporting a name reached only through the privilege | A named re-export (`export import subject.{step}`) is an error, once per named name; a glob re-export (`export import subject.*`) re-exports the exported view only and raises no error | E0364/E0365 for a named `pub use`; `pub use super::*` skips the private items silently |
| A module whose file is not `*_test.mdk` importing one that is | Error | `#[cfg(test)]` items do not exist in a non-test build |
| A sibling's own new exports, including ones whose types mention the subject's private types | Allowed (only `_test` modules can import them) | A child's `pub fn` may return a parent-private type; `private_interfaces` is a lint, not an error |
| A private helper used only by the sibling | Still reported by `rule-dead-code`; the remedy is to move it into the sibling | Reported dead in a non-test build |
| Gate-tests under `test/`, and a `*_test.mdk` with no subject beside it | Exported names only, as today | Integration tests under `tests/` |
| What a module interface records | `ModuleInterface` (`compiler/ARCHITECTURE.md` A7, D6) carries the private surface too, so a sibling can be checked against an interface | `.rmeta` |

### 3.2 Deviations

1. **The subject does not declare its tests.** Rust needs the parent to write `mod tests;`.
   Medaka identifies modules by path and has no `mod` declaration anywhere, so this would be
   the only one. The trust boundary is the project, as Rust's is the crate.
2. **One level only.** `foo_test_test.mdk` is not a sibling of `foo_test.mdk`. Medaka has no
   module tree for privilege to descend.
3. **Doctests keep seeing private names.** Rust compiles doctests as external crates. Medaka's
   doctests are part of the module, and R34 already permits short internal doctests.
4. **No `pub(crate)` or `pub(super)`.** Finer-grained visibility is a separate question.

### 3.3 Defining "sibling"

`S` is the sibling of `M` exactly when all of these hold:

- `S`'s file name is `M`'s file name with `.mdk` replaced by `_test.mdk`;
- both files are in the same directory, compared after canonicalization (so they also share
  one project root).

The relation is physical, not a comparison of module ids. Stdlib module ids are bare names, so
an id rule would let a user's root-level `net_test.mdk` see stdlib `net`'s private names. The
path canonicalization matches `isNewVehiclePath` in `compiler/tools/test_cmd.mdk`, which
already classifies sibling files.

### 3.4 Example

```medaka-nocheck: proposed semantics — the sibling's import of the unexported counter is rejected by today's compiler, which is what this design changes
-- file: counter.mdk
export data Counter = Counter Int

export tick : Counter -> Counter
tick (Counter n) = Counter (step n)

step : Int -> Int
step n = n + 1

-- file: counter_test.mdk
import test.{expectEqual}
import counter.{Counter(..), step, tick}

test "step adds one" = expectEqual 2 (step 1)

test "tick goes through step" = match tick (Counter 1)
  Counter n => expectEqual 2 n
```

`counter_test.mdk` names the private `step` and pattern-matches on `Counter`'s constructor,
which `export data` keeps abstract from every other importer. A file `other.mdk` writing the
same `import` is rejected exactly as it is today. If `counter_test.mdk` wrote
`export import counter.{step}`, that is the new re-export error.

### 3.5 Authority

The phantom-authority rule (`checkPhantomAuthorityExport` in `compiler/types/typecheck.mdk`)
trusts the declaring module because its constructors are private. Under this design the
subject's sibling is trusted equally. That is sound only because §3.3 grants the privilege by
location inside the project, and §3.1 bars non-test modules from importing a `_test` module.
Both rules are therefore soundness obligations, not conveniences, and each needs a rejection
test.

## 4. Implementation strategies

### 4.1 Rejected: merge the sibling into its subject

Loading `foo_test`'s declarations as part of module `foo` is Rust's `mod tests;`, taken
literally, and would need no change to visibility code. At `c98fa3894`, 16 of the 67
compiler/stdlib siblings that have a subject import a module whose import closure reaches the
subject (`typecheck_test` through `eval`, `lint_test` through `lint_cmd`,
`effect_authority_test` through `typecheck`, …). After a merge, each of those is an import
cycle.

### 4.2 Rejected: publish everything during test runs

Marking the subject's declarations exported when the entry is its sibling would change name
resolution for the subject's other importers in the same program, such as a wildcard import
that picks up a new name, or a new collision. The program under test would differ from the
one that ships.

### 4.3 Rejected: a sibling branch in each visibility projection

"What does this module export" is derived independently in at least five places:

| Consumer | Projection |
|---|---|
| `compiler/frontend/visibility.mdk` | the `ExpNs` descriptors' `nsDirectOf`, one per export namespace, each matching on the `pub` flag |
| `compiler/types/typecheck.mdk` | `publicValNames`, `publicDataDecls`, `kindPublicDataDecl`, `polarityPublicKeys`, `publicStandaloneNames` |
| `compiler/types/private_mangle.mdk` | `pubLetRecBinders`; its export maps otherwise read `frontend/visibility.mdk`'s surface |
| `compiler/eval/eval.mdk` | `ModExports`, `ctorNamesOfDecl`, `publicExternNamesRev` |
| tooling | LSP completion and hover, `rule-dead-code` |

Adding "unless the importer is the sibling" to each is a family of carve-outs that must stay
in agreement by hand. A projection that misses the branch fails in a way no single gate sees.
For example, resolve accepts a name that the interpreter then cannot find.

### 4.4 Chosen: a visibility subsystem with an importer view

Visibility becomes its own subsystem, a new module (`compiler/ARCHITECTURE.md` A8: "a new
subsystem is a new module"). It answers one question: may importer `I` see name `n` declared
in module `M`, and through which namespace? It has two views of each module: the exported
view, which is today's behaviour, and the full view.

Its interface is the split that keeps §3.5's authority argument checkable:

- **Input:** the subject's declarations, plus a classification of the importer that the loader
  supplies (whether it is the subject's sibling, §3.3).
- **Output:** the full view for the subject's sibling, the exported view for every other
  importer.
- **The subsystem never looks at paths. The loader never looks at `pub` flags.** The sibling
  decision is then one loader function, and the visibility rules are one module, and each can
  be tested without the other.

Both views derive from the same declarations, so no cache key needs an importer component:
the chain memo and the interface keys (D7: source fingerprint, compiler fingerprint, instance
environment, IO join) are unchanged by who imports a module.

It belongs in `frontend/`, beside `resolve`: by A1 (`support` < `frontend` < `types` < `ir` <
`backend`), the lowest layer that needs the answer is resolve, and `types`, `eval` and
`private_mangle` can all import `frontend`. Its seed is the `ExpNs` block in `resolve.mdk`,
which already holds the per-namespace export rules in one place. Extracting it also shrinks
`resolve.mdk` (7,046 lines), which is over A8's 3,000-code-line threshold.

Every consumer in §4.3 then reads the subsystem instead of matching on `pub` flags. Universal
mangling already renames private functions to `<mid>__<name>`, so the emitted symbols exist;
only the mangler's import map consults `pub`.

## 5. Coordination with the planned refactors

Several planned efforts touch the same code. The subsystem must land in an order that gives
each of them one producer to read, rather than one more derivation to reconcile.

| Planned work | Overlap | Consequence for this design |
|---|---|---|
| M-IDENTITY, #2563 (identity-key every cross-module namespace) | Its remaining scope includes the typechecker's import-scope ladders (`applyCtorScopeOverrides` → `scopedCtorEntry` → `importedCtorEntry`, and the record rung). They answer "which module's declaration does this importer's name denote" (#2563's wording): they choose among candidates that are already visible. Which names are visible at all comes from the `public*` family in §4.3. | Only the `public*` family has to change for a sibling to typecheck. The ladders stay untouched and stay #2563's; when #2563 retires them it reads the same producer. The feature does not wait on M-IDENTITY. |
| Phase 2 as planned 2026-10-19: sprint 1 the cell-lifetime table and the `tc_types` leaf, sprint 2 lowering and eval read `CheckedProgram`, then a gate between Phase 3 C1/C2 and state threading | Every Phase 2 sprint lives in `typecheck.mdk`. Slice 1 touches no Phase 2 source, but shares the LEG A golden mechanism (`frontend.resolve` is a LEG A module). | Each slice runs serially between Phase 2 sprints, never in parallel with one. Slice 2 edits `typecheck.mdk` and carries the D1 growth ratchet. Replacing five projections with calls should shrink the file; if it grows, the override names where the lines go. |
| Phase 3 C1, the `ModuleInterface` codec | C1 serializes "a module's published export surface". | C1 serializes the subsystem's output, so slice 1 lands before C1. The full view (§3.1) does not exist until slice 3; if C1 exists by then, slice 3 adds the full view to the interface under a format-version bump, which the codec has by design. Slices 2 and 3 do not gate Phase 3. |
| The interpreter's export table | Eval's `ModExports` is built by the eval driver from declarations (`evalModulesWith`), not installed by the typechecker; Phase 2 sprint 2's installed-table deletion does not move it. | Eval's switch moved into slice 2 (see the deviation in §6). `evalModules` (`compiler/eval/eval.mdk`) and `cevalModules` (`compiler/ir/core_ir_eval.mdk`) move together, and both call `eval.moduleExports` ([T-EVAL-LOCKSTEP]). |

**In the playbook.** `compiler/ARCHITECTURE-PLAYBOOK.md` carries this design as follows:

- a dated amendment in §7 adds the visibility producer as F1 to F3 (slices 1 to 3 here),
  beside the typechecker phases like Phase 5 but ordered against them, with F2 accepting on "no
  direct `pub`-flag projection remains outside the producer" (a grep pin that may only fall);
- the §8 mapping table gains a row for M-IDENTITY / #2563, which had none: its ladders are the
  `Sh` component of `types/`, and they read the F1 producer when retired;
- C1 records the §3.1 ruling (the interface carries the private surface as well as the exported
  one, serialized from the producer's output) and needs only F1; F3 adds the full view under a
  format-version bump.

## 6. Slices

1. **Extract the subsystem from resolve, no behaviour change.** Move the `ExpNs` export rules
   into the new frontend module with the importer parameter (exported view only for now), and
   point resolve and `private_mangle`'s import map at it. No playbook phase owns
   `resolve.mdk`'s export block; the open bugs in re-export handling (#2017, #1687) are
   unscheduled. Evidence: selfproc LEG A goldens and two-arm IR identity unchanged.
2. **The typechecker reads the subsystem.** The five `public*` projections in `typecheck.mdk`
   read it; the ladders are untouched (§5). The slice first confirms that the ladders consult
   no `pub` flag of their own; if one does, that check moves to the subsystem too, and the
   rest of the ladder stays. Evidence: two-arm IR identity unchanged, `typecheck.mdk` smaller,
   and a census showing no remaining direct `pub`-flag projection in `types/`.
3. **The sibling relation.** Loader classification (§3.3), the full view, and the two new
   errors (re-export of a privileged name; a non-test module importing a `_test` module),
   across check, both interpreter drivers in lockstep, and emit. Placed after Phase 2 sprint 2;
   if C1 has landed, the slice also adds the full view to the interface under a format-version
   bump. Evidence: `check` accepts the §3.4 example and rejects the same import from
   a non-sibling, from a `*_test.mdk` in another directory, and from a user-project
   `net_test.mdk` against stdlib `net`, each rejection naming its diagnostic (R37);
   `medaka test` agrees across the interpreter, native and wasm engines for private values,
   abstract constructors and non-exported impls.
4. **Tooling, docs, migration.** LSP completion in a sibling offers private names; SYNTAX.md's
   module section, AGENTS.md `[P-TEST-SIBLING]` and the `write-tests` skill describe the rule.
   Remove `registry_test.mdk`'s duplicated fixtures, move the R34 doctests that could not move,
   and un-export the test-only names in §1. The migration reports how many of them become
   sibling-local (a helper only the sibling uses moves into it and leaves the shipping module,
   §3.1) and how many become private names of the subject, since the first kind changes what
   the subject module contains.

**Deviation (2026-10-31): eval's switch moved from slice 3 into slice 2.** Reading the exported
view in `evalModules` and `cevalModules` is behaviour-preserving except where eval exported names
the module does not export. The slice-2 census found those (#4710: a `run` that bound a private
or impl-method name through a wildcard import ahead of an explicit one), and the same change that
reads the exported view fixes them. Slices 1 and 2 are landed (F1 #4314, F2 #4703); slice 3 is
not started.

## 7. Out of scope

- `medaka test foo.mdk` also running `foo_test.mdk`.
- Finer-grained visibility (`pub(crate)`-style).
- Changing which doctests may see private names.

## 8. Known limits

Four cautions measured during the migration (#4616). A private type alias imported by name
into a sibling does not expand, so leave an alias exported when a sibling uses it in a
signature. A sibling sees the names its subject imports, so removing an "unused" import from
a subject can break its sibling; import the name from its defining module instead. A sibling
cannot read the record fields of an abstractly exported type: `Regex` is exported abstractly,
so its field `prog` is not accessible. And `medaka test` on a stdlib sibling copies the file
to a scratch directory with no manifest, which loses the sibling view (`unbound variable
parseGetInt` for `stdlib/toml_test.mdk`, while `medaka check` passes).
