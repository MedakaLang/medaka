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
