# Stage B / Phases 4 + 4b — DECISIONS ledger

Contract: `.claude/STAGE-B-PHASE45-SPRINT.md`. Predecessor records: `.claude/sprint-phase3/`.

**BASE pinned at sprint open:** `aaa43716` (`git rev-parse HEAD` in
`/root/medaka/.claude/worktrees/peppy-brewing-kitten`, 2026-08-14). `origin/main` moves under this
worktree — every worktree shares one `.git` — so diff and checkout against `$BASE`, never a ref.

**Shape of the sprint after the §2b adoption:** Phase 0 → **Phase 4** (`B-2.3` frozen
admissibility) → **Phase 4b** (selector re-key, #1182) → **one** close-out. Phase 5 is CUT and
routed to #1403 (X-E.C).

---

## RUN-P45-001 — Exit criterion 0 is DISCHARGED. Verified first-hand, not inherited.

The sprint doc asserts it; a claim in a doc is not a verification. Re-derived at `aaa43716`:

| requirement | evidence |
|---|---|
| ruling recorded on **#1113** | last comment `2026-08-14T06:21:47Z`, val-grasley, *"OWNER RULING (2026-08-14) — B-2 ends at Phase 4 + a new Phase 4b. Phase 5 is CUT and routed to #1403 (X-E.C)."* |
| ruling mirrored on **#1403** | last comment `2026-08-14T06:21:52Z`, val-grasley, *"X-E.C **inherits** route-word / `KeyBuckets` retirement. The typechecker arc's `B-2.4` is CUT."* |
| reciprocal pointer in the arch doc | `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1436` — *"🚨 **Emitter-arc coordination — this arc HAS a downstream consumer, and until…"* |
| **#1182 REOPENED** | `gh issue list --state all` → `1182 OPEN` |

⇒ Phase 0 does **not** re-adjudicate §2b. It opens on the design run.

## RUN-P45-002 — Tracker state at sprint open, derived (not quoted from the doc)

`gh issue list --state all`, filtered. All twelve are **OPEN**: #1068 · #1113 · #1182 · #1265 ·
#1403 · #1608 · #1617 · #1618 · #1619 · #1620 · #1621 · #1622.

Notably #1182 is open, so the doc's *"blocking tracker correction"* is already discharged; and
#1113 is open, so nothing desk-closed itself during the Phase 3′ sweep this time.

## RUN-P45-003 — Phase 0 packet set, and why these four

Phase 0 is all **readers** ⇒ parallelized (the standing rule is PARALLELIZE READERS, SERIALIZE
WRITERS; Stage A ran 3-5 concurrent *writers* and paid with four contaminated measurements and
~4 bites of rework). No writer is live during Phase 0.

| packet | owns | output |
|---|---|---|
| **P0-A** | The Phase 4 design run — Phase 4 has no design doc, and concurrent design-ahead was ruled out by measurement (75% rework rate). Also owes the **Q2** render-vs-omit derivation and the **Q3** scoped-key fixture design | `phase0/P0-A-phase4-design.md` |
| **P0-B** | **Residual 1 — the 4b SUPPLY question.** The ruling sizes 4b as "one line given an interface"; whether an interface is *in hand* at each `*ByMethod` site is unsettled and is the design run's first question. An `IMPOSSIBLE HERE` verdict at any site falsifies the sizing | `phase0/P0-B-4b-supply.md` |
| **P0-C** | **Q7 — the `_ => None` arm SET.** If Phase 4's table keys on a head function that returns nothing for three type shapes, the table under-discriminates *by construction* and freezing it freezes that. Verdict owed: Phase 4 **precondition** or independent unit | `phase0/P0-C-armset.md` |
| **P0-D** | The **pre-fix drain baseline** (#1182/#1617/#1618/#1619/#1620/#1608, both permutations each) + **Q5** (#1608's harness, still unowned) + the permutation-instrument survey | `phase0/P0-D-drain-baseline.md` |

**Why the baseline is a Phase 0 deliverable and not a close-out one:** exit criterion 3 demands
the drains be graded on the final binary and that the report say whether each drain is *causal or a
shape move*. That distinction is unrecoverable without a pre-fix observation captured on a binary
built from the unmodified base. Captured at `aaa43716`.

Binary for P0-D: `/root/medaka/.claude/worktrees/peppy-brewing-kitten/medaka`, cold-bootstrapped
from `compiler/seed/emitter.ll.gz` at `aaa43716`, `make medaka` exit 0. No emitter was borrowed
from a sibling tree.

## Open — to be ruled at the close of Phase 0

- **Q2** — render or omit the 5th `CProgram` field in the S-expr. ORCH rules on P0-A's derivation.
- **Q3** — the scoped-key proof fixture, and the full set of gates that fixture directory enrolls it in.
- **Q5** — which harness carries #1608. ORCH rules on P0-D's sizing. ⚠️ residual 3 of the adopted
  ruling says #1608 *"needs its own owner call; this ruling does not make one."*
- **Q7** — arm set: Phase 4 precondition or rides with 4b. ORCH rules on P0-C's verdict.
- **4b sizing** — one bite or many, contingent on P0-B's supply verdict.

---

## RUN-P45-004 — P0-C: the arm set. **The sprint doc's membership is WRONG, and I verified it myself.**

P0-C returned `PRECONDITION`. Before relaying any of it I re-derived the two structural claims
first-hand — a relayed citation is a claim I am re-asserting.

**Derived by ORCH at `aaa43716`:**

`compiler/types/typecheck.mdk:19452-19456`
```
headTyconTy : Ty -> Option HeadKey
headTyconTy t = match headTyNode t
  TyCon { tyConName = n, tyConOrigin = o } => Some (headKeyOfCon o n)
  TyTuple ts => Some (headKeyOfCon OriginBuiltin (tupleHeadTagTc (listLen ts)))
  _ => None
```
`headTyNode` (`:19433-19435`) unwraps `TyApp` only. `public export data Ty` (`compiler/frontend/ast.mdk`)
has **eight** constructors: `TyCon` · `TyVar` · `TyApp` · `TyFun` · `TyTuple` · `TyEffect` ·
`TyConstrained` · `TyRow`.

⇒ the catch-all swallows **five** shapes. The honest accounting — which is neither the doc's nor,
exactly, P0-C's:

| shape | status | evidence |
|---|---|---|
| `TyVar` | **correct by design** — a fully-general `impl C a` head *is* headless | `typecheck.mdk:18395` |
| `TyFun` | **defect, filed** #1617 (S0) | — |
| `TyEffect` | **defect, filed** #1618 (S1) | — |
| `TyConstrained` | **measured NOT a defect** | #1617 body: *"A third candidate arm, `TyConstrained`, was **measured NOT to be a defect** … The live set is two."* |
| `TyRow` | **UNKNOWN — unfiled, unnamed anywhere** | added by #997; probe dispatched as **P0-E** |

🚨 **The sprint doc (§4 Q7) says the arm swallows three things — `TyFun`, `TyEffect`, and
`TyConstrained` "unfiled by ruling, named in both bodies".** It kept #1617's citation and **inverted
its polarity**: #1617 names `TyConstrained` to *bound the class at two*, not to extend it to three.
And the doc **misses `TyRow` entirely**. So the one instruction Q7 gives — *"audit the arms as a
SET"* — was itself handed a wrong set, in a section whose own text quotes Phase 3′'s retrospective:
*"I wrote 'audit the arms as a SET' and then shipped a set one arm short."* **It happened again, in
the sentence warning about it.**

This is the `##REFUSALS`-earns-its-keep case: the brief relayed the doc's "three" and the analyst
refused it. Correct the doc at close-out — it is ungated prose and it is what the next agent reads
first.

**Verdict deferred, and P0-C says exactly why (its R-1):** the arm set is a Phase 4 **precondition
IFF** Phase 4 computes admissibility from `IE`'s head-keyed buckets (`univReceiverTag → headTyconTy`,
`:22574`), and an **independent unit** if Phase 4 computes it structurally from `implTys`. That
choice is P0-A's to derive. **Do not rule Q7 before P0-A lands.**

Corroborating mechanical fact, worth keeping: `headBucketKey None = headlessBucketKey` (`:18388`),
whose own comment (`:18391`) calls it *"the bucket holding the fully-general (`impl C a`) entries."*
Every swallowed shape lands in a bucket that documents itself as containing only fully-general
entries. Four of the five are not.

---

## RUN-P45-005 — 🚨 P0-B: the adopted ruling's SIZING IS WRONG, and the "weak" fix is a loud→silent move

**Two claims verified by ORCH first-hand before relay**, because this one contradicts the ruling
that shaped the sprint:

**1. The `*ByIface` peer family is keyed by NAME, not identity.** Derived:
```
compiler/types/typecheck.mdk:19119
ieEntriesForIface : List ImplRow -> String -> List Mono -> List KeyEntry
```
The interface parameter is a **`String`**, and the body's guard compares `ir.irName`. So §2b
derivation 2 — *"the interface-keyed peer ALREADY EXISTS"* — is true of a **name**-keyed peer and
**false of the `module::Iface` identity** that §3's Phase 4 constraint demands. **The ruling's
central derivation does not reach its own requirement.**

**2. The only available supply is itself the bug.** `ifaceOfMethodName` (`:24507`) reads
`methodIfaceParamsRef`, whose own header (`:2327-2338`) states verbatim:

> *"BOTH forms pick by REGISTRATION ORDER, and neither picks by what the occurrence resolved to — so
> on a bare-name collision between two unrelated interfaces this table hands
> `recordImplObligation` / `ifaceParamMonos` the **WRONG INTERFACE, silently, in either direction
> (S0)**."*
> *"The FLAT path is unchanged and still last-write-wins."*

⇒ **The re-key does not remove the order dependence; it moves it from `impl`-block order to
`interface`-block order.** #1182's pin drains and the S0 class survives, under a permutation **no
gate performs**. That is precisely the severity-increase shape this repo's own ladder forbids: a
fix that makes a defect quieter reads as progress because the loud signal disappears.

⚠️ **Consequence for 4b's deliverable set:** an **interface-permutation control** is not a
nice-to-have. Without it 4b certifies its own blind spot — the drain "passes" against the only
permutation anyone runs. Cf. *"a verification probe must be ABLE to fail."*

⚠️ **Contradiction inside the source worth flagging, not yet adjudicated:** that same header claims
*"a module's scope binds a bare method name to at most one declaration — resolve rejects the
ambiguous case outright."* #1182's repro is two interfaces in ONE file and `check` is **clean**. The
comment and the filed S0 cannot both be right. P0-B's finding 2 (`Ident = Ident Ns IdentOrigin
String`, `ast.mdk:310` — module-scoped, no interface component, so both interfaces in one module
mint the SAME `Ident` and the scope-override machinery reports "no collision" and never runs)
explains how. **Not yet ORCH-verified — do not relay it as settled.**

**Sizing, per P0-B:** 3 bites under WEAK (permutation control FIRST, then the `keyForSite` repoint,
then striking `ieImplExistsForHeadGo` as an existence test rather than a selector); 4 under STRONG,
where the fourth is a **design run** — ≥3 files, ≥8 signatures, and a new AST field, because
`EMethodAt`/`EMethodRef` carry a bare `String` minted from a name at `frontend/marker.mdk:90`.
**Either way, not "one line".**

**P0-B disagrees with the doc on two drain targets** — reported as its claims, NOT ORCH-verified:
- **#1619 NOT drained** — both colliding interfaces are spelled `Tag`, and `ieEntriesForIface`
  compares names, so the re-key is a literal no-op there.
- **#1620 UNVERIFIABLE** — the issue itself records *"the mis-selecting site is unknown"*, and its
  symbols are already correct and distinct.
It agrees with the doc on #1617 (arm set, not selector) and #1608 (`core_ir_eval`, untyped path).

⇒ **Of the four drain targets the ruling declared "typecheck-only, so cutting Phase 5 defers not a
single S0", at most two survive contact.** That premise needs an owner ruling, not a repair.

---

## RUN-P45-006 — P0-A, and the fact that RECONCILES P0-A with P0-B. Derived by ORCH.

P0-A reached P0-B's conclusion **independently** — `ieEntriesForIface` filters on a bare spelling.
Two independent derivations agreeing is worth something; two agreeing because they read a common
prefix is not, so ORCH re-derived the primitive:

```
compiler/types/typecheck.mdk:5794
public export data IfaceRef = IfaceRef {
    irName : String,  -- the SPELLING; still needed for diagnostics and for the spelling-keyed KeyBuckets question
    irOrigin : TyConOrigin,  -- the I4 identity of the declaration this occurrence denotes
  }

compiler/types/typecheck.mdk:19121
  | ir.irName == iface && ieRowHeadMatches tys goals = keyEntryOfRow r
```

🎯 **The identity is on the row and the filter compares the spelling.** This dissolves the apparent
P0-A/P0-B conflict over sizing — they were describing different sides of the same seam:

| side | identity available? | evidence |
|---|---|---|
| **impl row** | ✅ **YES** — `ImplRow → IfaceRef.irOrigin` | `:4074`, `:5794` |
| **query / call site** | ❌ **NO** — callers pass a bare `String`, sourced from `ifaceOfMethodName` → `methodIfaceParamsRef`, itself the S0 | `:19119`, `:24507`, `:2327` |

⇒ **STRONG 4b is blocked on the QUERY side only.** P0-B's ≥3-files/≥8-signatures/new-AST-field
estimate is a claim about the query side and may be right; P0-A's *"only the interface half of the
key is bare"* is a claim about the row side and is verified. Neither is a refutation of the other.

**P0-A's other findings, relayed as ITS claims (ORCH-verified only where marked ✅):**
1. **Phase 4 is a RELOCATION, not a re-key.** Arg-tag admissibility is not in `compiler/types/` at
   all — it lives in `eval.mdk` (`buildIfaceDispatch`, `dispatchPositionsOf`, `lookupPositions`),
   consumed at exactly two sites: `eval.mdk:1976` and `core_ir_lower.mdk:1409` — **the known
   `evalModules`/`cevalModules` lockstep pair.** It is *already* computed once and frozen, so the
   design doc's stated justification (*"stop re-deriving per call site"*) is false; the real
   justification is the key plus two **fail-OPEN** defaults (`lookupPositions _ _ [] = [0]`,
   `keepOrAll original [] = original`).
2. **`CProgram` has 29 construction sites, not AD-2's 13** — 23 in
   `compiler/entries/wasm_emit_typed_main.mdk`, **the file PR #1623 / X-W is actively rewriting.**
   Any site list over it has a shelf life of days.
3. **Q2: the sprint doc's silent-wrongness hazard DOES NOT REPRODUCE.** `parseCProgram` has exactly
   one consumer (`core_ir_roundtrip_main.mdk:30`) and it lowers via the untyped path, so the field
   is `CAdmisAbsent` before *and* after the round trip. Recommends rendering behind the existing
   `faithfulRoutesRef` flag, default off.
4. **No seam channel.** No import edge either way between `typecheck.mdk` and `core_ir_lower.mdk`;
   all three elaboration entry points return `List Decl` only (`:14538`, `:14566`, `:28990`).
   AD-2's *"one hop, no branch"* is right about the signature and **silent about the supply**.
5. Q7: **PRECONDITION** — agreeing with P0-C. ⚠️ But P0-A repeats the sprint doc's WRONG arm set
   (includes `TyConstrained`, misses `TyRow`). **RUN-P45-004's set is the authority, not P0-A's.**
   P0-A does contribute one fact worth keeping: eval's `headTycon` (`:513-519`) *already* strips
   `TyConstrained`/`TyEffect`, so **"mirror the arms across the two files" would be WRONG** — the
   two sides need different arm counts.

---

## RUN-P45-007 — ⭐ THREE OWNER RULINGS (Val, 2026-08-14). These supersede the adopted §2b sizing.

Asked once, with the full Phase 0 picture, rather than twice with partial data.

### Ruling 1 — **Phase 4b does the STRONG fix: identity-keyed selection. In-sprint.**
Not the name-keyed repoint. The `*ByIface` repoint is rejected **as a fix** because it moves the
order dependence from `impl`-block order to `interface`-block order — draining #1182's pin while the
S0 class survives under a permutation no gate performs. Design run dispatched as **P0-G**.

### Ruling 2 — **Hold the writer for P0-E; ship the arm set COMPLETE.**
The arm set is a Phase 4 precondition under both P0-A and P0-C and drains #1617 + #1618 on its own,
so it is the obvious first writer — but its membership is still open pending P0-E's `TyRow` verdict.
Shipping it one arm short is the exact failure Phase 3′'s retrospective records **and which the
sprint doc then committed in the sentence warning about it** (RUN-P45-004). Writer stays idle until
P0-E lands. Val accepted the idle cost explicitly, against her own standing *"always keep a writer
live"* directive — recorded here because it is a deliberate exception, not a lapse.

### Ruling 3 — **AD-2 is RE-OPENED as a Phase 0 deliverable.** Dispatched as **P0-F**.
Three of its factual premises are measurably wrong at HEAD (13→29 sites; "one hop, no branch"→no
edge at all; admissibility in `types/`→ in `eval.mdk`). The *reasoning* — fail-closed, two-valued,
`Option` rejected — is not what is re-opened and survives unless P0-F shows otherwise.

### 🚨 ORCH consequence Val did not have to rule on, stated here because it is mine to call

**Ruling 1 REINSTATES the mitigation §2 declared "simplified" away.** The doc dropped the
two-close-out requirement on the reasoning that *"with Phase 5 cut there is one IR-moving rewrite
again, so the standing one-per-sprint rule is satisfied."* **STRONG 4b is a second IR-moving
rewrite over the same organs.** The premise for simplifying is therefore void, and the original
mitigation binds again:

> **Phase 4 takes its OWN terminal close-out — goldens re-cut exactly once, seed re-minted TWICE,
> fixpoint C3a+C3b — BEFORE 4b opens a single bite.**

Two IR-moving rewrites with deferred goldens is the F-3 failure by name: CI cannot say which half
moved a golden. ⚠️ **Unless P0-F or P0-G returns "4b must land BEFORE Phase 4"** — both are asked
that question explicitly — in which case the ordering flips and the checkpoint goes between them in
the other direction. The checkpoint itself is not optional either way.

**Also newly in scope from ruling 1:** STRONG 4b may add a field to `EMethodAt`/`EMethodRef`. Per
`AGENTS.md`'s task-playbook routing that makes it **add-language-feature**, not
`harden-typechecker` — and it lands squarely in the *"ADDING A PROGRAM-GLOBAL TABLE OR A NEW AST
CONSTRUCTOR"* trap, whose required fixture is **"feature + UNRELATED code still behaves"**, not
"feature works". P0-G is briefed on it.

---

## RUN-P45-008 — P0-D: the pre-fix drain baseline. **All six reproduce.** Plus one escalation.

Captured at `aaa43716` on the cold-bootstrapped binary, `MEDAKA_STRICT=1`, redirect-then-read-`$?`
throughout (never a pipe — `build`'s exit code does not survive one). Env verified free of
`MEDAKA_ROOT`/`MEDAKA_EMITTER`, which would silently cross the arms. Full cell table in
`phase0/P0-D-drain-baseline.md`; **that table is the authority for exit criterion 3.**

| issue | reproduces | note |
|---|---|---|
| #1182 | ✅ both permutations | `run`/native answer `1` vs `2` by impl order; `check` silent, exit 0 |
| #1617 | ✅ both permutations | `ab`→`(5,5)`, `ba`→`(9,9)`, control `(5,9)`; `build` exit 1 + E-PANIC |
| #1619 | ✅ | `(100,100)` where `(7,100)` is correct — **both import orders AGREE at the wrong answer** |
| #1620 | ✅ **and worse than filed** — see RUN-P45-009 | |
| #1608 | ✅ | eval + native correct and order-invariant; `cevalModules` prints `boxint` in permA |
| #1618 | ✅ | byte-identical E-PANIC; control builds |

🚨 **THE FINDING THE DRAIN GRADER MUST NOT MISS: three cells already AGREE pre-fix** — #1619 in both
orders, #1618 in both orders, #1608's permB. **Post-fix agreement therefore proves nothing on those
cells; grade the VALUE, not the agreement.** #1608's permB is *accidentally correct*, so a
single-ordering probe would have reported it fixed. This is the "absence probes cannot see undercount
bugs" shape and it is pre-loaded to fool exit criterion 3.

**Two corrections P0-D makes to the record, both derived:**
- #1608's body says swapping flips *"both answers"*; measured, **only the `cevalModules` arm moves.**
- Q5 clause 3 (*"the only driver that reaches the broken arm is `core_ir_modules_main.mdk`"*) —
  **two** entries reach `cevalModules`, `profile_eval_main.mdk` as well. The conclusion survives
  (that one is a single-file untyped *timing* driver), but the clause as written is wrong.

## RUN-P45-009 — ⭐ #1620's BA permutation SEGFAULTS. ORCH-reproduced, and now filed.

P0-D ran a permutation the issue never did. **ORCH re-derived it independently** rather than relaying
it — a new failure mode is a filing, and a filing needs its own proof:

```
check    -> exit 0    "ok (1 declaration(s) checked, 0 errors)"
build    -> exit 0    "built ba.mdk -> ba.bin"
./ba.bin -> exit 139  runtime error [E-FATAL-SIGNAL]: fatal memory fault (segmentation fault)
```

Swapping only the two **interface** declarations. **The existing pin covers the AB ordering only, so
BA is graded by nothing** — a fix validated against the current fixture can leave this segfaulting
and still read green.

⇒ The two orderings are not "the bug and its mirror": they are **two failure modes of one
mis-selection**, one silent (AB: raw word at exit 0) and one fatal (BA). Reporting either alone
understates the class.

**Filed** as `#1620 issuecomment-5290657940`, with the readback verified (a `gh` write that silently
no-ops is a known shape here). Nothing closed. **Ask on the record: extend the pin to the BA
ordering** — a repair-round deliverable for this sprint.

## RUN-P45-010 — ⭐ RULING (ORCH): Q5 goes to **Option B**, a typed multi-module Core-IR gate.

The decision was Val's to delegate and the cost fact is decisive, so ORCH rules it. **Verified
first-hand** rather than taken from the packet:

```
.github/workflows/ci.yml:701
pattern: "'diff_compiler_eval*' 'diff_compiler_core_ir*' ... "
```

⇒ a gate named `diff_compiler_core_ir_typed_modules.sh` **matches an existing shard pattern**, so it
needs **no `ci.yml` edit and no `test/CI-COVERAGE-EXCEPTIONS.txt` row** — which is otherwise the
tax on every new `test/*.sh` (a `.sh` matching no shard SILENTLY NEVER RUNS, and
`diff_compiler_ci_shard_coverage.sh` reds the tree for it). It also lands in `eval`, the cheapest
shard.

Rejected: **Option A** (a fourth arm on `diff_compiler_engines.sh`) — that is the POLE shard *and*
the arm would still drive the untyped path. **Option C** (a new `run_verb`) — breaks the must-fail
harness's shipped-binary invariant and is likewise still untyped.

⚠️ **Why "still untyped" is disqualifying, not a nitpick:** the one gate that runs `cevalModules`
today (`test/diff_compiler_core_ir_modules.sh`) drives desugar + annotate with **no marker and no
typecheck**, so **no `Route` is ever stamped** — it cannot distinguish a correct route word from no
route word at all. **Its green proves nothing in either direction.** A gate must RUN where the bug
lands.

**This also unblocks the permutation ledger.** None of the six shapes is currently a fixture in
`test/import_order_fixtures/`, and #1608 — the one that most belongs there — **cannot be filed as a
row today**: all five signature cells are invariant across its orderings while only `cevalModules`
flips, so the fixture would pass as INVARIANT. **A fixture that passes for the wrong reason is worse
than no fixture.** Option B is what makes that row legal.

⚠️ Also confirmed: `test/diff_compiler_import_order.sh` has **no wasm arm** (one `wasm` hit, line
505, an unrelated comment). That remains inherited by X-E.C, not this sprint's to fix.

---

## RUN-P45-011 — P0-E: `TyRow` is **REACHABLE, NO DEFECT**. The arm set closes at TWO.

`TyRow` does genuinely land on `headTyconTy`'s `_ => None` arm: one producer (`mkRow` ←
`parseBareEffectAtom` ← `parseTyAtom`'s `TLt` arm), and `implRest` parses an impl head vector with
`many parseTyAtom`, so `impl Foo <Stdout>` puts a bare `TyRow` in the slot `keyEntryOfRow` hands to
`headTyconTy`. It is the only route — a `TyApp` spine can never be *headed* by a `TyRow`, since a
leading `<…>` in full type position goes to `parseEffectTy` → `TyEffect`.

**But it is guarded twice, either guard sufficient:**
1. Every spelling is rejected **loudly at exit 1** with a located `T-ROW-KIND-MISMATCH` from
   `fromAstTypeE`'s `TyRow` arm — in `check`, `check --json`, `run` and `build`, in **both** impl
   permutations, with no binary emitted. Control with a `TyCon` head exits 0.
2. Even as a candidate it is unselectable: the scary-looking `tyIsConcrete (TyRow…) = True` and
   `tyStep (TyRow…) _ = MOk` arms are **dead**, because dispatch matching runs through `matchStep`,
   a different function with no `TyRow` arm, ending in `matchStep _ _ = MFail`. A discriminating
   probe (row impl alone; goals `Bool`/`Int`/`Unit`) captured **nothing** — ruling out the
   `TCon "Unit"` recovery hypothesis too.

Tracker searched (`TyRow`, `997`): nothing covers a row impl head or `headTyconTy`. **Nothing to
file.**

⇒ **#1617's *"the live set is two"* stands.** ORCH's RUN-P45-004 left `TyRow` open as possibly a
fourth member; it is not. **The sprint doc's error was membership, not size**: it named
`TyConstrained` (a measured non-defect) as the third member and omitted `TyRow` (a real
catch-all resident that happens to be harmless). Both halves of that are still worth correcting in
the doc — a reader who fixes the doc's three arms would change a non-defect and miss nothing real,
but would also be reasoning from a false map.

**Ruling 2's condition is DISCHARGED.** The set is complete and known. Writer released.

---

## RUN-P45-012 — W1 dispatched: the arm-set bite. First and only writer live.

Isolated worktree, cold-bootstrapped (explicitly forbidden from borrowing an emitter — the `cp` that
trips the isolation classifier is stateful and has cost a full session). Scope: `TyFun` (#1617) +
`TyEffect` (#1618) **only**.

Three hazards written into the brief, each from a Phase 0 finding:
1. **Do NOT mirror the arms across files.** eval's `headTycon` already strips
   `TyConstrained`/`TyEffect` while `headTyconTy` does not — the asymmetry IS #1618's mechanism, so
   equalising the two sides would be the wrong fix.
2. **Impl side and goal side must land together.** Fixing only the impl projection makes the impl
   *unreachable from the goal side* — a partial fix manufactures a NEW defect.
3. 🚨 **Unresolved design question handed over as the FIRST task, with explicit licence to refuse:**
   what tag does a `TyFun` head carry? Currying means a single `__fun__` tag may **not** drain
   #1617 — two distinct function-headed impls would still collide. `tupleHeadTagTc`'s arity-bearing
   tag, in the same function, is the nearest precedent. **Resolve with evidence or refuse.**

Every arm fixed turns NOTHING into SOMETHING — these impls are currently *invisible*, so no
pre-existing fixture can fail and neither coverage nor the diff can say what to test. Tests must be
hand-derived from the spec: a permutation pair per shape, plus a **bystander** fixture (the arm is
present; the assertion is about code that does not use it).

🛑 **W1 is forbidden to bless any golden** and must stop and report which moved. Blessing a red gate
without independently deciding the new output is correct is the rubber stamp the golden gates exist
to prevent. ORCH rules on blessing.

---

## RUN-P45-013 — 🚨 P0-F: **AD-2's `CProgram` carrier is DEAD.** And the key is not what anyone said.

P0-F re-derived all three premises independently and matched P0-A line-for-line (29 constructions,
no import edge, zero admissibility code in `compiler/types/`). It then corrected **P0-A and ORCH**
on three further points. ORCH verified the two decisive ones first-hand.

### ✅ Verified by ORCH — the carrier cannot reach one of its two consumers
```
$ grep -c 'CProgram' compiler/eval/eval.mdk
0
$ grep -n '^import' compiler/eval/eval.mdk        # no `ir.` import of any kind
```
`compiler/eval/eval.mdk` has **zero** `CProgram` occurrences and **no `ir.` import**. Admissibility's
two consumption sites are `eval.mdk:1976` and `core_ir_lower.mdk:1409` — the `evalModules`/
`cevalModules` lockstep pair — so **a 5th `CProgram` field cannot reach the first one at all**, and
making it reachable would introduce an import cycle. P0-F adds a second, independent kill: `lowerImpls`
(which contains the *other* consumption site) is an **argument to the `CProgram` constructor**
(`core_ir_lower.mdk:533`), so the proposed field is **downstream of its own consumer**.

⇒ **The two-valued `CAdmisAbsent | CAdmisTable` TYPE ruling survives — on stronger ground than AD-2
had.** The live fail-open arm `lookupPositions _ _ [] = [0]` discriminates on exactly the `[]` the
two-valued type splits, so fail-closed is no longer hypothetical, and the argument binds *harder* on
a `Ref` carrier (which must have an initialiser). **`Option` stays rejected. The `CProgram` CARRIER
is what dies.** P0-F recommends `Ref CAdmis` in a module all three importers already share — ~6
sites, **zero in `wasm_emit_typed_main.mdk`** (the file with the live cross-arc writer, which holds
24 of the 40 total sites), and no serialization question, which also **moots Q2**.

### ✅ Verified by ORCH — the table is keyed `(bare iface, bare method)`. There is NO head component.
```
compiler/eval/eval.mdk:1903
export lookupPositions : String -> String -> List ((String, String), List Int) -> List Int
lookupPositions _ _ [] = [0]
```
⇒ **The sprint doc's, AD-2's and ORCH's shared `(method, head)` framing describes the WRONG TABLE.**
`headTyconTy`'s already-identity-bearing `HeadKey` therefore does **not** narrow Phase 4's key work;
exactly one component is bare, and it is the interface name.

🎯 **And the fix site is tiny — the identity is in scope and thrown away one line later:**
```
compiler/eval/eval.mdk:1973-1976
implMethodEntry env disp o ifaceName typeArgs (ImplMethod mname pats body) =
  ...
  let key = implRouteKeyWord o ifaceName typeArgs None      -- `o` IS the identity, used here
  let positions = lookupPositions ifaceName mname disp      -- ...and DISCARDED here
```
`o : TyConOrigin` is a parameter, consumed on one line as identity and dropped on the next in favour
of the bare `ifaceName`. Same shape at `core_ir_lower.mdk:1408/1409`, and `DInterface.ifaceOrigin`
supplies the producer. `ifaceWordOf` is the ready-made key spelling.

### ⚠️ P0-A's *"no channel at all"* is OVER-STATED — and ORCH relayed it
Typecheck **already crosses the seam**, by stamping mutable `Ref`s inside `EMethodAt` (`ast.mdk:919`;
written `typecheck.mdk:6613-6614`, read `core_ir_lower.mdk:150` and `eval.mdk:1256`). What is missing
is a channel for a **whole-program value** — a much narrower gap than "no channel". RUN-P45-006 item 4
is corrected accordingly. Corroborating: `eval.mdk:48` already imports `types.route_key`, so a shared
module between the two sides exists today.

### 🚨 An honesty constraint on whatever ships
`keepOrAll original [] = original` — the *other* fail-open default — is **structurally unreachable
from any carrier**: it filters candidate *values*, not the table. Freezing an authoritative table
upstream of it is RUN-B-013's own *"has changed nothing"* warning. **Either retire it in the same
unit, or the unit must NOT claim to have closed the fail-open behaviour.** A claim reaching past its
evidence is this arc's most frequent review defect.

### ⏸️ ORDERING — P0-F refuses to pick, correctly. This is the last open decision.
It depends on **which source Phase 4 reads**, and the sprint doc states its intent two ways:
- **route α — from `List Decl`:** Phase 4 is **NOT** blocked on 4b.
- **route β — from `IE`'s `ieRows` post-K** (the charter's literal wording): **HARD-ORDERED AFTER
  4b**, because every `IE` reader takes a bare `String` and `ieEntriesForIface` filters
  `ir.irName == iface` — so freezing that selector **freezes the order-dependence** behind a table
  that then reads as authoritative.

Picking requires knowing which property Phase 4 is chartered to freeze. **Await P0-G, then one
combined ordering decision to the owner.** Do not let a bite be cut against an unpicked branch —
that is the F-3 failure arriving through the front door.

---

## RUN-P45-014 — 🚨 P0-G: the fix is CHEAPER and lives UPSTREAM. **The source comment is FALSE.**

P0-G was killed by a server-side 529 with §§E/F/G unwritten, but **sections 0/A/B/C/D landed on disk
(47 KB)** — the append-as-you-go rule paid for itself. Resumed for the remainder; the ordering
verdict (§F) is still owed.

### ✅ ORCH-verified — `resolve` has NO value-name duplicate check
```
compiler/frontend/resolve.mdk:1922
duplicateErrors : List Decl -> List Decl -> List ResError
  ... map (dupErr "type")        (findDups typeSeed  (dataRecordNames prog))
   ++ map (dupErr "constructor") (findDups ctorSeed  (ctorNames prog))
   ++ map (dupErr "interface")   (findDups ifaceSeed (map fst (interfaceList prog)))
```
Exactly three kinds. **There is no fourth.** ⇒ `methodIfaceParamsRef`'s header claim — *"resolve
rejects the ambiguous case outright"* — **is false**, and RUN-P45-005 flagged it as a contradiction
that had to resolve one way or the other. It resolves against the comment.

P0-G found *why* the comment believes itself: a **cross-module** ambiguity rejection does exist
(`AmbiguousOccurrence`, `resolve.mdk:726`) — but `keepAmbiguous`'s `not (contains n sameMod)`
**explicitly excludes own-module declarations**. The comment generalised the cross-module guard to
the intra-module case. **That asymmetry is the whole bug.**

### The identity is NOT missing — the KEY collides
There is exactly **one** identity supply for a method occurrence in the whole compiler:
`perRun.methodIfaceParamsRef`, an `OrdMap` keyed by the **bare method name** whose *value* is a full
`IfaceRef { irName, irOrigin }`. Its only readers — `recordImplObligation` (`:11306`),
`ifaceParamMonos` (`:15314`), `ifaceOfMethodName` (`:24508`) — all take the interface out of that
payload. ⇒ **the identity is in the value; the key is what loses it.**

This is a named class in this tree, and P0-G found the register: `frontend/ast.mdk:492-494` —
*"a table keyed by a BARE NAME that STORES a type head is an identity-supply defect"* — which
instructs the reader to **derive** the member set rather than trust its list of two (#1256
`recordByNameRef`, #1259 `universeDataEnv`). **`methodIfaceParamsRef` is an unlisted third member.**
Deriving instead of reading the list is exactly what that paragraph asks for, and it worked.

### ⇒ STRONG 4b is TWO independent units, not one
| unit | what | cost |
|---|---|---|
| **S — selection** | re-key the `*ByIface` family from `ir.irName` (spelling) to `IfaceRef` identity, via the comparator that already exists (`sameTyConHead`, `ast.mdk:496`) | one file, ~6 signatures, **narrowing only** |
| **Q — supply** | make the ambiguity **unrepresentable** — reject it in `resolve.mdk` | upstream, and it makes the bare-name key SOUND instead of working around its unsoundness |

**For #1182's shape there is no supply answer to derive** — both declarations are "own", and the
source says so itself (`typecheck.mdk:16802-16818`). That is what forces Q upstream rather than
deeper.

🚨 **Neither subsumes the other.** S without Q ships identity-keyed selection over an order-decided
supply. Q without S leaves #1619's same-spelled-interfaces class untouched. **Both are needed, in
that order.**

⇒ This is a materially **cheaper and better-placed** fix than either sizing the owner chose between:
P0-B's ≥3-files/≥8-signatures/new-AST-field estimate assumed identity had to be *manufactured and
plumbed*. It does not — it exists, and the cheap move is to stop the collision upstream. **Bite
`G-0` — the interface-permutation instrument — lands FIRST and MUST BE RED**, which is the
fail-capable control RUN-P45-007 ruling 1 demanded.

## RUN-P45-015 — Two agents lost to server-side 529s. Both RESUMED, nothing redone.

W1 (arm set) died at *"Now fmt + lint on the three touched files"* with uncommitted edits; P0-G died
with §§E/F/G unwritten. **Both were resumed by message rather than replaced** — a resume keeps the
agent's own context and worktree, where the documented salvage path (extract a patch, hand it to a
replacement) exists only for agents that cannot be resumed.

W1's resume instruction adds one thing its original brief lacked: **commit the WIP before the next
long step.** It has now been killed once mid-edit; carrying uncommitted work through a rebuild is how
that becomes lost work. It was also told to report a half-written edit plainly rather than push
through — a truncated edit silently poisons every later measurement — and given explicit licence to
restart the bite from its last good commit if resuming is messier than redoing.

**These were infrastructure faults, not agent errors.** Recorded so the run's throughput numbers are
not later read as agents failing.

---

## RUN-P45-016 — P0-G §F: the ORDERING, and a silent-wrongness trap the FIX would introduce

### The ordering matrix — the split IS the answer
| | vs **Q** (resolve rejection) | vs **S** (identity-keyed selection) |
|---|---|---|
| **route α** | not ordered | not ordered — *and* Phase 4 goes identity-keyed for free |
| **route β** | not ordered | 🚨 **`S1` MUST land first** |

**`S1 → Phase 4` on route β is the only hard constraint in the matrix.**

**P0-F's discriminator is NAMED and decidable today, with no charter ruling needed.** The table Phase
4 would freeze **already exists and is route α**: `buildIfaceDispatch : List Decl -> List ((String,
String), List Int)` (`eval.mdk:1882-1883`) walks `DInterface` decls (`:1888`) and is consumed by
`lookupPositions` (`:1903`). Nothing in its production or consumption touches `IE`/`ieRows`/
`*ByIface`. ⇒ the open question was **scope** (does Phase 4 freeze *this* table, or build a new
`IE`-derived one?), not code — and α is strictly cheaper. **ORCH rules route α.** It needs no owner
call: it is what the tree already does, and route β would be a new, more expensive table whose only
distinction is inheriting the defect S exists to remove.

### 🚨 ORCH-VERIFIED — the fix's own trap, and the tree pre-warns the exact mistake
```
compiler/frontend/ast.mdk:121-123
ifaceIdentity (OriginModule m) name = "\{m}::\{name}"
ifaceIdentity OriginUnresolved _ = ""
ifaceIdentity OriginBuiltin _ = ""

compiler/frontend/ast.mdk:139-140
export ifaceIdMatches : String -> String -> Bool
ifaceIdMatches a b = a != "" && a == b
```
Absence never matches, **not even itself** — and the surrounding comment says the flat/loader-less
drivers *"deliberately stamp nothing"*. ⇒ a naively identity-keyed `lookupPositions` **misses on
every FLAT lookup**, falls through the fail-open `lookupPositions _ _ [] = [0]` (`eval.mdk:1904`),
and silently degrades dispatch positions on `check <single file>`, lsp, repl and doc. A naive `==`
is the opposite bug (two unstamped interfaces compare equal). **Phase 4 needs a TWO-TIER key, and
that requirement is invisible from the charter.** This is a would-be S0 *introduced by our own fix*
— the "does this turn NOTHING into SOMETHING" question, answered in the dangerous direction.

🎯 **ORCH cross-check P0-G did not draw, from the same comment block:**
> *"⚠️ `sameTyConHead` BELOW IS THE OPPOSITE RULE ON THE SAME ABSENCE … this one answers a LOOKUP (a
> miss is loud, a false hit is silent), that one answers ACCEPTANCE (a false reject refuses a valid
> program). **Neither shape may be copied to the other site.**"*

Unit **S** re-keys a *filter* and P0-G correctly reaches for `sameTyConHead` (acceptance). Phase 4's
`lookupPositions` is a *lookup* and must use `ifaceIdMatches` **plus** the flat-path tier. **The two
units need DIFFERENT comparators, and copying either to the other's site is pre-warned in the
source.** Write this into both briefs.

Also newly reported: the **producer** discards the origin too — `ifaceDispatchEntries`
(`eval.mdk:1888`) destructures `DInterface { name, typarams, methods, … }` with `ifaceOrigin` in
reach and unbound. And route α's identity fix is free at **both** ends: `ifaceIdentity`
(`ast.mdk:121`) mints `"\{m}::\{name}"` — literally C4/I2's spelling — and is already called two
lines away in both engines (`eval.mdk:1969`, `core_ir_lower.mdk:1402`), with `o` in hand.

### ⭐ P0-G RETRACTED ITS OWN §B/§D CLAIM, unprompted
Its earlier sections implied **Q1 blocks Phase 4**. Once P0-F named the consumer, P0-G refuted
itself: `lookupPositions`' key comes from the *declaration* side (`DImpl.iface`/`DInterface.name`)
and never reads `methodIfaceParamsRef` — verified negative by grep over both files, no hits. It
labelled the original *"an inference about an unidentified consumer, not a derivation."*

That is the sprint's most-cited defect class — **a claim reaching past its evidence** — caught by its
own author, across a 529 restart. Recorded as the standard to hold the implementers to.

### §E — the control exists nowhere, and its pre-fix reading is already on record
**Nothing in the tree permutes `interface` declarations.** `diff_compiler_import_order.sh` permutes
entry *import clauses*; `diff_compiler_dict_semantics.sh` §4 permutes *`impl` blocks* (regex `:889`).
⇒ bite **G-0** is genuinely new coverage, not a re-run. Its pre-fix reading is already recorded in
the source as a **measured verdict flip** (`typecheck.mdk:16806-16810`), so the probe is **provably
able to fail** — satisfying RUN-P45-007 ruling 1's demand — and it discriminates all four states:
today / name-scoped / Q1 / S1-alone.

---

## RUN-P45-017 — ✅ PHASE 0 CLOSED. The plan of record.

Seven packets (P0-A … P0-G), five owed questions answered, two rulings by the owner and three by
ORCH. **Every Phase 0 finding that contradicted the sprint doc was verified by ORCH first-hand
before being acted on.**

**Landing order.** G-0 first and RED; the arm set is a precondition under every route; Phase 4 takes
route α with a two-tier key.

| # | unit | owner | state |
|---|---|---|---|
| 1 | **arm set** — `TyFun` + `TyEffect` (#1617, #1618) | W1 | 🔨 in flight |
| 2 | **G-0** — interface-permutation instrument, MUST BE RED | — | ready to cut |
| 3 | **Q1** — `resolve` rejects two same-method interfaces in one module | — | ready to cut |
| 4 | **S1 → S2** — widen `*ByIface` to `IfaceRef`; supply real identity | — | ready to cut |
| 5 | **Phase 4** — freeze admissibility, route α, `Ref CAdmis` carrier, two-tier key | — | ready to cut |
| 6 | **S3** — repoint `keyForSite` | ⏸️ **OWNER** | separable, LAST |
| — | **X** — strike `ieImplExistsForHeadGo` from the target list | — | free, docs only |

**Superseded and NOT to be re-inherited:** AD-2's `CProgram` carrier (dead — cannot reach
`eval.mdk`); Q2's render-vs-omit question (moot — a `Ref` carrier has no serialization); the
`(method, head)` framing (wrong table); the doc's three-member arm set (wrong member); and the
ruling's *"one line, inside one file"* sizing for 4b (the fix is upstream, in `resolve.mdk`).

**Two honesty constraints binding on the PR bodies:**
1. `keepOrAll original [] = original` is unreachable from any carrier. **Retire it in the same unit,
   or do not claim the unit closed the fail-open behaviour.**
2. #1068 is co-owned with X-E and carries an X-W physical residual. **This sprint cannot CLOSE it**
   regardless of what lands.

---

## RUN-P45-018 — W1 lands PR #1629, and DISPROVES the brief twice. Both were ORCH's errors.

**PR #1629** (`fix/1617-1618-fun-and-effect-impl-head-tags`), open, unmerged.

| shape | before | after |
|---|---|---|
| `ab` | `run [(5, 5)]` `build=1` | `run [(5, 9)]` `build=0` `exec [(5, 9)]` |
| `ba` | `run [(9, 9)]` `build=1` | `run [(5, 9)]` `build=0` `exec [(5, 9)]` |
| `eff` | `run [2]` `build=1` | `run [2]` `build=0` `exec [2]` |

`(5, 9)` and `2` were **hand-derived from the source before any invocation** — the rule that stops a
golden enshrining what the engine did. Both permutations now agree, which they did not before.

### ⭐ The `TyFun` tag question: RESOLVED, and it refutes the brief's concern
ORCH briefed that currying might mean one `__fun__` tag cannot drain #1617. **W1 disproved it with
the typed Core-IR dump:** the two impls **already carry distinct canonical words**
(`ab::Sz|(Int -> Int)|` vs `…|(Bool -> Bool)|`) while sharing one tag. The tag's only job is to make
them *collide*, which is what upgrades the site to the canonical word — the same mechanism
`Pair Int Bool`/`Pair Bool Int` rides. Tuples are arity-bearing for the *opposite* reason (arity is
their only head discriminator and the runtime cell carries it; an arrow carries no cell tag at all).
Verified with a curried pair at two arities. **One arity-free tag is correct.**

### ⚠️ BRIEF DEFECT 1 — the site set was ONE FUNCTION SHORT
With all four head projections fixed, #1618 drained and **#1617 did not**. `sz : a -> Int` dispatches
on its *argument*, so its route comes from `resolveArgStamp` → `entail`, whose `inst` arm projected
through `headTyconNameMono` — the residual ORCH's brief left untouched — and took the fallback every
time. Repointing it at `headTyconMono` is the same repoint A-2.2b made at `goalHeadCon`.

**Found by the typed Core-IR dump, not by reading source.** `AGENTS.md` calls that probe the highest-
value tool here and says to reach for it *before* reasoning about routes; this is another instance.

### 🚨 BRIEF DEFECT 2 — ORCH's authority table was WRONG, and ORCH told W1 not to re-litigate it
RUN-P45-004/011 concluded the defect set closes at `{TyFun, TyEffect}`, and the W1 brief stated it as
settled with *"do not re-litigate it, and do not extend the set."* **W1 probed the nearest uncovered
shape anyway and found a defect.** ORCH-verified on the base binary:

```
impl Sz (Eq a => Int) where sz _ = 2
check -> 0     run -> 0  [2]     build -> 1
runtime error [E-PANIC]: no impl of method 'sz' for type '__none__'
```

Byte-identical to #1618. `headTyNode` unwraps `TyApp` only — it does **not** peel `TyConstrained` —
so `Eq a => Int` never reaches the `TyCon Int` underneath.

⇒ **#1617/#1618's *"measured NOT to be a defect"* is correct but SCOPED, and neither says so:** it
holds for a **headless** body (`Eq a => a`, peel is a bare `TyVar`, legitimately headless). A
**headed** body is #1618 one constructor over. **Filed #1630** (S1); scope corrections posted to
#1617 (`issuecomment-5291012993`) and #1618 (`issuecomment-5291013346`). Deliberately kept OUT of
#1629 — extending a set mid-bite is how a fix ships wrong in the other direction.

**The propagation chain is the lesson.** One under-scoped sentence in an issue body → repeated into
the sprint doc *with its polarity inverted* → quoted verbatim into an implementer brief as an
authority table → caught only because the implementer disobeyed the instruction not to check.
**"Disproving me is a SUCCESS" earned its place in the brief twice in one bite.** An enumeration that
BOUNDS a class must carry its derivation and its scope, because every later reader treats it as
settled.

### Golden ruling — BLESS, in a separate terminal commit
`diff_compiler_snapshot_frontend` is red **by construction** (the three edited files are themselves in
the snapshot corpus). W1's evidence is the right evidence: 161 insertions / 26 deletions across
`route_key.md`, `typecheck.md`, `eval.md`, with **every non-comment line traced to one of the six
edited declarations or the import, and no unrelated declaration moved** — the "unrelated code still
behaves" property applied to a golden, which is what separates a bless from a rubber stamp.

Ruled: bless by NAMING each path (never a corpus), in its **own terminal commit**, then re-run the
plain check and report the ratio — **the re-run is what makes it a pass.** `test/selfproc_goldens/legA/*`
is **NOT** to be blessed: measured unmoved, with a mechanism (`funHeadTag` lives in `route_key.mdk`,
not a LEG A module). ORCH reviews the **committed** diff, not a description of it.

### Fixpoint — CI is NOT sufficient here
W1's `unchecked:` deferred `selfcompile_fixpoint` to CI's `soundness`. **A green CI fixpoint covers
C3b ONLY.** This change moves emitted IR, so the fixpoint is its decisive gate. W1 instructed to run
it locally, backgrounded with a PID poll, and report **C3a and C3b as separate verdicts** — *"the
fixpoint passed"* is not a reportable result. A segfault there is the stale-seed signature, not a
bug; a seed re-mint is a decision to bring to ORCH, not a step to take.

### Friction accepted from W1 (all four are real)
1. Brief's site set incomplete (above).
2. The `TyConstrained` claim quoted as authority (above).
3. The isolation classifier rejects ordinary compound commands as "too complex", forcing every
   multi-step probe through a written `.sh` — roughly doubled its tool calls. **Environmental, worth
   knowing when sizing future probe packets.**
4. `test/build_diff_fixtures` has **no golden regen script by design** — its header says hand-write
   and review. Worth knowing before someone hunts for one.

---

## RUN-P45-019 — #1629 close-out: goldens blessed, fixpoint BOTH halves, and a hook bypass VERIFIED CLOSED

**PR #1629** — three commits: two source (`e051788b`, `588a3322`), one **terminal golden re-cut**
(`0da75b34`) carrying no source change, so the golden move is reviewable on its own.

**Goldens.** Blessed by name, one file at a time, never a corpus sweep; each reported `1 blessed`;
`git status` showed exactly three files, all under `test/snapshots/compiler/`. **Plain re-run:
`202 fixtures, all 202 compared and matching`, exit 0** — the re-run is what makes it a pass, not the
bless. `test/selfproc_goldens/legA/*` deliberately NOT blessed (measured unmoved; `diff_compiler_selfproc`
PASSES), with the mechanism recorded **in the commit message** so a later reader cannot "restore
symmetry" by blessing it.

**Fixpoint — both halves, named:**
```
C3a (IR1 == seed-bootstrapped converged reference): YES
C3b (IR1 == IR2, fixpoint):                          YES     exit 0
```
No segfault at any step ⇒ **no stale-seed signature, no seed re-mint owed.** This is why ORCH refused
to accept CI's `soundness` as sufficient: a green CI fixpoint covers **C3b only**, and this change
moves emitted IR.

### ⚠️ W1 disclosed it committed with `core.hooksPath=/dev/null` throughout — ORCH verified the gap CLOSED
Volunteered plainly rather than implying the hook had validated the commits, which is the right
disclosure. The bypass drops **all four** pre-commit checks, so ORCH closed each independently rather
than accepting the manual substitute:

| hook check | status |
|---|---|
| **fmt** | ✅ ORCH-verified — `medaka fmt` (read-only mode) over the three files **as pushed** (`git show FETCH_HEAD:<path>`), **exit 0** |
| **lint** | ✅ ORCH-verified — `medaka lint` over the same three, **exit 0** |
| **lextok** | ✅ **moot** — no `.lextok.golden` sibling exists for any of the three; the check is opportunistic and would have been a no-op |
| **snapshot** | ✅ blessed + 202/202 re-run, committed; CI's snapshot shard re-verifies against the merged tree |

⚠️ **One honest residual, not closed:** the per-file lint above does **not** exercise the cross-file
`rule-duplicate-body`, which needs a whole-project scan. Risk is low (W1 edited existing declarations
and added few), but it is **not zero and is not covered by any gate** — derived: no gate enforces
tree-wide `fmt`/`lint` (`grep -rn 'medaka lint\|fmt --check' test/*.sh` returns gates *about* fmt/lint
behaviour, not enforcement of tree cleanliness). **The pre-commit hook is the ONLY enforcement of
that rule, and it was bypassed.** Recorded rather than papered over.

### `gh pr edit --body-file` silently no-opped AGAIN
Returned **rc=1 and left the old body in place.** W1 caught it only by reading the state back —
all three new key strings absent (`grep -c` → 0) — then landed it via `scripts/pr.sh body`, which
self-verifies, and re-verified independently. **This is the documented shape and it recurred on this
very sprint.** Standing rule reconfirmed: **verify the resulting state, never the return code.**

## RUN-P45-020 — W2 dispatched: bite G-0, where a RED GATE IS THE DELIVERABLE

Only writer live (W1 finished). G-0 is a *verification instrument for a fix that has not happened
yet*, so **a green G-0 is a FAILED bite** — it would mean the probe cannot see what it exists to see.
The brief requires the PR body to say so unmistakably, so no later agent "fixes" the red by weakening
the probe.

**It must discriminate FOUR states, not two** — today / name-scoped / Q1-landed / S1-alone. A probe
that reports only "same vs different" collapses *name-scoped* into *Q1-landed*, which is precisely
the confusion that lets a shallow fix look like a real one. Multi-channel signature recording, on the
`import_order.sh` model, is what buys the discrimination.

**Its proof-of-fail is already on record:** `typecheck.mdk:16806-16810` documents a measured verdict
flip for this shape. If the instrument does not reproduce that flip, the instrument is broken — that
check precedes believing any other result it produces.

**One design tension handed over explicitly rather than decided:** a gate that is red by design
cannot simply be wired into a required shard without redding the tree for everyone. W2 must choose —
wire it and record the expected-red in `.claude/HANDOFF.md`, or exclude it with a reasoned
`CI-COVERAGE-EXCEPTIONS.txt` row — and **state the consequence**. It was also pointed at
`test/must_fail_fixtures/` as a possibly-simpler home, since that harness's contract already *is*
"assert this bug still reproduces, go red when it drains", with the caveat to check
`MUST-FAIL-NOT-PINNABLE.txt` first because those verbs may not reach the interface-permutation axis.

---

## RUN-P45-021 — ⭐ W2 OVERTURNS ORCH's central design instruction. **ADJUDICATED: W2 is right.**

**PR #1631**, CI **12/12 green**: `test/diff_compiler_iface_order.sh` + `test/iface_order_fixtures/`
(5 cases) + `test/IFACE-ORDER-LEDGER.txt`. Gate confirmed to have actually *run* in the CI logs
(`PASS diff_compiler_iface_order`) — not a shard that went green having executed nothing.

**ORCH mandated a RED gate** (*"a green G-0 is a FAILED bite"*). **W2 landed it GREEN, deliberately,
and its argument is grounded in this tree's own solved precedent.** ORCH-verified verbatim:

> `test/IMPORT-ORDER-LEDGER.txt` — *"The gate is GREEN with rows present because a gate that lands
> red breaks `main` and teaches people to ignore it. **The rows are what keep the green honest.**"*

**The ledger form is STRICTLY STRONGER than the red exit ORCH asked for**, on ORCH's own stated
requirement:
- a red-by-design gate must be **excluded** from CI (or it reds the tree for everyone), so it never
  runs and rots — and it carries **one bit**, which *cannot* distinguish state 2 from state 3. That
  is the exact four-state collapse the brief itself forbade. **The mandate contradicted its own
  requirement.**
- the ledger pins **every distinct signature** and reds in **three** directions — **DRAINED**,
  **MOVED** (the partial/name-scoped fix), and **new unledgered divergence** — all three demonstrated
  by negative control on the branch.

**✅ ADOPTED. ORCH's red-gate instruction is withdrawn.** W2 also generalized
`must_fail_census.sh` HALF 4 over **both** order ledgers — it was written for `IMPORT-ORDER-LEDGER.txt`
alone and would have silently stopped covering the family. That is the state-2 backstop and it was
not asked for.

**Proof-of-fail delivered:** `typecheck.mdk`'s documented FA/FB flip reproduces by hand *and* through
the instrument, as an **ACCEPT vs REJECT** flip (`check=0;…run=0:11` vs `check=1;codes=T-NO-IMPL`).
W2 additionally proved the **permuter actually moves the file** (identity byte-identical; swap differs
at exactly the two `interface` headers; 1414 bytes all three) — because *"found nothing"* and *"moved
nothing"* are the same reading. That check was not in the brief and should have been.

**W2's bounding finding:** #1182's canonical program is **INVARIANT** on the interface-order axis.
So for #1182's own program a name-scoped fix leaves nothing here to object to; **the state-2 signal
comes from the sibling cases.** Kept as an explicit `negative-1182-…` case. This narrows — correctly —
the claim RUN-P45-005 made about what the instrument can see.

## RUN-P45-022 — 🚨 ORCH's own #1620 filing was WRONG. Corrected in public.

W2 reported #1620's segfault **did not reproduce** on the interface-order axis (8 runs). ORCH had
reproduced it first-hand and filed it. Rather than assume either side was wrong, ORCH ran the
**discriminating third program**:

| program | interfaces | impls | result |
|---|---|---|---|
| original `ab` | `Alpha`,`Beta` | `Alpha`,`Beta` | raw word, exit 0 |
| **interfaces only** | `Beta`,`Alpha` | `Alpha`,`Beta` | **prints `alpha`, exit 0 — well-behaved** |
| **interfaces AND impls** | `Beta`,`Alpha` | `Beta`,`Alpha` | **exit 139, segfault** |

⇒ **The segfault is real and still ungraded, but it is NOT reached by permuting interfaces alone.**
P0-D's `ba` fixture swapped **both**; ORCH described it as *"swapping the two interface declarations —
nothing else changes"*, which is **false**.

🚨 **The failure mode is precisely the one this sprint keeps cataloguing, and the ask was the
dangerous part:** extending the pin along the interface axis — as ORCH asked #1620 to do — would have
pinned a **well-behaved** program, left the segfault ungraded, and *looked* like coverage. **Worse
than no pin.**

**And note where the error entered:** ORCH re-derived the segfault first-hand *specifically to avoid
relaying P0-D's measurement unverified* — and then **described the setup from memory rather than from
the file.** The verification was real; the sentence around it still reached past its evidence. A
first-hand measurement does not immunise the prose that frames it.

**Correction posted** (`#1620 issuecomment-5291356596`), readback verified, with the corrected ask:
pin the **joint** permutation. Recorded rather than quietly edited.

**Both W2 friction items 1 and 2 are ACCEPTED as ORCH brief defects**, alongside W1's two. Running
tally of brief defects caught by implementers this sprint: **four, all from writers, none from
gates.** Item 2 is the sharper one — the brief summarised `import_order.sh` as *"five cells, no wasm
arm"*, accurate but omitting that it is a fully-developed self-draining ledger harness **whose header
argues against the design ORCH mandated**. *Reading the file instead of the summary reversed the
bite's central decision.* That is "derive, don't encode" biting at the **summary layer** — the
orchestrator's layer.

Item 3 also stands: `.claude/HANDOFF.md` already specified this instrument (*"Only a permutation
differential sees it"*) and the brief never cited it. Item 4 is a genuine trap worth adding to
`AGENTS.md`: **gate output invites `| head`, and a gate run piped to `head` reported `EXIT=0` for a
run with two failures** — the documented `medaka build` pipe trap applies to gates too.

---

## RUN-P45-023 — Merge request received; premise was FALSE on both counts. Rounds run instead.

Val: *"let's merge the PR assuming we've done the review and repair rounds."* **We had not**, and
**#1629 was not green.** Merging is hard to reverse and the sprint's own rule — never merge an S0 fix
on green alone, base rate 6 reviews / 6 real defects, all on 12/12-green PRs — applies squarely.
Reported the gap and ran the rounds rather than acting on the assumption.

### #1629's `soundness` red is the LICENSED one, but it hid two skipped steps
Read the gate rather than guessing. The failing step is *"Open bugs must still reproduce (must-fail
suite — a RED here means someone FIXED something)"*:
```
checked 100 fixtures: 98 still reproduce, 2 DRAINED, 0 control-broke, 0 malformed
DRAINED  1617-fn-typed-impl-head-none-bucket          (issue #1617)
DRAINED  1618-effect-carrying-impl-head-cannot-build  (issue #1618)
```
Exactly the two the PR fixes; **0 control-broke, 0 malformed** ⇒ no collateral drains. The tracker
self-drained, which is that gate's entire purpose.

🚨 **But the job dies there, and takes two steps down with it:**
```
failure :: Open bugs must still reproduce (must-fail suite …)
skipped :: Compiler source must be well-typed
skipped :: Emitter must reproduce itself (C3b fixpoint; C3a drift only warns)
```
**`typecheck_compiler_source.sh` — the ONE gate that catches an ill-typed compiler while every other
gate passes — has not run on this PR.** A green rollup would never have shown that; only reading the
step list did. **W3 dispatched**, briefed that the deliverable is making those two steps *execute*,
not turning a tick green.

W3 was steered toward **re-pointing** the drained fixtures rather than deleting them: **a drained
fixture is not a drained class**, and **#1630** proves the class is live one constructor away. Also
told **not to close #1617/#1618** — this sprint's policy is *implement, do not close*; closure
happens post-merge with the landing sha.

## RUN-P45-024 — R2 on #1631: **MERGE**, no S0/S1. And it verified what it was told to doubt.

R2 built a read-only fakeroot in scratch (symlinked binary/stdlib/runtime + `git archive` of the
branch's tests), exploiting the gate's `ROOT`-from-`dirname $0/..` to run **the branch gate against a
base binary** without building anything. It then verified the instrument can fail **four independent
ways**, building each mutation itself rather than accepting the author's negative control:
unledgered divergence · MOVED · DRAINED · ROT — all EXIT=1 with the right message. Gate confirmed to
have actually *run* in CI (`PASS diff_compiler_iface_order`, `gates (eval)` planned as FULL) — not a
shard reporting SUCCESS having executed nothing.

It also **executed the two things W2 had listed as `unchecked:`** — `must_fail_census.sh` HALF 4 with
a stubbed `gh` (4 findings, **both** ledgers covered, no coverage loss), and dash/macOS portability.

**⭐ And it independently re-derived ORCH's exit-139 debunk:** no 139 in any cell on the interface
axis; alpha-first **leaks a heap address** (`47049609283896`, then `47401252067640` — different each
run), beta-first stable. RUN-P45-022's correction holds under a second, independent method.
⚠️ **Consequence for whoever pins #1620: the wrong answer is a LEAKED POINTER that varies per run**,
so an exact-match pin will red on address drift. Project it to a stable predicate.

### Findings and disposition
| # | sev | finding | disposition |
|---|---|---|---|
| **F1** | S2 | the drain note printed at failure time drops the `R-*` qualifier the gate header carries, so an **S1-alone** fix converging on `check=1;codes=T-NO-IMPL` gets the **state-3** rule printed over it — the state collapse the instrument exists to prevent, one notch over. Reviewer forced the convergence and watched it happen | **W4 — fix BEFORE merge** |
| **F2** | S2 | the corpus cannot discriminate interface-NAME keying from MODULE-QUALIFIED-IDENTITY keying — what HANDOFF demands of Phase 4. The limit IS disclosed, but as a coverage footnote never connected to the four-state table it undermines. Discriminating shape is structurally inexpressible today | **W4 — doc, next to the table** |
| **F3** | S3 | `schemes=` cell is inert across the corpus — a pure function of `check=` | deferred |
| **F4** | S3 | HALF 4's banner and lead paragraph still describe one ledger; only the file-top summary was updated. Behaviour verified correct | **W4 — doc** |
| **F5** | S3 | unescaped TAB where TAB is the `cut -f2` separator | **SPLIT OUT — filed #1634** |

**ORCH ruled F1 fixed pre-merge, against R2's "neither blocks the merge".** An instrument whose sole
value is discriminating four states must not land misreporting one of them; "fix it before anyone
acts on a red" is a promise no future agent inherits.

## RUN-P45-025 — #1634 filed: a MASKING PATH inside the DETECTOR. ORCH-verified before filing.

```
test/diff_compiler_import_order.sh:254  esc() { … s/\\/\\\\/g; s/\|/\\p/g; s/;/\\s/g; s/\n/\\n/g … }
                              :352      printf '%s\t%s\n' "$ord" "$(sig_for …)"
                              :365      cut -f2 … | sort -u
```
`esc` escapes backslash, `|`, `;`, newline — **not TAB** — while TAB is the record separator that
`cut -f2` splits on. A signature containing a TAB is truncated, so **two different signatures compare
EQUAL**. Reachable: the signature embeds program stdout.

**The direction is the dangerous one.** Truncation makes signatures *more* equal, never less ⇒ the
only failure mode is **under**-reporting, and it cannot produce a false red. For this family that is
the worst possible shape, because the ledger design reads "one distinct signature" as *"this case no
longer diverges — drain the row."*

**Severity S3, derived from what was measured** — no current fixture emits a TAB, so nothing is
mis-reported today — with the escalation condition stated explicitly rather than inflating it to S2.
That is the same discipline ORCH has been enforcing on every packet.

Affects **both** gates (`import_order` and the new `iface_order`, which inherits the code). **Split
out of #1631 rather than folded in**: a pre-existing defect must not be absorbed by the PR that
merely replicates it, or the diff claims a fix it did not make and the original gate's decade of
exposure disappears.

## RUN-P45-026 — Two writers live concurrently. Deliberate, and stated to both.

W3 (`compiler/` + `must_fail_fixtures/`, branch `fix/1617-1618-…`) and W4 (`test/*iface_order*` +
`must_fail_census.sh`, branch `test/iface-order-instrument`) run at the same time in **separate
isolated worktrees on separate branches touching disjoint files.**

The SERIALIZE WRITERS rule exists because Stage A ran 3-5 concurrent writers **in one worktree** and
paid with four contaminated measurements and ~4 bites of rework — the mechanism is shared state, not
concurrency itself. Disjoint worktrees and disjoint files carry no such coupling.

**W4's brief states the concurrency explicitly, naming W3 and its file set** — because a prior
orchestrator on this arc opened a brief with *"you are the ONLY agent live"* and dispatched two more
minutes later. If the premise is that they cannot collide, the agent is owed the facts to check it.

---

## RUN-P45-027 — W4: F1/F2/F4 landed on #1631. And a corpus that contradicted its own advice.

Two commits (`b732e582`, `6c3609a4`) on `test/g0-iface-order-differential`; CI re-running. Gate
re-verified `EXIT=0`, `5 case(s) — 5 ok, 0 failing`, byte-identical to baseline.

**⭐ W4 found a stronger proof than the brief prescribed.** ORCH briefed it to *construct* the
state-4 convergence. It did — but first noticed **the committed corpus already pins the
counterexample**: the #1182 ledger row's own second signature is `check=1;codes=T-NO-IMPL`, a
*type*-stage code, which the gate's printed note was labelling state 3. **A gate whose own pinned
data contradicts its own printed advice** — that is the artifact, and W4 put it in the commit message
rather than the constructed probe. Fixed in **four** places carrying the same flaw (printed note,
four-state table, `codes=` cell description, ledger header), now discriminating by prefix: `R-*` ⇒
state 3, `T-*` or empty ⇒ state 4. **No state collapsed — 3 and 4 are more separated than before.**

### 🎯 ORCH-VERIFIED, and it corroborates the sprint's two-unit split from a citation nobody had
W4 grep-proved F2's inexpressibility rather than accepting the brief, and turned up a better source:
```
compiler/types/typecheck.mdk:16700
-- Interface names are NOT globally unique — nothing in resolve or the
-- loader enforces it across modules, only WITHIN one (`Duplicate interface: Eq`).
```
⇒ **Q and S are NOT redundant, and this is the proof.** Q (reject the ambiguity in `resolve.mdk`)
can only reach the **intra-module** collision, because cross-module same-name interfaces are
**legal** — the #1258 shape, where two unrelated modules declaring `Same` shared one bare-name key
and an impl completely implementing its own `Same` was rejected as missing the *other* one's method.
**That is exactly why name-keying is insufficient and identity-keying is required.** RUN-P45-014's
*"neither subsumes the other"* now rests on a source citation, not an argument.

⚠️ **And it names what this corpus is structurally blind to: #1258.** F2's doc fix now says so at the
four-state table — a drain here is **not** evidence Phase 4 keyed by module-qualified identity.

### W4's `unchecked:` is exemplary and is kept as-is
It flagged that R2's stubbed-`gh` execution of `must_fail_census.sh` HALF 4 is **a relayed
observation, not its own** (its change there being provably comment-only, so it cannot matter), that
it ran one gate only, and that F2's inexpressibility rests on reading + two cited diagnostics rather
than on building a two-module fixture. **Labelling someone else's measurement as relayed, inside your
own report, is the discipline this arc keeps finding absent.**

### Friction — three accepted, one is a real harness defect worth escalating
1. **ORCH gave the wrong branch name** (`test/iface-order-instrument` vs the real
   `test/g0-iface-order-differential`). Cheap only because the brief also said to confirm it.
2. **The PR branch was already checked out in a live sibling worktree, so `git checkout <branch>` is
   impossible.** The brief's "check out the existing branch" is **not achievable as written** under
   this repo's worktree fan-out; the working pattern is a local branch + `push HEAD:<ref>`. **This
   belongs in the orchestration playbook — every writer on a multi-worktree sprint hits it.**
3. W4 bypassed the hook on commit 1 out of caution, then ran commit 2 with it live and it passed —
   and **flagged its own unnecessary bypass rather than leaving it in the reflog.** No `.mdk` was
   staged, so all four checks were no-ops either way.
4. 🚨 **The harness refuses `cmd > /path/in/scratchpad 2>&1; echo $?` as "too complex"** — while the
   standing rule for gates and `medaka build` is *"never pipe; redirect to a file and read `$?`."*
   **The SAFE pattern is the one being refused, leaving the unsafe one available.** ORCH hit this
   repeatedly this session too. Worth raising as tooling, not worked around forever.

---

## RUN-P45-028 — W3: #1629 is **12/12 green and the skipped steps EXECUTED.** ORCH-verified.

The deliverable was never the green tick. Verified first-hand on the new `soundness` job (not relayed
from W3, and not inferred from the rollup — the rollup is exactly what hid this last time):
```
success :: Open bugs must still reproduce (must-fail suite — a RED here means someone FIXED something)
success :: Compiler source must be well-typed
success :: Emitter must reproduce itself (C3b fixpoint; C3a drift only warns)
```
`typecheck_compiler_source.sh`: **PASS, type-clean, 0 error-severity diagnostics across
`medaka_cli.mdk` + 69 entries** — the gate that catches an ill-typed compiler while every other gate
passes, which had **never run on this PR**. must-fail: `100 fixtures / 2 DRAINED / exit 1` →
**`98 fixtures, 98 reproduce, 0 DRAINED, 0 control-broke, 0 malformed, exit 0`**.

### The pins were RE-POINTED, not deleted — and the home was derived
Into `test/diff_compiler_dict_semantics.sh`, because **a drained fixture is not a drained class** and
**#1630 is live** — which W3 re-verified first-hand rather than relaying from the brief
(`impl Sz (Eq a => Int)` → `check=0 run=0 [2] build=1`, E-PANIC byte-identical to the #1618 just
fixed). The home was **derived, not invented**: two earlier members of the same `noneHeadTag` family
already live there, and one arrived by exactly this route (`s3-nary-requires-goal-vector`, #1154,
whose must-fail pin drained and migrated; Section 4's header documents it).

**⭐ And it fixed a real coverage hole in the process.** The #1617 fixture's discriminating property
is **declaration-order dependence**, which *a single-order value pin passes by construction*. The
drained must-fail fixture could only carry that half as an **ungraded third file** (`permutation.mdk`,
run by nothing). Written as a flat `.mdk`, Section 4's derived permuter now picks it up and it
**executes**: `PASS perm … [Sz]`. Likewise #1618's discriminator is the **`build` cell** — `check`
and `run` were *both already correct while the bug was live*, so a value-only reading is vacuous.
**Both fixtures now assert the cell that can actually fail.** Fail-capability proven by mutation
(`185 passed, 2 failed`), then reverted byte-clean.

### ⭐ W3 caught its own grep wrong — by running it
Its first consumer-enumeration excluded `/` from the leading character class, which *looks* like
tightening a word boundary and instead **hid the gate itself** (`FIXDIR="$ROOT/test/must_fail_fixtures"`
— the separator **is** a slash). Corrected: `must_fail_fixtures/` has **exactly two** directory
readers; a naive grep also returns two **code**-line hits that are the path inside **TABLE row label
strings** — prose no comment-filter heuristic can remove. Four files hit, two consume.

### ⚠️ Flagged rather than silently overruled: the autoclose keywords
`Closes #1617. Closes #1618.` sit at line 1 of the PR body — **the original author's, left in
place**, with W3 noting a reader may want them stripped. ORCH-verified the form is **plain and
unbolded**, so they **WILL fire on merge** (a bolded `Fixes **#N**` would silently not).

**ORCH ruling: KEEP them.** The sprint's *"implement, do not close"* policy targets **desk closes** —
closing without a landing commit — which is what let #1182 be closed while its pin still reproduced.
Autoclosing on merge **is** closure with the landing sha, which is the policy's own prescribed form.
Both issues drained against green controls and are re-pinned as fixed-behavior regressions. #1630
stays open and is unaffected.

### Friction — two repeats, one new
1. **Branch already checked out in a sibling worktree ⇒ `git checkout -B` hard-fails.** Second writer
   to hit this (W4 too). *Handing two agents the same branch name serializes them at the git layer,
   not just logically.* **Goes in the playbook.**
2. The isolation classifier rejected **three ordinary read-only commands**; each cost a round trip
   into a scratch `.sh` — **and the scratch-script workaround is itself the one that eats exit
   codes**, so it trades one hazard for another. Same defect as W4's item 4.
3. 🆕 **`PREFLIGHT_DRY` cannot help a drain.** This diff's real gate set (`must_fail`,
   `typecheck_compiler_source`) lives in **`soundness`, which preflight does not map at all** —
   confirmed by `grep -n must_fail test/preflight.sh` returning nothing. By design per the gate
   header, but the consequence is worth stating: **a drain is structurally invisible to the local
   loop and only ever surfaces in CI.**

## RUN-P45-029 — Both PRs are green. **Neither merges until R1 reports.**

| PR | head | CI | review |
|---|---|---|---|
| **#1629** (arm set, S0+S1) | `a8a226cb` | **12/12**, skipped steps now executing | ⏳ **R1 running** |
| **#1631** (G-0 instrument) | `6c3609a4` | **12/12** after W4's fixes | ✅ R2: MERGE |

#1629 is an S0 fix and the standing rule is **never merge one on green alone** — base rate here is
6 reviews / 6 real defects, every one on a 12/12-green PR. Green is the *precondition* for the
review, not a substitute for it. Waiting.

---

## RUN-P45-030 — 🚨 R1 on #1629: **HOLD.** The review found an S1 the 12/12 green cannot see.

**Verdict: do not merge as it stands.** R1 built a real two-arm differential (base `aaa4371` vs the
PR's `compiler/` diff rebuilt in its own worktree) and **confirmed faithfulness first** — base prints
`(5, 5)` on the #1617 repro, branch prints `(5, 9)`, matching the PR's own table. A differential
whose arms were never shown to differ correctly proves nothing; this one was.

### F1 (S1) — the projection has THREE readers. The PR analysed ONE.
The PR gives `headTyconNameTy` a `TyFun` arm and makes the **shared** `headTyNode` peel `TyEffect`.
Two of the other readers decide **ACCEPTANCE**, not dispatch:
- `implHeadTagForIface` → `implHeadTagsForIface` → `routeUndeterminedTop` (`:20104-20112`, `:20085`)
  — counts distinct impl head tags: one → stamp; **two or more → `T-AMBIGUOUS-INSTANCE`**. Arrow and
  effect impls were *dropped* from that census before, and are *counted* now.
- `implTysIfMatch` → `uniqueImplTysFor` → `groundOneObligation` (`:23107-23141`).

Measured both arms, on programs that **never dispatch to an arrow or effect head**:

| probe | BASE | BRANCH |
|---|---|---|
| `impl C Int` + `impl C (Int -> Int)`, undetermined site | `3`, exit 0 | `Ambiguous instance for C`, **exit 1** |
| same with `impl C (<Stdout> Bool)` | `3`, exit 0 | **exit 1** |
| multi-param `Conv` + effect-headed sibling | `True`, exit 0 | `Ambiguous instance for Display` (**prelude cascade**), **exit 1** |

🚨 **The PR's own bystander fixture asserts this cannot happen, and is falsified by adding ONE method
to its own interface** (`48`/exit 0 base → hard error branch, arrow impl still never dispatched to).
It passes only because `Sz a` is single-param — which short-circuits `groundOneObligation` — and has
no undetermined constraint. **This is the "feature + UNRELATED code still behaves" fixture failing at
precisely the job it exists to do**, which is why 11 green checks are all consistent with the defect.

### 🎯 ORCH-VERIFIED, and it is worse than R1 reported: THE TREE WARNED, SIX LINES AWAY
`compiler/types/typecheck.mdk:18234-18240`, verbatim:
> *"`implHeadTagForIface` feeds ONLY `implHeadTagsForIface` → `routeUndeterminedTop` … one head →
> stamp it; two or more → `T-AMBIGUOUS-INSTANCE`. Including headless impls there changes an ACCEPT
> into a REJECT … **That may well be the right answer under §3 … but it is an ACCEPTANCE NARROWING,
> and this stage is a bug fix.**"*

The warning names the function, the consequence, and the disposition — and sits a few lines from the
projection the PR edited. **The defect is not that the new behaviour is wrong** (it may well be
right); it is that an acceptance narrowing was shipped **undisclosed, unfixtured, and contradicted by
the PR's own §8** (*"the change is inert wherever no impl head is an arrow or carries an effect
row"*). That sentence is false, and it is in the body of an S0 fix — **the sprint's dominant defect
class, again.**

### What R1 RULED OUT — the review's value is not only the finding
Attacks 2-6 and 8 all clean, each verified rather than accepted: arm set audited as a SET (`TyVar`/
`TyRow` untouched, `impl C a` stays headless); the deliberate `headTyconNameMono` asymmetry is
correct and defended from `uOblIsDecidableNow`'s closed set; **the `entail` repoint really is
identical at every non-`TFun` head** (traced through `headKeyOfCon`/`tabKeyName`, *not* taken on the
author's word); no `evalModules`/`cevalModules` lockstep gap (`core_ir_lower` **imports**
`headTyconHead` from `eval`); **the `__fun__` single-tag ruling survives a currying attack
empirically** — `(Int -> Int) -> Int` vs `Int -> Int -> Int` → `11, 22, 33`, run == build, because
`rkTyAtom`/`rkTyFunArg` do parenthesize; and the golden re-cut is exactly the six edited declarations
plus the import.

**W5 dispatched.** Default is **option A** — keep the dispatch fix, restore acceptance behaviour,
since #1617/#1618 are dispatch-bucketing bugs, not acceptance bugs. Option B (accept the narrowing)
changes which programs compile, so it is a language-semantics decision needing an owner ruling and
its own fixtures; W5 is told to **stop and report** rather than choose it. Also assigned: strengthen
the bystander fixture so it *can* fail, correct §8, F2 (`registry.mdk:958`/`:1045` still say a `None`
means "a function type"), and F5 (the underivable "8/8 agree").

## RUN-P45-031 — ✅ #1631 MERGED-QUEUED. Review + repair genuinely complete for it.

Preconditions actually satisfied, not assumed: CI **12/12** at `6c3609a4`; R2 verdict **MERGE** (no
S0/S1); F1/F2/F4 **fixed and re-verified**; F5 **split out to #1634**; F3 deferred with a reason.

Enqueued via `scripts/pr.sh enqueue` — the verified helper — which **read the state back** rather
than trusting an exit code: `ok: PR 1631 is in the merge queue (state=OPEN)`, corroborated by
`isInMergeQueue: true` over GraphQL. That matters because `gh pr merge --auto --merge` has returned
**both** exit 0 and exit 1 on success in this repo, and `autoMergeRequest` reads `null` while queued
— indistinguishable from never-armed.

⚠️ `scripts/pr.sh complete` (which polls until the head SHA lands on `main`) was **blocked by the
auto-mode classifier when backgrounded**. Landing will be confirmed by polling `isInMergeQueue` /
`state` directly. **Not treating "enqueued" as "merged"** — the queue builds the PR *merged onto
current `main` plus everything ahead of it* and can still bounce.

✅ **LANDED.** `{"isInMergeQueue": false, "mergedAt": "2026-08-14T18:50:20Z", "state": "MERGED"}` —
confirmed by state readback, never by a return code. **G-0 is on `main`.**

---

## RUN-P45-032 — W5: option A landed. The hold was MORE justified than the finding that caused it.

CI **12/12** on head `41a1d77d` (ORCH-verified). Fixpoint **C3a YES / C3b YES, re-run on the
amendment rather than inherited** — which is the right instinct, since the amendment changed compiler
source after the earlier fixpoint run. Full `engines`: **553 agree / 0 differ / 0 regressions.**

### 🚨 The un-amended head would have shipped a SEGFAULT
W5's strengthened `fun_head_impl_bystander` fixture, run against `a8a226cb` (the head R1 reviewed):
**check 0, run correct, build 0, built binary `E-FATAL-SIGNAL: fatal memory fault`**, reproducible.
The *old* fixture printed `(48, True)` at exit 0 on that same commit. ⇒ the version ORCH held was one
strengthened fixture away from shipping a segfault — **not merely an acceptance narrowing.** The
fixture that could not fail was hiding a crash, not just a policy change.

### ⭐ A FOURTH acceptance reader — the brief's list was short, again
`univReceiverTag` (`= headTyconTy`) also populates the `ImplUniverse` iface→head-tag **SET** →
`implCountForIfaceU` → `checkUndeterminedObligation` **RULE 3**. That set has **TWO WRITERS** —
`insertUnivImplAt` (Flat) and `ieInsertRowAt` (IE/Module), the parallel-driver hazard — and **both
had to move**. W5 found it because repointing only the two named readers **left probes 1 and 2 still
rejecting**: the fix didn't work, so the missing reader announced itself. **"Audit the arms as a SET"
failed once more at the brief layer, and was caught once more by the writer.**

### Two ORCH brief corrections, one of which UPGRADES the fix
1. Probe 1 prints **`4`** on base, not `3`. And `4` is the **arrow impl answering a goal whose only
   concrete head is `Int`** — on base both bystanders sit in the headless wildcard bucket. ⇒ **that
   probe is ALSO a silent wrong answer on base that this PR fixes**, and the amended `3` is the first
   correct value. The fix drains more than either the PR or the review claimed.
2. F2's path is `compiler/types/registry.mdk`. ORCH's brief had said "ir/registry.mdk" (no such
   file — deliberately unbackticked here so the doc-link gate does not read a known-wrong path as a
   live citation).

### Fixture placement, decided by measurement rather than preference
The undetermined-constraint shape **cannot** live in a build-executing corpus — it E-PANICs at
`build` on **every** arm including base. W5's first cut imported it anyway and
**`diff_compiler_engines` caught it as a REGRESSION**, because a plain `medaka build` passed while
the gate's `MEDAKA_PRELUDE_OBJ` fast path does not DCE the dead binding. It went to
`test/check_json_fixtures/` as check-only with golden `"diagnostics":[]` — **which cannot pass
vacuously.**

### Goldens moved AGAIN, and a prior claim was retracted in place
`snapshots/compiler/typecheck.md`, `.../registry.md`, and **`selfproc_goldens/legA/types.typecheck.golden`**
— re-cut in `3cbea687`, blessed **by name**, LEG A **additive-only (4 lines, no existing binding's
inferred type changed)**. ⚠️ **§5 of the PR body had claimed LEG A "did not move"; W5 retracted that
in place rather than quietly overwriting it**, and corrected §4/§6/§9 the same way — quoting the
false text. §9's *"the change is inert wherever no impl head is an arrow or carries an effect row"*
is **retracted, not softened**, and replaced by three separate claims: dispatch-changed,
acceptance-restored, still-unswept.

### 🆕 Friction worth promoting out of this sprint
- **`MEDAKA_PRELUDE_OBJ`/`MEDAKA_RT_OBJ` change DCE behaviour versus a plain `medaka build`**, so a
  fixture that builds standalone can fail inside `diff_compiler_engines`. **Documented nowhere** —
  found only by replicating the exports by hand. Belongs in `AGENTS.md`.
- **`git worktree add` from the shared checkout is refused**; it must be
  `git -C <own-worktree> worktree add`. Not in AGENTS.md's worktree section.
- **`gh pr view --json body` readback differs by exactly one trailing newline** from what
  `pr.sh body` wrote — a byte-compare "fails" on a successful write. Third writer to hit a
  `gh`-write verification quirk this sprint.
- The redirect-refused-as-"too complex" harness defect again, called *"the single largest time cost
  of the session"* by this writer.

## RUN-P45-033 — R3 dispatched: a THIRD round, deliberately narrow

**Not a re-review of the PR.** R1's clears stand and R3 is told not to redo them. Scope is **only**
the `a8a226cb..41a1d77d` delta, justified by two facts: it was authored *in response to* a review so
**no fresh eyes have seen it**, and it **changes acceptance semantics in the type checker**.

Priority 1 is the **two-writer `ImplUniverse` set** — the same structural hazard as the
`evalModules`/`cevalModules` pair, where patching one path and not the other left a bug live for
months. A guard on Flat but not Module is a **flat-vs-module divergence**, and R3 is asked whether
`diff_compiler_flat_vs_onemodule.sh` even covers it. Also: whether acceptance was restored
*everywhere* or merely at the three probed shapes — including the **opposite and worse** direction,
a silent **widening** that no golden could catch, which W5's own `unchecked:` concedes was never
swept.

**ORCH will merge on a clean verdict without a further round.** Proportionality: a third pass on an
S0-fix PR whose repair touched a known parallel-driver hazard is warranted; a fourth would not be.

---

## RUN-P45-034 — R3: **CLEAN ON THE CODE. #1629 merges.** Two prose findings, filed as #1636.

R3 built real arms — BASE = this worktree's binary, `MEDAKA_STRICT=1`-verified fresh at `aaa43716`;
HEAD = cold-bootstrapped in a private detached worktree at `41a1d77d`, **no emitter borrowed.**

**Item 1 — the two-writer SET: clean, and the real structure is SAFER than W5 described.** R3
enumerated rather than accepting "two": `ieIfaceTags` has exactly one non-empty writer and **ZERO
readers** (at head *and* at base); `ImplUniverse`'s tag field has exactly one constructor-application
writer, `insertUnivImplAt`. **No third writer.** Decisively, the Module path does **not** reach the
census via `ieIfaceTags` at all — `ieUniverseAt` reads `ieUnivSnaps`, built by
`ieBuildSnapsGo → insertUnivImpl → insertUnivImplAt` ⇒ **both drivers share the ONE guarded writer**,
so the lockstep hazard ORCH was worried about cannot arise without editing the shared helper.
Measured flat vs 2-module on the same impl set: identical on each arm.

**Item 2 — acceptance: PROVED, not probed.** `censusHeadNameTy`/`headTySpineNode` are **arm-for-arm
and walk-for-walk identical** to base's `headTyconNameTy`/`headTyNode`, and `univHeadCountsInCensus`
is **extensionally identical** to base's `isSome (headTyconTy …)` gate ⇒ **no program's acceptance can
move through those readers in either direction.** That answers the question ORCH actually asked —
including the **widening** direction, which no golden could catch — by *argument over the code*
rather than by five more probes. The un-restored part (bucket placement) feeds only order-insensitive
`||`-unions and a min⊑ selector, not a first-match; five base-vs-head probes found no widening.

**Item 3 — the dispatch fix is intact:** `diff_compiler_build` 84/84 including both permutations,
`check_json` 69/69, `dict_semantics` 187/187, snapshot 202/202, fmt+lint clean, bystander binary
execs `(48, True, True)`, pins deleted and `soundness`'s must-fail step green.

**Item 4:** E-PANIC-on-base verified verbatim including the single-impl control; the check-only golden
is **non-vacuous AND fail-capable** (adding one concrete-headed impl flips it to
`T-AMBIGUOUS-INSTANCE` exit 1). ⚠️ **R3 down-graded W5's `MEDAKA_PRELUDE_OBJ` "undocumented trap"**:
it *does* change what is emitted (`withEmitHalf "program"`, `build_cmd.mdk:411`), but that is
documented at the producer **and** in `diff_compiler_prelude_obj.sh`'s header. **Not a new trap, not
worth filing** — RUN-P45-032's friction item is corrected accordingly.

**LEG A golden: additive over the WHOLE PR** — 4 added lines, **zero removals or modifications.**

### The two findings — filed as **#1636** rather than deferred verbally
- **F-R3-1 (S2)** — `test/engine_fixtures/fun_head_impl_bystander.mdk`'s header states as MEASURED
  that base agrees on all four cells. **False: base builds it and the built binary segfaults 5/5**
  (exit 139), reduced to an 8-line repro. ⇒ the segfault is **pre-existing #1618**, not introduced by
  `a8a226cb`, and **the fixture is a DIRECT REPRO of the bug being fixed, not the "bystander" it
  claims to be.** Risk is the quiet kind: a later reader told *"base agrees"* may weaken or delete a
  direct regression test for a closed S1, with every gate green.
- **F-R3-2 (S3)** — the new comment at `typecheck.mdk:4413` says `ieIfaceTags` is the census
  `ieUniverseAt` hands to `implCountForIfaceU`. **It has no reader at all.** The code is right
  (guarding a dead index is correct); the *explanation* names a path that does not exist — and the
  comment exists precisely to stop the next agent re-deriving it.

**Why filed and not fixed pre-merge, unlike #1631's F1:** these are not free edits.
`compiler/types/typecheck.mdk` is in its own snapshot corpus, so a comment change **moves its
snapshot golden**, and fixture line counts are load-bearing where a golden pins `file:LINE:COL`. The
fix carries a golden re-cut and its attendant rubber-stamp risk. #1631's F1 was two lines in a shell
script with no golden — the asymmetry is in the cost, not the principle. **Filed** so it cannot rot
into a remembered intention.

## RUN-P45-035 — #1629 ENQUEUED. Both sprint PRs are through review.

`ok: PR 1629 is in the merge queue (state=OPEN)`, corroborated `isInMergeQueue: true`. Head
`41a1d77d`, CI 12/12, three review rounds, repair applied, fixpoint C3a+C3b re-run on the final
amendment.

On merge, the body's plain unbolded `Closes #1617. Closes #1618.` fires — **closure with the landing
sha**, which is the policy's prescribed form, not a desk close. **#1630, #1634, #1636 stay open** and
are unaffected.

---

## RUN-P45-036 — ⭐ IMPLEMENTATION PHASE OPENED (2026-08-14). FOUR OWNER RULINGS (Val).

Phase 0 closed at RUN-P45-017; this entry opens the implementation phase against that closed design.
Asked once, with the Phase 0 picture in hand.

### Ruling A — **scope: 4b + Phase 4 in ONE sprint.** Two IR-moving rewrites ⇒ **two terminal
close-outs**, per the mitigation RUN-P45-007 reinstated. Phase 4 takes **route α**.

### Ruling B — **S3 (`keyForSite` repoint) is ruled ON EVIDENCE, in-sprint.** Land Q1/S1/S2, re-measure
the surviving #1182-class residual on the **built binary**, then decide. This adopts P0-G's own
recommendation (§D.1 BITE S3 `unchecked:`) rather than pre-committing to the largest IR move in the set.

### Ruling C — **#1608: adopt the GATE only.** Build RUN-P45-010's Option B typed multi-module Core-IR
gate this sprint (it also closes the fourth-engine blindness); the FIX is filed as a separate unit with
a named owner. Instrument now, fix later — the issue has been "unowned" for three consecutive sprints
and an instrument is what stops that recurring silently.

### Ruling D — **#1630 rides as bite 0**, landed FIRST and ALONE, on its own PR. It is the arm set's
third member, same organ as #1629, and a Phase 4 precondition under the same reasoning the arm set was.
⚠️ It is landed as its own bite precisely because #1629 was right not to extend its set mid-bite.

**Landing order adopted:**
```
#1630  →  Q1  →  S1  →  S2  →  X  →  ⟦close-out 1⟧  →  Phase 4  →  ⟦close-out 2⟧
       →  #1608 gate  →  ⟨rule S3 on evidence⟩
```
Phase 4 is **not** ordered against Q1 on either route (P0-G §F, verified negative); its position above
is a serialization choice under *serialize writers*, not a dependency.

**Plan of record for this phase:** `/root/.claude/plans/kind-humming-wirth.md` (owner-approved).

## RUN-P45-037 — #1182 REOPENED (third state change in one day), with a mechanical argument

Closed 03:52Z (no commit id) → reopened 06:20Z by ruling → **closed again 18:50Z, again with no commit
id, no comment, and no PR referencing it** → reopened here. Derived from the issue timeline.

What is new since the first reopen is that a **landed gate now contradicts the closure**:
`test/IFACE-ORDER-LEDGER.txt` (PR #1631) carries row `1182-unimplemented-iface-obligation-iface-order`
under the heading `── #1182 (OPEN): …`, and **`test/must_fail_census.sh` HALF 4 reds when a ledgered
issue is CLOSED**. So the desk close does not merely mis-state the tracker — it breaks a nightly gate.
The pin `test/must_fail_fixtures/1182-two-ifaces-same-method-name-order-decides/` is also still present
and was recorded "100 reproduce, 0 drained" at the Phase 3′ merge.

⇒ **A close-out desk sweep must check the PIN, not the sprint's narrative.** Twice now on this issue.
Comment posted with readback verified: `issuecomment-5298050551`.

## RUN-P45-038 — W1 dispatched: bite 0 (#1630), isolated worktree

Briefed as a transformation over named sites (`headTyNode` / `headTyconTy`), with #1629's diff as the
template, and three standing constraints stated explicitly: **do NOT symmetrize the arms with
`eval.mdk`'s `headTycon`** (it already strips `TyConstrained`/`TyEffect`; the two sides need different
arm counts), **count the readers of the changed projection two levels out** (#1629 narrowed acceptance
through three of them at 11/12 green), and the **nearest-miss** test. Refusal licensed in the brief in
the terms that earned their place on the sibling bite.

## RUN-P45-039 — S1 site census (reader, pinned to `401e3e30`, no build). Four findings.

**1. `sameTyConHead`'s absence arm is a WILDCARD, not a never-match — and that is what makes S1
byte-neutral on the flat path.** Quoted (`ast.mdk:496-507`): `sameTyConHead n1 o1 n2 o2 = n1 == n2 &&
not (tyConIdsConflict o1 o2)`, and `tyConIdsConflict` answers `False` unless BOTH origins are
identities and they differ. So the only answer that moves is *same spelling, two known different
declarations* — exactly the case the bite intends to catch. ⚠️ The contrasting rule
`ifaceIdMatches` (`ast.mdk:139-140`, `a != "" && a == b`) is the LOOKUP-direction comparator where
absence never matches; picking it here would turn every unstamped flat-driver interface into a
non-match. **This is the plan-of-record's trap 2 ("lookup and filter need DIFFERENT comparators")
appearing as a concrete choice between two named functions.**

**2. Blast radius is ONE FILE.** No member of the family is `export`ed and there is no non-comment
reference outside `compiler/types/typecheck.mdk` (hits in `core_ir_lower`, `route_key`, `registry`,
`llvm_emit` are all comments). The risk is internal plumbing, not an API break.

**3. The supply is not uniform — three grades, and the site list is now leaf-traced:**
- **Site A** (`concreteReqMatchByIface :22889`) — `findMatchingImplReqsU` already holds an `IfaceRef`
  and projects `.irName` purely to satisfy the narrow callee. Widening DELETES the projection. Zero
  plumbing.
- **Sites C / C′** (`keyForSiteByIface :20087`, `ieHeadCollidesByIface :19277`) — **the real bite.**
  The `String` lives inside two DATA declarations (`EKNestedTop`'s payload; `CountImpls`), so supply
  means widening both plus ~12 signatures. Roots trace to `CSlot.csIface` (an `IfaceRef`, projected
  to `.irName` at `:9277` and `:12480`) — recoverable, but that projection is a **documented
  deliberate decision** (route words stay spellings), and `ifaceFromDictApps` (`:26606`) reads the
  channel back expecting a `String`.
- **Root C3** (`argImplReqRoutes :20447`) — cheapest supply (`Require` already carries
  `requireOrigin`, `ast.mdk:1042`) and **highest odds of a real behaviour change**: the query origin
  is stamped by resolve on a `requires` clause while the row origin comes from `DImpl.implOrigin`.
  Different stamping paths ⇒ a disagreement silently DROPS a `requires` route.

**4. 🚨 A hazard that is dead only by a comment, not by a type.** `ifaceIdentity` (`ast.mdk:121`)
maps `OriginBuiltin` to `""` (absence); `identOriginOf` (`ast.mdk:324`) maps it to
`Some IdentBuiltin` (a real identity). Hence `sameTyConHead "Eq" OriginBuiltin "Eq" (OriginModule
"core")` is **False — a conflict**, where today's `==` on the spelling answers True. Anywhere the
widened plumbing mints `OriginBuiltin` for an interface, byte-neutrality breaks. Two comments assert
that is unreachable for an interface; **the S1 bite must verify that rather than inherit it.**

⚠️ Also flagged by the reader and NOT to be lost: `ieHeadCollidesByIface` decides which word
`keyForSiteByIface` stamps (canonical vs bare). A count falling 2→1 under the widened comparator is a
**dict-cell byte change**, and `core_ir_lower.ifaceDeclHeadUnique` counts over a different table and
would not follow — the skew the file's own `:19315-19330` records as previously producing exit 0 plus
a segfault. **The S1 bite's byte-identical bar is therefore load-bearing, not ceremonial.**

## RUN-P45-040 — 🚨 Q1 BLAST-RADIUS CENSUS: Q1 as specified REJECTS A PROGRAM THE TREE PINS AS CORRECT

Reader, pinned to `401e3e30`, layout-block parser (not grep), no build. 3165 `.mdk` files · 657
declare an interface · 101 declare ≥2 · **10 files collide intra-module.**

**The good half — Q1 is shippable as stated:**
- **`compiler/` declares ZERO interfaces**; `stdlib/` declares 23, all in `core.mdk`, **pairwise
  disjoint** method sets (nearest misses `Index`/`IndexMut`, `Applicative`/`Thenable` — no overlap).
  So Q1 breaks neither the compiler's own build nor the prelude.
- Two `must_fail` pin dirs (#1182, #1620) stop compiling ⇒ **the pins DRAIN**, which is the shape the
  #1182 claim itself names as one of its two viable fixes.
- Two ledgered `iface_order` rows converge ⇒ RED on `diff_compiler_iface_order.sh`, which is that
  gate's **documented drain path**, not a break.

**🚨 The half that needs an owner ruling — Q1 destroys the G-0 instrument's two UNLEDGERED CONTROLS,
and one of them is a legal, order-invariant, working program:**
- `test/iface_order_fixtures/control-shared-method-name-disjoint-receivers/` — two interfaces share
  method `n`, implemented at **disjoint receiver types**; `case.txt` asserts `n U + n V == 3` at
  exit 0 **in every ordering**. Nothing about it is ambiguous at any occurrence. **Q1 rejects it.**
- `test/iface_order_fixtures/negative-1182-impl-axis-shape-is-iface-axis-invariant/` — same fate.
- These controls are what **bound what the ledgered rows are evidence for** (their own `case.txt`
  says so). Losing them silently converts G-0 from an instrument into a tautology: every case
  rejects, so every case "agrees".

⇒ **Q1 is not purely a repair of an invariant the tree already believes.** `methodIfaceParamsRef`'s
header claims resolve rejects the ambiguous case; the control proves the *unambiguous* case is
legal today and works. Rejecting on DECLARATION alone narrows acceptance for working programs.

**⚠️ Second unmeasured axis, and it is the one that could blow the radius open:** the census compared
interfaces **textually in the same file only**. `resolve.mdk` seeds `pIfaces`/`expIfaceMethods` from
`preludeDecls` (`:1608`, `:2763`, `:2836`). **If Q1's "one module" is read to include the implicit
prelude, every user interface declaring `map`/`eq`/`compare`/… collides** and the radius is not 10.
The bite must state, in code and in its PR body, that its scope is *interfaces declared in the
module's own source*, and pin that with a fixture. The prelude-vs-user axis belongs to SHADOW/#1499.

**Also recorded from the census (not acted on):** 29 directories carry genuine CROSS-module
collisions co-loaded into one program — the population Q1 deliberately does NOT reach, outnumbering
the intra-module population ~3:1. The two populations are disjoint in practice (no directory holds
both shapes), which is the practical check P0-G's *"Q and S are not redundant"* claim needed.

## RUN-P45-041 — ⭐ OWNER RULING (Val): Q1 rejects on DECLARATION. The controls are re-posed.

Asked with the census in hand (RUN-P45-040), not up front.

> **Keep P0-G's rule as designed: two interfaces in one module may not share a method name, period.**

Three things this ruling BINDS on the bite, so none of them can be quietly dropped:

1. **It narrows acceptance for a working shape, and the bite must SAY SO** — in the diagnostic's
   `help` text and in the PR body's Q6 answer. The disjoint-receiver program
   (`n U + n V == 3`, exit 0, order-invariant) compiles today and will not after. That is a
   deliberate cost bought for a decidable rule at resolve, not an oversight.
2. **G-0's two unledgered controls must be RE-POSED in the same bite**, on a shape Q1 permits, so the
   instrument keeps the bound its ledgered rows rest on. A gate whose every case rejects agrees with
   itself vacuously. ⚠️ The replacement control must be **proven able to fail** (mutate, watch it
   red, revert) — a control that cannot fail is the masking path this sprint's own attack list names.
3. **The rule's SCOPE is the module's own declared interfaces — NOT the implicit prelude.** If the
   check is written over the seeded set (`pIfaces`/`expIfaceMethods`, seeded from `preludeDecls` at
   `resolve.mdk:1608,2763,2836`), every user interface declaring `map`/`eq`/`compare` is rejected and
   the blast radius stops being 10. **Pin the prelude case with a fixture that must still compile.**

## RUN-P45-042 — 🚨 P0-G's Q1 PREMISE IS REFUTED, and the refutation makes Q1 CHEAPER

Reader, pinned, no build. P0-G §C.1 asserts — with three derivations — that
*"resolve has NO value-name duplicate check at all."* **False.** Five exist [read]:
`R-DUPLICATE-DEF` for duplicate **type**, **constructor** and **interface NAME**
(`resolve.mdk:1928`/`:1929`/`:1930`), plus `R-DUPLICATE-SIGNATURE` (`:1734`) and `R-DUP-BINDING`
(`:1762`). What P0-G is *right* about is narrower and is documented as deliberate at `:1720-1733`:
there is no check for a multi-clause function-name collision without a repeated signature.

⇒ **Consequence for the bite, and it is good news: `resolve.mdk:1930` IS the template, line for line.**

```medaka
duplicateErrors preludeDecls prog =
  let ifaceSeed = whenL seed (map fst (interfaceList preludeDecls))
  … ++ map (dupErr "interface") (findDups ifaceSeed (map fst (interfaceList prog)))
```

It already demonstrates the **exact prelude-exclusion mechanism RUN-P45-041 rules for**: the module's
own set is `interfaceList prog`; the prelude enters only as a *seed*, which Q1 simply **omits**.
Imports are not in the picture at all — `buildErrors` (`:1664`) has no `known` table, and it is the
one import-independent error pass BOTH resolve entry points run (`:2056`, `:2064`, `:3096`). So the
ruled scope is achieved by construction at that site, not by a guard.

⚠️ **Rejected placements, with what each gets wrong:** `checkInterfaceDecl` (`:1379`) sees only `Env`,
whose `interfaces`/`ifaceMethods` are **prelude+imports-merged** (`:1624-1625`, `:2784`) — wrong set;
`buildEnvMM` (`:2763`) is multi-module only, so a check there is **invisible to `medaka check
one.mdk`**; `expIfaceMethodsDirect` (`:2930`) is `pub`-filtered and carries re-exports — wrong on
both ends.

**Three constraints the writer must carry:**
1. **`interfaceList` has NO `DAttrib` arm** (`:1509` falls to the wildcard) while `interfaceNamesOf`
   (`:4133`) recurses into it. An `@attrib`-decorated `interface` is **invisible** to the template
   function — the #1228 family exactly. Follow `interfaceNamesOf`'s shape, and pin an attributed
   interface in the fixture set.
2. **`DInterface` carries NO `Loc`** (`ast.mdk:1210`; `declLoc` `:1871` has arms for `DAttrib`/
   `DFunDef` only, so `DInterface` hits `_ = None`), and `IfaceMethod` (`ast.mdk:1021`) has none
   either. Per-method name spans exist ONLY in the parser (`declNameSpanOf`/`methodNameIdxs`) and do
   not survive to resolve. ⇒ **The diagnostic will be location-less like its sibling
   (`dupErr … None`), or best-effort via `firstTyLoc`** — and `firstTyLoc` yields `None` for a fully
   parametric signature. "Point at the second declaration" is not achievable here without an AST
   change. Say that in the PR rather than shipping a wrong span.
3. **Resolve is PURE — there is no `pushResolveError` family** (`resolve.mdk:8`). A new `ResError`
   constructor must touch its five exhaustive consumers: `data ResError` (`:93`), `resErrorLoc`
   (`:214`), `resErrorSexp` (`:1971` — feeds the `resolve_modules` gate), `ppResError` (`:2078`),
   `resErrorCode` (`:2140`); `resErrorDidYouMean` has a wildcard and needs nothing. Goldens that move:
   `test/snapshots/compiler/resolve.md` and `test/check_json_fixtures/*.check_json.golden`.

⭐ **Direct authority for the scope ruling, found by the reader:** the RESERVED row
`W-PRELUDE-METHOD-SHADOW` (`DIAGNOSTIC-CODES-DESIGN.md:280`) specifies the *prelude*-collision case as
a **warning, explicitly not an error**, per `SHADOW-SEMANTICS.md` S1-PRELUDE, owned by **#1499**. So
Q1 rejecting a prelude collision would not merely be over-broad — it would **contradict a written
spec ruling and pre-empt another issue's deliverable.**

## RUN-P45-043 — BITE 0 LANDS AS PR #1638 (open, unenqueued). The brief was RIGHT this time.

Unlike the sibling bite, the briefed site and mechanism held: one arm,
`headTyNode (TyConstrained _ t) = headTyNode t`. `eval.headTycon` deliberately untouched (it already
had the arm) and `Mono` needs nothing (it has no constrained constructor) — the two sides keep
DIFFERENT arm counts, which is the documented correct state.

Cells, C3a/C3b, golden accounting and the four DEBT fields: `.claude/sprint-phase45/DEBT.md`, bite 0.

**ORCH verification of the PR itself (evidence, not re-running):** three commits in the required
shape (source · pin · terminal goldens); the body's only closing keyword is `Fixes #1630.` — nothing
else is aimed at an issue that must stay open; CI running, `backend`/`sqlite`/`seed-health` already
green. Two adversarial reviewers dispatched — **semantics** (arm-set completeness, the headless-body
scoping claim, the acceptance-reader claim, `nothing → something` against the spec, the pin's
discrimination) and **evidence/prose** (every shipped sentence traced to a command) — following the
#1319 finding that the two lenses catch disjoint sets.

## RUN-P45-044 — TWO TOOLING GAPS FOUND BY THE BITE, both reproducible for the next agent

Recorded because both are structural, not one agent's bad luck:

1. **`make medaka` bakes the source fingerprint at STAGE A START**, so any compiler-source edit made
   *while a build is in flight* — a comment is enough — silently yields a binary lacking it, which
   then fails `MEDAKA_STRICT=1` on every subsequent probe. Cost one full rebuild. The remedy is a
   rule, not a tool: **do not edit compiler source while a build is running.**
2. **`PRECOMMIT_SNAPSHOT_DEFER=1` does NOT reach the #1179 unstaged-snapshot guard.** Consequence: the
   standing *"goldens re-cut in their own terminal commit"* rule and any LATER commit that stages a
   `.mdk` are **mutually exclusive** under the current hook — the guard refuses the `.mdk`-staging
   commit while a blessed snapshot sits unstaged. The writer worked around it by stashing the goldens
   across the fixture commit (no `--no-verify`, no `hooksPath` override). ⇒ Ordering rule for this
   sprint: **stage the goldens LAST, after every `.mdk`-staging commit is in.**

Both landed as AGENTS.md lines in this sprint's docs commit so the next agent inherits them.

## RUN-P45-045 — EVIDENCE-LENS REVIEW OF PR #1638: 4 real findings, and the split earned its keep

The prose lens found things the semantics lens is not looking for, exactly as the #1319 split predicts.
**None of them is wrong code.** All four are claims reaching past their evidence — the arc's dominant
defect shape, ninth consecutive instance.

**F1 (MEDIUM-HIGH) — a live fixture header still asserts the ruling this PR falsifies, WITH cells.**
`test/dict_fixtures/s3-fn-typed-impl-heads-discriminated.mdk:35-38` says #1630 is *"still `check=0
run=0 build=1` on this binary"* — a present-tense measurement that becomes false the moment this PR
lands, in a file the PR **does not touch**. The PR carefully corrects `eval.mdk`, `registry.mdk`,
`headTyNode`'s header and the gate ledger, and misses the sibling FIXTURE carrying the same ruling.
⇒ **This is the mechanism that created #1630 in the first place**, reproducing one file over.

**F2 (MEDIUM) — a CORRECTING comment overshoots in the other direction.** The new `eval.mdk` text says
#1617 is *"one that builds and E-PANICs"*. Three in-tree records say `build` **exited 1**
(`diff_compiler_dict_semantics.sh:402`, the fixture header, `PLAN.md:1837`), and the message is minted
in `llvm_emit.mdk:5588` — the EMITTER panicking, so no binary exists. The same sentence folds all
three arm-set members into *"CHECKS and RUNS"*, erasing that #1617's `run` was **wrong and
order-dependent** while #1618's and #1630's were correct. A comment written to fix an over-general
comment, restating a sibling's cells in the "less broken" direction.

**F3 (MEDIUM) — the enumeration of the walk that ACTUALLY CHANGED is 3 of 4.** `headTyconTy` has three
call sites; the PR names `keyEntryOf` and `univReceiverTag` and never mentions **`keyEntryOfRow`**
(`:19123`), which feeds `ieSelectRowByIface` — the very selector the NEXT bite widens. ⚠️ Note the
polarity: the PR follows the **untouched** census walk to its leaves and gives a one-hop list for the
walk it **did** change. That is backwards, and it is trap 3 from `HANDOFF.md` verbatim. **Relayed to
the semantics reviewer as ITS claim to verify, with the two questions that decide whether it is a
defect or a sentence.**

**F4 (MEDIUM) — three precise counts no shipped table supports.** *"all 10 programs"* over tables
containing 8; *"the six newly-buildable programs"* where 5 rows go `build 1 → 0`; and *"`build` +
executed the produced binary — all 10, both arms"*, which is impossible as stated because the pre-fix
arm produced **no binary** and the overlap row rejects at `check` on both arms — the body says both
things itself. `DEBT.md` describes the same work as 7. **Three artifacts, three counts.** The
underlying row-by-row table is real evidence; the summary numbers on top of it are not derived from it.

**Four minor:** the falsified quote is attributed to *"#1617's commit body"* (an issue has none; it is
PR #1629's commits `e051788b`/`699f0b5b`) in two SHIPPED artifacts while commit 1 gets it right;
`registry.mdk:970`'s *"for both"* is stale at three after this PR's own insertion; `unchecked:` omits
`typecheck_compiler_source.sh`, the gate `AGENTS.md:556` names for this exact change class; and one
commit message mixes an exit code and a printed value in adjacent cells (`run 0` then `run 2`).

**Checked and CLEAN, worth recording because it is the part most likely to have rotted:** exactly one
closing keyword (`Fixes #1630.`); the negative result is stated as *structural, not demonstrated* in
source, body and commit alike with **no sentence anywhere softening it to benign** — the best-handled
part of the PR; `"measured benign"` survives nowhere else in the tree; all three golden line-count
deltas re-derive from the diff; the `202/202` string is a verbatim instance of the script's own success
format, not a reconstruction; and Q4's *"I looked for a fourth member and did not find one"* is backed
by an enumeration that is present and correct.

⇒ **Repair set for bite 0, to be applied before enqueue** (queued behind W2 under serialize-writers):
F1, F2, F3's sentence, F4's counts, and the four minor. **F3's SEMANTIC half is not a repair item until
the semantics reviewer rules on it.**

## RUN-P45-046 — SEMANTICS-LENS REVIEW OF PR #1638: could not break the fix; two findings, both UPWARD

Method worth recording because it is the bar: **three cold-built arms** — FIX (`906bae74`), BASE (the
one line reverted, rebuilt), and **NARROW (the reviewer wrote the special-case fix the pin claims to
catch, and rebuilt)** — 25 probe programs, every verb redirect-then-read-`$?`, env checked free of
`MEDAKA_ROOT`/`MEDAKA_EMITTER`.

**The fix holds.** Arm set complete (`Ty` has 8 constructors; after the peel set and the classifier
arms the residue is `TyVar`, correctly headless, and `TyRow`, which is **rejected at the kind check on
all three arms** so it never reaches dispatch). Headless preserved **byte-identically**. `check`
stdout and exit code **byte-identical on all 25 programs across BASE and FIX** — no acceptance move,
attacked directly at overlap, duplicate constrained heads, no-impl misses, undetermined receivers,
specificity-with-`requires`, and cross-module. Spec conformance derived BEFORE invoking: DICT §3
compares *heads only*, contexts play no role ⇒ the head of `impl Sz (Eq a => Int)` **is** `Int`; the
IR agrees on both sides of the seam (`@mdk_impl_Int_sz` at definition and call site).

**Pin verified the hard way:** on BASE, `diff_compiler_dict_semantics` fails **exactly the 2 new rows**
and nothing else; on NARROW, **the effect fixture fails and the other passes** — i.e. the second
fixture does precisely the discriminating job its header claims. That is an able-to-fail proof AND a
discrimination proof, which is more than the bar asked for.

### ⭐ F1 (CONFIRMED, in the PR's FAVOUR) — the fix also closes SILENT WRONGNESS, and the PR under-claims
```medaka
impl Sz (Eq a => Box Int) where sz _ = 13
impl Sz (Box Bool)       where sz _ = 14
main = println (sz (Box 1) + sz (Box True))     -- spec answer 27
```
**BASE: `run` prints 26 at exit 0** — both calls took 13. FIX: run, build and the executed binary all
**27**. Two more BASE `run` failures the fix removes (`E-NOT-A-FUNCTION`, `E-PANIC: unknown op '+'`).

⇒ **Both new fixture headers and the `headTyNode` comment assert *"`check` and `run` were both already
CORRECT"*. True of the PINNED one-impl shape, FALSE of the class.** #1630's S1 grading is likewise
scoped to the reported shape; the neighbour is an S0. This is
[[feedback_severity_is_a_repro_artifact_not_a_defect_identity]] arriving from the good direction —
and it is a *stronger* claim than the PR makes, so it must be corrected upward, not left.

### 🚨 F2 (CONFIRMED) — the "tried and FAILED" negative in the new comment is FALSIFIED. Pre-existing.
The PR's `censusHeadNameTy` comment records that #1630 *"tried and FAILED to build a program that
observes"* the census residual. The candidate it used had the constrained impl as the interface's
**only** impl — but `checkUndeterminedObligation` RULE 3 is guarded on `implCountForIfaceU >= 2`, so a
one-impl program **cannot reach the arm the residual disables.** With two impls:

| head | check | run | build |
|---|---|---|---|
| control, plain `Int` | **1** — *"Ambiguous instance for 'Zero'…"* | — | — |
| constrained `Eq x => Int` | **0** | 5, exit 0 | **1** — `E-PANIC: arg-tag dispatch … not supplied` |

Measured **identically on BASE, FIX and NARROW** ⇒ arm-invariant, **not introduced by this PR**. The
same shape with #1618's effect wrapper behaves identically, so the phrase *"structural, not
demonstrated"* is now falsified for **two of the three wrappers**. Severity as measured: **S1**.

⚠️ **And its deferral points at a CLOSED issue** — the comment routes the ruling to F-3c (#1155).
**Nothing open owns this residual today.**

⇒ ORCH is reproducing F2 first-hand before filing (a binary is building in the orchestrator worktree).
**Do not file an agent's claim unreproduced** — the rule this arc keeps paying for.

### Repair set for bite 0 — GROWN by this review
The prose repairs from RUN-P45-045, plus: **(a)** correct *"check and run were both already correct"*
in the two fixture headers and the `headTyNode` comment — the class includes a silent-wrongness
neighbour; **(b)** replace the *"tried and FAILED"* paragraph rather than shipping it, and drop the
dead #1155 deferral; **(c)** the author's acceptance argument (*"goes through `censusHeadNameTy`"*) is
**narrower than the real surface** — three other consequences exist (`univReceiverTag`'s bucket move
feeding `implMatchesU`, the two `ieHeadCollides*` gates, and `implEntryFromTys` now registering
`requires`-bearing constrained impls) — and the conclusion survives measurement, but the PR should
state the surface it actually attacked. **F3 from the prose lens (`keyEntryOfRow`) is answered by
this review's Q3 surface: it is a routing reader, and the 25-program acceptance sweep found no move.**

## RUN-P45-047 — ORCH REPRODUCED BOTH AGENT FINDINGS FIRST-HAND. One filed, one routed to an existing issue.

Neither was relayed on an agent's word. Cold-built binary in the ORCH worktree (base — no sprint fix
present, which is what a *pre-existing* claim requires), `MEDAKA_STRICT=1`, env clean,
redirect-then-read-`$?`.

**Filed #1641 (S1, `verified`)** — the census residual, reproduced exactly as the semantics reviewer
described: `impl Zero (Eq x => Int)` alongside `impl Zero Bool` with an undetermined receiver gives
`check` **0** / `run` **5** / `build` **1** (`E-PANIC: arg-tag dispatch … not supplied`), where the
byte-identical plain-headed control is **rejected at check** with *"Ambiguous instance for `Zero`"*.
The issue records the mechanism (`censusHeadNameTy` → `headTySpineNode` does not peel the wrapper, so
`checkUndeterminedObligation`'s `implCountForIfaceU >= 2` guard is never met), that it is
**arm-invariant hence pre-existing**, that the **effect wrapper does the same thing**, and that its
former owner **F-3c (#1155) is CLOSED** so nothing lived here. A must-fail pin is recorded as owed.

**Routed to #1228, not filed separately** — the `@attrib` finding. Reproduced, and then graded one
step further than the reporting agent took it: the attributed `interface` is **dropped entirely**
(`Unbound variable: aa` at the use site, loud, exit 1 in all three verbs), which is #1228's exact
mechanism one namespace over — a `DAttrib` wrapper falling through a wildcard arm. ⇒ A comment on
#1228 with the derivation, not a duplicate number.

⭐ **But the probe found something the "same as #1228" reading would have missed, and it is the half
worth keeping:** the drop **silences a rejection that otherwise fires**. Two same-named interfaces are
rejected today (`Duplicate interface: Dup`); put `@inline` on the first and `check` exits **0** with
*"1 declaration(s) checked"* — the declaration is gone before `duplicateErrors` ever sees it. **An
attribute is currently a way to switch a duplicate-declaration rejection OFF.** That is a different
failure shape from #1228's use-site consequence: a check that does not run, with no diagnostic at all.
Same root cause, so same issue — recorded there rather than split.

⚠️ Directly load-bearing for THIS sprint: a new rejection written over `interfaceList` inherits that
blindness **silently**. W2 wrote its own attribute-aware walk for exactly this reason, and proved the
premise on the binary rather than asserting it.

## RUN-P45-048 — ⚠️ ORCH ERROR: I misrouted a coordinator message INTO A LIVE WRITER'S CONTEXT

The `keyEntryOfRow` lead was addressed to the semantics reviewer and sent to **W2's** agent id, mid-bite,
while W2 was writing Q1 in `resolve.mdk`. It concerned another PR, another file, and questions W2 was
never asked.

**W2 handled it correctly** — refused the binary experiments as not its bite, ran only the one cheap
grep, reported that the structural claim holds, and asked me to route it back to its owner. The
semantics reviewer had meanwhile reached the same surface independently, so nothing was lost.

**The lesson is mine, not W2's.** *Parallelize readers, serialize writers* protects the tree; it does
not protect a writer's ATTENTION, and an orchestrator message is an unaudited write straight into it.
A misaddressed brief is indistinguishable, from inside, from a scope change. **Address by role, and
re-read the id against the dispatch record before sending — the ids differ by two characters.**

## RUN-P45-049 — ⭐ TWO ORCH RULINGS ON Q1's CONVERGED SIGNALS (PR #1640)

Both were correctly refused by W2 rather than decided in-bite. Both reds are LICENSED and expected:
`gates (eval)` = `iface_order`, `soundness` = `must_fail`.

### Ruling 1 — the two `iface_order` ledger rows are DELETED. The issues stay OPEN.
Converged, STATE 3, identical for both rows:
`check=1;codes=R-DUPLICATE-IFACE-METHOD;schemes=;run=1:;build=1/-:` — an `R-*` prefix, i.e. a resolve
rejection, not the `T-NO-IMPL` trap the four-state table warns about. Both orderings now reject
identically, so **the divergence those rows pinned does not exist on this axis any more** and the two
cases become ordinary invariant (unledgered) cases — which is a *stronger* guard than the row was.

🚨 **The row deletion must NOT be read as a drain of the issue, and the ledger must SAY so.** The
gate's four-state table pairs "converged" with "close the issue and delete the row"; here Q1 fixes only
the **intra-module** half, while #1182/#1620 survive on the **cross-module** axis (a census found 29
directories carrying that shape, which this corpus does not reach). A bare row deletion would read, to
the next agent, as *"issue drained"* — and #1182 has already been desk-closed **twice** on exactly that
kind of inference. ⇒ **W2 adds a header note naming the axis split and the surviving population.**
Mechanically safe: `must_fail_census.sh` HALF 4 reds when a *ledgered* issue is CLOSED; an open issue
with no row is not a violation.

### Ruling 2 — #1182's must-fail pin is RE-POSED onto the cross-module axis.
It reports `CONTROL-BROKE`, and the harness's printed advice (*"the ENVIRONMENT moved, not the bug"*)
is **wrong for this case**: the control is itself a two-interface module, so Q1 rejects it too. The
pin's whole signature moved, not its subject alone.

The bug #1182 states — *impl-block order decides which impl runs* — **still reproduces cross-module**,
which is where the issue now lives. ⇒ Re-pose the fixture there: keep the assertion, move the shape to
two modules. Hand-derive the expected cells; do not capture them. If the cross-module shape turns out
NOT to reproduce, that is a finding and the pin goes to `MUST-FAIL-NOT-PINNABLE.txt` with the reason —
**not** a quiet deletion.

⚠️ Both rulings preserve the invariant that matters: **an open bug keeps a live, self-draining pin.**
Neither issue is closed by this PR.

### Throughput note, recorded against myself
These two rulings sat unmade for ~15 minutes while I filed #1641 — a finished bite parked on the
orchestrator's desk. That is the Stage B `0.73×` bottleneck reappearing in a new shape: not gaps
between writers, but a **decision queue**. The fix is the same one that worked earlier tonight —
rule on receipt, do the ledger work afterwards.

## RUN-P45-050 — BOTH Q1 RULINGS LANDED, and the row deletion COST A TRIPWIRE (W2 caught it, I did not)

PR #1640, two more commits. `diff_compiler_iface_order.sh` **5 ok / 0 failing (GREEN)**;
`diff_compiler_must_fail.sh` **98 fixtures, 97 reproduce, 1 DRAINED, 0 control-broke, 0 malformed**.
`soundness` stays red on #1620's drain alone. Neither issue closed.

**W2 verified my census premise rather than taking it** — HALF 4 is row-driven, so an open issue with
no row is not a violation. My reading was right.

🚨 **But it recorded a consequence my ruling did not mention, and it is the ruling's real cost:**
deleting the rows also deletes the HALF 4 **tripwire** — the coupling that catches someone closing
these issues on a partial fix, which HALF 4's own header calls *load-bearing*. What survives is
HALF 1 (PINNED-BUT-CLOSED), which reaches **#1182** through its re-posed fixture and **#1620 not at
all**. ⇒ I ruled a guard gap into existence; closing it is mine, not scope creep. **#1620 is being
re-posed cross-module in the same bite.**

⭐ **Ruling 2's re-pose is STRICTLY STRONGER than the fixture it replaces, and the derivation came
first.** Hand-derived before measuring, right on every cell: entry imports the method name from `a1`
only and `a2` for its interface name only, so the occurrence of `m` has **exactly one binding** — and
printing `2` runs a method of an interface the occurrence never named. **Wrong under every reading**,
so #1182's name-resolution dispute is gone from the pin. (Importing `m` from both does *not*
reproduce — `Ambiguous occurrence`, measured.) `check --json` clean at exit 0 across three files;
`run` and the **built binary** both print `2`, so it is not an eval artifact.

**The misleading `CONTROL-BROKE` is now twice-observed and written into `claim.txt` as a general
rule** — the harness's *"the ENVIRONMENT moved, not the bug"* advice is wrong whenever the control
shares the subject's rejected shape.

**Filings authorised** (W2 reproduced all three first-hand, so it is the reporter): the
`capture_goldens.sh boot_resolve` remedy string naming a command that cannot work; and the
interface-order-dependent **diagnostic set** — which also refutes the `iface_order` header's *"cannot
even be written"* claim, with an explicit instruction to state whether it was measured pre-Q1,
post-Q1 or both. **The third was STOPPED** — the `@attrib` duplicate-name shape is already routed to
#1228 with a first-hand reproduction; adding a number would duplicate.

⚠️ `gh pr edit --body-file` **silently no-op'd** on this PR's body — byte-identical readback, exit 0,
only a projects-classic warning on stderr. `scripts/pr.sh body` landed it. Known trap, hit again.

## RUN-P45-051 — REPAIR ROUND APPLIED (PR #1638). W3 DISPROVED TWO OF MY ELEVEN, and found a third thing.

Two commits (`5074fc24` repair, `699cd6b8` goldens). **The one-line fix is untouched — W3 filtered the
repair commit's `compiler/` diff and it is 100% comment lines, zero non-comment changes.** Final gate
on the committed tree: **exit 0, 191/191 assertions.**

### ⭐ The finding neither the brief nor either review had: #1630's class is ORDER-DECIDED
Pre-fix, the two-impl program prints **26**; **reversing the two impl blocks makes it 28** — still
exit 0, still `check` clean. That is **#1617's signature at #1630's constructor**: a silent,
declaration-order-dependent wrong answer. The fix arm prints **27 in both orders**, and W3 added a
permutation row to the gate's Section 4 grading exactly that.

⇒ This lands #1630 squarely in **the conjunct-1 family this sprint exists to drain**, which nobody had
claimed. It also means the bite-0 severity story is now: filed S1 (loud at `build`) → the class also
contains **S0 silent wrongness** → and that wrongness is **order-dependent**. Three gradings of one
defect, each correct for the shape that produced it.
[[feedback_severity_is_a_repro_artifact_not_a_defect_identity]], third instance in this arc.

### 🚨 TWO OF MY ELEVEN REPAIR ITEMS WERE WRONG. Both were mine relaying a reviewer's cells.
1. **A1's second error string does not reproduce.** I briefed `E-PANIC: unknown op '+'` for a
   return-position shape. Measured: a one-impl return-position constrained head is **correct pre-fix**
   (`run` 106; only `build` fails); a two-impl one fails as `E-NONEXHAUSTIVE-MATCH`; the `requires`
   shape reproduces but prints `applied non-function: 21`, **not `1`**. W3 recorded what it measured
   plus a note that my strings were not reproduced.
2. **B5's citation was half wrong.** I named commits `e051788b` **and** `699f0b5b`; `git log -S` finds
   the phrase in **`e051788b` alone**. The corrections cite that commit only.

**This is the review lesson eating its own author.** I wrote eleven items telling a writer that every
claim must trace to a command — and two of mine were relayed cells I had not re-derived. W3 checked
them rather than complying, which is the third time this sprint that briefing for refusal has paid.
[[feedback_dont_launder_an_agents_observation_into_your_inference]].

### 🚨 `gh pr edit --body-file` has a FOURTH failure mode: SILENT TRUNCATION
Wrote **16,769 of 29,266 bytes at exit 0** — whole sections dropped from the middle. Every prior
instance left the OLD body intact, so *"did it change?"* was a sufficient test; truncation **changes**
the body, so a length-changed check passes and the missing half is exactly the evidence a reviewer
needs. **Size-dependent** — small bodies landed fine in the same session. ⇒ **byte-compare the
read-back against the file**, which is what `scripts/pr.sh body` already does. Recorded durably in
the standing memory rather than only here.

### Goldens
Three snapshots (comment-only edits) blessed **by name**, plain re-check **202/202**. W3 read the diff:
comment lines plus exactly three `source_lines=` counters, nothing else — the complete expected
footprint. Staged **last**, all four hook checks live on the terminal commit. `selfproc_legA` cannot
move (comment-only compiler diff). New pin row proven able to fail: `27 → 28` reds **that row alone**
across all 91 units; reverted, 191/191.

## RUN-P45-052 — S1 LANDS AS PR #1643 (open). Bar: 391/391 byte-identical IR. One ruling, one flag.

Nine functions widened `String` → `IfaceRef` (the 7-member `*ByIface` family + `concreteReqMatchByIface`
+ `selectReqImpl`), plus one new seam `ieRowIfaceMatches`. W4 confirmed first-hand that nothing in the
family is exported and there is no non-comment reference outside `typecheck.mdk`.

**Evidence:** 391/391 byte-identical across six corpora (`differing=0 missing=0`); 330 produce real IR,
the other 61 are error fixtures compared on **build status**, all 61 agreeing. **Positive control run** —
injecting one byte into one `.ll` and one wrong status into another makes the harness report
`differing=2`, naming both. **C3a YES, C3b YES**, separate verdicts. Plus `check-self`, `make test`,
dict-semantics, iface_order, import_order, selfproc 16/0, lex_files, diff_native_cli.

**ORCH verified the legA golden myself** (not from the report): the diff is exactly the nine re-signings
plus the one added binding; **no pre-existing binding's inferred type changed**. A zero IR diff beside a
moved scheme golden is consistent — the golden records declared types, the IR records behaviour.

### ⭐ The neutrality is STRUCTURAL, not merely measured — and W4 said so without being asked
Because every query is minted `ifaceRefBare` (absent origin), `tyConIdsConflict`'s `(Some, Some)` arm
is **unreachable**, so a row minted `OriginBuiltin` cannot conflict with an absent query *regardless* of
the invariant. ⇒ W4 **declined to certify the `OriginBuiltin` invariant** and flagged it in `unchecked:`
as **S2's obligation**, since S2 is what makes that arm reachable. That is the right shape of answer:
it did not need the invariant, so it did not claim it.

### ⭐ RULING (ORCH): the count/collision test STAYS SPELLING-KEYED. S1's choice stands.
W4 threaded `IfaceRef` through `ieCountHeadByIface`/`…Go` but left the comparison as
`ir.irName == iface.irName`, citing the file's own #1317 derivation — the route-word collision question
is inherently spelling-scoped because three engines re-derive that word from a bare `String` tag. **It
flagged this rather than deciding it silently, and its bar could not distinguish the two choices.**
Ruled: **the shipped design already says this** — B-2.2 kept the collision *test* spelling-keyed on
purpose so the checker's stamp keeps matching `core_ir_lower.declRouteKey` byte for byte, while identity
moved onto the FIELD. The reasoning is the design's, not W4's invention. Relayed to S2 with an explicit
licence to overturn it on evidence.

### ⚠️ ORCH's own follow-up, because the headline number invites a vacuity error
`sameTyConHead` can differ from `==` in **exactly one situation**: two interfaces sharing a SPELLING with
two known, different origins. **If no program in those six corpora contains that shape, 391/391 identical
is precisely what a no-op produces** and the bar proves far less than it appears
([[feedback_a_byte_identical_bar_on_unread_code_is_vacuous]]). A reader is enumerating the corpora for
the discriminating shape now. **This is not a doubt about the code — it is a question about the inputs**,
and it is the same question that let #1381's engines gate stay green while a layout bug shipped.

## RUN-P45-053 — S1's BAR IS DISCRIMINATING, NOT VACUOUS. And the census hands S2 its control corpus.

The falsification hypothesis fails, cleanly. `sameTyConHead` can differ from `==` in exactly one shape —
two interfaces sharing a SPELLING with two known, different origins — and the corpus carries it:

| corpus | projects | cross-module same-spelled iface | produce IR |
|---|---|---|---|
| `llvm_fixtures_modules` | 56 | **5** | all 5 |
| `dict_fixtures` | 88 | **13** | 8 (5 more are build-REJECT, graded on status) |
| the other five corpora | 320 | 0 | — |

⇒ **13 discriminating projects, 13 of them reaching emitted IR.** A regression from `sameTyConHead`
back to spelling `==` has somewhere to bite. ⚠️ The reader flagged that its 13 collapses to 5 **if**
S1's harness consumed the existing dict gate's verdicts instead of building IR itself — it did not;
W4 ran `medaka build --keep-ir` over all six corpora (dict_fixtures' 88 are inside the 391). The 13
stands, derived rather than assumed.

⭐ **The load-bearing single carrier: `test/dict_fixtures/s6-c1-xmod-same-spelled-ifaces-accepted/`** —
`amod.mdk` and `zmod.mdk` each declare `interface Same a` with disjoint methods, both impl'd at head
`Int`, entry using one method from each. Its own ledger row names the mechanism: *"`CohImpl`'s interface
half is an `IfaceRef` compared through `cohSameIface`/`sameTyConHead` … re-key that half back to
spelling and it reds."* Its `!T-CONFLICTING-IMPL` assertion is what makes it fail-capable, and its
header warns the **shared head `Int` is load-bearing** — two module-local heads would mask the interface
half entirely, because the head half is already identity-aware.

### ⚠️ The caveat that matters, and it is S2's not S1's
The reader verified the same-SPELLING shape, **not** that both `IfaceRef`s arrive **origin-tagged** at
the selector. Under S1 they demonstrably do not — every query is `ifaceRefBare` — so under S1 these
fixtures are no-ops **by construction**, which is exactly why S1 is neutral. **The discrimination is
latent: it activates when S2 supplies real origins.** ⇒ These 13 are S2's positive controls, and *"they
still pass"* is only meaningful for S2 if S2 first shows the origins actually arrive. Relayed to W5.

**Also recorded:** exactly one user-vs-prelude same-spelling project exists
(`dict_fixtures/i7-qual4-user-class-same-spelling.mdk`, `interface Num a`), it is REJECT on all three
verbs and produces no IR — the prelude axis is essentially unexercised for IR purposes. And the 19
apparent prelude clashes in `llvm_fixtures_typed` are **false positives**: that corpus is prelude-free
(`diff_compiler_llvm_typed.sh` passes only `runtime.mdk`, which declares zero interfaces).

## RUN-P45-054 — Q1 COMPLETE (PR #1640). Must-fail suite fully green; two issues filed; both lenses dispatched.

```
diff_compiler_iface_order.sh: 5 case(s) — 5 ok, 0 failing
diff_compiler_must_fail.sh:   98 fixtures: 98 reproduce, 0 DRAINED, 0 control-broke, 0 malformed (exit 0)
```
#1620 moved from DRAINED back to reproducing on its new axis, exactly as ruled. **Both counts re-run on
a freshly rebuilt branch binary** after W2 swapped the tree to pre-Q1 and back — so they are not from a
binary that had ceased to exist, which W2 flagged as a residual risk **and then closed rather than
assumed.** That is the right instinct and it is worth naming: every earlier number in that PR was
measured on a binary that no longer existed at the moment of the swap.

⭐ **The #1620 re-pose rebuilt its derivation from scratch rather than transferring the value** — the
thing I asked for and the thing that is easy to fake. `claim.txt` derives `False`-is-wrong from its own
imports: `import beta.{Beta, ping}` binds the METHOD name while `import alpha.{Alpha}` binds only an
INTERFACE name, so `ping T` has exactly one binding; `ping T : Int` is **shown** (a String comparand
gives `Type mismatch: Int vs String`), only `impl Beta T` exists with body `7`, therefore `True` is
required and `False` delivers `impl Alpha T`'s String where the accepted type says Int. The raw probe
still prints a live heap address across three executions, so the Bool projection is still required.

**Filings, both first-hand and both defended from measurement:** **#1642** (S3, `ws:testing`) — the
`capture_goldens.sh boot_resolve` remedy naming a command that cannot work, with the working recipe and
the `diff_compiler_diagnostics.sh` precedent one file over. **#1644** (S2, `ws:diagnostics`) — the
order-dependent *diagnostic set*, **measured on BOTH binaries** (restore `resolve.mdk` to `401e3e30`,
cold rebuild, re-run, restore, rebuild) and identical, hence pre-existing on `main`, not branch-induced.
S0 ruled out because both orderings reject at exit 1. It also notes the gate header's broader Stage B
conclusion is untouched — the refutation is scoped to the *"cannot even be written"* clause.
**#1228 got a comment, not a number**, adding the pre-Q1 measurement and the `Method 'p' is not part of
interface 'Dup'` mis-diagnosis that appears once an `impl` is added.

**Both lenses dispatched on #1640** — semantics aimed at the boundaries (the S1-PRELUDE carve-out per
#1499, imported/re-exported interfaces, `@attrib`, the single-file path, and whether the re-posed
fixtures reproduce for the reason their claims state) and evidence aimed at the claim files, the ledger
note, the tripwire-loss account, and the two new issues.

**#1638 verified `isInMergeQueue: true` via GraphQL** — not from `gh pr merge`'s exit code, which
carries no signal here in either direction.

## RUN-P45-055 — 🚨 CORRECTION TO RUN-P45-050, AND IT IS MINE: HALF 1 is DIRECTORY-driven, not verdict-driven

RUN-P45-050 recorded, from W2's report and then in my own words, that census **HALF 1** *"reaches #1182
through its re-posed fixture and **#1620 not at all**"*, and I ruled the #1620 re-pose partly on that.
**The script contradicts it.** `test/must_fail_census.sh:113-121` (enumerator) and `:136-166` (HALF 1):
any `test/must_fail_fixtures/*/` whose `claim.txt` carries an `issue:` line is enrolled, and the half
fires **purely on the issue being CLOSED**. It never reads the gate's REPRO/DRAINED verdict.

⇒ While #1620's directory existed — **including while it was drained** — HALF 1 *would* have caught a
desk-close. So *"covered by nothing"* overstates, in my ruling, in the PR body, and in the shipped
ledger banner.

**The re-pose is still right, on a stronger justification that was available the whole time:** a drained
pin **reds the must-fail gate** and would have been deleted, and a drained pin **proves nothing about a
live bug**. The correct claim is about the pin's *evidentiary* value, not about census coverage.

⚠️ **Provenance of the error, because it matters more than the error:** W2 reported the HALF 1/HALF 4
split, I did not check it against the script, and I then wrote it into a RULING — which W2 dutifully
inscribed into a shipped artifact. That is
[[feedback_dont_launder_an_agents_observation_into_your_inference]] running exactly as documented, on the
same night I recorded RUN-P45-048 about laundering a message into a writer's context. **Second instance
tonight of me relaying an agent's mechanical claim without opening the file.**

**Also mine: the "29 cross-module directories" figure.** I commissioned it, handed it to W2, and it
shipped in the ledger banner with a hedge but **no derivation**. An independent parse lands nearer 55
and could not reproduce 29. ⇒ Either the command ships with the number or the number does not ship.
[[feedback_derive_dont_encode]], violated by the person who keeps citing it.

## RUN-P45-056 — EVIDENCE-LENS REVIEW OF #1640: nine findings, one BLOCKING, and the defect is STALENESS

Verdict on the engineering prose: *"unusually disciplined — the derivations are real, the census
reproduces exactly, the counts are honest, nothing is closed that shouldn't be."* The reviewer
independently re-ran the newly-rejected-files census with its own layout parser and got **exactly the
same 10 files**, and verified four counts/diffs character-for-character (98 fixture dirs, 5 iface_order
cases, resolve snapshot +145/−5, legA +5/−0 additive-only).

**F1 BLOCKS: commit 3 falsified a paragraph commit 2 wrote.** The ledger banner still says #1620 *"has
NOT been re-posed"* and *"nothing mechanical guards it today"* — written truthfully at `e964f43d`, false
since `5d3745e3` re-posed that exact fixture. **The banner is the artifact designed for whoever next
touches #1620, and it tells them the issue is unguarded.** It is the same inference the banner's own
next paragraph warns about. ⇒ Not a patch of two lines: **re-read the whole banner against the tree at
head.**

**F6 is the arc's signature failure, again:** `compiler/types/typecheck.mdk:16806-16816` still states in
the present tense that a single-file two-interface program is ACCEPTED when the declarations are swapped
— **Q1 rejects it in both orderings now** — and the ledger's removed-row prose *points the next reader
straight at that comment* (`grep -n 'interface declarations SWAPPED'`). A falsified recipe surviving in
the file the ledger cites as authority.

**F7:** two files still instruct readers that the coupling this PR removed is intact
(`diff_compiler_iface_order.sh:118-121` *"Do not remove that coupling."*; `must_fail_census.sh:~236`
*"LOAD-BEARING, not decorative … Do not decouple them."*), and the gate's drain remedy still prints
"close the issue, DELETE the row". Disclosure in the banner is honest but one-sided.

**F4, not blocking but the one claim ranked above its evidence:** #1182's `claim.txt` **asserts** its
load-bearing step (*"exactly ONE binding"*) from the spelling of the import lines, and — unlike #1620's
— it cannot be corroborated by the value, since both modules declare `m : a -> Int` so no type probe
distinguishes the denotations. **A cheap probe exists** (drop `m` from the `a1` import list, confirm the
occurrence goes unbound) and has been ordered.

Repair round dispatched to W2 with all nine, my two corrections stated as mine, and an instruction to
verify every item — including my corrections — before acting.

## RUN-P45-057 — ✅ BITE 0 LANDED. PR #1638 MERGED (`22:39:00Z`), #1630 CLOSED by its own keyword.
First merged unit of the implementation phase. Closure carries the landing sha via the plain
`Fixes #1630.` — the policy's prescribed form, not a desk close.

## RUN-P45-058 — SEMANTICS-LENS REVIEW OF #1640: could not break it, and the boundary work is the deliverable

Two cold-built arms (PR `5d3745e3` / base `8eb0d359`), env clean, `MEDAKA_STRICT=1`,
redirect-then-read-`$?`. **Verdict: no false reject, no missed member of the intended set.**

**The prelude carve-out — the worst-outcome boundary — holds on 105 NAMES, not on the one fixture.**
One program per name: all **50** method names across `core.mdk`'s 23 interfaces plus **55** prelude
standalones. `check` output **byte-identical base vs PR on all 105**; `test` byte-identical on the 50;
**zero** `R-DUPLICATE-IFACE-METHOD` anywhere. The exit-1 cases (`map`, `eq`, `compare`, …) are
pre-existing arity/type errors, identical on base. And the *reason* was verified structurally, not just
observed: `duplicateErrors` receives `preludeDecls` and demonstrably ignores it, the doctest path passes
`livePrelude` as a **separate argument** rather than flattening it into `prog` (`test_cmd.mdk:385-393`),
and the REPL's `combined` is user decls only — **so no path exists by which prelude decls enter `prog`.**
That is the difference between "I probed it" and "it cannot happen."

**Imports never participate:** 8 spellings (`{I}`, `.*`, `as A`, bare, own+imported, `export import`
chain, chain+own, entry re-exporting) plus a 2-hop dependency — all byte-identical. The check fires only
on a module's OWN decls, including when that module is two hops down, which is correct.

**Also holds:** a method declared twice *within* one interface; method-vs-function/local/field names;
defaults, `requires`, `deriving`, multi-impl; `@attrib` on either or both interfaces **and** the sibling
duplicate-NAME check's own gap unchanged; three-way collisions naming the first declarer; every verb
including `--json`, REPL, LSP `publishDiagnostics`, and the single-file path. `make check-self` and
`snapshot-check` green; 29 stdlib modules checked, the two failures identical on base. **No `List`-as-set
quadratic** — the walk is `OrdMap`-keyed, single pass.

⭐ **A static census bounds what any further probing could find:** exactly **5** files in 3171 have two
interfaces sharing a method name in one module — the 2 new resolve fixtures, the 2 kept iface_order
fixtures, and one non-gated `.claude/` scratch repro. Nothing imports any of them, and Q1 reads only a
module's own decls, **so no other file in the tree CAN change acceptance.** A full 3171-file differential
was still running and its partial result agreed.

**The reviewer RETRACTED its own F2** after finding the loc-less rendering identical on base — the
behaviour it flagged is the pre-existing shape for every location-less resolve error. Retraction counted
as a success, as it is here.

### RULING on its F1 (S3): leave the message as-is, knowingly, and say so.
`@inline interface E1` + `interface E1` (duplicate NAME, same method) makes the new diagnostic read
*"declared by two interfaces in this module: 'E1' and 'E1'"* with the advice *"merge the two
interfaces"*. The message is odd, but **the shape only exists because #1228 drops the attributed decl
before the duplicate-NAME check can fire** — special-casing a message for a program that should never
have been accepted adds a branch that must be maintained past the real fix. ⇒ **Record it in the PR body
and on #1228 as a consequence of that drop, do not special-case it.** Base silently ACCEPTS this program
at exit 0; the PR at least rejects it, so this is loud→louder, not a regression.

**Its F3 is the evidence lens's F1** — already repaired in this round, independently found by both
lenses, which is the two-lens split converging rather than duplicating.

**Observation carried forward, not a defect:** Q1 makes the ambiguity unrepresentable **intra-module
only**; the cross-module axis stays fully representable, and the two re-posed pins are the proof. **A
later interface-identity keying unit still inherits an order-dependent supply cross-module.** The PR
states this in three places and does not oversell it.

## RUN-P45-059 — Q1 CLOSED OUT. And W2 labelled a DERIVED cell as derived, unprompted.

Both post-review items landed (PR body note + the self-draining #1228 comment). W2 **reproduced the odd
wording first-hand before recording it** rather than transcribing it from the review — the right reflex
for a claim that ships.

⭐ **The precision it volunteered is the entry worth keeping.** The *"base silently accepts, so this is
loud→louder"* cell is **DERIVED, not measured on a base binary**, and it labelled it that way in both
artifacts rather than stating it flat. Its derivation, which I accept:
1. on the PR binary the program yields **exactly one** diagnostic and it is Q1's — no `R-DUPLICATE-DEF`;
2. resolve errors **accumulate rather than short-circuit**, so a firing duplicate-NAME check would appear
   alongside — it demonstrably does not fire on this shape;
3. Q1 is the only check this PR adds ⇒ base's diagnostic set is this one minus Q1's = **empty**.
Corroborated by the pre-Q1 measurement already on #1228 (same construction, different method names,
exit 0 clean on a base binary). It offered the direct base run at a cost of two rebuilds and did not
take it unasked. **Ruled: the derivation stands** — it is closed under the accumulate property, not a
plausibility argument, and the marginal value of two rebuilds does not justify the box time with two
writers live.

**Gates: none owed, and it said so instead of burning a cycle.** Neither change touches a `.mdk`,
fixture, golden or script; `HEAD` unchanged at `83b8fc8d`. Re-running would re-measure an unchanged tree
with an unchanged binary. **Declining to re-run, with the reason, is the correct answer** and the
opposite of the reflex that pads a report.

Its own retrospective on the F6 refusal is worth preserving verbatim in spirit: *"what made it refusable
was having measured the premise cross-module first. Without that probe I'd have had only an opinion
against a finding, and would probably have complied."* ⇒ **Briefing for refusal is necessary but not
sufficient; the agent also needs the MEASUREMENT that makes refusal defensible.** Budget probe time for
that, not just permission.

Q1 session output: PR #1640 (4 commits) · issues **#1642** (S3 `ws:testing`), **#1644** (S2
`ws:diagnostics`) · two comments on **#1228**. Nothing closed, no closing keyword. Enqueued.

## RUN-P45-060 — PHASE 4 (`B-2.3`) DISPATCHED as W6, concurrent with S2

Briefed on route α with the three corrections Phase 0 measured (`CProgram` carrier DEAD ⇒ `Ref CAdmis`;
key is `(bare iface, bare method)` with **no head component**; the charter's stated justification is
false and the real one is the **two fail-OPEN defaults**), the two-tier key requirement, the
lookup-vs-filter comparator split, the lockstep obligation on `eval.mdk` + `core_ir_lower.mdk`, and the
`keepOrAll` all-or-nothing ruling.

🚨 **The framing that matters most, stated in the brief:** if Phase 4 freezes admissibility **computed by
the current selector, it FREEZES THE ORDER-DEPENDENCE into data** and makes it harder to remove later.
That is the worst outcome available in this bite, and it is why refusal was licensed explicitly as the
likeliest correct answer of the sprint.

## RUN-P45-061 — PHASE 4 LANDS AS PR #1646, and THREE of its judgement calls beat the brief

`((iface, method), positions)` → `((ifaceId, iface, method), positions)`, both consumers
(`eval.implMethodEntry`, `core_ir_lower.lowerImplMethod`) re-keyed in lockstep. C3a PASS · C3b PASS ·
check-self PASS · selfproc 16/0 · snapshots 202/202 · eval_modules, core_ir_modules, eval_typed_modules,
dict_semantics 4/4 · import_order 15/15. #1113 NOT closed.

**1. The carrier — I briefed `Ref CAdmis`; W6 widened THE ROW instead, and that is strictly better.**
The element type sits in `installDispatchTables`, `lowerImplsWith`, `cBuildModInfos`, `declImplEntries`,
`modImplEntries`, `lookupPositions` — so updating one consumer and not the other **does not compile.**
The `evalModules`/`cevalModules` lockstep stops being a convention plus a comment and becomes a type
error. That is the correct answer to a trap `AGENTS.md` records as having survived for months.

**2. `keepOrAll` NOT retired, and the unit therefore does NOT claim to close the fail-open behaviour** —
the honest half of the all-or-nothing ruling, with `ARGSTAMP-UNIFY-PLAN.md`'s measured **22/3 → 15/10**
parity regression as the reason. The `[0]` miss default likewise retained and named at the site.

**3. The legA golden is NOT additive-only and was reported as such** — 13 rows, 2 new plus **11
pre-existing bindings whose inferred type changed** — and discharged by **set equality against the
signatures re-signed by hand**, not by eyeballing. The bar was never "additive"; it is "no UNTOUCHED
binding moved", and that is what was checked.

**Identity-keying was free, verified from the CONSEQUENCE not the source:** the pre-fix dump already
printed `a::Speak|DogA|` / `b::Speak|DogB|` route keys **on the very line that then looked up by
spelling.**

### ⭐ The finding W6 nearly shipped as its own, and killed with a base arm
It wrote a `dict_fixtures` row asserting `build|ACCEPT` and **deleted it**: on BOTH arms the shape fails
`build` with `no impl of method 'display' for type 'DogB'`, byte-identical, so it is **not this change's
defect**. The control settles it — identical signatures for the two `speak`s and the same two-module
collision builds clean — so the failure tracks the **SIGNATURE**, i.e. a separate bare-name
**method-scheme** collision (#1070 family).

🚨 **The consequence is the sprint's most important architectural fact so far:** an admissibility
mis-key **requires** different method signatures, which **forces** that collision ⇒ **the two defects are
COEXTENSIVE on today's compiler**, and the typed Core IR dump is the only observation separating them.
⇒ **Phase 4 is architectural hardening, not a user-visible fix**, and the PR says so. Anyone reading it
as a drain of the #1070-family shape is wrong.

**Second finding:** `diff_compiler_import_order.sh` **could not have caught this** — its signature
excludes `build`'s stderr, so both pre-fix orderings collapse to `build=1/-:` and it would have graded
the pre-fix binary INVARIANT while the emitter failed under a different type per order. Written into the
fixture's `case.txt`.

**Nearest miss, named and deliberately not folded in:** `llvm_emit.lookupSelfFnParams` /
`core_ir_lower.selfFnParamTable` — same `(bare iface, bare method)` key, same `DInterface` source,
`ifaceOrigin` equally in hand. **Fails CLOSED (`[]`), so it narrows rather than widens** — which is why
it is next rather than now. No issue filed for it, correctly.

### 🚨 ORCH's review question, which the semantics lens is aimed at
**Does tier 2 fire when tier 1 missed for the RIGHT reason?** Tier 1 (`ifaceIdMatches`, absence never
matches) misses in two structurally different situations: **(a) absence** — flat path, where falling back
to spelling is CORRECT and preserves today's behaviour; and **(b) genuine conflict** — both sides carry
identities and they DIFFER, where falling back to spelling **re-collides exactly the two interfaces the
key exists to separate.** If tier 2 is a blanket *"tier 1 returned nothing ⇒ try spelling"*, case (b)
falls through, the re-key delivers nothing for its target shape, and **every gate stays green** — because
the defect is not value-observable (above). This is the one question that decides whether the unit works.

## RUN-P45-062 — THE #1640 SEMANTICS REVIEWER RETRACTED 14 OF ITS OWN HITS, AND FOUND A NEW TRAP DOING IT

Its tree-wide sweep first reported **14 `base=1 → pr=0` stdlib divergences** — i.e. *"the branch fixed 14
stdlib files"*, a finding shaped exactly like a real one. **All 14 retracted.**

🚨 **The mechanism is a NEW instance of the exe-relative property, running in the opposite direction
from the one `AGENTS.md` documents.** The internal-extern guard trusts a stdlib file only when it sits
under the *binary's own* `MEDAKA_ROOT` (= `exeDir`). A base binary in a scratch worktree, pointed at the
branch worktree's `stdlib/array.mdk`, sees it as **outside its stdlib** and emits `R-INTERNAL-EXTERN`;
the branch binary on its own tree accepts. **Swapping the file's tree reverses the direction** — the
variable was the file's LOCATION relative to the binary, not the compiler. Re-run with each binary
against its own tree's stdlib, prefix normalized: **all 29 modules byte-identical, 0 divergences.**

⇒ `AGENTS.md` says exe-relative resolution is what makes a two-worktree differential **sound**. That is
true for ordinary programs and **false for `stdlib/*` targets**, which is the exception nobody had
written down. **Landed in `AGENTS.md`** beside the existing exe-relative block.

### ⭐⭐ Two epistemic corrections the reviewer made against ITSELF, both worth more than the sweep
1. **It overstated its own bound and said so.** It had written that no other file in the tree *can*
   change acceptance; the sweep then reported 18 divergences where it predicted 1. All 18 resolve, but
   *"I asserted the bound before the evidence that would have tested it had arrived."*
   [[feedback_a_claim_reaching_past_its_evidence]], self-caught.
2. **Its sweep compared EXIT CODES ONLY, so it is blind to a change of REASON at the same exit code.**
   `iface_order_fixtures/1182-…/main.mdk` does not appear among the 18 for precisely that reason: base
   rejects with `T-NO-IMPL`, PR rejects with `R-DUPLICATE-IFACE-METHOD` — **same exit 1, different
   diagnostic.** ⇒ *"The static census, not the sweep, is what actually bounds this change."*
   [[feedback_an_exit_code_graded_control_answers_the_wrong_question]], found by the instrument's own
   author.

**Corrected result: exactly 5 files tree-wide change acceptance** — the 2 new resolve fixtures, the kept
`1620` iface_order fixture, one non-gated `.claude/` scratch repro, and the text-only `1182` fixture.
**Exactly the static census set.** Everything else in its report stands: the 105-name prelude carve-out,
8 import spellings plus re-export chains, attribute-awareness both positions, verb reach, both re-posed
pins with their load-bearing steps confirmed and controls proven fail-capable.

**Bottom line: no false reject, no missed member of the intended set.** The one widening it thought it
had found was its own probe asking the wrong question.
