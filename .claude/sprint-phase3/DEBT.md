# Stage B / Phase 3′ (`B-2.2`) — DEBT

Append-only, one row per landed bite. The orchestrator commits; the implementer supplies the row.
**`could move:` and `nearest miss:` may not be blank** — *"nothing, and here is why"* is valid,
silence is not.

```
### <bite id> — <one-line description>
sites:        <files:lines actually touched>
transform:    <what was applied>
could move:   <what acceptance behaviour could plausibly have changed>
nearest miss: <the nearest program this does NOT cover, and what it does today>
engines:      <LLVM / wasm / eval / core_ir_eval — which arms moved, which peers are owed>
unchecked:    <what was not verified, and why>
```

⚠️ **A row is owed for any behaviour delta the repair round's differential DETECTS**, not only
those an implementer recognized — written at detection time, by the round that found it.

---

### B-2.2-a — the shared route-word mint
sites:        `compiler/types/route_key.mdk` (NEW, 374 lines — 3 exports, 6 private helpers, 4
              fixtures, 38 doctests) · `Makefile:91-94` (the `test:` line that is the ONLY thing
              typechecking or running this module — see `unchecked:`). NOTHING else was touched:
              `frontend/ast.mdk` is unchanged (`data Route` untouched per RUN-P3-019), and
              `implKeyTc`/`implKeyOf`/`ppTyAtom`/`ppTyAtomK`/`declRouteKey`/`keyForSite` are all
              still exactly as they were.
transform:    Minted, at zero call sites: `ifaceWordOf` (`module::Iface`, falling back to the bare
              name on both absent-origin arms), `implRouteKeyWord` (the existing
              `iface|args|method` wire format, with the iface half swapped for the qualified word
              when an origin exists — the #1047/#1265 route-word residual (#1113); NOT #1182, whose
              interface-free candidate key no word substitution reaches — AVAILABLE and APPLIED
              NOWHERE), `routeWordFor`
              (`declRouteKey`'s body and `keyForSite`'s collision branch, unified behind a
              caller-supplied verdict), and `rkTy`/`rkTyFunArg`/`rkTyAtom` (one prec-2 `Ty`
              printer, based on typecheck's `ppTy` — the more complete of the two mirrors).
could move:   NOTHING, and here is the evidence rather than the assertion. The module is in no
              entry's import closure (`grep -rn route_key compiler stdlib test` → the file's own
              doc-comment and the `Makefile` line, no import anywhere), so no compiled byte reaches
              any consumer. Measured: `make medaka` exit 0, `make check-self` PASS,
              `diff_compiler_snapshot_frontend` **201 of 201 existing snapshots compared and
              matching — zero goldens MOVED**. The one non-inert consequence is an ADD, not a move:
              `compiler/types/*.mdk` is a GLOB in that gate (`test/diff_compiler_snapshot_frontend.sh:165`),
              so the new file auto-enrolled in the snapshot corpus and the gate now reports
              `202 fixtures — 201 compared` with `route_key.mdk: FAIL no snapshot`. The close-out
              re-cut therefore owes a CREATE (`--new`) for `test/snapshots/compiler/route_key.md`,
              not only re-blesses of moved goldens.
nearest miss: The nearest program this does not cover is EVERY program — there is no call site, so
              no route word in the tree is produced by this module yet. Concretely: a two-module
              program where `a.mdk` and `b.mdk` each declare `interface Speak` and each impl it for
              the same head still routes on the bare word `Speak|T|` today, exactly as before this
              bite; the #1047/#1265 residual (#1113) is not closed until a later bite points
              `implKeyTc`/`implKeyOf` here. (#1182 is NOT addressed by any of it.) The
              nearest thing this module could get wrong but does not: on the loader-less path
              (`medaka check <single file>`, lsp, repl, doc, lint, snapshot) a RAW `ifaceIdentity`
              would spell `"|T|"` for every interface and collapse instances the present bare-name
              word keeps apart — `ifaceWordOf`'s fallback is what prevents it, and it is
              fail-capable: replacing the function body with the raw `ifaceIdentity o name` reds 8
              of the 38 doctests (measured, then reverted).
engines:      ONE LINE, because no compiled byte reaches an engine: the module is imported by
              nobody, so LLVM, wasm, eval and core_ir_eval all emit and execute byte-identically to
              base. No peer arm is owed by THIS bite — but the bite that collapses the callers owes
              all four, because `rkTy` is typecheck-complete and `eval`'s `ppTyAtomK` is not (see
              `unchecked:`).
unchecked:    (1) **The divergence between the two printers this mint is meant to replace is
              recorded, not resolved.** `types/typecheck.mdk`'s `ppTy` renders `TyEffect` as
              `<row> t` and `TyConstrained` as `cs => t`; `eval/eval.mdk`'s `ppTyK` strips both
              (`TyRow` agrees on both sides — the packet's "eval strips all three" is off by one,
              `eval.mdk:506` renders it). `rkTy` follows typecheck, so pointing eval's callers here
              would WIDEN eval's words: two impls differing only in an effect row or a constraint
              currently collapse onto one `implKeyOf` word there and would stop doing so. That is
              very likely the fix direction and it is a BEHAVIOUR CHANGE — bite `e` owes a
              discriminating probe on the eval arm before it collapses the callers. This bite ran
              no such probe. (2) **Verification of this module rests entirely on one `Makefile`
              line.** A call-site-free module is invisible to `make medaka`, `make check-self` and
              `test/typecheck_compiler_source.sh` (measured 2026-08-03 for `types/registry.mdk`,
              whose header records it; the `Makefile`'s own comment says "Add a line here for every
              call-site-free compiler module"), so `./medaka test compiler/types/route_key.mdk` in
              the `test:` target is the only thing that typechecks it or runs its 38 doctests.
              Delete that line and every assertion silently stops running. (3) **No gate beyond
              build/check-self/snapshot was run** — no fixpoint, no engines, no perf: with zero
              call sites there is nothing for them to observe, and the packet forbids capturing.
              (4) **`rule-duplicate-body` is RED and deliberately left un-silenced** — see the
              orchestrator hand-off in the bite report; `rkEffAtom` is a transitional 4th copy of a
              helper whose 3 existing copies each carry a `lint-disable-next-line`.

### B-2.2-f — the declared-prefix sidecar (plumbing only; nothing reads it yet)
sites:        `compiler/types/typecheck.mdk` only, plus two allowlist rows in
              `test/registry_keying_ratchet.sh:191-192`. Types: `CDeclaredPrefix` /
              `CDeclared` beside `data CSlot`. Fields: `PerRun.funConstraintDeclaredRef`,
              `CrossRun.crossModuleFunConstraintDeclaredRef` + `…DeclaredQualRef` (+ their
              `freshPerRun`/`freshCrossRun` `Ref []` initialisers — reset is free through the
              existing whole-record re-mints). FIVE writes: `setFunConstraintEntry` (the entry
              append), the module seed bare + alias-prepend, the module snapshot bare + qual, and
              the JOINT-DISCOVERY snapshot in `discoverPromotedModules` — the fifth, which
              RUN-P3-015 omitted and which module 1 is seeded from. ONE read:
              `declaredConstraintFor`, with `declaredConstraintSlots` demoted to a projection of
              it. **`data CSlot` is UNTOUCHED and no `CSlot` mint site was edited.** Four
              signatures generalized to carry a scalar payload: `aliasConstraintEntries` /
              `aliasEntriesFor` / `moduleAliasEntry` / `memberAliasEntry` (`List a` → `a`) and
              `promotedConstraints`; two pairs of structural duplicates collapsed into one
              polymorphic function each — `attributeModuleArities`+`attributeModuleArrIfaces` →
              `attributeModuleEntries` (**both `rule-duplicate-body` disables DELETED**, #1201
              partially discharged) and `lookupQualArity`+`lookupQualIfaces` → `lookupQualPayload`.
transform:    Every entry written into the ids table now carries, in a sidecar table keyed by the
              SAME name, the number of dict slots the callee's own `=>` context DECLARED —
              recorded as `CDPLen (listLen (dedupSlots slots))`, so `b1` can compare `index < k`
              and withhold identity from the super slots `expandSupersPairs` APPENDS. Absence is a
              distinct token, `CDPUnknown`, never `0` and never `Option Int`; it means WITHHOLD.
              The single read clamps with `minI k (listLen slots)` before returning.
could move:   Acceptance behaviour: NOTHING, and here is the evidence rather than the assertion.
              Nothing reads `cdPrefix` — the sidecar is write-only this bite by the scope ruling,
              so neither fill site was touched and no route word, dict arity or emitted symbol has
              a new input. Measured on the rebuilt binary: `make medaka` exit 0 · `make check-self`
              PASS · `test/registry_keying_ratchet.sh` PASS (24 CrossRun fields, 24 write targets,
              both checks — the second allowlist is DERIVED from the first, which is why two rows
              sufficed where RUN-P3-015 said four) · `diff_compiler_llvm_typed` and
              `diff_compiler_llvm_typed_ir` **PASS — the emitted typed IR is byte-unchanged**,
              which is the direct observation that dict arity and route words did not move ·
              `diff_compiler_eval_modules` PASS (the run-path cross-module arm) · `fmt --check` and
              `lint` clean on the touched file and on `lint compiler stdlib sqlite`. The one
              non-behavioural consequence is that `compiler/types/typecheck.mdk`'s SNAPSHOT and its
              `selfproc_legA` `types.typecheck` scheme golden both move — new top-level symbols,
              generalized signatures, and four deleted duplicates (`git diff` on the file is the
              derivation; no count is written here). Per the packet ZERO goldens were blessed —
              the close-out re-cut owns them, and that diff must be read as a REVIEW artefact:
              it is not additive-only, because collapsing the four duplicates deliberately
              removes their rows.
nearest miss: The nearest program this does not cover is EVERY program: with no reader, a callee
              whose declared prefix is recorded as 1 and whose expansion appended 3 super slots is
              stamped exactly as it was before this bite — #1113 is not fixed until `b1` reads
              `cdPrefix`. The nearest program whose RECORDED value would be wrong if the arithmetic
              were: `twice : (Shw a, Shw a) => a -> Int` — one tyvar, duplicated constraint.
              Independently corroborated at the consumer end rather than by re-running the
              packet's instrumentation: built with `--keep-ir`, `@mdk_w__twice` takes **one** dict
              param, while the sibling control `both : (Shw a, Tag a) => a -> Int` takes **two**.
              So `dedupSlots` really does collapse 2→1 and `listLen slots` would have recorded 2 —
              marking the first APPENDED slot declared, the unsafe direction. That program is NOT
              landed as a test (see `unchecked:` (1)).
engines:      ONE LINE, because no engine sees a different byte: `diff_compiler_llvm_typed_ir`
              passes, so LLVM emits identically; wasm shares the same Core IR input and the same
              front end, and `eval`/`core_ir_eval` read routes this bite does not write. No peer
              arm is owed by THIS bite. **`b1` owes all four**, since the moment `cdPrefix` gates
              identity the route word itself changes on every engine.
unchecked:    (1) **The packet's "doctests" deliverable is NOT LANDED, and it is not landable as
              written.** `compiler/` carries no doctests and no `test "…"` blocks at all
              (`grep -rn '>>>' compiler/` and `grep -rn '^test "' compiler/*/*.mdk` are both
              EMPTY), so adding the first one to `typecheck.mdk` would be a first-of-its-kind
              construct in a 30k-line file, run by no gate — `medaka test` is never pointed at it.
              With `cdPrefix` unread there is also nothing observable to assert. The witness
              program is carried instead as the `dedupSlots` comment at `setFunConstraintEntry`
              and in `nearest miss:` above; `b1`, which makes the prefix observable, is where it
              becomes a real fixture. (2) **The `minI` clamp is DEFENSIVE, not measured** — the
              `pairSlots` truncation it guards was instrumented by the prep pass over a full
              compiler build and a two-module probe and never fired. It is one token and it fails
              closed. (3) **The vacuity measurement (§7 M-3) was NOT run** — it needs an
              instrumented fill site, which the scope ruling forbids this bite from touching; the
              orchestrator owns it. The `:14600-14612` joint-discovery write, which is what that
              measurement exists to detect the absence of, IS present. (4) **No fixpoint, no
              engines gate, no perf gate** — `llvm_typed_ir` passing byte-for-byte makes the
              fixpoint's question (does the emitter emit the same thing) already answered for this
              diff, and no backend file was touched. (5) **`CDPUnknown` is currently constructed
              only by `clampPrefix`'s absent arms and consumed by nobody**, so the fail-closed rule
              is stated and typed but not yet exercised; `b1` is the first reader that can violate
              it.

### B-2.2-e + B-2.2-b1 — the mirror deletion, and the origin on both sides of the seam
sites:        `compiler/types/typecheck.mdk` (import of `types.route_key`; `implKeyTc`'s body →
              `implRouteKeyWord OriginUnresolved`; **`b1`'s TWO LINES** at `keyForSite` and
              `keyForSiteByIface`, now `implRouteKeyWord ir.irOrigin ir.irName tys None`; plus
              the two `f`-review one-liners relayed mid-flight — `funConstraintDeclaredRef` is
              now CLEARED at `dictPassModulesIfEnabled`/`dictPassModulesScoped`, and
              `CDeclaredPrefix`'s definition is reworded off "declared by its own `=>` context"
              onto "present before super expansion appended any") · `compiler/eval/eval.mdk`
              (`implKeyOf` AND its whole private `ppTyK`/`ppTyAtomK`/`ppEffAtomK` printer family
              DELETED; `declImplIfaceIdRow` and `implMethodEntry` repointed, the latter grown an
              origin param threaded from `declImplEntries`) · `compiler/ir/core_ir_lower.mdk`
              (imports the mint directly instead of `eval.implKeyOf`; `ifaceImplHeadEntries` +
              `lowerImplMethod`, the latter grown an origin param threaded from `lowerDeclImpl`)
              · `compiler/types/route_key.mdk` (header retractions only — no code) ·
              `test/diff_compiler_dict_semantics.sh` (5 TABLE rows + 8 IR rows) ·
              `test/typecheck_compiler_source.sh` (3 ratchet allowlist entries — see
              `unchecked:` (5)) · 5 new `test/dict_fixtures/` directories.
              **ZERO edits at the four `inst` arms** (RUN-P3-025 holds: selection and the
              collision gate are inside `keyForSite*`; the arms hold only `fromOption tag`),
              and **D5/D6's element routes are untouched by construction** — `b1` edits neither,
              so `b2`'s prohibition is honoured with no explicit guard. Stated because a reader
              of a two-line diff cannot see that it was considered.
transform:    ONE route-word mint for the whole tree. The caller side (`keyForSite*`) and the
              definition side (`eval`, `core_ir_lower`) call the same function with the same
              `implOrigin`, so a route word carries `module::Iface` where the loader stamped an
              origin and the bare name where it did not (flat drivers — `check <single file>`,
              lsp, repl, doc, lint, snapshot — byte-identical to pre-bite).
could move:   **IT DID MOVE, and here is what.** (1) **ACCEPTANCE, on the `run` path:
              `test/must_fail_fixtures/1514-xmod-same-spelled-iface-impl-selection` DRAINED.**
              Two unrelated modules each declaring `interface Same` + `impl Same Blob` used to
              collapse onto ONE route word and answer both call sites with one module's impl —
              import-order dependent, exit 0, no diagnostic. Measured on this binary: `11 / 110
              / 7`, the fixture's own hand-derived correct answer. That is the #1047/#1265
              family, **not** #1182 (see `nearest miss:`). The gate is RED *because* it drained;
              per the packet nothing was blessed or deleted — the close-out owns closing #1514
              and removing the fixture. (2) **A COLLISION VERDICT.** `ifaceDeclHeadUnique` →
              `declKeysAtHead` dedups by canonical key, so identity-bearing keys make two
              same-spelled interfaces at one head count 2 instead of 1: `unique` flips False and
              the definition side stops routing both under the bare tag, closing a skew that was
              live and masked by `implEntryRouteWords`' union arm. ⇒ **"byte-identical IR on
              programs with no head collision" is FALSE as usually stated.** The defensible
              claim is *"…and no two same-spelled interfaces in the module graph."*
              (3) **EMITTED SYMBOLS AND DICT WORDS at collision sites** —
              `@mdk_impl_Base__Box_Int___btag` becomes `@mdk_impl_base__Base__Box_Int___btag`
              (pinned both ways, HAS + LACKS, by the new `b1-p4-super-slot-colliding-heads`
              rows) ⇒ the IR-text goldens and the LEG A scheme goldens move (all three edited
              modules are LEG A). **ZERO goldens blessed, including the seed.** (4) **THE SEED
              DOES NOT NEED RE-MINTING, measured rather than hoped:** `selfcompile_fixpoint.sh`
              reports **C3a YES** — IR1 byte-identical to the seed-bootstrapped reference — and
              **C3b YES**. The compiler's own source emits the same bytes through this change.
              (5) **NOT acceptance anywhere else:** engines 0 regressions / 0 promotions / 0
              pinfails; `eval_modules` 11/11; `llvm_typed_ir` 54/54 byte-identical (a SINGLE-FILE
              corpus ⇒ absent origin ⇒ bare name, which is exactly why it cannot see this bite —
              do not read its green as multi-module evidence); `dict_semantics` 176/176;
              `typecheck_compiler_source` PASS; `check-self` PASS. And `pickMostSpecificEntry`
              still RETURNS the first match after reporting, so a REJECTED program's routes are
              unchanged — asserted, not assumed, by the two new REJECT fixtures keeping their
              exact diagnostic codes (`T-INCOMPLETE-IMPL`, `T-MISSING-SUPER-IMPL`).
nearest miss: **#1182 IS NOT FIXED AND NOT TOUCHED — its pin still reproduces** (`run` → 1,
              control → 2). Two independent derivations agree why: the wrong row is chosen
              UPSTREAM of this word, by `ieCandidatesForMethod`'s `(method, head)` key with no
              interface component; and #1182's repro is a SINGLE FILE, so `ifaceIdentity` answers
              `""`, `ifaceWordOf` falls back to the bare name and the word does not even move.
              ⚠️ `b1` makes that bug **quieter → differently wrong**: where the head-tag hedge
              used to mask the mis-selection, the wrongly-selected instance's IDENTITY is now
              stamped directly. Watching artifact: the existing `must_fail_fixtures/1182-…`
              pair, whose `why-control` block already explains how to read a convergence.
              **`sanitizeId` is not injective and this bite widens the alphabet reaching it:**
              module ids are loader-derived PATHS and `.`, `/`, `-` all sanitize to a SINGLE
              `_`, so `a.b::I|T|`, `a/b::I|T|` and `a-b::I|T|` collide — pre-existing at MODULE
              granularity, newly exposed at INTERFACE granularity. (⚠️ the circulated `a_` +
              `_Alpha` example is WRONG — each offending char maps to one `_`.) Independently,
              the runtime word is `hashName key` (djb2), a second and unrelated collision
              channel no `sanitizeId` reasoning covers. **`D1-leak` is untouched:** a rigid
              in-scope goal whose lookup misses still falls through to `inst`; `b1` makes that
              wrongness NAMEABLE without fixing it — #1127 legs 1–2 are B-1's.
engines:      **ALL FOUR MOVED, and the peers are owed.** eval and `core_ir_eval` share the
              definition-side mint (`core_ir_eval.mdk:455` is a CONSUMER — owed a *test*, not a
              patch); LLVM and wasm read the words through their own families. **OWED PEERS,
              unedited here:** `llvm_emit.implEntryRouteKey` / `implEntryRouteWords` /
              `headTagUnique` / `distinctKeysAtHead`, wasm's independently-written family, and
              `core_ir_lower.distinctKeysAtHeadL`. Acceptance survives the verdict skew in
              `could move:` (2) only because `implEntryRouteWords` emits the UNION
              `{routeKey, headTag}` — the new colliding-heads fixture shows that union doing
              exactly that work (`icmp eq` against BOTH the identity key and the bare tag).
              ⚠️ `wasm_emit.mdk:4090`'s `implKeyOf` is a DIFFERENT function sharing the name (a
              local projection for `distinctImplKeys`) — deliberately not touched.
unchecked:    (1) **#1608 (S1, OPEN, declared un-pinnable) sits under the `run` arm of every
              cross-module fixture added here** — `core_ir_eval` selects a cross-module impl by
              IMPORT ORDER, ignoring the receiver, with no pin. Mitigation, not a fix: all five
              new fixtures are graded `ALL_EXACT` (run AND build must agree byte-for-byte with a
              hand-derived value) and every discriminating assertion is on EMITTED IR, so **no
              assertion added by this bite rests on `run` alone.** (2) **The `headTycon`
              asymmetry is NOT fixed and its enumeration is NOT complete.** eval's `headTycon`
              strips `TyEffect` AND `TyConstrained` to the inner head where typecheck's
              `headTyconTy` answers `None` (as it does for a function head) — three known shapes
              of one wildcard arm, on a projection nobody has audited arm-for-arm. `e` unifies
              the printers (the WORD), not the head projections (the TAG). Measured with a
              control: `impl Sz (<Stdout> Int)` alone → check 0, run 0, **build 1**
              (`E-PANIC: no impl of method 'sz' for type '__none__'`); `impl Sz Int` alone
              builds and executes. Filed separately. (3) **The `ppTy` fold WIDENS eval's words**
              (`<Stdout> Int` no longer prints as `Int`); the safety argument is that the
              observing program does not typecheck — two impls differing only in an effect row
              or a constraint are rejected by coherence (*"Overlapping impls of Sz: Int and
              Int"* — the diagnostic strips the row too), exit 1 on check AND run, both shapes.
              NOT measured: the LONE effect-headed impl, whose definition-side word does change
              (to the one typecheck was already stamping) and which (2) says is broken on the
              build path either way. (4) **`route_key` is now in the import closure**, so the
              `Makefile` `test:` line is no longer its only verification — but it IS still the
              only thing that RUNS its 38 doctests (all pass). Do not delete it. (5) 🚨 **THREE
              RATCHET ALLOWLIST ENTRIES WERE ADDED TO `test/typecheck_compiler_source.sh`, AND
              TWO OF THEM DISCHARGE A PRE-EXISTING RED INHERITED FROM `a`.** The `#1110`
              occurrence-layer and `OriginUnresolved` producer ratchets are `git grep`s over
              TRACKED files, **not** over an import closure — so `compiler/types/route_key.mdk`
              has tripped them since `B-2.2-a` landed it, unnoticed because `a`'s own row records
              that no gate beyond build/check-self/snapshot was run. ⚠️ *"A call-site-free module
              is in no gate"* is true of the compiler's gates and FALSE of this one. Both entries
              are justified at the list (doctest fixtures; the file constructs no AST the
              pipeline consumes). The third is `b1`'s own — `implKeyTc`'s new `OriginUnresolved`
              argument — justified by (6). (6) **M4 WAS RUN; it is the evidence for skipping two
              of D1's nine sites.** `KeyEntry`'s key field was replaced with a literal
              `"__DEAD__"` at both mint sites on a full rebuild: `make medaka` 0, `make
              check-self` PASS, `diff_compiler_dict_semantics.sh` **163/163**. Corroborated at
              field level — every `KeyEntry` destructuring binds `_` in position 4 and
              `bucketKeyEntriesFrom` only rebuilds it. ⇒ dead field; `e` correctly skips
              `keyEntryOf`/`keyEntryOfRow`. (7) **`a`'s instruction to retire `rkEffAtom`'s
              `rule-duplicate-body` directive is REFUSED, measured.** `e` deletes eval's copy,
              but typecheck's `ppEffAtomTy` and doc's `ppEffAtomDoc` are reached by the
              DIAGNOSTIC printers, untouched here — so `rkEffAtom` becomes one of THREE, not the
              only one. With the directive removed, `medaka lint --only=rule-duplicate-body
              --deny=rule-duplicate-body compiler stdlib sqlite` exits 1 naming both files.
              Directive kept; the comment above it records this instead of promising a deletion.
              (8) **Not run:** perf/scaling, the wasm gates, and `diff_compiler_selfproc` (its
              LEG A goldens move by construction and the packet forbids blessing — the close-out
              re-cut owns them, along with `route_key.mdk`'s still-owed snapshot CREATE, which
              `a` bequeathed).

### B-2.2-c — the comment-only bite: three wrong comments corrected, one property inscribed
sites:        `compiler/types/typecheck.mdk` only, four hunks, **comment lines exclusively**
              (`git diff -U0 | grep -vE '^[+-][[:space:]]*--'` over the non-marker lines is
              EMPTY — the mechanical check, not an assertion): `:18482-18487` (the
              `fromOption tag` consequence, appended to `keyForSite`'s header), `:19539-19549`
              (`implDictRoutesForFull`'s `[keyTable]` justification), `:19811-19850` (the new
              selector-reachability block, above `entail` — a FUNCTION, so #829 cannot fire),
              `:19896-19898` (`entailInst`'s header, the `EKNestedTop` clause). +60/−3.
transform:    (1) `keyForSite`: the WRONG-TIER paragraph was **already corrected by `b1`+`e`**
              (it names `emitDefaultRKey`, and the `Some __none__`-is-a-direct-hit measurement,
              correctly) — **not re-edited**. What was still missing is the CONSEQUENCE, which is
              the half that nearly shipped a break, so it was appended: `fromOption tag` is not a
              hedge over a selector result, it is the ONLY source of that TAG where it fires,
              deleting it breaks every cross-module method-less impl inheriting an interface
              default, and a green suite here is evidence about the DEFAULT tier, not the route
              word. (2) `implDictRoutesForFull`: *"[keyTable] is still threaded for the nested
              `requires` recursion, which re-buckets by each requires' own head"* replaced with
              **dead parameter awaiting the sweep**, carrying the derivation (`selectReqImpl`'s
              signature takes no `KeyBuckets`; its own header says the parameter was REMOVED
              rather than ignored; every link on `argImplReqRoutes → argReqRoute → routeOfD →
              entail` only FORWARDS the table; the one `KeyBuckets`-consuming fallback,
              `undeterminedRoute`'s `CountImpls` arm, is unreachable because `argReqRoute` seeds
              with `KeepNone`). (3) `entailInst`'s header: `EKNestedTop → bare head tag` replaced
              with *the min⊑ winner's canonical key (bare head only when the iface-keyed
              collision gate is False)* — false since #203, and the arm's own body comment and
              the `EntailKind` ladder comment both already said so. (4) NEW: the ladder's
              **selector-reachability** property above `entail`, with its three earned guards —
              why it matters (§3 `assum` ≺ `inst` ≺ `fallback`; a later rung answering re-routes
              a dict cell from a caller-supplied parameter to a statically selected impl, wrong
              value at exit 0), that it is **reachability, not a count** (two selector calls per
              `inst` arm are legitimate and at `EKArg`/`EKOp` deliberately ask about DIFFERENT
              methods via `innerDefaultMethod`/`ieDefinesReqMethodAt` — verified at both arms —
              so any *"one call per arm"* rule licenses a collapse that changes which impl's
              context is discharged), and that a grep of `ieSelectRowBy*` is not the check
              (`concreteReqMatchByIface` is a legitimate out-of-ladder selector, the obligation
              channel's evidence check).
              ⚠️ **THE PACKET'S WORDING OF THE PROPERTY WAS AMENDED, NOT INSCRIBED VERBATIM, AND
              THE AMENDMENT IS REPORTED RATHER THAN SILENT.** The packet's clause *"No selector
              call may be reachable from `entailAssum`, `entailAssumVar`, `entailAssumRoute` or
              `entailFallback`"* is TRUE for the three `assum` functions (enumerated: every arm
              is a `perRun` registry lookup — `activeDictVarOfEncl`/`activeDictVarForEncl`/
              `enclDictVarOf`/`opDictVarOf`/`activeDictPredOf`/`ifaceOfMethodName` — none reaches
              a selector) and **FALSE for `entailFallback` at this pin**: `EKNestedTop`'s
              `CountImpls` policy goes `undeterminedRoute` → `routeUndeterminedTop`, whose
              exactly-one arm calls `argImplRequiresRoutes` → `selectReqImpl` (`:20036`). Writing
              the packet's form verbatim would have inscribed a property the tree violates on
              its first read — the exact failure this bite exists to end. The block therefore
              states the assum trio as an absolute, and names the fallback path as a
              **derived non-violation**: that rung answers THIS goal by COUNTING
              (`implHeadTagsForIface`, exactly-one, else `T-AMBIGUOUS-INSTANCE`), never by
              selection, and only then routes the chosen impl's own nested `requires` as a FRESH
              sub-goal descending the ladder again. The forbidden shape — the fallback rung
              answering the ladder's own goal by selection — is stated explicitly, and the
              `KeepNone` policy (every element-dict recursion) cannot reach even this path.
could move:   NOTHING, and the reason is structural rather than an assertion: **the diff contains
              no expression**, only `--` lines, mechanically confirmed by the grep quoted in
              `sites:`. Corroborated end-to-end: `make medaka` exit 0 (full 2-stage rebuild) and
              `make check-self` **PASS** on the rebuilt binary; `medaka fmt --check` 0 and
              `medaka lint` 0 on the edited file, before AND after the rebuild. Comment-bearing
              record decls were not touched — every edit is a free-standing `--` block above a
              FUNCTION or a signature, so #829's record-header hazard has no site here.
nearest miss: The property inscribed is about PLACEMENT of selector calls, not about lookup
              correctness, so the nearest program it does not cover is the **`D1-leak`
              fall-through**: a rigid, in-scope goal whose `assum` lookup MISSES, so the ladder
              falls through to `inst` and re-resolves it by selection. That is a real
              re-resolution TODAY, on a correct-by-this-property tree — the selector call sits in
              the `inst` arm exactly where the rule allows — and **this bite does not fix it**.
              #1127 legs 1–2 are B-1's, and B-1 is out of this sprint's scope
              (RUN-P3 scope ruling), so the leak survives the sprint. Second nearest: the
              `[keyTable]` parameter that (2) now calls dead is still PRESENT in every signature
              on that chain (the set is a command, not a number written here:
              `grep -n 'KeyBuckets ->' compiler/types/typecheck.mdk`); naming it dead does not
              remove it, and the sweep that does is owed.
engines:      **None moved.** No emitted byte changes: comment-only, and the LLVM/wasm/eval/
              core_ir_eval arms all consume the AST after comments are discarded by the lexer.
              No peer is owed a mirroring edit — `eval.mdk`/`core_ir_eval.mdk` carry no copy of
              these comments (they are about the typechecker's routing ladder, which has no
              parallel in the eval drivers).
unchecked:    (1) **BLESSED ZERO GOLDENS, per the packet.** `diff_compiler_snapshot_frontend.sh`
              was RUN (not blessed) and reports 4 failures in the `compiler` family:
              `typecheck.mdk` (SOURCE, DESUGAR, MARK), `core_ir_lower.mdk`, `eval.mdk` (same
              sections) and `route_key.mdk` (no snapshot). **Three of the four are inherited, not
              mine** — `core_ir_lower.mdk` and `eval.mdk` are UNMODIFIED in this working tree
              (`git status` lists only `typecheck.mdk`), so they are `b1`+`e`'s deferred re-cut,
              and `route_key.mdk` is `a`'s owed CREATE. (2) **My edit provably cannot have moved
              `typecheck.mdk`'s DESUGAR/MARK sections, and did not need to be measured to know
              it:** those sections contain **zero** location-like tokens (`grep -cE '[0-9]+:[0-9]+'`
              from `# DESUGAR` to EOF of the committed golden → **0**), so a line-shifting comment
              edit cannot reach them; and the golden's own `source_lines=29596` against `HEAD`'s
              29763 shows the file was already 167 lines past its golden BEFORE this bite. That
              is also the derivation behind the packet's instruction NOT to compress for line
              count, and it held. (3) **Not run:** the gate suite at large, `selfcompile_fixpoint`,
              `typecheck_compiler_source.sh`, perf/scaling, the wasm gates, `diff_compiler_selfproc`
              — justified by (2)+`could move:`: with no expression in the diff there is no
              behaviour for them to grade, and the LEG A/snapshot goldens they touch are the
              close-out re-cut's, which this bite is forbidden to bless.
