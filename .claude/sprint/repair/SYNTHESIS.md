# SYNTHESIS — Stage A repair round

Trunk `arch/stage-a-sprint` @ `0b953165`, read-only. No rebuild, no bless, no tracked-file
edit; this file is the only write. Probes `MEDAKA_STRICT=1`, exit codes read from a file or
directly, never through a pipe. Scratch:
`/var/tmp/medaka-scratch/claude-0/-root-medaka/b99a3174-…/scratchpad/{syn,seam}`.

**Label key** — **DERIVED** = I ran or grepped it here · **RELAYED** = a reviewer's, not
re-derived · **OWED** = nobody has.

> 🚨 **Input gap, recorded first because it bounds everything below.**
> `.claude/sprint/repair/` contains **four** reports (R2, R3, R4, R5). **`R1-permutation.md`
> does not exist** (DERIVED: `find` over `.claude/`, `/var/tmp` — the only artifacts are R1's
> isolated worktree's, not in this tree). R1's findings are therefore taken from
> `DECISIONS.md` **RUN-052** alone, which is an orchestrator's summary of a reviewer's report
> — one relay hop further from the measurement than every other finding here. **SA-3 is the
> only S0 in this document with no primary artifact and no first-hand reproduction**, and
> recovering it is fix-plan item 0.

---

## 1. Adjudicated finding list

Globally re-labelled `SA-n` per RUN-051's naming-collision warning (R3-F1 ≠ R5-F1).
Ranked by **what breaks worst if left**, not by fix cost.

| id | severity | attribution | reviewers | status |
|---|---|---|---|---|
| SA-1 | **S0** silent wrongness | **REGRESSION (ours)** | R3-F1 ≡ R1-F1 | DERIVED here |
| SA-2 | **S0** silent wrongness | **REGRESSION (ours)** | R1-F2 only | RELAYED (2 hops) |
| SA-3 | S1 loud false reject + architectural contradiction | pre-existing reject, **new inconsistency** | R5-F1 ≡ R2-F2 | DERIVED here |
| SA-4 | S2 misleading | not a regression | R5-F2 | DERIVED (code) |
| SA-5 | S2 misleading | not a regression | R3-F2 | RELAYED |
| SA-6 | S2 latent silent-accept arm | REGRESSION (ours, latent) | R5-F3 | RELAYED + code DERIVED |
| SA-7 | S2 location loss | relocation-adjacent; attribution OWED | R4-F3 | DERIVED (one instance) |
| SA-8 | S3 duplicate diagnostic, pinned in an oracle | INTENDED-by-argument, now real | R4-F2 | RELAYED |
| SA-9 | S3 ledger stale in the direction that hides SA-3 | ours | R5 §ledger | DERIVED |
| SA-10 | S3 dead symbol + a gate that cannot see it | ours / pre-existing | R2-F4 (+ new) | DERIVED |
| SA-11 | S3 attack-list target that cannot exist | ledger defect | R2-F1 | RELAYED |
| SA-12 | — | **INTENDED, not defects** | R1-F3, R3-F3, parts of R2/R5 | classified, no action |

### SA-1 — the segfault SURVIVES Door 4 for any goal that never residualizes (S0, ours)

**One defect, two discovery routes, one mechanism** — merged per RUN-053's corroboration map:
R3 reached it from **goal groundness** (an added type signature; also a nullary binding ground
by literal defaulting), R1 from a **non-generalized** binding. Both bypass the same code.

**DERIVED first-hand.** #1564's own fixture, four files unchanged, `nest.mdk` given
`export nest : Int -> String` and nothing else:

| arm | `main.mdk` (rejecting order) | `control.mdk` (2 import lines swapped) |
|---|---|---|
| `check` | **0** (`main : Unit`) | 0 |
| `run` | 1 — `E-PANIC: putStrLn: not a String` | 0 — `wrap(int)` |
| `build` | **0** | 0 |
| execute the binary | **139 — `E-FATAL-SIGNAL: segmentation fault`** | 0 — `wrap(int)` |

**Attribution: OURS.** BASE rejects at `check` exit 1, HEAD accepts and segfaults — R1's
two-arm differential (RUN-052), which is the authority here; R3's own pre-sprint oracle was
`/root/medaka`'s stale binary and R3 labelled it OWED itself. Do not attribute by plausibility.

**Mechanism, DERIVED by grep, not relayed.** `unroutedResidual` has **exactly one call site**:
`compiler/types/typecheck.mdk:24701`, `residualPredsOf`'s `None` arm (definition `:24743`).
`residualPredsOf` is the residual reducer at a generalizing group's close (`:24617`,
`:24694`). **A goal that is fully concrete, or a binding that is not generalized, never
reaches it** — those discharge through the end-of-body obligation checker, which accepts via
`implMatchesU` over the graph-global `IE` while the evidence/route side still reads the
topological-prefix accumulator. Door 4 patched the reducer's `None` arm only; its own header
says it drains when the reader moves. **The two-registry disagreement is untouched.**

**#1564's pin cannot see this** — it grades the deferred shape, on `check`.

### SA-2 — import order decides whether the BUILT BINARY segfaults, silently (S0, ours)

**RELAYED, 2 hops, no primary artifact** (see the input gap above). RUN-052: a 6-way
permutation of three import lines; HEAD `check`/`run`/`build` **all exit 0 in all six** and
`run` prints the **correct** value `5` in all six, while the **built binary segfaults in 3 of
6**, deterministic over 3 re-runs; single variable `import gen` before `import spec`. BASE
rejects all six.

**Why this outranks SA-1.** SA-1 leaves one loud signal (`run` panics). Here **every arm is
clean and `run` gives the right answer** — the divergence is codegen-only and there is no
signal anywhere short of executing the artifact. `run` and `build` share the whole front end,
so this is a genuine codegen/runtime split, not a second view of one typecheck observation.
It is **not** licensed by RUN-047, which licenses import order deciding acceptance *via a
diagnostic*; acceptance here is uniform.

⚠️ **Not reproduced by me and not reproducible from this tree** — the fixture lives in R1's
isolated worktree and the report was never copied back. Treat the mechanism as **OWED** until
item 0 lands: whether SA-1's fix subsumes it is an open question, not an assumption. If the
front end accepts uniformly and `run` is right, the fault may be *downstream* of the
typecheck-side registry split that explains SA-1.

### SA-3 — `checkSuperImpls` contradicts graph-global candidacy; import order decides (S1)

**R5-F1 ≡ R2-F2, merged.** **DERIVED here, with a discriminating positive control**, on a
third construction (my own, distinct from both reviewers'):

```
amod.mdk  interface Sup a where sf ; interface Sub a requires Sup a where ufn
umod.mdk  import amod.{…} ; public export data Bar = Bar ; export impl Sub Bar
main.mdk  import amod.{…} ; import umod.{Bar} ; impl Sup Bar where sf x = 3 ; main = println (ufn Bar)
```
→ `check` **exit 1**: `umod.mdk:6:10: 'impl Sub Bar' requires a superinterface 'impl Sup Bar',
which is missing` — while that impl **is in the graph and is a dispatch candidate post-A-3.6**.
Positive control (both impls moved into `umod2`, so the probe can succeed): `run` → **7**,
exit 0. R5 sharpened it further: in ONE program a `Sup W` goal *resolves* beside the check
that calls the same impl missing.

**Site, DERIVED:** `checkSuperImpls` (`typecheck.mdk:15990-15995`) binds
`rows = ieRowsVisibleAt cur ie`; `ieRowsVisibleAt` (`:4318-4320`) filters on
`declEnvVisibleAt` (`:2872-2873`, `entryOrd <= cur`), while candidacy went to
`ieCandidacyVisibleAt _ _ = True` (`:2901-2902`, single reader `ieSnapAt:4293`). **One
binding, one line — the fix site is unambiguous.**

**Attribution: NOT a regression** (BASE rejects too, both axes being prefix-scoped then). What
is new is the **inconsistency** — A-3.6 moved one axis and not the other. Fail direction is
**loud** (a prefix can only under-report), so no silent accept.

**🚩 OWNER DECISION REQUIRED — do not implement either arm before it is ruled.** RUN-039 and
RUN-042 both recorded it UNRULED and nobody has ruled since.

### SA-4 — Door 4 fires where there is no evidence to route (S2)

**DERIVED from source**, corroborating R5-F2's probe: `unroutedResidual` (`:24744-24748`) is
guarded by `implMatchesU perRun.value.residualUnivRef.value iface args` **alone** — it never
asks whether the matched impl *has* a `requires` context. For a no-`requires` impl the correct
answer is `[]` on both arms, yet the case is converted into a hard error whose text asserts
*"accepting it would build a program that reads a dictionary that was never passed"* —
falsified by R5's IR read (`define i64 @mdk_nest__nest(i64 %arg0)`, arity 1, no dict). Not a
regression (pre-A-3.6 this was `T-NO-IMPL`); an incoherence between the guard and its claim.

### SA-5 — Door 4's remedy is wrong for the declared-given shape (S2, RELAYED)

R3-F2: with `export nest : Tag (Wrap a) => a -> String` the message advises adding an
`import`; following that advice still fails, now demanding `Tag a =>`. The program is
correctly refused in **both** orders — not a false reject — but the printed remedy sends the
reader to a dead end. Wording, not behaviour.

### SA-6 — `ordHere == -1` fails in two OPPOSITE directions (S2, latent)

R5-F3, code side DERIVED: `checkSuperImpls` at `-1` → no rows → every super reported missing
(**loud**); `checkCoherence` (`:15947`) takes `cohRowsOwnedBy cur` (`:15417`) → at `-1` no rows
→ **coherence checks nothing, silently**, where pre-A-3.7 it walked the decl list
unconditionally. Unreachable today (mids come from the list `buildDeclEnvs` indexed); a fourth
Module-mode driver makes it live. **A silent arm under a sentinel the arc documents as
fail-closed is exactly the loud→silent transition the repo treats as a severity increase.**

### SA-7 — location loss in the relocated decl-time checks (S2)

R4-F3, and **DERIVED incidentally by my SA-3 probe**: `T-MISSING-SUPER-IMPL` landed on
`umod.mdk:6:10`, i.e. the impl's *method body* (`ufn x = 7`), not the impl head. R4 measured
worse siblings: `T-CYCLIC-SUPERINTERFACE` points at function bodies and, on a file with a
leading comment, at `1:0` — **the comment**; `T-RECURSIVE-ALIAS` and `T-PHANTOM-METHOD` print
`<unknown location>`. Cause: `ImplRow`/`CeRow` carry no `Loc` and these checks use
`pushTypeError` (no `…At`), inheriting `currentLoc`. **Whether they were better before the
relocation is OWED** — the `.tc.golden` baselines record message text with no location field,
so they structurally cannot answer it.

### SA-8 — the "at worst a duplicate report" is real, and pinned (S3)

R4-F2: one cycle, two reports, two modules, both pinned in an `oracle.json` added by the
A-3.5c commit itself. Accepted-by-argument at ruling time; nobody has looked at it as UX. That
it exists today is RELAYED-and-credible; that A-3.5c introduced it is **OWED**.

### SA-9 — the ratchet is stale in the direction that hides SA-3 (S3, ours)

**DERIVED by grep on this tree** (`test/registry_keying_ratchet.sh`):
`ieRowsVisibleAt` → **0** occurrences · `flatImplEnvOf` → **0** · `cohSameIface` → **0**
(A-3.7 has no row at all) · the `declEnvsRef` row still asserts *"A-3.5b remains owed and DOES
read IE"*, falsified by `5efc8525`. The row's post-A-3.6 enumeration of which readers kept the
ordinal filter lists six name-scoping readers and **omits the one IE reader that kept it** —
`ieRowsVisibleAt`, which *is* SA-3's seam. The ratchet is the arc's account of that reader set,
so the ledger currently reads as if SA-3 could not exist. `sh test/registry_keying_ratchet.sh`
itself PASSes (R2) — **no gate can see this**, which is #1574's shape recurring.

### SA-10 — dead symbol, and a doc gate that cannot see the form it appears in (S3)

**DERIVED:** `test/dict_fixtures/s6-c1-hard-and-soft-in-one-file.mdk:18` still names the
deleted `cohCollectImpls` (R2-F4). **New, not reported by any reviewer:**
`docs/spec/DICT-SEMANTICS.md:2524` backticks the deleted `cohCollectImpls:11548` **and**
`cohCollectModuleImpls:11564` — and `sh test/check_agent_doc_symbols.sh` run here reports
`dead: 0`, PASS, over 1034 claims. `docs/spec/*.md` **is** in that gate's corpus, so the gate
does not see the `` `name:LINE` `` citation form. Mechanism of the miss is **OWED** (the
script has bare-`file.mdk:NNN` handling at `:173`; I did not trace the tokenizer).
⚠️ The fixture edit must be **line-count-neutral** — a fixture's line count is load-bearing.

### SA-11 — an attack-list target that cannot exist (S3, RELAYED)

R2-F1: `A5a-4`'s "user interface shadows a prelude one by spelling" Flat delta is rejected by
**resolve** first (`Duplicate interface: Debug`), so there is no acceptance delta in either
direction; `resolve.mdk` is untouched by the sprint, so BASE agrees. **Retire the target; do
not write that fixture.** Not re-derived by me — low stakes, and it only ever *removes* work.

### SA-12 — INTENDED. Reported, correctly, but NOT defects — do not "fix" these

- **A-3.6's candidacy flip** (graph-global instance candidacy) — RUN-010/040.
- **A-3.7 / #1438's coherence widening** — R1-F3 confirmed BASE emitted a false-positive
  `Conflicting impl Show2` that HEAD correctly accepts, **and that it did not eat the true
  positive**. #1438 still must not be closed (its own `why-note`).
- **Door 4's in-class rejects** — R3-F3 (`if False then …`) and R3's 2-deep chain are inside
  the declared class and fail closed. R3's "would have run correctly" half is self-labelled
  OWED and does not change the ruling.
- **Import order deciding acceptance via a diagnostic** — licensed by RUN-047. (SA-2 is *not*
  this; see there.)

### Claims that SURVIVED audit — recorded so nobody re-opens them

`runFinalChecks` **clears** on all three call sites (R5-F4, behavioural not just read).
RUN-035 holds and extends: of 13 LEG A modules only `types.typecheck` moved, 45 scheme changes
**all attributable to a named bite, zero unattributed** (R2). RUN-042 holds (re-DERIVED here:
`declEnvVisibleAt:2873` body unchanged, four direct callers `:2981/:4320/:4759/:4782`;
`ieCandidacyVisibleAt` one reader). Must-fail suite quiescent: 99 fixtures, 98 REPRO, 1
DRAINED (`1438-*`), 0 malformed. Door 4's closure of the **deferred** shape is real on all
three arms. **No `DECISIONS.md` ruling is falsified by this round except RUN-047's scope
sentence, already corrected by RUN-050.**

**Non-contradiction, explicitly:** R1 could not exhibit SA-3 and self-labelled that *"failed
to exhibit ≠ disproved"*; it probed a sibling-module configuration that rejects identically on
both arms before dispatch can contradict it. R5's and R2's exhibits — and mine — stand. This
is not a reviewer disagreement and must not downgrade SA-3.

---

## 2. The fix plan

**Serial. One item at a time, one commit per item.** Concurrency cost this sprint ~4 bites of
rework and 1 duplicated function; reviewers parallelize safely because they do not edit.
Items 6–8 are the only ones that may be reordered against each other.

---

### Item 0 — RECOVER SA-2's primary artifact (no code change) — **BLOCKING for items 1–2**

- **What changes:** nothing in the tree. Retrieve `R1-permutation.md` and R1's fixture from
  its isolated worktree into `.claude/sprint/repair/`; if the worktree is gone, **reconstruct**
  the 3-module `gen`/`spec` permutation from RUN-052's description and re-measure all six
  orders × 4 arms.
- **Why first:** SA-2 is the round's worst finding and the only S0 with no primary artifact.
  Planning a fix for a defect nobody in this tree can reproduce is how a fix gets verified
  against the bug report instead of the defect — RUN-050's own lesson.
- **Verified by:** the 6-way permutation reproducing (3 segfaults, 3 clean, `run` correct in
  all six) on `0b953165` — i.e. **the probe must succeed pre-fix**.
- **Owner ruling needed:** no.

### Item 1 — SA-1: extend the unrouted-evidence reject to the non-residual path (**REJECT LOUDLY**)

- **Direction, stated as required:** **reject**, not route. The honest fix for "accepts then
  segfaults" is a compile-time error. Routing the evidence is **B-2's job by the epic's own
  words** (`P0-H-plumbing-scope.md`), with all three A-3 doors closed and one measured still
  faulting. **Any plan that re-opens those doors is wrong, and this one does not.**
- **Sites (grep-verified):** `compiler/types/typecheck.mdk` — the guard
  `unroutedResidual:24743-24748` and its message `requiresUnroutedMsg:24757` are reusable
  as-is; the **new** call site is the end-of-body obligation checker (the consumer that accepts
  via `implMatchesU` over the graph-global universe while evidence reads the prefix
  accumulator). ⚠️ **That consumer's exact name is not yet grep-pinned by me** — the
  implementer's first act is to name it from `residualUnivRef`/`implMatchesU`'s reader set, and
  it must be named in the DEBT row, not described.
- **What it fixes:** SA-1 in both discovered forms (ground goal from a signature; ground by
  literal defaulting; non-generalized binding).
- **What could move:** every program where a concrete goal matches an impl in a
  non-imported, later-sorting module. This is an **acceptance narrowing** by construction —
  the risk direction is false rejects, exactly Door 4's. R3 attacked Door 4's class and found
  no false reject where evidence was routable, and swept `medaka_cli.mdk`, `sqlite.mdk`,
  `stdlib/json.mdk` clean; that sweep must be **re-run after this change**, since it widens
  the reject to the concrete path the prelude actually uses.
- **🎯 Nearest program this fix does NOT cover:** a concrete goal whose impl is in a
  non-imported module **that sorts EARLIER** — the prefix accumulator already contains it, so
  neither channel disagrees and nothing fires; and any shape where the two registries agree
  but the *emitted* dict is still wrong (that is SA-2's territory, item 2). Second-nearest:
  the same ground shape reached through `medaka test`'s single-file arm, whose driver differs.
- **Verified by:** the four-arm table above going 1/1/1/— on `main.mdk` and staying 0/0/0/0 on
  `control.mdk`; plus a **new must-fail pin** graded on the **built binary's exit code**, not
  on `check` — #1564's pin grades the deferred shape and structurally cannot see this.
- **Owner ruling needed:** **no** on direction (reject is forced by the severity rule), **yes**
  if the implementer finds the reject cannot be made without touching the routing side.

### Item 2 — SA-2: derive the mechanism, then fix or file

- **What changes:** unknown until item 0 lands. **Do not write a fix from RUN-052's summary.**
- **Method, mandated:** grade the **mechanism**, not the exit code — `medaka build --keep-ir`
  on a segfaulting order and a clean order, and diff the emitted IR for the dict parameter
  (this is what turned a dispatch S0 from speculation into `call @mdk_impl_…` on screen).
  `run` being *correct* in all six orders means the interpreter routes and codegen does not,
  so the front-end-only story that explains SA-1 is **not** sufficient here.
- **Decision point after derivation:** if the root cause is the same registry split, item 1's
  reject may already subsume it — **prove that by re-running the permutation on the item-1
  binary, do not infer it.** If it is codegen-side, this is `ws:emitter` work and should be
  **filed, not fixed in this round** (see §3).
- **🎯 Nearest program not covered:** any permutation of >3 imports, and the same shape on
  **wasm** — untested by anyone.
- **Owner ruling needed:** yes, if it turns out to be codegen-side and therefore out of A-3.

### Item 3 — SA-6: make the `-1` sentinel fail-closed on BOTH checks

- **Sites:** `checkCoherence:15947` / `cohRowsOwnedBy:15417` — the `-1` arm must not silently
  return no rows. Guard at the `ordHere` producer (`declEnvsOrdOf`'s miss) or at the two
  consumers; the arc documents the sentinel as fail-closed, so the loud arm
  (`checkSuperImpls`) is the intended shape and coherence should match it or hard-error.
- **What it fixes:** a latent silent-accept arm — a loud→silent transition, which the repo
  ranks as a severity increase even while unreachable.
- **🎯 Nearest program not covered:** none today, by construction — it is unreachable from the
  three current Module-mode drivers. **The fixture must therefore be a unit-level assertion,
  not a program**; a "feature works" fixture cannot exist here.
- **Owner ruling needed:** no. Cheap, and it is pure fail-direction hygiene.

### Item 4 — SA-4 + SA-5: Door 4's guard and its remedy text

- **SA-4 (behaviour):** narrow the guard so a matched impl with **no `requires`** does not
  produce `T-REQUIRES-UNROUTED` — its correct answer is `[]` on both arms. Site:
  `unroutedResidual:24745`.
- **SA-5 (wording):** the remedy must not advise `import` for the declared-given shape.
  Site: `requiresUnroutedMsg:24757`. Follow `compiler/ERROR-QUALITY.md`; the code
  `T-REQUIRES-UNROUTED` is already in `DIAGNOSTIC-CODES-DESIGN.md` and does not move.
- **What could move:** SA-4 turns a reject into an accept for the no-`requires` shape — **a
  loud→silent transition, and therefore the one item here that needs its own justification.**
  It is justified only if the accepted program is *correct*: R5's IR read (arity 1, no dict)
  says no dictionary is ever passed for that shape, so there is nothing to mis-route. **That
  IR read must be re-taken on the item-4 binary before the change is called done** — R5's was
  on the control order.
- **🎯 Nearest program not covered:** an impl with an *empty but written* `requires`, and a
  chain where the outer impl has no `requires` but an inner one does — SA-4's narrowing must
  not reach either. R3's `pdeep` 2-deep chain is the regression fixture for that.
- **Verified by:** `1564-*` still REPRO; R5's `i2` shape accepting and executing correctly;
  R3's `pgiven`/`pgiven2` showing the new wording; the full must-fail suite.
- **Owner ruling needed:** **yes for SA-4** — it is an accept-widening and this repo does not
  let those land on an implementer's judgment.

### Item 5 — SA-3: **STOP. Owner decision, then implement.**

Two coherent end states, and the sprint's own record says nobody has ruled:

- **(a) Widen `checkSuperImpls` to match candidacy** — point it at the graph-global row set
  (`ieRowsAll`, or `ieRowsVisibleAt` re-pointed at `ieCandidacyVisibleAt`). One line,
  `typecheck.mdk:15992`. Removes the contradiction and the false reject. **Risk: it is an
  accept-widening on a check whose whole job is to reject**, and R4's positive controls show
  the check currently accepts correctly on both arms — so the widening's blast radius is
  every super-impl obligation in every multi-module program.
- **(b) Keep it prefix-scoped and accept the contradiction** — then the deliverable is a
  documented ruling plus a pinned fixture recording that dispatch and the existence check
  disagree by design, and P0-B §4.3(4)'s missing fixture gets written against (b).

**Recommendation, not a decision:** (a) is what A-3.6's own licence implies and what makes the
two channels agree; but it is an accept-widening, so it wants the adversarial-review gate every
soundness-adjacent change here gets, which this round cannot supply. **My advice is to rule
now and implement in the gated round, not to slip a one-line widening into a repair commit.**
- **🎯 Nearest program (a) would NOT cover:** a super satisfied by a **non-exported** impl in
  an imported module (R4 could not construct one), and a **transitive** 2-hop super chain —
  both are untested by every reviewer.

### Item 6 — ledger and fixture re-cuts (documentation only, one commit)

- **SA-9:** re-cut `test/registry_keying_ratchet.sh`'s `declEnvsRef` row — delete *"A-3.5b
  remains owed and DOES read IE"*, **add `ieRowsVisibleAt` to the kept-the-ordinal-filter
  enumeration** (its omission is what makes the ledger read as if SA-3 were impossible), add
  `flatImplEnvOf` and correct *"all three relocated checks build a single-module ClassEnv"* to
  four checks / two env kinds, and give **A-3.7 a row** (`cohSameIface`, `cohRowsOwnedBy`,
  `ieRowsAll`, `ieRowsOwnedBy`), retiring the stale *"`deImpls` has no reader"* sentence.
- **SA-10:** re-word `test/dict_fixtures/s6-c1-hard-and-soft-in-one-file.mdk:18`
  **line-count-neutrally**; fix `docs/spec/DICT-SEMANTICS.md:2524`'s two dead symbols.
- **SA-11:** strike `A5a-4`'s item-1 target from `DEBT.md` with R2's derivation attached.
- **Verified by:** `sh test/registry_keying_ratchet.sh`, `make agent-doc-symbols`,
  `make docs-links` — all three PASS today, so all three must still PASS. ⚠️ **None of them
  can see any of these defects** (SA-9 and SA-10's doc half are both invisible to their own
  gates), so the verification here is **reading**, not a green check.

### Item 7 — the golden re-cut. **Terminal commit, its own commit, nothing else in it**

Owed since the sprint's start and still owed. Two families, both moved by every item above:
`test/snapshots/` (the compiler's own source is in the corpus) and
`test/selfproc_goldens/legA/types.typecheck.golden`.

```sh
make -C /root/medaka/.claude/worktrees/wiggly-giggling-nygaard medaka   # from the FINAL binary
sh test/diff_compiler_snapshot_frontend.sh --bless <each moved source>
sh test/capture_goldens.sh --frozen selfproc_legA
git diff -- test/selfproc_goldens/legA test/snapshots     # READ IT — that diff is the review
```
- **The LEG A diff must be additive-only**: no *existing* binding's inferred type may change.
  Items 1–5 add bindings; if a surviving binding's scheme moves, the fix changed types and that
  is a finding, not a bless.
- 🚨 **Never merged, never hand-resolved, never folded into a behavioural commit.** On any
  rebase, take BASE's version of both families and **re-derive** — a golden three-way-merges
  with no conflict marker and the blend becomes the new oracle. Three agents hit this in one
  session on this exact file.
- 🚨 The golden **is** the oracle: a `--bless` that merely turns a gate green without an
  independent decision that the new output is correct is a rubber stamp.

### Item 8 — re-run the round's own evidence against the final binary

Not a fix; the round's exit criterion. Re-run, on the item-7 binary: the full must-fail suite
(expect `1564-*` REPRO, `1438-*` still DRAINED and **still not closed**), R3's corpora sweep
(`medaka_cli.mdk` / `sqlite.mdk` / `stdlib/json.mdk`, all exit 0), R4's 12-diagnostic intact
table on **both** Flat and Module arms, my SA-1 and SA-3 probes, and `make preflight`.
⚠️ `preflight` is a filter, not an authority; the **merge queue** is.

---

## 3. File, do not fix

| finding | why not now |
|---|---|
| **SA-3** (if the owner picks (a)) | An accept-widening on a rejecting check. Needs the adversarial-review gate, which this round is not. Rule now, implement gated. |
| **SA-2** if codegen-side | `ws:emitter`, not A-3. Two-rebuild discipline applies before any measurement; out of this round's scope. |
| **SA-7** (location loss) | The real fix is `Loc` on `ImplRow`/`CeRow` — a data-model change across four checks, i.e. a unit, not a repair. File under `ws:diagnostics` with R4's three measured instances and my `umod.mdk:6:10`. |
| **SA-8** (duplicate cycle report) | UX judgment, and its attribution to A-3.5c is OWED. File; the oracle pins today's behaviour, so changing it moves a committed golden. |
| **The `DL` population set-equality** (A5a-3 / A5b-3) | Needs the instrumented hard-panic build A-3.4 PR2 used. **R2 calls it the most load-bearing unchecked item in the sprint and I agree** — it is the only thing that would prove IE/CE's visible row set at `cur` equals `accAll ++ accData ++ prog`. File as a gated task with a build. |
| **The doc-symbol gate's blindness to `` `name:LINE` ``** (SA-10's second half) | A gate defect, not an arc defect. File under `ws:tooling`; #1574 is adjacent, do not re-file that. |
| **Everything in SA-12** | Intended. Filing them as bugs is how an intended drain gets reverted by a later agent reading the tracker. |

**The plan is deliberately eight items, not twelve.** Padding it would imply coverage that
does not exist.

---

## 4. What is still UNKNOWN — aggregated honestly

**Top three, ranked by how much they could hide:**

1. **The `DL` population set-equality is unmeasured** (OWED, needs an instrumented build). It
   is the invariant the whole A-3.5/3.6/3.7 relocation rests on. Two independent reviewers
   (R2, R4) failed to exhibit the `None => []` identity-miss it would rule out — **that is
   evidence, not proof**, and an absence probe structurally cannot see an undercount.
2. **The built-binary / codegen axis is covered by exactly one reviewer, whose report is
   missing from this tree.** SA-2 is the worst finding of the round and rests on a 2-hop
   relay. **wasm was probed by nobody**, on any finding. No engine differential was run.
3. **The Flat path was never differentiated against a base arm**, and no reviewer covered
   `import m.*` / `as` / rename forms, graphs **>5 modules**, or module depth beyond 2. R3
   found Door 4 structurally cannot fire on Flat and argued why; that argument is
   source-derived, not measured against BASE.

Also owed, and not to be implied as checked:
- **`check --json` vs human `check`** on every finding here — and **#1362 is an OPEN S0**: the
  JSON/MCP arm silently drops an internal-extern violation on multi-module projects. R3 read
  SA-1's `check --json` as exit 0 with empty diagnostics; that agrees with human `check` for
  that shape, but the JSON arm is **not** an independent witness in this tree.
- **Allocation and perf**: A5b-1's per-call list, A5b-2's second whole-program fold, 3.7-7's
  new `flatImplEnvOf userDecls` on every seeded flat check. All deferred, none measured, and
  every item in §2 adds work to a decl-time check.
- **`pickMostSpecificEntry`-ambiguity as a route into Door 4** — argued from source by R3,
  never made to fire (OWED).
- **The #1438 same-spelled-interface shape crossed with a conditional impl** — designed by R3,
  never executed; R3 names it the one remaining structural route to a *spurious* Door 4 fire.
- **SA-8's attribution**, **SA-7's before/after**, and **SA-4's mid-sprint accept correctness**
  — all three need a binary this round was forbidden to build.
- **No gate, golden, snapshot or LEG A capture was run or blessed by any reviewer**, except
  the read-only comparisons R2 and I ran. The tree's expected-red set is unchanged.
