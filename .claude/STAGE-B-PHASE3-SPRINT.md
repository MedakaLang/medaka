# Stage B / Phase 3′ sprint — run doc (`B-2.2`, evidence references in routes)

**Status:** planning artifact for a single long-running orchestration session. Written
2026-08-13 against `main` @ `983e5dd0`.
**Records directory:** `.claude/sprint-phase3/` — **not** `.claude/sprint/` or `.claude/sprint-b/`,
both of which already hold a `DECISIONS.md` and a `DEBT.md` (`ORCHESTRATING.md`, template delta 5).
**Premise:** land **one** unit — `B-2.2`, the identity payload on `Route` — on one branch, in one
worktree, with the self-compile fixpoint and the seed re-mint IN-BAND (this unit changes emitted
IR) and golden/differential verification deferred to a mandatory repair round.

> ## 🚨 This doc is the contract for what is IN and HOW IT EXITS. The *protocol* is inherited.
>
> **`.claude/STAGE-B-SPRINT.md` §3 (agent architecture), §4 (bite protocol + region discipline),
> §5 (quiescence, in-band gates, zero-goldens), §6 (communications + referee charter) and §7
> (operational traps) apply verbatim.** They survived two sprints without correction and are not
> restated here. §9 below records only the **deltas**.
>
> **Also binding, and read before Phase 0:** `.claude/ORCHESTRATING.md`'s two closing sections —
> the Stage B retrospective and **the 2026-08-13 two-sprint audit**. The audit's one-line verdict:
> *keep the model; the repair round is load-bearing and is never cut for schedule.*

---

## 1. Where the arc actually is

**Stage B landed Phases 0–2′ as PR #1605 (`1b5e740d`).** What that delivered, in the words the
memory record insists on because the shorthand over-claims: **the evidence reader now consults the
graph-global `bodyImplEnvRef`, and `KeyBuckets`' two Refs are deleted.** `#1113` (ARCH B-2) is
still OPEN and owns three remaining phases:

| phase | unit | state entering this sprint |
|---|---|---|
| **3′** | `B-2.2` evidence references in routes | **THIS SPRINT.** Design written and refreshed; blocker discharged |
| 4 | `B-2.3` frozen admissibility | OUT. No design doc exists; its carrier has a live escalation (§3) |
| 5 | `B-2.4` the three engines (+#1068, #1072, #1265-keying) | OUT. `D2-phase5-engines.md` is pinned at `604278bb` and carries relayed, unverified cells |

### The blocker is discharged — this is why 3′ is dispatchable now

Phase 3′ was refused a packet on 2026-08-13 (`.claude/sprint-b/next/QUEUED-p3-first.md`) for one
durable reason: `B-2.2-b1` cannot stamp identity while two sites in its own region mint `RKey`
with **no selector in the path** — the stamp there would be a *fabricated* identity, the exact S0
`D1 §4` exists to prevent. **`AD-1` (`5ef29a60`) took that ruling:**

- **D8** (`routeUndeterminedTop`) and **D9** (`resolveRecMono`): **DEFER the selection, with a
  BINDING interim of NEVER STAMP.** D8's decision is a dedup'd head **count** over `prog` and is
  not a selection at all; D9's path is iface-blind by construction, so no selector *can* run there.
- **The payload consequence `B-2.2-a` must absorb:** absence of identity has to be expressible on
  `RKey` ⇒ **the identity field is `Option`-valued** (or carries an explicit `unselected`).
- ⚠️ **That is a FIELD becoming optional, not a third `Route` constructor** — so B-1's
  `SupersPath` deferral is undisturbed and is **not** reopened by this sprint.
- **Consequence that unblocks sizing:** defer+never-stamp is, for `B-2.2-f`'s purposes only,
  behaviourally identical to demotion ⇒ **`f` keeps its ✅ ~7–9-site sizing**, and D1's ordering
  **`d`-ruling → `f` → `b1`+`e`** is satisfied by that document.

---

## 2. Scope

### IN — one unit, six bites

From `.claude/sprint-b/design/D1-phase3-routes.md` §5/§7, refreshed by `QUEUED-p3-first.md` §3:

| bite | statable as | note |
|---|---|---|
| `B-2.2-a` | 2 sites + a compiler-enumerated error set | `Route`'s payload becomes identity-bearing; absorbs AD-1's `Option` ruling |
| `B-2.2-f` | ~7–9 sites, one file | mark appended super slots so identity can be WITHHELD. **Lands before `b1`** |
| `B-2.2-b1` | 4 sites | stamp identity at the four `inst` arms, **from the selector's ROW** |
| `B-2.2-e` | 9 sites | paired definition-side key derivation. **Must land WITH `b1`** |
| `B-2.2-b2` | 2 named pairs | collapse the double selection at **D3 and D4 only** |
| `B-2.2-c` | 5 sites, comment-only | precedence assertions on the non-`inst` discharge kinds |

### IN — one adjudication, no implementation

**The `D2 §3` carrier escalation**, ruled by the architecture companion and written to
`DECISIONS.md`, then filed to #1113. It is a ruling, not a design run, and it is cheap now while
the reasoning is loaded. The finding: RUN-B-013 ruled Phase 4's carrier a *"5th positional
`CProgram` field"*, but `lowerProgram` is the **untyped shared path** used by nine probe drivers
that have no table — so an empty table is indistinguishable from an absent one and RUN-B-013's
fail-closed condition 1 collapses either way. The escalated recommendation is a **two-valued
type** (`Option <table>` or `CAdmisAbsent | CAdmisTable …`). **Rule it; do not build it.**

### OUT — and each with its reason, so it can be overturned

- **Phase 4 (`B-2.3`) implementation** and **Phase 5 (`B-2.4`)**. One IR-moving evidence rewrite
  per sprint. Two rewrites over the same organs with deferred goldens reproduces the F-3 failure
  the design doc names: CI cannot say which half moved a golden.
- **Designing Phase 4 concurrently.** Ruled out by measurement, not taste: the audit put
  design-ahead's rework rate at **75%**, and D1's own line numbers had drifted **~+530** before
  anyone used them (a further ~+50 since — see §4).
- **B-1 (#993).** The Stage B ruling's three reasons are untouched by anything that landed, and
  AD-1 explicitly leaves the two-constructor route presumption intact.
- **#1610** (nightly `perf_scaling` DEEP red since 08-10, bisect owed). Real and untriaged, but
  it is a lint-stage perf issue with no typechecker coupling. Out-of-band.

### Issue-closure policy — unchanged

**Implement; do not close.** A drained pin is drained, not closed. **But desk closes are now an
EXIT CRITERION** (§8) — Stage B verified #991 and #1114 done in Phase 0 and then let the tracker
lag the tree for weeks.

---

## 3. What is already settled — do NOT re-derive

Anything in this section that a Phase 0 agent contradicts should be reported as a finding, not
quietly worked around.

1. **AD-1's D8/D9 ruling** (§1) and its `Option`-on-`RKey` consequence.
2. **`B-2.2-b1` is CHEAPER than D1 priced it.** D1 §5 made a row-returning selector 3′'s
   precondition and warned 3′ stops without it. `ieSelectRowByMethod` / `ieSelectRowByIface` both
   return `Option ImplRow` and take `env` explicitly; `keyForSite` is a **6-line pure projection**
   over them. So the stamping arms call the row-returning selector directly and project the word
   themselves — **no re-signature of `keyForSite`, and no second scan**, which retires
   RUN-B-023's +17% `check-self` cost as this bite's justification. *An implementer handed D1
   verbatim will read `keyForSite : … -> Option String` and wrongly conclude 3′ stops.*
3. **D4 is the recursion hub**, not `argReqRoute` — which selects nothing and is a `routeOfD` →
   `entail EKNestedTop` adapter. A `b1` implementer's `nearest miss:` must therefore be
   **nesting-depth ≥ 2**.
4. **`b2` excludes D5/D6.** Their element helpers select on a `name` the caller passes
   (`innerDefaultMethod` / `dictMethod`); collapsing there is a semantics change.
5. **`CSlot`'s header is single-line** (`typecheck.mdk:5843`, re-verified at `983e5dd0`), so
   `B-2.2-f`'s commented field addition is in #829's measured-safe class. ⚠️ Re-check the shape on
   the day anyway; do not trust this line.
6. **The `RKey` site set is 6 construct + 2 destructure**, re-derived at `983e5dd0` (§4).

---

## 4. Phase 0 — the refresh, and the five questions it owes

**Small and read-only. The design exists; Phase 0's job is to refresh it against the tree and
answer what nobody has.** Two to four concurrent read-only agents, no writers live, nobody
rebuilds the binary.

### The refresh, already started

Re-derived by the orchestrator at `983e5dd0` — **the drift since the packet's `6ec0111a` pin is
~+50 lines and the shape is unchanged**:

```
RKey construct: 15726 · 19720 · 19748 · 19773 · 19900 (D8) · 20161 (D9)
RKey destructure: 20287 · 20454                                    (6 + 2 = 8, as D1 §3.2)
routeUndeterminedTop : 19889   resolveRecMono : 20159   data CSlot : 5843 (single line)
ieSelectRowByIface : 19041     ieSelectRowByMethod : 19049   (both -> Option ImplRow)
keyForSite : 18430             keyForSiteByIface : 19109     (both -> Option String)
```

Phase 0 re-runs these at the branch pin and **stops the sprint if the shape moved**, not just the
numbers.

### The five owed questions

- **Q1 — the `keyTable` residue.** `KeyBuckets` survives as a *type* with **86 occurrences** and
  `keyTable` is still threaded through **91**, live for the nested-`requires` re-bucketing
  (`typecheck.mdk:19397`'s own comment). `EX-1` deleted the two Refs and thirteen bindings; it did
  not delete this. **Does `B-2.2` retire the last of it, or does it survive into Phase 5?** A
  second surviving population that still decides something is exactly this arc's S0 shape — and
  `routeUndeterminedTop`'s signature still takes `KeyBuckets` while AD-1 rules its site never
  stamps. Derive; do not assume either answer.
- **Q2 — `B-2.2-e`'s nine sites.** `OWED` since the packet: they are in `core_ir_lower.mdk`,
  `eval.mdk`, `typecheck.mdk`, and only the last was read. `grep -n
  'declRouteKey\|ifaceRouteKeysGo\|ifaceDeclHeadUnique\|ifaceImplHeadEntries'` in the first, and
  `'implMethodEntry\|declImplIfaceIdRow\|implKeyOf'` in the second.
- **Q3 — the `noneHeadTag` general-fallback tier.** `keyForSite`'s neighbouring comment calls the
  behaviour surviving this IR change **"EMPIRICAL, not structural"**. That is the tree's own
  warning, relayed twice now and never re-derived. **It needs a build.** It is `b1`'s real risk.
- **Q4 — `CSlot:26089`'s inferred-id mint.** D1 ruled all three non-`superSlotOf` mints
  "declared = True"; the packet confirmed the *sites*, not the ruling. `f` depends on it.
- **Q5 — the P4 tripwire.** `.claude/sprint-b/repair/R3-c4i2.md` F-4: organ 4's copied-route
  invariant is **a premise Phase 3′ falsifies**, and P4 is green today *because dict words are
  still bare tags*. **This must be a named bite's owned consequence, or the run mints a DICT C2
  violation with no gate watching.** Assign it to `f` or `b1` explicitly in Phase 0.

**Deliverable:** `.claude/sprint-phase3/DECISIONS.md` entries, each with its derivation, plus a
GO/NO-GO on the bite order `f → b1+e → b2 → c` (with `a` first).

---

## 5. Phase 1 — implementation

**One implementer live at a time**, in the trunk worktree, on disjoint named regions
(STAGE-B §3/§4). Order: **`a` → `f` → `b1`+`e` (one landing) → `b2` → `c`.**

`a` and `f` both precede `b1` for different reasons: `a` because the payload type must exist
before anything stamps into it, `f` because withholding must be expressible before identity flows
down the recursive fill path.

Every bite's `DEBT.md` row carries `sites:` / `transform:` / `could move:` / `nearest miss:` /
`engines:` / `unchecked:`. None may be blank. **`engines:` matters even though this unit is
mostly `typecheck.mdk`**: `B-2.2-e`'s definition side reaches `core_ir_lower` and `eval`, and D1
§8.7 already caught a design that omitted `core_ir_eval`'s own `VTypedImpl` producer — the P0-9
shape, in this very unit.

**Integration checkpoint** after roughly every three bites: `make medaka && make check-self`,
plus a backgrounded `sh test/preflight.sh`. Detached and polled — preflight forces the fixpoint on
backend-adjacent diffs and exit 143 at 600s is the harness ceiling, not a hang.

---

## 6. Phase 2 — the in-band close-out

Not deferrable, because **this unit changes emitted IR**:

1. `test/refresh_seed.sh` **run TWICE** — it is not idempotent after a codegen change, and a stale
   seed segfaults the fixpoint on a perfectly correct change.
2. `sh test/selfcompile_fixpoint.sh` green on the twice-refreshed seed.
3. **The goldens, re-cut exactly once, from the final binary** — snapshot + `selfproc_legA`
   (+ `llvm_typed_ir` if it moves; it did not in Stage B, and that green proves less than it
   looks). Never merged, never hand-resolved; on any rebase, take base's version of both families
   and re-derive.
4. `EX`-equivalent: **re-show the drain claims on the final binary**, twice, quiescent.

---

## 7. Phase 3 — the repair round (MANDATORY)

**Budgeted up front, not discovered.** Both prior sprints introduced S0/S1s mid-run; **every one
was caught here and zero were caught by gates.** Stage B's worst was a loud compile-time refusal
turned into an exit-0 build of a crashing binary — green on every check that ran.

Standing agenda, in priority order:

1. **Work `DEBT.md`'s `could move:` and `nearest miss:` columns.** This is what produced the
   attack lists that found the regressions in both sprints.
2. **The base-vs-branch differential** (FX-2's instrument, now proven): N programs × 4 channels ×
   2 arms, **graded on the built binary's stdout, not exit codes** — two of Stage B's four known
   differences had identical exit codes on both arms in every channel.
3. **The C4/I2 conjunction question, asked again at the end**, on a hand-derived permutation
   differential: same instance set *and* same evidence. Include **P4** (Q5) explicitly.
4. **Engines.** eval is a known-wrong oracle on exactly the shapes this unit moves; hand-compute
   every moved golden's winner with its DICT clause cited.

### Two audit deltas that bind this round specifically

- **A `DEBT.md` row is owed for any delta the differential DETECTS**, not only ones an implementer
  recognized — written by the round that found it, at detection time. Stage B landed a real
  acceptance regression with no row anywhere.
- **A probe whose verdict gates the merge must be LANDED** — fixture, gate, or committed script.
  FX-1's 589→0 order-invariance number lives in prose and session scratch. A number nobody can
  re-run is a claim, not a record.

---

## 8. Exit criteria

The sprint is done when, and only when:

1. Every in-scope bite is landed; the tree builds and self-typechecks.
2. The self-compile fixpoint is green **on a twice-refreshed seed**.
3. The goldens are re-cut once, from the final binary, each moved family with a hand-derived
   justification.
4. The repair round has run and its findings are either fixed or filed.
5. **Every verified desk close is executed or handed to a named owner** — new this sprint,
   costs minutes, and its absence is what let the tracker lag the tree after Stage B.
6. The `D2 §3` carrier ruling is written to `DECISIONS.md` and filed to #1113.
7. The PR title's severity claims match the body's own table.

---

## 9. Deltas from the inherited protocol

- **Sole occupancy is NARROWER than Stage B's.** This unit owns `compiler/types/typecheck.mdk`,
  `compiler/frontend/ast.mdk`, and — for `B-2.2-e` only — `compiler/ir/core_ir_lower.mdk` and
  `compiler/eval/eval.mdk`. It does **not** own `llvm_emit.mdk` or `wasm_emit.mdk`; those are
  Phase 5's. Confirm no scheduled agent is pointed at the four before Phase 0.
- **Records live in `.claude/sprint-phase3/`.** Do not write into `.claude/sprint-b/`; its
  contents are a frozen record cited by the Stage B PR.
- **Phase 0 is small.** Stage B's Phase 0 was seven parallel design packets because nothing was
  designed. Here the design exists and has been refreshed twice — Phase 0 is a verification pass
  plus five questions, and an orchestrator who grows it back into a design fan-out has re-bought
  the 75% rework rate the audit measured.
- **One Fable consult is available** for the C4/I2 conjunction question in the repair round
  (broad-semantics work is what it is for). Not for the bite cutting.
