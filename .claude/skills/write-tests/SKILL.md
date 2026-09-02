---
name: write-tests
description: Pick the right vehicle for a new Medaka-repo test — doctest, property, `test` block in a `*_test.mdk` sibling, or a shell/`medaka gate` differential — before writing one. Use when asked to "write tests for X" / "add unit tests for X" / "test this module", so the test lands in the vehicle that fits instead of whatever fixture is nearby.
---

# Write tests — pick the vehicle first

**Route by what the check is actually checking, not by what's nearby.** The
concrete failure mode this skill exists to stop: 277 doctest input lines in
`compiler/types/{registry,typecheck,route_key}.mdk` were unit tests wearing a
documentation costume, because no other in-language vehicle existed
(#2296/#2290, epic #2276 leg 5). The vehicle now exists — use it.

## The dispatch table

| Vehicle | When | Lives |
|---|---|---|
| **Doctest** | A short (1-3 line), *exported* function's real return value, shown as documentation a reader benefits from. | In-file, in the doc comment. |
| **Property (`prop`)** | An algebraic law that should hold over many generated inputs (`reverse (reverse xs) == xs`), not one fixed case. | In-file, `prop "name" (x : T) … = body`. |
| **`test` block, in a `*_test.mdk` sibling** | Unit/regression assertion against a specific case, especially one touching unexported/internal machinery. | `<module>_test.mdk` beside `<module>.mdk` — see `compiler/types/registry_test.mdk` for the worked example. |
| **Shell gate / `medaka gate`** | Cross-engine agreement, a golden/snapshot, or a CLI contract — anything whose subject is compiled-binary behavior, not interpreter behavior. | `test/diff_compiler_*.sh`. **Load the `gates` skill** for authoring — this table does not duplicate its fixture/golden steps or CI shard rules. |

**#2298's criterion, folded in as one row of this table:** a new check
defaults to native Medaka (doctest / `prop` / `test` block) over a shell gate,
UNLESS its subject is native-binary behavior (LLVM/wasm codegen, CLI
conformance, cross-engine agreement) — those structurally cannot migrate to
`medaka test`, because everything under `medaka test` runs under the
interpreter (see Sharp edges). Open question, not resolved here: does
orchestration *by* `medaka gate` (the CLI subcommand itself) count as harness
dependence for #2298's harness-independence exemption? Flagged, not settled,
by S-3/S-4's reports.

## Negative space — NOT a doctest

A candidate doctest is unit-test-shaped, not documentary, if any of:
- it asserts `== True` / `== False` / `== None` (a boolean check standing in
  for an assertion, not a shown value);
- its target needs a fixture binding to run (a top-level value that exists
  only to feed the example);
- it pins an encoding a gate already covers (moving it loses nothing a reader
  needs and duplicates what the gate already asserts).

`test/doctest_shape_census.sh` (`make slop-census`'s `doctest-shape` row)
implements these three tells as a derived, honest-about-its-edges litmus —
reuse it rather than eyeballing a module.

## Worked example: S-4's per-corpus outcome

S-4 (`reports/S-4.md`) ran this table against the three abuse corpora it
inherited. The disposition, quoted from the landed diff, not the contract's
original prediction:

- **`compiler/types/registry.mdk` → migrated.** 80 of 83 unit-test-shaped
  sites moved to `compiler/types/registry_test.mdk` as `test` blocks — every
  function they exercise was already exported, so no widening was needed.
  3 sites stayed as doctests: each names `OriginUnresolved` directly, and
  `test/typecheck_compiler_source.sh`'s #1110 producer ratchet pins the set
  of tracked files carrying that mention by exact line text and filename —
  moving them would red the ratchet.
- **`compiler/types/typecheck.mdk` → stayed in-file.** Every unit-test-shaped
  site asserts a property of a private record type (`DeclEnvModule`/
  `DataEnv`/`ClassEnv`/`CeRow`) built by a private constructor. A sibling
  only sees exported names, and widening the compiler's central module's
  surface for test access was out of scope for that slice.
- **`compiler/types/route_key.mdk` → stayed in-file.** Its fixtures
  (`rkTyInt`/`rkTyBool`/`rkTyList`) are *also* pinned by the #1110 ratchet
  (by exact line text), and 9 of its 26 unit-test-shaped sites name
  `OriginUnresolved` directly, same as `registry.mdk`'s residue.

**Take from this:** a unit-test-shaped doctest may legitimately stay in-file
when either (a) it asserts a property of a private, unexported type/builder
that a sibling structurally cannot name, or (b) its exact fixture text is
pinned by a producer ratchet elsewhere in the tree (grep the ratchet before
assuming a move is free). Neither is an excuse to skip the table — both are
measured, per-corpus decisions, not defaults.

## Sharp edges

- **The doctest extern allowlist.** `internalExterns`
  (`compiler/frontend/resolve.mdk`) gates which externs a doctest example may
  call — a doctest can't reach for an internal-only primitive the way a
  `test` block or the interpreter driver can.
- **No custom prop generators.** `compiler/tools/prop_runner.mdk` generates
  structurally from the parameter's type; there is no `Arbitrary` deriver
  (`prop_runner.mdk:194`) and recursive-ADT generation depth is capped.
- **A failed prop's shrunk counterexample is RNG-dependent and diverges
  across engines** (`prop_runner.mdk`, see its own header comment) — never
  bake a specific counterexample into a golden as though it were
  reproducible.
- **Everything under `medaka test` runs under the interpreter.** A report
  must say "passes under eval," never bare "passes," when the claim is about
  `medaka test` output — it says nothing about `medaka build`/wasm.

## Verify

```sh
./medaka test <file_or_sibling>.mdk     # doctests + test/prop blocks, under eval
./medaka check <file_or_sibling>.mdk    # typechecks cleanly
./medaka fmt --check <file>.mdk && ./medaka lint <file>.mdk
```

For a cross-engine or golden claim, load the `gates` skill instead of adding
ad hoc shell here.
