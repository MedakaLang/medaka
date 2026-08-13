# AD-2 — the Phase 4 (`B-2.3`) admissibility carrier: **RULED TWO-VALUED**, spelling `CAdmisAbsent | CAdmisTable …`, **not** `Option`

**Status:** RULING (adjudication, not design). Ruled in Phase 0 of the Stage B / Phase 3′ sprint by
the architecture companion, read-only. **Pin `68f84bf1`**; every citation `@68f84bf1`. Nothing here
is MEASURED — no build, no gate, no `./medaka` invocation. **Rule it; do not build it.**
**Owner of everything it does NOT decide: Phase 4 / `B-2.3`.**

---

## Verdict table

| question | ruling | basis |
|---|---|---|
| Is the escalation's premise sound? | **PARTIALLY — sound in conclusion, WRONG in its stated reason, and its count is wrong.** `lowerProgram` is the *shared* path, not the *untyped* path: **2 of its 7 probe-driver callers are typed** (`elaborateOne` / `elaborateDict`). It is also reached by a **user-facing verb** (`medaka snapshot`), not only by probe drivers. | §1 |
| "nine probe drivers" | **REFUTED. 7 probe drivers**, plus `lowerProgramEmit` itself, plus `compiler/tools/snapshot.mdk`. The "9" counts *application sites*, and two of the nine are not drivers. | §1.1 |
| Does RUN-B-013 condition 1 collapse under a bare-table positional field? | **YES — on a stronger reason than the escalation gives.** Not "untyped drivers have no table", but: **the field's value is not determined by which lowering function you call**, so no call site can be trusted to mean "absent". | §2 |
| Positional 5th field vs two-valued type | **BOTH — they are orthogonal axes.** RUN-B-013's C-2 (a 5th positional `CProgram` field) **stands, unamended**. This ruling is only about that field's **type**. | §3 |
| `Option <table>` vs `CAdmis = CAdmisAbsent \| CAdmisTable …` | **`CAdmisAbsent \| CAdmisTable`.** Condition 1 forbids "a single `Option`-with-default" *by name*; `fromOption` is auto-prelude and already used **99×** in `compiler/`, so the forbidden collapse is one idiomatic token away. A bespoke type has **no prelude eliminator** and a **greppable unique token**. | §4 |
| Does the wildcard-arm trap apply? | **NO, to either spelling** — both introduce a *new type*, not a new constructor of an existing one. The trap that *does* apply is the program-global unscoped-key one. | §4.3 |

---

## 1. The premise, verified first-hand — and corrected

### 1.1 The `lowerProgram` site set (DERIVED)

```sh
grep -rn 'lowerProgram\b' --include=*.mdk compiler/ | grep -v 'lowerProgramEmit'
```

Stripping the definition (`core_ir_lower.mdk:522-523`), imports and comments, the **9 application
sites partition into three kinds, not one**:

| # | site @`68f84bf1` | kind | elaborated? |
|---|---|---|---|
| 1 | `compiler/entries/core_ir_dump_main.mdk:26` | probe driver | **no** — `annotateProgram (desugar (parse src))` |
| 2 | `compiler/entries/core_ir_main.mdk:33` | probe driver | **no** |
| 3 | `compiler/entries/core_ir_run_main.mdk:29` | probe driver | **no** |
| 4 | `compiler/entries/core_ir_prelude_main.mdk:25` | probe driver | **no** |
| 5 | `compiler/entries/core_ir_roundtrip_main.mdk:28` | probe driver | **no** |
| 6 | `compiler/entries/core_ir_typed_main.mdk:34` | probe driver | **YES — `elaborateOne`** |
| 7 | `compiler/entries/core_ir_dict_pp_main.mdk:35` | probe driver | **YES — `elaborateDict`** |
| 8 | `compiler/ir/core_ir_lower.mdk:555` | **library** — inside `lowerProgramEmit` | n/a (its caller decides) |
| 9 | `compiler/tools/snapshot.mdk:568` (`coreIrOf`) | **user-facing verb** — `medaka snapshot` | **no** |

**7 probe drivers, not 9.** Site 9 is CLI-reachable: `medaka_cli.mdk:295` dispatches
`"snapshot"::rest => dispatchSub snapshotHelpText runSnapshotCmd rest`, and `snapshot.mdk:568` is
`coreIrOf d = cprogramToSexp (lowerProgram (annotateProgram d))`.

### 1.2 What this does and does not do to the escalation

- **Does NOT refute it.** The conclusion (two-valued) survives, on a stronger argument (§2.1).
- **Does correct its premise.** `lowerProgram` is **shared**, not "untyped"; the typed/untyped
  distinction does **not** coincide with the `lowerProgram`/`lowerProgramEmit` split. D2 §3's own
  source quote says only *shared*; "untyped" is D2's addition and the tree contradicts it at 2 of 7.
- **Adds a fact neither RUN-B-013 nor D2 has.** RUN-B-013's assent to the untyped-eval carve-out
  rested on *"no user-facing verb reaches the untyped path"* (`.claude/sprint-b/DECISIONS.md:697-709`).
  **That is true of `cevalModules`/`cevalProgram` and FALSE of `lowerProgram`.** It does not
  invalidate the assent (`medaka snapshot` renders, it does not dispatch) but it **must not be
  restated about the carrier**, and Phase 4's `DEBT.md` row must not claim it.

### 1.3 The typed path

`lowerProgramEmit prog = hoistNullaryMemo (rewriteProgramRecPats (declaredRecordFieldOrders prog)
(lowerProgram prog))` (`core_ir_lower.mdk:551-555`) — a **wrapper**, not a peer. A table parameter
added to `lowerProgram` must also be added to `lowerProgramEmit` and forwarded: one hop, no branch.

---

## 2. RUN-B-013 fail-closed condition 1, verbatim, and where it collapses

From `.claude/sprint-b/DECISIONS.md:713-723` @`68f84bf1`:

> 1. 🚨 **The two absence states must stay DISTINCT in the code.** They are different things and
>    collapsing them is how the fail-open default returns:
>    - *table present, **no row** for a (class, position)* → **FAILS CLOSED** (not admissible).
>    - *table **structurally absent*** (the two untyped drivers) → today's arg-tag behaviour,
>      marked UNVERIFIED.
>
>    A single `Option`-with-default that serves both is **forbidden.** The precedent is concrete:
>    today's analogue **fails open** — `lookupPositions _ _ [] = [0]` (`eval.mdk:1934`) declares
>    position 0 dispatchable on a miss, and `keepOrAll` (`:967-969`) then returns the **original**
>    candidate set when every tagged candidate is filtered out. A table inheriting that default
>    **has changed nothing.**

Both precedent citations verified first-hand @`68f84bf1`: `eval.mdk:1934` is
`lookupPositions _ _ [] = [0]`; `eval.mdk:967-969` is `keepOrAll` with `keepOrAll original [] =
original`.

### 2.1 Why a bare-table 5th field collapses it

`CProgram`'s payload is four plain lists (`compiler/ir/core_ir.mdk:241-242`):

```
public export data CProgram =
  | CProgram (List CBind) (List (String, Int)) (List (String, String)) (List CImplEntry)
```

A 5th field of type `List <row>` inherits that shape: **its only "I have nothing" value is `[]`**,
which is also the legitimate value of a fully-computed table with no rows. `absent ≡ no-rows`
becomes a **type-level identity** — not a discipline failure, not something a reviewer can catch.
Both readings are then wrong:

- `[]` as **absent** ⇒ the typed path cannot express *"table computed, genuinely zero rows"*, so
  **fail-closed is unrepresentable on the arm that needs it**;
- `[]` as **no-rows** ⇒ fail-closed fires on 7 of 9 sites plus `medaka snapshot`.

🚨 **Use this argument, not D2's.** D2 argues from *"the untyped drivers have no table"*, which
invites the rebuttal *"then thread the table on the typed drivers too."* That does not fix it. The
load-bearing fact is: **the `lowerProgram` / `lowerProgramEmit` split does not partition callers by
whether a table exists.** Both are reached by callers with and without one, so *no call site can be
inferred to mean "absent"* — the absence must be carried **in the value**. That survives Phase 4
upgrading any driver to typed.

---

## 3. The ruling on the carrier

**RUN-B-013's C-2 stands and does not need overturning.** C-2 chose *where* the table rides; the
escalation is about *what type* the field has. **Ruled: a 5th positional `CProgram` field whose type
is two-valued.**

### 3.1 Cost, in sites — DERIVED

```sh
grep -rn 'CProgram' --include=*.mdk compiler/ stdlib/
```

**11 destructure sites** — each becomes a compile error the moment a 5th field is added
(constructor patterns are arity-checked):

`core_ir_lower.mdk:638` (`rewriteProgramRecPats`) · `core_ir_lower.mdk:997` (`hoistNullaryMemo`) ·
`core_ir_eval.mdk:401` (`cevalProgram`) · `core_ir_sexp.mdk:225` (`cprogramToSexp`) ·
`draft_semantic_program.mdk:313` (`cprogramSummary`) · `llvm_emit.mdk:10761` (`emitProgramMode`) ·
`llvm_emit.mdk:11131` (`emitProgramGaps`) · `wasm_emit.mdk:1073` (`emitProgramWith`) ·
`wasm_emit.mdk:1143` (`emitProgramGaps`) · `entries/llvm_emit_modules_main.mdk:86` (`preludeSymsOf`)
· `entries/wasm_emit_typed_main.mdk:219` (`implSelfCensusProgram`)

**13 construction sites:** `core_ir_lower.mdk:525` (`lowerProgram` — the only *lowering*
construction) · `:639` · `:999` · `:1007` · `core_ir_sexp_parse.mdk:381` (`parseCProgram`) ·
`llvm_emit_typed_main.mdk:77` · `wasm_emit_typed_main.mdk:210, 220, 315, 334, 377, 483, 494`

🚨 **This refutes a second D2 §3 claim:** *"`CProgram` is constructed at exactly ONE site"*. It is
constructed at **13** — ten of the others are hand-built literals in two probe drivers plus the two
rewrite passes, and the thirteenth is a **deserializer**.

**Either spelling costs the same 24 sites, so the site count is NOT a decision axis. Rule on silent
wrongness alone.**

---

## 4. The spelling: `CAdmisAbsent | CAdmisTable …`

### 4.1 Condition 1 already forbids the `Option` idiom by name

```sh
grep -n 'fromOption' stdlib/core.mdk                     # 1389: export fromOption : a -> Option a -> a
grep -rn 'fromOption' --include=*.mdk compiler/ | wc -l  # 99
grep -rn 'fromOption' --include=*.mdk compiler/ir/ compiler/backend/ | wc -l  # 9
```

`fromOption` is auto-prelude and already used **99× across `compiler/`, 9 of them inside `ir/` and
`backend/` themselves**. With the `Option` spelling the exact move condition 1 forbids is
`fromOption [] admis` — one idiomatic call, matching 99 existing uses, in a diff a reviewer has no
reason to stop on. **The `Option` spelling ships its own defeater in the prelude.**

### 4.2 The bespoke type has no eliminator and one unique token

`CAdmis = CAdmisAbsent | CAdmisTable <rows>` has **no** prelude eliminator. Collapsing it requires
hand-writing `CAdmisAbsent => []`, which is (a) deliberate, (b) visible in a diff as a *decision*,
and (c) **greppable on a token that exists nowhere else in the tree**, so the Phase 4 tripwire is
one line:

```sh
grep -rn 'CAdmisAbsent' --include=*.mdk compiler/    # every arm, enumerable as a SET
```

`Option` admits no such tripwire. This is the decisive asymmetry and the **only** one: the two
spellings are identical in site count, identical in what they make unrepresentable, and identical
under the wildcard trap. They differ **solely in how cheap and how quiet it is to re-collapse
them** — and condition 1 is an anti-collapse condition.

### 4.3 The wildcard-arm trap — checked, and it is NOT the hazard here

Neither spelling adds a constructor to an *existing* type, and there are zero pre-existing
scrutinees of a field that does not yet exist. **The trap that DOES fire is the other one in the
same `AGENTS.md` paragraph:** `CAdmisTable`'s rows are keyed by *(class, position)*, and a bare
class name is a **program-global bare-name key** — the recorded failure mode (a kind table keyed on
a bare type-param name re-kinding every arity-matching application in the whole module graph, silent
accept, exit 0). **Phase 4 owns PROVING the key is scoped, not asserting it.**

### 4.4 A concrete implementation hazard, handed to Phase 4

`CProgram`'s declaration is in the **two-line `data X =` / `| X …` header form**
(`core_ir_lower`'s `core_ir.mdk:241-242`) — the **unsafe** shape for the reopened #829 `fmt --write`
comment-migration defect, on which `fmt --check` then exits **0** over the corrupted output so the
pre-commit hook passes it. The 5th field will want an explanatory comment. **Add the field bare and
put the prose on `lowerProgram` or on the `CAdmis` declaration instead**, or diff the decl by eye
after `fmt --write`. Do not trust `fmt --check`.

---

## 5. What this ruling does NOT decide — Phase 4 / `B-2.3` owns all of it

1. **The row type and its KEY** — whether *(class, position)* is scoped. The live instance of the
   program-global bare-name-table trap (§4.3). Phase 4 must **prove** it.
2. **Serialization.** `cprogramToSexp` (`core_ir_sexp.mdk:224-233`) emits exactly 4 sub-lists;
   `parseCProgram` (`core_ir_sexp_parse.mdk:381`) matches exactly a 4-element `SList` and panics
   otherwise. A 5th field forces a choice neither RUN-B-013 nor D2 made: **render it** (every
   `core_ir_sexp` golden moves, and `parseCProgram` must round-trip it — note
   `core_ir_roundtrip_main.mdk:28-30` lowers → serializes → **re-parses** → evaluates, so a
   non-round-tripped field **silently becomes ABSENT after a round trip**) or **omit it** (goldens
   hold still, but `core_ir_typed_modules_dump_main.mdk:43` — `AGENTS.md`'s designated probe for
   *"which impl did it actually pick"* — cannot show admissibility). Both defensible; this ruling
   picks neither.
3. **What `CAdmisAbsent` means at each of the 11 destructures.** Ruled only that it must be a
   distinct constructor. Condition 1 fixes the dispatch arms; it says nothing about
   `cprogramToSexp`, `cprogramSummary`, `preludeSymsOf`, `rewriteProgramRecPats`, `hoistNullaryMemo`
   or the two `emitProgramGaps`. **Enumerate the 11 as a SET** (§3.1 lists them).
4. **The `DEBT.md` row's driver list.** §1.1 supersedes the counts in both RUN-B-013 ("two untyped
   drivers") and D2 ("nine"). Re-derive from §1.1's command, and do **not** repeat *"no user-facing
   verb reaches the untyped path"* about the carrier (§1.2).
5. **Sizing, ordering, bite-cutting.** Out of charter, deliberately — the orchestrator's.

---

## 6. Corrections this ruling makes to the record

| claim | source | status |
|---|---|---|
| *"`lowerProgram` is the UNTYPED shared path"* | `D2-phase5-engines.md` §3 | **WRONG as worded** — 2 of 7 probe-driver callers are typed. Conclusion survives on a different argument (§2.1). |
| *"Its 9 application sites are the untyped probe drivers"* | `D2-phase5-engines.md` §3 | **WRONG** — 7 drivers; the others are `lowerProgramEmit` and `compiler/tools/snapshot.mdk` (a user-facing verb). |
| *"`CProgram` is constructed at exactly ONE site"* | `D2-phase5-engines.md` §3 | **WRONG** — 13 construction sites (§3.1). |
| *"no user-facing verb reaches the untyped path"* | `.claude/sprint-b/DECISIONS.md:697-698` | **True of `cevalModules`/`cevalProgram`; FALSE of `lowerProgram`** — does not transfer to the carrier (§1.2). |
| *"the carrier field must be `Option`-shaped (or a two-constructor type)"* | `.claude/sprint-b/DECISIONS.md:1747` (RUN-B-026) | **Two-valued: upheld. `Option`: REJECTED** (§4.1). |
