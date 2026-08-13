# Stage B sprint — DEBT.md

**Append-only, one row per bite.** The sub-orchestrator is the single writer of history;
implementers hand back a row and the sub-orchestrator commits it with the bite.

> ⚠️ **This run trades verification latency for implementation throughput. That trade is only
> safe because the debt is WRITTEN DOWN.** An agent that skips a row has not saved time — it has
> converted a deferred check into **a check nobody will ever know to make.**

## Row format (contract §4)

```
### <bite id> — <unit> — <one-line description>
sites:        <the files:lines actually touched>
transform:    <what was applied>
could move:   <what acceptance behavior could plausibly have changed, incl. "nothing — pure rename">
nearest miss: <the nearest program this does NOT cover, and what it does today>
engines:      <LLVM / wasm / eval — which arms this bite moved, and which peers it owes>
unchecked:    <what I did not verify, and why>
```

**`could move:` and `nearest miss:` may not be left blank.** *"Nothing, and here is why"* is
valid; **silence is not.** The referee bounces any row missing `could move:`, `nearest miss:` or
`engines:`.

Why each field exists — these are earned, not ceremonial:

- **`could move:`** is what the repair round reads. It cost nothing in Stage A and produced the
  attack list that found 2 S0 regressions, an architectural contradiction, and a pre-existing S0.
- **`nearest miss:`** — *state and TEST the nearest program your fix does NOT cover.* Stage A's
  repair round exists because that went unasked and **an S0 survived one added type signature.**
  Once mandatory it found a live S0 on the first try (#1599). A fix verified only against its own
  repro is verified against the **bug report**, not the defect.
- **`engines:`** is specific to this stage. B-2 moves dispatch in **three** engines. A bite that
  lands the LLVM arm without naming its wasm and eval peers has created a divergence that
  `diff_compiler_engines` — deferred to the repair round — **will not see until then.**

## Standing hazards for every row in this ledger

- **The gate suite is structurally blind to this run's characteristic failures:** value goldens
  cannot see a diagnostic-only change; absence probes cannot see an undercount; **eval agreement
  proves nothing on a dispatch shape.** Do not offer any of those three as verification.
- **eval is a known-wrong oracle on exactly the shapes this stage moves** (#1071, #1062 are
  eval-only S0s on the drain list). Deriving expected behaviour from what eval prints **enshrines
  the bug.** Work the answer out from the DICT spec first.
- **Zero goldens are blessed for the entire run.** They are re-cut **once**, from the final
  binary, never merged and never hand-resolved.

---

*(Bite rows are appended below, in landing order.)*

### B-3-a — B-3 — fused per-entry write op for the fn-constraint triple; `CSlot` reaches the PRODUCERS

sites:        `compiler/types/typecheck.mdk:24304-24323` (new `setFunConstraintEntry`) ·
`:24325-24330` (`registerMember`'s doc, re-worded) · `:24341-24344` (`registerMember`) ·
`:24346-24353` (`keptConstraintArgs`' doc, prefix caveat added) · `:24361-24380`
(`keptConstraintIfaces` **DELETED**; `registerMemberSlots` re-signed
`List (IfaceRef, Mono) -> List CSlot`) · `:25392-25403` (`registerInferredFor`) ·
`:9040-9046` (new `setCrossFunConstraintTables`) · `:14274-14282` (cross-module snapshot
write). Plus the shared write op used by B-3-b at `:9019-9038`.

transform:    #994's documented **fallback** (a fused paired *write op*), not its headline
single record-valued table. Three per-entry/whole-table writes of
`funConstraintsRef`/`funConstraintArgsRef`/`funConstraintIfacesRef` now go through ops that
take **one** slot list. The slot type is the EXISTING `CSlot` (`:5537`, U1b/#1482) — whose
own header says it exists *"so that NO consumer of a callee's constraint slots ever holds
two parallel lists again."* This bite extends that to the **producers**: `registerMember`'s
ids and ifaces used to be two independent traversals applying the identical
`normalize mono`-is-a-`TVar` filter (`registerMemberSlots` + `keptConstraintIfaces`), now
one traversal emitting `CSlot`s; `registerInferredFor`'s ifaces are a `map` over the very
id list that is stored. `funConstraintArgsRef` stays a separate **`Option`** entry-level
payload, per RUN-B-016.
⚠️ **The `Option` is not only about `registerInferredFor` inventing a value.** Derived
here, not relayed: `keptConstraintArgs`' second clause (`keptConstraintArgs _ [] = []`)
stops when the vector list runs out, and its producer `constraintVarArgMonos` (`:24285`)
**drops constraints absent from the tvs map** — so the args payload is legitimately a
**PREFIX** of the slots. Folding it into `CSlot` would have had to either truncate the id
list (a dict-**ARITY** change) or invent a vector. That fact was not in the brief and it is
an independent reason the headline fusion is wrong for this triple; recorded in
`keptConstraintArgs`' own doc.

could move:   **(1) One evaluation-order change, and it is the whole risk of this bite.**
`registerInferredFor` used to compute `map (ifaceForInferredId m) ids` *inside the second
`setRef`'s argument* — i.e. **after** `funConstraintsRef` had already been given
`(m, ids)`. It is now computed before any write. Sound **iff** `ifaceForInferredId` reads
neither fn-constraint table; I traced its entire read set to `implObls` (`:25486`),
`schemeObligationsRef` (`:25431`) and `dictApps.items` (`:25433`) through all six callees
(`ifaceForConstraintId`/`Go`, `lookupSchemeIface`, `lookupIfaceById`, `ifaceFromDictApps`,
`ifaceAtMonoId`) — **no read of `funConstraintsRef`, `funConstraintIfacesRef`,
`funConstraintArgsRef`, `activeDictVars` or `promotedRef`.** If a future fallback (4) *did*
consult them, this reordering silently changes recovered iface names, hence route keying.
**(2) Write ORDER within `registerMember` changed** from ids→args→ifaces to
ids→ifaces→args. Three distinct refs, no reader between them, per-ref prepend order
unchanged ⇒ table contents identical. **(3) Nothing else can move: no ref changed type, no
payload changed shape, dict arity is a function of the stored id lists and those are the
same expressions.** **(4) `keptConstraintIfaces` is DELETED** — a removed top-level binding,
so the selfproc **LEG A** `types.typecheck` golden moves (a deletion, i.e. NOT
additive-only: re-cut must show exactly that one binding gone and no existing binding
re-typed). `registerMemberSlots`' signature also changed, so its LEG A line moves.

nearest miss: **A writer that adds an entry to `funConstraintsRef` WITHOUT going through
the op.** This bite does not and cannot prevent that — `setFunConstraintEntry` is a
convention-with-a-type, not a capability. Four such writers exist today and are **untouched
by design**, because they are whole-table replacements rather than per-fn registrations:
`:20399-20404` (the Module arm restoring both tables from `crossRun`, then prepending
`aliasConstraintEntries` to both — **two** co-write pairs), `:20657-20662` (the reverse
snapshot into `crossRun`, including the `*QualRef` pair), and `:28310`/`:28342`
(`scopeArities` reseeds, **ids-only** — these write `funConstraintsRef` and leave
`funConstraintIfacesRef` alone). **What those do today:** exactly what they did before this
bite; the convention survives at those four sites. The ids-only pair in particular means
"every ids entry has a parallel ifaces entry" is **still false** program-wide, and a reader
that assumed otherwise is no safer than yesterday. 🚩 **Flagged for the orchestrator rather
than absorbed** — they were not in the brief's site list and folding them in would have
been silent scope growth.

engines:      **None of the four moved, and none is owed. Reason, not the word:** all four
arms (`backend/llvm_emit.mdk`, `backend/wasm_emit.mdk`, `eval/eval.mdk`,
`ir/core_ir_eval.mdk`) see these tables only through what the elaboration *derives* from
them — dict arity on the define side, dict application on the call side. Every write here
stores the **same list values** as before (same expressions, same filter, same order), so
there is no derived value for an engine to see differently. **No engine file was opened**
and the diff contains no engine path. The one place this bite could have reached all four is
the `CSlot` truncation hazard in the args payload — declined above precisely because it
would have changed dict arity, which IS a four-arm event.

unchecked:    **Not built, not gated — by instruction.** Verified: `medaka fmt --write` +
`medaka lint` on `typecheck.mdk` (exit 0), whole-project `medaka lint compiler stdlib
sqlite` (exit 0, so the hook's cross-file `rule-duplicate-body` scan is clean over the two
near-identical new table ops), and `sh test/check_self.sh` → **PASS, exit 0** (read-only
`./medaka check` over the `medaka_cli.mdk` closure — no rebuild, no oracle). ⚠️ **That
check_self ran on the PRE-EXISTING binary**, which is now stale w.r.t. this diff; it proves
the *source* is type-clean, not that a binary built from it behaves. **NOT run:** any
differential gate, any golden, the self-compile fixpoint. **Owed to the orchestrator:**
`make medaka` + `check-self` + `selfcompile_fixpoint.sh`, and the two moved golden families
(snapshot `test/snapshots/compiler/typecheck.md`, selfproc LEG A
`types.typecheck.golden`) — **blessed by nobody in this run.** Also unchecked: `make
docs-links` / `make agent-doc-symbols` after B-3-e.

---

### B-3-b — B-3 — `expandSupersTable` fuses the STORAGE by delegating to `expandSupersCross`

sites:        `compiler/types/typecheck.mdk:9019-9038` (new `setFunConstraintTables` +
its hazard note) · `:9065-9077` (`expandSupersTable`, re-implemented). `expandSupersCross`
(`:9079-9085`) is **unchanged** — it was already the safe form.

transform:    `expandSupersTable`'s two `setRef`s become **one** call:
`setFunConstraintTables (expandSupersCross allDecls <idsRef>.value <ifacesRef>.value)`.
🚨 **This is the answer to RUN-B-014, and it is stronger than the "preserve an ordered
interior" the brief asked for.** The hazard was that the pre-edit `:9039`'s id expansion **read the
pre-expansion iface table** which the pre-edit `:9040` then overwrote, so writing both members
simultaneously double-expands the super slots and changes **dict ARITY**. Rather than
keeping the two writes ordered by statement position — which a later edit can reshuffle
with no diagnostic — the expansion is transposed into a **pure function that takes both
tables as parameters and returns both results**, so both reads necessarily happen before
either write. The ordering constraint is now discharged by the type, and the forbidden
implementation is no longer expressible at this site. Bonus, and it is the reason
`expandSupersCross` was the right target rather than a fresh helper: `expandSupersTable`
and `expandSupersCross` are now **one expansion implementation**, so the "both must move
together or a cross-module constrained fn under-fills" lockstep requirement is structural
instead of a convention across two functions 30 lines apart.

**Byte-equivalence argument, stated so it can be attacked:**
old = `ids' := map (expandSupersEntry allDecls ifaces_old) ids_old` ; then
`ifaces' := map (expandSupersIfaceEntry allDecls) <read of the ifaces ref>`, which is still
`ifaces_old` because the first write targeted the *ids* ref. new = both projections computed
by `expandSupersCross` from the same `ids_old`/`ifaces_old`, then both written. **Same two
values.** `expandSupersEntry`/`expandSupersIfaceEntry` read no fn-constraint ref (their only
ref read is `driverState.value.userIfaceNamesRef`, via `superSlotsOf:9138`), so the
transposition cannot change either projection.

could move:   🚨 **DICT ARITY, named explicitly as RUN-B-014 requires.** If this transform
is wrong, the failure is **not** in the diff: `expandSupersTable` is the ONE finalization
point whose own header (`:9061-9063`) exists so that define-side `dictArityOf` and call-side
`recRoutes`/`recRoute`/`inferDictAtFound` see **identical expanded entries**. A
double-expanded super slot means the define side binds **more** dict params than the call
site applies — the **S-1 under-application** shape: `check` green, `run` type-confused,
`build` printing a raw PAP pointer. **My claim is that arity cannot move, on the equivalence
argument above; the gate that can falsify it is `test/selfcompile_fixpoint.sh`, and it is
the only local signal that would.** Secondary, much smaller: if Medaka's tuple construction
were *lazy*, `snd tables` would be forced after the first `setRef` — still safe, because
`ifacesTbl` is a captured argument **value**, not a re-read of the ref. Medaka is strict, so
this is belt-and-braces.

nearest miss: **A THIRD expansion path that mutates only one of the pair.** Grep of every
`expandSupers*` caller: `expandSupersTable` (this bite), `expandSupersCross` (the
cross-module snapshot, B-3-a's site 3), and two direct `expandSupersPairs` callers at
`:8860` (in `declaredConstraintSlots`, `:8803`) and `:12052` — **both of which operate on a `List CSlot`
they already hold and write NO table**, so they are outside this hazard by construction and
were correctly not in the brief. What they do today is unchanged. **The program this does
NOT cover:** a future caller that expands one table's entries in place. Nothing prevents it;
`setFunConstraintTables`' comment is the only warning, which is why the hazard note lives on
the op rather than in a ledger.

engines:      **None of the four moved; none owed** — and this is the bite where that
statement needs its reason spelled out, because dict arity IS a four-arm quantity
(`llvm_emit` param counts, `wasm_emit`'s peer, `eval`'s `applyDicts`, and
`core_ir_eval`'s `VTypedImpl`/`CImplEntry` consumption all key off it). The reason none
moved is that the **values written are the same values** (argument above), so arity is
unchanged and there is nothing for an engine to observe. Had the fusion been implemented as
the issue's headline describes, this row would read **all four arms moved**.

unchecked:    As B-3-a's row (same verification set, same owed set). ⚠️ **Specifically NOT
checked and it is the one that matters:** no fixpoint, no `diff_compiler_*` differential,
so the arity claim rests on the source-level equivalence argument alone. There is also **no
fixture in the tree that would fail on a double-expansion** that I could find without
building — the shape needs a user `interface Sub a requires Sup a` reached cross-module, and
whether the existing supers corpus discriminates a 1× from a 2× expansion is **not
established**. Flagging that as the sharpest residual in Phase 1.

---

### B-3-c — B-3 — fused write op for the method-constraint pair; positions derived inside the op

sites:        `compiler/types/typecheck.mdk:23734-23739` (`registerMethodConstraints`) ·
`:23741-23757` (new `setMethodConstraintEntry`).

transform:    The sole co-write site now calls one op that takes `mname`, `fullIds` and
`ids`, and **derives** the positions entry (`map (id => indexOfInt id fullIds) ids`)
**inside** the op from the same `ids` list it stores. Previously the caller held `ids` and
mapped it into the second table itself. Effect is byte-identical; what changes is that the
two tables can no longer be given different lengths or a different slot order, because
there is only one `ids` list and one caller-visible entry point.
⚠️ **NOT `Option`, and NOT a fused table — deliberately, and for a reason different from
B-3-a's.** Verified rather than relayed: `methodConstraintPositionsRef` has **exactly one**
writer (this site) and **one** reader (`alignedMethodConstraintIds:8613`), while
`methodConstraintsRef` has ids-only writers at `:20598`, `:20663`, `:28311`, `:28344` — and
positions-**ABSENCE** selects the reader's fallback arm. A single record-valued table would
therefore need `Option` positions, and a non-optional field would **change which arm runs**,
not merely invent data. Keeping the tables separate keeps absence representable *by there
being no entry at all*, which is strictly safer than an `Option` that a later default could
collapse.

could move:   **Nothing, and here is why.** The op is a pure extraction of two adjacent
`setRef`s from one `else` branch: same guard, same key, same two payload expressions, same
order, and **neither table is read between the writes** (confirmed by reading the branch).
The only inputs are `mname`, `fullIds`, `ids`, all already in scope at the old site and
passed unchanged. No signature of any existing binding changed. Residual: `indexOfInt`
returns `-1` for an absent id (`:23762-23766`) — that behaviour is preserved verbatim, and
if it ever fires it now fires inside the op, which is where a future diagnostic would go.
Golden impact: one **added** top-level binding ⇒ the selfproc LEG A golden gains a line
(additive-only, unlike B-3-a's deletion).

nearest miss: **The four ids-only reseed sites, which this bite does not touch and must
not.** `:20598` (`methodConstraintsRef ++ crossModuleMethodConstraintsRef`), `:20663` (the
reverse snapshot), `:28311` and `:28344` (`scopeMethodArities`). Each writes ids with **no**
positions entry, and `alignedMethodConstraintIds` takes its `positionMatch`-miss arm for
those methods — i.e. **the fallback path is live in normal multi-module operation, not an
edge case.** A "fix" that gave those sites a positions entry (or that made the fused table
default positions to `[]`) would silently move every cross-module constrained method off
the fallback arm. That is the S0 shape hiding behind this bite and it is why the headline
fusion is refused here.

engines:      **None of the four moved; none owed.** `methodConstraintsRef` /
`methodConstraintPositionsRef` reach an engine only via the method-dict arity and route the
elaboration computes from them (`methodDictArityOf`, `constraintMonosOf`); both tables
receive byte-identical contents, so no derived value changes. No engine file opened; the
diff contains no engine path.

unchecked:    As B-3-a's row. Additionally not checked: that the `-1` sentinel from
`indexOfInt` is genuinely unreachable (its own comment says *"absent shouldn't happen"* —
I neither confirmed nor refuted that, and this bite does not change its reachability).

---

### B-3-e — B-3 — two doc corrections: a dead `implOblToU` citation, and `D1–D6` → `OD1–OD6`

sites:        `docs/spec/DICT-SEMANTICS.md:2491` (§11's `§4.2 OD4` row) ·
`compiler/TYPECHECK-TARGET-ARCHITECTURE.md:749` (design-doc row H).

transform:    (1) §11's OD4 row cited the method-occurrence channel's argument as
`` `map implOblToU perRun.value.implObls.items.value` `` — a symbol with **zero definitions
and zero call sites** since #991. Replaced with the live expression
`` `perRun.value.implObls.items.value` ``, plus a clause saying the bridge was retired
because `implObls` is now `Windowed UObligation` already. **Verified against the tree, not
the issue:** the two live calls are `checkCallObligations True False fullUniverse
perRun.value.implObls.items.value` (`typecheck.mdk:20701`, Flat arm) and
`checkCallObligationsU True False obUniv [] perRun.value.implObls.items.value` (`:20720`,
Module arm) — and the row's own claim *"both call sites sit in `checkBodyImpl`, one per
driver arm"* is **true** (enclosing definition confirmed as `checkBodyImpl`), so it was left
standing. (2) Row H's *"LANDED as DICT-SEMANTICS §4.2 **D1–D6**"* → **OD1–OD6**. The spec
**forbids** the bare spelling in that very section (`DICT-SEMANTICS.md:790-794`: *"§6.3
already owns `D1`–`D4` … Cite `OD`n and `§6.3 D`n; never a bare `D`n in this document"*), so
the design doc was citing a rule set that resolves to the wrong four rules.

could move:   **No behaviour — docs only, no `.mdk` touched by this bite.** What *can* move
is a doc gate: `make agent-doc-symbols` requires every backticked symbol to resolve, and
this edit **removes** an unresolvable one (`implOblToU`) while adding `implObls` and
`Windowed UObligation`, both of which resolve in `typecheck.mdk` (`:6732`). So the expected
direction is neutral-to-better. **I did not run either doc gate** (gate runs are out by
instruction) — flagged.

nearest miss: **The `D1–D6` / `implOblToU` instances I deliberately did NOT sweep** — per
the brief, reported instead of fixed:
- `compiler/types/typecheck.mdk:20697` — a code comment reading *"(projected via
  `implOblToU`)"*, describing the retired bridge as if it were the mechanism. Same defect,
  in source, in a region **outside my bites**; invisible to both doc gates by construction
  (`agent-doc-symbols` does not scan `.mdk`, `docs-links` checks paths).
- `.claude/STAGE-B-SPRINT.md:67` — the **contract** itself writes `§4.2 D1–D6`. Not edited:
  it is the run's own contract and the orchestrator owns it.
- `archive/DICT-CONFORMANCE-AUDIT.md:360` — *"The forward plan to close D1–D6"*. Frozen
  archive; left alone on purpose.
- `compiler/TYPECHECK-ARCH-BUG-FIT.md:862` and `TYPECHECK-TARGET-ARCHITECTURE.md:375` both
  say *"`implOblToU` retired"* — **correct prose about a dead symbol, not a dead citation.**
  Left standing. They are the shape a naive sweep would have broken.
**And the part I did not do:** P0-D's own row flagged that it *"checked OD1–OD6 only for
`implOblToU`"* and did **not** audit the rest of §11's citations. I did not either. That
audit is still owed and is not this bite.

engines:      **None — documentation only, zero code paths, zero engine files.** No peer
arm can be owed by a prose edit.

unchecked:    `make docs-links` and `make agent-doc-symbols` (both cheap, both gate runs, so
both out of scope for me — please run them). The §11 citation audit above. Whether
`docs/README.md` needs regenerating: **no** — no `**Status:**` banner was touched.


---

### B-2.1-a1 — Phase 2′ (B-2.1 precondition) — build the Flat-vs-Module grader before the change it grades

sites:        `test/diff_compiler_flat_vs_onemodule.sh` (NEW, +x, 9 rows / 3 cases) ·
`compiler/types/typecheck.mdk:14112-14119` (comment only; +8/-2) ·
`.github/workflows/ci.yml` (eval shard: +`diff_compiler_flat_vs_onemodule` + cost derivation) ·
`test/DOC-LINK-EXCEPTIONS.txt:174` (REF reason rewritten, **NOT deleted** — see below)

transform:    Added the instrument RUN-B-017 called missing, under the discoverable
`diff_compiler_*` name so `run_gates.sh`'s default pattern reaches it. It **PINS** the FLAT arm's
acceptance + diagnostic `code` per case (hand-derived from DICT §8 I5 / §3, **not captured**) and
grades the FLAT-vs-MODULE relation only via *"every ACCEPTING arm must compute the same value"* —
true on both sides of the #1564 fix. #1564's own row is CHARacterized (correct answer + today's
answer + a third-state FAIL), so the drain stays with the must-fail suite, unduplicated.

could move:   **NOTHING in compiler behaviour.** The only compiler-source byte changed is a
comment inside `elaborateOne`'s header; `fmt --write` reported *"already formatted"* and `lint` 0
findings, so no reflow reached code. The `ci.yml` and ledger edits are not compiled.
⚠️ **What DOES move:** the snapshot golden `test/snapshots/compiler/typecheck.md`, because the
compiler's own source is in the snapshot corpus and a comment edit shifts every line below it (+6
net). Per §5/§7 that corpus is expected-red for the run and **nothing was blessed**.

nearest miss: The nearest program this gate does **NOT** cover is one where the FLAT arm's
**EMITTED EVIDENCE** is wrong while its **ACCEPTANCE** is right. The `value` column comes from
`medaka run`, which takes the **MODULE** arm even on a single no-import file (the `elaborateOne`
1-module wrapper), so **no value here is a FLAT-arm observation** — the FLAT arm is graded on
acceptance + diagnostics ONLY. A FLAT-arm value needs `llvm_emit_typed_main` /
`wasm_emit_typed_main` (the `elaborateDict` entries), which are `test/bin` compiled probes,
excluded so this gate reads no oracle. Today that program behaves correctly (the flattened #1564
accepts and prints `wrap(int)` through `run`), but **a B-2.1 change that seats a NARROWER Flat
`ImplEnv` — right acceptance, wrong selected impl — would pass all 9 rows.** That gap belongs to
a Phase 3′/5 emitted-IR differential and is stated in the gate header under *"WHAT THIS GATE
CANNOT SEE."*
Second nearest miss, **tested**: FLAT decl ORDER. Both declaration orders of the flattened #1564
are rows (`flat_nest_first` / `flat_impl_first`) and both accept, so the gate would see a FLAT arm
that became order-sensitive.

engines:      **NONE MOVED, and the reason rather than the word:** this bite adds no compiler code
— the only `.mdk` byte is a comment — so none of the four arms (LLVM · wasm · eval ·
`core_ir_eval.mdk`) can have changed behaviour, and no peer arm is owed. Nor does the gate
**OBSERVE** any of the four: it drives `check` (typecheck front end, both `CheckMode` arms) and
`run` (the eval arm, incidentally, for the value column only). It is therefore **blind to an
LLVM/wasm/core_ir_eval divergence by construction** — cross-engine agreement on these shapes is
`diff_compiler_engines`' job, deferred to the repair round, and **this gate must not be read as
covering it.**

unchecked:    (1) The snapshot golden above — deliberately not re-derived, not blessed.
(2) `selfcompile_fixpoint` — not run by the implementer (no compiled byte changed); **the
orchestrator ran `check-self` → PASS** and judged the fixpoint unnecessary for a comment.
(3) **The gate has never been run against a binary in which the FLAT arm is actually broken** —
that binary does not exist yet, which is the point of building the grader first. Fail-capability
was instead proven by mutating one expectation at a time in a COPY (**6/6 RED**, incl. the
FLAT-pinned-REJECT regression direction and the value-agreement clause) plus a simulated
DRAIN-NOTICE pass. So the **failure mechanics** are verified; the **specific future regression**
is not, and cannot be until `B-2.1-a2` lands.
(4) **macOS:** not executed there (no macOS host). Portability by construction — dash-clean under
`sh`, the `perl`/`alarm` shim (reports **142**, not 124), octal-safe `printf` only, no `sed -i`,
no GNU-only flags.
(5) The two-arm `MEDAKA=` override path is implemented and was exercised only via the
fail-capability harness and a nonexistent-binary probe (exit 2), **not** against a genuine second
worktree.

---

### `B-2.1-a2` — Phase 2′ (B-2.1) — seat a real `ImplEnv` on the FLAT arm (hard precondition)

sites:      `compiler/types/typecheck.mdk`, four edits, +70 lines, **all additive** (no line
deleted, no existing expression changed — `git diff` is 70 insertions, 0 deletions):
* `:4130-4185` — NEW `buildFlatImplEnv : List Decl -> ImplEnv` (`:4175`) + NEW `ieIndexRows`
  (`:4182`), placed
  immediately after `buildImplEnvGo` (the Module-arm peer they mirror).
* `:6784` — NEW `PerRun` field `bodyImplEnvRef : Ref ImplEnv`, between `shadowKeyTableRef` and
  `pendingBinopSites`. **Added BARE, no trailing comment**, per the #829 record-comment hazard:
  `PerRun`'s header is the collapsed single-line `data PerRun = PerRun {` (the measured-safe
  form) *and* its side comments are a column-wise prose river, so the prose went on
  `buildFlatImplEnv` instead. `git diff` confirms no existing trailing comment moved.
* `:6880` — the matching `freshPerRun` initialiser `bodyImplEnvRef = Ref emptyImplEnv` (the
  record constructor makes this non-optional, which is `PerRun`'s own stated design).
* `:20450-20460` — NEW `let _ = match mode` **beside**, not replacing, the existing
  `shadowKeyTableRef` arm gate: `Flat _ => buildFlatImplEnv fullUniverse`;
  `Module _ _ _ => driverState.value.declEnvsRef.value.deImpls` (a pointer copy, not a re-derive).

transform:  Give the FLAT path the impl population it never had, on `IE`'s shape, and seat both
arms on ONE ref so `B-2.1-b` repoints one substrate instead of an arm gate. `buildImplEnv` needs a
`List DeclEnvModule` envelope that only the graph drivers build, so FLAT had `emptyImplEnv`; the
new builder takes the decl list the FLAT arm already has in hand (`fullUniverse`, the same list
`buildKeyTable` is handed one line above) and folds it through the *same* `implDeclFacts` /
`implRowsOf` / `ieInsertRowKeys` / `ieInsertRowAt` / `ieBuildSnaps` the Module arm uses. One flat
program is one scope ⇒ every row takes ordinal 0 and mid `""`; `seq` still runs across the whole
program so identities stay unique within the compile.
**`shadowKeyTableRef` and its THREE readers (`:11252`, `:11539`, `:21751` pre-edit numbering) are
untouched**, as briefed — nothing was repointed, nothing deleted. **`ieInsertRow`'s known
`ieRows ++ [r]` quadratic was NOT "fixed"**: `buildFlatImplEnv` is linear BY DESIGN instead (rows
are already one forward-ordered list, so `ieRows` is SET once and only the buckets are folded via
the index-only `ieIndexRows`), which imports no quadratic into the single-file path *and* leaves
RUN-B-007's ascending-`instRefSeq` order on the shared Module path completely alone.

could move: **NOTHING, and here is the argument rather than the assertion.** Three independent
grounds, in increasing strength:
1. **No reader.** `grep -rn bodyImplEnvRef compiler/` returns 6 hits: **four code sites** — the
   field (`:6784`), its initialiser (`:6880`), and the two `setRef` arms (`:20459-20460`) — plus
   two prose mentions in comments. **Every code site is a WRITE.** There is no read site anywhere
   in the tree, so no judgment can consult it. (Derive it; do not trust this count.)
2. **No existing expression changed.** The diff is 70 insertions / 0 deletions; the
   `shadowKeyTableRef` arm gate above it is byte-identical, and the new `let _ = match mode` is a
   sibling statement, not a rewrite.
3. **Measured, not reasoned:** `make check-self` PASS · `selfcompile_fixpoint` **C3a YES / C3b
   YES byte-for-byte** · `diff_compiler_flat_vs_onemodule` 9/9 as pinned, **0 drain notices** ·
   355 single-file `medaka check` runs with the equivalence audit armed, **0 findings** — across
   `test/{eval,eval_list,eval_dict,parse,llvm}_fixtures/*.mdk` + `stdlib/*.mdk`. ⚠️ Stated
   honestly: **330 of the 355 are no-import files and therefore the FLAT arm**; the other 25 take
   the MODULE arm, where the audit is a no-op. Two globs I wrote (`test/check_fixtures`,
   `test/types_fixtures`) **do not exist** and contributed nothing — the sweep's `-f` guard
   skipped them silently, which is exactly why the file COUNT is printed by the harness rather
   than assumed.
⚠️ The one thing that DID move and is not a behaviour: **per-Flat-compile work**. See `unchecked:`
item 3 for exactly what was and was not measured about it.

nearest miss: **An impl whose head type list is EMPTY (`tys = []`).** This is the ONE place the
two populations are known to disagree, and the disagreement is a **widening in `IE`'s favour**
(RUN-B-017 probe 2, re-derived here from the source): `keyEntryOf`'s `[] => []` arm emits
**nothing**, while `implDeclFact` keeps the row and `univReceiverTag [] = None` files it in
`ieHeadless`. So the Flat `ImplEnv` this bite seats can contain a row the FLAT `KeyBuckets` does
not. **Today that is unobservable** — nothing reads the ref — and it did not occur once in the
330-flat-program audit corpus (the row-level check is exact element-wise equality, so it would have
panicked; kt=118 / ie=118 on the probe). **But `B-2.1-b` inherits it the moment it repoints**, and
whether `tys = []` is surface-reachable at all is still one of RUN-B-017's five owed items. Second
nearest miss, and it is NOT covered: **a `Module`-mode driver that stamps a module id
`buildDeclEnvs` never indexed** — it now also seats `deImpls` on this ref, and `declEnvsOrdOf`'s
`-1` miss is vacuous under `ieCandidacyVisibleAt`, so such a driver reads the whole graph rather
than failing closed. `:17231` asserts no live path does this; I did not re-derive that assertion.

⭐ **THIRD nearest miss, ADDED BY `a4` (RUN-B-030) — it was ABSENT and R1's F1 is exactly it:
`bodyImplEnvRef` is ONE ref under TWO interface KEYINGS, selected by driver arm.** `oblIfaceKeys`
(`typecheck.mdk:21733-21736`) mints **one** key (`TkBare NsIface irName`) for an
`OriginUnresolved` interface and **two** (identity + bare) otherwise, and `flatTyOriginScope`
(`resolve.mdk:4271-4272`) deliberately holds no entry for the user's own declarations — so a
**user-declared** interface's impls file **bare-only** on Flat and under **both** keys on Module,
on the ref this row unifies. The `tys = []` miss above names a *population* difference; this is a
*keying* difference and it is the sharper one, because `B-2.1-b2` repoints a **lookup** onto it.
**`a4` ADJUDICATED IT BENIGN** — three legs, and the drain is **UN-GATED**. Full derivation and the
11-row probe: `DECISIONS.md` **RUN-B-030**. The one-line reason: the write side is a **superset** of
the read side (`oblIfaceKeys` *always* contains the bare key; the goal side mints exactly one,
`oblIfaceKey`, which **is** the bare key when the goal is identity-less — `registry.mdk:1754`), so
the only shape that can miss is *identity-bearing goal, identity-less impl*, which is the OPPOSITE
pairing and has **no producer** under the stamping-agreement invariant already recorded at
`typecheck.mdk:1591-1602`. ⚠️ **Do not read this as "the keying is uniform" — it is not, and the
asymmetry is still there.** What is established is that it is *unobservable through a keyed lookup*.
A future bite that compares two `TabKey`s for EQUALITY, or renders one into a diagnostic, an S-expr
or a golden, re-opens it immediately: `tabKeyEq` never equates `TkIdent` with `TkBare`
(`typecheck.mdk:1604-1607`), so such a bite would see Flat and Module disagree on a user-declared
interface. **That, not the lookup, is where F1 will bite.**

engines:    **NONE OF THE FOUR MOVED — reason, not word, per arm:**
* **LLVM** (`backend/llvm_emit.mdk`) — untouched. No route word, no `KeyEntry`, no dict arity, no
  symbol name changes: the bite adds a ref nothing reads and mints no new emitted name. Positively
  corroborated rather than asserted: `selfcompile_fixpoint` **C3a PASS byte-for-byte against the
  seed-bootstrapped reference**, i.e. the emitter's own emitted IR converged exactly as before.
* **wasm** (`backend/wasm_emit.mdk`) — untouched, same reason. ⚠️ Note the *consumer* side: the
  `wasm_emit_typed_main` entry reaches `checkBodyImpl` via `elaborateDict` on the **FLAT** arm, so
  it now BUILDS a Flat `ImplEnv` — but it cannot read one, so no wasm arm is owed. It is also the
  entry whose closure produced the measured `CFieldAccess: unknown field 'ieOrd'` panic when
  `ImplRow` was a named record; **`ImplRow` was not touched and stays positional**, and this
  entry's path was exercised: `check-self` PASS, and the emit entries are the FLAT path the
  audit sweep covered (330 no-import programs).
* **eval** (`eval/eval.mdk`) — untouched. Dispatch is unchanged; `IE` construction is
  typecheck-internal. Corroborated: the flat gate's `value` column comes from `medaka run` (the
  eval-driven MODULE path) and both accepting cases still print `wrap(int)`.
* **`core_ir_eval.mdk`** (AMENDMENT 3's required fourth arm) — untouched, and **no lockstep peer
  is owed**: the `evalModules` ‖ `cevalModules` law is about MODULE-FRAME semantics, and this bite
  adds no frame, no env cell and no name — it seats a typecheck-internal ref before inference. Not
  reasoned only: `grep -n 'ImplEnv\|ieRows\|bodyImplEnvRef' compiler/ir/core_ir_eval.mdk` returns
  nothing, so there is no peer site to mirror.
**Owed by later bites, not this one:** `B-2.1-b`'s repoint is the first change that can move any
engine, because it is the first thing that READS this ref.

unchecked:  (1) **Goldens/snapshots, deliberately.** `test/snapshots/compiler/typecheck.md` moves
(+70 lines of compiler source, all below existing lines) and `test/selfproc_goldens/legA/types.typecheck.golden`
gains `buildFlatImplEnv` / `ieIndexRows` (LEG A includes `types.typecheck`, and the golden is
additive-only here — no existing binding's inferred scheme can have changed, since no existing
signature was touched). **Blessed by nobody**, per contract §5. Both are expected-red for the run.
(2) **No seed re-mint run and, in my judgement, none needed** — `test/refresh_seed.sh` was NOT
executed, per the brief. The evidence: `selfcompile_fixpoint` C3a passed **byte-for-byte against
the seed-bootstrapped converged reference**, which is precisely the comparison a stale seed fails.
Orchestrator's call, flagged rather than assumed.
(3) **PERF: no A/B was measured, and the brief did not require one.** Its measurement clause was
conditional on using `ieAddRows`, which this construction deliberately does not. What IS derived
(from the audit's own positive-control output on a minimal no-import program): the FLAT arm now
does **118 rows → 235 distinct index keys** of work per compile — one `flatMap` over the decls
(the same walk `buildKeyTable fullUniverse` already makes one line above), 118 `InstRef` mints,
235 `mregAppendK`/`regInsertK` inserts, and 118 `insertUnivImpl`s producing exactly ONE
`ieUnivSnaps` entry (all rows share ordinal 0). All linear; the Module arm already pays the same
per-row cost for the same population. **Not measured: net allocation, and no wall-clock A/B** — a
base-arm binary would have cost two extra 75 s builds plus a source swap, and wall-clock on this
shared box cannot resolve a delta this size. A two-worktree allocation differential is the honest
instrument and belongs to the repair round.
(4) **The equivalence check's discrimination axis.** It compares
`iface-name | ppTyAtom heads | requires | method-names`, which is the axis `KeyBuckets` itself
keys on (`implKeyTc`). It therefore does **NOT** discriminate `IfaceRef.irOrigin` — `IE`'s extra
identity precision, which `KeyBuckets` has no peer field for — nor `InstRef`, nor `ieIfaceTags`,
nor `ieUnivSnaps` contents (the snapshot table was checked only structurally, by the reasoning at
`buildFlatImplEnv`, not digested). Two genuinely distinct impls could render identically only if
they shared iface name, head spelling, requires and method names, i.e. were duplicate impls.
(5) **The audit is not committed and cannot regress-guard.** It was temporary instrumentation in
`typecheck.mdk`, removed before handoff (`grep -n 'ieAudit\|TEMP-AUDIT' compiler/types/typecheck.mdk`
→ nothing). Re-deriving it is ~60 lines; the probes are at
`/var/tmp/medaka-scratch/.../scratchpad/probe/`, which is session-scoped and will be reaped.
(6) **`make preflight`, the differential gates, must-fail and the doc gates were not run**, per
the run's deferred-verification posture. Only `check-self`, the fixpoint, the flat gate,
`fmt --check`, per-file `lint`, and the whole-project `lint compiler stdlib sqlite` (0 findings)
were executed.

#### `B-2.1-a2`'s own equivalence check — and why the gates could not have supplied it

**An additive population nothing reads is UNOBSERVABLE**, so `make medaka` + green gates prove
nothing about whether the Flat `ImplEnv` is *correctly* populated — and RUN-B-020 already recorded
that `diff_compiler_flat_vs_onemodule` **cannot** see it either (a NARROWER Flat env is right
acceptance with a wrong selected impl and passes all 9 rows). A silently-empty or silently-narrow
env would therefore have passed everything in this tree and detonated in `B-2.1-b`.

So the bite carried its own grader: **temporary instrumentation inside `typecheck.mdk`**, armed on
the FLAT arm only, panicking on disagreement — the retired `ieShadowCompare` idiom. **Two
independent checks, both element-wise and order-sensitive, neither a count:**

1. **POPULATION vs `buildKeyTable`'s own source.** `map render (flatMap keyEntryOf fullUniverse)`
   compared as an ordered `List String` against `map render ieRows`, where `render` is
   `iface | ppTyAtom heads | requires | method-names`. Same walk `buildKeyTable` makes, same
   program, same order. Catches undercount, overcount, reordering, and a wrong head/requires/method
   payload.
2. **INDEX vs ROWS.** For every distinct registry key derived from the rows
   (`regKeyNTab [ifk, dispHeadTab hk]` into `ieConcrete`, `regKeyOfTab ifk` into `ieHeadless`, one
   per `oblIfaceKeys` element), the bucket's contents compared element-wise against the rows that
   key into it. **This is the check for the narrow-env gap RUN-B-020 named**, and being
   order-sensitive it is also the check for RUN-B-007's ascending-`instRefSeq` bucket order.

**POSITIVE CONTROL — the audit is provably not a no-op.** A sentinel arm makes it loud on a program
declaring `interface IeAuditPing`: `medaka check` on such a file panicked
`IEAUDIT OK rows=118 keys=235 ping=IeAuditPing|Int||pingv` — so on a minimal no-import program the
Flat env holds **118 rows under 235 distinct index keys**, includes the user's own impl, and *both*
checks had already passed (they panic earlier than the verdict). Without this, "no panic over 330
programs" would have been indistinguishable from "the audit never ran".

**FAIL-CAPABILITY — PROVEN, BOTH CHECKS, not asserted.** Two further ping-gated mutations were
compiled into the same audit binary and each observed RED:
| mutation | observed |
|---|---|
| index built from `tail rows` (rows intact) | `IEAUDIT BUCKET MISMATCH key=1:25:iface6:module4:core2:Eq4:type4:bare0:3:Int` · `expected=Eq\|Int\|\|eq` · `actual=` |
| `ieRows` set to `tail rows` (index intact) | `IEAUDIT ROWS MISMATCH kt=118 ie=117` |
So the row check catches a missing row and the bucket check independently catches a row that is
present but unindexed — **the exact narrow-env failure the flat gate is blind to.**

**AND THE SWEEP HARNESS ITSELF WAS CONTROLLED.** `corpus.sh` reported `files=355
audit_findings=0`; the identical detection path pointed at the two mutation probes reported
`files=2 audit_findings=2`. A zero from that script is therefore a clean corpus, not a broken
grep — which is the failure this tree calls *"a probe that cannot fail is not evidence."*

**Then the instrumentation and both mutation hooks were removed and the binary rebuilt from the
stripped source**, and every gate above was re-run on that clean binary (the audit-build results
were not carried over). `git diff` on the handed-back tree is 70 insertions / 0 deletions with no
`ieAudit` symbol anywhere.

---

### `B-2.1-b1` — Phase 2′ (B-2.1) — 🛑 **REFUSED AND REVERTED: the bite needs a THIRD leg. Two is a severity INCREASE.**

**Nothing landed. `compiler/types/typecheck.mdk` is byte-identical to `5d499dfb`.** The transform was
written, built and measured; it is **not shippable as briefed** and is parked as two patches in the
scratchpad (paths at the bottom of this row). What follows is the measurement, because the
measurement is the deliverable.

sites:      **Implemented and then reverted** — `compiler/types/typecheck.mdk`:
            `keyEntryOfRow` (new, beside `keyEntryOf`); `ieCandidateEntries` / `ieConcreteEntries` /
            `ieHeadlessEntries` / `ieIfaceBareTab` (new, beside `candidateBucket`/`mergeByDeclIdx`);
            `selectImplEntryByIfaceIE` / `matchingEntriesByIfaceIE` / `bodyImplEnv` (new, beside
            `matchingEntriesByIfaceGo`); `headCollidesByIfaceIE` / `countHeadByIfaceIE` /
            `ieBucketEntriesFor` (new, beside `countHeadByIfaceGo`); repointed
            `concreteReqMatchByIface`, `selectReqImpl` (iface-known arm) and `keyForSiteByIface`.
            +206/−11 before the experiment. **On disk now: nothing.**

transform:  Repoint every caller of the **iface-keyed** min⊑ selector off `KeyBuckets` (a
            topological PREFIX on the Module path — `shadowKeyTableRef` ← `universeKeyBucketsRef`
            on the checker's leg, `stampKeyTable = buildKeyTable implDecls` on the router's) onto the
            graph-global `perRun.value.bodyImplEnvRef` that `B-2.1-a2` seated. One adapter
            (`keyEntryOfRow`, index field = `instRefSeq`), one accessor pair over
            `ieConcrete`/`ieHeadless` keyed through the **bare** `oblIfaceKeys` leg (the only key a
            bare-`String` caller can mint, and the leg that reproduces `matchingEntriesByIfaceGo`'s
            `ifn == iface` spelling filter exactly), `candidateBucket`'s empty-headless fast path
            preserved, `mergeByDeclIdx` reused, `pickMostSpecificEntry` reused, **no second
            selector.** All `KeyBuckets`/`ImplBuckets` parameters retained (`_`-prefixed) per
            RUN-B-007 AM-1.

            ⭐ **ONE DERIVED ADDITION TO THE BRIEFED SITE LIST, and it is not optional.** The brief
            named `selectReqImpl` and `argReqRoute` as the router leg. **`argReqRoute` performs no
            selection at all** — it is a `routeOfD` adapter; its selection happens downstream in
            `entailInst`'s `EKNestedTop` arm, which calls `keyForSiteByIface … iface (m::rest)` for
            the route WORD and `argImplRequiresRoutes … m rest` (→ `selectReqImpl`) for the
            `requires`, **on the same interface and the same goal vector — one selection computed
            twice.** Repointing one and not the other attaches impl A's dictionary to impl B's route
            word: a §6 C2 violation, i.e. the bite's own failure mode one organ over. So
            `keyForSiteByIface` and its collision retest (`headCollidesByIface`/`countHeadByIface`,
            which would otherwise miss a collision that exists only in a later module and stamp the
            bare head word where the canonical key is required) moved with it.

could move: 🔴 **IT DID MOVE, AND THE DIRECTION IS A SEVERITY INCREASE. This is the finding.**
            On #1564's own fixture, measured four-arm on a freshly built binary:

            | arm | `5d499dfb` (base) | two legs (as briefed) | three legs (experiment) |
            |---|---|---|---|
            | `check main.mdk` | **1**, `T-REQUIRES-UNROUTED` | **0**, `main : Unit` | **0** |
            | `run main.mdk` | 1 (rejected) | **1**, `E-PANIC: putStrLn: not a String` | **0**, `wrap(int)` |
            | `build main.mdk` | 1 (rejected) | **0** | **0** |
            | built binary | — | **139**, `fatal memory fault` | **0**, `wrap(int)` |
            | `control.mdk` (all four) | clean, `wrap(int)` | clean, `wrap(int)` | clean, `wrap(int)` |

            The two-leg move converts a **loud located reject into `check` exit 0 plus a segfaulting
            binary** — `AGENTS.md`'s *"a fix that makes a defect QUIETER is a severity INCREASE"*,
            and #1560's S-1 under-application shape verbatim. **#1564's own `claim.txt` predicted
            exactly this state** (*"this pin grades `check` ONLY … a clean drain for half a drain.
            Re-run `medaka run main.mdk` and the built binary before closing"*), and the must-fail
            pin **would have reported it as DRAINED**. It was caught by
            `diff_compiler_flat_vs_onemodule.sh`'s VALUE clause, not by the pin — which is precisely
            the assert choice RUN-B-020 recorded, doing the job it was built for on its first real
            change.

            **EMITTED-IR EVIDENCE, the same fixture, `medaka build --keep-ir`:**
            - base/control (correct): `define i64 @mdk_impl_Wrap_tagOf(i64 %arg0, i64 %arg1)` called
              as `call i64 @mdk_impl_Wrap_tagOf(i64 %arg0, i64 %t2)` from inside
              `@mdk_nest__nest` — `%arg0` is `nest`'s own dict param, **forwarded**.
            - two legs: the *define* is still arity-2 and `@mdk_nest__nest` is still arity-2 and the
              caller still passes `@mdk_dc_0` — **so the checker leg DID move: the scheme gained its
              `λd̄.` slot and the call site fills it.** What is missing is one level in:
              `call i64 @mdk_impl_Wrap_tagOf(i64 %t2)` — **arity-1 call to an arity-2 define.** The
              value cell lands in the dict slot and the impl loads a function pointer out of it.
              That is the 139.

            🚨 **ROOT CAUSE, PROVEN BY EXPERIMENT RATHER THAN INFERRED — THE THIRD LEG.** The
            element-dict routes that forward `nest`'s dict into the impl come from the
            **METHOD-keyed** selector: `implDictRoutesForFull` / `argImplDictRoutesForEncl` are both
            gated on `matchedEntry keyTable name goals` → `matchingEntries` → `candidateBucket`, over
            the **prefix** `stampKeyTable`. At `nest.mdk`'s module that table cannot see
            `wrapimpl`'s impl (it sorts later), so `matchedEntry` answers `None`, the element-route
            list is `[]`, and the primary route word is still right only by `entailInst`'s `tag`
            fallback. I had reasoned this leg was safe to leave because its word and its element
            routes both read one prefix table and are therefore *consistent with each other* — true,
            and **irrelevant**: they are consistent with each other and inconsistent with the
            *scheme arity* the checker leg now produces. **Measured, not argued:** with
            `matchingEntries`' population made graph-global (a throwaway O(rows) scan over `ieRows`),
            #1564 goes to `wrap(int)` on **all four arms**, identical to the control, and
            `diff_compiler_flat_vs_onemodule.sh` **PASSES with 1 drain notice** — the exact
            deliverable state the brief describes.

            **Why that experiment is not the fix.** It is an O(rows) scan per goal in what
            `candidateBucket`'s own header calls *"the checker's hottest selector"*, and
            `ieRowsVisibleAt`'s 🚨 PERF banner forbids a per-goal `ieRows` caller by name.
            Measured cost on the compiler's own closure: `make check-self` **21.5 s → 25.1 s real,
            32.5 s → 38.2 s user (+17%)** — a real regression in a GC-bound stage, and the shape
            `compiler/AGENTS.md` forbids (*"thirteen quadratics, all the same shape"*). A shippable
            third leg needs an **`ImplEnv` index keyed by head ACROSS interfaces** (plus an
            all-interfaces headless bucket), because `matchingEntries` buckets by head alone and
            `IE`'s concrete key is `[iface, head]`. ⚠️ That index **cannot** be written inside
            `ieInsertRowAt`: `ieInsertRowKeys` enters it once per `oblIfaceKeys` element, so every
            row would be filed twice. It has to be written one level up, in `ieInsertRow` /
            `ieIndexRows` — i.e. it touches the insert path RUN-B-021 deliberately left alone, and
            it needs its own ascending-`instRefSeq` argument. **That is a new bite with real design
            content, not a mechanical repoint** — back to the architecture companion per contract §4.
            (Note the alternative, widening `stampKeyTable` to the whole graph, re-creates design
            law L1's two-registry hazard P0-A ruled against as an END state; it is a decision, not
            an implementer's choice.)

            Two further deltas the reverted patch would have carried, recorded so a re-landing does
            not have to re-derive them:
            - **The tie-break at a non-closed, no-unique-minimum multi-module goal changes from
              "deterministic but arbitrary"** (`universeKeyBucketsRef`'s per-module restarting
              indices, descending slices) **to GRAPH-GLOBAL DECLARATION ORDER** (`instRefSeq`,
              duplicate-free and ascending within every bucket by construction). Strictly an
              improvement in the direction `diff_compiler_dict_semantics.sh` §4 can see, and **not**
              licence to implement T4 (DICT §11: *"T4 MUST NOT be implemented before I5"*).
            - **Global min⊑ can pick a MORE SPECIFIC winner than prefix min⊑** where a later module
              declares the specific sibling — changing an existing route on a program that already
              compiled. Spec-correct (§3 `inst` over the global `IE`), and an observable delta.

            **`fmt`/`lint` note, for whoever re-lands:** repointing the three iface-keyed callers
            makes `selectImplEntryByIface`, `matchingEntriesByIface`, `headCollidesByIface` and
            `countHeadByIface` **genuinely dead**, and `medaka lint`'s `rule-dead-code` flags all
            four — which the pre-commit MAX RATCHET fails on. Deleting them contradicts the brief's
            own do-not-delete list (`matchingEntries*`, `headCollides*`) and RUN-B-007 AM-1, so the
            patch carries four `-- lint-disable-next-line rule-dead-code` comments with a
            time-bounded justification. ⚠️ **The suppression must sit above the EQUATION, not above
            the type signature** — above the signature it does not fire (measured; lint still
            reported all four). **This needs the orchestrator's ruling: suppress, or amend AM-1 to
            let these four `…ByIface` variants die now while their method-keyed peers stay.**

nearest miss: 1. **An impl carrying NO `requires` — TESTED, and it is the control that shows the
                 two-leg move touched the right thing.** `all_visible`'s three rows and
                 `no_impl_anywhere`'s two rows in `diff_compiler_flat_vs_onemodule.sh` were
                 **byte-for-byte unchanged** across base → two legs → three legs (`wrap(int)` /
                 `T-NO-IMPL`), and `control.mdk` — the same four modules under the other import
                 order — was clean on all four arms in every configuration. No dict was needed, so
                 nothing observable moved: the delta is confined to goals that need a dictionary,
                 which is what `unroutedGroundReqs`' `implMatchesWithReqsU` predicate isolates.
              2. 🚨 **THE HEADLESS LEG IS NOT REPOINTED, and this is where a "drained" claim
                 over-reaches.** `findMatchingImplReqsU`'s fallback `firstReqMatch (univHeadless
                 univ iface)` still reads its `ImplUniverse` argument, and the `args == []` arm
                 reaches *only* that fallback. So **a goal answerable only by a HEADLESS impl
                 (`impl C a requires …`) declared in a topologically later module remains
                 unroutable.** Note the sub-class boundary precisely: headless rows ARE candidates
                 on the repointed concrete leg (`ieCandidateEntries` unions `ieHeadless`, as
                 `candidateBucket` does — `concreteReqMatchByIface` has been able to return a
                 headless winner since #1128), so what is NOT drained is the **empty-goal-vector
                 arm** and the fallback path taken when the concrete leg answers `None`.
              3. **#1564 SUB-CLASS ACCOUNTING, since the brief asked for it.** Even the three-leg
                 experiment drains only the shape #1564's fixture pins: a **concrete-headed**
                 conditional impl in a later module, reached through a **method occurrence in a
                 module-level generalized binding**. NOT drained by any configuration tried here:
                 the headless sub-class above; #1046/#1075's local-lambda sites (F-1, out of scope
                 by ruling); and #1560's own pin, whose second layer is `funConstraintsRef`'s
                 per-tyvar SHATTERED dict slots (`residualPredsOf`'s header measures that an n≥2
                 joint residual has no joint dict to route to **independently of any reduction
                 change**) — that is #607 punch-list item 3, not this bite. **#1560's pin still
                 reproduced in both configurations.**
              4. **A `Module`-mode driver whose `mid` `buildDeclEnvs` never indexed** would read an
                 empty `deImpls` and the repointed selector would answer `None` everywhere — a false
                 `T-NO-IMPL`/`T-REQUIRES-UNROUTED` storm. Not directly probed; `make check-self`
                 PASSing on the compiler's own multi-module graph in both configurations is
                 indirect evidence that no live driver does this, and `:17231-17232` asserts it.

engines:    **FOUR arms, none EDITED by the reverted patch, and that is the point — all four consume
            changed evidence, so the repair round owes each of them work the moment this lands.**
            - **LLVM (`backend/llvm_emit.mdk`)** — nothing to change; it *realizes* the delta. The
              arity-1-call/arity-2-define skew above is emitted LLVM, and `--keep-ir` is the only
              instrument that showed it. Owes: an IR-text differential on #1564's pair (the value
              goldens are structurally blind to a dict-arity change on a program that used to be
              rejected).
            - **wasm (`backend/wasm_emit.mdk`)** — no arg-tag dispatcher and no interface-default
              arms (RUN-B-007 AM-2), so no peer site. Owes: confirmation that the cross-module
              same-name collision fixtures #1418 added are still present and still exercised before
              a green wasm arm is read as corroboration.
            - **eval (`eval/eval.mdk`)** — no edit; it dispatches by runtime arg tag and therefore
              **recovers from exactly this defect**, which is why `medaka run` printed a *panic*
              rather than the wrong value here and why base `run` and `build` disagreed. ⚠️ eval is a
              **known-wrong oracle** on these shapes (#1071/#1062): **no golden was captured** and no
              engine-agreement claim is made anywhere in this row.
            - **`ir/core_ir_eval.mdk`** — no edit, and it is the arm most likely to ship silently
              broken: it reads the specificity `score` and the `CImplDefault` iface identity
              (RUN-B-007 AM-3), its gates are deferred, and its corpus
              (`test/eval_modules_fixtures/*`) is **shared** with `diff_compiler_eval_modules.sh`,
              which will look green. Owes: `diff_compiler_core_ir_modules.sh` run explicitly, not
              inferred from its sibling.

unchecked:  - **`sh test/selfcompile_fixpoint.sh` — NOT RUN, deliberately, and the reason is that
              nothing changed.** The handed-back tree is byte-identical to `5d499dfb`, whose fixpoint
              RUN-B-021 verified C3a/C3b YES two commits ago; re-running it would grade that commit
              again, not this bite. **It was also not run on either measured configuration** — so
              *neither* patch has fixpoint evidence, and the three-leg experiment in particular
              changed emitted IR and must not be re-landed without it.
            - **No seed re-mint, and none needed** (`refresh_seed.sh` not run): no compiled byte
              differs from `5d499dfb`. Re-flag when a real patch lands.
            - **No golden blessed, no snapshot blessed** (§5). Because nothing landed, the snapshot
              and `selfproc_legA` goldens are **also unmoved** — unlike every other row in this file.
            - **Perf: only `check-self` wall/user time**, not allocation, and not
              `diff_compiler_perf_scaling.sh`. The two-leg configuration measured **21.8 s real vs a
              21.5 s base (+1.5%, noise)** — so `keyEntryOfRow`'s per-lookup `implKeyTc` string build
              is **not** a measurable cost at this scale, which is the one perf question the patch
              itself raised. The +17% figure above belongs to the throwaway `ieRows` scan alone.
            - **§4.3's owed substrate derivation is DISCHARGED and it is a non-issue:**
              `univReceiverTag (headTy::_) = headTyconTy headTy` is *literally* `keyEntryOf`'s own
              projection, so the impl-side head keying of `IE` and `KeyBuckets` cannot disagree.
              Read it, don't take it from here:
              `grep -n '^univReceiverTag' -A2 compiler/types/typecheck.mdk`.
            - **Quiescence caveat:** `.claude/sprint-b/DECISIONS.md` was **uncommitted (M) for the
              whole session** — the orchestrator's own RUN-B-021 entry. It is a doc no gate reads, so
              the two must-fail runs (100/100 reproduce, 0 DRAINED, twice, agreeing) stand; recorded
              rather than assumed away.
            - **Not probed:** whether the identity (rather than bare) `oblIfaceKeys` leg would change
              acceptance — deliberately out of scope (#1507's drain), and the patch's own comment
              says so at the accessor.

**Parked patches** (apply from the worktree root; neither is shippable as-is):
`/var/tmp/medaka-scratch/claude-0/-root-medaka/2f0cc56c-30c4-4612-bcb1-04d9e4d0a7e5/scratchpad/B-2.1-b1-2leg-AS-BRIEFED.patch` — the bite exactly as briefed (+ the derived
`keyForSiteByIface` site). Produces the severity increase above. **Do not land alone.**
`/var/tmp/medaka-scratch/claude-0/-root-medaka/2f0cc56c-30c4-4612-bcb1-04d9e4d0a7e5/scratchpad/B-2.1-b1-3leg-EXPERIMENT.patch` — the same plus the throwaway global `matchingEntries`
scan. Behaviourally correct on #1564's four arms; carries the +17% `check` regression. **Land only
after the head-across-interfaces `ImplEnv` index bite is cut.**

---

### `B-2.1-a3` — Phase 2′ (B-2.1 precondition) — a HEAD-keyed, interface-blind `ImplEnv` index, filed ONCE PER ROW

sites:      `compiler/types/typecheck.mdk` only. `git diff --numstat` = **257 insertions, 12
deletions**; every deletion is a line re-spelled in place (listed below), none removed outright.
* `:4083` — NEW `ImplEnv` field `ieByHead : MultiRegistry ImplRow`, between `ieHeadless` and
  `ieIfaceTags`. **Added BARE, no trailing comment** (#829): `ImplEnv`'s header is the collapsed
  single-line `data ImplEnv = ImplEnv {` — the measured-safe form — but the record already carries
  an interior comment river on `ieUnivSnaps`, so the prose went on the filer instead. Verified
  after `fmt --write`: the `ieUnivSnaps` block is byte-unmoved in the diff.
* `:4117` — the matching `emptyImplEnv` initialiser `ieByHead = mregEmpty`.
* `:4070-4077` — the `ImplEnv` header comment: *"the three buckets are the index"* → names the
  buckets instead of counting them. It was **wrong the moment this field landed**, which is the
  `stampKeyTable`-says-"five"-means-seven shape (RUN-B-022) one record over.
* `:4304` — `ieInsertRow` (Module) now `ieFileRow r { env | ieRows = env.ieRows ++ [r] }`.
* `:4190-4193` — `ieIndexRows` (Flat, `a2`'s index-only half) now folds `ieFileRow`.
* `:4306-4358` — NEW `ieFileRow`, **the one once-per-row filing seam**, + its header (the
  double-file derivation and the two-parallel-paths derivation).
* `:4360-4361` — NEW `ieFileRowByHead` — the filing itself: `mregAppendK (headBucketKey
  (univReceiverTag tys))`.
* `:4363-4375` — NEW `ieHeadRows : Option HeadKey -> ImplEnv -> List ImplRow`, the read accessor.
  **No production caller yet, by design** — `B-2.1-b2` consumes it.
* `:4285-4288` — `ieInsertRowAt` gains a 🚨 recording that it runs once per `oblIfaceKeys` element
  and that only interface-keyed indexes may be filed there.
* `:18107-18116` — `headBucketRender hd = regKeyRender (headBucketKey hd)`, with NEW
  `headBucketKey : Option HeadKey -> RegKey` split out of its two arms. **One mint, two tables.**
* `:170-176` — a pre-existing import-list comment already cited **`headBucketKey`, a symbol that
  did not exist**, and claimed the head buckets are keyed *"by IDENTITY"*. This bite makes that
  citation resolve, so the false half is corrected in place (bare spelling; #1317 T1 / #1277) —
  otherwise the next reader follows a live link to a wrong sentence.
* `:4660-4814` — the doctest corpus (`ieOtherImplIn`, `ieGenImplIn`, `ieLooseImplIn`,
  `ieHeadProbe{Amod,Zmod,Decls,Env}`, `ieProbeBlobHead`) and doctest items 5-9.

transform:  Give `IE` the partition `KeyBuckets` has — rows keyed by RECEIVER HEAD, across
interfaces, with a headless bucket — so the method-keyed selection leg
(`matchedEntry` → `matchingEntries` → `candidateBucket`) can be made graph-global by a LOOKUP
instead of the O(rows)-per-goal scan RUN-B-023 measured at `check-self` 21.5 s → 25.1 s (+17%) and
refused. Not a widening of `stampKeyTable`: that re-creates design law L1's two-registry hazard
`a2` just retired.

**The placement IS the design content, and it is a correctness constraint, not tidiness.**
`ieInsertRowAt` is entered once per `oblIfaceKeys` ELEMENT — twice for every origin-bearing
interface — so a head-keyed index filed there DOUBLE-FILES and corrupts every count, `min⊑` and
declaration-order merge over the bucket. It therefore goes in a once-per-row seam. There were
**two** such paths after `a2` (`ieInsertRow` Module, `ieIndexRows` Flat), each spelling
`ieInsertRowKeys (oblIfaceKeys ir) r` independently — the `evalModules`/`cevalModules` shape. So
rather than filing in both, both were **routed through ONE new seam `ieFileRow`**: the only
per-row difference left between the arms is the `ieRows` append, which is the difference that is
supposed to be there. (Deviation from the brief, which said file it in both: this is the cleaner
factoring it invited, and it makes the drift unrepresentable rather than merely absent.)

**Order:** `mregAppendK`, ascending by `instRefSeq` by construction on both arms — RUN-B-007's
declaration-index ruling and `mergeByDeclIdx`'s precondition. A prepend + reverse-at-finalize
would file in O(1) instead of O(bucket) and was **deliberately declined**: it makes the ascending
invariant true only AFTER a finalize step, which is exactly the second-maintainer hazard
`ieAddRows`'s own header forbids for `ieUnivSnaps` (*"do not add a second maintainer"*). Stated
plainly because it is a real trade and the brief asked for O(1): **the filing is O(bucket), not
O(1)** — per BUCKET, never per population (this is not `ieRows`' `++ [r]`), and it is the same
writer the two sibling buckets and `ImplUniverse` already use. R1's finding that *"`mregAppendK`
is still O(bucket) per add"* is correct, and this bite's comment says so **at the site** rather
than repeating the retired "avoided by construction" wording.

**Measured, not asserted** (allocation — deterministic and machine-independent):
* `test/bin/profile_modules_main` built from BASE source and from this source, **same emitter, same
  `GC_INITIAL_HEAP_SIZE=2147483648`, same input** (`sqlite/main.mdk`, 24 modules, 3352 decls —
  chosen because it does NOT contain `typecheck.mdk`, so both arms compile a byte-identical
  program; profiling the compiler's own graph instead confounds the delta with 22 extra decls of
  my own source, which was my first measurement and is why it is not the one reported):

  | stage | BASE alloc | this bite | delta |
  |---|---|---|---|
  | parse / load / desugar / resolve / mark | 39.8094482421875 / 382.70506286621094 / 7.87066650390625 / 35.252655029296875 / 2.248565673828125 MB | **byte-identical, all five** | **0** |
  | typecheck | 204.677001953125 MB | 205.14942932128906 MB | **+0.4724 MB (+495 KB, +0.231%)** |
  | total | 672.5711975097656 MB | 673.0475311279297 MB | +0.4763 MB (+0.071%) |

  The five untouched stages agreeing **to the last digit** is the instrument's own control: the
  delta is attributable to the filing and to nothing else. Re-run once: byte-identical, so the
  figure is deterministic as documented.
* **Op-count column unchanged in every stage** (117106 / 134546 / 553769). `opBump` counts
  `contains`/`lookupAssoc`, so this is direct evidence that **no `List`-as-a-set scan was added** —
  `compiler/AGENTS.md`'s one rule.
* **Bucket bound, measured on the compiler's own graph** (temporary audit panic, build stage B):
  `rows=159 keys=27 maxbucket=16`. So the O(bucket) cost is bounded by `Σ b² / 2 ≤ maxbucket ×
  rows / 2 = 1272` cons copies per whole-compiler compile — a constant factor, not a growth-rate
  change.
* Wall clock is **not** offered as evidence: the box carried load average 20-25 from other agents
  for most of this session. `check-self` passed; its duration is meaningless here.

could move: **NOTHING — and in its strongest available form rather than as an assertion:**
* Nothing reads `ieByHead` or `ieHeadRows`. Derive it: `grep -n 'ieByHead\|ieHeadRows'
  compiler/types/typecheck.mdk` — the only non-comment hits are the field, the initialiser, the
  filer and the accessor itself, plus the doctests.
* The two behavioural re-spellings are extensionally identity: `ieInsertRow`/`ieIndexRows` now call
  `ieFileRow`, whose body is the OLD body plus one write to a NEW field; `headBucketRender` is
  `regKeyRender` of the two arms it used to spell inline.
* **Independent confirmation:** the emitted-IR fixpoint is byte-for-byte green (C3a YES / C3b YES),
  and the five profiler stages above are byte-identical in ALLOCATION — which a behaviour change of
  any size would move.
* The one residual is the record itself: adding a field to `ImplEnv` re-orders nothing (named
  fields), and `emptyImplEnv` stays reachable from `freshDriverState`, which is what keeps
  `ImplRow`'s measured `CFieldAccess` emitter trap disarmed — see `ImplRow`'s header.

nearest miss: **A program with ONE head bearing hundreds of impls.** `maxbucket=16` today; the
filing is O(bucket) per row, so a corpus with e.g. 500 impls at head `Int` pays ~125 000 cons
copies at build time. The READ side stays O(1) (`mregLookupK`). Nothing in the tree is near that
and **no gate would see it**: `perf_scaling` scales DECLS and MODULES, not impls-per-head. Second
nearest miss, and the one that matters to the next bite: **the consumer.** This bite makes the
lookup affordable; it does not make it correct for `matchingEntries`, whose population must also be
filtered by METHOD NAME and by `entryHeadMatches`, and whose rows must be adapted to `KeyEntry`
(`keyEntryOfRow`, in the parked 3-leg patch, DROPS empty-`tys` rows while `ieByHead` files them
under the headless key). So `ieByHead`'s headless bucket is a **superset** of `KeyBuckets`' for a
`tys = []` impl — harmless while the consumer drops those rows, and an S0 the day it does not.

engines:    **FOUR-arm ledger, none moved — with the reason, not the word:**
* **LLVM** (`backend/llvm_emit.mdk`) — not touched and cannot be: this bite adds a typecheck-time
  table nothing reads, so no route word, dict arity or symbol moves. Proven, not argued: the
  self-compile fixpoint is byte-for-byte green (C3a/C3b YES), i.e. the emitted IR for the largest
  program in the tree is unchanged.
* **wasm** (`backend/wasm_emit.mdk`) — same reason, and **no peer arm is OWED**, because there is
  nothing to mirror: `ieByHead` has no representation in any engine and will not until
  `B-2.1-b2` changes which impl is *selected*. That bite owes the wasm arm; this one does not.
* **`eval.mdk`** — untouched. Its dispatch reads `VMulti`/arg-tag values built from the elaborated
  program, and the elaborated program is unchanged (fixpoint, plus the flat gate's VALUE clause at
  9/9 with 0 drain notices).
* **`core_ir_eval.mdk`** — untouched, and because RUN-B-007 AM-3 names this as the arm most likely
  to ship silently broken it gets the explicit derivation: it consumes `CImplEntry`'s specificity
  `score` and `CImplDefault`'s iface identity out of the LOWERED program. `ieByHead` is not
  lowered, is read by no selector, and does not reach `core_ir_lower`. No lockstep edit is owed
  because there is no `evalModules`-side change to mirror. ⚠️ The lockstep pair this bite DOES
  touch is a different one — `ieInsertRow`/`ieIndexRows` — and it is fixed by construction (one
  seam), asserted by doctest item 9.

unchecked:
* **`test/diff_compiler_perf_scaling.sh` NOT run** (measured 654-748 s, over the foreground
  ceiling). Judged not the right instrument anyway: it grades a growth RATIO and a constant factor
  at fixed impl count cannot move one — `compiler/AGENTS.md` says exactly this about that arm's
  blindness. The allocation A/B above is the discriminating measurement.
* **No `--bless`, no goldens, per §5.** `test/snapshots/compiler/typecheck.md` and
  `test/selfproc_goldens/legA/types.typecheck.golden` are both MOVED by this diff (new top-level
  bindings ⇒ additive-only on legA). **Blessed by nobody.**
* **`refresh_seed.sh` NOT run**, deliberately, and flagged rather than assumed: C3a passed
  byte-for-byte against the seed-bootstrapped converged reference, which is precisely the
  comparison a stale seed fails.
* **The corpus sweep was CUT from 1335 files to 415**, honestly: the first leg was `compiler/**`,
  where each `check` is a whole-compiler multi-module compile — ~3 files/minute under this box's
  load. 98 of those ran (the heaviest graphs in the tree, 159 rows each) plus 317 small
  fixture/stdlib files; `test/llvm_fixtures*`, `test/must_fail_fixtures`, `test/parse_fixtures`,
  `sqlite` and the rest of `compiler/**` did not. **Two globs I listed do not exist**
  (`test/check_fixtures`, `test/types_fixtures` — the same two `a2` found) and `playground` holds
  no `.mdk`; all three contributed nothing and are recorded rather than left to inflate the claim.
* **The F1-immunity assertion (doctest 6d) is not backed by a mutation run.** Double-filing,
  prepending and arm-drift were each proved by mutate-and-observe-RED; for 6d the evidence is the
  derivation (`headBucketKey` has no interface component; `dispHeadTab hk = TkBare NsType
  (headKeyName hk)`) plus the assertion that seq 4 — an `OriginUnresolved` interface, ONE
  `oblIfaceKeys` leg where its siblings mint two — sits in the bucket on BOTH arms. I did not build
  a fourth mutation giving the head key an interface component.
* **`ieConcrete`/`ieHeadless` are still F1-affected and this bite does not fix that** (RUN-B-025
  F1, a hard gate on the drain). It establishes only that the NEW index cannot inherit it.
* **Quiescence caveat, flagged rather than assumed away:** `HEAD` moved under me mid-bite
  (`604278bb` → `4b0f5b68`, the orchestrator's RUN-B-025 commit) and `.claude/sprint-b/DECISIONS.md`
  was uncommitted (`M`) during my sweep and my first perf arm. Both are docs no gate reads and that
  commit touched no `compiler/`/`test/` path (`git show --stat 4b0f5b68`), so the readings stand —
  but the allocation A/B was taken across that boundary and the rule exists so that I do not make
  that judgment silently.
* **`ieByHead` is a table nothing reads, built on every compile including per-keystroke LSP.** That
  is R1's objection to `a2` applied to this bite, and it is accepted for exactly ONE bite: if
  `B-2.1-b2` does not land, this field is +495 KB per compile for nothing and should be reverted,
  not carried.

---

### `B-2.1-a4` — Phase 2′ (B-2.1 precondition) — **R1's F1 ADJUDICATED: BENIGN. Zero compiler-source change; the drain is UN-GATED.**

🔗 **Ledger cross-reference: `DECISIONS.md` RUN-B-030** (the verdict, the three legs, the 11-row
probe table, and the two things it does NOT license). This row is the debt view; that entry is the
derivation. Also `review/R1-landed-work.md` **F1** (the finding) and RUN-B-027/029 (why it was
provisional).

sites:      **NO `compiler/` OR `test/` PATH TOUCHED. `git diff --numstat -- compiler test` is
empty.** Two ledger files only:
* `.claude/sprint-b/DEBT.md` — a THIRD `nearest miss:` paragraph on the `B-2.1-a2` row (F1 was
  absent from it; that absence is what the brief sent this bite to fix) + this row.
* `.claude/sprint-b/DECISIONS.md` — RUN-B-030.
No `.mdk` changed ⇒ no snapshot, no LEG A golden, no seed, no fixpoint. See `unchecked:`.

transform:  **None.** The bite's output is a VERDICT plus its evidence. F1's mechanism was never in
doubt (`oblIfaceKeys` is arm-asymmetric for a user-declared interface, and it still is); its
*reachability* was, and reachability is what gates `B-2.1-b2`. The brief's own instruction was that
either answer is a complete bite and a fix must not be manufactured; the answer is BENIGN, so the
correct diff to `compiler/` is the empty one. ⚠️ Recorded because a later reader will be tempted:
**"make the two arms file under the same keys" would be a REGRESSION, not a tidy-up.** Dropping the
bare leg from `oblIfaceKeys`' non-`OriginUnresolved` arm is measured to break `medaka check
stdlib/core.mdk` with 32 false `No impl of …` rejects (`typecheck.mdk:21683-21706`, and that
paragraph ends *"DO NOT DELETE THIS LEG"*). Adding identity to the Flat arm is **#1115 (E-1)**, a
different owner.

could move: **NOTHING — no compiled byte exists to move.** The two edited files are Markdown under
`.claude/`, read by no gate: the snapshot corpus is `.mdk` only, `fmt`/`lint` do not accept `.md`,
and the pre-commit hook's four checks are all `.mdk`-scoped (fmt, lint, snapshot, lextok). Derive it
rather than trust it: `git diff --numstat` lists exactly two `.md` paths, and
`git diff --numstat -- '*.mdk' '*.c' '*.sh'` is empty.

nearest miss: **The nearest program this adjudication does NOT cover: one that compares two
`TabKey`s for EQUALITY, or RENDERS one, instead of using one as a lookup key.** The whole verdict
rests on write-side ⊇ read-side, which is a property of *lookup*. `tabKeyEq` never equates
`TkIdent` with `TkBare` (`typecheck.mdk:1604-1607`) and `regKeyRender` builds a string that carries
the origin — so a bite that puts a `TabKey` into a diagnostic message, an S-expr dump, a golden, or
a set-difference between two arms will see Flat and Module disagree on a user-declared interface,
**loudly and correctly**. F1 is dormant, not absent.
**Second nearest miss, and it is UNCHECKED rather than argued away: `univHeadless` / `ieHeadless`
(`tys = []`).** The probe exercised `univConcreteBucket` (p1/p3) and `implCountForIfaceU` (p5/p6)
but NOT the headless bucket, because I could not produce a `tys = []` impl from surface syntax —
which is itself one of RUN-B-017's five owed items and the `a2` row's own first nearest miss.
Structurally it is the same key mint as the tags registry that p5 exercised (`regKeyOfTab ifk` on
write, `regKeyOfTab (oblIfaceKey iface)` on read), so the *keying* argument covers it; the
*behavioural* corroboration does not. **Third:** a Flat program declaring an interface whose
spelling COLLIDES with a prelude interface's. Both would key `TkBare NsIface "<Name>"` on Flat and
the buckets would MERGE — that is #1438/#1507's collision class, pre-existing, arm-independent,
and not created or worsened by anything here. Not probed.

engines:    **FOUR-arm ledger. NONE MOVED, and the reason is the same for all four, so it is stated
once and then discharged per arm rather than padded:** this bite emits no compiled byte at all.
* **LLVM** (`backend/llvm_emit.mdk`) — untouched. No `medaka` binary was rebuilt: the probe ran the
  binary that was already at `HEAD` = `23f4da83`, `MEDAKA_STRICT=1` clean (the staleness guard
  would have exited 1 on stderr had it lagged the tree — that is the arm's positive control here,
  and it is why `MEDAKA_STRICT=1` is exported in the probe script rather than assumed).
* **wasm** (`backend/wasm_emit.mdk`) — untouched, and **no peer arm is OWED.** `B-2.1-b2` still owes
  one (per the `a3` row); this bite does not move the day it comes due either way.
* **`eval.mdk`** — untouched. ⚠️ It is nonetheless an *instrument* here: probe rows `p1_run_MODWRAP`
  / `p3_run_MODWRAP` are `medaka run`, i.e. the eval-driven 1-module wrapper (the MODULE arm), and
  they are two of the four rows that make the cross-arm comparison a comparison at all.
* **`core_ir_eval.mdk`** — untouched, and **no lockstep peer is owed**: the `evalModules` ‖
  `cevalModules` law is about module-frame semantics and nothing here adds a frame, a cell or a
  name. `grep -n 'oblIfaceKeys\|bodyImplEnvRef\|ImplEnv' compiler/ir/core_ir_eval.mdk` returns
  nothing, so there is no peer site to mirror — same derivation the `a2` and `a3` rows give.

unchecked:
* **`make medaka` / `check-self` / `selfcompile_fixpoint` / `diff_compiler_flat_vs_onemodule` NOT
  RUN, and that is the deliberate answer to the brief's "if you change no code, say which gates you
  skipped and why."** All four grade compiler behaviour against compiler source; no compiler source
  changed (`git diff --numstat -- compiler test` empty). Running a ~10-minute fixpoint to prove that
  two Markdown edits did not move the emitted IR is the "avoidable build cycle" the brief's own
  accounting section asks me to report, so it was not spent. The binary the probe RAN is the one the
  fixpoint already certified when `a3` landed.
* **`fmt --check` / `lint` NOT RUN** — neither accepts `.md`; there is no staged `.mdk`.
* **No fixture, no golden, no `--bless`, no must-fail pin.** ⚠️ Flagged, not waved away: a BENIGN
  verdict is exactly the shape that rots silently, because no gate defends it. The right pin is
  **not** a must-fail fixture (nothing is broken) but a **row on
  `test/diff_compiler_flat_vs_onemodule.sh` using a USER-DECLARED interface** — R1's F1 notes the
  gate's existing 9 rows use only prelude interfaces or accept/reject, which is why the gate was
  blind to this question in the first place. Probe programs `p1`/`p3`/`p5`/`p6` are ready-made rows.
  **`B-2.1-b2` should land them WITH the repoint** — that converts this adjudication from prose into
  a gate at the exact moment the substrate acquires its first reader. **This bite did not add them**
  (a new gate row moves a golden and would have needed the build cycle above); it is owed, and it is
  the single most valuable follow-up here.
* **The probe cannot observe `ieConcrete`/`ieHeadless` DIRECTLY, because nothing reads them yet.**
  It observes the structurally identical `ImplUniverse` — same `oblIfaceKeys` write mint, same
  `oblIfaceKey` read mint, same arm gate (`typecheck.mdk:20649-20666`, where Module already reads
  `ieUniverseAt … deImpls` and Flat reads `buildImplUniverse prog`). That substitution is the ONE
  inferential step in the verdict and it is named as such in RUN-B-030 rather than buried: the
  behavioural evidence is about the universe, the transfer to `IE` is by shared mint.
* **`test/diff_compiler_perf_scaling.sh` NOT run** — no code changed; nothing to grade.

---

### `B-2.1-b2` — Phase 2′ (B-2.1) — **THE S0 DRAIN: all three selection legs onto the graph-global substrate. 3 must-fail pins drained (#1564, #1599, #1072), twice, agreeing.**

🔗 **Ledger cross-reference: `DECISIONS.md` RUN-B-031** (the orchestrator composes it from this
row + my report). Predecessors this bite consumes: RUN-B-023 (the refusal that found the third
leg), RUN-B-024 RULING 2 (the four `…ByIface` deletions authorised), RUN-B-030 (F1 BENIGN, and the
gate rows it left owed), and RUN-B-007 (the declaration-index defect, fixed here **by deletion**).

sites:        `git diff --numstat` — 312/92 `compiler/types/typecheck.mdk`, 9/3
`compiler/ir/core_ir_lower.mdk`, 5/2 `compiler/types/registry.mdk`, 1/1
`docs/spec/DICT-SEMANTICS.md`, 66/1 `test/diff_compiler_flat_vs_onemodule.sh`. The diff says the
rest; three things it does not:
* **DELETED** (RUN-B-024 RULING 2, verified dead once the legs moved): `selectImplEntryByIface`,
  `matchingEntriesByIface`(+`Go`), `headCollidesByIface`, `countHeadByIface`(+`Go`). **No
  `lint-disable` anywhere** — `medaka lint` exits 0 on all three touched files.
* **REPOINTED, NOT DELETED:** `keyForSiteByIface` (its `KeyBuckets` param is *removed* rather than
  ignored — an ignored table param reads as "still consulted"). `matchedEntry` /
  `matchingEntries` / `candidateBucket` / `mergeByDeclIdx` / `countHead` / `headCollides` /
  `keyForSite` / `keyEntryOf` / `buildKeyTable` are all **untouched and still live**.
* The three `docs`/comment edits are the **stale-symbol sweep**: `docs/spec/DICT-SEMANTICS.md`
  §2475 is in `check_agent_doc_symbols.sh`'s SCOPED tier (its line cites a `compiler/` path), so a
  deleted symbol there **reds `make agent-doc-symbols`**. The `core_ir_lower`/`registry` edits are
  ungated prose whose cited call chains no longer exist.

transform:    Three legs, one substrate (`perRun.bodyImplEnvRef`, `a2`) indexed by head across
interfaces (`ieByHead`/`ieHeadRows`, `a3`): **(1)** `concreteReqMatchByIface`, **(2)**
`selectReqImpl` **and** `keyForSiteByIface` **with its collision retest**, **(3)** the METHOD-keyed
element dicts at `implDictRoutesForFull` / `argImplDictRoutesForEncl`. **ONE min⊑ selector** (DICT
§11/§6 uniform resolution): rows are projected into the `KeyEntry` `pickMostSpecificEntry` already
speaks, via `keyEntryOfRow` — A-3.7's `cohImplOfRow` precedent. Declaration index = `instRefSeq`.
Three named entry points, all returning **`Option ImplRow`** (Phase 3′'s interface — the row
carries `InstRef`; a `String` or a `KeyEntry` loses it): `ieSelectRowByIface`,
`ieSelectRowByMethod`, `ieHeadCollidesByIface`.
Two design points worth not re-deriving:
* **`candidateBucket`'s empty-headless fast path is preserved without touching
  `candidateBucket`.** The IE side merges two *already-filtered* lists, and `mergeByDeclIdx xs []
  = xs` returns the left list ITSELF — no copy — while `ieEntriesFor*` on an empty bucket is its
  own `[] => []` clause. **Filter-then-merge == merge-then-filter** here: a stable merge on an
  index cannot reorder survivors or change which side wins a tie. Filtering first is what keeps
  the scan allocation-free on rejected rows, which is why `keyEntryOfRow` is called only on a
  match (its `implKeyTc` builds a string).
* **`ieRowOfEntry` is an EXACT inverse, not a search.** The winner's `idx` IS its row's
  `instRefSeq` (whole-graph, unique per compile) and its row is filed in the bucket of its own
  head — which is the `KeyEntry`'s own `hd` field, same `headTyconTy` mint. One bucket scan, no
  fallback arm to be silently wrong in.
* **RUN-B-007's declaration-index defect is fixed by DELETION.** `mergeByDeclIdx` needs ascending
  operands; `universeKeyBucketsRef` violates that (per-module restart at 0 ⇒ duplicate indices,
  each slice prepended ⇒ descending) and it reached the selector on **every multi-module compile**.
  All three functions on that path are gone. `instRefSeq` is ascending **by construction**
  (`ieFileRowByHead` appends over a forward fold), so the no-unique-minimum tie-break is now
  graph-global declaration order. `universeKeyBucketsRef` still has the property; nothing that
  merges reads it any more. `candidateBucket`'s comment records this in place.

could move:   **A GREAT DEAL, and most of it is the deliverable. MEASURED, four arms, not
inferred.** A goal whose impl sits in a topologically LATER module now recovers that impl's
`requires`, so a dict appears where there was none ⇒ **emitted IR changes** and
`T-REQUIRES-UNROUTED` stops firing for that class.
* **`test/diff_compiler_must_fail.sh`: 97 REPRO / 3 DRAINED / 0 control-broke / 0 malformed — run
  TWICE on the final binary, both runs reporting identical counts and the same three names.** Every
  drain's own CONTROL still passes, which is the gate's own "real fix, not a broken environment"
  signal. **DRAINED: #1564, #1599, #1072.** Still REPRO: **#1560** and **#1182** (both named in the
  brief as candidates — they did not move; do not claim them).
* 🚨 **#1564's drain is shown on the BUILT BINARY, not on `check`** — the hard requirement carried
  from RUN-B-023, whose two-leg scope would have reported this pin DRAINED over a **segfault**.
  Four arms on its `order2` fixture, base binary vs branch binary, both built in this worktree:

  | arm | BASE (`58995084`) | this bite |
  |---|---|---|
  | `check` | 1, `T-REQUIRES-UNROUTED` | **0** |
  | `run` | 1 | **0, `wrap(int)`** |
  | `build` | 1 (no binary produced) | **0** |
  | **built binary** | — | **0, `wrap(int)`** |

  **Emitted-IR evidence** (`medaka build --keep-ir`, read off the `.ll`, exit codes read from file
  redirects because `build`'s status does not survive a pipe): `define @mdk_impl_Wrap_tagOf(i64
  %arg0, i64 %arg1)` — arity 2, its `requires Tag a` dict — and **both** call sites pass two args
  (`(i64 %arg0, i64 %t2)`, `(i64 %t11, i64 %arg0)`); `define @mdk_nest__nest(i64 %arg0, i64
  %arg1)` with its one caller passing `ptrtoint (ptr @mdk_dc_0 to i64)`. So the dict chain agrees
  at *define, call site and dict global* at every level. RUN-B-023's S0 was precisely an **arity-1
  call to an arity-2 define**; that shape is absent.
* **#1072's drain is a SILENT-WRONGNESS drain and it corroborates the collision retest.** Its
  fixture pinned a built binary printing `general` where most-specific-wins requires `specific`,
  at exit 0 with no diagnostic; it now prints `specific`. Its own mechanism note names the cause:
  *"typecheck builds a.mdk's KeyBuckets from a.mdk's IMPORT CLOSURE, which holds one impl at head
  `Box`, sees no collision, and stamps the BARE HEAD into the caller's dict cell."* That is exactly
  the count `ieHeadCollidesByIface` now takes graph-globally. It reaches it through leg **2b**
  (`EDictAt` → `resolveDictApps` → `routeOfD` → `EKNestedTop` → `keyForSiteByIface`), which is the
  concrete argument for why the retest had to move **with** the selector rather than after it.
* **The route-word/emitter skew NARROWS rather than widens.** `core_ir_lower.ifaceDeclHeadUnique`
  — the emitter's side of the same verdict, which must agree word-for-word with what typecheck
  stamps into the dict cell — counts over `ifaceImplHeadTable`, installed from `lowerProgramEmit
  allDecls`, i.e. **already the whole program**. This side was a topological prefix. The two now
  count the same population. ⚠️ Not identical arithmetic: that side counts DISTINCT canonical keys,
  this one counts rows — a pre-existing difference `ifaceDeclHeadUnique`'s own comment records,
  unchanged here and **not** claimed as fixed.
* **Tie-break semantics change, deliberately, and this is the sentence for the spec reader:** at a
  non-closed, no-unique-minimum multi-module goal the fallback moves from *arbitrary* (a violated
  ascending precondition over a per-module-restarted index) to **graph-global declaration order**.
  ⚠️ **This is NOT licence to implement T4** — DICT §11: *"T4 MUST NOT be implemented before I5"*.
  The non-closed goal is still silently decided by list order; only the order is now statable.
* **Perf — the question `a3` exists for. NO measurable regression.** `make check-self` min-of-3,
  same worktree, same box, both binaries built here: **BASE 23.62 s** · branch **22.74 s** (final
  binary) and **24.23 s** (an earlier build of the same sources). The three samples **bracket
  zero**, i.e. the delta is load noise on a shared box — and nowhere near the **+17%** RUN-B-023
  measured for the O(rows) scan this index was cut to avoid. ⚠️ Stated honestly: **not
  interleaved** (A/B, not A/B/A), wall-clock only, load 1.9–2.1 throughout, and the **21.5 s**
  figure in the `a3`/`b1` rows is **another session's box and is not comparable** — that
  cross-session comparison is what made me measure rather than report a scare.

nearest miss: **Item 1 — the CONTROL: an impl with NO `requires`.** Proves this fixed the right
thing rather than everything. Read off the same `.ll`: `define @mdk_impl_Int_tagOf(i64 %arg0)` —
**arity 1, no dict param**, its call site `(i64 %arg0)` — unchanged from base. A no-requires impl
recovers an empty `reqs` list from the row exactly as it recovered one from the `KeyEntry`, so
widening candidacy adds no dict where the impl declares no context.

**Item 2 — the HEADLESS leg, and 🚨 THE BRIEF'S PREDICTION IS WRONG; I TESTED IT RATHER THAN
RESTATING IT.** The brief states the headless leg is not repointed (`firstReqMatch` still reads
`univ`) so *"a headless impl in a later module remains unroutable"*, and asks that any #1564 drain
claim name which sub-class drained. **The bare-tyvar-head sub-class ALSO drained**, and its
pre-state was not a reject at all. Derivation first, then measurement: `ieCandidatesForIface`
unions `ieHeadRows None` — the headless bucket — **graph-globally**, so a bare-tyvar-head impl is
reached by leg 1 *before* the `firstReqMatch (univHeadless …)` fallback is ever consulted.
Measured on a discriminating pair (`impl Tag a requires Dbg a` declared in a module the site's
module does **not** import, vs a byte-identical copy that does — the second is the control that
would expose a bad fixture):

| arm | BASE | this bite |
|---|---|---|
| `check` | 0 | 0 |
| `run` | **1 — `E-PANIC: putStrLn: not a String`** | **0, `h(blob)`** |
| built binary | 0, `h(blob)` | 0, `h(blob)` |

So base **accepted** this program, its **native binary was correct**, and **eval panicked** — a
pre-existing run≠build divergence on the headless leg, the same `E-PANIC` shape RUN-B-023's
two-leg patch produced, reached here without any patch. It is gone on all three arms. The
`imp` control passes on both binaries. ⚠️ **Not filed as a new issue** (it is drained, and by this
bite) but **named**, because the honest sub-class accounting is: **#1564's concrete-head
sub-class AND the bare-tyvar-head sub-class both drained; the `tys = []` sub-class is UNTESTED**
(RUN-B-030 already records that it cannot be produced from surface syntax — the same owed item
since RUN-B-017).

**Item 3 — what genuinely still misses, stated precisely because items 1–2 came out better than
briefed.** A goal whose own head is **not a tycon** (`goalHeadCon` answers `None`: a bare
metavariable or rigid receiver) keys no bucket, so **all three** new entry points return `None`
and the only thing that can answer is `firstReqMatch (univHeadless univ iface)` — which still
reads `univ`, i.e. the **prefix-projected** universe on the Module arm. I did not repoint it and
it is not in scope. Same for `findMatchingImplReqsU`'s empty-goal-vector clause (`iface []`).
**Item 4:** the METHOD-keyed ROUTE WORD (`keyForSite` → `matchedEntry` → `matchingEntries`) is
still prefix-read by design (AM-1), so a *method-keyed* site whose head-collision count differs
between prefix and whole graph can still stamp the bare word where the emitter derives the
canonical key. #1072 was the *iface*-keyed instance of that skew and it drained; the method-keyed
instance is untouched, and moving it renames route words and moves the seed — a separate bite.
**Item 5:** F1 stays **dormant, not absent** (RUN-B-030): this bite adds no `TabKey` **equality
comparison** and no `TabKey` **rendering** — the two things that re-open it. `ieByHead`'s key has
no interface component and so cannot inherit it, as `a3` proved.

engines:      **One line, per the orchestrator's instruction: no engine arm moved, because no
engine source changed** — the diff touches typecheck, one lowering *comment*, one registry
*comment*, one spec cell and one gate. **LLVM** · **wasm** · **eval** · **`core_ir_eval`**: all
four untouched as source; LLVM and eval appear here only as *instruments* (the four-arm tables
above), and wasm/`core_ir_eval` owe no lockstep peer — nothing here adds a frame, a cell or a
name, and `grep -n 'bodyImplEnvRef\|ieHeadRows\|ImplEnv' compiler/ir/core_ir_eval.mdk
compiler/backend/wasm_emit.mdk` is empty. ⚠️ What this bite DOES owe the engines is a
`diff_compiler_engines` run: eval and native now agree on shapes where they previously did not
(item 2), and that is the gate that would see a *new* divergence. Deferred to CI / the repair
round per the brief's reduced floor.

unchecked:
* **`selfcompile_fixpoint.sh` NOT RUN — and this bite CHANGES EMITTED IR, so it is the decisive
  gate and it is genuinely owed.** The brief assigns it to CI's `soundness` shard (draft PR #1605)
  and a parallel verifier, and instructs me to STOP and report at any sign of a codegen or
  dict-arity anomaly. **I looked for one specifically and found none:** dict arity agrees at
  define, call site and dict global on the #1564 IR (see `could move:`), the built binary runs, and
  `MEDAKA_STRICT=1 ./medaka check` on the compiler's own closure exits 0. That is evidence, not a
  substitute — **the fixpoint is the authority and nobody has run it on this diff.**
* **Snapshot and `selfproc_legA` goldens NOT re-cut, and BOTH are owed.** `compiler/types/
  typecheck.mdk` is in the snapshot corpus, so it moves its own snapshot golden; and this diff
  **adds 14 top-level bindings, deletes 6, and re-signatures exactly 2** (`keyForSiteByIface` and
  `selectReqImpl` each lost a parameter), so `test/selfproc_goldens/legA/types.typecheck.golden`
  moves too. Derive those three numbers rather than trusting them:
  `git diff -U0 compiler/types/typecheck.mdk | grep '^[+-][a-zA-Z]' | grep ' : '`. The legA diff
  must be read as **additive, minus those 6, plus exactly those 2 re-signatures** — any OTHER
  existing binding's inferred type changing means the fix changed types. 🚨 On a rebase, take the
  base's version of both families and **RE-DERIVE**; a clean three-way auto-merge of a golden is
  not evidence it is right (three agents hit that on this exact file in one session).
* **No seed re-mint attempted.** Emitted IR changes, so `refresh_seed.sh` may be owed — but it is
  not idempotent after a codegen change and belongs with the fixpoint, in one place, once.
* **`diff_compiler_perf_scaling.sh`, `diff_compiler_engines.sh`, `typecheck_compiler_source.sh`,
  any corpus sweep, and the full gate suite: NOT RUN**, per the brief's deliberately reduced floor
  (~11-min and ~6-min gates, foreground-unsafe, owned by CI and the parallel verifier). No sweep
  was started: `compiler/**` files are whole-compiler compiles at ~3/min, and the cost of scoping
  one is stated rather than paid.
* **The two new gate cases pin FLAT-arm verdicts I derived from the spec and then confirmed on the
  BASE binary before the change** (`p1` ACCEPT/7, `p3` REJECT/`T-NO-IMPL`, `p5`
  REJECT/`T-AMBIGUOUS-INSTANCE`, `p6` ACCEPT/3 — 13/13 rows green on base, 0 drain notices). So
  they are pins of the **pre-state**, not captures of my own output — but they are `PIN` rows on a
  path where prefix == whole program, so they are **fail-capable for a FLAT regression and inert
  as evidence about the drain**. That is deliberate (the gate's own assert-choice section) and it
  is why the drain evidence is the value clause plus the built binary, not these rows.
* **`p5` is graded on the diagnostic CODE, not on the count.** It asserts
  `T-AMBIGUOUS-INSTANCE` is emitted where RULE 3's `implCountForIfaceU >= 2` guard fires; it does
  **not** observe the count itself. A bug that changed 2 to 3 would keep this row green.
* **Quiescence, flagged not waved:** an untracked file `.claude/sprint-b/design/P-c-packet.md`
  (not mine) appeared in this worktree during my measurement window. It is a `.md` under
  `.claude/`, read by no gate, so the readings stand — but §5's rule is not mine to set aside, so
  it is recorded rather than judged harmless unilaterally.
* **NOT COMMITTED**, per the brief. Working tree holds all five files; the three restore points
  (`mine/`, `baseB/`, `postB/`) are in scratch outside the worktree, so both arms of every
  measurement above can be reproduced with a `cp` and no rebuild.

---

### `B-2.1-c` — Phase 2′ (B-2.1) — 🛑 **REFUSED AND REVERTED: moving the SHADOW existence reads without the ROUTE-time one is an S0. MEASURED: garbage value at exit 0.**

**Nothing landed. `compiler/types/typecheck.mdk` is byte-identical to `1e7cbbbb`.** The transform
was written, built, and measured; **as briefed it produces silent wrongness** and is parked as
`scratchpad/c-REFUSED.patch` (+128/−25). The measurement is the deliverable.

🔗 **`DECISIONS.md RUN-B-0xx`** — the orchestrator's ledger owns the entry; this row is its
evidence half. The ruling it needs: **the three existence reads are ONE bite, and that bite reaches
the evidence path.**

sites:      **Implemented and then reverted** — `compiler/types/typecheck.mdk`:
            `ieImplExistsForHead` / `ieImplExistsForHeadGo` (new, beside `headTabOf`; the `IE` peer
            of `implExistsForHead`, retest kept spelling-keyed through `headTabIs`/`dispHeadTab` per
            the `#1111` MEASURED block); repointed the **two importer-shadow** reads —
            `inferShadowApp` and `definerReceiverDispatches` — from
            `implExistsForHead perRun.value.shadowKeyTableRef.value` to
            `ieImplExistsForHead perRun.value.bodyImplEnvRef.value`. `resolveRLocalSite` left on its
            threaded `keyTable`, per the brief's ruling. Plus five prose corrections (below).
            **On disk now: nothing.**

transform:  Re-base `implExistsForHead`'s importer-shadow callers off the cumulative key table onto
            the graph-global substrate. Licensed as a CONFORMANCE FIX by
            `docs/spec/SHADOW-SEMANTICS.md:183-186` (the live-impl/no-impl test is taken *"against
            S2's **graph-global** impl universe (§1.0), never filtered by what `M` can name"*),
            `:226` (graph-global *"ranges over **every** module of the loaded graph, whether or not
            any import path reaches it"*), `:36-37` (*"S1's interface operand is scoped to what the
            module can NAME; **S2's impl universe stays graph-global**"*), and `:228-245` (the two
            operands are separately scoped; `:242-245` **retires** *"local ∪ imported ∪ prelude"* as
            a false synonym for graph-global). **No signature change** to `implExistsForHead`, which
            is what kept `resolveRLocalSite` off the diff — the brief's hard constraint was met
            without a pass-through parameter.

could move: 🔴 **IT MOVED, AND IT IS AN S0. THIS IS THE FINDING — and the brief's own scoping
            ruling is its cause.** Five files, `main.mdk` importing two independent siblings; the
            only difference between the two importer arms is **the order of two `import` lines in a
            third module**. Measured on freshly built binaries, base = `1e7cbbbb`:

            | arm | verb | base `1e7cbbbb` | after the two-site repoint |
            |---|---|---|---|
            | `c-imp` (`import m` first) | `check` | **1**, located `Type mismatch: Int vs Box` | **0**, `main : Unit` |
            | `c-imp` | `run` | 1 (same reject) | **1**, `E-PANIC: unknown op '+'` |
            | `c-imp` | `build` | 1 (same reject) | **0** |
            | `c-imp` | **built binary** | — | **0**, prints **`70018059149297`** |
            | `c-imp2` (imports SWAPPED) | all four | **0**, `300` | **0**, `300` |
            | `c-def` (definer shadow) | `check`/`run` | 1, located reject | **1, unchanged** ✅ |

            A **loud located reject became exit 0 printing a garbage pointer** — `AGENTS.md`'s *"a
            fix that makes a defect QUIETER is a severity INCREASE"*, arriving as the `check`-exit-0
            over-a-broken-binary shape RUN-B-023 already measured once at the selection legs.

            **Mechanism PROVEN from the emitted IR, not inferred** (`build --keep-ir`, `mv`'s
            forcing thunk, same source both arms):
            * `c-imp`  → `%t6 = call i64 @mdk_prov__size(i64 %t5)` — **the standalone** `Int -> Int`,
              handed a `Box` pointer, so `n + 1` is pointer arithmetic ⇒ `70018059149297`.
            * `c-imp2` → `%t6 = call i64 @mdk_impl_Box_size(i64 %t5)` — the impl ⇒ `300`.
            `@mdk_impl_Box_size` is **defined in both** IRs, so the impl was emitted and simply not
            routed to: a ROUTE defect, not an availability one.

            **Why: I split ONE decision across TWO TIMES.** The widening moved the
            **inference-time** existence read; the **route-time** existence read
            (`resolveRLocalSite`, still on the topological-prefix `keyTable`) did not move. So
            typecheck answers *"an impl exists → type against the METHOD scheme"* while the route
            resolver answers *"no impl in my prefix → stamp `RLocal` → the standalone."* Type and
            route disagree. **That invariant is written down at the violated site**, in
            `resolveRLocalSite`'s own header: *"Routing here on a gate the typing entry points do not
            share would route a site whose TYPE came from the dispatch path — route and type
            disagreeing is exactly the P0-20 bug class. **Keep the two gates identical.**"*

            🚨 **The brief and `P-c-packet.md` both saw the tension and resolved it the wrong way.**
            The packet's §2 offered two resolutions and the brief ruled (i): *"this bite covers
            `11548` and `11835` ONLY … `15352` is deferred."* Its stated reason — that the two
            inference sites *"have **NO** sibling selection read"* — **is true and is not
            sufficient.** They have a sibling **existence** read, at a different phase, and P0-20 is
            about exactly that pairing. The packet's hazard was *"existence global, selection
            prefix, at ONE site"*; the actual defect is *"existence global at typecheck, existence
            prefix at routing, across TWO sites."* Same desync, one organ over, and the deferral
            **created** it rather than avoiding it.

            **⇒ Correct scoping, for the re-cut:** all **three** existence reads move together, and
            `resolveRLocalSite` can only move together with its own sibling selection read
            (`routesOfMonosTop … keyTable` → `entail (EKNestedTop keyTable)`). That is the packet's
            resolution **(ii)**, which reaches the evidence path the brief walled this bite off
            from. **There is no two-site version of this bite.** The alternative — leave the tree in
            live divergence from `SHADOW-SEMANTICS.md:183-186` — is what `1e7cbbbb` already does,
            and it is a **false reject** (loud), not silent wrongness, so deferring costs nothing
            that this attempt would not have made worse.

            ⚠️ **`c-imp2` is why nobody would have caught this from the fixture corpus.** The
            widening's *intended* effect (order-invariance) and its *defect* are the same edit; the
            accepting order was already correct before the change, so every arm that looks right
            still looks right. The discriminator is the **pair**, not either member.

nearest miss: **(a) definer shadow, receiver's impl in a NON-PREFIX module — WRITTEN AND RUN, and it
            is the control that held.** Five files (`ifc`/`m`/`q`/`main`, packet §5(a));
            `m`'s `size` is `m`'s own top-level fn, the `Sizeable Box` impl lives in sibling `q`,
            which `m` does not import. Base and post-change agree: **located reject
            `m.mdk:4:9: Type mismatch: Int vs Box`, exit 1, on `check` and `run`** — S2's inversion,
            unchanged. ✅ **So the widening did NOT reach the definer arm**, as briefed: both moved
            reads short-circuit on `isDefinerShadow` first. That is the one outcome that would have
            made this an S0 *of a second kind* (silently re-erasing a user's own top-level function)
            and it did not occur. **The S0 above is on the IMPORTER arm, which is where the brief
            said the widening lands.**
            **(b) an `import`-less module (S1 vs S2 separation) — NOT WRITTEN, ALREADY COVERED.**
            `test/shadow_fixtures/i13_importer_not_nameable_liveimpl` (5 modules) is exactly this
            cell; siblings `i12`, `i17`, `i18`, `i21`, `d24_definer_return_pos_not_nameable` sit on
            the same axis. It cannot regress **structurally**, not merely by fixture: shadow-hood is
            computed *before* any existence read, from a **different substrate**
            (`crossRun.universeIfaceMethodsRef` through `nameableIfaceShadows`), and the impl table
            is not an input to it at all. S1's operand and S2's operand are **separately computed**,
            not merely separately documented (`SHADOW-SEMANTICS.md:228-245`). Graded by
            `test/diff_compiler_shadow_semantics.sh`.
            **(c) the nearest program the CORRECT (three-leg) fix will still not cover — stated
            now so the re-cut inherits it:** `resolveRLocalSite`'s **`None` arm** (ungrounded
            receiver). It consults no impl table at all, so an importer shadow whose receiver never
            grounds is left untouched on any substrate; widening cannot reach it, and no arm of
            `c-imp`/`c-imp2`/`c-def` exercises it.

engines:    **ONE LINE, and then it is not one line.** No compiled byte of the four arms changed
            (LLVM `llvm_emit` · WasmGC `wasm_emit` · `eval` · `core_ir_eval` are untouched source).
            🚨 **But the bite changed the `Route` — `RKey` vs `RLocal` — which all four consume, and
            two of them were MEASURED disagreeing about it:** `eval` said `E-PANIC: unknown op '+'`
            (loud) where **LLVM said exit 0 with a garbage integer** (silent). Same program, same
            route, opposite severities — so on the re-cut each arm owes an explicit reading:
            `eval`/`core_ir_eval` must be checked in **lockstep** (parallel module drivers), and
            `wasm` was never observed here at all. `diff_compiler_engines` is exactly the gate that
            would grade it and it was **not run** (~6 min, foreground-unsafe, owned by CI).

unchecked:  * **`make medaka` — RUN, exit 0** on the transform (stage A + stage B, no anomaly), and
              again after the revert to restore a `1e7cbbbb`-faithful binary. **2 build cycles for
              the experiment, 1 to restore; none avoidable.**
            * **`make check-self`, `diff_compiler_flat_vs_onemodule.sh` (13 rows), the gate suite:
              NOT RUN — deliberately abandoned the moment the S0 was measured.** Running a
              conformance floor over a diff already known to emit a garbage value would spend ~10
              min of a shared box to grade something that is being reverted. The IR read is the
              stronger evidence and it is in hand. **⇒ The transform's effect on those gates is
              UNKNOWN, and the patch must not be re-applied on the strength of this row alone.**
            * **`test/diff_compiler_shadow_semantics.sh` NOT RUN even single-armed** (#1431: it
              hardcodes `$ROOT/medaka`, so a base-vs-branch shadow differential needs a second
              worktree — cost restated, not paid). The base arm above came from the **pre-edit
              binary already in the trunk**, which is the same information a second worktree buys
              for this bite, at zero build cost. Worth generalizing: **capture the base arm before
              the first `fmt`/build, not after.**
            * **`selfcompile_fixpoint.sh`, `typecheck_compiler_source.sh`, corpus sweeps, seed
              re-mint: NOT RUN**, per the reduced floor. Moot — nothing landed.
            * **No goldens moved and none re-cut** (snapshot corpus, `selfproc_legA`) — the file is
              byte-identical to `1e7cbbbb`. The re-cut bite will owe both.
            * **`could move:`'s base column is one binary, not two.** The pre-edit `./medaka` in the
              trunk was built by the previous bite; I did not independently re-derive that it was
              built from `1e7cbbbb` source rather than something near it. Every base reading is
              corroborated by the post-revert rebuild agreeing, but that is agreement, not proof.
            * **FIVE PROSE CORRECTIONS WERE WRITTEN AND ARE IN THE PATCH, UNLANDED — they are true
              independently of the transform and the tree is still wrong without them:**
              1. **Both** stale defence comments rewritten (not deleted), per the retired-synonym
                 rule — `inferDefinerShadowApp`'s P0-19 d8 note and the `#415 item 2` block. Note
                 `grep -n 'local ∪ imported'` finds both; the longer phrase finds only one.
              2. 🚨 **`#415 item 2`'s premise *"there is no second table in scope to drift TO"* is
                 ALREADY FALSE at `1e7cbbbb`** — `bodyImplEnvRef` is a second impl table, in scope
                 from anywhere, and B-2.1-b2 already moved three selection legs onto it. **That
                 sentence is what licensed this bite's scoping**, so it is not cosmetic debt.
              3. **`"nothing reads bodyImplEnvRef yet"` appears TWICE and both are false at
                 `1e7cbbbb`** (B-2.1-b2's five readers) — `buildFlatImplEnv`'s header and
                 `checkBodyImpl`'s seeding block. Pre-existing, not mine.
              4. The `headTyconMono`-widening block's **derive-grep would go stale** under any
                 split of the three existence reads across two function names. Fixed form:
                 `grep -nwE '(ie)?[Ii]mplExistsForHead' … | grep -vE '^[0-9]+:[[:space:]]*--' | grep -vE '^[0-9]+:(ie)?[Ii]mplExistsForHead'`.
              5. **Discovered, and it is the re-cut's cheapest win:** the transform makes
                 `shadowKeyTableRef` **WRITE-ONLY** (zero code readers), and with it its whole
                 supply chain — `universeKeyBucketsRef` is read at exactly ONE site, the copy into
                 `shadowKeyTableRef`, so `bucketKeyEntries`' per-module append and `buildKeyTable
                 fullUniverse` on the Flat arm both become pure waste. **Not deleted**: retiring
                 the ref means editing the `PerRun` record, which carries the **#829** interior-
                 comment `fmt --write` corruption hazard (REOPENED). Verify the header shape before
                 touching it.
            * **`fmt --check` / `lint` clean on the transform** (`already formatted`, 0 findings) —
              run **before** the build, per the brief; no post-build reflow, no wasted cycle.
            * **NOT COMMITTED**, per the brief. Working tree holds **this row only**; the transform
              is `scratchpad/c-REFUSED.patch`, and `scratchpad/c-{def,imp,imp2}/` + `c-probe.sh` +
              `c-build-probe.sh` + `c-ir-probe.sh` + `c-before.txt` + `c-after.txt` reproduce every
              reading above against any binary (`sh c-probe.sh <medaka> <label>`).

---

### `B-2.1-f` — Phase 2′ (B-2.1) — the drain's Item-4 residual RE-ARMED as a loud reject. **The 139 is gone; `check` is still blind, and that is pinned, not hidden.**

🔗 **Ledger cross-reference: `DECISIONS.md` RUN-B-0xx** (the orchestrator composes it from this
row + my report). Predecessors: RUN-B-031 (`B-2.1-b2`, the drain that introduced the S0 while
genuinely draining three others) and `B-2.1-e`'s STOP, which measured it and refused to edit.

sites:        `compiler/types/typecheck.mdk` — `keyForSite` (both BARE-WORD arms now call the
guard; the canonical-key arm is untouched) · SIX new top-level bindings beside
`ieCountHeadByIface`: `ieCountHeadByMethod` / `ieCountHeadByMethodGo` /
`ieHeadCollidesByMethod` / `routeWordHeadSkew` / `reportRouteWordSkew` /
`routeWordAmbiguousMsg` · the `B-2.1-b2` block's leg-3 paragraph, corrected in place (its
"that residual is a *naming* skew" wording is quoted and retracted rather than deleted).
`compiler/DIAGNOSTIC-CODES-DESIGN.md` — the `T-REQUIRES-UNROUTED` row's CAUSE sentence
corrected (it still named `shadowKeyTableRef`/`universeKeyBucketsRef`, false since the drain
bite) and marked DRAINED for those causes; one new row, `T-ROUTE-WORD-AMBIGUOUS`.
`test/diff_compiler_check_cli_modules.sh` — `D4b` legs 1-2 and `SA-4b` re-cut as DRAIN
assertions that grade the BUILT BINARY's output; `SA-4c` re-cut as a reject on `build` + a
new row pinning the verb split.
**No `lint-disable` anywhere; `medaka lint` exits 0 on the touched source, `fmt --check` clean
(run BEFORE every build).**

transform:    ONE guard, ONE substrate, on the ONE unsafe direction. `keyForSite` stamps a
BARE head word whenever its prefix table says the goal's head is unique. That word is a NAME
three engines re-derive graph-globally, so it is only correct if the whole graph agrees the
head is unique. The guard is exactly that disagreement — `not (headCollides prefix …) &&
ieHeadCollidesByMethod graph …` — pushed as a new code `T-ROUTE-WORD-AMBIGUOUS` located
through `goalSiteLoc` (the span the five `resolve*` loops already republish per site).
`ieCountHeadByMethod` is the method-name-keyed peer of `ieCountHeadByIface`, spelling-keyed
through `headTabOf`/`headTabEq` for the reason derived in full on `countHead` (its consumer is
a byte-for-byte agreement with a bare-`String` namespace; an identity comparison is wrong
there at any supply level).
**NOT `T-REQUIRES-UNROUTED`, and that was a judgement call I own:** Door 4's message opens
*"Cannot pass a dictionary for …"*, and the impl min⊑ actually selects for this shape
(`impl Tag (Wrap Int)`) carries no `requires` and needs no dictionary — the dictionary only
appears because the ambiguous word resolves to the WRONG, conditional impl. Reusing the code
would have kept `SA-4c`'s existing assertion green at the price of a message that misnames its
own cause. ⚠️ **The cost of that choice is that `SA-4c`'s assertion had to move anyway**, so
the code choice bought nothing in gate churn — it was made on ERROR-QUALITY grounds alone.

could move:   **A REJECT-WIDENING, deliberately, and here is the named set.**
* **Newly rejected:** any *method*-keyed site (return-position, arg-position or operator —
  every kind that reaches `keyForSite`) whose goal has a head tycon `T`, where the module's
  topological prefix holds **0 or 1** impls defining that method at `T` and the **whole
  graph** holds **2 or more**. Concretely: two impls of one interface at one head, declared
  in a module that sorts after the goal's own module — **and, because the count is
  SPELLING-keyed, two unrelated modules each declaring their own distinct type of the SAME
  NAME with an impl of the same interface method** (the `#1397`/`#1514` shape below; this half
  was not in the brief and I did not predict it either). Nothing else — the guard's other
  count-pairs (1-vs-1, 2-vs-2, 2-vs-3, and every prefix that already collides) are inert.
* 🚨 **YES, LEGAL PROGRAMS ARE NOW FALSELY REJECTED, and this is the set.** A specific/general
  overlap where the SELECTED (most-specific) impl needs no dictionary is a legal, correct
  program — the control import order compiles it and its binary prints the right answer — and
  it is now rejected in the other import order. That is `SA-4c` itself. The reject is
  recoverable by adding one `import`; the state it replaces was a binary at **139**. `B-2.1-g`
  drains this whole set when it repoints the word.
* **NOT moved, verified rather than assumed:** the canonical-key arm of `keyForSite` (a
  colliding prefix stamps a key that names one impl on any substrate), `keyForSiteByIface`
  (already graph-global since the drain), the headless-winner word `noneHeadTag`, and every
  goal with no head tycon.
* 🚨 **TWO MORE MUST-FAIL PINS DRAINED, AND NOT BY BEING FIXED — BY BEING REJECTED. THIS IS
  THE BITE'S BIGGEST FINDING AND IT WAS NOT PREDICTED BY THE BRIEF.** `must_fail` reports
  **95 REPRO / 5 DRAINED / 0 control-broke / 0 malformed**, run TWICE with identical counts.
  Three are the expected `#1564`/`#1599`/`#1072`. The other two are **`#1397`** and
  **`#1514`**, and they are MINE: both are cross-module **same-SPELLED** collisions, and this
  guard is spelling-keyed (through `headTabOf`/`dispHeadTab`, deliberately — `countHead`
  derives why at length: the route word's consumer is a bare-`String` namespace three engines
  re-derive, so an identity comparison is wrong there at any supply level). Two unrelated
  modules each declaring their OWN type spelled `Thing` therefore count as **two impls at one
  head** graph-globally while each module's prefix sees one ⇒ the guard fires.
  Measured on both fixtures: `run main.mdk` **exit 1** (was exit 0 with a wrong value),
  `check main.mdk` **exit 0** (the same blindness as item 1), and **both controls still pass**
  (`aamod|zzmod`; `11`/`110`/`7`).
  ⛔ **DO NOT CLOSE #1397 OR #1514 ON THE STRENGTH OF THIS DRAIN.** Neither is fixed. #1397's
  own IR proof — ONE `@mdk_impl_Thing_label` where there must be two — is still true; the
  compiler simply now refuses to emit the program instead of silently picking one impl. For
  #1397 the refusal is arguably *correct* (that shape has no correct emission today).
  🚨 **For #1514 it is a genuine CAPABILITY LOSS: its `medaka build` BINARY WAS CORRECT**
  (`11`/`110`/`7`, per its own claim.txt) **and `build` now refuses it.** That is the sharpest
  instance of this bite's false-reject surface and the orchestrator's call, not mine.
* **The three expected drains hold.** `#1564` and `#1599` declare ONE impl at the head, so the graph
  count is 1 and the guard cannot fire; `#1072`'s method site is `speak x` at a bare tyvar,
  which keys no bucket at all. Measured, not reasoned — `must_fail` names all five drains.

**MEASURED, four verbs, before vs after, on the `SA-4c` program:**

| arm | `1e7cbbbb`…`3ba7817b` (the S0) | this bite |
|---|---|---|
| `check` (human) | 0, `main : Unit` | **0, `main : Unit`** ⚠️ unchanged |
| `check --json` | 0, empty diagnostics | **0, empty diagnostics** ⚠️ unchanged |
| `build` | 0 | **1, no binary produced** |
| `run` | 0, `wrap-int-specific` (eval was right) — ⚠️ **RELAYED from `.claude/HANDOFF.md`, not measured by me on the base binary**; every other base cell in this table I measured first-hand before touching the source | **1** |
| **built binary** | **139, `E-FATAL-SIGNAL`** | **none exists** |
| control order, built binary | 0, `wrap-int-specific` | **0, `wrap-int-specific`** |

nearest miss: **🚨 ITEM 1 IS THE BITE'S OWN FAILURE AND IT IS THE HEADLINE, NOT A FOOTNOTE:
`medaka check` STILL EXITS 0, and the reject carries NO LOCATION on any verb.** The brief's
evidence item 1 (a located diagnostic from human `check` **and** `--json`) is **NOT
DELIVERED**. What the user sees on `build`/`run` is `error: type error in main.mdk. Run
`medaka check` for details` — and `check` then reports nothing. So the compiler contradicts
itself, and this is an ERROR-QUALITY *Located* regression sitting on top of a genuine severity
DECREASE (no wrong binary can be produced).

**WHY, derived on the binary, two independent causes either of which alone suffices:**
1. `keyForSite` is reached ONLY from the five `resolve*` stamp passes, which run in
   `elabModuleStamp` — inside `elaborateModules`. `medaka check` on a multi-module project
   goes `analyzeProject` → `typecheckPass` → `checkModulesDiags` → `checkModuleFullDiags`,
   which typechecks and never stamps a route. (Door 4's guards reach `check` because they fire
   in the OBLIGATION channel, during typecheck proper.)
2. Even given the pass there is nothing to stamp: pending route sites are recorded by
   `inferMethodAt`, which only ever sees an `EMethodAt` node, and those are minted by the MARK
   pass (`markModules`/`prePassDict`) — likewise called only from `elaborateModules`. The check
   driver's method occurrences go through `inferVarPlainId`, so `pendingSites`/
   `pendingArgStamps` are **EMPTY** on that path.

**I WROTE, BUILT AND MEASURED THE FIX FOR THIS AND THEN REMOVED IT** — an `auditRouteWords`
pass at the tail of `checkBodyImpl`, the one function both drivers share, over
`shadowKeyTableRef`. It is **INERT**, for cause 2, and dead code that claims to guard something
is worse than no code: removed, with the whole derivation recorded in place on the guard block
so `B-2.1-g` inherits it instead of re-paying for it. **Two build cycles went to establishing
this; both were necessary and neither is repeatable from the source alone.**

⚠️ **TWO WRONG FIXES, NAMED so nobody spends a session on them.** (a) The check route DOES run
`elaborateModules` once — inside `mainShapeWarnings` (`driver/medaka_cli.mdk`, `checkRoute`'s
multi-module arm) — and DISCARDS its type errors, keeping only warnings. Same family as #1362.
Surfacing them narrows acceptance for every program in the tree; that is not a bite, it is a
sprint. (b) Re-deriving the skew in the OBLIGATION channel is keyed by INTERFACE over
`residualUnivRef` where this one is keyed by METHOD NAME over `KeyBuckets` — not the same count
(an impl inheriting the method via a DEFAULT is in one population, not the other), so it would
be a SECOND selector disagreeing with the first. DICT §11 forbids that, and RUN-B-023 and
`B-2.1-c` each produced an S0 by splitting one decision across two reads.

**Item 2 — the shape the guard does NOT catch, and it is a real residual.** A prefix that
ALREADY collides (count ≥ 2) stamps the canonical key of the **prefix's** min⊑ winner. If the
graph holds a *third*, strictly more specific impl at that head, the counts agree (both > 1),
the guard is silent, and the stamped key names the wrong impl. Not tested — I did not build the
three-impl fixture, and I am not claiming it reproduces; it is the next program to attack.
**Item 3** — the `noneHeadTag` (headless-winner) word: excluded on purpose, its correctness
rests on the emitter's general-instance fallback tier rather than on this count.
**Item 4** — a site inside an `impl` body: those are inferred only under `implInferEnabled`
(emit path), so on `check` they are not even recorded. Subsumed by item 1's cause 2.

engines:      **One line, then it is not one line.** No engine source changed — `llvm_emit`,
`wasm_emit`, `eval`, `core_ir_eval` are byte-identical. But the guard's whole subject matter is
the **route WORD**, which all four consume: `core_ir_lower.declRouteKey`/`ifaceDeclHeadUnique`,
`llvm_emit.headTagUnique`/`distinctKeysAtHead`, and `eval.pickTagFallback`'s peer arm each
re-derive the same uniqueness test from a bare `String`. This bite changes **no** word — it
refuses to stamp an untrustworthy one — so no engine's derivation moves and no lockstep peer is
owed. ⚠️ What it DOES owe is a `diff_compiler_engines` reading, because `run` (eval) now
rejects a program eval used to execute CORRECTLY (`wrap-int-specific`): eval was the one engine
that was right about this shape, and the guard silences it too. That is the accepted cost of a
type-level reject, but it is a genuine eval behaviour change and `diff_compiler_engines` is what
would grade it. NOT RUN (~6 min, foreground-unsafe, owned by CI).

gates run:    `diff_compiler_check_cli_modules.sh` **86 ok, 0 failing** (was 81/4 — +1 row: I
split `D4b`'s build leg into a binary-OUTPUT assertion and added the verb-split pin).
⚠️ The inherited `1112-A34/later-invisible` red that `.claude/HANDOFF.md` calls
"pre-existing, not ours" is **also green now** — it was not red on this binary at all, so that
HANDOFF line is stale as of this bite; I did not chase why, and it is not something this diff
could have fixed (it failed by ACCEPTING). · `diff_compiler_must_fail.sh` **twice, 95/5/0/0
both runs, same five names** · `diff_compiler_flat_vs_onemodule.sh` **13 rows, PASS** (1 drain
notice) · `make check-self` **PASS** — ⚠️ and it is a WEAK signal here by construction: it
runs `./medaka check`, the one verb this guard is invisible to (item 1). · `make
agent-doc-symbols` **PASS** (0 dead) · `make docs-links` **PASS** (0 dead) · `medaka fmt
--check` clean and `medaka lint` 0 findings on the touched source, both BEFORE each build.
**Breadth check for over-firing, since the false-reject surface is the whole risk:** all **39**
`sqlite/*_demo.mdk` + `*_probe.mdk` programs (a real multi-module project) `check` and `run`
with no route-word refusal, and `must_fail`'s **0 control-broke** means 100 control programs
still behave. So the over-fire set really is the same-spelled/overlap shape and not something
broad.

unchecked:
* **`selfcompile_fixpoint.sh` NOT RUN** — brief-assigned to CI's `soundness` shard. This bite
  emits no IR change by construction (it adds a reject; it never changes a stamped word), and
  `make medaka` completed cleanly twice on the final source, which is the two-stage self-compile
  in miniature. That is evidence, not the gate.
* **Snapshot and `selfproc_legA` goldens NOT re-cut, both owed.** This diff adds **six** new
  top-level bindings (`ieCountHeadByMethod`, `ieCountHeadByMethodGo`, `ieHeadCollidesByMethod`,
  `routeWordHeadSkew`, `reportRouteWordSkew`, `routeWordAmbiguousMsg`), renames none and
  re-signatures none — so the legA diff must read **purely additive**. Derive rather than trust:
  `git diff -U0 compiler/types/typecheck.mdk | grep '^[+-][a-zA-Z]' | grep ' : '`.
* **`diff_compiler_engines.sh`, `diff_compiler_perf_scaling.sh`, `typecheck_compiler_source.sh`,
  `diff_compiler_shadow_semantics.sh`, corpus sweeps, the full suite: NOT RUN**, per the brief's
  reduced floor.
* **PERF: one extra graph-global bucket scan per bare-word stamp, and it is NOT free by
  construction.** `&&` short-circuits only the case where the prefix ALREADY collides, which is
  the rare one — so the common path does pay one `ieHeadRows` lookup plus one bucket walk on the
  checker's hottest selector. It allocates only the single `headTabOf` key. Graded by
  `make check-self` (see below); **not** interleaved, wall-clock only, on a shared box.
* **The `SA-4c` verb-split row I added asserts a KNOWN-WRONG state.** It is fail-capable in both
  directions (it reds if `check` learns to see the channel, and it reds if `check` starts
  rejecting for some other reason), and it names `B-2.1-g` as its drain. But it is a pin of an
  S2, and a reader who greps this gate for "does `check` reject" will get "no" and be right.
* **NOT COMMITTED**, per the brief. Working tree holds four files (three source/gate/doc +
  this row); `scratchpad/sa4c/` + `probe.sh` reproduce every reading above against any binary
  (`sh probe.sh <medaka> <root> <label>`), and `probe4.sh` reproduces the #1397/#1514 readings.

---

### `B-2.1-g` — Phase 2′ (B-2.1) — **THE COMBINED BITE: route word + all three existence reads + `resolveRLocalSite`'s selection leg, onto ONE graph-global substrate. The `SA-4c` 139 is GONE and the program is CORRECT in BOTH import orders; `f`'s capability regression is CLEARED.**

🔗 **Ledger cross-reference: `DECISIONS.md` RUN-B-0xx** (the orchestrator composes it from this
row + my report). Predecessors this bite consumes and closes out: RUN-B-031 (`B-2.1-b2`, the
drain that introduced the S0 by leaving the method-keyed route word on the prefix table *by
design*, AM-1), `B-2.1-e`'s STOP (which measured it), `B-2.1-c`'s REFUSAL (which measured that a
two-of-three existence scope is itself an S0), and `B-2.1-f` (the loud stand-in reject, now
retired). **This bite AMENDS AM-1**: the `keyForSite*` family no longer reads the prefix table.

sites:        `git diff --numstat` — **285/62 `compiler/types/typecheck.mdk`, 69/34
`test/diff_compiler_check_cli_modules.sh`, 1/1 `compiler/DIAGNOSTIC-CODES-DESIGN.md`.** Three
files. The signature delta is exactly three lines
(`git diff -U0 compiler/types/typecheck.mdk | grep '^[+-][a-zA-Z]' | grep ' : '`):
**+`ieImplExistsForHead`, +`ieImplExistsForHeadGo`, and `keyForSite` re-signatured** (its
`KeyBuckets` parameter REMOVED, not ignored — an ignored table parameter reads as "still
consulted" at every call site; `keyForSiteByIface`'s precedent). **Nothing deleted, nothing
renamed** — so `selfproc_legA` must read as *those* two additions plus *that one*
re-signature, and any OTHER binding's inferred type moving means the fix changed types.
Two-thirds of the line count is prose: seven stale-comment blocks corrected in place
(see `unchecked:`), and the thirteen dead-code notes below.

transform:    **ONE substrate for one decision, at every phase it is taken.** Four members,
moved together because three prior scopings proved no subset is correct:
1. **The METHOD-keyed ROUTE WORD** — `keyForSite` reimplemented over
   `perRun.bodyImplEnvRef`: selection through `ieSelectRowByMethod` (the min⊑ selector `b2`
   already seated, `instRefSeq`-indexed) and the collision retest through
   `ieHeadCollidesByMethod` (`f`'s predicate, repurposed from a second opinion into THE
   opinion). Its three call sites (`entailInst`'s `EKReturn` and `EKArg` arms,
   `stampOpRouteVal`) drop the table argument. The winner's key is recomputed by the same
   `implKeyTc ir.irName tys` that `keyEntryOfRow`/`keyEntryOf` stamp, so the WORD is
   byte-identical for any winner both substrates agreed on; only the population moved.
2. **All three EXISTENCE reads** — `inferShadowApp`, `definerReceiverDispatches` (both
   inference-time) and `resolveRLocalSite` (route-time) → the new `ieImplExistsForHead`,
   the `IE` peer of `implExistsForHead`. Retest kept **spelling-keyed** through
   `headTabIs`/`dispHeadTab`: a structural `HeadKey` compare re-opens #1111's S0, measured,
   and the bucket it scans is filed under the same projection.
3. **`resolveRLocalSite`'s own SELECTION leg** — moved *by construction* rather than by a
   second edit: its leg is `routesOfMonosTop … keyTable` → `routeOf` → `entail` →
   `entailInst` → `keyForSite`, and (1) repointed `keyForSite`. So existence and selection at
   that site read ONE population again, which is the invariant its own header demands.
4. **`f`'s guard is UNREACHABLE, NOT DELETED** — see the ⛔ finding below.
**Licensed as a conformance fix** by `docs/spec/SHADOW-SEMANTICS.md:183-186` (the
live-impl/no-impl test is taken *"against S2's **graph-global** impl universe (§1.0), never
filtered by what `M` can name"*), `:226`, `:36-37`, and `:242-245` (which **retires** *"local ∪
imported ∪ prelude"* as a false synonym for graph-global — the phrase two of the corrected
comments were defending themselves with).

⛔ **THE FINDING I MUST REPORT RATHER THAN QUIETLY RESOLVE: `f`'S GUARD IS NOT SEPARABLE FROM
THE SUBSTRATE THIS BITE RETIRES.** The ruling was *"make the guard unreachable, do not delete
it — a loud→silent transition is a severity increase; deletion is a separate argued
decision."* Honoured. But `routeWordHeadSkew` reads `headCollides` → `countHead` →
`countHeadGo` → `bucketOfHead` — the whole prefix-table READ side, whose other members
(`implExistsForHead(Go)`, `matchedEntry`, `matchingEntries(Go)`, `candidateBucket`) went dead in
the same edit. **So "keep the guard, delete the rest" does not exist as an option: deleting its
dependencies deletes the guard.** ⇒ **THIRTEEN bindings are dead and all thirteen are RETAINED**,
each with its own `-- lint-disable-next-line rule-dead-code` and a one-line pointer to the shared
coupling note on `routeWordHeadSkew`. That is not cosmetic: `medaka lint` HAS a `rule-dead-code`
rule and the pre-commit hook is a max ratchet, so **the thirteen were a hard gate, not a
preference** — silence had to be explicit and PER SITE rather than a file-wide waiver that would
hide FUTURE dead code in a 30k-line file. `B-2.1-d` retires the thirteen in ONE argued sweep with
the two refs. ⚠️ **Derive by NAME, never by count** — one `rule-dead-code` disable in this file
(`wReset`) predates this bite, so `grep -c` answers **14**, not 13:
`grep -n -A1 'lint-disable-next-line rule-dead-code' compiler/types/typecheck.mdk`.

⚠️ **ONE ATTRIBUTION IN THE BRIEF IS WRONG AND IT MATTERED TO THIS DECISION.** The brief says
the guard *"still covers #1578"*. It does not. #1578 is `residualPredsOf`'s no-match arm, named in
**`T-REQUIRES-UNROUTED`**'s row, not in `T-ROUTE-WORD-AMBIGUOUS`'s; and `f`'s own `must_fail` run
shows **#1578 REPRO with the guard live**, as does mine with it dead. So retiring this guard costs
#1578 nothing — the reason to keep it is the loud→silent rule *as a rule*, not a covered issue.

could move:   **A GREAT DEAL, and it moved in the intended direction on every arm I could
observe. MEASURED, not inferred; every exit code read from a file redirect, never through a
pipe.**

🚨 **1. `SA-4c` — THE GATING REQUIREMENT — BUILDS AND RUNS CORRECTLY IN BOTH IMPORT ORDERS,
AND THE TWO ORDERS' IR IS BYTE-IDENTICAL.** Four verbs × two orders, all eight cells:

| arm | `1e7cbbbb`…`3ba7817b` (`b2`, the S0) | `086aeb35` (`f`) | **this bite** |
|---|---|---|---|
| `check` (human) | 0, `main : Unit` | 0, `main : Unit` | **0, `main : Unit`** |
| `check --json` | 0, empty diagnostics | 0, empty diagnostics | **0, empty diagnostics** |
| `build` | 0 | **1, no binary** | **0** |
| `run` | 0, `wrap-int-specific` | **1** | **0, `wrap-int-specific`** |
| **built binary** | **139, `E-FATAL-SIGNAL`** | none exists | **0, `wrap-int-specific`** |
| control order, binary | 0, `wrap-int-specific` | 0, `wrap-int-specific` | **0, `wrap-int-specific`** |

**Emitted-IR evidence, off `build --keep-ir`:** `%t3 = call i64
@mdk_impl_Tag__Wrap_Int___tagOf(i64 %t2)` against `define i64
@mdk_impl_Tag__Wrap_Int___tagOf(i64 %arg0)` — **the arity-1 SPECIFIC impl, called with one
argument**. The arity-2 conditional impl `@mdk_impl_Tag__Wrap_a___tagOf(i64 %arg0, i64 %arg1)`
is still defined and every one of its call sites passes **two** args (`(i64 %t13, i64 %arg0)`).
`b2`'s shape — an arity-2 define called with ONE argument — is **absent**. And
`diff main.bin.ll control.bin.ll` is **empty**: the two import orders now emit the same bytes,
which is the strongest form the order-invariance claim can take.

🚨 **2. #1514's CAPABILITY LOSS IS CLEARED, AND #1397's OVER-FIRE WITH IT.**
`diff_compiler_must_fail.sh` **run TWICE on the final binary: 97 REPRO / 3 DRAINED / 0
control-broke / 0 malformed, identical counts and the same three NAMES both runs.**
**DRAINED, read by name and never from the count: #1072, #1564, #1599** — exactly `b2`'s three
intended drains, still drained. **#1397 and #1514 are back to REPRO**, i.e. `f`'s
spelling-keyed guard no longer refuses their legal programs. ⚠️ The count going **5 → 3** is
itself the anti-swap check the brief asked for: a silent substitution would have held 5.
**Answering the brief's item 3 directly:** #1397 no longer rejects, and that is **correct** —
the reject was over-fire, not progress. Neither #1397 nor #1514 is FIXED (both are back to their
original silent wrongness) and **neither may be closed**; #1397's own IR proof (ONE
`@mdk_impl_Thing_label` where there must be two) is untouched by this bite.

**3. `B-2.1-c`'s five-file import-order corpus AGREES ON ALL FOUR VERBS.** The S0 `c` measured —
*a located reject becoming exit 0 printing `70018059149297`* — is gone, and so is the base's
false reject:

| arm | base `1e7cbbbb` | `c`'s two-site patch (the S0) | **this bite** |
|---|---|---|---|
| `c-imp` (`import m` first) | **1**, located `Type mismatch: Int vs Box` | 0, `main : Unit` | **0, `main : Unit`** |
| `c-imp` `run` | 1 | **1, `E-PANIC: unknown op '+'`** | **0, `300`** |
| `c-imp` `build` / binary | 1 / — | 0 / **0, `70018059149297`** | **0 / 0, `300`** |
| `c-imp2` (imports SWAPPED) | 0, `300` | 0, `300` | **0, `300`** |
| **`c-def`** (definer shadow) | 1, located reject | 1, unchanged ✅ | **1, `m.mdk:4:9: Type mismatch: Int vs Box`** ✅ |

**IR at the disputed site: `call i64 @mdk_impl_Box_size` on BOTH importer arms** (it was
`@mdk_prov__size`, the standalone, on `c-imp`). **`c-def` is the control that had to hold and
did** — the definer arm's located reject is unchanged, so this widening does **not** re-erase a
user's own top-level function; both shadow callers short-circuit on `isDefinerShadow` first.

**4. `check` AND `build` NOW AGREE ON THIS CLASS, WHICH RETIRES `f`'S ITEM-1 RESIDUAL BY
DISSOLVING IT RATHER THAN BY FIXING IT — and that distinction is the honest one.** `f` derived
that `keyForSite` is elaborate-only and `pendingSites` is empty on the check path, built the
obvious fix, and measured it INERT. **All of that is still true and I did not attempt either of
the two wrong fixes it named.** What changed is that the route word no longer decides
accept/reject — it decides only a word, and it now decides it correctly — so there is no verdict
for `check` to be blind to. Independently, the *shadow* half of this bite IS visible to `check`
(`inferShadowApp`/`definerReceiverDispatches` run in typecheck proper, which the check driver
does run), which is exactly why `c-imp`'s `check` moved from a false reject to 0 in agreement
with its `build`. ⚠️ **The underlying split is NOT fixed and must not be reported as fixed:**
`keyForSite` is still reached only from the five `resolve*` stamp passes inside
`elaborateModules`. If a FUTURE diagnostic is ever pushed from there, it will be invisible to
`check` again. I did not re-pin it, because the pin `f` left asserted `check 0` on this project
as a KNOWN-WRONG state and `check 0` is now the CORRECT answer — see `gates run:`.

**5. Tie-break and word semantics, for the spec reader.** The no-unique-minimum fallback at a
method-keyed site moves from *arbitrary* (`bucketKeyEntriesFrom` restarts its ordinal per module
⇒ duplicate indices, each slice prepended ⇒ descending, violating `mergeByDeclIdx`'s ascending
precondition) to **graph-global declaration order** (`instRefSeq`, ascending by construction) —
the same change `b2` made on the iface-keyed legs, stated verbatim from its row: *"at a
non-closed, no-unique-minimum multi-module goal the fallback moves from arbitrary … to
graph-global declaration order."* ⚠️ **This is NOT licence to implement T4** — DICT §11: *"T4
MUST NOT be implemented before I5."* The non-closed goal is still silently decided by list
order; only the order is now statable. **Second word change, stated because it is an IR change
and not a no-op:** where the prefix table held NO entry at the goal's head, `keyForSite`
answered `None` and the caller fell back to the bare goal tag; now a graph-global HEADLESS
winner (`impl C a`) yields `noneHeadTag` instead. That is `keyForSiteByIface`'s own else-arm
behaviour and the word the emitter derives (F-3b's derivation, on `keyForSite`), but it rests on
the emitter's general-instance fallback tier (`emitGeneralRKey` → `findByTag noneHeadTag`,
`eval.pickTagFallback`) — **empirical, not structural**, exactly as that block already warns.

**6. Perf.** `make check-self` PASS. `keyForSite` was already the checker's hottest selector and
it now takes `ieHeadRows` + one graph-global bucket walk in place of a prefix bucket walk — the
same trade `a3`'s index was cut to make affordable, and `f` already added the graph-side scan on
this path without a measurable regression. ⚠️ **I did NOT time it**: `check-self` is a pass/fail
here, not a benchmark, and a wall-clock A/B on a shared box with sibling agents live is the
measurement `b2`'s row is careful to disown. **The perf question for this diff is genuinely
UNANSWERED**; `diff_compiler_perf_scaling.sh` (allocation-graded, machine-independent) is what
would answer it and it was not run (~11 min, foreground-unsafe, CI's).

nearest miss: **Item 1 — the `tys = []` sub-class: STILL OWED, and this bite adds no new
exclusion.** `keyEntryOfRow`'s `[] => []` arm and `ieRowHeadMatches [] _ = False` drop a row
with no head type, which is exactly what `keyEntryOf`'s own `[] => []` arm did on the prefix
side — so such a row is unselectable on BOTH substrates, before and after. RUN-B-030 records
that it cannot be produced from surface syntax and I did not falsify that; **it is untested
because it is unwritable, which is a weaker statement than "safe" and I am not upgrading it.**

**Item 2 — a goal whose head is NOT a tycon (`goalHeadCon = None`): STATED *AND TESTED*, and
the test came out clean — but read what it actually shows.** `keyForSite` answers `None` there
(`ieSelectRowByMethod`'s own `None` arm) and the caller stamps the bare goal tag, so the repoint
cannot reach it; the fallbacks that CAN — `firstReqMatch (univHeadless univ iface)` and
`routeUndeterminedTop`'s `implHeadTagsForIface prog` — are still prefix-read (`b2`'s Item 3),
untouched. **Two discriminating programs, each with the impls in a topologically LATER module
than the goal, each run in both import orders:**
* `g-hd` — `export nest x = tagOf x`, no signature ⇒ inferred `Tag a => a -> String`, goal at
  the rigid `a`. Two impls (`Int`, `Bool`). All four verbs 0 in both orders, `int/bool`, **IR
  byte-identical between orders.**
* `g-hd2` — `export nest = tagOf`, a method occurrence in VALUE position with the receiver never
  supplied (the `undeterminedRoute` → `routeUndeterminedTop` path). All four verbs 0 in both
  orders, `int`, **IR byte-identical.**
🚨 **WHAT THAT DOES AND DOES NOT ESTABLISH.** It does *not* show the prefix-read fallbacks are
correct — it shows I **could not reach them in a way that diverges**, because a constrained
`nest` routes through its DICT (`RDict`) rather than through a stamped word, so the word is never
consulted at the headless goal. **The residual is therefore still open, and my probes are a
negative result, not a clearance.** The shape that would discriminate it has to reach
`firstReqMatch`/`routeUndeterminedTop` with prefix and graph disagreeing, and I did not find
one; that is the next program to attack, and it is the same one `b2`'s Item 3 named.

**Item 3 — `resolveRLocalSite`'s `None` arm (ungrounded receiver) is still untouched**, as
`c`'s refusal predicted for the correct fix: it consults no impl table at all, so an importer
shadow whose receiver never grounds is unaffected on any substrate. No arm of
`c-imp`/`c-imp2`/`c-def` exercises it.

**Item 4 — `f`'s own Item 2 (a prefix that ALREADY collides while the graph holds a third,
strictly more specific impl) is DRAINED BY CONSTRUCTION, not by fixture.** That shape was a
disagreement between two counts; there is now one count, taken graph-globally, so the
"counts agree while the stamped key names the wrong impl" state is unreachable. **I did not build
the three-impl fixture** — the argument is structural and the honest label is *underived*.

**Item 5 — the residual arithmetic difference is UNCHANGED and NOT claimed as fixed.**
`core_ir_lower.ifaceDeclHeadUnique` counts DISTINCT canonical keys where
`ieCountHeadByMethod` counts ROWS. Both are now graph-global over the same population, so the
POPULATION skew is closed; the arithmetic difference is the pre-existing one
`ifaceDeclHeadUnique`'s own comment records.

**Item 6 — F1 stays dormant, not absent** (RUN-B-030): this bite adds no `TabKey` **equality
comparison** and no `TabKey` **rendering**. `ieImplExistsForHeadGo` compares through
`headTabIs` (which is `dispHeadTab hk == goal`, the projection the bucket is filed under, and
the same comparison `implExistsForHeadGo` made) and `ieByHead`'s key has no interface component.

engines:      **All four arms consume the changed `Route`, and unlike `b2`/`c` this bite CHANGES
the stamped word — so "no engine source changed" is true and is not the whole answer.** No
engine source is touched (`grep -n 'bodyImplEnvRef\|ieHeadRows\|keyForSite' compiler/ir/core_ir_eval.mdk
compiler/backend/wasm_emit.mdk` is empty), but each re-derives this word independently and each
owes a different reading:
* **LLVM** (`llvm_emit.headTagUnique`/`distinctKeysAtHead`, `core_ir_lower.declRouteKey`/
  `ifaceDeclHeadUnique`) — **OWED AND PAID, as the instrument of every table above.** Its
  derivation was ALREADY graph-global; this bite makes the checker agree with it rather than
  teaching it a new word, which is why the fix shows up as *the right call site* rather than as a
  renamed symbol. Read directly off three `.ll` files (SA-4c, `c-imp`, `g-hd`/`g-hd2`).
* **eval** (`pickTagFallback`) — **OWED AND PAID on these programs.** The severity disagreement
  `c` measured (eval loud `E-PANIC: unknown op '+'` vs LLVM silent garbage at exit 0) is GONE:
  `run` and the built binary now agree, on the right answer, on every arm. ⚠️ eval was also the
  engine `f` silenced (it used to print `wrap-int-specific` correctly and then rejected); it
  prints it again.
* **`core_ir_eval`** (`cevalModules`, eval's parallel module driver) — **OWED AND NOT PAID.**
  I did not observe it. Its gate `diff_compiler_core_ir_modules.sh` shares
  `test/eval_modules_fixtures/*/` with `diff_compiler_eval_modules.sh` (the corpus that let the
  P0-9 fix ship "green" having run only the first), and **both** are on this branch's known-red
  list for the S-expr/`CProgram`-carrier reason, so a run of either would not have been
  informative about this diff. It is genuinely owed to the repair round.
* **wasm** (`wasm_emit`) — **OWED AND NEVER OBSERVED, in this bite or in `b2`/`c`/`f`.** It
  re-derives the same uniqueness test from a bare `String`. `test/wasm/diff_wasm*.sh` and
  `diff_compiler_tmc_parity.sh` need the wasm oracle; not built, not run. **This is the arm with
  the least evidence behind it and it should be named as such in any merge decision.**

gates run:    `diff_compiler_check_cli_modules.sh` **86 ok, 0 failing** (was 86/0 under `f`; two
legs re-cut, net row count unchanged) · `diff_compiler_must_fail.sh` **TWICE, 97/3/0/0 both
runs, same three names** · `diff_compiler_flat_vs_onemodule.sh` **13 rows PASS** (1 drain
notice) · `make check-self` **PASS** · `make agent-doc-symbols` **PASS** (0 dead — nothing was
deleted, so no symbol claim moved) · `make docs-links` **PASS** · `medaka fmt --check` clean and
`medaka lint` **0 findings** on the touched source, both **BEFORE** each build.
⚠️ The inherited `1112-A34/later-invisible` red that `.claude/HANDOFF.md` calls "pre-existing,
not ours" is **green**, as `f` also observed — that HANDOFF line is stale, and nothing here
could have fixed it (it failed by ACCEPTING).

**🚨 THE TWO RE-CUT `SA-4c` LEGS, AND WHY EACH WAS RE-CUT RATHER THAN LEFT TO GO RED.**
The gate's own FAIL text says *"the split CHANGED — re-cut"*, so this was licensed; what it
does not license is a weaker assertion, and neither replacement is weaker.
* `SA-4/overlap-still-rejects` → **`SA-4c/overlap-DRAINED-both-orders`**: from *"build must
  REFUSE"* to *"build must SUCCEED and the binary must print `wrap-int-specific` in BOTH import
  orders."* **Fail-capable against the whole history, not just against today**: it fails on
  `b2`'s state (binary 139) and on `f`'s (no binary at all).
* `SA-4/overlap-check-blind-to-route-word` → **`SA-4c/route-word-order-invariant`**, and the
  predecessor was **DELETED rather than kept because it had become VACUOUS**: it pinned
  `check 0` as a known-wrong state, and `check 0` is now the correct answer for a legal program,
  so it would have gone on passing while asserting nothing. An exit-code-graded row over a
  program that should check clean cannot discriminate — **grade the MECHANISM instead**. The
  replacement asserts (a) the two import orders' IR is byte-identical AND (b) the callee is the
  arity-1 specific impl. **Both halves are load-bearing and neither implies the other**: (a)
  alone passes if both orders are equally wrong; (b) alone passes on the accepting order while
  the other segfaults — which is exactly `b2`'s state.
* **FAIL-CAPABILITY MEASURED, not argued** (`scratchpad/g-failcap.sh`): the arity grep run
  against `b2`'s literal IR line (`@mdk_impl_Tag__Wrap_a___tagOf(i64 %t2)`) exits **1** (leg
  FAILS), against this bite's line exits **0**; the diff arm against a one-line-mutated arm
  exits **1** (leg FAILS). The no-IR arm is what catches `f`'s state.

**🔓 THE ANSWER `B-2.1-d` IS BLOCKED ON: `shadowKeyTableRef` IS NOW FULLY DEAD, AND
`universeKeyBucketsRef` WITH IT.** Derived, not assumed —
`grep -n 'shadowKeyTableRef\|universeKeyBucketsRef' compiler/types/typecheck.mdk | grep -vE '^[0-9]+:\s*--'`
returns **seven** lines and **not one is a read for a decision**: the two record fields, the two
`Ref omEmpty` initializers, the two `setRef perRun.value.shadowKeyTableRef …` writes in
`checkBodyImpl`, and `universeKeyBucketsRef`'s own read-modify-write accumulate in
`appendUniverseAccums`. `shadowKeyTableRef` has **ZERO** readers; `universeKeyBucketsRef`'s only
consuming read is the copy INTO that write-only ref. Outside this file the only mention is a
comment in `compiler/types/registry.mdk:682`. So `d`'s precondition is met.
🆕 **AND `d` INHERITS ONE MORE THING THIS BITE CREATED, WHICH ITS PACKET DOES NOT YET NAME: the
threaded `keyTable` PARAMETER NOW HAS ZERO TERMINAL READS.** Its only two terminal consumers were
`keyForSite` and `implExistsForHead`; both moved. The remaining ~25 `KeyBuckets` parameters
(`resolveSites`/`resolveSite`/`resolveArgStamps`/`resolveOpSites`/`stampOpRouteVal`/
`resolveRLocalSites`/`resolveRLocalSite`/`resolveDictApps`/`resolveMethodDicts`/`routeOf`/
`routeOfD`/`undeterminedRoute`/`routeUndeterminedTop`/`routesOfMonos(Top)(V)`/`topRouteV`/
`implDictRoutesForFull`/`argImplRequiresRoutes`/`argImplDictRoutesFor(Encl)`/`argImplReqRoutes`/
`argReqRoute`, plus the `KeyBuckets` field on all four `EntailKind` constructors) form a closed
cycle of pass-throughs. **Deliberately NOT removed here**: `lint` does not flag a dead parameter,
so there was no ratchet forcing it, and threading removal touches ~25 signatures + a data
constructor — a diff that would have buried the four-member repoint this bite is graded on.

unchecked:
* **`selfcompile_fixpoint.sh` NOT RUN — and THIS BITE CHANGES EMITTED IR, so it is the decisive
  gate and it is genuinely owed.** Brief-assigned to CI's `soundness` shard (which has been
  PASSING, hence a live trusted signal). **I looked specifically for the anomaly class I was told
  to STOP on and found none:** dict arity agrees at define, call site and dict global on the
  SA-4c IR (arity-1 callee for the arity-1 define, arity-2 for the arity-2, no mismatch anywhere);
  `make medaka` completed cleanly (stage A + stage B, one cycle, exit 0); `make check-self`
  passes. **That is evidence, not the gate — nobody has run the fixpoint on this diff.**
* **No seed re-mint attempted.** Emitted IR changes, so `refresh_seed.sh` may be owed — it is
  **not idempotent after a codegen change (run it TWICE)** and a stale seed can SEGFAULT the
  fixpoint on a correct change. Belongs with the fixpoint, in one place, once.
* **Snapshot and `selfproc_legA` goldens NOT re-cut, both owed** (§5: zero goldens blessed this
  run). `compiler/types/typecheck.mdk` is in the snapshot corpus. The legA diff must read as
  **+2 additions and exactly 1 re-signature** — derive, don't trust:
  `git diff -U0 compiler/types/typecheck.mdk | grep '^[+-][a-zA-Z]' | grep ' : '`. 🚨 On a rebase,
  take the base's version of BOTH families and **RE-DERIVE from the rebuilt binary**; a clean
  three-way auto-merge of a golden is not evidence it is right (three agents hit that on this
  exact file in one session). ⚠️ `diff_compiler_llvm_typed_ir` also moves, by design.
* **`diff_compiler_engines.sh`, `diff_compiler_perf_scaling.sh`, `typecheck_compiler_source.sh`,
  `diff_compiler_shadow_semantics.sh` (#1431: hardcodes `$ROOT/medaka`, so a differential needs a
  second worktree), `diff_compiler_eval_modules.sh` / `diff_compiler_core_ir_modules.sh`, corpus
  sweeps, the full suite: NOT RUN**, per the brief's reduced floor. `check-self` is a *weaker*
  authority than `typecheck_compiler_source.sh` (which also covers `compiler/entries/*.mdk`).
* **No breadth sweep for over-firing.** `f` ran all 39 `sqlite/*_demo.mdk`/`*_probe.mdk`
  programs because its diff was a reject-WIDENING and over-fire was its whole risk. This diff
  is a reject-NARROWING plus a WORD change, so the symmetric risk is a wrong word on a program
  that previously worked — and the instrument for that is the fixpoint and the IR goldens, not a
  check sweep. **I did not run the sweep, and I am naming the substitution rather than implying
  the risk is absent.**
* **The base columns in tables 1 and 3 are RELAYED, not re-measured.** `b2`'s and `f`'s cells
  come from their DEBT rows; `c`'s come from `c`'s row. Only the **this bite** column and
  `c-def`'s control were measured by me on a binary I built. I did not rebuild three historical
  binaries to re-derive them.
* **Reproduction, all outside the worktree:** `scratchpad/g-probe.sh <medaka> <root> <dir>
  <label>` (four verbs × two orders, keeps IR) over `g-sa4c/`, `g-hd/`, `g-hd2/`;
  `scratchpad/g-cprobe.sh <medaka> <root>` for `c`'s five-file corpus; `scratchpad/g-failcap.sh`
  for the new legs' fail-capability. Logs: `g-build1.log`, `g-ccm.log` (pre-re-cut, 85/1),
  `g-ccm2.log` (86/0), `g-mf1.log`, `g-mf2.log`, `g-fvo.log`, `g-cs.log`.

### `B-2.1-d` (EX-1) — Phase 2′ — **THE ARGUED SWEEP: both write-only refs + the ENTIRE prefix-table READ SIDE (13 bindings) + all 13 dead-code suppressions. Pure deletion: 13 signatures removed, ZERO added, ZERO re-signed. IR PROVEN UNMOVED on an IR golden gate.**

🔗 **Ledger cross-reference: `DECISIONS.md` RUN-B-0xx** (the orchestrator composes it). Consumes
`B-2.1-g`'s ⛔ finding (the guard is not separable from its dependencies) and cashes
`TYPECHECK-TARGET-ARCHITECTURE.md`'s *"DEFERRED → B-2, by DELETION"* row — **partly**; see
`could move:` item 5 for what that row still owes.

sites:        `git diff --numstat` — **414/669 `compiler/types/typecheck.mdk`, 0/1
`test/registry_keying_ratchet.sh`, 9/5 `docs/spec/SHADOW-SEMANTICS.md`, 2/2
`compiler/DIAGNOSTIC-CODES-DESIGN.md`, 1/1 `compiler/TYPECHECK-TARGET-ARCHITECTURE.md`.** Five
files. **Signature delta is 13 lines and every one is a `-`** — derive, don't trust:
`git diff -U0 -- compiler/types/typecheck.mdk | grep '^[+-][a-zA-Z]' | grep ' : '`. So
`selfproc_legA` must read **SUBTRACTIVE-ONLY**: those 13 bindings leave and **no surviving
binding's inferred type may move**; if one did, the deletion changed types and that is a finding.
Net −255 lines, of which the code is a small minority — the bulk is prose (see `transform:` §3).

transform:    **THREE things deleted, and only the first was in the packet.**
1. **The two write-only refs.** `universeKeyBucketsRef` (`CrossRun` field + `freshCrossRun`
   initialiser + `appendUniverseAccums`' read-modify-write accumulate) and `shadowKeyTableRef`
   (`PerRun` field + `freshPerRun` initialiser + both `setRef` arms of `checkBodyImpl`'s
   `match mode`). Verified ZERO code readers before deleting, per packet §5.
2. **The 13 dead bindings `g` was forced to retain**, with all 13 `-- lint-disable-next-line
   rule-dead-code` suppressions: `implExistsForHead(Go)`, `bucketOfHead`, `matchedEntry`,
   `matchingEntries(Go)`, `candidateBucket`, `headCollides`, `countHead(Go)`, and `f`'s guard
   trio `routeWordHeadSkew` / `reportRouteWordSkew` / `routeWordAmbiguousMsg`.
   **PROVEN DEAD PER SYMBOL, not inherited from either list** (the brief required this because
   `g` moved the picture). Method: for each of the 13, every tree-wide word-bounded code hit is
   the def, its own signature, self-recursion, or a call **from another member of the 13** —
   i.e. the set is a CLOSED subgraph with exactly **three zero-caller roots**
   (`implExistsForHead`, `matchedEntry`, `reportRouteWordSkew`). Re-derive:
   `for s in <the 13>; do git grep -nw "$s" -- '*.mdk' | grep -v ':[[:space:]]*--'; done`
3. **ZERO second-order cascade, checked rather than assumed.** Every callee of the 13 keeps an
   out-of-set caller: `pickMostSpecificEntry`/`mergeByDeclIdx` (the two `IE` selectors),
   `entryHeadMatches` (`ieRowHeadMatches`), `headTabOf`/`headTabEq` (the `IE` counters),
   `headBucketRender` (`bucketKeyEntriesFrom`), `bucketOf` (4 sites), `goalHeadCon` (both `IE`
   selectors), `findMostSpecificEntry`, `ppPredArgsShared`, `pushTypeErrorOnceAt`, `dispHeadTab`.
   **Nothing on the anti-scope list was deleted** — `buildKeyTable`, `bucketKeyEntries(From)`,
   `keyEntryOf`, `KeyEntry`, `KeyBuckets`, `keyForSite*`, `mergeByDeclIdx`, `matchedEntry`'s
   `IE` peers all stand. `buildKeyTable` keeps 2 of its 3 callers; `bucketKeyEntries` is now its
   SOLE callee-caller pair.

🚨 **WHY EACH DELETED GUARD'S CLASS IS COVERED — the argument the brief demanded, not an
assertion.** Only ONE of the 13 was a reject-bearing guard: `reportRouteWordSkew`, pushing
`T-ROUTE-WORD-AMBIGUOUS`. Its class was *"the prefix says this head is unique so a BARE route
word is stamped, while the whole graph says that word names ≥2 impls defining the method"* — the
`SA-4c` 139 miscompile. **That class is now handled CORRECTLY rather than rejected:** `B-2.1-g`
repointed `keyForSite` onto the graph-global `bodyImplEnvRef`, so selection and the collision
retest read ONE population and the two counts the guard compared **are one count** — the skew is
not merely unreported, it is unconstructible. Evidence it is handled and not hidden:
`diff_compiler_check_cli_modules.sh`'s `SA-4c/route-word-order-invariant` leg passes, asserting
both import orders' IR is byte-identical AND the callee is the arity-1 specific impl. The other
12 bindings pushed no diagnostic at all (pure lookups/counters/selectors), so there is no
reject-coverage question for them. **No deleted symbol's class is unhandled ⇒ nothing was held
back, and I found nothing that required me to STOP.**
⚠️ **`#1578`: confirmed a NON-cost, first-hand.** `g` disproved the brief's attribution and I did
not take that on trust — `1578-*` reports **REPRO on both must-fail runs of my final binary**,
i.e. its behaviour is identical with the guard deleted. It belongs to `T-REQUIRES-UNROUTED`'s row.

**Prose: 8 knowledge blocks RELOCATED, not deleted — and this is where the packet was most
incomplete.** The packet named 3 stale comments + 2 dangling cross-refs + 5 present-tense sites;
the real figure is **~50 comment references to the 13 symbols**, because `g` added 7 stale blocks
and 13 dead-notes of its own AND because two high-value derivations *lived on functions this bite
deletes* while LIVE symbols cited them as their home. Relocated (each to the live symbol its
citers already point through):
* the **#1111 spelling-keyed-retest derivation** (why a structural `HeadKey` compare re-opens an
  S0) — was on `implExistsForHeadGo` → now on **`headTabIs`**, the primitive every surviving
  retest shares. Three live citers repointed (`headTabEq`, `headTabOf`, `ieImplExistsForHeadGo`),
  plus `dispHeadTab`'s T1 ledger and the `monoHeadCon` obituary's *"thirty lines from here"*
  locator, which had become a dangling pointer into deleted text.
* the **#1317 three-build measurement** (identity-vs-spelling counting, `(1,2)`→`(1,1)`) — was on
  `countHead` → now on **`ieCountHeadByIface`**, with its 3 live citers repointed.
* the **declaration-index / ORDER tie-break argument** and the **`mergeByDeclIdx` precondition**
  — merged onto `mergeByDeclIdx`, which now ENUMERATES its callers (see `could move:` item 1).
* the **`noneHeadTag` headless-self-merge unrepresentability derivation** — was on
  `candidateBucket` → now on **`headBucketKey`**, inverting the old *"see there"* pointer.
* the **F-3c/T4 non-closed-goal list-order residual** (packet §4b said explicitly not to lose
  this) — was inside `candidateBucket`'s comment → now on **`pickMostSpecificEntry`**, the
  function it is actually about.
* the **`keyForSite`-is-elaborate-only / invisible-to-`check` derivation** — was framed as "the
  verb split THIS GUARD leaves behind" → now on **`keyForSite`** itself, restated as what it
  actually is: nothing is pushed from there today, so nothing is hidden today, but the split is
  STRUCTURAL and a future diagnostic added there would be silently invisible to `check`.
* `checkBodyImpl`'s writer site and `appendUniverseAccums`' header rewritten from "this seeding
  is write-only, `d` will retire it" into **do-not-re-add warnings** naming the S0 mechanism.
* `f`'s ~215-line guard block collapsed to a compact **HISTORY** block above
  `ieCountHeadByMethod`, keeping the `SA-4c` IR evidence, the one-direction asymmetry, the
  corrected #1578 attribution, and the DICT §11 *"do not re-derive this count in the obligation
  channel"* warning.

could move:   **Nothing at the language level, and that is measured, not assumed for a "pure
deletion".** No `.mdk` code line outside the 13 dead bindings and the 6 ref sites changed; the
compiler cannot behave differently because nothing reachable was touched. Proof rather than
argument: **`diff_compiler_llvm_modules` PASSES on the final binary** — an IR golden gate whose
corpus includes `test/llvm_fixtures_modules/module_local_route_word/`, the fixture
*constructed* to be `f`'s guard's firing condition. **Byte-identical emitted IR on the one gate
that would see a change ⇒ the deletion moved no IR and no dict arity.** I looked for the anomaly
class the brief said to STOP on and found none.

**1. The one real change, and it is a STRENGTHENING of a precondition, not a behaviour move.**
`mergeByDeclIdx`'s ascending-index precondition now holds tree-wide **structurally**. ⚠️ The
brief and packet both framed this as *"`buildKeyTable` becomes `bucketKeyEntries`' sole caller"*.
That is true but it is no longer the operative reason, and the stronger statement is the honest
one: because `candidateBucket` is ALSO dead, **no `KeyBuckets` value reaches `mergeByDeclIdx` at
all any more.** Its only two callers are `ieCandidatesForIface`/`ieCandidatesForMethod` over
`ieHeadRows`, indexed by `instRefSeq` — a whole-graph counter appended in build order, ascending
by construction. The table that violated the precondition is gone AND the union that fed it is
gone. Both facts are recorded on `mergeByDeclIdx` with the enumerated callers.

**2. The ratchet moved and BOTH SIDES were derived, never quoted.** `test/registry_keying_ratchet.sh`
check 1 is a set equality with no hardcoded count. Deleting the `CrossRun` field without deleting
allowlist line 175 (or vice versa) fails with a set diff. Both deleted; gate **PASS**. The
`CrossRun` field count, via the script's own `sed` extraction, is now **22** (was 23).
⚠️ **I got this wrong twice before getting it right, and the failure mode is worth recording:**
my hand-rolled re-derivation of the *expected* side returned **22** and then **68** while the gate
was green at 23 — because `cross_allowed`'s first row shares the assignment line (`:173`), so any
filter that drops that line silently undercounts. I stopped hand-rolling and used the gate's own
set equality as the oracle. This is the fifth wrong count in this arc and the first one caught
inside the bite that produced it.

**3. `test/typecheck_compiler_source.sh` delta is EMPTY — verified, not trusted.** None of the
13 deleted signature lines nor the 6 ref lines contains `OriginUnresolved`, so the text-keyed
`tc_originun_allowed` list is untouched. Derive: `git diff -U0 | grep '^-' | grep -c OriginUnresolved`
→ 0. *(I did not RUN that gate — it needs slow oracles and is CI's per the reduced floor.)*

**4. `make agent-doc-symbols` moved and is green with NO exceptions row added.** The four
`docs/spec/SHADOW-SEMANTICS.md` cells were rewritten to name the live successor
(`ieImplExistsForHead` over `bodyImplEnvRef`); three are dated historical UPDATE notes, so the
dead name is kept as **unbacktick'd** prose to preserve the history without a live-symbol claim.
⚠️ **My first rewrite RE-INTRODUCED the dead backtick inside its own replacement text and reddened
the gate** (`:1742`, `dead: 1`) — caught by running the gate rather than by reading my own diff,
which is exactly why the floor has that gate in it.

**5. 🚨 A CORRECTION I OWE THE LEDGER, found while sweeping prose: the Door 4 / Door 4b blocks
and `DIAGNOSTIC-CODES-DESIGN.md`'s `T-REQUIRES-UNROUTED` row describe a two-registry split that
`b2` ALREADY CLOSED on the leg they name.** All three said the cause is *"the evidence reader
`concreteReqMatchByIface` consults `shadowKeyTableRef`, copied from the CUMULATIVE
`universeKeyBucketsRef`"*. Derived on the tree: `concreteReqMatchByIface` reads
`perRun.bodyImplEnvRef` (graph-global) since `b2`. **The split is NARROWER, not closed** — the
surviving prefix read is `findMatchingImplReqsU`'s HEADLESS fallback,
`firstReqMatch (univHeadless univ iface)` over `residualUnivRef`, a per-module ordinal
projection. This is exactly `b2`'s Item 3 residual that `g` re-confirmed untouched. I corrected
all three to state the surviving mechanism and explicitly wrote *"do NOT read this narrowing as
(b) is fixed — this arm must still reject"*. ⛔ **I changed no behaviour here and did not touch
the guard.** But it means the architecture doc's deferral row and that diagnostic row were BOTH
stale in the direction that makes a live residual look closed, and **whether Door 4's guard now
over-fires on the concrete leg is an open question for the repair round, not something I could
settle inside a deletion bite.**

**6. `keyTable` threading — IN SCOPE, DECIDED, DEFERRED, and the reason is not "too big".**
`g` flagged that the threaded `keyTable` parameter now has zero terminal reads (~25 signatures +
the `KeyBuckets` field on all four `EntailKind` constructors). **I derived where removing it
leads and it exits my bite's licence:** `buildKeyTable`'s two surviving call sites
(`let keyTable = buildKeyTable prog2`, `let stampKeyTable = buildKeyTable implDecls`) exist ONLY
to feed that threading, so removing the parameter makes `buildKeyTable` dead, which cascades to
`bucketKeyEntries(From)`, `keyEntryOf`, `headBucketRender`, `KeyEntry` and `KeyBuckets` — **six
symbols the anti-scope list names as MUST-SURVIVE, and which AM-1 scopes to #1113.** So taking it
would not be an enlargement of this bite, it would be a violation of it. Deferred, recorded in
the architecture doc's row as *"the table is still BUILT and still threaded but has zero terminal
reads"* so the next agent inherits the finding rather than re-deriving it.

nearest miss: **A reader introduced between the packet's derivation (`1e7cbbbb`) and my deletion.
RE-RAN packet §5's greps against `26423f93` immediately before touching anything, and diffed
against the packet's stated baseline. The sets DIFFER from the packet — and they differ in the
SAFE direction, which is the only reason I proceeded rather than stopping.**
* Packet §5 probe (1) expected 2 code readers at the pin and ZERO after `c`; measured **ZERO**.
* Packet §5 probe (2) expected 9 code lines at the pin, 7 after `c`; measured **7**, at the
  post-`g` line numbers `6185 / 6307 / 7032 / 7128 / 21308 / 21309 / 26783` — the 2 decls, the 2
  initialisers, the 2 `setRef` writes and the accumulate. **Not one is a read for a decision.**
* Packet §5 probe (3) expected prose-only outside `typecheck.mdk`; measured exactly one hit,
  `compiler/types/registry.mdk:682`, past-tense and still true (left alone).
* Packet §5 probe (5) expected `implExistsForHead` to keep ONE caller via the threaded table.
  **MEASURED ZERO — this is the packet's biggest miss and it ENLARGED the bite.** `g` moved
  `resolveRLocalSite`'s leg too, so `implExistsForHead` has no callers and is itself one of the
  13 dead. The packet's anti-scope table lists it as surviving; it does not.
* **What I could NOT rule out, stated as a limit rather than a clearance:** a reader added to a
  file I did not re-grep between my grep and my edit. I hold the only writer slot and
  `git status` showed a clean tree throughout, so this is bounded by that assumption, not by a
  measurement.

engines:      **ONE LINE, and the reason rather than the word: no compiled byte reaches any
engine, because nothing reachable was deleted.** All 13 bindings had zero live callers before
deletion (proven per symbol above) and the two refs were write-only, so no engine's input
changed — LLVM · wasm · eval · `core_ir_eval` all re-derive their words from the same `Route`
values they received at `26423f93`. **Corroborated, not merely argued:** `diff_compiler_llvm_modules`
PASSES on the final binary, so the LLVM arm's emitted IR is byte-identical on the corpus that
contains the fixture built to exercise the deleted guard's condition.
⚠️ **wasm: OWED AND STILL NEVER OBSERVED — five bites running** (`b2`/`c`/`f`/`g`/`d`). Stating
it loudly as instructed: **my deletion touches nothing wasm consumes** — `grep -n
'routeWordHeadSkew\|headCollides\|countHead\|matchedEntry\|candidateBucket\|implExistsForHead\|shadowKeyTableRef\|universeKeyBucketsRef'
compiler/backend/wasm_emit.mdk compiler/ir/core_ir_eval.mdk` is **empty**, and `wasm_emit`
re-derives its uniqueness test from a bare `String` it receives, not from any table I removed. So
the wasm arm's exposure to THIS bite is nil; its exposure to `g`'s word change is unchanged and
still unmeasured. `core_ir_eval` likewise untouched and likewise unobserved.

gates run:    All on the FINAL binary (`make medaka` exit 0, `MEDAKA_STRICT=1` fresh), `fmt
--write` and `lint` BEFORE each of the two builds:
`medaka fmt --check` **clean** · `medaka lint compiler stdlib sqlite` **0 findings** ·
`make check-self` **PASS** · `sh test/registry_keying_ratchet.sh` **PASS** (set equality held
across the moved row; CrossRun 22) · `sh test/diff_compiler_check_cli_modules.sh` **86 ok, 0
failing** (derived off the log, not quoted — the brief warned this number moved twice) ·
`sh test/diff_compiler_flat_vs_onemodule.sh` **13 rows PASS, 1 drain notice** ·
`sh test/run_gates.sh 'diff_compiler_llvm_modules*'` **PASS** ·
`sh test/diff_compiler_must_fail.sh` **TWICE: 97 REPRO / 3 DRAINED / 0 control-broke / 0
malformed, identical, same three NAMES read individually — #1072, #1564, #1599** ·
`make agent-doc-symbols` **PASS, 0 dead, no exceptions row added** · `make docs-links` **PASS**.
Must-stay-put pins held: **`1597-*` REPRO, `1046-*` REPRO.**
⚠️ **`test/must_fail_fixtures/1075-*` DOES NOT EXIST** — the brief's must-stay-put list names a
`#1075` pin, and `ls test/must_fail_fixtures/ | grep 1075` is empty. Nothing flipped because
there is nothing there; the list item is misnamed or the pin was never created.
⚠️ `diff_compiler_llvm_modules` **phantom-skipped on first invocation** (no
`llvm_emit_modules_main` oracle in this worktree) and **refused with exit 1 on a later one**
because my second `make medaka` staled the oracle. Both are the harness working, not results:
built the oracle narrowly (`FORCE=1 JOBS=1 … --build-one llvm_emit_modules_main`) and re-ran to a
real PASS each time. **A phantom skip is not a pass and I did not record one as such.**

**🚨 ORCHESTRATOR FOLLOW-UPS (relayed mid-flight, both answered on my binary, both CLEARED):**
* **#1599 is a GENUINE DRAIN, not a build refusal.** `check` **0** (`main : Unit`), `check --json`
  **0** with `"diagnostics":[]` and **zero** `T-ROUTE-WORD-AMBIGUOUS`, `build` **0** (redirected
  to a file, never piped), **built binary exit 0 printing `5`** — and `5` is the answer the
  fixture's OWN `claim.txt` names as correct (*"THE CORRECT ANSWER IS 5 — `spec`'s `impl Show2
  (Box T)` body"*), against the pinned-wrong `1003`. The reviewer was RIGHT on the fact:
  `impl Show2 (Box …)` is declared in **both** `gen.mdk` and `spec.mdk`, so `f`'s *"one impl at
  the head"* safety claim was false. It is moot — the guard is deleted and the program is now
  correct rather than refused. **No headline drain unwinds.**
* **#1564's two orders AGREE.** `main.mdk` (the previously false-rejecting order) and
  `control.mdk` both: `check` **0**, `build` **0**, binary **0** printing **`wrap(int)`**. No
  `T-ROUTE-WORD-AMBIGUOUS` in either stream. Genuine drain.
* **`diff_compiler_llvm_modules` GREEN** ⇒ `g`'s retirement covered
  `test/llvm_fixtures_modules/module_local_route_word/`. Nothing to escalate.

unchecked:
* **`selfcompile_fixpoint.sh` NOT RUN, and NOT owed by this bite the way it was owed by `g`.**
  Per the reduced floor it is CI's `soundness` shard and EX-2's exit criterion. My positive
  evidence that it should be a no-op is `diff_compiler_llvm_modules` PASS (byte-identical IR) —
  **that is evidence, not the gate**; nobody has run the fixpoint on this diff.
* **No seed re-mint attempted** — EX-2's, and on a no-IR-change deletion it should be a no-op.
* **Snapshot and `selfproc_legA` goldens NOT re-cut — EX-3's, deliberately.** `zero goldens
  blessed` is intact: `git status` shows five modified files and **no golden**. My contribution to
  the legA diff is **13 deletions, zero additions, zero re-signatures** (command in `sites:`).
  `test/snapshots/compiler/typecheck.md` also moves (−255 lines of source).
* **`typecheck_compiler_source.sh`, `diff_compiler_engines.sh`, `perf_scaling`,
  `shadow_semantics` (#1431), `eval_modules` / `core_ir_modules`, corpus sweeps, full suite: NOT
  RUN**, per the reduced floor. `check-self` is a weaker authority than
  `typecheck_compiler_source.sh` (which also covers `compiler/entries/*.mdk`).
* **PERF: not measured, and a deletion is not automatically neutral to it.** Removing dead code
  cannot slow the checker, but `appendUniverseAccums` no longer does a per-module
  `bucketKeyEntries` fold over every decl, which should be a small WIN on multi-module compiles.
  `check-self` PASSes; I did not time it, and a wall-clock A/B on a shared box with siblings live
  is not a measurement. **Genuinely unanswered**; `perf_scaling` (allocation-graded) is CI's.
* **The ~50 comment references were triaged, not exhaustively rewritten.** I fixed every
  present-tense claim about a deleted symbol and every dangling *"see X"* locator I could find;
  I deliberately LEFT past-tense historical mentions (e.g. lines 215/235's A-2.2b narrative,
  `dispHeadTab`'s obituaries) because they are honest history and deleting them destroys the
  record. **A reader should expect deleted names to appear in this file as history.** Derive the
  set: `grep -nE '\`(implExistsForHead|matchedEntry|matchingEntries|candidateBucket|bucketOfHead|headCollides|countHead|routeWord\w+)\`' compiler/types/typecheck.mdk`
* **Reproduction:** `scratchpad/refs.sh` (per-symbol death proof for the 13), `refs2.sh`
  (second-order cascade), `p1599.sh` / `p1564.sh` (the two orchestrator follow-ups),
  `final.sh` / `mf.sh` (the floor). Logs: `build.log`, `build2.log`, `f.*`, `fmf1.log`,
  `fmf2.log`, `llvm3.log`, `ratchet-before.log`.

---

### `EX-2` — Phase 2′ (sprint exit) — **the checkpoint seed re-mint (×2) and the IN-BAND fixpoint. C3a+C3b GREEN both BEFORE and AFTER the re-mint; the second pass was byte-identical — non-idempotence NOT reproduced on this diff, measured. One tracked file changed: the seed.**

🔗 **Ledger cross-reference: `DECISIONS.md` RUN-B-0xx** (the orchestrator composes it). Discharges
§8's exit criterion *"the self-compile fixpoint is green on a twice-refreshed seed"* and consumes
`B-2.1-d` (EX-1)'s `unchecked:` first bullet (*"nobody has run the fixpoint on this diff"* — now
somebody has, twice, and it is green).

sites:        **ONE tracked file: `compiler/seed/emitter.ll.gz`** (`git status --porcelain` →
`M compiler/seed/emitter.ll.gz`, plus untracked `scratchpad/`). **Zero `.mdk`, zero goldens, zero
gates, zero docs.** Two *untracked-by-git* build artifacts also moved as a side effect of
`refresh_seed.sh` step 1: `./medaka_emitter` (rebuilt from current source, `FORCE_EMITTER_REBUILD=1`)
and `.medaka_emitter.srcstamp` (unchanged value `4e6908b8…` — same source, so same stamp). `./medaka`
was NOT rebuilt and needed no rebuild: no compiler source changed, and `MEDAKA_STRICT=1 ./medaka run`
on a hello probe exits **0** with no staleness warning, before and after.

transform:    Four steps, in this order, each timed on a quiet box (`uptime` load **0.15** at start
— stated because a wall-clock number from a loaded box is not a measurement):
1. **Fixpoint BEFORE touching the seed** (`sh test/selfcompile_fixpoint.sh`, redirected to a file,
   `$?` read — never piped): **exit 0, `C3a YES` / `C3b YES`, 38 s** (`scratchpad/fixpoint-pre.log`).
2. **`sh test/refresh_seed.sh` — pass 1: exit 0, 85 s.** Seed gz `1359573 → 1679648` bytes, raw IR
   `11880260 → 14552244` bytes, `355600 → 437276` lines.
3. **`sh test/refresh_seed.sh` — pass 2: exit 0, 89 s.** **Raw IR byte-IDENTICAL to pass 1**
   (`md5 d08eb4bba108c4c894b457d28b83ba8b` both passes; `cmp -s` silent). See `could move:` item 2
   for the `.gz` byte difference, which is NOT an IR difference.
4. **Strict byte-currency + fixpoint AFTER**: `SEED_STRICT=1 sh test/bootstrap_from_seed.sh
   scratchpad/emitter_from_seed strict` → **exit 0, 30 s, `C3a PASS: seed == native re-emission from
   current sources, byte-for-byte`** (an explicit `$OUT` was passed so the strict bootstrap did not
   overwrite the tree's `./medaka_emitter` with a seed-built one); then
   `sh test/selfcompile_fixpoint.sh` → **exit 0, `C3a YES` / `C3b YES`, 39 s**
   (`scratchpad/fixpoint-post.log`).

**THE RE-MINT DECISION, ARGUED — and the brief's discriminator is only half right.**
🚨 **There are TWO different C3a checks in this tree and they answer different questions.** Conflating
them is what makes "the fixpoint is green, so the seed is current" a false inference:
* **`selfcompile_fixpoint.sh`'s C3a** = `IR1 == REF`, where `REF` is the seed-bootstrapped
  emitter's *re-emission* of the gap-tolerant driver. Its own SEMANTIC NOTE (`:26-35`) says the seed
  is *expected* to lag by exactly one generation and that one turn of the crank converges. So this
  C3a is a **one-crank convergence** test that a lagging seed **passes by design** — which is exactly
  what happened: it was **GREEN before the re-mint on a seed minted 2026-07-19, 1341 commits back.**
* **`bootstrap_from_seed.sh`'s C3a** = `cmp seed.ll emitter2.ll` — the **byte-currency** test. That
  is the one a stale seed fails, and at `26423f93` **CI reported it failing**: `C3a WARN: committed
  seed differs from native re-emission (lagging seed)` (`seed-health`, job `94370157028`, log line
  209; also the `soundness` shard's cold-bootstrap step, job `94370157051`, log line 296).
  Reproduced locally: strict mode over the OLD seed is what the re-mint fixed.
⚠️ **Corollary that corrects the brief's ⭐ note:** *"CI has been running this on every push and it
PASSED"* is true only of **C3b**. `ci.yml`'s soundness step asserts `C3b PASS` and **explicitly
demotes C3a to a `::warning::`** (`.github/workflows/ci.yml:1282-1316`, *"C3b errors, C3a warns"*),
so a green `soundness` never claimed the seed was current — and in fact it was not.
**So was a re-mint NEEDED?** Under the SEED POLICY (`test/bootstrap_from_seed.sh:46-72`) — **no**,
not for correctness: only property (a) *"the seed WORKS"* is required, (b) byte-currency is a drift
detector, and `seed-health` was **green** at `26423f93` (`BOOTSTRAP-FROM-SEED PASS`). Under §8 — **yes**,
because §8 makes a twice-refreshed seed the exit criterion, and the policy's own carve-out is that
byte-currency *"is checked EXPLICITLY at checkpoints (`make bootstrap`) and re-minted then"*. **A sprint
exit is that checkpoint.** I did it for that reason and not because anything was broken.
**What the green pre-re-mint C3a does and does not prove:** it proves current source converges in one
crank from the committed seed and that the emitter reproduces itself. It does **not** prove the seed
was current (it was not), and it does **not** attribute the drift to this sprint — **the drift is
overwhelmingly pre-sprint**: the seed dates to 0917e97f (2026-07-19) and
`git diff --shortstat 0917e97f..HEAD -- compiler stdlib runtime` reads **109 files, +48715/−7337**,
against this branch's **+1296/−523 in one file**. The +23% seed growth is 1341 commits of accumulated
drift, **not** a measurement of `a3`/`b2`/`f`/`g`'s IR effect. Do not read it as one.

**Non-idempotence: NOT reproduced, and that is consistent rather than surprising.** The
`benchmark-emitter` rule (pass 1 mints with the old-generation emitter, pass 2 with an emitter built
from the new seed, so pass 1 can leave `C3a: NO`) is conditioned on a **codegen change**. This branch
has **none**: `git diff --name-only 2b9dc798..HEAD -- compiler/backend` is **EMPTY** (the only
non-`typecheck.mdk` compiler source touched is `compiler/ir/core_ir_lower.mdk`, 9/3, and
`compiler/types/registry.mdk`, 5/2). With codegen fixed, the mint is a pure function of source, so
pass 2 reproducing pass 1 byte-for-byte is the expected outcome — **and running it twice is still the
right move, because the prediction is only sound if the "no backend diff" premise holds, and the
second pass is what tests the premise rather than trusting it.** Measured, not asserted: identical
raw md5 across passes.

could move:   **Nothing in the language, in any engine, or in any golden — the diff contains no
executable byte the compiler reads.** The seed is *input to the cold bootstrap only*; every
`./medaka`/`medaka_emitter` in the tree was built from source and does not read it (`AGENTS.md`'s
borrow paragraph and `test/build_native_medaka.sh` cold/warm split). Concretely:

**1. What a re-mint changes, and what it cannot.** It changes the bytes a *cold* clone starts from
— i.e. which generation of the compiler compiles the first-generation compiler. It cannot change what
a warm build produces, because stage A/B rebuild the emitter from source either way. ⭐ **The emitted
IR carries no target triple** (`AGENTS.md`), so the new seed cold-bootstraps on x86 **or** arm from
these same bytes; the re-mint does not narrow the platform set. What it *does* buy on the cold path
is the removal of one generation of lag — the strict `C3a PASS` above is that statement.

**2. ⚠️ A NEW FINDING worth the ledger: `refresh_seed.sh` produces a DIFFERENT `.gz` blob on every
run even when the IR is byte-identical — so "the seed file changed" is NOT evidence that emission
changed.** Measured here: pass 1 gz `md5 7dab13ef…`, pass 2 gz `md5 8556110e…`, **same 1679648-byte
length, identical decompressed IR.** Mechanism derived, not assumed (`scratchpad/ex2-gzprobe.sh`):
`gzip -9 -c <file>` stores the input file's **MTIME** in the header — the probe compresses one
unchanged file at two mtimes and gets different bytes differing at **byte 6**, inside the 4-byte
MTIME field, with `FLG=0x08`. Two consequences: (i) every re-mint costs a fresh ~1.7 MB blob in git
history *regardless of whether anything moved*, which sharpens the SEED POLICY's own 86 MB / 41-re-mint
complaint; (ii) no gate is fooled, because both C3a checks compare the **decompressed** IR, never the
`.gz`. A future reviewer diffing the `.gz` will see a change that may mean nothing.

**3. The seed is also a FIXTURE for three other gates — enumerated, not assumed.**
`grep -rn 'seed/emitter.ll.gz'` names `gzip/test/inflate_oracle.sh:357-361`,
`gzip/test/deflate_oracle.sh:228-233` and `test/wasm/diff_gzip.sh:238`, which use it as *"the
self-referential, real-world corpus"*. **Their assertion is content-independent**: the expected
plaintext is obtained from the **system `gunzip`** of the very same bytes (`inflate_oracle.sh:176-181`
says so explicitly — *"never against a golden captured from our own code"*), so a re-minted corpus
changes the input and not the property. ⚠️ **NOT RUN** (see `unchecked:`) — the argument is from the
gates' construction, and a bigger corpus is a longer run, not a different verdict. `test/preflight.sh`
mentions the path only in comments; `test/selfcompile_build_fixpoint.sh` and
`test/diff_compiler_source_bytes.sh` consume it the same way the fixpoint does.

**4. The one behavioural surface that DOES move: `make bootstrap`/`seed-health` flip from WARN to
PASS**, and CI's cache key hashes `compiler/**`, so **this re-mint busts the medaka-binary and oracle
caches once** (`ci.yml:54-56` predicts exactly this: *"a seed re-mint busts the cache once"*). Expect
a slower first CI run on the pushed commit; that is designed, not a regression.

nearest miss: **A green fixpoint on a twice-refreshed seed proves SELF-CONSISTENCY and CONVERGENCE.
It cannot see a UNIFORM change — and this sprint's whole subject matter is uniform.** C3b is
`IR1 == IR2`: it asks whether the compiler reproduces *its own* output, so any change that moves the
emitted IR of **every** program in the same way (a dispatch route the whole graph now agrees on, a
dict arity uniformly re-shaped, a selection rule that picks a different-but-consistent impl
everywhere) is reproduced identically at every generation and **passes**. C3a after a re-mint is
weaker still: the reference is derived *from the seed I just minted with this same binary*, so it
compares the compiler against itself. **A wrong-but-self-consistent compiler passes both.** That is
precisely why `B-2.1-b2`/`f`/`g` needed a hand-built dict-arity/IR probe (`scratchpad/sa4c/probe.sh`,
`medaka build --keep-ir`) rather than the fixpoint: the fixpoint would have been green on the S0.
The nearest concrete programs it misses:
* **`SA-4c`'s two import orders** — the fixpoint compiles ONE module graph in ONE order, so an
  order-dependent route is invisible to it; `diff_compiler_check_cli_modules.sh`'s
  `route-word-order-invariant` leg is the check that sees it, and it is EX-4's to re-run.
* **Any program the emitter graph does not contain.** The corpus here is exactly
  `compiler/entries/llvm_bootstrap_lex_main.mdk`'s closure — no `deriving`-heavy user code, no
  graded-interface shapes, no `#1514`/`#1397`/`#1599` fixtures. A miscompile confined to a construct
  the compiler does not use itself is *structurally* outside this gate.
* **Diagnostics.** The gate compares emitted IR of a program that compiles clean; a
  diagnostic-only regression (an over-fire, an under-fire, a message change) leaves IR untouched.
  Value goldens cannot see it either — that is this run's standing blindness, restated because a
  green fixpoint is the most tempting thing in the sprint to over-read.

engines:      **ONE LINE, with the reason rather than the word: no engine's input changed, because
no `.mdk` and no `runtime/` byte changed** — the diff is one gzipped IR blob that only the *cold
bootstrap* reads, and the fixpoint's own C3b confirms the LLVM arm re-emits byte-identically at three
successive generations. LLVM: **positively observed** (C3a+C3b byte-identical, twice — pre- and
post-re-mint). eval · `core_ir_eval` · wasm: untouched by construction; none of them reads
`compiler/seed/emitter.ll.gz` (`grep -n 'seed' compiler/backend/wasm_emit.mdk
compiler/ir/core_ir_eval.mdk compiler/eval/eval.mdk` is empty).
⚠️ **wasm: STILL OWED AND STILL NEVER OBSERVED — six bites running** (`b2`/`c`/`f`/`g`/`d`/`EX-2`).
Stating it loudly as instructed: **this bite reaches nothing wasm consumes** (the wasm seed/bootstrap
path is `test/wasm/build_wasm_oracle.sh`, which builds from source, not from this seed), so its
exposure to EX-2 is nil — **but its exposure to `g`'s route-word change is unchanged and remains
unmeasured, and a green LLVM fixpoint is not evidence about the WasmGC backend.** The one gate that
would compare them (`diff_compiler_tmc_parity.sh`, `diff_compiler_engines.sh`) has not run this run.

gates run:    `sh test/selfcompile_fixpoint.sh` **exit 0 — `C3a YES` / `C3b YES`, BEFORE the
re-mint (38 s)** · `sh test/refresh_seed.sh` **×2, exit 0 each (85 s, 89 s)**, raw IR byte-identical
between passes · `SEED_STRICT=1 sh test/bootstrap_from_seed.sh <out> strict` **exit 0 — `C3a PASS`
byte-current, `BOOTSTRAP-FROM-SEED PASS` (30 s)** · `sh test/selfcompile_fixpoint.sh` **exit 0 —
`C3a YES` / `C3b YES`, AFTER the re-mint (39 s)** · `MEDAKA_STRICT=1 ./medaka run <probe>` **exit 0,
no staleness warning** (before and after). Every invocation redirected to a file with `$?` read
separately — **nothing piped**, per the `build`/`fixpoint`-exit-code-does-not-survive-a-pipe trap.
**⚠️ OWED-TIMINGS, now MEASURED (the brief's two `⚠️ OWED:` items):** `refresh_seed.sh` **85 s / 89 s**;
`selfcompile_fixpoint.sh` **38 s / 39 s**; strict `bootstrap_from_seed.sh` **30 s**. Total EX-2
wall-clock on the box ≈ **4.7 min**. 🚨 **The brief's foreground-ceiling warning did not bind:** the
fixpoint is a **~40-second** gate here, not a 600 s one. `AGENTS.md`'s foreground-ceiling paragraph
names `perf_scaling` (654-748 s) and `engines` (~5-7 min) — **the fixpoint is not in that class on
this box** and the caution appears to have been inherited by association. Backgrounding it cost
nothing, so this is a note for the next brief's budget, not a complaint.

unchecked:
* **Zero goldens blessed — intact.** `git status --porcelain` is exactly `M compiler/seed/emitter.ll.gz`
  plus untracked `scratchpad/`. **No snapshot, no `selfproc_legA`, nothing under `test/`.** EX-1's
  required LEG A shape (**13 deletions, zero additions, zero re-signatures**) is undisturbed: I
  changed no `.mdk`, so I cannot have moved a scheme. EX-3 inherits exactly what EX-1 left.
* **The three gzip corpus gates were NOT run** (`gzip/test/inflate_oracle.sh`,
  `gzip/test/deflate_oracle.sh`, `test/wasm/diff_gzip.sh`) — the seed is their fixture and its bytes
  changed. Argued content-independent above from their own construction; **that is an argument, not a
  run.** ⚠️ **OWED:** `sh gzip/test/inflate_oracle.sh` · `sh gzip/test/deflate_oracle.sh` ·
  `sh test/wasm/diff_gzip.sh` (the last needs node ≥24 + the wasm oracle). Cheapest first-line
  substitute, also not run: `gunzip -t compiler/seed/emitter.ll.gz`.
* **`typecheck_compiler_source.sh`, `diff_compiler_engines.sh`, `perf_scaling`, `tmc_parity`,
  `must_fail`, corpus sweeps, full suite: NOT RUN** — per the reduced floor, and none of them is
  moved by a seed blob. EX-4 owns the must-fail and `check_cli_modules` re-runs on this binary.
* **A COLD clone from the new seed was not exercised end-to-end** — `bootstrap_from_seed.sh` builds
  the emitter from the seed (that ran, strict, PASS) but I did not then run a full cold
  `make medaka` in a fresh checkout with no `./medaka_emitter`. CI's every shard does exactly that
  (`ci.yml:941`, *"Build medaka (cold bootstrap from seed)"*), and the cache-bust in `could move:`
  item 4 guarantees it happens on the next push. ⚠️ **OWED:** a fresh-clone `make medaka` if the
  release cares.
* **Whether the seed lagged at BASE could NOT be retrieved.** `gh run view --job 94308407847 --log`
  (the `soundness` job on `2b9dc798`) returns **empty output at exit 0** — the log is gone or
  unavailable, so the BASE-side C3a WARN is inferred from the seed's 2026-07-19 date and the
  1341-commit gap, **not observed**. ⚠️ **OWED:** nothing re-derivable now; the inference is
  labelled as such.
* **PERF: not measured.** A re-mint cannot change any built binary's speed (nothing reads the seed
  after bootstrap), but the *cold bootstrap itself* now expands a 23%-larger IR and compiles it —
  `bootstrap_from_seed.sh` took **30 s** here post-re-mint and I have no pre-re-mint reading of the
  same script to compare against. **Genuinely unanswered.**
* **Reproduction:** `scratchpad/ex2-state.sh` (state + seed identity), `ex2-fp.sh <label>` (timed
  fixpoint), `ex2-remint.sh` (the two-pass re-mint with the identity comparison), `ex2-post.sh`
  (strict bootstrap + post fixpoint), `ex2-gzprobe.sh` (the gzip-mtime derivation). Logs:
  `fixpoint-pre.log`, `fixpoint-post.log`, `remint-1.log`, `remint-2.log`,
  `bootstrap-strict.log`, `ci-soundness.log`, `ci-seedhealth-head.log`. ⚠️ The multi-MB seed copies
  those scripts made were **deleted** after their md5s were recorded (47 MB → 164 KB of untracked
  scratch); the pre-re-mint seed is recoverable from git (`git show HEAD:compiler/seed/emitter.ll.gz`,
  `md5 aabf000154a06fa5964815706e63267d`, raw `md5 60e85f34ea808452af49c955828cfc9d`).
