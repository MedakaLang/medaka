# Stage B / Phases 4 + 5 (`B-2.3` + `B-2.4`) — sprint run doc

**Unit:** ARCH B-2 (#1113), its final two phases. **This sprint closes #1113.**
**Base:** `main` @ `0913762f` (pin your own `BASE=$(git rev-parse HEAD)` — `origin/main` moves
under you, every worktree shares one `.git`).
**Predecessor:** `.claude/STAGE-B-PHASE3-SPRINT.md` (Phase 3′, `B-2.2`, merged as PR #1616).
Its records are `.claude/sprint-phase3/`; its close-out checklist is the template for §5 and §7 here.

> ⚠️ **This doc is UNGATED PROSE.** `.claude/STAGE-*.md` is not in `check_agent_doc_symbols.sh`'s
> `git ls-files` set. Every citation below was derived first-hand on 2026-08-14 at `0913762f`, and
> each carries the command that reproduces it. **Re-run the command; do not quote the number.**

---

## 1. Where the arc actually is

Phase 3′ (`B-2.2`) landed identity into the route **word**. It did not land identity into the
selection **key**. The arc's headline claim was re-asked at the end of that phase, as its contract
requires, and answered with measurement (#1113 comment 2026-08-14; `.claude/sprint-phase3/DECISIONS.md`
RUN-P3-050):

> **Evidence is now order-invariant. The instance consulted is not.**
> **C4/I2 holds as CONJUNCT 2 ONLY. Same shape as Stage A's failure, one layer in.**

The boundary, stated as a property rather than a list of programs:

> C4/I2 holds **iff every constrained call site's candidate scan — keyed by `(method name, head
> type)` with no interface or origin component — yields exactly ONE row.**

Where two impls share a method name *and* a head type, the row is chosen by declaration/import
order **upstream of any word**, on every engine, at `check` exit 0, with no diagnostic. Phase 3′
made the wrong choice **nameable in the IR without making it right**.

| phase | unit | state entering this sprint |
|---|---|---|
| 3′ | `B-2.2` evidence references in routes | ✅ merged, PR #1616 |
| **4** | `B-2.3` frozen admissibility | **THIS SPRINT.** Carrier ruled (AD-2); no design doc |
| **5** | `B-2.4` the three engines (+#1068, #1265-keying, #1608) | **THIS SPRINT.** `D2` is STALE (§4 Q1) |

---

## 2. Scope

### The owner ruling that sets it (Val, 2026-08-14)

**Phase 4 + Phase 5, in one sprint, closing #1113.** The standing rule this overrides —
*"one IR-moving evidence rewrite per sprint"* — exists to protect **golden attribution**: two
rewrites over the same organs with deferred goldens reproduces the F-3 failure the design doc
names, where CI cannot say which half moved a golden.

🚨 **The mitigation is structural and is not optional: Phase 4 takes its OWN terminal close-out —
goldens re-cut exactly once, seed re-minted TWICE, fixpoint C3a+C3b — BEFORE Phase 5 opens a single
bite.** That restores attribution at the cost of one extra checkpoint rather than a second sprint.
A Phase 5 bite landing on top of un-re-cut Phase 4 goldens voids the ruling's premise, and the
correct response is to stop and close Phase 4 out, not to defer harder.

### IN

| # | item | why |
|---|---|---|
| 1 | **Phase 4 — `B-2.3` frozen admissibility** | Per-(class, position) admissibility computed once post-K from global `IE`, frozen into the elaboration output **as data**, consumed and never re-derived |
| 2 | **Phase 4's terminal close-out** | The attribution mitigation above. Non-negotiable |
| 3 | **Phase 5 — `B-2.4` the engines** | LLVM `implEntryRouteWords` superset-OR retirement + `noneHeadTag` catch-all re-key + disjoint default-tag namespace; wasm peer arm; `eval.mdk` mirrored dispatch; `Route`/`core_ir_lower` |
| 4 | **#1068**, with Phase 5 | The design doc's coordination note: #1068's filed fix direction *"would build in wasm the superset arm this task deletes"*. Sequential is the wrong answer |
| 5 | **#1265 keying half** | Stage B RUN-B-011 split it: keying **IN** (bite `B-2.4-k`), denotation **OUT**. Boundary: *can the key express two distinct answers?* No ⇒ representation ⇒ IN |
| 6 | **#1621** (inert `keyTable`/`KeyBuckets` residue) | Phase 3′ left it built with zero terminal reads. ⚠️ **99 lines across TWO binders** — a census keyed on `keyTable` alone misses the multi-module half and Phase 5 sizes off the wrong count |
| 7 | **#1622** (the `b2` drop + the D4 `iface == ""` finding) | Without it Phase 5 re-plans the dropped `b2` off D1's stale ✅ |

### IN as drain targets (Val's ruling, 2026-08-14) — the conjunct-1 family

**#1617 · #1619 · #1620 · #1608.** All four are the order-dependent-selection family this sprint's
re-key is aimed at. State the expected drains up front; grade them at close-out on the **final**
binary, twice, quiescent.

- **#1617** (S0) — a function-typed impl head falls into the `noneHeadTag` bucket; `run` answers by
  declaration order in **both** permutations at exit 0, `build` E-PANICs.
- **#1619** (S0) — a cross-module interface **default** is silently hijacked by a same-spelled
  interface at the same head; the default is never reached, no diagnostic.
- **#1620** (S0) — two interfaces sharing a **method** name in one file: `check` clean, `run`
  E-PANICs, the built binary prints a raw word at exit 0 (symbols are correct and *distinct*).
- **#1608** (S1) — `cevalModules`/`cevalProgram` resolve a cross-module interface method by import
  order rather than by the receiver's type. ⚠️ **Ungated in every direction** — see §4 Q5.

⚠️ **#1618** (S1, effect-carrying impl head: checks and runs, cannot be built) is a **sibling, not a
member** — it is the `headTyconTy` arm-set defect, not the selector. Its ownership is Q7.

### OUT — each with its reason, so it can be overturned

- **B-1 (#993).** Untouched by anything that landed. AD-1 leaves the two-constructor route
  presumption intact; Phase 4's carrier is a `CProgram` field, not a `Route` constructor.
- **#1593** (retire the ELABORATED trio) and **#1597** (field-owner topological prefix). Both are
  A-3 residue with their own owners; neither gates B-2.
- **#1610** (nightly `perf_scaling` DEEP red, bisect owed). Real and untriaged; a lint-stage perf
  issue with no typechecker coupling. Out-of-band, as in Phase 3′.
- **The `TyConstrained` third arm** as an independent unit. It is named in both #1617's and #1618's
  bodies as the third member of the SET; whoever fixes the arm set fixes all three. Filing a fourth
  issue for it duplicates.

### Issue-closure policy — unchanged

**Implement; do not close.** A drained pin is drained, not closed. **Desk closes are an exit
criterion** (§8): Stage B verified #991 and #1114 done in Phase 0 and then let the tracker carry
them as open for a further sprint.

---

## 3. What is already settled — do NOT re-derive

### AD-2, the Phase 4 carrier — RULED

`.claude/sprint-phase3/AD2-carrier-ruling.md`. **Two-valued, spelled
`CAdmisAbsent | CAdmisTable …`. `Option` is REJECTED** — RUN-B-013's fail-closed condition 1
forbids the `Option` idiom by name. A bare 5th `CProgram` field collapses that condition because an
empty table is indistinguishable from an absent one.

Corrections that ruling makes to the record, so they are not re-inherited from `D2`:

| claim | source | status |
|---|---|---|
| *"`lowerProgram` is the UNTYPED shared path"* | `D2` §3 | **WRONG as worded** — 2 of 7 probe-driver callers are typed |
| *"its 9 application sites are the untyped probe drivers"* | `D2` §3 | **WRONG** — 7 drivers, plus `lowerProgramEmit` and `compiler/tools/snapshot.mdk`, a **user-facing verb** |
| *"`CProgram` is constructed at exactly ONE site"* | `D2` §3 | **WRONG** — 13 construction sites |
| *"no user-facing verb reaches the untyped path"* | `sprint-b/DECISIONS.md:697-698` | True of `cevalModules`/`cevalProgram`; **FALSE of `lowerProgram`** |

### The two constraints C4/I2 places on these phases

- **Phase 4 must key the frozen table by INTERFACE IDENTITY (`module::Iface`), not by
  `(method, head)`.** The obligation minted from one module's interface may only be discharged by
  an impl *of that interface*. 🚨 **If Phase 4 freezes admissibility computed by the CURRENT
  selector, it freezes the order-dependence** — and does so behind a table that then reads as
  authoritative. This independently corroborates AD-2's arrival at an identity-keyed carrier.
- **Phase 5 must make the engines CONSUME that table**, not re-run their independent
  `(method, head)` families. 🚨 **Cross-engine agreement CANNOT detect a Phase 5 miss** — measured,
  all three engines agree on the *same wrong, order-dependent* answer. **Only a permutation
  differential sees it** (§4 Q4).

### DICT §5's actual condition, in its precise form

Per (class, argument position), **every reachable constructor uniquely determines the
min-specificity winner for every goal reaching the site, and the argument must be evaluated.**

⚠️ **NOT "no overlap below the head"** — that paraphrase licenses an S0 with zero overlap:
`impl C (T Int)` and `impl C (T Bool)` do not overlap and the tag `T` determines nothing. Phase 3′'s
review lesson was that *every* spec-conformance DEFECT was a place the draft paraphrased a rule more
loosely than written. Quote the rule.

---

## 4. Phase 0 — the refresh, and the seven questions it owes

**Phase 4 has no design doc**, and concurrent design-ahead was ruled out by measurement, not taste
(the audit put design-ahead's rework rate at **75%**; D1's line numbers drifted ~+530 before anyone
used them). So the Phase 4 design run happens **here**, at Phase 0, reading HEAD.

### Q1 — `D2-phase5-engines.md` is STALE. How stale, measured

`D2` is pinned at `604278bb` and rests its entire usability on one structural claim: *"only
`compiler/types/typecheck.mdk` changed … so every engine-file line number in P0-C is still valid."*
**That claim is now FALSE.** Derived at `0913762f`:

```sh
git diff --stat 604278bb HEAD -- compiler/
```

`wasm_emit.mdk` **+628**, `eval.mdk` **+106**, `core_ir_lower.mdk` **+35**, `typecheck.mdk`
**+2036**, and a **new** engine surface: `compiler/entries/wasm_emit_typed_main.mdk` (+463).

Symbol-level survival, checked one at a time (`grep -nE '^<sym>' <file>`):

| symbol | `D2`'s line | HEAD | verdict |
|---|---|---|---|
| `llvm_emit.implEntryRouteWords` | 1512 | 1512 | ✅ exact — `llvm_emit.mdk` is byte-identical |
| `llvm_emit.emitDispatchArm` / `emitRouteWordMatch` / `implEntryTags` | 5336 / 5356 / 5491 | same | ✅ exact |
| `eval.hasTag` / `matchesTag` | 1206-1212 | 1176-1182 | ⚠️ drifted −30 |
| `eval.implMethodEntry` | 1998-2004 | 1972 | ⚠️ drifted −26 |
| `wasm.implEntryRouteKeyW` | 4034 | 4000 | ⚠️ drifted −34 |
| `wasm.methodImplKey` | 4456 | 4422 | ⚠️ drifted −34 |

**The owed answer:** every symbol survives; **every line citation in `D2` for `eval.mdk` and
`wasm_emit.mdk` is stale.** Re-derive Phase 5's site lists **by symbol**, never by line — and treat
`wasm_emit_typed_main.mdk` as a site set `D2` never saw at all.

### Q2 — serialization of the 5th `CProgram` field: **render** or **omit**?

AD-2 §5(2) explicitly picks neither. `cprogramToSexp` (`core_ir_sexp.mdk`) emits exactly 4
sub-lists; `parseCProgram` (`core_ir_sexp_parse.mdk`) matches exactly a 4-element `SList` and
**panics** otherwise.

- **Render** ⇒ every `core_ir_sexp` golden moves, and `parseCProgram` must round-trip it. ⚠️
  `core_ir_roundtrip_main.mdk` lowers → serializes → **re-parses** → evaluates, so a non-round-tripped
  field **silently becomes `CAdmisAbsent` after a round trip** — a silent-wrongness shape, not a
  golden move.
- **Omit** ⇒ goldens hold still, but `core_ir_typed_modules_dump_main.mdk` — `AGENTS.md`'s
  designated probe for *"which impl did it actually pick"* — cannot show admissibility, on the
  exact sprint where that is the question.

**Rule it in Phase 0 and write the ruling to `DECISIONS.md`.** Both are defensible; shipping
neither deliberately is not.

### Q3 — is the `(class, position)` key SCOPED? **Prove it, do not assert it**

AD-2 §5(1) hands this forward as *"the live instance of the program-global bare-name-table trap."*
This tree has paid for that shape thirteen times. The required deliverable is a fixture where the
new table is **present** and the assertion is about code that does **not** use it — a module that
never imports the feature, a binding whose type mentions none of the new machinery, the prelude.
*"It is keyed per-X"* is an assertion; `<iface-identity>@<slot>` is a proof.

### Q4 — does the permutation differential reach WASM? (it appears not)

`test/diff_compiler_import_order.sh` is the instrument the C4/I2 ruling names as the **only** thing
that can see a Phase 5 miss. Its signature, from its own header:

```
check=<exit>;codes=<sorted,comma>;schemes=<check stdout>;run=<exit>:<stdout>;build=<exit>/<exec-exit>:<stdout>
```

**`check` · `run` (eval) · `build` (native) — and no wasm cell.** Derived at `0913762f`, not
inferred from the header: `grep -ni wasm test/diff_compiler_import_order.sh` returns **one** hit,
line 505, and it is a comment about an unrelated absent-tool hazard. **There is no wasm arm.**

Phase 5 changes wasm's independent uniqueness family (`headTagUniqueW`, `distinctKeysAtHeadW`,
`implEntryRouteKeyW`, `methodImplKey`, `findByTagW`). ⇒ **Extending this gate to a wasm arm is a
Phase 5 deliverable, not a nice-to-have** — without it the one instrument that can see the miss is
blind to one of the three engines it must grade. What Phase 0 owes is the *sizing*, not the
derivation: re-run the grep to confirm nothing has landed since, then cut the bite.

### Q5 — #1608's fourth arm: which harness carries it?

`test/MUST-FAIL-NOT-PINNABLE.txt:174` refuses the pin with a derived argument: **no verb in the
must-fail harness drives the engine that is wrong.** `run_verb` offers check / check-json /
check-types / run / build / build-run / fmt-write / mcp-call, and every one drives `eval.mdk` or the
native path; **none reaches `cevalModules`**. `diff_compiler_engines.sh` has three arms (eval,
native, wasm) and this driver is not one of them. The only driver that reaches the broken arm is the
compiled probe `compiler/entries/core_ir_modules_main.mdk`.

🚨 **And the one gate that does run `cevalModules` drives the UNTYPED path** (desugar + annotate, no
marker, no typecheck) — so **no `Route` is ever stamped and that gate cannot distinguish a correct
route word from no route word at all. Its green proves nothing in either direction.** Phase 5 owes a
fourth engine arm or a typed multi-module gate; pick one in Phase 0 and size it.

### Q6 — does the SELECTOR re-key belong to Phase 4 or Phase 5?

The C4/I2 ruling says Phase 4 keys the **frozen table** by interface identity and Phase 5 makes the
engines **consume** it. It does not say who re-keys the **candidate scan** that conjunct 1 fails on.
Both readings are live and they size very differently. **Adjudicate before the first bite is cut**
— a bite list cut against the wrong reading is the F-3 failure arriving through the front door.

### Q7 — #1618's ownership

Effect-carrying impl head: `eval.headTycon` strips `TyEffect`; `typecheck.headTyconTy`'s `_ => None`
arm swallows it. That arm swallows **three** things — `TyFun` (#1617), `TyEffect` (#1618) and
`TyConstrained` (unfiled by ruling, named in both bodies). If Phase 4's table is keyed on a head
function that returns nothing for three type shapes, the table **under-discriminates by
construction** and freezing it freezes that too. **Derive whether the arm set is a Phase 4
precondition or an independent unit.** Audit the arms as a SET either way — Phase 3′'s own
retrospective records *"I wrote 'audit the arms as a SET' and then shipped a set one arm short."*

---

## 5. Phases 1–2 — `B-2.3`, then its terminal close-out

**Phase 1 — implementation.** Bites cut from the Phase 0 design run. A bite is a transformation over
named sites: if it cannot be stated as *"apply this transformation to these N named sites"*, it goes
back to the architecture companion. That test is the whole reason Sonnet can be trusted inside a
27k-line `typecheck.mdk`.

Between every bite: backgrounded `sh test/preflight.sh` + `sh test/selfcompile_fixpoint.sh`, run
detached and polled. A kill at 600 s with exit 143 is the **foreground tool ceiling**, not a hang.

**Phase 2 — the close-out, in execution order.** Follow `.claude/sprint-phase3/CLOSE-OUT.md` §1
verbatim; it is the checked template. Steps, compressed: quiescence → the FINAL binary →
`test/refresh_seed.sh` **TWICE** (it is not idempotent after a codegen change; a stale seed
SEGFAULTS a correct change) → `sh test/selfcompile_fixpoint.sh` **C3a and C3b** on the
twice-refreshed seed → rebuild the oracles the re-cuts read, **before** any capture → goldens re-cut
**exactly once** from the final binary → re-show the drain claims **twice**, quiescent → PR body.

⚠️ **Goldens are re-cut, never merged, and never three-way auto-merged.** A rebase auto-merges
`test/selfproc_goldens/legA/*` cleanly with no conflict marker — that happened to three agents in
one session on one file. Take the base's version of both moved golden families and **re-derive**
from the rebuilt binary.

---

## 6. Phases 3–4 — `B-2.4`, then its close-out

Phase 5's bites, sized off **re-derived** site lists (Q1), not off `D2`. Same bite protocol, same
inter-bite checkpoint, same close-out sequence. **#1068 lands with it, not after it.**

⚠️ **The `unchecked:` set that Phase 3′ shipped with must be run here:** perf/scaling, the wasm
gates, and `diff_compiler_selfproc`. A phantom-skipped `diff_compiler_selfproc` on a
compiler-source change is **not dismissible** — it is the only local signal for the LEG A scheme
golden, and it reds in the CI `backend` shard when skipped.

---

## 7. The repair round (MANDATORY)

Phase 3′'s repair round found real defects in landed, green work; budget for it rather than treating
it as slack. Its standing attack list, carried forward and re-aimed:

1. **The permutation differential, on the shapes the sprint claims to fix** — including the
   uncovered shape from #1113's comment, recommended there for `test/import_order_fixtures/` as a
   known-bad ledger row.
2. **The `_ => None` arm SET** (Q7) — not one member.
3. **Every claim in the PR body traced to a command.** The dominant finding across nine Stage A
   adversarial reviews: with two exceptions, **every real finding was a claim reaching past its
   evidence** — a comment, a fixture header, a PR body, an orchestrator brief — never wrong code.
   The gates check the code; the prose about the code survives them unchecked.
4. **The base-vs-branch differential**, with the exe-relative trap respected: a `medaka` binary
   resolves its emitter *and* its stdlib from `exeDir`, and `medaka build` additionally needs
   `runtime/` beside it — a missing `runtime/` passes `check` and `run` and dies at the first
   `build`.

---

## 8. Exit criteria

| # | criterion | owner |
|---|---|---|
| 1 | **#1113 closes.** Both phases landed, or the residual is FILED with a number — *"unowned"* is not an allowed outcome | ORCH |
| 2 | **C4/I2 asked a THIRD time, at the end, with the CONJUNCTION as the bar.** Hand-derive every expected answer from DICT §8 I4 **before** any invocation. Report conjunct 1 and conjunct 2 separately and name the shape each still fails on | ORCH |
| 3 | **The four drain targets graded on the final binary, twice, quiescent.** A drain is causal or it is a shape move; say which | ORCH |
| 4 | **Fixpoint C3a + C3b PASS** on the twice-refreshed seed, per phase | ORCH |
| 5 | **The desk closes** — every issue encountered is tracked, every pinnable open bug has a self-draining fixture, worktrees and orphan processes reaped | ORCH |
| 6 | **`DEBT.md` rows carry `could move:`, `nearest miss:`, `engines:` and `unchecked:`** — all four mandatory, per bite | IMPL |

🚨 **Criterion 2 is the one that can be quietly failed.** A sprint that lands both phases and
reports *"C4/I2 now holds"* without the shape-level split repeats Phase 3′'s near-miss in the one
place the arc cannot afford it. The honest answer may again be *"conjunct 2 only"* — say so.

---

## 9. Deltas from the inherited protocol

- **Two phases, two close-outs.** New this sprint; §2's mitigation. Everything else in the Stage B
  protocol is unchanged.
- **PARALLELIZE READERS, SERIALIZE WRITERS.** One implementer live at a time. Stage A ran 3–5
  concurrent writers and paid: four contaminated measurements, all from agents holding uncommitted
  edits; ~4 bites of rework from a region collision; one function built twice. Read-only reviewers
  interfered with nothing.
- **State concurrency honestly in briefs.** Stage A's orchestrator opened a brief with *"you are the
  ONLY agent live"* and dispatched two more into that worktree minutes later.
- **The fixpoint and seed re-mint are IN-BAND, not deferred** — both phases change emitted IR.
- **Brief for refusal, then believe the refusal.** Design was wrong on 4 of 6 bites in a prior run
  and every catch came from the implementer.
