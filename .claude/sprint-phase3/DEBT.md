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
              when an origin exists — #1182's fix, AVAILABLE and APPLIED NOWHERE), `routeWordFor`
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
              bite; #1182 is not fixed until a later bite points `implKeyTc`/`implKeyOf` here. The
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
