# Style rulings

A ruling is the project owner's decision on one real instance from the tree, asked as
a before/after question and settled one question at a time. These rulings were made on
2026-10-17. Each row of `docs/design/STYLE-RUBRIC.md` cites the rulings it rests on, and
this file is where to follow a citation back to the instance and the words that decided it.

- Fixtures labelled `val` in `scripts/review_bench/fixtures/` pin the instance a ruling was made on.
- Line numbers are as of the ruling's date. Look the instance up by declaration name.
- A ruling is not relitigated in a review. Changing one is a new ruling that names what it amends.
- New rulings are appended with the next number. The process lives in `.claude/skills/style-rule/SKILL.md`.

The class slug is the rubric's current slug. Where the ruling was first logged under a
different slug, that is noted.

### R1: a sentinel standing for absence is a defect

- **Instance:** `compiler/driver/build_cmd.mdk:1676`, `cachedRtObj`, where `""` means "no cached object" through three layers.
- **Ruling:** An in-band value meaning absent, failed or none is a defect, existing code included, even when a comment documents it. This covers `""`, `-1`, `0` and any other such value. Use `Option`/`Result`. "Clearly a data defect. Semantically empty string should be different from a failure/nothing. That's the whole point of having Option built into the language."
- **Class:** `data.sentinel` (logged as `magic-literal`, sentinel arm).

### R2: boolean blindness

- **Instance:** `compiler/driver/build_cmd.mdk:787`, `runBuild`, three adjacent `Bool` parameters; the call site at `compiler/driver/medaka_cli.mdk:1579` passes a bare `True`.
- **Ruling:** Two or more adjacent `Bool` parameters, or a bare `True`/`False` literal at a call site, is a positive. A single `Bool` parameter is judgment: neither a miss nor a false positive. "a for sure, b is possible but more of a judgment call."
- **Class:** `data.bool-blind`.

### R3: single-word ALL-CAPS emphasis is fine sparingly, a defect when dense

- **Instance:** `compiler/tools/prop_runner.mdk:1174`, a comment containing "A declaration name is NOT an identity".
- **Ruling:** One emphatic word in a calm comment is fine and is a control. A block where emphasis is dense is a positive. "b sounds correct." The hook already bans emoji and 3+ consecutive caps words.
- **Class:** `comment.shout`.
- **Open / follow-up:** Operationalization, not part of the ruling: for fixtures, 1 emphatic word per block is a control, 2 is judgment, 3 or more is a positive. Revise if the project owner objects.

### R4: an issue number in a comment is fine only when it points at a live constraint

- **Instance:** `compiler/types/route_key.mdk:66`, the comment `-- ── the published evidence table (#2549 M2) ──`.
- **Ruling:** An issue number is fine only when it points at a live constraint or an open issue the code waits on. A provenance tag is a defect, with or without a plan sub-id. "c". Positives are `#NNNN`, `#NNNN A-2.3` and `#838 I1` tags recording which work item introduced the code, which is git blame's job. A control is a pointer such as "bare-name keyed until #1115 lands". This supersedes the earlier practice of treating every bare `#NNNN` as an acceptable stable pointer.
- **Class:** `comment.provenance`.

### R5: history is a defect even inside defensive prose

- **Instance:** `compiler/tools/prop_runner.mdk:901`, the fuel-cap comment ("as `shrinkInt` did before this cap existed, see #1307").
- **Ruling:** A past incident cited to justify a guard is a positive. State the hazard in the present tense. "a". The defensive register itself stays a control. Rewrite shape: show the hazard ("`shrinkInt 0` returning `[1]` cycles 0 to 1 to 0"), not the story. History goes in the commit or issue.
- **Class:** `comment.history`.

### R6: hand-typed measurements in comments are a defect

- **Instance:** `compiler/backend/emit_plan.mdk:39` at 4bdeb12be, a comment carrying 0.29% of `.ll`, +3.7 CPU-s, 0.155 s and 106 MB.
- **Ruling:** State the conclusion; put the figures in the commit, the issue or `compiler/PERF-RESULTS.md`. "a". A qualitative conclusion stays ("measured: no native gain beyond GlobalDCE").
- **Class:** `comment.measurement`.

### R7: Option/Result match cascades instead of `do`

- **Instance:** `compiler/tools/test_pins.mdk:250`, `readPin`, which opens a `do` and drops back into `match … Err err => Err err` twice; its guard wants `unless`. The single-level case ruled on is `compiler/tools/prop_plan.mdk:236`, `pairModules`.
- **Ruling:** Any pass-through arm is a positive, even one level deep, "unless we can articulate a good reason to NOT use do syntax."
- **Class:** `shape.do-cascade` (new slug at the time).
- **Open / follow-up:** Candidate exceptions, to be allowed only if measured. `do` lowers to `andThen`/`pure` (`rewriteDo` in `compiler/frontend/desugar.mdk`), so a recursive call in the success arm stops being a tail call, which matters for stack depth on unbounded input. Dict-passed `andThen` on a hot path is the other candidate.

### R8: deeply nested `match` is a smell; the fix pattern is approved

- **Instance:** `compiler/tools/gate_pack.mdk:2348`, `balNewText`, 9 levels deep over 47 lines.
- **Ruling:** The fix is approved: "this is a perfect fix". Fallible steps become `do`, with a `mapErr`-based tag helper when every `Err` arm adds the same prefix. A validation of the form "if this list is non-empty, refuse" becomes a named check helper (`refuseIfAny : (List String -> String) -> List String -> Result String Unit`) used as a bare `do` statement. Multi-line inline messages become top-level message functions. A bare `Result _ Unit` statement in the middle of a `do` sequence short-circuits, as verified by probe.
- **Class:** `shape.nested-match`.

### R9: `Result String` overuse

- **Instance:** `compiler/driver/diagnostics.mdk:451`, `parseErrCode`, about 35 `startsWith "<message text>"` guards recovering an error kind from lexer and parser message text (`TLexError String`). Rewording a message silently changes its diagnostic code.
- **Ruling:** "a". Positive when the error crosses a module boundary, or the function can fail in two or more ways a caller might distinguish. A local single-failure helper may keep `String`. Code that inspects the string is high severity. Added by the project owner: "code that adds prefixes or manipulates the string in the Result often should be a dedicated data type that gets rendered at the end, rather than doing all of this constant string manipulation." So `mapErr (m => "prefix: \{m}")`, `Err "\{head}\{m}"` re-wrapping and string concatenation of error context are positives. The fix is an error sum type, with context as constructors wrapping the inner error, and `Display` at the edge.
- **Class:** `data.stringly-error`.
- **Amends:** R8. The `balErr` mapErr-prefix helper in the approved `balNewText` rewrite is itself this smell; the fuller fix gives gate balance a `BalanceError` type rendered once.

### R10: use the right container

- **Instance:** `compiler/driver/diagnostics.mdk:2226`, `resolveBlockedMods`. `buckets : List (String, List Diag)` is scanned per module by the hand-rolled `lookupBucket` (:1331), beside an `OrdMap Unit` used as a set in the same function. The `List` was chosen to keep load order.
- **Ruling:** "We should always use the appropriate datatype for the job … overusing List and almost never using some of the options" (Array, Vector, HashMap, Set, Map). Keyed lookup or membership on an input-growing `List`, index-in-a-loop on a `List` (use `Array`), and repeated append (use `Vector`) are positives. Fix here: a map for lookup, with order taken from the module list already walked. Bounded or arity-sized lists are fine and are controls ("a").
- **Class:** `data.container` (logged as `perf.list-as-set`, broadened).

### R11: container tells

- **Instance:** `compiler/backend/llvm_emit.mdk:10655`, `emitLeaf … nthArm arms i` (T1); `compiler/driver/loader.mdk:1376` (T3 control); `compiler/backend/llvm_emit.mdk:5741` (T2); `compiler/tools/refindex.mdk:343` (T4).
- **Ruling:** "yes. that sounds perfect." Firm positives: T1, a hand-rolled positional `nth*` on a `List` built once and read by index (use `Array`); T3, `acc ++ [x]` inside a recursion (use `Vector`; cons then reverse is fine); T6, a `HashMap` whose unspecified iteration order reaches output (use `Map`; possibly a correctness bug). Judgment: T2, a length check guarding positional access; T4, a `Ref (List a)` used as a push buffer; T5, a `Map`/`OrdMap` used only for hot get/insert, never iterated or shared (use `HashMap`). `compiler/backend/emit_support.mdk:361` `nthArm` is a cross-file duplicate with a stated oracle-independence reason, which makes it a good `ctrl.suppression-with-reason` control.
- **Class:** `data.container`.

### R12: clones of Option and Result

- **Instance:** `compiler/types/scopes.mdk:25`, `ScopeCursor = ScopeClosed | ScopeOpen ScopeId`. It carries a suppressed `rule-clone-type` with the reason "distinct misuse diagnostics"; those diagnostics are two panics that would read the same over `Option ScopeId`. `closeScopeCursor` converts `Option` to the cursor and `cursorView` at `compiler/types/scopes_test.mdk:84` converts back.
- **Ruling:** Agents implement datatypes "essentially identical to built in types like Option or Result". A two-case type whose cases mean presence/absence or success/failure is a clone, and that is a positive ("a"). The strong tell is conversion functions to or from `Option`/`Result`. A type is legitimate when every case is a meaningful domain state (`IdentBuiltin`, `InterpStr`/`InterpExpr`, `TypeVarRoot`/`RowVarRoot`). The `rule-clone-type` detector already exists, so the review job is judging the suppression reason.
- **Class:** `data.clone-type`.
- **Open / follow-up:** `CDeclaredPrefix` at `compiler/types/typecheck.mdk:9364` was raised as a sibling and is settled by R31.

### R13: too many parameters means missing datatypes

- **Instance:** `compiler/tools/test_cmd.mdk:996`, `driveAll`, 15 parameters passed nearly whole to `driveMulti` (14) and `driveSingle` (12); it hides Prelude, TestTarget and RunOptions records.
- **Ruling:** "Many functions take way too many parameters … suggests … we're not using datatypes properly to encapsulate things." The answer was "c". Firm positives: a clump, meaning the same three or more parameters travelling together through two or more functions; and three or more adjacent parameters of the same primitive type (`String`, `Int`), which extends R2. A high parameter count alone is judgment. A code scan can find these and a cheap judge can confirm the clump is one concept.
- **Class:** `data.param-clump`.

### R14: use the stdlib; hand-rolled reimplementations are positives unless measured hot

- **Instance:** `compiler/tools/gate_cmd.mdk:1420`, `findGate` (use `find`); `compiler/tools/doc.mdk:1064`, `allBlankLines` (use `all (== "")`); the three `elem` copies `containsInt`, `memberW` and `elemStrCli`.
- **Ruling:** "moving towards b is correct. i get the sense that we preemptively optimize a lot of things that aren't even on the hot path, so I think we should default to the stdlib and only deviate with measured evidence." Default to the stdlib everywhere. A hand-rolled copy needs a measurement showing a hot path and a suppression saying so. The direction is to fix `Foldable`/dict cost (specialization) rather than work around it.
- **Class:** `dup.existing` (shape arm).

### R15: compiler reimplementations of the stdlib go

- **Instance:** `compiler/support/ordmap.mdk` and `compiler/support/util.mdk`.
- **Ruling:** "it would be nice to ditch OrdMap and just use plain Map. same for pretty much anything that the compiler reimplements from the stdlib … only deviate from the stdlib with a measured performance penalty." This extends R14 to `compiler/support/`. `support/ordmap.mdk` is already `type OrdMap a = Map String a` and imports the stdlib `map`; only `omLookup` and `omHasKey` (monomorphic String descent, with a comment claiming it avoids dict `compare`) carry a performance claim.
- **Class:** `dup.existing`.
- **Amends:** R14, extending it to `compiler/support/`.

### R16: interfaces are underused

- **Instance:** `compiler/backend/core_validate.mdk:982`, `sameMode`, which is `deriving (Eq)` on `CallMode` (`compiler/ir/core_ir.mdk:215`, which derives nothing). The extreme case is `compiler/eval/eval.mdk:933`, `boolEq`.
- **Ruling:** "we're currently underusing interfaces, especially compared to what i'm used to from Haskell/Rust." The answer was "b". Firm: a hand-written function duplicating `deriving` or a standard interface (structural `sameX` for `Eq`, the canonical rendering for `Display`/`Debug`, compare functions for `Ord`; secondary renderings such as sexp may stay named); and a family of same-shaped functions over several types with no shared interface. Operationalization, not part of the ruling: a family is 3 or more parallel functions with the same role and shape over distinct types.
- **Class:** `iface.underused`.

### R17: avoided idioms, `|>`

- **Instance:** `compiler/tools/gate_cmd.mdk:1254`, `filterList nonBlank (map firstToken (filterList liveLine (splitNl src)))`.
- **Ruling:** "a". A pipeline of three or more transformation stages written as nested application is a positive. Two-stage nesting is fine.
- **Class:** `idiom.inside-out-pipeline`.
- **Amends:** the `style-review` DECLINED row "Pipe-density / idiom quotas". Density quotas (pipes per file) stay declined; concrete 3+-stage inside-out pipelines are no longer protected.

### R18: `let _ = <Unit expression>` is a positive

- **Instance:** the pattern as it appears across `compiler/` and `stdlib/`; `compiler/backend/llvm_emit.mdk:6396`, `let _ = emitExpr e env e1`, discards a `(String, LTy)` and is a different smell.
- **Ruling:** Write the bare statement. "the language doesn't require statements … that return Unit to destructure but we do it everywhere." Bare Unit statements sequence in plain blocks and in `do`, verified on both eval and native build. A lint can use the declared Unit return of a top-level function, with a saturation check, since `let _ = f a` on an arity-2 Unit function discards a closure, which is a bug.
- **Class:** `idiom.let-underscore-unit`.
- **Open / follow-up:** The project owner floated a type-aware lint for this. Discarding a non-Unit value is a separate smell, covered by R26.

### R19: suppressions need an actually valid reason

- **Instance:** the triplicated `maxInt`/`minInt`/`maxI` ("hot monomorphic … AGENTS.md anti-pattern") at `compiler/backend/llvm_emit.mdk:9130`, `compiler/frontend/lexer.mdk:1333` and `compiler/support/util.mdk:347`; the whole-file `rule-duplicate-body` disable in `stdlib/hash_map.mdk` ("out of scope"). Valid examples: `stdlib/path.mdk:225` `stripPrefix`, `string_test.mdk:363`, `compiler/backend/emit_support.mdk` `nthArm`.
- **Ruling:** "agents are too prone to disabling lint rules without an actually valid reason." Confirmed ("yes, that seems correct"): a reason is valid only if it names (1) a concrete semantic difference, ideally test-pinned; (2) an independence requirement; (3) a measured cost, as a number or a pointer to the measurement; or (4) a verified language limitation. Citing a norm without evidence, deferring work ("out of scope"), and bare "intentional" or "kept on purpose" are positives. A whole-file disable is a positive unless the reason covers every declaration. A lint can enumerate suppressions and a cheap judge can grade each reason against the four criteria.
- **Class:** `suppress.invalid-reason`.

### R20: long-winded comments; sentence-level register

- **Instance:** `compiler/tools/refindex.mdk:346`, `defSiteId`, a 7-line comment that reduces to "Not injective for a path containing a TAB, the same limit `mkKey` has."
- **Ruling:** Comments are "long-winded and lacking in actually useful information … good stuff … side-by-side with a lot of history narration, explaining the code, etc." The test is per sentence, not a length rule. Keep constraints, invariants, hazards and why-not-the-obvious-alternative (the defensive register). Cut history (R4, R5), measurements (R6), reviewer-arguing ("Pre-existing parity, not a new assumption") and speculation about the future ("if X ever …, this follows"). Restating the code ("b") is a positive only when it dominates the block, meaning at least half its sentences; one orienting sentence is judgment. A length ratchet was declined in #2281.
- **Class:** `comment.restates`, `comment.ephemeral`, `comment.speculative` (the last new at the time).

### R21: tuples standing in for records

- **Instance:** `(String, String, List Decl)`, the loaded module (modId, path, decls) with no name, in `compiler/driver/loader.mdk` `visitModF` and at `compiler/driver/diagnostics.mdk:2230` (`((mid, path, prog) :: rest)`). Also `(String, Int, String, String)` for a lint occurrence and `(Int, Int, Int, Int)` for a span.
- **Ruling:** "we could be doing better about using real datatypes and semantically structuring our data." The answer was "a". A tuple of three or more fields appearing in two or more signatures is a positive, because it is a travelling concept. Local transient tuples are fine. Same-typed fields make it high severity. This is an umbrella over R1, R2, R9, R12 and R13.
- **Class:** `data.tuple-as-record`.

### R22: String-encoded enums, parse don't validate

- **Instance:** `compiler/tools/test_pins.mdk`. `data PinKind = PropPin | TestPin` exists (:18), yet `readPin` (:250), `validKind` (:143) and `validateFields` (:161) carry the raw `kind` String and branch on `kind == "prop"` three times.
- **Ruling:** "a". A `String` compared to two or more literal values to choose behaviour, outside the one function that parses it, is a positive. It is high severity when the ADT already exists. The parse function at the boundary is where those literals belong, and is a control.
- **Class:** `data.string-enum`.

### R23: strings as composite keys

- **Instance:** `compiler/tools/refindex.mdk`, `mkKey` (:165, `modId ++ sep ++ ns ++ sep ++ name`), re-split by `keyModId` (:489) and `ifaceTyKey` (:1086) with silent `_ => k` fallbacks and a hardcoded `'\t'` instead of `sep`. The namespace is itself a string enum (`nsIface = "iface"`).
- **Ruling:** "a". Building a composite identity by joining fields into a `String` inside the program is a positive. It is legitimate only at a serialization boundary (cache file, JSON, LSP) with a matching parser. Fix: a record key deriving `Eq`, `Ord`, `Hashable`, plus a Namespace ADT. A performance exception only if measured (R14).
- **Class:** `data.string-key`.

### R24: modules turn into bags of functions

- **Instance:** `compiler/driver/build_cmd.mdk` (2,189 lines, 101 functions, about 10 concerns side by side). Clang linking is split across :1343 and :1840 with the rt-object cache between them, which is where five copied clang flag lists drifted.
- **Ruling:** "without constructs like classes there's kind of a tendency for all code to turn into a somewhat disorganized bag of functions … might be a language design problem, but … agents doing a poor job … structuring modules." The answer was "a". Review flags a diff that adds a new concern to a file not about it, or scatters one concern across distant regions or files. Existing disorganization is a periodic census, not a per-diff finding.
- **Class:** `module.scattered-concern` (logged as `placement`).
- **Open / follow-up:** The language-design half is deferred to its own discussion: whether Medaka needs a construct between function and module (sections, namespaces, nested modules). See the directory-facade convention in #2285.

### R25: invariant arguments threaded through recursion

- **Instance:** `compiler/tools/doc.mdk:900`, `extractFold`, where 5 of 8 arguments (`bare heads schemes origins tbl`) are re-passed unchanged at each of 5 recursive calls.
- **Ruling:** "a". Two or more arguments passed unchanged through every recursive call is a positive. The fix is a local `go` in a `where`, closing over them. A capturing, tail-recursive where-local `go` over 200k items runs under native build, verified by probe.
- **Class:** `shape.threaded-invariants`.

### R26: a discarded Result or Option is always a positive

- **Instance:** `compiler/driver/build_cmd.mdk:583`, `detectGCBare`, where `let _ = writeFile probe …` turns a failed write into "libgc not found". Non-Unit discards that drop a value after its side effect, such as `emitExpr`'s `(String, LTy)`, are fine and are controls.
- **Ruling:** "b". Even best-effort calls go through a named helper (for example `bestEffort : Result e a -> Unit`), not `let _ =` plus a comment.
- **Class:** `defensive.discarded-result`.
- **Open / follow-up:** Such a helper belongs in the stdlib (R15), so it is a stdlib addition and needs a proposal the project owner reviews first.

### R27: the rules apply to test code too

- **Instance:** `test/diff_compiler_dict_semantics_test.mdk:2551`, one label that breaks R3, R4, R5, R6 and R20.
- **Ruling:** "yeah, i agree with your lean". Every ruling applies to `*_test.mdk`, test row labels and shell gates exactly as to source. The only exception is a fixture that deliberately exhibits a pattern (a must-fail pin, a lint rule's own fixture). A test label's job is to name what the row proves, in the constraint register; history, measurements, SHAs and shouting in a label are positives.
- **Class:** all classes.
- **Open / follow-up:** The comment-register census and the style-review scope exclude `test/`, so both are too narrow against this ruling.

### R28: raw numeric character codes are a positive

- **Instance:** `stdlib/http.mdk`, 31 comparisons such as `byteAt input start == 32 || byteAt input start == 9` (:554) and `== 34`/`== 92` (:988, :990).
- **Ruling:** "yep, that sounds correct." Positive now; the fix is named constants (`sp`, `htab`, `cr`, `lf`, `dquote`, `backslash`) from one shared stdlib home. The long-term fix is byte-literal syntax (`b'"'`).
- **Class:** `magic-literal` (char-code arm).
- **Open / follow-up:** The shared constants are a stdlib proposal for the project owner to review. Byte-literal syntax is for the language-design session. A side find, to be filed separately: `byteAt` is defined three times with different argument order or return type (`stdlib/http.mdk:332` returns `Int`, `stdlib/bytes.mdk:97` returns `U8`, and `stdlib/base64.mdk:32`).

### R29: cost statements in stdlib docs, contracts allowed and narration not

- **Instance:** `stdlib/http.mdk:1444`, "A resumed scan costs time proportional to the bytes that arrived since the state was produced."
- **Ruling:** "a". A cost contract, a bound a caller relies on to choose or use the API ("O(1) average lookup", "push amortized O(1)", the resumable-scan bound), is allowed in a doc comment and is a control. Implementation narration ("copied per element", "this used to allocate", rewrite history) is a positive under the doc-comment rules in `stdlib/README.md` § "Writing documentation" (2026-10-11: no implementation notes; state the consequence, not the mechanism).
- **Class:** `doc.register` (perf-narration arm).

### R30: a constant's value repeated as a literal

- **Instance:** `stdlib/http.mdk:138`, `checkHttpRequestLineBytes`, with `Err "http: request line exceeds 8192-byte resource limit"` beside `maxHttpRequestLineBytes = 8192` (:59). The same holds for all six exported limits (:141 to :191) and an unnamed 4096 at :2419.
- **Ruling:** "b". In messages and second definitions the repeated literal is a positive: interpolate the constant. R9 also wants a limit-error type rendered by `Display`. In a doc comment the number is allowed for readability, ideally pinned by a doctest (`> maxHttpRequestLineBytes` giving `8192`).
- **Class:** `magic-literal` (duplicated-constant arm).

### R31: a clone with no default-eliminator is legitimate where a silent default is dangerous

- **Instance:** `compiler/types/typecheck.mdk:9364`, `CDeclaredPrefix = CDPUnknown | CDPLen Int`, an `Option Int` clone. `optionOr 0` would turn "unknown" into "length 0", and `CDPUnknown` must fail closed (withhold identity).
- **Ruling:** "yeah, that makes sense". Keep it. A type that forces an explicit decision where the default is dangerous is protection, not a clone, and is a control for `data.clone-type`. Its comment still needs fixing: one sentence of reason, no census count (R6) and no sigil (R3).
- **Class:** `data.clone-type`.
- **Amends:** R12, which gains this exception.

### R32: Option fallback staircases become `orElse`

- **Instance:** `compiler/tools/doc.mdk:793`, where the `Some s =>` arm is written twice.
- **Ruling:** "a". A fallback staircase is a positive; use `orElse` from `interface Alternative f` (`stdlib/core.mdk:1278`, with `noMatch`/`orElse`, `Option` and `List` impls). Delete the compiler-private `orElseOpt` (`compiler/support/util.mdk:454`). `orElse` is strict in its second argument, so where `b` is expensive or effectful, the `match` stays with a reason valid under R19; the two existing `rule-orelse-staircase` suppressions (`compiler/tools/refindex.mdk:381`, op-count ratchet; `compiler/frontend/exhaust.mdk:945`, recursion walk) qualify. No lazy variant until a third case appears.
- **Class:** `shape.do-cascade` (fallback arm).

### R33: where `prop`s live

- **Instance:** the `write-tests` skill said `prop`s live in-file, while the 2026-10-11 rule put property tests in `*_test.mdk` siblings.
- **Ruling:** "b". A `prop` may stay in its module when the law documents the API (for example `reverse (reverse xs) == xs` beside `reverse`), like a doctest. Every other `prop` goes in the sibling.
- **Class:** `test.vehicle`.
- **Amends:** the 2026-10-11 rule on where property tests live; this refines it and does not reverse it.

### R34: doctests in compiler/ are documentation only

- **Instance:** `compiler/types/registry.mdk:1236`, `> identOriginOf OriginUnresolved == None` giving `True`, and `regLookup identTypeFooM (regInsert …)` over in-module fixture bindings.
- **Ruling:** "a". The stdlib rule applies: a doctest must read as usage documentation for its function. One that needs fixture bindings, or asserts `… == x` giving `True`, is a positive and migrates to the `*_test.mdk` sibling. A short illustrative internal doctest (`> mangle "a.b"` giving `"a$b"`) is fine and is a control.
- **Class:** `test.doctest-costume`.

### R35: test siblings should see their subject's internals

- **Instance:** `compiler/types/registry_test.mdk:14`, which duplicates fixtures ("forced rather than sloppy") because a sibling sees only exported names, and leaves costume doctests behind (see R34).
- **Ruling:** "a". Propose that `<module>_test.mdk` may see its subject's unexported names, on the Rust model. Until then the duplication is accepted debt and is a control, not a positive.
- **Class:** `test.doctest-costume`, `test.probe-in-production` (both named as fed by this cause in the rubric).
- **Open / follow-up:** A proposal for the language-design session; not implemented. The `write-tests` skill says a sibling is "especially" for unexported machinery, which it cannot currently reach.

### R36: when shell is allowed

- **Instance:** the `shell-because:` headers of the external-harness gates, which carry one pasted generic line while their subjects are shell scripts (`scripts/pr.sh`, `mutation_transaction.sh`, the must-fail census).
- **Ruling:** "a". Shell is allowed for a trust anchor, for instrumentation (Callgrind-class), and for an external harness, redefined as "the subject IS a shell script or external tool". "node, clang, sqlite3" is not a reason, since a native gate-test spawns them via `test_process` as it does `./medaka`. The `shell-because:` text must name the specific subject, not a pasted generic line (R19).
- **Class:** `test.vehicle`.
- **Open / follow-up:** The `write-tests` skill row still says "node, clang, sqlite3" and needs updating.

### R37: a rejection test must name what it expects

- **Instance:** `compiler/types/effect_authority_test.mdk:51`. A precise `rejects` (checking `T-AUTHORITY`) exists, but the file uses `expectFalse (accepts …)` 55 times. Other forms are `expectNotEqual [] errs` and bare `expectErr` (32, against 10 `expectErrContains`).
- **Ruling:** "a". A test asserting a rejection must name the expected diagnostic, by code or message fragment. Otherwise a typo or renamed name in the inline program fails with an unbound-name error and the test stays green.
- **Class:** `test.weak-reject`.

### R38: test helpers return an Expectation, never a Bool

- **Instance:** `pds/test/http_test.mdk:71`, `rejects : String -> Bytes -> Bool`, graded by `expectTrue (rejects …)` 68 times. It becomes `rejects expected input = expectErrContains expected (parseRequest input)`.
- **Ruling:** "a". A `Bool` helper graded by `expectTrue`/`expectFalse` is a positive. A bespoke predicate goes through `expectSatisfies "<property>"` inside the helper, so the failure names the property and shows the value.
- **Class:** `test.bool-helper`.

### R39: compare contents, not lengths

- **Instance:** `compiler/types/effect_solver_test.mdk:130`, `expectEqual 0 (length failures)`; `compiler/tools/gate_cmd_test.mdk:96`, `expectEqual 1 (listLen (violations …))`, which stays green on the wrong violation.
- **Ruling:** "a". Use `expectEqual [] xs`, `expectEqual [expected] xs`, or match the item. A length check is fine only when the count is the property (a census floor, via `expectAtLeast`) or the elements cannot be compared or printed.
- **Class:** `test.length-not-contents`.

### R40: multi-line test programs are triple-quoted

- **Instance:** `compiler/types/effect_authority_test.mdk:118`, a 4-line layout-sensitive program in `\n  ` escapes; also `compiler/types/effect_bindings_test.mdk:415`, a one-liner of about 600 characters.
- **Ruling:** "a". Programs of two or more lines are triple-quoted, with the closing `"""` on its own line. Programs big enough to need `fmt`/`lint` go in fixture files. The migration is mechanical and byte-verifiable. A `let program = """` with an indented body and a closing `"""` drops the leading newline, removes the common indent, interpolates, and passes `medaka test`.
- **Class:** `test.escaped-program`.
- **Open / follow-up:** Blocked for interpolating programs on #4268 (`fmt --write` collapses a triple-quoted string into a `\n` one-liner whenever it contains an interpolation, wherever the closing `"""` sits). The migration of those programs waits for that fix, since `fmt` would undo it.

### R41: no exact hand-maintained row counts

- **Instance:** `test/diff_compiler_dict_semantics_test.mdk:5962`, `tableRows = 528`, checked as `graded /= tableRows`; `declaredFixtureCount` in `run_check_agreement` is the same shape.
- **Ruling:** "a". Derive what can be derived (visit every row, then `graded == length table`). Guard shrinkage with a coarse floor (`expectAtLeast`) raised only at milestones, never per row. Silent-empty-table protection is real; the exact count was the wrong instrument.
- **Class:** `test.hand-count`.

### R42: test probes don't belong in production modules

- **Instance:** `compiler/types/typecheck.mdk:48358`, `methodReturnResolutionMutationProbe : Unit -> (Bool, Bool, Bool, Bool)`, which saves, resets and restores global run state and is consumed by `compiler/types/typecheck_test.mdk:1765` as `let (_, rejected, _, _) = …`.
- **Ruling:** "a". A probe in a production module is a positive. New ones belong in the sibling, which needs R35. Until R35 lands, existing probes are accepted debt, but they must return a named record or `Expectation`s, never a positional `Bool` tuple, which is a positive today (R21, R38). Existing probes migrate when R35 lands.
- **Class:** `test.probe-in-production`.

### R43: tables encode the shared default; the exception is an explicit override

- **Instance:** `test/diff_compiler_dict_semantics_test.mdk:122`, `Row {… expCheck = "REJECT", expRun = "REJECT", expBuild = "REJECT", pinned = "", …}`. In 527 of 528 rows one verdict repeats three times (1,584 strings); `shadow_semantics` has 113 of 114.
- **Ruling:** "a". One value per row (`expect = Reject`), with an explicit override where verbs disagree (`Split { check, run, build }`). Already covered elsewhere: string verdicts are R22, `pinned = ""` is R1, label history is R27 and R4. The label is never read by the grader (a failure prints only `entry`), though the header calls it load-bearing.
- **Class:** `test.repeated-columns`.

### R44: an issue pointer is live only when the code waits on the issue

- **Instance:** `compiler/tools/lint.mdk`, the `trimWs` comment ending "Kept intentionally; see #2349". #2349 is the open drain issue for stdlib-reimpl findings, and the comment already states the VT/FF constraint.
- **Ruling:** "b". The pointer records which work item decided to keep the code, so it is provenance. That the issue is open is not enough. The control stays "until #1115 lands": the code changes when the issue closes. Fixture RB-0463 was flipped on this ruling.
- **Class:** `comment.provenance`.
- **Amends:** R4, refining which pointers count as live.

### R45: a cost contract is the bound, not the mechanism

- **Instance:** the `pushArray` doc in `stdlib/vector.mdk`: "Amortized `O(1)` per element. The backing store grows at most once, to the smallest doubling that holds the result, so appending many elements costs one copy of the live prefix … not one grow per element."
- **Ruling:** "b". Keep "Amortized O(1) per element". The growth policy and copy counts are implementation narration, a positive. Fixture RB-0491 was flipped on this ruling.
- **Class:** `doc.register`.
- **Amends:** R29, refining where a cost contract ends.

### R46: a prop's oracle stays Bool

- **Instance:** `sameUpToOrder : Outcome -> Outcome -> Bool` in `compiler/types/check_invariance_property_test.mdk`. It is the body of a `prop` and is also graded by `expectTrue`/`expectFalse` in a test that checks the oracle itself.
- **Ruling:** "b". A predicate serving as a property oracle returns `Bool`, and a meta-test of it uses `expectTrue`/`expectFalse`. This is a control. R38 still applies to `Bool` helpers used only by `test` blocks. Fixture RB-0502 was flipped on this ruling.
- **Class:** `test.bool-helper` (control).
- **Amends:** R38, adding the oracle exception.

### R47: one summary sentence on a top-level function is judgment

- **Instance:** `-- Match a DLetGroup, returning (is_pub, bindings) or None.` over the two-clause `letgroupOf`. Also "Add each letgroup extra if its name is unseen (first wins)." and "Increment the innermost bracket frame's open-context count (no-op at top level)."
- **Ruling:** "a". A one-line summary is the house norm (plain Haskell), so it is judgment and not `comment.restates`. R20's half-the-sentences test targets blocks of two or more sentences, so a two-sentence block that restates stays a positive (RB-0474). The rubric row lost "above dense code". RB-0473, RB-0475 and RB-0543 became judgment.
- **Class:** `comment.restates` (judgment).
- **Amends:** R20, narrowing `comment.restates`.

### R48: "now" words; pipeline time is not history, a snapshot in place of the rule is ephemeral

- **Instance:** `core_ir_lower.mdk`, "the clauses as they now are" (after the eta pass); `medaka_host.mjs`, "None now: every extern a granted slice serves has a wasm lowering" above an empty list.
- **Ruling:** "b". The first is vague and not history: judgment, and better to name the pass. The second is `comment.ephemeral`: state the membership rule, not today's contents. RB-0064 became judgment and RB-0209 became `comment.ephemeral`, both labelled `val`.
- **Class:** `comment.ephemeral`.
- **Amends:** R20, refining `comment.ephemeral`.

### R49: "if a future caller …" names a present hazard

- **Instance:** `llvm_emit.mdk`, `paramDecls`: "keeping the arms avoids a spurious catch-all panic if a future caller drops that gate". The callers are `allPVar`-gated today.
- **Ruling:** The project owner agreed with reading (a). This is a control for `comment.speculative`: an unenforced precondition is a hazard that exists now. Better wording states the precondition ("callers must be allPVar-gated; these arms fail closed"). The positive stays for code justified by a feature that does not exist ("exported so a future round-trip parser can import them", RB-0480). The dead arms are a separate `defensive.redundant` judgment.
- **Class:** `comment.speculative` (control).
- **Amends:** R20, refining `comment.speculative`.

### R50: a comment excuses a copy only with a reason valid under R19

- **Instance:** `compiler/backend/wasm_reach.mdk`, `canonKey` (comment added in `d4a46d95e`). It is a copy of `dce.canonRef` with the same three cases. Its comment says "Not shared with `dce.canonRef` … exporting it would put this wasm-only pass's lookup in that path's blast radius". `dce.mdk`'s own comment counts four mirrored copies of this canonicalization.
- **Ruling:** "a". A comment that explains why a copy is not shared excuses it from `dup.cross-file` only if its reason is one of R19's four valid kinds: a concrete semantic difference, an independence requirement, a measured cost, or a verified language limitation. Any other reason does not excuse it. "Blast radius" with identical behaviour names a worry, not a difference, so `canonKey` stays a positive. Bare "deliberate", "kept on purpose" and "out of scope" fail as they do for a suppression.
- **Class:** `dup.cross-file`. `dup.existing`'s exceptions are already of R19's kinds (a measured hot path, an oracle's independence).
- **Amends:** R19, extending its test from lint suppressions to comments that justify a copy.
