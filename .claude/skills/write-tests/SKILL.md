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
| **Gate-test — a `*_test.mdk` with `kind = "native"`** | The subject is the compiled binary: a CLI contract, a golden, a fixture corpus swept per row. The test is still native Medaka; it spawns `./medaka` through `stdlib/test_process.mdk` and grades exit status, stdout AND stderr. | `test/<name>_test.mdk`, registered in `test/gates.toml` with `kind = "native"`. `test/compiler_cli_test_support.mdk` is the shared support module; `pds/test/vector_runner.mdk` is the runner-plus-data template. |
| **Shell gate** | A trust anchor (something that must not depend on the binary under test), an external harness (node, clang, sqlite3), or Callgrind-class instrumentation. | `test/diff_compiler_*.sh`, carrying a `shell-because:` header. **Load the `gates` skill** for authoring — this table does not duplicate its fixture/golden steps or CI shard rules. |

**#2298's criterion, as epic #2600 settled it:** a new check defaults to native
Medaka (doctest / `prop` / `test` block) over a shell script. "The subject is
the compiled binary" is NOT a reason to write shell — that is what the
gate-test row above is for, and 43 registry rows are already written that way.
Shell is reserved for the three cases in its row. A shell gate written because
the vehicle genuinely cannot express the check yet is debt with a name:
register it `migration = "native-wrap"` so the epic can find it again.

**Routing a spawn through a shared helper module no longer hides it.**
`medaka gate verify`'s native-grading clause follows a gate module's
project-local imports one level, so a helper binding the gate imports is a
spawn site like any other, reported at the helper's own file and line (#3234).
The stdlib and declared dependencies are never followed. Two consequences for
an author: a helper that spawns and grades nothing reds every gate that
imports it, and a spawn two imports deep is still invisible.

**Resolved, no longer an open question:** orchestration *by* `medaka gate` (the
CLI subcommand) does NOT count as harness dependence for #2298's
harness-independence exemption — `docs/ops/TESTING-ARCHITECTURE.md` §3 defines
the exemption over being the *sole oracle*, and the independent
differential/fixpoint floor is what supplies independence. A migrated gate is
never the only thing standing between a miscompile and green.

**Known capability walls** — if your check needs one of these, the vehicle
cannot express it yet and shell is the honest answer today: a long-lived
detached process (#3147), an interactive process handle written and read
incrementally (#2896), or several processes in flight at once and joined
(#2897). `stdlib/test_process.mdk`'s `boundedVerb*` helpers are synchronous:
they return only once the spawned process has exited.

## The assertion vocabulary — pick the verb, don't hand-roll it

The vehicle table above says WHERE a check lives. This one says WHAT to write
once you are there. Both modules' verbs return `stdlib/test.mdk`'s
`Expectation` — `Pass expected actual` or `Fail message expected actual`, both
carrying the rendered operands — so a failure shows the values, never just a
verdict. Never declare a per-file outcome type of your own, and never
hand-roll a verb this table already names: the hand-rolled form is what keeps
losing the operand, the label or the reason. Signatures are in
`docs/stdlib/index.md`, name by name, generated from the source.

### `stdlib/test.mdk`

| You have | Verb | Instead of |
|---|---|---|
| a branch that is fine, with nothing to show | `pass` | `expectTrue True` |
| a branch that is not fine, and the reason | `fail "<why>"` | `expectTrue False`, which throws the reason away |
| a `Bool` that must be true / false | `expectTrue` / `expectFalse` | `expectTrue (not b)` for the false case |
| a value and a one-off predicate | `expectSatisfies "<property>" p x` | `expectTrue (p x)` — the failure names neither the property nor the value |
| two values that must be equal / differ | `expectEqual` / `expectNotEqual` | `expectTrue (a == b)`, `expectTrue (a /= b)` |
| a strict bound | `expectLessThan` / `expectGreaterThan` | `expectTrue (a < b)` |
| an inclusive floor or ceiling — a census that must find SOMETHING | `expectAtLeast` / `expectAtMost` | `expectTrue (n >= 1)`, or pinning today's exact count and failing on every legitimate growth |
| a `Result` that must be `Ok` / `Err` | `expectOk` / `expectErr` | `expectTrue (isOk r)`, `expectTrue (isErr r)` |
| a `Result` that must be `Err` SAYING something | `expectErrContains "<needle>"` | `expectErr` alone, which stays green once the diagnostic it was written for is replaced |
| a `Result` whose `Ok` payload you then assert on | `expectOkThen (v => …)` | `match r` with `Err _ => expectTrue False`, which drops the error that says why |
| an `Option` that must be `Some` / `None` | `expectSome` / `expectNone` | `expectTrue (isSome o)` |
| two `Float`s within a tolerance | `expectWithin` | `expectTrue (abs (a - b) < eps)` |
| text that must contain several substrings | `expectTextContainsAll` | a chain of `expectTrue (contains … )` where only the first failure reports |
| …all of them on the SAME line — a location bound to its diagnostic | `expectLineContainsAll` | `expectTextContainsAll`, which accepts each landing in a different error |
| text with a required prefix AND substrings | `expectTextStartsWithAndContains` | two assertions, only the first of which reports |
| two texts where a trailing `()` or a whole-line `0` is a driver artefact | `expectEqualText` | `expectEqual` over the whole text, which dumps both and names no line |
| two texts where that trailing `0` is DATA | `expectEqualLines` | `expectEqualText`, which normalizes the `0` away and equates two different answers |
| several expectations that must all pass | `expectAll` | `&&`-chaining `Bool`s down to one `expectTrue` |
| …one of which has to say WHICH row it was | `labelFail "<row>"` | a label kept beside the expectation — `expectAll` forwards the first `Fail` and drops everything else |
| a whole corpus of labelled rows | `expectEach [("<row>", e), …]` | `expectAll (map snd rows)` |
| a check returning `Result String (List String)` that must be clean | `expectNoFindings "<check>"` | `expectOk`, which passes on a check that ran and found violations |
| …and its mutation control | `expectFindings "<check>"` | no control at all, so a check that can never fire reads as clean |
| an `Expectation` to inspect rather than return | `expectationTag` / `expectationMessage` / `expectationExpected` / `expectationActual` | matching on `Pass`/`Fail`, which a module declaring its own cannot do |
| named tests run from an ordinary program | `runTests` | a hand-rolled loop printing its own summary |
| output compared against a committed golden file | `expectGolden` | `readFile` plus `expectEqualText`, with a separate branch for "no golden yet" |

### `stdlib/test_process.mdk`

Its verbs reach a subprocess extern the interpreter does not bind, so a file
using them runs under `medaka test --native`.

| You have | Verb | Instead of |
|---|---|---|
| the tree under test, a path in it, the binary to spawn | `medakaRoot` / `underRoot` / `medakaBin` | an inline `getEnvOr "MEDAKA_ROOT" "."`; a bare `"medaka"` that can resolve to another build or to nothing (exit 127) |
| the per-spawn wall-clock ceiling | `spawnTimeoutSeconds` | a timeout constant re-chosen per gate |
| a spawn that must not hang the whole job | `boundedVerb` | `runVerb`, where the first hanging row consumes the job's own timeout and the sweep names nothing |
| …whose own pipeline is legitimately slower | `boundedVerbSeconds n` | stretching `spawnTimeoutSeconds` for every caller |
| a directory to write into | `scratchDir` | a constant `/tmp/…` path two concurrent gate runs write over |
| a spawn that must exit 0 | `expectSpawnOk` | `runVerb` plus `expectEqual 0 code`, which drops stdout and stderr from the message |
| a rejection: nonzero exit AND a diagnostic | `expectSpawnFails` | the exit code alone, which stays green once the diagnostic is deleted; or the text alone, which accepts a program that never ran |
| …whose diagnostic must say several things at once | `expectSpawnFailsAll` | one needle, which passes on a message that kept its headline and lost its location |
| a spawn that must exit 0 and print an exact line | `expectSpawnOkLine` | a substring check, which accepts a longer or differently prefixed line |
| the `*_test.mdk` stem of a file name | `testFileStem` | an inline `stripSuffix` |
| a suite's executed-assertion count | `testAssertionCount` | parsing the human transcript, which a formatting change silently zeroes |
| a roster closed over a directory | `unrosteredUnits` / `unrosteredTestFiles` | assuming the roster is complete, so a new file joins nothing |
| …its other half: roster rows naming nothing | `missingUnits` / `missingTestFiles` | a renamed or deleted file still reading as coverage |

**One asymmetry worth knowing before you convert anything.** `expectOk`,
`expectErr` and `expectErrContains` constrain the `Result`'s payload types with
`Debug`, because the failure message renders the value; `isOk`/`isErr` are
plain `Bool` predicates with no such constraint. So
`expectTrue (isErr (f x)) → expectErr (f x)` does not typecheck wherever the
`Ok` payload is a program type that derives nothing, and adding `deriving
Debug` to that type is usually a larger change than the conversion was worth.
`expectOkThen` is the way through when you need the payload anyway: it asks for
`Debug`/`Display` on the ERROR only.

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

- **`medaka test` does not enforce the internal-extern guard.**
  `internalExterns` (`compiler/frontend/resolve.mdk`) is a module-TRUST guard,
  not a doctest one: it restricts what an untrusted module may reference at
  all, and it binds a `test` block exactly as much as a doctest. `medaka test`
  switches it off for both (`compiler/tools/test_cmd.mdk`: `allowInternal =
  True`, `trustedMods = []` — *"`medaka test` is not the internal-extern
  enforcement surface (`check`/`--json` is)"*). So a check that passes under
  `medaka test` can still be rejected by `medaka check`; run both.
- **No custom prop generators.** `compiler/tools/prop_runner.mdk` generates
  structurally from the parameter's type; there is no `Arbitrary` deriver
  (`prop_runner.mdk:194`) and recursive-ADT generation depth is capped.
- **A failed prop's shrunk counterexample is RNG-dependent and diverges
  across engines** (`prop_runner.mdk`, see its own header comment) — never
  bake a specific counterexample into a golden as though it were
  reproducible.
- **`medaka test` defaults to the interpreter, but no longer only runs it.**
  `--engines eval,native` runs both and the exit code is the AND; `--native`
  runs the compiled arm INSTEAD of the interpreter (epic #2600, #2588). The
  default is still eval alone, so a bare `medaka test` report must say "passes
  under eval," never bare "passes" — and it still says nothing about wasm,
  which stays deferred. If a claim is about agreement between engines, ask for
  it: `--engines eval,native`.
- **A module with `test "…"` decls and no doctests is NOT typechecked by
  `medaka test`** (#1229) — it prints a loud `note: typechecking was skipped`
  first. A sibling under a project's `test/` dir does get typechecked
  (`underProjectTestDir`, `compiler/tools/test_cmd.mdk`), so this bites
  throwaway probes and files outside that layout. Read the note; if you see
  it, run `medaka check` too before believing a green run.

## Verify

```sh
./medaka test <file_or_sibling>.mdk     # doctests + test/prop blocks, under eval
./medaka test --engines eval,native <file>.mdk   # both engines; exit is the AND
./medaka check <file_or_sibling>.mdk    # typechecks cleanly (medaka test may skip it, #1229)
./medaka fmt --check <file>.mdk && ./medaka lint <file>.mdk
```

Writing a gate-test, or unsure whether a gate is the vehicle at all? Load the
`gates` skill for the authoring half — but the vehicle question is settled by
the table above, not there.
