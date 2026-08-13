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
