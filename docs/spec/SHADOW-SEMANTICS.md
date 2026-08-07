# Declaration-Shadowing Semantics (standalone fn ⇄ interface method)

**Status:** ENFORCED — the decision matrix is a GATE
(`test/diff_compiler_shadow_semantics.sh`): it runs every fixture in
`test/shadow_fixtures/` through `check` + `run` + `build`, asserting each cell's
verdict AND (per **S7**) that `run` and the built binary print the same pinned
value. **Every cell with a fixture is conformant** (2026-07-17). S-3 (row 26,
multi-typaram interface) was the last **BUG** and closed with #54; row 29 (S5's
carve-out at multi-typaram width) was its residual **GAP** and closed with
[#604](https://github.com/MedakaLang/medaka/issues/604) — **in the parser, with no
change to the shadow machinery**; row 30 (multi-typaram *importer* shadows) was
**UNVERIFIED** and, once #604 made a probe possible, turned out **conformant**,
disproving the divergence #54 predicted for it. Both ledger rows went RED the day
their bug was fixed, which is what a ledger row is for. ⚠️ **`0 BUG` in the tally
below means only "no two engines disagree" — an observability property, not a health
claim; see the note under the matrix, and S7's own warning.** Until
this gate existed the corpus below **ran nowhere**, and the matrix's own Status
column had silently gone stale in the OK direction (see the note under §2).
> ## 🔒 2026-08-06 — **S1's SCOPE IS RULED, AND THE WORD "visible" IS RETIRED FROM S1–S9.**
>
> A commissioned spec pass found the adjective **"visible"** used four times
> across S1–S2, **defined nowhere**, carrying **three different scopes** — so the
> clause set was internally inconsistent under *both* candidate readings and the
> repair could not be a branch selection. Both halves are now landed:
>
> - **The vocabulary repair.** §1.0 defines **nameable in `M`** /
>   **defined-in-`M`-or-imported-into-`M`** / **graph-global** once, and each of
>   the four occurrences now names its own scope. **Do not reintroduce a bare
>   "visible" ANYWHERE IN THIS DOCUMENT** — widened 2026-08-07 from "S1–S9" after
>   a fifth bare occurrence surfaced in §5's historical narrative, outside the
>   literal S1–S9 clause text but the same failure mode; a word-scoped
>   instruction does not stop a class of ambiguous scope adjectives ("in scope",
>   "available to", "reachable from", "sees", …) either — see §0's fix to the
>   `Shadow` bullet. This half stands independently of the branch: the defect
>   was the undefined adjective, of whatever spelling, wherever it appears.
> - **The branch.** **S1's interface operand is scoped to what the module can
>   NAME; S2's impl universe stays graph-global.** The argument, the cost, and
>   the **⟲ overturn condition** are in the **S1-SCOPE** note under S1.
>
> ⚠️ **S2's old `GLOBAL` gloss ("local ∪ imported ∪ prelude") was independently
> wrong** — narrower than `DICT-SEMANTICS.md` §8 I5's actual instance universe —
> *and* it was the same enumeration S1 used restrictively, thirty lines apart.
> Corrected; see the warning on S2's importer arm.
>
> **Home of the ruling:**
> [#1375](https://github.com/MedakaLang/medaka/issues/1375) (successor to
> #1107), which owns [#1353](https://github.com/MedakaLang/medaka/issues/1353)
> and [#1302](https://github.com/MedakaLang/medaka/issues/1302) as **one**
> ruling — they are two axes of the same operand, reachability and export
> visibility. The derivation, the measurements, and the strongest argument
> *against* the ruling are on #1353.
>
> 🚨 **The implementation does NOT yet conform, and §2's matrix cannot tell you
> so** — no fixture exercises the axis (see the corpus-blindness note under the
> matrix). Per this document's own scope rule, *the spec is the target, not a
> description of present behavior.* **The spec change lands no compiler
> behaviour change.**

**Scope:** a bare name `N` that is BOTH a top-level standalone function AND an
interface-method name (a "shadow"). Peer of `DICT-SEMANTICS.md` /
`LAYOUT-SEMANTICS.md`: clauses S1–S9, a gated decision matrix, and a per-stage
enforcement table. Where the binary disagrees with a clause, the matrix row says
**BUG** — the spec is the target, not a description of present behavior.

> ## ⚡ 2026-07-14 — **S2 IS INVERTED: A TOP-LEVEL STANDALONE WINS.**
>
> A standalone function defined in a module now **beats** a same-named interface
> method **inside that module**, unconditionally. **The impl universe is no longer
> consulted for a definer shadow.** This replaces the old S2 ("a live impl at the
> receiver's head dispatches; the standalone is only a no-impl fallback").
>
> **The bug that forced it** — and it is not a corner case:
>
> ```medaka
> eq : List Int -> List Int -> Bool
> eq a b = True
> main = println (debug (eq [1] [2]))    -- printed False. THE USER'S FUNCTION WAS IGNORED.
> ```
>
> `check` passed. `run` and `build` **agreed** — both wrong the same way — and
> `check --types` did not even report the user's signature. The function was not
> shadowed, it was **erased**, because `List` has a prelude `impl Eq List`. By **S1**
> shadow-hood is `standalones ∩ iface-method-names` *and the interface may be the
> prelude*, so **~45 of the most natural names in the language were landmines**:
> `map`, `filter`, `length`, `compare`, `eq`, `min`, `max`, `abs`, `empty`, `index`,
> `append`, `fold`, `toList`, `display`, `debug`, `pure`, `traverse`, …
>
> ⚠️ **And the compiler was obeying this spec.** The old S2 said dispatch; the
> compiler dispatched. **The SPEC was the bug** — which is why the fix is a spec
> change, and why **no differential gate could ever have caught it**: by **S7** the
> three engines agree on every shadow cell *by construction*, and they did.
>
> **The new tie-break.** *A name written at top level in a module is that module's
> name.* The prelude declares 49 method names over every common type; a user cannot
> be expected to know them and `check` could not tell them. Silently discarding a
> declared, signatured top-level function because a **prelude** impl exists for the
> argument's type is not a tie-break — it is erasure. The stdlib's own fallback
> pattern (`map.mdk`'s `toList` beating the `Foldable` method of the same name) is not a special case of
> the old rule; it is the **general case** of the new one.
>
> **Two deliberate limits** (both decided by the language owner, both load-bearing):
> - **Definer-only.** An **imported** standalone does **not** shadow — an `import` is
>   a *sibling* scope, not an *inner* one. Total inversion would break the everyday
>   `import map` pattern (row 20: `isEmpty [1,2]` must still reach `Foldable.isEmpty`).
> - **The `=>` carve-out stays.** A call on a **dict-bound** (`Sz a =>`) receiver still
>   **dispatches**: writing the constraint is an explicit request for dispatch, and it
>   is the only way to reach the method by name inside a shadowing module (§1.1).
>
> **What moved:** five cells went ACCEPT → **located REJECT** (rows 5, 6, 7, 8, 14 —
> `d2`, `d3`, `d6`, `d7`, `d8`), each now `Type mismatch: Int vs <receiver>` at the
> call site on all three paths. **Nothing that rejected became an accept**, except
> `p0_20_shadow_literal_result_pinned`, whose reject existed *only* as a side effect
> of the method stealing the call. Row 14 (`d8`) **deliberately reverts** `ebb8ee90`
> (P0-19 batch 2), which had made a definer shadow dispatch cross-module — that fix
> faithfully implemented the OLD S2, and the inversion abolishes the rule it
> implemented. Design: `compiler/SHADOW-INVERSION-DESIGN.md`.

**Why this exists.** This one rule produced four bugs in four different stages
(P0-18 arc: typecheck routing `953d9ea1`, mangle/mark ordering `0b4a7882`,
scheme selection → SIGSEGV, cross-module registration `cfc4fa5a`) because each
stage made its own keying assumption about the same rule (§3 makes those keys
explicit). Fixtures: `test/shadow_fixtures/` (one per matrix cell), run by
`test/diff_compiler_shadow_semantics.sh` — see §4. History/context: memory
`project_phase112_standalone_vs_method`, `qa-beta-2026-07-07/P0-18-*.md`.

## 0. Terminology

- **Shadow**: bare name `N` naming BOTH (a) a standalone top-level fn **defined
  in `M` or imported into `M`**, AND (b) an interface method **nameable in
  `M`**. ⚠️ **These are deliberately NOT the same scope** — see §1.0's **Scope
  vocabulary** and S1, which states both operands explicitly; a single phrase
  covering "both" (as an earlier revision of this bullet had it) reads as one
  shared scope and is exactly the reading the ruling rejects. Shadow-hood is
  per-**module**, so "at the call site" would be the wrong granularity.
- **Definer shadow**: the standalone is defined in the *call site's own module*
  (in-tree: `stdlib/map.mdk` + `stdlib/hash_map.mdk` `toList`/`isEmpty`,
  `compiler/frontend/parser.mdk` `orElse` — all applied only to no-impl
  receivers, all route standalone).
- **Importer shadow**: the standalone is *imported* from another module (the
  everyday `import map` → `isEmpty m` pattern; the shadowed interface may live
  in the prelude, in the consuming module, or in a third module).
- **Live impl** / **no-impl** (of a receiver): the receiver's head tycon does,
  or does not, have an `impl` of the shadowed interface — tested against S2's
  **graph-global** impl universe (§1.0), never filtered by what `M` can name.
  Used throughout §2's matrix ("live-impl recv" / "no-impl recv") and §3.
- **Routes** (`compiler/frontend/ast.mdk:69-72`): `RKey tag dicts` = dispatch to
  the impl whose head tycon is `tag`; `RLocal sym dicts` = NOT a dispatch, call
  the standalone (`sym` = the mangled standalone symbol on the build path, `""`
  on the un-mangled run/check path). **`dicts` is the standalone's OWN
  `=>`-constraint dicts** — see clause **S9**. It is `[]` for an unconstrained
  standalone, which is every one of the compiler's own definer shadows.
  ⚠️ Until 2026-07-13 this document, `ast.mdk` and `eval.mdk` all asserted
  *"RLocal carries no dict"* as a settled **invariant**. That invariant WAS the
  S-1 silent miscompile: it is now false by design. Do not restore it.

## 1. The resolution function (clauses S1–S9)

### 1.0 Scope vocabulary — READ THIS BEFORE S1

⚠️ **The word "visible" used to appear four times in S1–S2, undefined, carrying
three different scopes.** That ambiguity is what produced
[#1353](https://github.com/MedakaLang/medaka/issues/1353), and it is why this
section now names the scope at every occurrence instead of reusing one
adjective. **[CORRECTED 2026-08-07 — this sentence used to also name
[#1302](https://github.com/MedakaLang/medaka/issues/1302). That attribution was
simply wrong: #1302's own filed repro never reaches this clause at all** (its
`mth` is bound only as an impl method, never a standalone `DFunDef`, so S1's
`funDef-names ∩ iface-method-names` conjunct is vacuously false there — see the
⚠️ under S1). **Whether #1302's actual mechanism — a wildcard import surfacing
a private interface's methods to a DIFFERENT check, the impl-obligation path —
shares any root cause with this vocabulary defect is unverified; nothing here
traces one. #1302 was bundled into "one ruling" by #1375's own framing (two
axes of one operand), not because this clause's ambiguity produced its bug.**
**Do not reintroduce a bare "visible" ANYWHERE IN THIS DOCUMENT** (widened
2026-08-07 from "S1–S9" — see the top-matter note's account of why, and treat
this as a *class* of ambiguous scope adjectives, not one string: "in scope",
"available to", "reachable from", "sees" are the same failure under a
different spelling). The three scopes are genuinely different and must be
spelled out:

| Term | Means | Used by |
|---|---|---|
| **nameable in `M`** | the declaration is one `M` may refer to by name: declared in `M`, **or** exported by a module `M` imports (directly, or through a re-export chain), **or** declared in the implicit prelude | S1's **interface** operand |
| **defined in `M` or imported into `M`** | the two cases that assign a shadow its **kind** (definer / importer) — so this is also, exactly, S1's **standalone** operand | S1's **standalone** operand + the kind partition |
| **graph-global** | ranges over **every** module of the loaded graph, whether or not any import path reaches it — `DICT-SEMANTICS.md` §8 **I5** | S2's **impl universe** only |

⚠️ **S1's two operands are NOT the same set, and that is deliberate.** The
standalone operand is the *narrower* one — it is pinned by S1's own kind
partition, not chosen: a standalone neither defined in `M` nor imported into `M`
has no shadow **kind**, and S2 is stated **per kind**, so S1 would classify an
occurrence that S2 then gives no denotation. The interface operand is the wider
**nameable in `M`**, which is what the phrase "the interface may live locally, be
imported, or be the prelude" was always for. Both operands are scoped; they are
scoped to different things, and each now says which.

**"Nameable" and "graph-global" are NOT the same set** either, and *that*
difference is the whole content of S1 versus S2: a module `M` with no import path
to module `P` cannot name `P`'s interfaces (so they create no shadow in `M`) but
`P`'s **instances** are still candidates for every goal arising in `M` (I5). One
is about **names**, the other about **instances**. ⚠️ Beware in particular that
"local ∪ imported ∪ prelude" is **not** a synonym for graph-global — it is
strictly narrower than I5's instance universe, an older wording of S2 used it as
one anyway, and that collision (the same three-item enumeration carrying opposite
force thirty lines apart) is what made S1 unreadable.

Given an occurrence of bare name `N` in module `M`:

- **S1 (shadow-hood).** **[SCOPE RULED 2026-08-06 — §1.0 + the S1-SCOPE note
  below; #1375]** `N` is a shadow **in `M`** iff `N` ∈ funDef-names(standalones
  **defined in `M` or imported into `M`**) ∩ iface-method-names(interfaces
  **nameable in `M`**). `N` is a **definer shadow** in module `M` iff the
  standalone is defined **in `M`**; an **importer shadow** iff it is *imported*
  into `M`. The *interface* may live in any of the three nameable-in-`M`
  positions — local, imported, or prelude — and it is **not required to be
  local**; but an interface that `M` cannot name creates **no shadow in `M`**,
  whether because no import path reaches its module at all or because its
  declaration is not exported through the path that does — this clause treats
  both failures of "nameable in `M`" uniformly; S1 does not distinguish which
  reason applies. **The impl universe is
  not narrowed by this clause** — see S2 and §1.0. Shadow-hood is per-module,
  per-name — not
  per-occurrence — and **the PRELUDE IS A MODULE**: a `core.mdk` occurrence of `N`
  is never a shadow of a user standalone, on *any* path, flat or multi-module
  (P0-21; before it, a user's `map` leaked into the prelude's own bodies). A name
  bound by a **local pattern** at the occurrence is not a shadow there — lexical
  scope resolves it to the binder.

  ⚠️ **This clause settles [#1353](https://github.com/MedakaLang/medaka/issues/1353)'s
  reachability axis. It does NOT, by itself, settle
  [#1302](https://github.com/MedakaLang/medaka/issues/1302)'s export-visibility
  axis, and a claim that it does is an over-claim — checked directly against
  #1302's own filed repro (2026-08-07): its `mth` is bound only inside `impl IB
  Blob where mth b = 5`, an **impl method**, never as a top-level standalone
  `DFunDef`. S1's shadow-hood conjunct is `funDef-names(...) ∩
  iface-method-names(...)` — with no standalone `mth` in the program, the
  `funDef-names` side is empty and the conjunct is **vacuously false**
  regardless of how the interface operand is scoped. Whatever governs #1302 (a
  private interface's methods reaching a wildcard importer's impl-obligation
  check, per its own filing) is therefore a **different mechanism** than the
  one S1 governs — #1375's own Epistemic-status section already listed "#1302
  measured under any predicate" as **not established**, and nothing landed here
  establishes it. **#1302's grading remains open**, not settled by this clause.

  > ### 🔒 S1-SCOPE — why the operands are nameable-in-`M` and not graph-global
  >
  > **The argument, so it can be disagreed with rather than merely obeyed.** S1
  > is a **name-resolution** rule: given a bare name the author wrote, it decides
  > which of two candidate denotations that name has. For the rule to be
  > *choosing*, both candidates must be things the author could have meant — and a
  > method of an interface `M` cannot name is one `M` cannot call, cannot import,
  > cannot request by writing a `=>` constraint (S5), and cannot write an `impl`
  > for. Letting it decide what `M`'s own written names denote is not a tie-break
  > between candidates; it is one candidate being supplied from outside the
  > program the author can see. That is also the reading under which S1's
  > **left** operand and its **right** operand carry the same scope: the left one
  > is *already* pinned by this clause's own kind partition (a standalone neither
  > defined in `M` nor imported into `M` has no shadow kind, so S2 — stated per
  > kind — would assign its occurrences no denotation at all).
  >
  > This is the same tie-break the **S2 inversion** rests on, applied one level
  > out: *"a name written at top level in a module is that module's name"*, and
  > *"an `import` is a **sibling** scope, not an **inner** one"*. Both are
  > statements about scopes the author can see.
  >
  > **What it costs, stated as a cost.** This is an acceptance **narrowing** in
  > exactly one cell — an importer shadow whose only declaring interface is not
  > nameable in `M`, applied to a receiver at a live-impl head. Such a program
  > compiles today and stops compiling under this clause. That is deliberate (it
  > was reaching a method it could not name), and it is the same migration shape
  > as `DICT-SEMANTICS.md` §8 I5's class 2.
  >
  > **What it does NOT cost: S2's global impl universe is untouched.** S1
  > constrains a set of **names**; S2 constrains a set of **instances**; I5 rules
  > those are separately scoped, and narrowing a name set cannot narrow the
  > instance environment. Measured (2026-08-06, `1443870c`): §2's corpus is
  > byte-identical under either scope for S1 — including **every** S2-importer
  > *dispatch* cell and `i5`'s explicit Fork-1 control. ⚠️ **Read that as a
  > corpus GAP, not as a proof of innocuousness** — it is identical *because* no
  > unit puts the interface outside `M`'s nameable set. See the corpus-blindness
  > note under the matrix; the discriminating fixtures are #1375's, not this
  > document's.
  >
  > **The strongest argument AGAINST this ruling, so it is not lost.**
  > `DICT-SEMANTICS.md` §8 I5's own price paragraph already concedes that a
  > program's meaning is a function of the whole loaded graph, which is exactly
  > the cost charged against the graph-global reading above. The answer is that
  > I5 buys that cost *for instances*, in exchange for a specific property —
  > global coherence (C4), which per-module candidate sets cannot provide — and
  > there is no analogous purchase for names: two modules resolving the same
  > **name** differently is scoping, not incoherence. Extending I5's concession
  > from instances to names would need its own argument, and I5 makes none. If
  > you want to reopen this ruling, that is the place to push.
  >
  > **⟲ Overturn condition.** This scope ruling is overturned by a program that
  > (a) is written entirely against names its own module can name, (b) is correct
  > under the language's other rules, and (c) can only be given its intended
  > meaning if S1's operands range over declarations the module cannot name —
  > equivalently, a legitimate use of a method the author could not have written
  > down. It is **not** overturned by a program that breaks under the narrowing
  > (that narrowing is the ruling's content), nor by a perf result on per-module
  > name sets (that is an argument about the implementation: cache the scoped
  > predicate, do not re-globalize it).
  >
  > **What is NOT ruled here** — three things, left open deliberately rather than
  > decided in passing:
  >
  > 1. **Whether an interface is nameable through a re-export chain** — the
  >    finer-grained sub-question inside the
  >    [#1302](https://github.com/MedakaLang/medaka/issues/1302) export-visibility
  >    axis — is deferred to the ordinary import/export rules. This clause
  >    *consumes* that answer; it does not define it. (It is also the arm a naive
  >    implementation of this clause is most likely to get wrong, by failing
  >    **closed**.)
  > 2. **Whether a PRELUDE standalone can be S1's left operand at all.** The kind
  >    partition admits only *defined in `M`* and *imported into `M`*, and the
  >    implicit prelude is neither on its face; no cell in §2 exercises it (every
  >    corpus unit's standalone is local or explicitly imported). Nothing here
  >    turns on it, so nothing here decides it.
  > 3. **Effect-label identity**, which `DICT-SEMANTICS.md` §8 I4 also leaves open.
  >
  > **What this ruling was NOT decided on.** It is an argument from the clause's
  > text and from what kind of rule S1 is — **not** a finding about what the
  > author of "may live anywhere" intended, which was not established and is not
  > claimed. It was adopted as a decision on that basis (#1375).

- **S2 (applied — THE INVERSION).** **[CHANGED 2026-07-14]**

  - A **definer** shadow `N` applied to any receiver denotes **the standalone,
    unconditionally** (`RLocal`). **The impl universe is NOT consulted.** The
    argument must type against the standalone's declared domain; a mismatch is a
    **located reject** at `check` (and at `run`/`build`, which typecheck first).
    *An impl of the shadowed interface at the receiver's head no longer
    overrides the standalone — **this is the inversion.*** (Carve-out: S5's
    dict-bound receiver.)

  - An **importer** shadow keeps the **old per-receiver rule**: if any impl of the
    shadowed interface for the receiver's head tycon `T` exists **anywhere in the
    loaded module graph** (the impl universe is **graph-global** — instances are
    coherent across modules, and import scoping never decides which instances
    exist: `DICT-SEMANTICS.md` §8 **I5**) → **method dispatch** (`RKey T`); else →
    the standalone (`RLocal`), with the same domain obligation. An `import` is a
    *sibling* scope, not an *inner* one, so it does not shadow.
    ⚠️ **This clause glossed `GLOBAL` as "local ∪ imported ∪ prelude" until the
    S1-scope ruling (2026-08-06, #1375). That gloss was wrong on its own terms,
    independently of anything about S1**: I5's instance universe is *"every
    instance declared in every module of the loaded graph … **not only** the
    modules the goal's own module imports"*, which is strictly **larger** than
    those three. And it was the **same three-item enumeration** S1 uses for its
    interface operand — a set that genuinely *is* those three and no more — so
    one phrase carried opposite force thirty lines apart, which is precisely what
    made S1 unreadable. Do not restore it: say **graph-global** here and
    **nameable in `M`** at S1 (§1.0).

- **S3 (N-way).** **[CHANGED]** **Vacuous for a definer shadow:** every occurrence
  is the standalone regardless of receiver, so no receiver selects an impl; a
  receiver at a live-impl head is a **located reject**, not a dispatch. The impls
  remain installed and still dispatch N-way — from any module that does not shadow
  the name, and, inside the shadowing module, through a written `=>` constraint
  (S5's carve-out). Unchanged for importer shadows. (Gated: `d3_definer_nway`,
  `definer_shadow_nway`.)

- **S4 (value position).** A shadow name NOT syntactically applied to its
  receiver (passed to a HOF, bound with `let`, sectioned) denotes the
  **standalone, always** (Phase 112: a method value has no receiver to dispatch
  on). Consequently value-position use over live-impl elements whose type
  mismatches the standalone's domain is a **located reject** — never a silent
  dispatch, never a runtime panic. *Unchanged, and now **consistent with** S2
  rather than an exception to it: under the old S2 this was the one place lexical
  shadowing already won; under the new S2 it is simply the general rule.*

- **S5 (ungrounded receiver).** **[CHANGED — narrowed]** A definer shadow applied
  to a receiver that never grounds (a polymorphic parameter) routes to the
  **standalone**, and the enclosing function **monomorphises to the standalone's
  declared domain** — it must NOT generalize over the shadow's receiver (a
  generalized wrapper later called at a live-impl type would run the standalone on
  a foreign value). Calling such a wrapper outside the standalone's domain is a
  located reject.

  **⭐ CARVE-OUT (the one dispatch a definer shadow still permits):** a receiver
  that is a **dict-bound `=>` constraint variable of the enclosing function**
  **DISPATCHES**. Writing `Sz a =>` is an explicit, written-down request to resolve
  through the interface, and — for a non-operator interface — it is the **only** way
  to name the method inside a shadowing module (§1.1). Removing it would make
  generic code unwritable in any module that shadows a method name.
  (`definerReceiverIsDictVar`; gated: `accept_constrained_receiver_shadow` → `14`,
  and `definer_shadow_nway`, which dispatches N-way through exactly this channel.)

  ✅ **The carve-out fires at MULTI-TYPARAM width too (row 29 / `d21`), since
  2026-07-17.** It briefly did not, and the cause was never in this machinery: `Ty`'s
  `TyApp Ty Ty` is binary, so `Ix a i` nests, and `parser.mdk`'s `extractConstraints`
  matched only the one-argument `TyApp (TyCon iface _) arg` — **every ≥2-argument
  constraint was silently discarded at parse** (`TyConstrained []`). S5's antecedent was
  false because *there was no constraint*: `definerReceiverIsDictVar` handles multi-argument
  constraints correctly, it simply never received one. **#604 fixed the parser
  (`extractConstraints` now walks the whole `TyApp` spine) and the carve-out started
  working with no change to this machinery at all** — `d21` went from a pinned
  REJECT/REJECT/REJECT gap to ACCEPT `4, 3`, and `4/400/3` at N-way width, so the
  per-receiver dict dispatch is real.

  ⚠️ **`d21`'s `4` is NOT `d11`'s `4`.** They are the same number from opposite verdicts,
  and the gate row says so, because this *will* look like a regression to someone:
  `d11`'s `4` was an **unqualified** call the impl universe stole — the abolished
  pre-inversion S2, a **bug**. `d21`'s `4` is dispatch the author **explicitly requested
  by writing `Ix a i =>`** — S5's carve-out, **correct**. Do not "fix" it back.

> ### ♻️ 2026-08-07 — **S6, S7 and S8 below were RESTORED. They had no text for three weeks.**
>
> They were dropped by `9c6dcee5` (2026-07-17), whose diff replaced S5's
> then-`#604`-blocked block and carried S6, S7 and S8 out with it. **Its commit
> message does not mention them**, and nothing in this document ever retired
> them: §2's matrix cites **S6** in the Clause column of rows 14–18 and **S8** in
> rows 8 and 26, §5's narrative cites both, and the top matter and §2 cite **S7**
> as a live claim — including *"S7's own note above says why"* under the matrix,
> which pointed at deleted text. Restored **verbatim** from `9c6dcee5^` with
> exactly two deviations, both in S8:
>
> - Its definer-gate sentence read *"is this a method of some **visible**
>   interface"*. A bare "visible" is retired document-wide (§1.0) and no scope
>   claim about `ifaceMethodName`'s lookup table has been established here, so
>   the adjective is **dropped, not replaced** — the predicate is a membership
>   test and the clause now says only that.
> - Its closing paragraph predicted a *"probable live divergence from S2"* at
>   multi-typaram importer width and recorded row 30 as **UNVERIFIED**.
>   `9c6dcee5` — the very commit that dropped the clause — **probed row 30 and
>   disproved that prediction**. The paragraph now records the measured outcome,
>   which §2's row 30 and this document's top matter already state. **S8's
>   normative content is unchanged by the swap**: the specified outcome for a
>   multi-typaram *importer* shadow was the standalone before and is the
>   standalone now.

- **S6 (module-independence).** **[CHANGED]** For a **definer** shadow the impl
  query is *deleted*, so S6 is **trivially satisfied**: where the interface and impl
  live cannot change the outcome, because the outcome no longer depends on them. An
  all-local live impl (`d2`) and an imported one (`d8`) now reject identically. For
  an **importer** shadow S6 stands as written: the impl query is
  location-independent, and where the standalone/interface/impl each live changes
  *detection bookkeeping*, never the outcome.

- **S7 (path agreement).** `run`, `check`, and `build` agree on every cell:
  `check` accepts iff `run` and the built binary produce the (identical)
  defined value. A shadow cell where they disagree is a conformance bug even if
  each path is individually defensible.

  > ⚠️ **Note what S7 COSTS you.** Because it *guarantees* the three engines agree,
  > **no differential gate can ever see a shadow bug** — the `eq [1] [2]` erasure was
  > invisible to every gate the project owns, **by construction**, and P0-20 even
  > "fixed" that cell by making all three paths agree on the *wrong* answer. Tests for
  > this rule must assert on **printed values against a pinned expectation**
  > (`run_check_agreement`'s `.out` pin; the shadow gate's `value` column), **never**
  > on cross-path agreement alone.

- **S8 (arity and typaram arity).** **[S-3 CLOSED 2026-07-17, #54]** Neither a
  method's *parameter* count nor its interface's *type-parameter* count changes the
  rule: a shadow of a multi-**param** method (`comb : a -> a -> Int`, row 8 / `d7`) and
  a shadow of a method on a multi-**TYPARAM** interface (`interface Ix a i`, row 26 /
  `d11`) both follow S2 keyed on the first parameter, so under the inversion the
  standalone wins in both and a live-impl receiver is a located reject.

  ⚠️ **The gating predicate is a Fork-1 boundary, NOT an arity restriction.** The
  **definer** entry points are gated on `ifaceMethodName` — is this name an interface
  method at all — and nothing more, because the inversion never consults the impl
  universe, so there is no receiver-to-typaram correspondence for them to require. The
  **importer** entry points keep `singleTyparamIfaceMethod` (renamed from the
  misleading `singleParamIfaceMethod`, which counted TYPE PARAMS while its name said
  method params — the name that sent an agent down a wrong hypothesis and is called out
  in #54). Fork 1's per-receiver rule genuinely does key the impl query on the receiver
  head standing at the interface's ONE typaram, and a multi-typaram interface offers no
  such correspondence to key on — `FromEntries c e`'s `fromEntries : List e -> c` does
  not even take its first typaram as an argument.

  ⚠️ **That is an implementation boundary, NOT a rule of the language — and #54 did not
  make it one.** S2's importer arm is itself unqualified by typaram arity and carries an
  explicit fallback (*"else → the standalone (`RLocal`), with the same domain
  obligation"*), so the **specified** outcome for a multi-typaram *importer* shadow is
  the standalone. An earlier draft of this clause called such shadows "out of scope,
  deliberately"; that was a claim about the *language* with nothing in S2 to support it,
  and it is **retracted**. A boundary in the code explains why the code is shaped as it
  is; it does not license this document to stop specifying.

  ✅ **And the binary conforms — measured, not assumed (row 30 / `i10`, 2026-07-17).**
  This clause used to predict the opposite: that because all three importer entry points
  decline at multi-typaram width, the occurrence falls through to **ordinary dispatch**,
  which has no "else → standalone" arm, so a multi-typaram importer shadow was a
  *"probable live divergence from S2"* — recorded as row 30, **UNVERIFIED**. Probed once
  [#604](https://github.com/MedakaLang/medaka/issues/604) made a probe possible: it is
  **conformant** (`4, 3`; `4/400/3` at N-way width). Ordinary dispatch reaches the impl
  for a live-impl head, and for a no-impl head **the env's binding of the bare name
  already IS the imported standalone**, so S2's fallback falls out without anyone
  implementing it.

### S9 — a CONSTRAINED standalone (added 2026-07-13; closes S-1)

When S2/S4/S5 resolve a shadow occurrence to **the standalone**, and that
standalone is itself `C a => …`, the occurrence is an **ordinary constrained
call**: `C` is solved at the receiver's type and the dictionary is supplied at
the call site, exactly as at a non-shadow call site. **`RLocal` therefore DOES
carry dicts** (`RLocal sym dicts`, mirroring `RKey tag dicts`).

> **The shadowed interface decides WHICH function; the standalone's own
> constraints decide WHICH DICTS. They are different interfaces.**

A `C` with no impl at the receiver's type is a **located reject at `check`**
(`No impl of Num for String` for `size "hi"`), never a runtime panic.

**Why this clause exists.** Both halves of dict-passing key off the same name
sets, and a constrained shadow is in **both**: the marking prePass is a
first-match guard chain whose *shadow* arm is tested **before** the *dict* arm
(`typecheck.mdk` `rewriteRPDict` / `rewriteRPDictArg` / `rewriteArgScoped`), so
the occurrence became `EMethodAt` and was **never marked as a dict application**
— while `dictPassDecl`, keyed on the same dict-name set, still gave the
**definition** its leading dict parameter. Def arity 2, call arity 1: the call
silently **under-applied**, the first real argument landed in the dict slot, and
`build` **exited 0 printing a raw heap pointer**.

**Do NOT "fix" this by reordering the guard chain so the dict arm wins.**
`EDictAt` carries no route and cannot dispatch — that would break matrix row 5
(`size (Box 3)` → the impl), which works. A shadow occurrence is genuinely
*undecided* at mark time; `EMethodAt` is the node that can be either. The fix is
to give its `RLocal` arm a dict channel.

**Tie-break rationale.** **[REPLACED 2026-07-14 — the old rationale is the premise
the inversion rejects; kept below, struck, because it is the argument you will
re-derive if you don't see why it fails.]**

> ~~*Per-receiver* (not lexical shadowing) because **a live impl is the ground truth
> of intent** — the user wrote a method for that exact type; unconditional lexical
> shadowing was the pre-`953d9ea1` behavior and mis-ran `size (Box 3)` on the
> standalone.~~

**Why that fails.** It silently assumes the impl is *the user's*. Almost always it
is the **PRELUDE's** — `impl Eq List`, `impl Mappable List`, `impl Foldable Option`
— and a user who writes `eq`, `map`, or `length` has expressed no intent about it
whatsoever. "The ground truth of intent" turned into "the prelude outranks you, and
we will not tell you." The `size (Box 3)` case that motivated the old rule is real
but is the *rare* one; it is now a **located reject**, which is the honest answer:
the module said `size` means `Int -> Int`, so a `Box` does not fit.

**The rule now.** *A name written at top level in a module is that module's name.*
A module's own top-level binding is an **inner** scope relative to the implicit
prelude and therefore **shadows** it; an `import` is a **sibling** scope and does
not. The stdlib's pattern of `map.mdk`'s `toList` beating the `Foldable` method of the same
name is not a special case of the old rule — it is the **general case** of the new one.

*Standalone-in-value-position = standalone* (S4) still holds for the original
reason: dispatch needs a receiver at the call and a method value carries no
evidence (no dict is threaded at value position on the arg-tag path) — the
standalone is the only coherent denotation. Under the new S2 it is no longer an
exception; it is just the rule.

### 1.1 Reaching the interface method from INSIDE a shadowing module

Under the inversion, a module that defines `toList` / `map` / `eq` / `display` / …
**cannot call that method by its bare name, for any type, anywhere in that module.**
That is the deliberate cost of true lexical shadowing, and it is the one thing the
new rule takes away that the old one gave. What still works:

| Route | Works? | Notes |
|---|---|---|
| **Operators** (`==`, `!=`, `<`, `+`, `++`, …) | **YES** | They desugar through the method-call path and never touch the bare-name funDef intersection (row 24, UNREACHABLE). A module with `impl Eq Foo` *and* a standalone `eq` still evaluates `Foo 1 == Foo 2` correctly. Covers `Eq`/`Ord`/`Num`/`Semigroup`. |
| **A written `=>` constraint** (S5 carve-out) | **YES** | `sizeOf : Sizeable a => a -> Int ; sizeOf x = size x` dispatches — including N-way. For a non-operator interface this is the **only** in-module route. Gated by `definer_shadow_nway`. |
| **Any other module** | **YES** | Shadow-hood is per-module (S1). A module that does not define a colliding standalone is completely unaffected — including the prelude's own bodies (P0-21). |
| **Module alias** — `import core as C` → `C.eq` | **NO** | `Unbound variable: C.eq` |
| **Member alias** — `import core.{eq as eqM}` → `eqM` | **NO** | `Unbound variable: eqM. Did you mean 'eq'` |
| **Interface-qualified** — `Eq.eq x y` | **NO** | No such syntax. |

**Recommended follow-up (not a blocker):** make `import core.{eq as eqM}` resolve.
The member-alias machinery already exists and is gated
(`test/eval_modules_fixtures/import_alias/` aliases a *user* interface's method);
the prelude is simply not reachable as an importable module for aliasing. It is a
contained change to `resolve.mdk`'s import handling and needs **no new syntax**.
Until then the answer for a user is: **rename your function.**

## 2. Decision matrix (re-observed 2026-07-14, post-`eb92cdff`; now GATED)

Axes: shadow kind × receiver impl-status × topology × use form. "Outcome" is
the S1–S9-specified result; **Status** is what the binary actually does on all
three of run / build / check. Fixtures in `test/shadow_fixtures/`.

> ⚠️ **This column used to be STALE, and that is the reason the gate exists.**
> From 2026-07-10 to 2026-07-14 rows 10 / 12 / 13 / 14 read **BUG** while the
> binary was in fact conformant on all four — P0-19 and P0-20 had fixed them,
> and this table was never updated even though the §5 change-log a few
> paragraphs below *said so*. A spec that says BUG where the binary says OK
> sends the next agent down a wrong hypothesis; that is exactly what it did.
> Every Status below is now re-observed empirically **and enforced by
> `test/diff_compiler_shadow_semantics.sh`**, which drives every fixture
> through `check` + `run` + `build` and pins the value. This column can no
> longer drift without a gate going red.

| # | Cell (kind · receiver · topology · use) | Clause | Specified outcome | Fixture | run | build | check | Status |
|---|---|---|---|---|---|---|---|---|
| 1 | not a shadow — standalone only | S1 | ordinary call | — (whole tree) | — | — | — | BASELINE |
| 2 | not a shadow — method only | S1 | ordinary dispatch | — (construct-coverage gates) | — | — | — | BASELINE |
| 3 | definer · no-impl recv (impl exists for another type) · 1-file · applied | S2 | RLocal → 4 | `d1_definer_noimpl.mdk` | 4 | 4 | accept | **OK** |
| 4 | definer · no-impl recv (interface has ZERO impls) · 1-file · applied | S2 | RLocal → 4 | `d1b_definer_noimpl_zeroimpls.mdk` | 4 | 4 | accept | **OK** |
| 5 | definer · live-impl recv · 1-file · applied | S2 | **REJECT** `Int vs Box` @ `size (Box 3)`; `size 3` → 4 | `d2_definer_liveimpl.mdk` | reject | reject | reject | **OK** (**FLIPPED 2026-07-14** — was `3,4` (dispatch). The inversion: the module's own `size : Int -> Int` takes the call, so `Box` mistypes) |
| 6 | definer · N-way (2 impls + no-impl) · 1-file · applied | S3 | **REJECT** ×2 (`Box`, `Bar`); `size 3` → 4 | `d3_definer_nway.mdk` | reject | reject | reject | **OK** (**FLIPPED** — was `3,30,4`. S3 is now VACUOUS for a definer shadow: no receiver selects an impl. The impls still dispatch N-way through a `=>` dict — see `definer_shadow_nway`) |
| 7 | definer · live impl at PARAMETRIC head (`impl … (P a)`) · applied | S2 | **REJECT** `Int vs P Bool` @ the `P a` receiver; 4 | `d6_definer_parametric_receiver.mdk` | reject | reject | reject | **OK** (**FLIPPED** — was `9,4`. A parametric impl head is no more privileged than a concrete one) |
| 8 | definer · TWO-param method shadow · applied | S8 | **REJECT** `Int vs Box` @ `comb (Box 1) (Box 2)`; `comb 2 3` → 6 | `d7_definer_multiparam_method.mdk` | reject | reject | reject | **OK** (**FLIPPED** — was `3,6` via ordinary arg-dispatch. Multi-*param methods* now follow S2 like everything else — and since #54 so do multi-*TYPARAM interfaces*: row 26 / `d11` is this row at multi-typaram width) |
| 9 | definer · value position · no-impl elements · **method/standalone arity EQUAL** | S4 | standalone → [2, 3, 4] | `d4_definer_value_pos.mdk` | [2,3,4] | [2,3,4] | accept | **OK** — ⚠️ arity-EQUAL, so this row is **blind to S1-RESIDUAL-A (#410)**; rows 9a/9b/9c are the arity-DIFFERING cells |
| 9a | definer · value position · **method arity 2 / standalone arity 1** · annotated result | S4 | standalone → [2, 3, 4] | `d17_definer_value_pos_arity_differ.mdk` | [2,3,4] | [2,3,4] | accept | **OK** (**FIXED 2026-07-16 #410** — was `build` exit 0 printing PAP heap pointers as Ints, an S0 silent wrongness; see §6 S1-RESIDUAL-A (A)) |
| 9b | definer · value position · arity-differing · **ZERO impls** of the iface | S2+S4 | standalone → [2, 3, 4] | `d19_definer_value_pos_arity_differ_zeroimpls.mdk` | [2,3,4] | [2,3,4] | accept | **OK** (**FIXED 2026-07-16 #410** — proves the impl universe is irrelevant: shadow-hood + arity mismatch + value position suffice) |
| 9d | definer · value position · **method arity 1 / standalone arity 2** (opposite direction) · annotated | S4 | standalone → 3 | `d20_definer_value_pos_arity_differ_opposite.mdk` | 3 | 3 | accept | **OK** (**FIXED 2026-07-16 #410** — pins the other side of the route-derived arity) |
| 9c | definer · value position · arity-differing · **UNANNOTATED** result | S4 | standalone → [2, 3, 4] | `d18_definer_value_pos_arity_differ_unannot.mdk` | [2,3,4] | accept, **binary SEGFAULTs** | accept | ❌ **KNOWN-BAD (#410 (B), open)** — `println`'s `Display` requirement gets a NULL element dict (RNone route). NOT the emitter: the route is stamped in `types/typecheck.mdk`. Pinned `BUILD_CRASH` (self-draining) |
| 10 | definer · value position · LIVE-impl elements | S4 | located REJECT | `d4b_definer_value_pos_liveimpl.mdk` | reject `Int vs Box` | reject | reject | **OK** (fixed P0-19 batch 2 `ebb8ee90`; was a 3-way split) — ⚠️ also arity-EQUAL |
| 11 | definer · ungrounded recv · wrapper used at standalone domain | S5 | 4; wrapper : Int -> Int | `d5_definer_poly_receiver.mdk` | 4 | 4 | accept (but `useIt : a -> Int` — over-general, the row-12 hole) | **OK** (value), caveat on scheme |
| 12 | definer · ungrounded recv · wrapper CALLED at live-impl type | S5 | located REJECT | `d5b_definer_poly_liveimpl_call.mdk` | reject `Int vs Box` | reject | reject | **OK** (fixed P0-19 batch 1 `ef0874f3`; was a silent miscompile) |
| 13 | definer · no-impl recv · domain mismatch (`size "hi"`) | S2 | located REJECT | `d9_definer_reject.mdk` | reject `Int vs String` | reject | reject | **OK** (fixed P0-19 batch 1 `ef0874f3`; was check-over-accept → build garbage) |
| 14 | definer · live impl, interface+impl IMPORTED · applied | S6 | **REJECT** `Int vs Box` @ `size (Box 3)`; 4 | `d8_definer_imported_impl/` | reject | reject | reject | **OK** (**FLIPPED 2026-07-14 — DELIBERATELY REVERTS `ebb8ee90`** (P0-19 batch 2), which made this dispatch cross-module. That fix faithfully implemented the OLD S2; the inversion abolishes the rule it implemented. S6 now holds VACUOUSLY — the impl universe is never queried, so *where* the impl lives cannot matter. Rejects identically to the all-local `d2`, which is the point. Also re-pinned in `diff_compiler_check_cli_modules`'s `definer-shadow-xmod` leg) |
| 15 | importer · live impl · interface LOCAL to consumer | S2/S6 | RKey → 3 | `i1_importer_local_iface/` | 3 | 3 | accept | **OK** |
| 16 | importer · no-impl recv · interface LOCAL | S2/S6 | RLocal → 4 | `i1_importer_local_iface/` | 4 | 4 | accept | **OK** |
| 17 | importer · live impl · interface+impl in a THIRD module | S6 | RKey → 3 | `i3_importer_imported_iface/` | 3 | 3 | accept | **OK** |
| 18 | importer · no-impl recv · third-module interface | S6 | RLocal → 4 | `i3_importer_imported_iface/` | 4 | 4 | accept | **OK** |
| 19 | importer · no-impl own type · PRELUDE interface (the stdlib shape) | S2 | standalone → True/False | `i4_importer_prelude_iface/` | T,F | T,F | accept | **OK** |
| 20 | importer · LIVE prelude impl recv (`isEmpty [1,2]`) alongside the shadow | S2 | method → False/True | `i4_importer_prelude_iface/` | F,T | F,T | accept | **OK** |
| 21a | importer · value position · no-impl elements | S4 | standalone → [2, 3, 4] | `i6_importer_value_pos/` | [2,3,4] | [2,3,4] | accept | **OK** (fixed #411 2026-07-16; was a LOUD S7 split — check+run gave `[2, 3, 4]` but `build` died `no impl of method 'size' for type 'Int' (slice 6)`, no binary, on a valid program) |
| 21b | importer · value position · LIVE-impl elements | S4 | located REJECT | `i7_importer_value_pos_liveimpl/` | reject `Int vs Box` | reject | reject | **OK** (fixed #411 2026-07-16; was the SILENT half — check reported zero diagnostics and run AND build both printed `[1, 2]`, all three engines agreeing on the answer S4 forbids. The exact S7 trap: no differential gate could see it) |
| 22 | importer · N-way | S3 | per-receiver → 3, 30, 4 | `i8_importer_nway/` | 3,30,4 | 3,30,4 | accept | **OK** (probed while fixing #411; already conformant). ⚠️ This row formerly read "expected ≡ row 6" — **stale**: row 6 FLIPPED to REJECT when S3 became vacuous for *definer* shadows, but S3 is explicitly *"Unchanged for importer shadows"* (Fork 1). Per-receiver is the expectation; the fixture is Fork 1's control at N-way width |
| 23a | return-position method shadow (no receiver param, e.g. `pure`-like) · DEFINER | S4 | value-position rule → standalone → 4 | `d13_definer_return_pos.mdk` | 4 | 4 | accept | **OK** (probed while fixing #411; already conformant) |
| 23b | return-position method shadow · IMPORTER | S4 | value-position rule → standalone → 4 | `i9_importer_return_pos/` | 4 | 4 | accept | **OK** (probed while fixing #411; already conformant) |
| 24 | operator-named shadow (`==` etc.) | — | n/a — operator occurrences resolve through the desugared method-call path, not bare-`EVar` funDef intersection | — | — | — | — | UNREACHABLE |
| 25 | definer · **CONSTRAINED** standalone (`size : Num a => a -> a`) · no-impl recv | S9 | RLocal **carrying the standalone's dicts** → 4 | `d10_definer_constrained.mdk` | 4 | 4 | accept | **OK** (fixed 2026-07-13, S-1 / clause S9; was `check` green + `run` E-PANIC + `build` printing a raw heap pointer) |
| 26 | definer · method of a **multi-TYPARAM interface** (`interface Ix a i`) · applied | S2/S8 | **REJECT** `Int vs Box` @ `get (Box 3) 1`; `get 3 1` → 3 | `d11_definer_multityparam_iface.mdk` | reject | reject | reject | **OK** (**S-3 FIXED 2026-07-17, #54** — was the corpus's last BUG row: `run` E-PANICked `unknown op '*'` while check+build agreed on the OLD per-receiver answer `4,3`, an S7 violation. Every definer entry point gated on `singleParamIfaceMethod`, which counts interface TYPE PARAMS, not method params, so `Ix a i` bypassed the machinery entirely. Fixed by splitting that predicate **by shadow kind**: `ifaceMethodName` (typaram-agnostic) gates the definer arms — under the inversion they never query the impl universe, so typaram arity is irrelevant to them — while `singleTyparamIfaceMethod` (the rename) keeps gating the Fork-1 importer arms, whose per-receiver rule *does* key on the receiver standing at the interface's one typaram. Row 26 is now simply row 8 / `d7` at multi-typaram width) |
| 27 | definer · **UNGROUNDED (numeric-literal) receiver** whose grounded head HAS a live prelude impl | S2+S5 | standalone → 3, 30 | `d12_definer_ungrounded_literal.mdk` | 3,30 | 3,30 | accept | **OK** (the P0-20 cell, now INVERTED: `eq 1 2` = 3, was `False`. `groundShadowReceiver` grounds the literal to the standalone's domain BEFORE the S2 question, so check/run/build ask it about the same head) |
| 28 | **importer** · **UNGROUNDED (numeric-literal) receiver** · prelude iface + the Fork-1 control | S2+S5 | standalone → True, False; **method** → False, True | `i5_importer_ungrounded_literal/` | T,F,F,T | T,F,F,T | accept | **OK** (fixed 2026-07-14, **S1-RESIDUAL-B** — was `Type mismatch: Int literal vs Int Int` on ALL THREE paths, PRE-EXISTING, and invisible to the corpus because i1/i3/i4 all use GROUNDED receivers. The last two lines are the Fork-1 control: an importer shadow still dispatches on a live-impl head) |

| 29 | definer · **dict-bound `=>` receiver** (S5's carve-out) on a **multi-TYPARAM interface** | S5 (carve-out) + S2 | **dispatch → 4**; the unqualified `get 3 1` → standalone **3** | `d21_definer_multityparam_dictvar_receiver.mdk` | 4,3 | 4,3 | accept | **OK** (**GAP CLOSED 2026-07-17 by [#604](https://github.com/MedakaLang/medaka/issues/604)**, with **no change to the shadow machinery**. #54 pinned this REJECT/REJECT/REJECT as an S5 gap and it went RED the day #604 landed — the ledger working a **third** time. The cause was `parser.mdk`'s one-level `extractConstraints`: `Ix a i` nests as `TyApp (TyApp (TyCon Ix) a) i`, no arm matched, and every ≥2-arg constraint was discarded at parse, so S5's antecedent was vacuous. ⚠️ Two errors of #54's own are corrected in this row: it predicted the dispatch value as **3, 6** — that was `d7`'s pair, copied; the correct pair is **4, 3** — and the gate row asserted mode `NONE`, i.e. **agreement only**, on a matrix whose own S7 note says agreement is the *precondition* for the worst bug here. The row is now `ALL_EXACT`, pinning `4\n3`) |

| 30 | **importer** · shadow of a method on a **multi-TYPARAM interface** | S2 (importer arm) | live impl → dispatch **4**; no-impl → standalone **3** | `i10_importer_multityparam_iface/` | 4,3 | 4,3 | accept | **OK** (**VERIFIED 2026-07-17 — and it DISPROVED the prediction this row was created with.** #54 recorded a *"probable live divergence from S2"* here, reasoning that since all three importer entry points decline at multi-typaram width, the occurrence falls to ordinary dispatch, **which has no "else → standalone" arm**. It is **conformant**: ordinary dispatch reaches the impl for a live-impl head, and for a no-impl head **the env's binding of the bare name already IS the imported standalone**, so S2's fallback falls out without anyone implementing it. `4/400/3` at N-way width. The fixture is #604-independent — no `=>` appears in it) |

| 31 | definer · **value position** over no-impl elements · method of a **multi-TYPARAM interface** (`interface Ix a i`) · UNANNOTATED | S4 | standalone → [2, 3, 4] | `d22_definer_multityparam_value_pos.mdk` (+ `d22b` String elems, `d22z` app-head control) | [2,3,4] | [2,3,4] | accept | **OK** (**FIXED 2026-07-19, [#724]** — row 9c/`d18` at multi-typaram width, the cell the corpus lacked: `d18` is single-typaram, `d11`/row 26 is multi-typaram but an APP head. The CHECK path grounded the value position to the standalone typaram-agnostically (`maybeStandaloneValueMono`'s definer arm = `ifaceMethodName`), but the EMIT path DECLINED it behind a blanket `singleTyparamIfaceMethod` gate, so `map size` inferred a function element type → NULL `Display` element dict → the shipped binary **SEGFAULTed (139)** while check/run were clean — the #410 skew at multi-typaram width. Fixed by splitting `maybeStandaloneValueMonoEmit`'s gate per shadow kind (`emitValueShadowGate`): DEFINER arm `isDefinerShadow` (typaram-agnostic), IMPORTER arm `singleTyparamIfaceMethod` (i10/Fork 1). Safe against the app-head ambiguity because a definer app head is bracketed `shadowHeadCtxRef` True by `inferDefinerShadowApp` — `d22z` is the control) |

| 32 | **importer** · shadow of a PRELUDE method whose live-impl receiver is **EXTERN-SOURCED** | S2 (importer arm) | standalone → `tok`; method → `3`, `2`, `97` | `i11_importer_extern_receiver/` | tok,3,2,97 | tok,3,2,97 | accept | **OK** — the **PROVENANCE** axis, not a new type axis. `display (3 : Int)` and `display (stringLength "xy")` have the SAME receiver type and must route the same way; only how the `Int` was obtained differs. **ADDED 2026-08-04 by the adversarial review of [#1274](https://github.com/MedakaLang/medaka/pull/1274) (#1111 A-2.2b), which shipped an S0 this corpus could not see**: a dispatch-existence retest was changed to compare the goal head's *identity* against the impl head's, and `stdlib/runtime.mdk`'s extern signatures never pass through resolve's head-stamping walk, so an extern-sourced `Int` carries no `TyConOrigin` and the retest answered "no impl" — silently rerouting the call to the imported standalone. `diff_compiler_shadow_semantics` graded **36/36 on the broken binary**, because **every other cell in this corpus uses an annotated or literal receiver**. This row is the one the ⭐ rule in that gate's header (*"vary the receiver's PROVENANCE"*) had always asked for and nobody had written |

**Tally: 26 OK · 0 BUG · 0 GAP · 0 UNVERIFIED · 3 UNTESTED-NO-FIXTURE ·
1 UNREACHABLE · 2 baselines.**

> ### 🕳️ THIS MATRIX DOES NOT GRADE S1's SCOPE. A green shadow gate says NOTHING about it.
>
> **No unit in `test/shadow_fixtures/` puts the shadowed interface outside the
> occurrence module's nameable set** (§1.0), so **no row above discriminates
> S1's scope from a graph-global reading of the same clause.** Derived, not
> assumed: every `d*` unit is single-file, so nameable-in-`M` and graph-global
> coincide there by construction; `i1`/`i6`/`i6b`/`i7`/`i8`/`i9`/`i10` declare
> the interface in `main.mdk` itself; `i3` and `d8` import it by name; `i4`/`i5`
> shadow prelude `Foldable` and `i11` prelude `Display`.
>
> **Measured, not inferred** (2026-08-06, `1443870c`): the whole corpus grades
> **byte-identically** whether S1's operands are scoped or graph-global —
> `test/diff_compiler_shadow_semantics.sh` reports **37 assertions** (the **36**
> fixture units the directory contains, plus the gate's own coverage self-audit)
> passing under each, with the two logs `diff`-identical. ⚠️ **36 units, 37
> assertions — the two numbers are not interchangeable, and neither is a count to
> trust from this page.** Derive them: `ls test/shadow_fixtures/ | wc -l`, and the
> `ok   coverage:` line the gate prints. (A figure of *17* has circulated for this
> corpus. It is wrong and it is not a stale-but-once-true number — do not
> reintroduce it.)
>
> **So this section cannot be the evidence that S1's scope is implemented.** The
> corpus is blind to the axis, and a reader who takes a green
> `diff_compiler_shadow_semantics` as having graded the clause will be wrong.
> Same shape as row 32's lesson (`36/36` on a *broken* binary, because every unit
> then used an annotated or literal receiver) one axis over: **this corpus has
> now twice graded green over a cell nothing in it could express.**
>
> 🚧 **OWED, not landed here.** [#1375](https://github.com/MedakaLang/medaka/issues/1375)
> is the spec unit; it rules the clause and repairs the vocabulary but does not
> touch `compiler/` or `test/`, so it cannot itself land a KNOWN-BAD fixture row
> in §2 pinned to a guessed value (this document's own capture-goldens
> discipline: a captured value must be independently established, never merely
> observed).
>
> - **Reachability row (#1353 axis) — owed to M-2** ([#1354](https://github.com/MedakaLang/medaka/issues/1354)).
>   A shadow occurrence in module `M` where the interface's declaring module `P`
>   is loaded in the graph but `M` has no import — direct or transitive — to
>   `P`. #1375's own "sharper repro", measured at `1443870c`: an imported
>   standalone `size : Int -> Int` applied to a `Box` whose `impl Sizeable Box`
>   lives in a module the occurrence module never imports, accepted at exit 0
>   printing `300`; deletion control `Type mismatch: Int vs Box`. On the
>   mechanism (verified 2026-08-07 by tracing to the actual consumer, not
>   inferred from §3's row below, which names the wrong one): the Module-path
>   shadow test reads `crossRun.value.universeIfaceMethodsRef`, grown per module
>   by `appendUniverseAccums`'s call to `allIfaceMethodNames` — which carries
>   **no `pub` filter** — accumulated **cumulatively in the loader's
>   dependency-first topological order**, the same shape `DICT-SEMANTICS.md` §8
>   I5's own "PARTIAL — cumulative, not global" finding documents for the impl
>   universe: module *k*'s test sees every interface method declared in every
>   module processed at or before *k*, whether or not *k* imports it. This is
>   NOT `accData`/`publicDataDecls`/`foldModules` (an earlier draft of this
>   paragraph named that path; it is dead on the Module path — see the marker on
>   §3's S1-detect row).
> - **Export-visibility row (#1302 axis) — ownership uncertain, NOT necessarily
>   M-2.** Whether this axis even has an S1-shaped corpus row is unresolved:
>   #1302's own filed repro does not exercise S1's shadow-hood conjunct at all
>   (see the ⚠️ under S1 above — its `mth` is an impl method, never a
>   standalone `DFunDef`, so `funDef-names ∩ iface-method-names` is vacuously
>   false there regardless of interface scoping). A genuine S1-shaped
>   export-visibility row would need a *different* program — a real
>   definer/importer shadow where the interface lives in a module `M` imports
>   directly but the interface's own declaration is not exported along that
>   import — and whether such a shape reproduces anything wrong today is
>   unverified; it would also be a distinct question from #1302's actual
>   mechanism (a wildcard import surfacing a private interface's methods to the
>   impl-obligation check, per its own filing), not a re-export-chain case (the
>   S1-SCOPE note's "not ruled" item 1 is the re-export-chain sub-question
>   specifically, and is not this row). Owed to whoever picks up #1302's actual
>   mechanism.
>
> Until then: **do not read the 26 OK / 0 BUG tally above as covering either
> axis** — see the corpus-blindness note this paragraph sits under.

> ### ⚠️ **`0 BUG` DOES NOT MEAN "NO VIOLATIONS". READ THE GAP AND UNVERIFIED COLUMNS.**
>
> **BUG** here means *the engines disagree with each other* — and that is an
> **observability** property, not a severity one. It is the thing a differential gate can
> see, which is why the column exists; it is **not** the thing that hurts users.
> **S7's own note above says why: `run`/`check`/`build` are *guaranteed* to agree, so a
> shadow violation they all share is invisible BY CONSTRUCTION** — the `eq [1] [2]`
> erasure that this entire inversion exists to fix was agreed on by all three engines, and
> P0-20 once "fixed" a cell by making all three agree on the *wrong* answer.
>
> **Under a naive reading of the BUG column, both of those would have counted as `0 BUG`.**
> So a **GAP** (a clause the binary does not reach) or an **UNVERIFIED** row is *not* a
> lesser finding that happened not to qualify. Rows 29 and 30 both read `0 BUG` while
> row 29's cell was shipping a **raw heap pointer at exit 0** — that is what `0 BUG` is
> worth on its own. Three engines agreeing is the *precondition* for the worst bug this
> document knows about, not evidence of health.
>
> ⚠️ **The same trap has a MODE column.** A row pinned `NONE` asserts *verdicts only* —
> it cannot see a wrong value. #54 pinned row 29 `NONE`; when #604 flipped that cell to
> ACCEPT, the gate could report `ACCEPT ACCEPT ACCEPT PASS` **without ever looking at
> what it printed**. Both rows are now `ALL_EXACT`. **If a row can accept, pin its
> VALUE.**
>
> **The tally is a map of what is CHECKED, not a claim about what is CORRECT.** If you
> want the second thing, read the rows.
Rows 10/12/13/14 were BUG until P0-19; row 25 was BUG until S-1; **row 28 was BUG
until 2026-07-14 (S1-RESIDUAL-B) — and it was PRE-EXISTING, not introduced by the
inversion.** Row 26 was the last open **BUG** and closed 2026-07-17 (#54) — which is also when
row 29 was *added*, as that fix's residual: a **GAP** (a clause the binary did not
reach), not a BUG (a divergence between the engines), and strictly better than what it
replaced. **Row 29 then closed on 2026-07-17 with #604** — in the *parser*, with no
change to the shadow machinery — and row 30, added UNVERIFIED at the same time, probed
**conformant**.

> ⭐ **Row 29 is why "fix the cell" is not the same as "close the axis."** #54 was
> filed as, and was, a loud S7 violation on row 26. Driving that fix to its edges —
> crossing row 26's axis (typaram arity) with the axis **this document's own warning
> above names** (receiver provenance) — turned up row 29: the *same* bypass, one axis
> over, was **silently shipping a raw heap pointer at exit 0**. Strictly worse than
> the panic that got the issue filed, and invisible to every gate, because by S7 all
> three engines have to agree before a differential gate can see anything. **Twice
> now the silent bug has been hiding on the provenance axis** (rows 27–28 were the
> first time). Cross it *before* you call a shadow fix done.

> ⭐ **Rows 27–28 exist because the corpus was blind to an entire AXIS.** Every
> importer fixture used a **grounded** receiver, so the gate graded **18/0 while
> row 28 was broken**. A numeric literal is `Num a => a` — **ungrounded** at
> inference time — so the routing decision is taken before the receiver has a head
> tycon, and the type is then resolved against a receiver that has *since changed*.
> **That is the P0-20 root cause, and it is the root cause of this entire arc.**
> When adding a shadow fixture, vary the receiver's **PROVENANCE** — literal /
> grounded / dict-bound — not just its type. **A gate that cannot express a cell
> cannot defend it.**

> **The 2026-07-14 inversion moved exactly five rows — 5, 6, 7, 8, 14 — all
> ACCEPT → located REJECT.** The change is **monotonically more rejecting** for
> definer shadows, which is what made it safe to land: it cannot turn a rejected
> program into a silently-miscompiled one. (One cell went the other way, outside
> this matrix: `run_check_agreement`'s `p0_20_shadow_literal_result_pinned` REJECT →
> ACCEPT — its reject existed *only* because the method was stealing the call and
> returning a `String` where the annotation said `Int`.)
>
> **Rows 15–20 (importer shadows) did NOT move, and must not.** They are the Fork-1
> boundary. If any of them moves, the inversion has leaked out of definer scope —
> `test/diff_compiler_shadow_semantics.sh` is the tripwire, and during development it
> caught exactly that, twice. It is also what proved the #54 fix stayed in scope: **row
> 26 moved (deliberately) and rows 15–20 did not**, on the same run.
>
> Row 26 used to be named here alongside them, for the opposite reason — it was the S-3
> **ledger** row and had to stay pinned to the *bug*. #54 fixed the bug, so it moved to
> REJECT/REJECT/REJECT and is now just another definer cell.

**In-tree census (re-verified 2026-07-14, two independent methods).** The whole
tree contains **exactly five** definer shadows, and the inversion is a **semantic
no-op for all five** — none is ever applied to a receiver whose head has an impl of
the shadowed interface, so all five routed `RLocal` before and route `RLocal` now:
`compiler/frontend/parser.mdk:221` `orElse` (46 uses, all on `Parser`; there is no
`impl Alternative Parser`) · `stdlib/map.mdk:158` `isEmpty` + `:347` `toList` (all
on `Map`; there is deliberately no `impl Foldable Map`) · `stdlib/hash_map.mdk:63`
`isEmpty` + `:220` `toList` (all on `HashMap`; same). Every interface in production
source lives in `stdlib/core.mdk` (49 method names), so shadow-hood reduces to
`standalone-names ∩ those 49`. This is why `selfcompile_fixpoint` (C3a/C3b) and
`typecheck_compiler_source` stayed green through the inversion — the compiler does
not depend on the rule that changed. `hash_map.mdk:210`'s comment is a **workaround
for the old rule** ("an internal use of `toList` would be shadowed by the method and
mistyped") — the inversion retires the need for it.

## 3. Per-stage enforcement table (clause → site → keying assumption)

The four P0-18 bugs were each a *disagreement between two rows of this table*.
Line numbers at `cfc4fa5a`.

| Clause | Stage / site | What it enforces | **Keying assumption** |
|---|---|---|---|
| S1 detect (run/check, definer) | 🔴 **STALE — re-verified 2026-08-07, wrong on the Module path.** `buildDefinerShadows` is the FLAT-path function; on the MODULE (multi-module) path the reader is `definerShadowsFromSet`, keyed on `crossRun.value.universeIfaceMethodsRef` (grown by `appendUniverseAccums` → `allIfaceMethodNames`) — not the symbols or line numbers this cell names. Line numbers are additionally untrusted per this table's own preamble | this module's funDefs that name a method | **bare-name intersection, but NOT via `accData`/`publicDataDecls` — those are DEAD on the Module path** (`fullUniverse` binds `[]` there; an in-source comment calls the old accData concat "a dead per-module O(N) concat"). The real feeder, `allIfaceMethodNames`, has **no `pub` filter** (sees a private interface's methods too — the opposite of what "public decls" implies) and is accumulated **cumulatively in the loader's dependency-first topological order**, not filtered by import reachability — the same shape as `DICT-SEMANTICS.md` §8 I5's "PARTIAL — cumulative, not global" row for the impl universe. This is the mechanism behind #1375's reachability axis; see row-14 BUG |
| S1 detect (run/check, importer) | `typecheck.mdk:17020` `buildStandaloneShadowsGraph` | imported standalones shadowing a method | imported funDef names minus local names, methods scanned across `implDecls ++ prog` (the `cfc4fa5a` fix: LOCAL interfaces included) |
| S1 detect (build path) | `typecheck.mdk:11475` `computeMangledShadowMap` + `unitMangledShadows:11480`, set once at `elaborateModules:11932` (`mangledShadowMapRef`); consumed by `buildDefinerShadows:11460` and `buildStandaloneShadowsGraph:11487-11497` | recover shadows AFTER mangling renamed the standalone | **forward-constructs `mangledName mid m`** per (module, method) and checks it against actual funDefs — exact, not prefix-stripping; empty map on the un-mangled path (inert) |
| S1 mark | `typecheck.mdk:11942` `markRpNames` (∪ `buildStandaloneShadowsGraph`) → `prePassDictArg`/`prePassModulePairArg:11943-11944` rewrite occurrences to `EMethodAt` | occurrences get a route ref | graph-wide name set over USER modules (core excluded) |
| (enabler of the S1 build split) | `compiler/backend/private_mangle.mdk`: `mangleUnits:117`, `buildUnitRenameMap:372`, `renameDecl` DFunDef `~578` + `renameScoped` EVar `~651` rename the standalone def + refs to `<mid>__N`; `renameIfaceMethod:626`/`renameImplMethod:636` leave the method **NAME bare** (header `:34-46`: dispatch is by bare name cross-module) | collision-free private symbols | **the asymmetry**: standalone side mangled, method side bare — which is exactly what defeated name-intersection detection (bug `0b4a7882`); driver order `compiler/entries/entry_support.mdk:133-134` (`runEmitWith`) and `:145-146` (`emitModulesWith`): mangle STRICTLY before mark |
| S2 type + record (definer) | app-head peel → `definerShadowArgHead` (definer disjunct gated `ifaceMethodName`, fires on `definerShadowNamesRef`; importer-on-emit disjunct gated `singleTyparamIfaceMethod`, fires on a mark-seeded `RLocal sym` — the cross-module emit signal) → `inferDefinerShadowApp` + `definerShadowHeadType`. The un-marked `check` path peels via `definerShadowVarHead` → `inferDefinerShadowVarApp`. **`definerReceiverDispatches` is the single decision point** | **[CHANGED — THE INVERSION]** a definer shadow types against the STANDALONE scheme, **always** (via the mangled sym on build — the scheme-selection SIGSEGV fix); `enforceStandaloneDomain` then imposes its declared domain, so a live-impl receiver is a located reject. The only dispatch arm left is S5's dict-bound receiver | ⚠️ **`definerShadowArgHead` fires for IMPORTER shadows too** — its `routeLocalSym != ""` arm is the cross-module emit signal, so `inferDefinerShadowApp` serves BOTH kinds on the mangled path. "Did we reach this function" is therefore **NOT** the same question as "is this a definer shadow": `definerReceiverDispatches` must re-ask it via `isDefinerShadow` (`definerShadowNamesRef` never holds an imported standalone) or the inversion leaks onto importers and breaks `import map` |
| S2 type + record (importer) | `typecheck.mdk:4950` `shadowStandaloneHead` → `inferShadowApp:4979`; standalone schemes stashed in `shadowStandaloneSchemesRef` (`checkModuleFullImpl:11210`, concrete-head pick); impl query table `shadowKeyTableRef` (`:11217`, includes LOCAL impls per `cfc4fa5a`) | live-impl head ⇒ ordinary app (dispatch); else instantiate the IMPORTED standalone scheme + stamp `RLocal` | standalone scheme = the seedVars entry whose first arrow domain has a **concrete head tycon** (never the poly method scheme) |
| **S4 value-position pin** | check: `maybeStandaloneValueMono` (`typecheck.mdk`); build: `maybeStandaloneValueMonoEmit` via `inferMethodAt` — gated by **`emitValueShadowGate`** | a bare value-position shadow (`map size xs`, not an app head) denotes the STANDALONE: pin its TYPE to the standalone scheme (`Int -> Int`) so a HOF grounds the element concretely, instead of the permissive method scheme (`a -> i -> Int`, a function) whose `Display (List (Int -> Int))` stamps a **NULL element dict → SIGSEGV** (#410/#669 single-typaram; **#724 multi-typaram**) | **[#724] gated PER SHADOW KIND on BOTH paths** — DEFINER arm typaram-agnostic (`isDefinerShadow`, i.e. `contains name definerShadowNamesRef`), IMPORTER arm `singleTyparamIfaceMethod` (Fork 1). Before #724 the check path was already per-kind (definer typaram-agnostic) but the emit path used ONE blanket `singleTyparamIfaceMethod`, so a **multi-typaram definer value position** grounded on check yet DECLINED on emit → the #410 skew at multi-typaram width. ⚠️ the emit classifier is **`isDefinerShadow`, NOT `shadowStandaloneSchemesRef` membership** — that ref is `standaloneSchemeFor`'s scheme-SOURCE selector and an importer occurrence is not reliably in it at this pin, so keying on it mis-grounds the i10 multi-typaram importer app head to a garbage-pointer build. App heads never reach the pin as value positions: a definer app head is bracketed `shadowHeadCtxRef` True by `inferDefinerShadowApp`. Fixtures: `d22`/`d22b` (multi-typaram definer value position), `d22z` (app-head control) |
| S2 no-impl obligation skip | `typecheck.mdk:4670` `recordImplObligation`, skip arm `:4688` | a no-impl shadow receiver is a legitimate standalone fallback, not `No impl of …` | bare name ∈ `definerShadowNamesRef` ∪ `standaloneValuesRef` — skips the obligation for EVERY occurrence of the name, impl-having or not (this un-checks row 13: the domain mismatch is never re-imposed) |
| S2/S3/S5 route stamping | `recordRLocalSite` (gated on `standaloneValuesRef`, suppressed inside `inferDefinerShadowApp`); `resolveRLocalSites` / `resolveRLocalSite`: **`isDefinerShadow` ⇒ `RLocal sym` unconditionally**, else (importer) grounded head + `implExistsForHead` → leave route (dispatch) else `RLocal sym` (`stampRLocalOrFallback`); ungrounded → `RLocal` for definer shadows; build-path RKey via `pendingArgStamps` push → `resolveArgStamps` | **[CHANGED — THE INVERSION]** route by SHADOW KIND first, receiver second. `resolveArgStamps` runs BEFORE `resolveRLocalSites`, so the `RLocal` stamp wins | ⚠️ **`isDefinerShadow` carries the SAME gate as every typing entry point** (`ifaceMethodName` since #54; it was the typaram-count test `singleParamIfaceMethod`, whose mismatch with nothing else was S-3 / row 26). Routing here on a gate the typing entry points do not share routes a site whose TYPE came from the dispatch path — **route and type disagreeing is precisely the P0-20 bug class.** The two gates must stay identical |
| route representation | `compiler/frontend/ast.mdk:69-72` (`RKey`/`RLocal String`); sexp `compiler/ir/core_ir_sexp.mdk:43-44` (`RLocal ""` serializes to the old nullary form) | ONE occurrence needs TWO names: bare `N` for dispatch, `<mid>__N` for the standalone | the mangled standalone symbol is **carried in the route**, stamped at resolve time (Fork-2 carry-in-route) |
| lowering | `compiler/ir/core_ir_lower.mdk:144` `EMethodAt name … → CMethod name …` | route + both names survive to the backends | `name` is the single bare field; the RLocal symbol rides the route |
| emit (LLVM) | `compiler/backend/llvm_emit.mdk:3413` `emitMethod … (RKey tag)` → `implFor e name tag`; `:3435` `… (RLocal sym)` → `emitKnownFnSat e ("mdk_" ++ sym)` | S2's two arms at codegen | RKey needs the **bare** method name; RLocal needs the **mangled** symbol |
| emit (WasmGC) | `compiler/backend/wasm_emit.mdk:3076` `emitMethodRef … (RLocal sym)` (peer arm, header `:3071`) | same split, second backend | same two-name split |
| eval | `compiler/eval/eval.mdk` `evalMethodAt … (RLocal sym dicts)` → standalone via env lookup, **then `applyDicts … dicts`** (S9); other routes → arg-tag/dict dispatch (`methodAtNarrow` treats RLocal as not-a-dispatch; `dictOfRoute (RLocal _ _)` is the no-op dict — RLocal's dicts are the call's leading dict ARGS, not a witness FOR the route) | S2 + S9 on the interpreter | run path is UN-mangled: `sym` is `""` and the bare name resolves to the standalone lexically |
| S9 dicts (typecheck) | `shadowStandaloneDicts` / `shadowStandaloneDictSlotsAt` (slot monos, expanded-supers, from the SIGNATURE's id space) → carried on `pendingRLocalSites` (an `RLocalSite` record) → resolved **inside** `resolveRLocalSites` via `routesOfMonosTop` | the standalone's own `=>` dicts, stamped by the SAME single writer as the route | ⚠️ resolve them **inside the stamp** — `resolveRLocalSites` runs BEFORE `resolveDictApps` in `elabModuleStamp`, so routing them through `pendingDictApps` reads `[]` and reproduces the bug with more code |
| S9 reject direction | `recordStandaloneSigObligations` → `recordCallObligations` → `checkCallObligations` | `size "hi"` ⇒ located `No impl of Num for String` | ⚠️ obligations must come from the **signature**, not `schemeObligationsRef`: for a signatured binding those are **different id spaces** (generalization vs `sigToSchemeTvs`), so the id lookup silently finds nothing |

## 4. The gate (`test/diff_compiler_shadow_semantics.sh`)

**The matrix in §2 is enforced.** One gate owns the whole corpus
(`test/shadow_fixtures/` — single-file `.mdk` units plus the `d8`/`i*`
multi-module directories), and for each it drives all three paths and asserts:

⚠️ **This paragraph carried a hard-coded "17 fixture units — 13 single-file
`.mdk` plus the `d8`/`i1`/`i3`/`i4` multi-module directories" until 2026-08-06.
It was stale by more than a factor of two, and it PROPAGATED** — the figure was
copied forward into issue text and into a task brief, where it was used to size
the blast radius of a spec ruling against this corpus. **Do not write the count
here.** Derive it, and keep the two numbers distinct: `ls test/shadow_fixtures/ |
wc -l` gives the fixture-**unit** count, the gate's own `ok   coverage:` line
prints the same number as it grades it, and the gate's final tally reports
**assertions**, which is units **plus one** (the coverage self-audit). At
2026-08-06 those were **36** and **37** respectively — recorded as a dated
observation, not as a fact this page maintains.

- the **verdict** — `check`, `run`, and `build` each ACCEPT or REJECT exactly as
  the cell specifies; and
- the **value** — for a cell all three accept, `run`'s stdout and the **built
  binary's** stdout must be byte-identical to each other *and* to a pinned
  expectation. This half is not optional: **S7** is a claim about values, and an
  exit-code-only gate cannot see the bug class this arc keeps producing (P0-20:
  `build` exits 0 while printing a wrong number; S-1: `build` exits 0 while
  printing a raw heap pointer). Both would have graded PASS.

Two properties that keep it from rotting:

- **A coverage self-audit.** The gate diffs the fixture directory's actual
  contents against its own table and FAILS if a fixture is ever added without
  being wired in — the orphan-corpus failure this gate was written to end.
- **KNOWN-BAD rows are a ledger, never a skip-list.** An open bug is pinned to
  its *current, wrong* behavior, so it is asserted on every run and goes **red the
  day it is fixed** — which is the signal to correct the row. **This has now worked
  twice.** `d10` (row 25) was added as a KNOWN-BAD row pinning the S-1 miscompile,
  S-1 landed, and the gate went red on the next run. `d11` (row 26) pinned S-3 the
  same way, and went red the moment #54 taught the definer entry points this shape
  (2026-07-17). The only KNOWN-BAD row left is `d18` (a #410 residual: `build`
  ships a binary that SEGFAULTs while `run` is correct).

CI: the `types` shard (`.github/workflows/ci.yml`); `diff_compiler_ci_shard_coverage`
enforces that it is in exactly one shard.

Still **UNTESTED-NO-FIXTURE** (rows 21–23): importer value-position, importer
N-way, and a return-position method shadow. Adding those three fixtures is the
next mechanical step — the gate picks them up automatically once a row is added
to its table (and its coverage audit will fail until one is).

## 5. Residuals — HISTORICAL (all four now CLOSED; kept for the repro + root cause)

> **All four cells in this section are FIXED** (P0-19 batches 1–2, 2026-07-10;
> see the update notes at the end of the section). They are kept because the
> repro and the root cause are the useful part — and because *this section
> saying "fixed" while §2's table still said BUG for the same four rows* is
> precisely the drift the §2 gate now prevents. Read §2's table for current
> status; it is the one that is enforced.

1. **Row 10 — value-position shadow over live-impl elements: three-way split.**
   `d4b`: `map size [Box 1, Box 2]` → check ACCEPTS, run E-PANICs (`unknown op
   '+'` — the standalone on a `Box`), build prints `[1, 2]` (dispatches to the
   impl!). Hypothesis: eval honors S4 (bare value = standalone) while the emit
   path's marked `EMethodAt` value-position occurrence falls into method
   arg-dispatch, and check types the occurrence permissively (obligation
   skipped) — three stages, three different S4 answers.
2. **Row 12 — generalization over the shadow receiver: silent miscompile.**
   `d5b`: `useIt x = size x; useIt (Box 3)` → check ACCEPTS (`useIt : a ->
   Int`), run E-PANICs, build prints a garbage integer (Box pointer + 1).
   Hypothesis: the ungrounded-receiver occurrence is typed against the
   polymorphic METHOD scheme, so the wrapper generalizes instead of
   monomorphising to the standalone's domain (S5), and the RLocal route then
   runs the standalone on any argument.
3. **Row 13 — no-impl + domain mismatch: check over-accepts, build garbage.**
   `d9`: `size "hi"` → check ACCEPTS, run E-PANICs, build prints garbage.
   Hypothesis: `recordImplObligation:4688` skips the impl obligation for every
   occurrence of a shadow name, and nothing re-imposes the standalone's domain
   on the check path — the S2 "must then type against the standalone" half is
   unenforced.
4. **Row 14 — definer shadow with imported interface+impl: no dispatch.**
   `d8`: local `size : Int -> Int`, `import prov.{Sizeable, Box(..)}`,
   `size (Box 3)` → all three paths reject `Type mismatch: Int vs Box`
   (consistent, loud — but S6 says dispatch to 3). Hypothesis: on the
   multi-module run/check path the occurrence is typed directly against the
   local standalone before any per-receiver machinery fires — the
   definer-shadow app path or its `shadowKeyTableRef` impl query doesn't span
   the imported impl universe for a LOCAL standalone.

Rows 12 and 13 are **silent build soundness holes** (check accepts, binary
prints garbage) — the same severity class as the original P0-18 build hole, and
strong candidates for the next fix batch, with rows 10/14 folded in as the
same "which stage owns S4/S6" decision.

> **✅ UPDATE (2026-07-10, `ef0874f3` — P0-19 batch 1):** rows **12 (d5b)** and **13
> (d9)** are FIXED — both now `check`/`run`/`build` REJECT with a located
> `Type mismatch` (`enforceStandaloneDomain` re-imposes the standalone's declared
> domain whenever a definer-shadow occurrence resolves to the standalone, on both
> the marked run/build path and a new un-marked `EVar` check path; gated by
> `shadowKeyTableRef` so live-impl receivers still dispatch). Regression fixtures
> `test/run_check_agreement_fixtures/p0_19_{poly_wrapper_shadow,noimpl_domain_mismatch}`
> (`.expected=REJECT`); agreement gate 22/0, fixpoint C3a/C3b YES. Bonus: row 11's
> over-general wrapper scheme (`useIt : a -> Int`) is fixed to `Int -> Int`.
>
> **✅ UPDATE 2026-07-10 (P0-19 batch 2, `ebb8ee90`, main `ebb8ee90`) — the last two
> cells CLOSED; all 4 BUG cells now conformant.** Row **10 (d4b)** value-position
> now REJECTs `Int vs Box` (d4 over-Int still accepts `[2,3,4]`): a new
> `shadowHeadCtxRef` flag distinguishes "shadow `EVar` as app head" (keeps the
> method scheme for dispatch) from "bare value position" (pinned to the standalone
> scheme via `maybeStandaloneValueMono`). Row **14 (d8)** now DISPATCHES cross-module
> (run+build print `3`,`4`, matching d2): `shadowKeyTableRef` seeded from the global
> `accData ++ implDecls ++ prog` (was missing the imported impl on the check path),
> and both definer-shadow app paths decide per-receiver — a receiver with a live
> impl fetches the method scheme from `methodIfaceParamsRef`, else the standalone
> scheme. (This paragraph predates the **2026-07-14 S2 inversion**, not the
> 2026-08-06 scope ruling — it is row 14's own per-receiver dispatch, later
> reverted by the inversion (row 14's current entry a few paragraphs above says
> so). The inversion is what superseded it: a definer shadow's applied
> occurrence no longer consults the impl universe AT ALL, scoped or otherwise —
> S1-SCOPE narrows a *name* set and explicitly leaves S2's impl-universe lookup
> untouched (`DICT-SEMANTICS.md` §8 I5's cross-reference says the same from the
> other side), so it is not the pointer this paragraph's mechanism needs.
> "Live impl" is §0 Terminology's term, not a fourth undefined adjective.)
> Fixtures
> `p0_19_value_pos_{shadow=REJECT,ok=ACCEPT}` + a d8 leg in
> `diff_compiler_check_cli_modules` (14/0); agreement 24/0, fixpoint C3a/C3b YES.

> **🐛 NEW CELL + ✅ FIX (2026-07-13, P0-20) — row 25: a LITERAL receiver.  The worst
> cell in the arc: `check` accepted, `run` panicked, and `build` SILENTLY PRINTED A WRONG
> NUMBER.** The matrix above varies the *shape* of the receiver (grounded / ungrounded /
> dict-bound) but never its *provenance*, and that is where the hole was:
>
> ```
> eq : Int -> Int -> Int      -- a definer shadow of the PRELUDE's `Eq` method
> eq a b = a + b
> main = println (eq 1 2)     -- check: Int · run: E-PANIC · build: prints 0
> ```
>
> A **numeric literal is `Num a => a`, i.e. UNGROUNDED at inference time**, so typecheck
> took the S5 (ungrounded ⇒ standalone) arm and typed the site against `eq : Int -> Int ->
> Int`. But typing it against the standalone *unifies `Int` into the receiver* — so by the
> time the POST-inference route resolver (`resolveRLocalSite`) ran, the receiver WAS
> grounded, to `Int`, which has `impl Eq Int`, and it left the site to **dispatch**. The
> TYPE came from one arm and the ROUTE from the other. `eq 1 2` evaluated to a `Bool` that
> `println` rendered with `Display Int`: `run` panicked (`intToString: not an Int`), and
> the native binary printed **`0`** with exit 0. (With a user interface whose method
> returns a `String` the binary printed a raw heap **pointer**; with `abs` it SEGFAULTED.)
> Only literal receivers were affected — `f k = eq k 1` (k : Int, grounded on arrival)
> dispatched consistently on all three paths, which is why the arc missed it.
>
> Per **S2 the answer is DISPATCH** (the receiver grounds to `Int`; `Eq Int` has an impl),
> so `eq 1 2` is now `False` on check == run == build, and the user's own `eq` is reachable
> only at a type with no `Eq` impl — exactly as `d2` already specified for `Box`.
>
> Fix (`compiler/types/typecheck.mdk`): `groundShadowReceiver` performs S5's
> monomorphisation to the standalone's declared domain **BEFORE** the dispatch decision, so
> typecheck asks the S2 impl question about the SAME head the route resolver will see; and
> `pendingRLocalSites` gained a `forceLocal` flag so **the route FOLLOWS THE ARM** typecheck
> actually took instead of being independently re-derived post-inference. The domain lookup
> is sym-aware (`shadowDomainFor`) — on the mangled emit path the standalone is
> `<mid>__eq`, so a bare-name sig lookup is silently inert there, which flips *build* to the
> standalone while check/run dispatch (the same bug, mirrored).
>
> Fixtures: `test/run_check_agreement_fixtures/p0_20_shadow_literal_{receiver,user_iface,
> result_pinned,noimpl_standalone}` — and that gate now also compares the **VALUE** (`run`
> stdout == the built binary's stdout, plus an optional `.out` pin). It graded exit codes
> only, so a build that exits 0 while printing a wrong number was invisible to it: **the
> gate that owns this bug class could not see this bug.** Agreement 42/0, run_gates 83/0/0,
> fixpoint C3a/C3b YES.
>
> **Residuals found while closing this (both pre-existing on `main`, both filed):**
> 1. ~~**A definer shadow whose standalone is CONSTRAINED (`size : Num a => a -> a`) is
>    miscompiled**~~ — **FIXED 2026-07-13 (S-1; see clause S9).** `check` accepted, `run`
>    panicked, and `build` **exited 0 printing a raw heap pointer**, even with no impl at
>    the receiver head. The filing's mechanism was *close but wrong in the way that changes
>    the fix*: the `RLocal` route did not **drop** a dict — **no dict was ever computed for
>    the occurrence**, because the marking prePass's shadow arm is tested before its dict
>    arm, so the call was never marked an `EDictAt` while the *definition* still got its
>    dict param. `RLocal` now carries the standalone's own dicts (S9).
> 2. ~~**A multi-TYPARAM interface (`interface Ix a i`) bypasses the whole definer-shadow
>    machinery**~~ — **FIXED 2026-07-17 (#54; S-3, row 26; see clause S8).** Every definer
>    entry point was gated on `singleParamIfaceMethod`, which counts interface TYPE PARAMS,
>    not method params — **the name states the opposite of what the body does, and that
>    alone sent one agent down a wrong hypothesis.** `check` and `build` kept the OLD
>    per-receiver answer (`4,3`); `run`, which has no route stamp to follow and resolves
>    the bare name lexically to the standalone, E-PANICked `unknown op '*'` on a `Box`.
>    The fix splits the predicate **by shadow kind rather than by arity**: `ifaceMethodName`
>    gates the definer arms (the inversion never queries the impl universe, so typaram
>    arity is irrelevant to them), and the renamed `singleTyparamIfaceMethod` keeps gating
>    the Fork-1 importer arms, whose per-receiver rule *does* key on the receiver standing
>    at the interface's one typaram. S8 now covers both multi-*param methods* and
>    multi-*typaram interfaces*.

> **🐛 NEW CELL + ✅ FIX (2026-07-14, P0-21) — row 27: S1 ("shadow-hood is per-module")
> was NOT enforced on the single-file/flat path — a user's shadow LEAKED INTO THE
> PRELUDE.** Every cell in the matrix above varies the shadow's *use*; none of them asks
> **whose module the occurrence is in**. That is where the hole was:
>
> ```
> map : Int -> Int      -- defined, and NEVER USED
> map n = n + 1
> main = println "hello"
> ```
>
> **14 errors**, every one of them raised inside the PRELUDE's own bodies
> (`map2`/`map3`/`replaceWith`/`discard` in `stdlib/core.mdk` all call `map`), all reported
> against the user's file at a fabricated `1:0` — including `'map' takes 1 argument(s) but
> is applied to 2` for a call the user never wrote. This is also the source of the
> separately-filed fabricated-`1:0` diagnostics.
>
> Root cause: `checkProgramSeeded` was handed ONE flat program, `core ++ user`, computed
> `buildDefinerShadows prog prog`, and then applied that single name set to **every
> occurrence in the flattened program, core's included**. The multi-module path never had
> this — `checkModuleFullImpl` seeds the shadow set per module and checks `core` in
> isolation, which is why `helper.mdk`'s `map : Int -> Int` and `other.mdk`'s
> `map (x => x*2) [1,2,3]` have always both worked.
>
> Today the leak was "only" a TYPING leak — a leaked prelude occurrence with a live-impl
> receiver still dispatched, so `println 42` and `elem 9 [1,2,3]` were merely accompanied
> by spurious errors, not miscompiled. **That stops being true the moment S2 is inverted so
> a standalone WINS over a same-named method**: the same leaked occurrence would then ROUTE
> the prelude's `println` into the user's `display`. So this is Stage 0 of the inversion
> arc (`compiler/SHADOW-INVERSION-DESIGN.md`) and had to land first.
>
> Fix (`compiler/types/typecheck.mdk`): the flat path now knows **where the prelude ends**.
> Every driver that flattens the prelude into what it checks (`desugar coreP ++ desugared`)
> passes the two halves separately — `checkProgramSeededSplit seed coreProg userProg`
> (`checkToLinesWithRuntime` / `checkErrorsWithRuntime` / `checkProgramDiags` /
> `checkProgramSchemes{,WithRuntime}` each gained the parameter). With the boundary known,
> `definerShadowNamesRef` is scoped exactly as `checkModuleFullImpl` scopes it: it is the
> USER module's shadow set (`buildDefinerShadows prog userProg`) and is toggled **empty
> while a CORE-owned letrec group, or core's impl/default/prop/test bodies, is inferred**
> (`flatShadowScopingRef` / `flatCoreFnNamesRef` / `flatUserShadowNamesRef`,
> `scopeShadowsForGroup`). Every consumer of that ref — `definerShadowVarHead`,
> `definerShadowArgHead`, `maybeStandaloneValueMono`, `recordImplObligation`'s skip arm,
> `resolveRLocalSite` — becomes per-module for free. All three refs are cleared by
> `resetState` and set ONLY by a `checkProgramSeededSplit` with a non-empty prelude, so the
> multi-module path and every prelude-free probe path are byte-identical.
>
> The `=>`-constrained-receiver carve-out (`definerReceiverIsDictVar`) is UNCHANGED and
> still load-bearing — it is what keeps a *user's* constrained fn dispatching through its
> dict in a shadowing module (`accept_constrained_receiver_shadow`). It is no longer what
> saves the prelude's own `neq x y = not (eq x y)`; the prelude is now simply not in the
> shadow's scope.
>
> Fixtures: `test/run_check_agreement_fixtures/p0_21_prelude_shadow_scope` (ACCEPT — the
> repro, plus a *used* `map 3` → 4 alongside prelude `map2`/`discard`/`elem`/`length`) and
> `p0_21_prelude_shadow_scope_reject` (REJECT — `map "hi"`, proving the machinery is still
> live inside the user's own module and P0-19's row-13 hole stays closed). Agreement 46/0,
> run_gates 83/0/0, fixpoint C3a/C3b YES, `make test` green.
>
> **Residual (unchanged, pre-existing):** inside a module that DOES shadow, a
> multi-*param* method (`map : (a -> b) -> f a -> f b`) still peels only its FIRST argument
> as the receiver, so `map (x => x*2) [1,2,3]` in a file that also defines `map : Int ->
> Int` is rejected `Int vs a -> a`. This is the S8 residual, not S1: the already-correct
> multi-module path rejects the identical shape identically, so the two paths now AGREE.
---

## 6. S-1 residuals (open; grep `S1-RESIDUAL`)

Found while closing S-1 (2026-07-13). **Neither is a regression and neither is a silent
wrong answer** — both were already broken on `main`, and both now fail *loudly*. They are
the two shadow occurrences that do **not** flow through an application-head arm.

### S1-RESIDUAL-A — value-position shadow miscompiles at emit (NOT an S-1 bug) — ✅ **CONFIRMED REAL; emitter half FIXED 2026-07-16 (issue #410)**

`map size [1,2,3]` (a bare shadow occurrence passed to a HOF) miscompiles when the
**interface method's arity DIFFERS from the standalone's**. `run` is correct throughout.

⚠️ **This is NOT caused by the constraint, and NOT by S-1.** Verified: an **unconstrained**
shadow (`size : Int -> Int`) in value position fails *identically*, and that takes the
`dicts == []` path — byte-identical to pre-S1 codegen. So does a shape with **zero impls**
of the interface (`d19`): shadow-hood + arity mismatch + value position suffice. S-1's
design doc mis-attributed this row's `build` failure (it saw a GC OOM) to the missing dict.

> **THE 2026-07-14 "DOES NOT REPRODUCE" NOTE WAS WRONG — AND ITS OWN SUSPICION WAS THE
> ANSWER.** It observed that the stated mechanism "requires the method and standalone
> arities to **differ**, and in both shapes above they are both 1" — then filed the entry
> unreproducible anyway. It was right: **every fixture it tested (`d4`, `d4b`, `d10`) is
> arity-EQUAL**, and when the arities coincide the arity lie is invisible. The corpus could
> not express the bug, so the gate could not defend it — this spec's own lesson, paid twice.
> **A "does not reproduce" that names its own missing ingredient has disproved nothing — it
> has written the next repro.**

**Two bugs stack here. They must not be conflated:**

**(A) the arity lie — emitter — ✅ FIXED 2026-07-16.** The value-position lift built a
closure of `methodArityOf name` — the **interface method's** arity — for a body calling the
**standalone**. With the arities differing, a HOF applying the standalone's arity got a
**partial application** back instead of a value: `map size [1,2,3]` produced a list of PAP
heap pointers and `build` **printed them as Ints at exit 0 with no error**
(`[70290166652896, …]`) — an S0 *silent wrongness*, worse than the segfault this entry
originally described. Fixed by making the arity **route-derived**: `methValArity`
(`llvm_emit.mdk`) and `methodValArity` (`wasm_emit.mdk`) resolve an `RLocal` route's target
via `fnArity`/`progFnArity` **minus the route's dict count** (both are dict-INCLUSIVE — see
the `trmcTryFn` note in `llvm_emit.mdk`), and keep the old name-derived arity for every
non-RLocal route, so the self-compile fixpoint cannot move (C3a/C3b YES). Pinned by
`d17`/`d19`/`d20` (**both** arity directions: method>standalone and method<standalone).
Wasm carried the same lie via an arity helper taking **no Route**; pre-fix its
symptom was a hard assembly failure (`unknown func: failed to find name $mdk_w_…__size`),
**not** the `illegal cast` this entry guessed. Both backends fixed together.

**(B) the NULL element dict — NOT the emitter — ❌ STILL OPEN.** With (A) fixed, the
*unannotated* `println (map size [1,2,3])` still **segfaults** the built binary: `println`'s
`Display (List Int)` requirement is emitted with a **NULL element dict**
(`@mdk_dc_N = [2 x i64] [<List-display tag>, i64 0]`; the `0` is an **RNone** route), so
`display` dereferences NULL. The element **type** resolves correctly to `Int` (annotating
`List String` reports `Type mismatch: Int vs String` at the list literal), so this is not a
typing failure — it is the requirement **route** stamped without being resolved against the
inferred type. Annotating `let ys : List Int = map size [1,2,3]` makes the route resolve and
the program correct, which is what isolates (B) from (A). Routes are stamped in
`compiler/types/typecheck.mdk`, so **(B) is not an emitter fix**; it is plausibly the same
root as the `#412` structured-requires pre-bake. Ledgered by `d18` (`BUILD_CRASH` —
self-draining: it goes RED the day (B) is fixed).

*Fix location (A, done):* `compiler/backend/llvm_emit.mdk` `methValArity`;
`compiler/backend/wasm_emit.mdk` `methodValArity`.
*Fix location (B, open):* `compiler/types/typecheck.mdk` — requirement-route resolution.

> ⚠️ **UPDATE 2026-07-16 (#411): the DEFINER shape above still does not reproduce — but
> its IMPORTER twin DID, and is now fixed.** `map size [1,2,3]` where `size` is
> **imported** rather than defined locally failed at `build` for real: not a SIGSEGV but
> `E-PANIC: no impl of method 'size' for type 'Int' (slice 6)`, exit 1, no binary.
> **The mechanism was NOT the one this entry names** — nothing to do with
> `emitMethodValue`'s arity, and no line of `llvm_emit.mdk` was touched to fix it. The
> bug was entirely in `typecheck.mdk`: `standaloneShadowsFromSet` (the importer
> shadow-set builder) lacked the `mangledShadowMapRef` recovery arm its definer peer
> `definerShadowsFromSet` has carried since P0-18, so on the EMIT path — where every
> funDef is mangled (`prov__size`) — the importer shadow set came back **empty**.
> `recordRLocalSite` therefore never recorded a site, and `resolveArgStamp`'s `RKey Int`
> **clobbered the mark pass's correct `RLocal prov__size` seed**, landing in
> `emitDefaultRKey`'s no-impl arm. That asymmetry is precisely why the definer shape
> never reproduced while the importer one always did — this entry's "value-position
> lift" theory was looking at the wrong half of the pipeline. Rows 21a/21b pin both.

### S1-RESIDUAL-B — importer shadow on an UNGROUNDED receiver — ✅ **CLOSED 2026-07-14**

**The filed diagnosis was right, and its own suggested fix was the fix.** But the residual
**understated the blast radius**, and that is the part worth remembering.

*As filed:* `import prov.{size}` where `prov.size : Num a => a -> a` shadows a local
interface method, called as `size 3` — "`build` and `wasm` are correct (4); `run` still
under-applies." Read that way it sounds like a **constrained**-standalone dict-threading
nit on one engine.

*What it actually was:* the root breaks an **unconstrained** standalone at **`check`**, on
**all three paths**, whenever the shadowed method is **higher-kinded** — which every
`Foldable`/`Mappable`/`Traversable` method is:

```medaka
-- prov.mdk:  export isEmpty : Int -> Bool   (isEmpty n = n == 0)
import prov.{isEmpty}
main = println (debug (isEmpty 0))    -- Type mismatch: Int literal vs Int Int
```

The **`Int Int`** is the tell. A numeric literal is `Num a => a`, i.e. **ungrounded** at
inference time, so `inferShadowApp`'s `headTyconMono tx` said `None`, it never reached its
*standalone* arm, and it fell to the ordinary-app arm — which types against the **method**
scheme the env rebound the name to. The prelude's `Foldable.isEmpty : t a -> Bool` is
higher-kinded, so unifying `t a` against the literal's tyvar solved `t := Int, a := Int`.
The user's imported `isEmpty : Int -> Bool` was **never consulted**.

**Cause (as filed):** `inferShadowApp` lacked the `groundShadowReceiver` call that P0-20 gave
its definer peer `inferDefinerShadowApp`. **Fix (as filed):** add it — ground the ungrounded
receiver to the *imported* standalone's declared domain (`importerShadowDomain`) **before**
asking the S2 impl question, so typecheck and the post-inference route resolver ask it about
the **same head**.

> ⚠️ **This is the P0-20 shape again, one arm over: ONE DECISION, DERIVED TWICE, AT TWO
> DIFFERENT TIMES, OVER A RECEIVER THAT CHANGED IN BETWEEN.** It is the recurring root cause
> of this entire arc. When you touch shadow routing, the question to ask is never "is the
> receiver the right *type*" but "**is the receiver GROUNDED YET, and will it still be the
> same thing when the route is stamped?**"

**Why no gate caught it, and the lesson.** Every importer fixture — `i1`, `i3`, `i4` — used a
**grounded** receiver (a `Box`, a `Tok`, a `List`). **Not one used a bare numeric literal**,
so the corpus was *structurally blind* to the cell and the gate graded **18/0 over a real
break**. Rows 27–28 (`d12`, `i5`) close it, and `i5` carries the Fork-1 control in the same
fixture. **A gate that cannot express a cell cannot defend it: vary the receiver's
PROVENANCE — literal / grounded / dict-bound — not just its type.**

*Fixed in:* `compiler/types/typecheck.mdk` `inferShadowApp` + `importerShadowDomain`.
Fork 1 is untouched: grounding only decides **which head** the per-receiver rule is applied
to; a grounded head with a live impl still dispatches (`isEmpty [1, 2]` → `Foldable.isEmpty`).
