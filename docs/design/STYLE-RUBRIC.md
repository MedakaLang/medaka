# Style rubric

The rules a reviewer applies to Medaka source, tests and comments, with the
exceptions that make a finding wrong. Each rule was settled by the project owner
on a real example from the tree, one question at a time (2026-10-17); the
ruling id (`R1` onward, recorded in `docs/design/STYLE-RULINGS.md`) is the key the review benchmark labels against. The
target style is plain, readable Haskell: idiomatic, typed, and never clever for
its own sake.

How to read a rule:

- **Positive**: a finding. A reviewer that misses it has missed something.
- **Judgment**: a reviewer may raise it; it is scored neither as a miss nor as a
  false positive.
- **Control**: looks like the positive but is fine. Raising it is a false
  positive.

Every rule applies to test code, test row labels and shell gates exactly as to
source (R27). The one exemption is a fixture that deliberately exhibits a
pattern: a must-fail pin, or a lint rule's own fixture.

Review is diff-scoped: a finding is about code the diff adds or changes.
Existing instances in untouched code feed censuses and migration issues, not
review findings.

The machine-readable form of these classes is the `class` field of the fixtures
in `scripts/review_bench/`.

## Data and types

| Class | Positive | Exceptions and controls | Ruling |
|---|---|---|---|
| `data.sentinel` | An in-band value standing for absence or failure (`""`, `-1`, `0`), even when a comment documents it. Use `Option`/`Result`. | none | R1 |
| `data.bool-blind` | Two or more adjacent `Bool` parameters, or a bare `True`/`False` literal at a call site. Use a small sum type or a record. | A single well-named `Bool` parameter is judgment. | R2 |
| `data.stringly-error` | `Result String` whose error crosses a module boundary or has two or more failure kinds a caller could distinguish; prefixing or concatenating context onto an error string. Use an error sum type rendered once by `Display`. Code that inspects an error string's content is high severity. | A local helper with one failure kind may keep `String`. | R9 |
| `data.clone-type` | A two-case type whose cases mean presence/absence or success/failure: an `Option`/`Result` clone. Strong tell: conversion functions to or from `Option`/`Result`. | Every case is a meaningful domain state (`InterpStr`/`InterpExpr`). A clone with no default-eliminator where a silent default would be dangerous (`CDeclaredPrefix`, fail-closed) is legitimate. | R12, R31 |
| `data.param-clump` | The same three or more parameters travelling together through two or more functions; three or more adjacent parameters of one primitive type. Use a record. | A high parameter count alone is judgment. | R13 |
| `data.tuple-as-record` | A tuple of three or more fields appearing in two or more signatures. Same-typed fields make it high severity. | Local, short-lived tuples. | R21 |
| `data.string-enum` | A `String` compared against literals to choose behaviour outside the function that parses it: two or more distinct literals, or one literal tested in more than one place. High severity when the ADT already exists. Parse, don't validate. | The parse function at the boundary. | R22 |
| `data.string-key` | A composite identity built by joining fields into a `String` inside the program. Use a record key deriving `Eq`/`Ord`/`Hashable`. | A serialization boundary (cache file, JSON, LSP) with a matching parser. | R23 |
| `data.container` | Keyed lookup or membership on a `List` that grows with input; a hand-rolled positional `nth` on a list built once and read by index (wants `Array`); `acc ++ [x]` inside a recursion (wants `Vector`, or cons then reverse); a `HashMap` whose iteration order reaches output (wants `Map`). | Bounded, arity-sized lists. Judgment: a length check guarding positional access; a `Ref (List a)` used as a push buffer; a `Map` used only for hot get/insert. | R10, R11 |
| `iface.underused` | A hand-written function duplicating `deriving` or a standard interface (structural `sameX` for `Eq`, the canonical rendering for `Display`/`Debug`, a compare function for `Ord`); a family of three or more same-shaped functions over distinct types with no shared interface. | Secondary renderings (an s-expression form) stay named functions. | R16 |

## Code shape and idiom

| Class | Positive | Exceptions and controls | Ruling |
|---|---|---|---|
| `shape.do-cascade` | A `match` on `Option`/`Result` with a pass-through arm (`None => None`, `Err e => Err e`), even one level deep; a fallback staircase (`None => match …`) that `orElse` expresses. | An articulated reason not to use `do`/`orElse`, valid under the suppression criteria (R19): `orElse` is strict in its second argument, so an expensive or effectful fallback may keep the `match`. | R7, R32 |
| `shape.nested-match` | Deeply nested `match` where the arms are "check, then refuse or continue". Fix: name the check (`refuseIfAny`-style helper) and the refusal (a message function or error constructor), sequence them in `do`. | none | R8 |
| `shape.threaded-invariants` | Two or more arguments passed unchanged through every recursive call. Use a local `go` that closes over them. | A single constant argument. | R25 |
| `idiom.inside-out-pipeline` | A pipeline of three or more transformation stages written as nested application. Use `|>`. | Two-stage nesting. Density quotas (pipes per file) remain declined. | R17 |
| `idiom.let-underscore-unit` | `let _ = e` where `e` is `Unit`. Write the bare statement. | `let _ = e` discarding a non-`Unit`, non-`Result`, non-`Option` value after its side effect. A partial application discarded this way is a bug, not a style finding. | R18 |
| `defensive.discarded-result` | A discarded `Result` or `Option`, including best-effort calls. A best-effort call goes through a named helper. | none | R26 |
| `dup.existing` | A hand-rolled function the stdlib already provides (including renamed twins, shape matches of `map`/`filter`/`any`/`all`/`find`/`count`/`elem`, and inline shapes: a `match` with `Some v => v` and `None => d` is `optionOr d`); a compiler-private reimplementation of a stdlib facility. | A measured hot path, recorded in a suppression that cites the measurement. An independence requirement: an oracle must not share a helper with what it checks. Both already share the prelude and stdlib, so independence never justifies re-implementing a stdlib function. | R14, R15 |
| `dup.ctor-wrapper` | A function whose body only applies an exported data constructor to its own parameters, in the same order or as a record literal setting each field from one of its parameters, whatever the parameters are called. Use the constructor. | A wrapper that does real work: validates, supplies a default, reorders its arguments, is the smart constructor of a type exported abstractly, or has a name that states a unit or representation the constructor's argument type does not (`millis n = Duration n`). | R51 |
| `magic-literal` | A raw numeric character code (`== 34`); a constant's value repeated as a literal in a message or second definition. | The number in a doc comment, ideally pinned by a doctest. | R28, R30 |
| `suppress.invalid-reason` | A `lint-disable` whose reason is not one of: a concrete semantic difference, an independence requirement, a measured cost, a verified language limitation. Citing a norm without evidence, deferring work ("out of scope"), and bare "intentional" are positives. A whole-file disable is a positive unless the reason covers every declaration. | A reason of one of the four valid kinds. | R19 |
| `module.scattered-concern` | A diff that adds a new concern to a file not about it, or scatters one concern across distant regions or files. | Existing disorganization (census, not review). | R24 |

## Comments and documentation

The keep/cut test is per sentence, not per comment, and never a length rule.
Keep: constraints, invariants, hazards, and why not the obvious alternative
(defensive prose is the house register). Cut the classes below.

| Class | Positive | Exceptions and controls | Ruling |
|---|---|---|---|
| `comment.history` | Narrating what the code used to do or how it got here, including inside defensive prose. State the hazard in the present tense. | none | R5 |
| `comment.provenance` | An issue number or plan sub-id recording which work item introduced the code. | An issue number pointing at a live constraint or an open issue the code waits on ("until #1115 lands"). "Kept intentionally; see #N" waits on nothing and is provenance (R44). | R4, R44 |
| `comment.measurement` | Hand-typed measurements or recorded observations: percentages, CPU-seconds, sizes, counts, or what a run printed at a named commit ("measured at base <sha>: …"). State the conclusion; figures and SHAs go in the commit, issue or `compiler/PERF-RESULTS.md`. | none | R6 |
| `comment.restates` | Sentences that restate the code, when they make up half or more of the block. | One summary sentence on a top-level declaration is judgment, even when it paraphrases the clauses (R47). | R20, R47 |
| `comment.ephemeral` | Arguing with a reviewer ("pre-existing parity, not a new assumption"); anchoring to an in-flight change ("this slice"); a snapshot of current contents in place of the rule ("None now: …" above a list, instead of when an entry belongs in it). | "Now" meaning a point in the pipeline ("the clauses as they now are", after a pass) is not history; name the pass (R48). | R20, R48 |
| `comment.speculative` | Speculation about future changes ("if X ever gains Y, this follows"); code justified by a feature that does not exist ("exported so a future parser can import them"). | A hazard phrased as a future caller ("if a future caller drops that gate") is an unenforced precondition, a present hazard; better stated as the precondition (R49). | R20, R49 |
| `comment.shout` | An emoji sigil (🚨, ⚠️, 🔒), or dense ALL-CAPS emphasis: three or more emphatic words in one block. | One emphatic word in a calm comment; two is judgment. | R3 |
| `doc.register` | Implementation narration in a stdlib doc comment ("copied per element", a rewrite's history). | A cost contract a caller relies on ("O(1) average lookup", "push amortized O(1)"): the bound, not the growth policy or copy count that meets it (R45). | R29, R45 |

## Tests

| Class | Positive | Exceptions and controls | Ruling |
|---|---|---|---|
| `test.weak-reject` | A test asserting a rejection without naming the expected diagnostic (code or message fragment). | none | R37 |
| `test.bool-helper` | A test helper returning `Bool`, graded with `expectTrue`/`expectFalse`. Return an `Expectation`; a bespoke predicate goes through `expectSatisfies`. | A predicate that is a `prop`'s oracle stays `Bool`, and a test of that oracle grades it with `expectTrue`/`expectFalse` (R46). | R38, R46 |
| `test.length-not-contents` | Asserting a list's length where its contents are knowable. | The count is the property (a census floor via `expectAtLeast`); elements that cannot be compared or printed. | R39 |
| `test.escaped-program` | A test program of two or more lines written as a `\n`-escaped string. Use a triple-quoted string, closing `"""` on its own line, or a fixture file. | none | R40 |
| `test.hand-count` | An exact hand-maintained row or fixture count. Derive what can be derived; guard shrinkage with a coarse floor raised only at milestones. | A coarse floor. | R41 |
| `test.probe-in-production` | A test probe in a production module; a probe returning a positional `Bool` tuple (positive wherever it lives). | Until test siblings can see internals (R35), a probe has nowhere else to live: one returning a named record, a named list or `Expectation`s is accepted debt, new or old. | R42 |
| `test.repeated-columns` | A table column repeating one value in nearly every row. Encode the shared default with an explicit override where it differs. | none | R43 |
| `test.doctest-costume` | A doctest that needs fixture bindings or asserts `… == x` resulting in `True`. Doctests are documentation; move the check to the sibling. | A short illustrative doctest on an internal helper. | R34 |
| `test.vehicle` | A `prop` in a module whose law does not document the API; a shell gate whose `shell-because:` is not a trust anchor, Callgrind-class instrumentation, or a subject that is itself a shell script or external tool, or whose reason does not name this gate's subject by path or tool name (`scripts/pr.sh`, `gh`); a category list ("a shell/python/browser harness or live gh state") names no subject. | A `prop` that documents the API may stay in the module. | R33, R36 |

## Established before the rulings

These classes come from the end-of-sprint style reviews and their fix rounds
(`.claude/skills/style-review/SKILL.md`, `.claude/skills/pr-review/SKILL.md`)
rather than from a one-at-a-time ruling. Their labels rest on a fix having
landed.

| Class | Positive |
|---|---|
| `comment.stale` | A comment that contradicts or no longer describes the code, including references to deleted symbols, files or mechanisms. |
| `comment.layout` | A comment left ragged or broken mid-clause by an edit (`fmt` does not reflow comments). |
| `dup.in-diff` | The same expression or body repeated within the new code, or new code repeating a body or expression that already exists in the same module instead of calling it. |
| `dup.cross-file` | A helper copied between files, often test files, instead of shared. Not a test sibling copying its subject's unexported helpers until siblings can see internals (R35); a copy of a test-support module's helper still counts, since that module can export it. A comment or suppression explaining why the copy is not shared excuses it only when the reason is a concrete semantic difference, an independence requirement, a measured cost, or a verified language limitation (R19, R50); a worry about coupling or blast radius with identical behaviour, "out of scope", and bare "deliberate" do not excuse it. |
| `dead.code` | An unused binding, parameter, arm or import; a constructor with no producer; an unreachable branch. |
| `naming.misleading` | A name that says something other than what the binding holds or does. |
| `defensive.silent-default` | An error or absence turned into a plausible value (`_ => ""`, a swallowed `Err`), making a failure quiet. |
| `defensive.redundant` | Re-checking what the types or the caller already guarantee. |
| `diag.quality` | A diagnostic that fails `compiler/ERROR-QUALITY.md`: vague, double-reported, or without a remedy. |
| `test.gap` | New behaviour or a new branch with no test. |

## Language and tooling causes

Several classes have a root cause in the language or tooling rather than in the
author. A finding whose cause is listed here should say so; fixing the cause can
drain the class.

| Cause | Classes it feeds | Status |
|---|---|---|
| The value restriction rejects a point-free polymorphic definition | discourages point-free style | by design |
| Local `where` is almost unused although it works | `shape.threaded-invariants` | adoption issue #2242 |
| `orElse` is strict in its second argument | `shape.do-cascade` | accepted |
| `do` lowers to `andThen` | possible loss of a tail call | unmeasured |
| The stdlib index omits interface methods (`orElse`, `traverse`, `compare`) | `dup.existing` | #4269 |
| No byte-literal syntax | `magic-literal` | proposal |
| A test sibling sees only exported names | `test.doctest-costume`, `test.probe-in-production` | proposal (R35) |

Two former causes were re-measured on 2026-10-17 and no longer hold: importing a
stdlib module that defines a new type (`set` added 0.17% to the binary and no
measurable instruction count to `check`), and delegating the compiler's hot list
helpers to the prelude `Foldable` methods (instruction count within noise).
