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
> - **Follow-on ruling, 2026-08-07
>   ([#1380](https://github.com/MedakaLang/medaka/issues/1380)): the
>   RE-EXPORT-CHAIN arm of that operand is IN SCOPE.** An interface reaching `M`
>   through a re-export chain is nameable in `M` — **conditional on the ordinary
>   import/export rules saying the declaration is exported along that path**,
>   which S1 consumes and does not define; failing closed on such a chain is
>   non-conformant. ⚠️ Unlike the branch above, this one is an acceptance
>   **WIDENING** on the importer arm, not a narrowing, and it has a **silent**
>   member (same accept both ways, different value at exit 0) as well as a loud
>   one — the rule, the full licensing set, its cost, and the sub-predicate that
>   stays deferred are all in the **S1-CHAIN** note under S1.
> - **Follow-on ruling, 2026-08-09
>   ([#1351](https://github.com/MedakaLang/medaka/issues/1351)): S2's importer arm
>   is evaluated PER DECLARATION.** When more than one interface declares a method
>   named `N`, S2's *"any impl of **the shadowed interface** for **the receiver's**
>   head tycon"* has no referent for either definite article — shadow-hood is
>   decided over **names**, and which argument is the receiver is a property of an
>   interface's **declaration**. **S2-DECL** (under S2) repairs both: only
>   declarations S1-NS (a) admits may decide, the receiver argument and the impl
>   query must come from the **same** declaration, disagreement between two admitted
>   declarations is a located reject, and no answer may move with import-clause
>   order. ⚠️ Unlike the two rulings above, **neither execution arm implements this
>   today, and they are non-conformant for DIFFERENT reasons** — `check`/`run` reads
>   a bare-name dispatch-index table, `build` reads none and assumes the receiver is
>   argument 0. The measurement is in S2-DECL's Conformance paragraph; it is also
>   why a candidate fix graded on `run` alone is a new **S7** violation.
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
> 🚨 **When the ruling landed the implementation did NOT conform and §2's matrix
> could not tell you so** — no fixture then exercised the axis. **Both halves have
> since moved, in opposite directions, and neither generalises to the other
> clauses above:**
> - **S1-SCOPE and S1-NS are now implemented and GRADED** — [#1353](https://github.com/MedakaLang/medaka/issues/1353)
>   is closed, the shadow-hood answer is intersected with the module's nameable
>   set (§3's S1-detect rows), and §2 **rows 33–45** are the discriminating cells.
>   Those rows are the corpus-gap item #1375 recorded as owed; before them the
>   corpus graded byte-identically under either reading.
> - **S2-DECL is NOT implemented on EITHER execution arm**, and they are
>   non-conformant for different reasons ([#1351](https://github.com/MedakaLang/medaka/issues/1351),
>   OPEN) — see S2-DECL's own Conformance paragraph.
> - **Row 39 ([#1430](https://github.com/MedakaLang/medaka/issues/1430), OPEN
>   S0)** is a live three-verb divergence on S2's definer inversion at
>   *return position*, with the interface unambiguously nameable — so it is
>   downstream of every ruling here rather than covered by one.
>
> Per this document's own scope rule, *the spec is the target, not a description
> of present behavior.* **The 2026-08-06 spec change itself landed no compiler
> behaviour change**; the conformance above arrived separately and later.

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
| **nameable in `M`** | the declaration is one `M` may refer to by name: declared in `M`, **or** exported by a module `M` imports **AND ADMITTED BY THAT IMPORT PATH** (directly, or through a re-export chain — **RULED IN SCOPE 2026-08-07, [#1380](https://github.com/MedakaLang/medaka/issues/1380); see S1-CHAIN under S1**, which also says what is still deferred: the sub-predicate deciding when a declaration counts as *exported through* a chain), **or** declared in the implicit prelude. ⚠️ **The "and admitted by that import path" clause was ADDED 2026-08-08 by S1-NS**: this row previously said only *"exported by a module `M` imports"*, which is module-level and, read literally, is satisfied by `import smod.{sf}` — an import that names one unrelated function. That reading is exactly the too-loose one this document's own headline forbids, and it shipped as a bug. **What "admitted" means is S1-NS (a), which is the per-METHOD union of the two namespaces — see S1-NS under S1.** | S1's **interface** operand |
| **defined in `M` or imported into `M`** | the two cases that assign a shadow its **kind** (definer / importer) — so this is also, exactly, S1's **standalone** operand. ⚠️ **The implicit prelude is NEITHER, and is therefore EXCLUDED from this row — RULED 2026-08-10, S1-PRELUDE under S1** ([#1375](https://github.com/MedakaLang/medaka/issues/1375) item 2). A standalone that reaches `M` only as an implicit prelude export contributes nothing here and creates no shadow in `M`. **The asymmetry with the interface row above — which names the prelude as INCLUDED — is deliberate, not an oversight**, and S1-PRELUDE carries the argument: the interface operand is the wider *nameable in `M`*, while this operand is pinned by the kind partition, because S2 is stated **per kind** and a standalone with no kind would leave an occurrence classified by S1 and undenoted by S2 | S1's **standalone** operand + the kind partition |
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

  **The reach of this ruling for each of the two issues #1375 bundled, stated
  as a verdict rather than left to be inferred — this is #1375's scope item 3.**

  | Issue | Axis | Verdict of the S1 clause set |
  |---|---|---|
  | [#1353](https://github.com/MedakaLang/medaka/issues/1353) | reachability — no import path reaches the interface's module | **DRAINED.** The clause decides it, §2 rows 33–35 grade it, and the issue is CLOSED with its must-fail pin drained and deleted |
  | [#1302](https://github.com/MedakaLang/medaka/issues/1302) | export visibility — a path reaches the module, the declaration is not exported through it | **CONSTRAINED, NOT DRAINED.** The clause fixes what the answer *would* be for an S1-shaped program on that axis — a declaration `M` cannot name contributes no method name to `M`'s shadow surface, whatever the reason it cannot name it, which S1 states as one uniform condition. It does **not** reach #1302's filed program, which never poses an S1 question |

  🚩 **This is a correction to #1375's own framing, recorded rather than
  harmonised.** That issue adopted the ruling as covering *"#1353 and #1302 as
  ONE ruling … two axes of the same operand"*, and its reasoning — that a repair
  on one axis alone would leave the other open for a third issue to be filed
  against the same clause — is sound **about the clause**. It is wrong about
  **#1302**, whose repro exercises a different clause entirely. The bundling
  therefore bought the axis, not the issue: **#1302 must not be drained on the
  strength of this ruling, and its severity is not re-graded by it.** What is
  owed there is unchanged — a measurement of that issue's own mechanism, which
  has never been taken under any predicate.

  > ### 🔒 S1-SCOPE — why the operands are nameable-in-`M` and not graph-global
  >
  > **The argument, so it can be disagreed with rather than merely obeyed.** S1
  > is a **name-resolution** rule: given a bare name the author wrote, it decides
  > which of two candidate denotations that name has. For the rule to be
  > *choosing*, both candidates must be things the author could have meant — and a
  > method of an interface `M` can neither **name** nor **call** is one `M` cannot
  > reach at all. Letting it decide what `M`'s own written names denote is not a tie-break
  > between candidates; it is one candidate being supplied from outside the
  > program the author can see. That is also the reading under which S1's
  > **left** operand and its **right** operand carry the same scope: the left one
  > is *already* pinned by this clause's own kind partition (a standalone neither
  > defined in `M` nor imported into `M` has no shadow kind, so S2 — stated per
  > kind — would assign its occurrences no denotation at all).
  >
  > 🚨 **CORRECTION (2026-08-08, S1-NS). The sentence above USED TO READ** *"a method
  > of an interface `M` cannot name is one `M` cannot call, cannot import, cannot
  > request by writing a `=>` constraint (S5), and cannot write an `impl` for."*
  > **That four-way conjunction is FALSE, and its falsity is why this clause could be
  > quoted in good faith to reach opposite answers.** Measured: the four split **2–2**
  > along the namespace line. With `import ifc.{size}` — the interface NOT nameable —
  > calling `size 5` is **ACCEPTED with no diagnostic**, while `impl Sizeable Blob` and
  > `twice : Sizeable a => a -> Int` are both rejected `Unknown interface: Sizeable`.
  > With `import ifc as I`, `I.size 5` is likewise **ACCEPTED** while `impl Sizeable Int`
  > is rejected. So *call* and *import* track the **VALUE** namespace; *`impl`* and
  > *`=>`* track the **TYPE** namespace. The repaired sentence claims only what holds:
  > a method the module can neither name nor call is unreachable. **The consequence —
  > that S1's operand must be the UNION of the two namespaces rather than either one —
  > is S1-NS below.**
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
  > instance environment. Measured (2026-08-06, `1443870c`): §2's corpus **as it
  > then stood** was byte-identical under either scope for S1 — including **every** S2-importer
  > *dispatch* cell and `i5`'s explicit Fork-1 control. ⚠️ **Read that as a
  > corpus GAP, not as a proof of innocuousness** — it was identical *because* no
  > unit then put the interface outside `M`'s nameable set.
  > ✅ **That gap is CLOSED: §2 rows 33–45 are the discriminating cells**, landed
  > 2026-08-08 and enumerated in the corpus note under the matrix — the item
  > #1375 recorded as owed. 🚨 **Do not cite the byte-identical result as current
  > evidence of anything.** It is a statement about a corpus that no longer
  > exists, and the whole content of rows 33–45 is that a corpus which cannot
  > express a cell says nothing about it in either direction.
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
  > ### 🔒 S1-NS — RULED 2026-08-08: S1's interface operand is the PER-METHOD UNION of the two namespaces, and marking is CLOSED under shadow-hood
  >
  > **(a) The operand.** A bare method name `n` is in S1's **right** operand in module
  > `M` iff at least one interface `I` declaring a method named `n` satisfies any of:
  >
  > - **(i) TYPE arm** — `I`'s own name is admitted into `M`: `I` is declared in `M`,
  >   declared in the implicit prelude, or `M`'s import path admits the name `I` (a
  >   member list naming `I`, or a wildcard), **at any re-export depth**.
  > - **(ii) VALUE arm** — the name `n` is admitted into `M` as a callable method of
  >   `I`: a member list naming `n`, a wildcard, or a **module alias**
  >   (`import ifc as A`, since `A.n` is a legal call), **at any re-export depth**.
  > - **(iii)** `I` is declared in `M` or in the implicit prelude.
  >
  > **Per METHOD, not per interface row.** A member list naming the *interface* admits
  > every method of it (an author who can write `impl I T` can write all of them). A
  > member list naming *some* methods admits **only those methods**. This is measured,
  > not stylistic: `import ifc.{tag}` leaves a sibling `size` **Unbound**, so admitting
  > a whole row because one member is named makes a **different** name dispatch-eligible
  > on evidence that says nothing about it.
  >
  > **Both arms apply symmetrically on the RE-EXPORT side.** `export import ifc.{size}`
  > must admit `size` one hop down exactly as `export import ifc.{Sizeable}` admits the
  > row. An implementation whose re-export arm matches only interface names is
  > **non-conformant**.
  >
  > **(b) THE CLOSURE INVARIANT.**
  >
  > > **An occurrence of a bare name that a conforming implementation resolves by
  > > interface DISPATCH must be one S1 classifies.** The predicate deciding
  > > **shadow-hood** MUST be a **superset** of the predicate deciding **dispatch
  > > eligibility**. Two different predicates at the two sites is **non-conformant,
  > > whichever way they differ.**
  >
  > In the gap `dispatch-set ∖ shadow-set` an occurrence is routed to an `impl` while
  > S1 has declined to classify it, so S2's definer inversion never fires and a module's
  > own top-level binding is replaced by a foreign impl body with no diagnostic on any
  > verb. Worse, the occurrence is *typed* against the standalone and *routed* to the
  > method: measured, that yields `check` exit 0 then `run`/`build` E-PANIC. That is a
  > type hole, not a scoping disagreement. (b) is namespace-independent.
  >
  > **Why the union, and not either namespace alone.** Each arm is load-bearing and each
  > was measured. Drop the VALUE arm and `import ifc.{size}` — the spelling the compiler
  > *demands* for a call — stops being dispatch-eligible: `check` 0, `run` correct,
  > **`build` E-PANIC: arg-tag dispatch on impl type that owns no constructors**. Drop
  > the TYPE arm and `export import ifc.{Sizeable}` stops making a shadow — precisely
  > what S1-CHAIN enumerates as non-conformant. Neither namespace alone can serve S1,
  > and (b) forbids serving each at a different site.
  >
  > **Newly NON-CONFORMANT.** (1) Deciding shadow-hood with one predicate and dispatch
  > eligibility with a wider one. (2) A predicate satisfied only by the **type** name,
  > so `import ifc.{size}` does not admit it. (3) A predicate satisfied only by a
  > **method** name, so `import ifc.{Sizeable}` does not admit the row. (4) An
  > implementation whose **re-export** arm and **import** arm evaluate different
  > namespaces. (5) Admitting a whole interface row because a member list names **one of
  > its methods**.
  >
  > **Newly ACCEPTED / a DIFFERENT VALUE.** 🚨 **Read the BASELINE before the count — this
  > paragraph used two different ones in four lines.** Every figure below is against the
  > **merge base of the PR that landed S1-NS** (`main` at `61aa6399`; `compiler/types/
  > typecheck.mdk` is byte-identical there and at `b5f8c489`, the base that PR was cut
  > from). That is the only referent still reconstructable once the PR is merged, so an
  > intra-PR baseline — "before this round's filter", "the state that shipped per-row
  > admission" — must never be spelled *pre-ruling compiler*, which is what an earlier
  > revision did on one side of this paragraph and not the other.
  >
  > **Of the shapes S1-NS itself governs, exactly ONE changes value against that base:** an
  > **importer** shadow whose interface is reachable only by naming a *sibling* method loses
  > shadow-hood, so a receiver inside the standalone's domain answers with the imported
  > standalone rather than the impl (777 → 42). That is S1-SCOPE's acceptance narrowing
  > reaching its **silent** half, and it is the cost this clause charges itself. Corpus:
  > `test/shadow_fixtures/i19_importer_sibling_method_silent/`.
  >
  > ⚠️ **Measured, and stated because an earlier draft of this paragraph over-claimed.**
  > The definer twin (`d23_definer_sibling_method_silent/`) and the method-name re-export
  > chain (`i20_importer_method_reexport_chain/`) are **42/42 and 50/50** against that same
  > base and after: they pin shapes the ruling makes *unrepresentable*, not values it
  > changes. Citing all three as "newly different" reads as three behaviour changes where
  > there is one.
  >
  > ⚠️ **"ONE shape" is scoped to S1-NS, NOT to the PR that carried it.** S1-SCOPE (#1375)
  > landed in the same PR and moves considerably more against the same base — `i12` (7 → 99),
  > `i13` (ACCEPT 300 → located REJECT), `i15` (7 → 99), `i17/main.mdk` (7 → 99),
  > `i17/order-swapped.mdk` (REJECT → ACCEPT 99), plus `i19` above. This list is a floor and
  > a pointer, not a census: re-derive it by building the base and re-running
  > `test/diff_compiler_shadow_semantics.sh` rather than by trusting a count written here.
  >
  > **Explicitly NOT changed:** S2's graph-global impl universe (`DICT-SEMANTICS.md` §8
  > I5). S1-NS constrains a set of NAMES; it cannot narrow an instance environment.
  >
  > **⟲ Overturn condition.** (a) is overturned by a program written entirely against
  > names its own module can either *write* or *call*, correct under the language's
  > other rules, whose intended meaning requires a **strictly narrower** operand than
  > the union. (b) is overturned only by exhibiting a dispatch-eligible occurrence that
  > S1 declines to classify **and** for which some other clause supplies a denotation —
  > today no clause does, which is why the gap is silent.
  >
  > ### 🔒 S1-CHAIN — RULED 2026-08-07 ([#1380](https://github.com/MedakaLang/medaka/issues/1380)): a RE-EXPORT CHAIN is IN SCOPE for S1
  >
  > §1.0's **nameable in `M`** row lists, among the ways a declaration can be
  > *exported by a module `M` imports*, the case of reaching `M` **through a
  > re-export chain**. That arm **stands**. An interface that reaches `M` through
  > a re-export chain **is nameable in `M`**, and is therefore eligible as S1's
  > interface operand. A
  > conforming implementation **MUST** treat it so wherever the ordinary
  > import/export rules say the declaration is exported along `M`'s import path,
  > and **MAY NOT fail closed on chains.** Only the *sub-predicate* — what makes a
  > declaration count as **exported through** a chain — stays deferred; that is
  > item 1 below, now narrowed to it.
  >
  > **The verdict, on the worked program.** `M` imports `P`; `P` re-exports `Q`'s
  > interface `I`, whose methods include `n`; `M` defines a standalone `n`. Then
  > `I` is nameable in `M`, S1's intersection is non-empty, `n` **is a definer
  > shadow in `M`**, and by S2's definer arm `n` denotes the standalone
  > **unconditionally** — so `n` applied to a receiver at a live `impl I` head is a
  > **located reject**, not a dispatch.
  >
  > **Why.** S1-SCOPE's criterion above is *can the author write it down*. If the
  > import/export rules let `M` import and call the chain-exported method, it is a
  > candidate the author could have meant; excluding it would be S1 answering a
  > question this very note argues S1 has no business answering. The nameable set
  > is **exactly** what "can `M` name it" evaluates to — no more, and no less.
  >
  > **🚨 WHAT THIS LICENSES THAT WAS NOT LICENSED BEFORE.** Stated as a set,
  > because a rule that quietly widens is invisible to a citation audit.
  >
  > - **Newly NON-CONFORMANT:** an implementation whose nameable-in-`M` predicate
  >   is satisfied only by a *direct* export and answers "not nameable" for a
  >   chain-exported declaration. Failing closed on a chain was permitted by S1's
  >   previous silence. It is not permitted now.
  > **The discriminating cell is the IMPORTER arm**, not the definer one above,
  > and it **splits in two on the standalone's domain**. Fix the configuration: `M`
  > imports a standalone `n`; `P` (imported by `M`) re-exports `Q`'s interface `I`
  > declaring a method `n`; the receiver's head `T` has a live `impl I`. With the
  > chain arm **IN**, `n` is an **importer** shadow, so S2's importer arm applies
  > and a live-impl head **DISPATCHES**. With it **out**, `n` is no shadow at all
  > and the imported standalone is the only denotation. What that difference *looks
  > like* depends on whether `T` is inside the standalone's declared domain:
  >
  > - **`T` OUTSIDE the standalone's domain — the LOUD half. Newly ACCEPTED.**
  >   Chain out, the occurrence is a **located reject** (`Int vs T`). Chain in, it
  >   **dispatches**. So this ruling turns a located reject into an accepted
  >   dispatch — a **widening**, and the exact mirror of the acceptance
  >   **narrowing** S1-SCOPE charges as this ruling's cost above (*"an importer
  >   shadow whose only declaring interface is not nameable in `M`, applied to a
  >   receiver at a live-impl head"*): chains are the sub-case being put back in.
  > - 🚨 **`T` INSIDE the standalone's domain — the SILENT half. Newly a DIFFERENT
  >   VALUE AT EXIT 0, and this is the member of the set that is easy to miss.**
  >   Both readings **accept**. Chain in, the occurrence dispatches to `impl I T`;
  >   chain out, it calls the imported standalone. Two different answers, no
  >   diagnostic on either path, exit 0 both ways. **This is the `eq [1] [2]`
  >   erasure shape** — the one the 2026-07-14 S2 inversion exists to abolish (see
  >   the ⚡ banner in the top matter) — reaching the **importer** arm through a
  >   re-export chain. And after this ruling the dispatch answer is **mandatory**,
  >   not merely permitted, so this is a **licensing change and not only a
  >   widening**: an implementation that returns the standalone's answer here is
  >   non-conformant, and nothing about its output says so.
  > - **The DEFINER cell does NOT discriminate the two readings.** Chain in, `n` is
  >   a definer shadow and S2's definer arm gives the standalone unconditionally.
  >   Chain out, **§1.0's `nameable in M` excludes `I` outright**, so `I`'s method
  >   is never a candidate denotation for `n` in `M` at all and the module's own
  >   top-level standalone is the only one left. Same denotation, reached by two
  >   different routes. The worked program above states this ruling's verdict
  >   correctly, but it is **not** the cell that tells the readings apart — do not
  >   reach for it as a discriminating fixture. ⚠️ **Do not derive the chain-out
  >   half from S9's tie-break prose** (*"a name written at top level in a module
  >   is that module's name"*): that sentence sits inside a block marked
  >   **`[REPLACED 2026-07-14]`**, and its very next clause — an `import` is a
  >   *sibling* scope and does not shadow — is silent on this question rather than
  >   support for it. **The route is §1.0's table, and only that.**
  >
  > **Nothing in `test/` asserted the behaviour this forbids — enumerated, not
  > sampled, AT THE TIME OF THE RULING (2026-08-07).** `test/shadow_fixtures/`
  > then contained **zero** files matching `export import`, so the S1 corpus was
  > chain-free (consistent with the corpus-blindness note under §2).
  > ⚠️ **That is no longer the corpus's state and must not be re-derived from
  > this sentence** — the chain rows (§2 rows 40, 43, 44) were added
  > 2026-08-08 and each carries an `export import`. Derive it:
  > `grep -rl 'export import' test/shadow_fixtures/`. The enumeration below is
  > about **pins**, not fixtures, and is unaffected. Seven
  > `test/must_fail_fixtures/` directories matched, and
  > **none** pins chain-dependent shadow-hood:
  > `1353-transitive-iface-shadow-no-visibility`'s only match is a **comment
  > stating the fixture is deliberately not a re-export** (its `bridge.mdk`:
  > *"Plain `import`, NOT `export import`"*) — that is the **reachability** axis,
  > not this one — and `1072` / `1288` / `1359` / `1369` / `1373` / `1377` are
  > overlap, interface-identity, ctor-mangling, dict-passing, field-variant and
  > named-type rows. Of the four must-fail pins whose `claim.txt` mentions
  > shadowing (`93`, `1191`, `1351`, `1353`), only `1353` contains the string
  > `export import` at all, in that negating comment. **No pin is orphaned by this
  > ruling.**
  >
  > 🕳️ **The SILENT half above WAS UNGRADEABLE by this corpus — and not merely
  > for want of a chain. ✅ CLOSED 2026-08-08 by §2 row 44**
  > (`i16_importer_iface_via_chain_silent/`), which is exactly the shape this
  > paragraph said no unit had: a standalone whose domain **covers** the
  > live-impl head, both spellings graded, hop and no-hop pinned to the same
  > value. The derivation below is kept because it is *how* the missing cell was
  > identified, and because the reasoning generalises — read it as the method,
  > not as the corpus's present state. At the time of the ruling: **no unit in
  > `test/shadow_fixtures/` could express it**, because every importer unit's
  > standalone was
  > **domain-disjoint** from its own live-impl head, so all seven land in the LOUD
  > half by construction. Derived over the whole importer corpus, not sampled:
  > `i1` and `i3` and `i8` pair `size : Int -> Int` against `impl … Box` (`i8` also
  > `Bar`); `i4` pairs `isEmpty : Tok -> Bool` against a `List` receiver; `i5`
  > pairs `isEmpty : Int -> Bool` against `List`; `i10` pairs
  > `get : Int -> Int -> Int` against `impl Ix Box Int`; `i11` pairs
  > `display : Tok -> String` against an extern-sourced `Int`. In every one, the
  > live-impl head is outside the standalone's domain, so the chain-out reading
  > **rejects** rather than quietly returning a second answer. **A fixture for the
  > silent half needs a standalone whose domain COVERS the live-impl head** — the
  > shape no unit then had, and the shape row 44 now is. This is the same lesson
  > as rows 27–28 and row 32, a third time: *a gate that cannot express a cell
  > cannot defend it.*
  >
  > ✅ **One gated fixture already requires a chain to propagate, one path over.**
  > `test/analyze_project_fixtures/1272_wildcard_reexport_method_scope/` — enrolled
  > by directory glob, not an allow-list (`test/diff_compiler_analyze_project.sh`
  > iterates `"$FIXDIR"/*/`) — pins `T-NO-IMPL` *"No impl of MSIB for Blob"* on a
  > program where `msmth` reaches the root module **only** through `msmid`'s
  > `export import msifb.{MSIB, msmth}`: this note's `M`/`P`/`Q` shape at one hop.
  > Failing closed there was the S0 that fixture exists to pin.
  > ⚠️ **It corroborates the direction; it does not grade this clause.** That is
  > the **impl-obligation** path, and its `msmth` is never a standalone `DFunDef`,
  > so S1's conjunct is vacuously false there — the same reason #1302's repro does
  > not exercise S1 (see the ⚠️ under S1).
  >
  > **⚠️ THE COST, stated as a cost.** This puts S1's conformance **downstream of
  > a layer that has no spec of its own.** There is no import/export semantics
  > document in `docs/spec/`; "the ordinary import/export rules" resolves to
  > `SYNTAX.md` prose plus the implementation. That is the structural half of the
  > cost and it is not in doubt.
  >
  > The behavioural half is **much narrower than `SYNTAX.md` makes it look**, and
  > most of it is pinned GREEN. `docs/spec/SYNTAX.md:627-639` says `export import
  > <mod>.{name}` does **not** re-export a name `<mod>` itself only has via its own
  > `export import core.{name}`, and calls it *"a real compiler bug … filed as a
  > finding by this pass, not fixed here."* That paragraph was written by
  > `a8c54215` on **2026-07-13**, one day before
  > [#52](https://github.com/MedakaLang/medaka/issues/52) (*"`export import m.{x}`
  > silently re-exports NOTHING"*) closed on **2026-07-14** — so its *"reproduces
  > on current `main`"* was measured against a tree without that fix. Against the
  > corpus today:
  >
  > - **One hop, `core` origin — WORKS, pinned in two corpora.**
  >   `test/resolve_module_fixtures/reexport_core/` (`prov.mdk` is exactly
  >   `export import core.{Filterable, filter, filterMap}`) has a **0-byte**
  >   `expected`, and `test/eval_modules_fixtures/reexport_core/main.eval.golden`
  >   reads `[2, 4, 6] [30, 40]`. ⚠️ **That is `SYNTAX.md`'s own worked example —
  >   `stdlib/list.mdk` re-exporting `core`'s `filter`, consumed by a plain
  >   downstream `import` — and it is DISPROVED**, not merely unverified.
  > - **Two hops, non-`core` origin — WORKS, pinned.**
  >   `test/run_check_agreement_fixtures/lib/obl1114_reexp2.mdk` re-exports a
  >   re-export; its own header says it *"Pins that the chain resolves at every hop
  >   … rather than only at depth 1."*
  > - **Two hops WITH a `core` origin — the intersection of those two, and the only
  >   part still unpinned.** Tracked as
  >   [#1412](https://github.com/MedakaLang/medaka/issues/1412).
  >
  > So do not cite `SYNTAX.md:627-639` as a live general bug: its concrete example
  > is disproved and its general claim survives only at that one intersection.
  >
  > **The ruling does not turn on which.** Whichever way that resolves, the
  > structural point stands: a chain defect belongs to the **import/export** layer
  > and stays there, with one home. Under the rejected reading, S1's silence would
  > have let an implementation bake fail-closed behaviour in as **conformant** —
  > laundering an import/export defect into a spec-sanctioned outcome. That is the
  > trade this ruling makes, and it is where to push to reopen it.
  >
  > **🚧 NEITHER READING DESCRIBES TODAY'S BINARY. This arm is a TARGET, not a
  > description of behaviour.** The S1-detect universe today is **strictly wider
  > than both** candidate readings: `allIfaceMethodNames`
  > (`allIfaceMethodNames`, `compiler/types/typecheck.mdk` — cited **by symbol, not
  > by line**: this function has moved twice in two days, and
  > `test/check_doc_links.sh` strips a `:NNN` suffix before validating, so a line
  > citation here can rot while `docs-links` still passes) matches
  > `DInterface { methods, … }` and **never reads that declaration's `pub` field**
  > (`pub : Bool` is `DInterface`'s first field —
  > `compiler/frontend/ast.mdk:1210-1218`), and `appendUniverseAccums` folds its
  > result into
  > `crossRun.value.universeIfaceMethodsRef` **seeded with the ref's own previous
  > value**, i.e. accumulated cumulatively in the loader's dependency-first
  > topological order — the same shape `DICT-SEMANTICS.md` §8 **I5** records for
  > the impl universe. So the binary today sees interfaces from modules `M` does
  > not import **at all**, chain or no chain: the two readings are
  > **indistinguishable on it**, and their difference becomes observable only once
  > the reachability narrowing lands. That narrowing is owed to
  > [#1354](https://github.com/MedakaLang/medaka/issues/1354) (§2's reachability
  > row). **This ruling lands no compiler behaviour change.**
  >
  > **What is NOT ruled here** — three things, left open deliberately rather than
  > decided in passing:
  >
  > 1. **What makes a declaration count as "exported through" a re-export chain**
  >    — the sub-predicate, and *only* the sub-predicate. **Whether a
  >    chain-exported interface is nameable in `M` is RULED: it is** — S1-CHAIN
  >    above ([#1380](https://github.com/MedakaLang/medaka/issues/1380)). What
  >    remains deferred to the ordinary import/export rules is the narrower
  >    question those rules own: given a chain, is *this* declaration exported
  >    along it. This clause *consumes* that predicate; it does not define it.
  >    ⚠️ **Fail-closed is not an available answer for ANY chain, and the test is
  >    BEHAVIOURAL — one witness is enough.** If the ordinary import/export rules
  >    say a declaration is exported along `M`'s import path, an implementation
  >    that answers *"not nameable in `M`"* for it is **non-conformant** — whatever
  >    the hop count of that path, and whatever the implementation's internal
  >    structure. **Propagating one hop and failing closed on two is therefore also
  >    non-conformant, not a lesser form of compliance**, and "it does evaluate a
  >    predicate, the predicate just says no" is not a defence: an implementation
  >    that evaluates an unspecified predicate to false everywhere is
  >    observationally identical to one that never evaluates it, so the obligation
  >    is stated over **answers**, not over structure. This item's earlier wording
  >    flagged that arm as *"the arm a naive implementation of this clause is most
  >    likely to get wrong"*; it is now the arm a naive implementation gets wrong
  >    **against a rule**, not merely against expectations. Related but distinct: the
  >    [#1302](https://github.com/MedakaLang/medaka/issues/1302) export-visibility
  >    axis, whose own filed repro does not exercise S1 at all (see the ⚠️ under
  >    S1).
  > 2. ✅ **RULED 2026-08-10 — NO. A prelude standalone is NOT S1's left operand.**
  >    This item is **closed**; see **S1-PRELUDE** under S1 for the ruling, the
  >    argument, the diagnostic it requires and its ⟲ overturn condition. What
  >    remains of this item is only the record of why it was open: the kind
  >    partition admits only *defined in `M`* and *imported into `M`*, and the
  >    implicit prelude is neither on its face; no cell in §2 exercised it (every
  >    corpus unit's standalone was local or explicitly imported — **still true
  >    after rows 33–45**, which vary the *interface* operand and leave the
  >    standalone operand alone). Rows 46–48 are the cells that now exercise it.
  >
  >    🚨 **The spec may leave this open; CODE CANNOT** — this is the sentence that
  >    forced the ruling. A per-module
  >    nameable-in-`M` predicate has to answer it the moment it is written, and if it gets
  >    answered **by accident** — as a fallthrough, a default arm, or whichever
  >    branch was convenient — that is the class of defect this whole pass exists
  >    to remove: an unwritten rule decided by implementation drift and then
  >    inherited as if intended. **Owed: the implementing unit must state which
  >    way it answers this and why, or this item must be ruled first.** Answering
  >    it silently is not an option (#1375). It was ruled first.
  >
  >    ⚠️ **Adjacent, and NOT the same question — but the nearest live evidence
  >    that the prelude boundary is load-bearing rather than theoretical:**
  >    [#1191](https://github.com/MedakaLang/medaka/issues/1191) (OPEN) is a user
  >    binding colliding with a **prelude standalone**, with no interface
  >    anywhere in the program — so S1 does not reach it under *any* reading of
  >    either operand, and it is not an argument for either answer. What it shows
  >    is that the flat/zero-import path already resolves such a collision against
  >    the **prelude's** scheme rather than the user's, which is the mechanism
  >    whoever rules this item will be reasoning about. Pinned at
  >    `test/must_fail_fixtures/1191-prelude-standalone-collision/`.
  > 3. **Effect-label identity**, which `DICT-SEMANTICS.md` §8 I4 also leaves open.
  >
  > **What this ruling was NOT decided on.** It is an argument from the clause's
  > text and from what kind of rule S1 is — **not** a finding about what the
  > author of "may live anywhere" intended, which was not established and is not
  > claimed. It was adopted as a decision on that basis (#1375).

  > ### 🔒 S1-PRELUDE — RULED 2026-08-10 ([#1375](https://github.com/MedakaLang/medaka/issues/1375) item 2): a PRELUDE standalone is NOT S1's left operand, and the collision is NOT silent
  >
  > **The ruling, in two halves.**
  >
  > - **(a) Denotation — NO.** S1's **left** operand remains **exactly** the kind
  >   partition of §1.0: *defined in `M`* / *imported into `M`*. The implicit
  >   prelude is **neither**, so a standalone that reaches `M` only as an implicit
  >   prelude export **contributes nothing to S1's left operand and creates no
  >   shadow in `M`**. Consequently, where `M` declares an interface method named
  >   `N` and the prelude exports a standalone `N`, a bare occurrence of `N` in `M`
  >   denotes **the interface method** — not the prelude standalone, and not a
  >   choice made by the receiver's type. There is no shadow, so **no S2 arm
  >   applies**: neither the definer inversion nor the importer per-receiver rule,
  >   and in particular **the impl universe is never consulted to decide the
  >   name**. The occurrence is an ordinary interface-method occurrence and is
  >   subject to the ordinary obligation that an `impl` exist at the receiver's
  >   head; where none does, it is a **located reject**, exactly as it would be if
  >   the prelude standalone did not exist at all.
  > - **(b) Discoverability — a diagnostic is REQUIRED.** The collision **MUST NOT
  >   be silent.** A conforming implementation emits a **warning** (`W-PRELUDE-METHOD-SHADOW`,
  >   `compiler/DIAGNOSTIC-CODES-DESIGN.md`) at the declaration of the colliding
  >   interface method, naming the prelude standalone that the declaration makes
  >   unreachable by its bare name in `M`, and naming a recovery. A warning, **not**
  >   an error: under (a) the program is well-defined and is **accepted today**
  >   (measured — see Conformance), so rejecting it would be an
  >   accept-narrowing of working programs for the sake of a message.
  >
  > **The argument, so it can be disagreed with rather than merely cited.**
  >
  > (a) is the conservative reading of the two operands §1.0 already separates. The
  > left operand is not *chosen* — it is **pinned** by S1's own kind partition, and
  > S1-SCOPE says why in its own words: S2 is stated **per kind**, so admitting a
  > standalone that has no kind would let S1 classify an occurrence that S2 then
  > gives **no denotation**. Admitting the prelude to the left operand therefore
  > cannot be done by widening one set; it requires inventing a **third shadow
  > kind** with its own S2 arm. That third reading was considered and **rejected**:
  > nothing in this document needs it, and **no program has been exhibited that
  > needs it** — the requirement any such reading would have to meet is (a)'s ⟲
  > condition below.
  >
  > The rejected alternative worth naming explicitly is *"treat a prelude
  > standalone as an **importer** shadow"* — the reading that reuses an existing
  > kind rather than inventing one. It is rejected on its consequence, not on
  > taxonomy: S2's importer arm decides the occurrence by asking whether **an impl
  > happens to exist at the receiver's head**, over the **graph-global** instance
  > universe (`DICT-SEMANTICS.md` §8 **I5**). Under that reading, whether a bare
  > `N` in `M` means the user's interface method or a prelude function would move
  > when **an unrelated module anywhere in the loaded graph adds an impl** — a
  > program's meaning changing on an edit it has no import path to. S1-SCOPE
  > already refuses to let the instance universe decide **names** (*"One is about
  > **names**, the other about **instances**"*); this is that same refusal at the
  > left operand.
  >
  > **Comparative rationale — CITED, NOT MEASURED.** ⚠️ These characterisations of
  > other languages are **from knowledge and were NOT verified against a
  > toolchain** (no `ghc`/`rustc` on the box where this was written). Read them as
  > *cited comparative rationale, unverified* — they are an argument's supporting
  > analogy and must not be re-cited elsewhere as measured fact.
  > *Haskell* faces this exact question — class methods and free functions share
  > one namespace and one call syntax — and answers it by keeping both candidates
  > eligible and making every unqualified use an `Ambiguous occurrence` **error**,
  > with qualification or `import Prelude hiding (…)` as the explicit repairs; it
  > **deliberately refuses type-directed disambiguation of an ambiguous name**.
  > *Rust* avoids the question structurally — trait methods are not free functions
  > (`x.count()` / `Trait::count(x)`, never bare `count(x)`) — and its nearest
  > analogue, two in-scope traits offering the same method for one receiver, is
  > error **E0034**, requiring `<T as Trait>::count(x)`. Rust *does* let a local
  > item silently shadow a prelude or glob import, but only because the shadowed
  > item stays reachable **by path** (`std::option::Option`). **Neither language
  > does anything resembling the rejected importer reading**, and the half Medaka
  > departs from Haskell on is deliberate: Haskell errors because it has **no
  > winner**, whereas under (a) Medaka has one. What Medaka must not borrow from
  > Rust's silence is the silence itself — Rust can afford it because the path
  > repair always exists, and (b) exists because Medaka's does not (see the
  > recovery paragraph).
  >
  > **The recovery, MEASURED 2026-08-10 on a cold `make medaka` of this branch.**
  > (b) obliges the diagnostic to name a repair, so the repair had to be measured
  > before (b) could be written. **Two work; three plausible ones do not**, and the
  > message must name only the working ones:
  >
  > | Spelling | Verdict |
  > |---|---|
  > | Rename the interface method (or the local use) | **WORKS** — and is the only repair that needs nothing new |
  > | A shim module: a module that does **not** declare the colliding interface calls bare prelude `N` and exports it under a fresh name; `M` imports that | **WORKS** — `check` 0 / `run` correct / built binary correct. Follows directly from S1's per-module shadow-hood |
  > | `import core as C` → `C.N` | **DOES NOT WORK** — `Unbound variable: C.N`, and it fails **with no collision present at all**, so aliasing the implicit prelude is simply unimplemented (contrast `import list as L` → `L.take`, which works). §1.1's table recorded this for `eq` in 2026-07-14; re-measured for `count` |
  > | `import core.{N as pN}` → `pN` | **DOES NOT WORK** — `Unbound variable: pN. Did you mean 'N'` |
  > | `import core.{N}` (plain, no rename) | **DOES NOT RECOVER** — the interface method still wins; writing the import explicitly changes nothing |
  > | `import <shim> as S` → `S.N`, where the shim is `export import core.{N}` | **DOES NOT WORK, AND IS AN S0** — `check` exit 0 typing `S.N` as the *interface method*'s scheme, then a **SIGSEGV** from the built binary. Without the collision the same spelling builds a binary that prints the right answer, so the collision is the trigger. Filed separately; **do not name this spelling in any message** |
  >
  > **There is no `hiding`/exclusion syntax** — derived, not assumed: a
  > case-insensitive word-bounded grep for `hiding` over `compiler/`, `stdlib/` and
  > `docs/spec/` returns seven hits, **all** prose using the word in unrelated
  > senses, and none a construct. So Haskell's `import Prelude hiding (…)` repair
  > is unavailable here, which is precisely why (b) is a **warning that names a
  > repair** rather than an error that demands one.
  >
  > **🚨 WHAT THIS LICENSES, AND WHAT IT COSTS.** Stated as a set, because a rule
  > that quietly widens is invisible to a citation audit.
  >
  > - **Newly NON-CONFORMANT:** (1) An implementation that admits a prelude
  >   standalone to S1's left operand — under any kind, or under a third kind of
  >   its own invention. (2) An implementation that resolves the collision by
  >   receiver type, i.e. answers *prelude standalone* for a receiver at a head
  >   with no `impl` of the colliding interface and *interface method* for one that
  >   has one. (3) An implementation that accepts the colliding **declaration**
  >   with no diagnostic — (b) makes silence non-conformant.
  > - **NOT newly accepted, and NOT newly rejected.** (a) is the reading the front
  >   end already implements, so it changes **no** program's verdict and **no**
  >   program's value. This ruling's entire behavioural delta is (b)'s warning.
  >   That is deliberate: the alternative readings were the ones that would have
  >   moved values, and each is refused above.
  > - **The cost, stated as a cost.** A module that declares an interface method
  >   named `N` **loses the prelude's `N` by its bare name, everywhere in that
  >   module**, with no in-module repair — §1.1's *"rename your function"*, now
  >   reaching the prelude's own 49 method-and-standalone surface. That is the same
  >   cost §1.1 already charges for the definer inversion, and (b) is the whole of
  >   the mitigation. It is a real cost and it is not disguised: the honest summary
  >   is *the collision is cheap to hit, loud once (b) lands, and awkward to
  >   repair.*
  >
  > **Conformance today — MEASURED 2026-08-10, cold `make medaka` on this branch,
  > `MEDAKA_STRICT=1`, all three verbs plus the executed binary.**
  >
  > - **(a) HOLDS on `check` and on the built binary, and rows 46–48 are the
  >   discriminating cells.** With `interface Parity c where isEven : c -> Bool`
  >   colliding with the prelude standalone `isEven : Int -> Bool`, a receiver at a
  >   head with **no** `impl Parity` is `No impl of Parity for Int` on all three
  >   verbs — the interface method took the name, as (a) requires. The **rejected
  >   importer reading would have ACCEPTED and printed the prelude's answer**
  >   (`False`), because no impl exists at that head; that difference is what makes
  >   these cells discriminating rather than merely present. The arity-differing
  >   sibling (prelude `count`'s two arguments against an interface `count`'s one)
  >   likewise rejects on all three, with an arity diagnostic.
  > - 🚨 **THE EXECUTION ARMS DO NOT AGREE, AND THIS RULING IS WHAT MAKES THAT A
  >   BUG RATHER THAN AN OPEN QUESTION.** Three shapes are known, all filed
  >   separately and **deliberately NOT fixed here** — this note is their
  >   **oracle**, not their patch. In each, under (a) the answer that agrees with
  >   the interface method is the correct one.
  >   - **LOUD (WAS) —** [#1492](https://github.com/MedakaLang/medaka/issues/1492)
  >     (S1; still OPEN on the tracker, but its own repro no longer reproduces): at
  >     filing, `check` exit 0 clean, **`medaka run` exit 1 `E-PANIC
  >     intToString: not an Int`**, `build` exit 0 and the executed binary printed
  >     the **correct** value — an **S7** path-agreement violation. **Re-measured
  >     2026-08-28 on this tree** (post `S-prelude-cell-agreement` `89268878`),
  >     using #1492's own repro verbatim (`interface Sized c where count : c ->
  >     Int`, `impl Sized Box`, `println (count (Box 7))`, the same program as
  >     row 49's `x5_prelude_constrained_standalone_live_impl.mdk`): `check` 0,
  >     `run` **`7`**, `build` 0, binary `7` — all four now agree, no panic.
  >     The must-fail pin is **DRAINED**: `ls test/must_fail_fixtures/ | grep
  >     1492` returns empty, so there is no `test/must_fail_fixtures/1492-*` path
  >     left to cite.
  >   - **SILENT (WAS) —** [#1497](https://github.com/MedakaLang/medaka/issues/1497)
  >     (S0; still OPEN on the tracker, but its own repro no longer reproduces) —
  >     **row 49, and it is the one (a) most needs to be an oracle for.** At filing:
  >     make the two denotations *both* well-typed **at the same receiver** (an
  >     `impl` of the colliding interface at the receiver's head, so the interface
  >     method applies exactly where the prelude standalone also would): `check`
  >     exited 0 clean, **`run` printed the prelude standalone's answer** and the
  >     **built binary printed the interface method's answer** — two values, exit 0
  >     both ways, no diagnostic on any verb. That was the `eq [1] [2]` erasure shape
  >     reaching the *prelude* boundary — distinct from #1492's shape (loud) and
  >     #1493's (rejects on all three). At filing, the axis that produced silence
  >     was an UNCONSTRAINED colliding standalone at a receiver lying in both
  >     denotations' domains; a CONSTRAINED standalone (`sum`) in the same shape
  >     fell into #1492's loud cell instead.
  >
  >     **Re-measured 2026-08-28 on this tree** (post `S-prelude-cell-agreement`
  >     `89268878` + `F1` `abf203ba`), on the exact unconstrained shape (`interface
  >     Parity c where isEven : c -> Bool`, `impl Parity Int`, `println (isEven
  >     7)`, i.e. row 49's `x4_prelude_standalone_live_impl_receiver.mdk`): `check`
  >     0, `run` **`True`**, `build` 0, binary **`True`** — `run` and the built
  >     binary now AGREE, both giving the interface method's answer, matching (a).
  >     Sampled further, beyond the pinned shape (interface method colliding with a
  >     prelude standalone/method of the same name, at a live-impl receiver):
  >     `length`, `abs`, `compare`, `sum` (all definer/same-module), plus a
  >     cross-module **importer** variant of `abs` — every sample agreed between
  >     `run` and the built binary, matching (a). **This is a representative
  >     sample, not a re-run of the review round's full 55-name census** — see the
  >     row 49 status cell below for what that does and does not license saying.
  >     The must-fail pin is **DRAINED**: `ls test/must_fail_fixtures/ | grep 1497`
  >     returns empty, so there is no `test/must_fail_fixtures/1497-*` path left to
  >     cite.
  >   - **PRELUDE-INTERNAL (WAS) —** [#1493](https://github.com/MedakaLang/medaka/issues/1493)
  >     (S1; **CLOSED** on the tracker, and its own repro no longer reproduces):
  >     where the prelude's own bodies **call** the standalone, the collision used
  >     to make `stdlib/core.mdk` itself ill-typed and a legal program was rejected
  >     on all three verbs with diagnostics about prelude internals. **Re-measured
  >     2026-08-28 on this tree** with #1493's own `identity` repro (`interface Idn
  >     c where identity : c -> Int`, `impl Idn Box`, `println (identity (Box
  >     7))`): `check` exits **0** clean (was exit 1, five diagnostics including
  >     `No impl of Idn for Int`) — the collision no longer reaches `core.mdk`'s
  >     internals. **⚠️ That was the OPPOSITE DIRECTION from this ruling and
  >     S1-PRELUDE does NOT decide it** — see the missing-arm note below; whatever
  >     fixed it is not attributed to (a) or (b) here. The must-fail pin is gone
  >     (`test/must_fail_fixtures/1493-*` does not exist) — no path to cite.
  >
  >   ⚠️ **No mechanism is asserted for any of the three.** A candidate account —
  >   *"the occurrence routes to the prelude standalone, yielding a partial
  >   application"* — is **measured FALSE** (#1492): the symptom is
  >   arity-independent while that explanation is arity-dependent. Do not
  >   reintroduce it, here or in a fix's rationale.
  >
  > **🕳️ A MISSING CLAUSE ARM, FLAGGED AND DELIBERATELY NOT FILLED.** This ruling
  > governs an occurrence in a **user module** whose own interface method collides
  > with a prelude standalone. The **opposite direction** — an occurrence **inside
  > the prelude's own bodies**, where a *user* interface method's name collides
  > with a standalone the prelude itself calls (#1493) — is **not decided by any
  > clause here**. S1's *"the PRELUDE IS A MODULE"* sentence reads *"never a shadow
  > of **a user standalone**"*: it is scoped to **standalones**, so it is **SILENT**
  > about a user *interface method*, not violated by one. 🚨 **State it that way.**
  > The honest finding is a **missing arm**, and an implementation answering #1493
  > is not breaking an existing clause. Filling the arm is **owed and out of scope
  > for this ruling** — nothing in S1-PRELUDE should be read as deciding it.
  >
  > **⟲ Overturn condition.** (a) is overturned by a program that (i) is written
  > entirely against names its own module can name, (ii) is correct under the
  > language's other rules, and (iii) can only be given its intended meaning if a
  > **prelude** standalone participates in S1's left operand — which, per the
  > argument above, means exhibiting the **third shadow kind** and the S2 arm that
  > gives its occurrences a denotation, not merely asserting the operand should be
  > wider. It is **not** overturned by the awkwardness of the repair (that is the
  > cost this ruling charges itself, and (b) is its mitigation), nor by the `eval`
  > divergence above (that is a conformance bug *measured against* this ruling, and
  > citing it as an argument against the ruling inverts the direction of evidence).
  > (b) is overturned by a demonstration that the warning fires on programs whose
  > authors did not lose anything — in which case the fix is the **predicate**, not
  > the requirement that the collision be observable.

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

  > ### 🔒 S2-DECL — RULED 2026-08-09 ([#1351](https://github.com/MedakaLang/medaka/issues/1351)): the importer arm is evaluated PER DECLARATION, over declarations S1 admits, and BOTH its halves come from the SAME one
  >
  > **The gap this fills — two definite articles with no referent.** The importer
  > arm above reads *"any impl of **the shadowed interface** for **the receiver's**
  > head tycon `T`"*. Neither phrase denotes when **more than one interface declares
  > a method named `N`**. S1 and S1-NS classify shadow-hood over **names**, so `N`
  > can be a shadow in `M` while two distinct interfaces declare it — and then there
  > is no *the* shadowed interface. Nor is there a *the* receiver: **which argument
  > is the receiver is a property of an interface's declaration, not of the
  > occurrence**, and two declarations of the same method name may put it at
  > different argument positions. This is the same defect as the adjective this
  > document retired — a phrase that can be quoted in good faith to reach opposite
  > answers — and the clause set was inconsistent under both readings, so the repair
  > cannot be a branch selection.
  >
  > **(a) Receiver argument.** For a declaration `I` of a method named `N`, the
  > **receiver argument** is the first parameter of `I`'s declared method type whose
  > type mentions `I`'s **dispatch typaram** (S8: `I`'s first type parameter). It is
  > **not** necessarily the occurrence's first argument: for `interface IZ b where
  > mth : Int -> b -> Int` the receiver argument is **argument 1**. ⚠️ **S8's phrase
  > *"keyed on the first parameter"* means the interface's first TYPE parameter, not
  > the method's first value parameter** — read as the latter it contradicts this
  > sub-clause, and that reading is the emit-path non-conformance recorded below.
  >
  > **(b) Both halves from the same declaration.** The importer arm is evaluated
  > against a **declaration**, not a name. Each declaration `I` supplies **both**
  > halves together: the receiver argument (a), **and** the impl query, which is
  > *"does an `impl` of `I` exist at that receiver's head tycon `T`"* — still asked
  > over the **graph-global** instance universe (`DICT-SEMANTICS.md` §8 **I5**),
  > unchanged. **Taking the receiver argument from one declaration and the impl
  > query from another is non-conformant**: that pairing is a denotation no
  > declaration has, and it is exactly what #1351 ships (an occurrence typed against
  > one interface's declared method type and routed off another's argument
  > geometry).
  >
  > **(c) Admitted declarations.** `I` is **admitted** in `M` iff `I` satisfies
  > **S1-NS (a)** — the same per-method union of the two namespaces that decides
  > shadow-hood. A declaration `M` cannot name supplies **neither** half. This is
  > S1-SCOPE's criterion applied one level in: it already governs whether `N` is a
  > shadow at all, and a declaration that cannot make `N` a shadow cannot decide
  > what `N` denotes either. **Note the asymmetry this preserves:** the *names* that
  > may decide are narrowed; the *instances* that answer the query are not (I5).
  >
  > **(d) The choice, by cardinality of the admitted set.**
  >
  > - **Exactly one** → it decides, per (a)+(b).
  > - **Two or more that yield the SAME denotation** (all the standalone, or all the
  >   same impl) → that denotation. Shadow-hood is per **name** (S1); an occurrence
  >   is not ambiguous merely because two declarations agree about it.
  > - **Two or more that DISAGREE** → a **located reject** at the occurrence. Not a
  >   silent pick: by S1-SCOPE's own criterion this clause set is a
  >   *name-resolution* rule, which must be **choosing between candidates the author
  >   could have meant**; with two admitted candidates and no discriminator written
  >   in the source there is nothing to choose on, and any tie-break the
  >   implementation applies is supplied from outside the program the author can
  >   write down.
  > - **None** → S1 already says `N` is not a shadow in `M`; the standalone denotes.
  >   Unchanged by this clause.
  >
  > **(e) ORDER-INVARIANCE, stated as a rule so it can be gated.** The choice in (d)
  > **may never be a function of import-clause order, module-processing order, or
  > declaration order.** A resolution rule whose answer moves when two `import`
  > clauses are swapped is non-conformant **whatever value it produces** — including
  > when the two orders differ only in *accepting* versus *rejecting*. The
  > instrument is a permutation differential, not a golden:
  > `test/diff_compiler_import_order.sh`.
  >
  > **What it costs, stated as a cost.** One cell **narrows**: two admitted,
  > disagreeing declarations plus a standalone `N` compiles today and stops
  > compiling under (d). Same migration shape as S1-SCOPE's. And #1351's own corpus
  > **changes value**: under this clause every ordering of
  > `test/import_order_fixtures/1351-methoddispatchidx-import-order-collision/`
  > denotes the imported standalone (`IZ` is the only admitted declaration; its
  > receiver argument is argument 1, an `Int`, and no `impl IZ Int` exists), which
  > agrees with that case's semantic companion
  > `test/shadow_fixtures/i17_importer_two_ifaces_neither_nameable/`. **PREDICTED
  > UNDER THIS CLAUSE 2026-08-09, not measured at the time.** ✅ **CONFIRMED
  > 2026-08-29**: all six orderings now measure `99` on all three verbs, matching
  > the prediction; #1351 closed (`sprint/prelude-shadow-build-agreement` #2167,
  > slice `S-importer-position-spine` @`d5d71833` — see the issue's closing comment
  > for the mechanism and adjudication evidence).
  >
  > **What it does NOT change.** S2's graph-global impl universe (I5). This clause
  > changes what the query *asks* (an impl of `I`, rather than of anything declaring
  > a method of that name); it does not narrow which modules' instances may answer.
  > It also does not touch the **definer** arm, which never consults the impl
  > universe at all.
  >
  > **Conformance today — MEASURED 2026-08-09 (cold `make medaka` at `bfcd4ea7`,
  > `MEDAKA_STRICT=1`), and the two arms fail (b) DIFFERENTLY.**
  >
  > - **`check` / `run`.** The receiver argument comes from `methodDispatchIdx`, a
  >   **bare-method-name** first-match lookup over a graph-global accumulator, while
  >   the occurrence is typed from `methodIfaceParamsRef`, a bare-method-name map
  >   with the **opposite** tie-break. With two colliding declarations the two name
  >   different ones by construction — violating (b) — and the pick moves with
  >   import-clause order, violating (e). The impl query, `implExistsForHead`, is
  >   keyed by method **name** and head tycon, never by interface — so it can answer
  >   about an `impl` of a declaration `M` cannot name, violating (c).
  > - **`build`.** The emitter takes a different branch entirely:
  >   `definerShadowArgHead`'s importer-on-emit disjunct (`importerShadowOnEmitPath`,
  >   gated on a mark-seeded non-empty route symbol, hence **inert on the un-mangled
  >   `run`/`check` path**) routes the occurrence into `inferDefinerShadowApp`, which
  >   sets `suppressRLocalRecord` and therefore **never reads any dispatch-index
  >   table at all**. Its receiver is the peeled application's **first argument**,
  >   positionally — so it violates (a) for every method whose receiver argument is
  >   not argument 0, and it does so **order-invariantly**, which is why the defect
  >   cannot be seen by (e)'s instrument on that arm.
  >
  > Because the two arms decide by different mechanisms, **a fix applied to one is a
  > new S7 violation**: re-deriving the `check` arm's index alone moves `run` to the
  > standalone while the built binary still dispatches. Any candidate must be graded
  > on the **executed binary**, not on `run`.
  >
  > **⟲ Overturn condition.** (b) is overturned by a program, correct under the
  > language's other rules, whose intended meaning requires the receiver argument of
  > one declaration together with the impl query of another. (d)'s reject arm is
  > overturned by a **source-derivable, order-independent** discriminator between two
  > admitted declarations — an occurrence-level carrier recording which interface the
  > author named would convert many of today's reject cells into the one-admitted
  > case, and is the standing candidate; (e) survives either way.

  > ### 🔒 S2-DECL-SCOPE — RULED 2026-08-16 ([#1354](https://github.com/MedakaLang/medaka/issues/1354) M-1's residual): NO successor clause is owed — S2-DECL already governs it, and here is its reach per issue
  >
  > **The gap this closes is a CITATION gap, not a semantic one.** #1354's M-1 unit
  > records a residual it says only a spec ruling can decide — *"when the overlay
  > declines — both interfaces nameable, neither method name imported — there is no
  > scoped answer to route to … `docs/spec/SHADOW-SEMANTICS.md` should move before the
  > code does"* — and three slices of the 2026-08-16 cross-module-identity sprint were
  > planned around waiting for it. **It has already moved.** S2-DECL (above, ruled
  > 2026-08-09, on this same issue #1351) decides that residual in full. This note adds
  > no rule; it records the reach, so the next reader does not commission the ruling a
  > third time.
  >
  > **The residual's own framing is FALSE and is corrected here rather than repeated.**
  > *"Both interfaces nameable, neither method name imported"* does **not** empty S1's
  > right operand. S1-NS (a)(i) — the TYPE arm — admits a method name `n` when the
  > declaring interface's **own name** is admitted into `M`, whether or not `n` is. Two
  > nameable interfaces give a union of **two**, not zero. What declines in that shape is
  > an *implementation* predicate (`scopedMethodEntry`'s witness ladder, whose
  > `importedMethodEntry` arm requires an import binding the **name**), which is strictly
  > narrower than S1-NS (a). **A predicate that requires the method name where S1-NS (a)
  > admits on the interface name is NON-CONFORMANT with S2-DECL (c)**, which admits
  > declarations by S1-NS (a) and by nothing else. This is the whole content of the
  > residual, and it is an implementation-conformance statement, not an open question.
  >
  > **Reach, per issue, stated as a verdict so it can be graded rather than inferred.**
  >
  > | Issue | What S2-DECL specifies for it |
  > |---|---|
  > | [#1351](https://github.com/MedakaLang/medaka/issues/1351) | Its corpus is the **exactly-one-admitted** arm of (d), not the ambiguous one. `test/import_order_fixtures/1351-methoddispatchidx-import-order-collision/` names `IZ` in its member list and does **not** name `IA`, so exactly one declaration is admitted; (a)+(b) then give receiver argument **1** (`IZ`'s dispatch typaram `b` first appears at parameter 1), whose head is `Int`, and no `impl IZ Int` exists in the graph — so the occurrence denotes the **imported standalone**, value **99**, on **all six** orderings and on **all three verbs**. An implementation is conformant here iff its admission predicate is S1-NS (a) including the TYPE arm; requiring the method name leaves the bare-name first-match table in the loop and (e) is violated |
  > | [#1182](https://github.com/MedakaLang/medaka/issues/1182) / [#1620](https://github.com/MedakaLang/medaka/issues/1620) | **NOT GOVERNED.** S1's shadow-hood conjunct requires `N ∈ funDef-names(standalones defined in M or imported into M)` (S1, above; SHADOW-SEMANTICS.md:249-253) — a plain top-level `DFunDef` of the colliding name. #1182/#1620's repro has no such standalone: `m` exists **only** as two interface methods (`interface A1 … m`, `interface A2 … m`), never a top-level function. S1's conjunct is vacuously false, so S2-DECL never fires — the same pattern this document already names for #1302 (⚠️ under S1) and the wildcard-reexport case (row 44 / `msmth`, above): *"a different mechanism."* The actual mechanism, per #1182's own filed text: `matchingEntries` selects candidates by **method-name membership**, not by interface, so impls of different interfaces sharing a method name land in one candidate set and are ranked against each other by `pickMostSpecificEntry` — DICT-SEMANTICS §6 C1 coherence, a same-class-selector question, not an occurrence-granularity or import-order scoping question S2-DECL could ever reach |
  > | [#1265](https://github.com/MedakaLang/medaka/issues/1265) | **NOT GOVERNED.** Same vacuous-conjunct reasoning as the #1182/#1620 row: #1265's colliding name `speak` exists **only** as two interface methods (`ifa::Speak.speak`, `ifb::Greet.speak`), never a standalone top-level `DFunDef` — S1's shadow-hood conjunct is vacuously false, so S2-DECL never fires. The actual mechanism, per #1265's own filed text: `ifaceIdsAtTag tag` returns the identity of **every** interface implementing at that tag, and `defaultOwnedBy`'s filter yields **two** survivors when one type implements two interfaces sharing a method name, so the `_ => Some fallback` arm returns first-match — a cross-module DEFAULT-candidate registry leak (DICT-SEMANTICS §5 / §8 I4: the emitted symbol `mdk_default_<method>_<tag>` has no room for two interfaces' distinct default bodies), not an occurrence-granularity or intra-module problem |
  >
  > **What this note deliberately does NOT do, and why.** It does **not** commission
  > implementation of (d)'s **≥2-admitted-and-disagreeing** reject arm, and it does not
  > create a diagnostic code for it. S2-DECL's own ⟲ overturn condition names an
  > **occurrence-level carrier recording which interface the author named** as the
  > standing candidate to convert *"many of today's reject cells into the one-admitted
  > case"*. That carrier is live work. Implementing the reject before the carrier lands
  > would narrow acceptance across a cell set the carrier is expected to shrink — a
  > false-reject widening taken twice, against a shape that today has **no fixture in
  > either corpus** (derive, do not trust: no entry under `test/shadow_fixtures/` or
  > `test/import_order_fixtures/` names two distinct interfaces declaring one method
  > name). **Sequencing rule: the carrier first, then (d)'s reject arm over whatever
  > cells remain.**
  >
  > A pin existed for a neighbouring shape at
  > `test/must_fail_fixtures/1664-decl-agreeing-both-admitted/` (closed and deleted
  > 2026-08-29, `sprint/prelude-shadow-build-agreement` #2167 — see the closing
  > comment on [#1664](https://github.com/MedakaLang/medaka/issues/1664) for the
  > convergence evidence); its measured causal variable was the graph presence of a
  > non-admitted declaration's impl, i.e. an S2-DECL **(c)** conformance question,
  > not the (d) disagreeing arm — which still has no fixture anywhere.
  >
  > **Diagnostic code — RESERVED, NOT CREATED.** When (d)'s disagreeing arm is
  > implemented it needs a **new `T-` code**, and neither existing family will host it:
  > the `R-AMBIGUOUS-*` family is resolve-stage and this reject needs the receiver's head
  > tycon and the graph-global impl query, and `T-AMBIGUOUS-INSTANCE` is *"this predicate
  > has no unique evidence"* for a determined type, whereas this is *"two admitted
  > declarations disagree about what this name denotes"*. `R-DUPLICATE-IFACE-METHOD` is
  > its **intra-module, declaration-time** peer and explicitly does not cover the
  > cross-module case. **No row is added to `compiler/DIAGNOSTIC-CODES-DESIGN.md` by this
  > note** — a code in that catalog that no binary can emit is a lie in the catalog.
  >
  > **Row 42 (`i22_importer_member_alias_not_nameable`) is NOT reached by this note, and
  > that is a decision, not an omission.** It is already governed: **S1-NS (a)(ii)** says
  > the admitted name must be the **callable** one, so under the clause `99` is correct
  > for both `import ifc` and `import ifc.{size as sz}`, and the pinned `7` is an
  > implementation non-conformance, not an unruled cell. Its **fix shape** is the open
  > question, on a fresh axis, and 🚨 **the obvious fix is MEASURED INERT**: keying the
  > VALUE arm on the local spelling cannot move `run`/`build`, because
  > `renameAliasedMethods` → `deAliasMethodImports` has already rewritten `{size as sz}`
  > to `{size}` before `selectIfaceRows` runs on that path; the `check` path does not
  > de-alias, so the change moves **`check` alone** and manufactures a `check` ≠ `run`
  > split. Do not attempt it.
  >
  > **⟲ Overturn condition.** This note is overturned by exhibiting a shape in which
  > S2-DECL's four cardinality arms (d) give **no** answer — i.e. a method occurrence
  > that is a shadow under S1/S1-NS and for which the admitted-declaration set is
  > neither empty, nor a singleton, nor an agreeing set, nor a disagreeing set. Its
  > per-issue table is overturned per row by a measurement contradicting that row's
  > stated value or mechanism; the #1351 row in particular is overturned by an
  > `impl IZ Int` appearing anywhere in that corpus's graph, which would move its value
  > off the standalone.

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
> which pointed at deleted text. Restored from `9c6dcee5^` with **three
> deviations** — one in S6, two in S8:
>
> - **S6's importer half is NARROWED, not restored** — the 🚨 paragraph inside S6
>   below carries the derivation. Its three-subject location-independence
>   sentence was true when written (2026-07-09) and was made **false** by #1375's
>   scope ruling (2026-08-06) *while this clause was absent from the document*.
>   Restoring it verbatim would have re-imported a claim S1-SCOPE contradicts
>   thirty lines above it. ⚠️ **This is the deviation that makes the count three.**
>   An earlier revision of this note said "exactly two" — correct about what had
>   been done, wrong about what should have been. The third was found by the rules
>   review on PR #1390, not by the restoration.
> - Its definer-gate sentence read *"is this a method of some **visible**
>   interface"*. A bare "visible" is retired document-wide (§1.0) and no scope
>   claim about `ifaceMethodName`'s lookup table has been established here, so the
>   adjective is **dropped with nothing put in its place** — the clause is left
>   **silent on scope**, which is the honest state. ⚠️ It briefly read *"an
>   interface method **at all**"*; that was withdrawn, because "at all" asserts the
>   predicate is *unrestricted* — a true description of today's implementation, and
>   the graph-global reading #1375 overturned for S1's interface operand — placed
>   inside §1 with no marker saying which of the two it was.
> - Its closing paragraph predicted a *"probable live divergence from S2"* at
>   multi-typaram importer width and recorded row 30 as **UNVERIFIED**.
>   `9c6dcee5` — the very commit that dropped the clause — **probed row 30 and
>   disproved that prediction**. The paragraph now records the measured outcome,
>   which §2's row 30 and this document's top matter already state. **S8's
>   normative content is unchanged by the swap**: the specified outcome for a
>   multi-typaram *importer* shadow was the standalone before and is the
>   standalone now.
>
> **What this changes for an implementer — stated against the baseline that
> matters.** Against `9c6dcee5^` (the text as it last stood) the delta is the S6
> narrowing and nothing else. But **an implementer reads `main`**, where these
> three clauses have *no text at all*, and against that baseline **three clauses of
> obligation return**: S6 (location-independence for the impl and the standalone,
> with the interface carved out), S7 (path agreement, and its warning that
> cross-engine agreement is worthless as evidence), and S8 (neither method-param
> count nor interface-typaram count changes the rule). None of the three is new
> law — every one was already assumed by the tables that cite it throughout §2 and
> §5 — but "no licensing delta" is only true against the 2026-07-17 baseline, and
> saying it unqualified would be measuring against a document nobody reads.

- **S6 (module-independence).** **[CHANGED]** For a **definer** shadow the impl
  query is *deleted*, so S6 is **trivially satisfied**: where the interface and impl
  live cannot change the outcome, because the outcome no longer depends on them. An
  all-local live impl (`d2`) and an imported one (`d8`) now reject identically. For
  an **importer** shadow, **two of the three subjects** are still
  location-independent: where the **impl** lives cannot change the outcome (S2's
  impl universe is **graph-global**), and neither can which module the
  **standalone** is imported from. Those two change *detection bookkeeping*, never
  the outcome.

  🚨 **The INTERFACE's location is NOT free, and S6 must not be read as saying it
  is. [NARROWED 2026-08-07 — #1380.]** This clause read *"where the
  standalone/**interface**/impl each live changes detection bookkeeping, never the
  outcome"* — verbatim from the document's creation (`c96192c2`, 2026-07-09), when
  S1's operands were graph-global and it was **true**. `b725020b` (2026-08-06,
  #1375) scoped S1's interface operand to **nameable in `M`**, which makes the
  interface's location **load-bearing**: hold the standalone, the impl and the
  receiver fixed and move only the interface's declaring module out of `M`'s import
  reach, and `N` stops being a shadow at all — S2's importer arm never applies, and
  a live-impl head that **dispatched** now denotes the imported **standalone**
  instead (a different answer, and a located reject where the receiver falls
  outside that standalone's declared domain). The outcome flips on nothing but
  where the interface lives. **S1-SCOPE says so in its own words, as the price of
  that ruling:** *"an importer shadow whose only declaring interface is not
  nameable in `M`, applied to a receiver at a live-impl head. Such a program
  compiles today and stops compiling under this clause."*

  **Why nobody reconciled the two.** This clause had **no text in the document**
  from `9c6dcee5` (2026-07-17) until it was restored under #1380 (2026-08-07) — see
  the restoration note above — and that is the entire window in which #1375 landed.
  A clause that is absent cannot be checked against a new ruling, so the ruling's
  own cost paragraph came to sit thirty lines above a contradiction that was not on
  the page. **Restoring the sentence verbatim would have re-imported it.**

  ⚠️ **§2's rows 14–18 do not grade this.** They vary the interface's topology only
  *within* `M`'s nameable set (`i1` declares it in `main.mdk`; `i3` and `d8` import
  it by name), so they are consistent with the narrowed clause and blind to the
  out-of-set case. **A green row 14–18 is not evidence about this paragraph.**
  ✅ **Rows 33–45 ARE**, and they are what to cite instead — added 2026-08-08,
  after this note was written, and they move the interface's declaring module out
  of `M`'s reach in every way the import/export rules allow: no path at all
  (33–34), a path that binds a different name (35), a sibling method (36–37), no
  admitted name at all (38), a re-export chain (40, 43–44), a module or member
  alias (41–42). **Row 44 is the one that shows the outcome flipping with nothing
  but the interface's location and NO diagnostic on any verb** — the silent
  member this paragraph's own narrowing produces.

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
  method — and nothing more, because the inversion never consults the impl
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
| **Operators** (`==`, `/=`, `<`, `+`, `++`, …) | **YES** | They desugar through the method-call path and never touch the bare-name funDef intersection (row 24, UNREACHABLE). A module with `impl Eq Foo` *and* a standalone `eq` still evaluates `Foo 1 == Foo 2` correctly. Covers `Eq`/`Ord`/`Num`/`Semigroup`. |
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

> ### ⭐ Rows 33–45 — THE NAMEABILITY BLOCK. These are the cells this corpus could not express, and they close the gap #1375 recorded as owed.
>
> **Every row 3–32 above puts the shadowed interface INSIDE the occurrence
> module's nameable set** (§1.0) — the `d*` units are single-file, so
> nameable-in-`M` and graph-global coincide there by construction;
> `i1`/`i6`/`i6b`/`i7`/`i8`/`i9`/`i10` declare the interface in `main.mdk`;
> `i3` and `d8` import it by name; `i4`/`i5`/`i11` shadow the prelude. That is
> why the corpus once graded **byte-identically** under S1's scoped reading and
> under the graph-global one it replaced, and why a green
> `diff_compiler_shadow_semantics` was **not** evidence about the ruling.
>
> The rows below are the discriminating cells. Each holds the standalone, the
> impl and the receiver fixed and varies only **how much of the interface `M`'s
> import path admits** — no path at all (33–35), a sibling method (36–37), no
> method and no type name (38), a module alias (41), a member alias (42), a
> re-export chain (40, 43–44), two colliding declarations and neither admitted
> (45). ⚠️ **They discriminate S1's operand; they do not re-grade S2.** The impl
> universe stays **graph-global** in every one of them (§1.0, `DICT-SEMANTICS.md`
> §8 I5) — what changes is whether the occurrence is a shadow at all.
>
> 🚨 **Read the SILENT rows first, not the loud ones.** Only **34** and **43**
> fail with a located reject — the easy half. **33, 35, 36, 37, 38, 41, 42, 44
> and 45 accept under BOTH readings** and differ only in the value printed at
> exit 0 on all three verbs: the `eq [1] [2]` shape, which by **S7** no
> differential gate can see and which no ACCEPT/REJECT column can express. **39
> and 40 are neither** — they split *across verbs* (39: `check` accept, `run` a
> wrong value, `build` an E-PANIC; 40: `check` and `run` correct, `build` an
> E-PANIC), which is an **S7** violation and the reason each is graded on the
> verb that can see it rather than on `run`. This is the corpus's own recurring
> lesson (rows 27–28, row 29, row 32) a fourth time: **the loud half of a defect
> gets a fixture and the silent half is the one that ships.**
>
> **Where the Status column for 33–45 comes from, stated because it is not a fresh
> local run** (2026-08-10). It is read off each unit's pinned expectation in
> `test/diff_compiler_shadow_semantics.sh`, which asserts verdict **and** value on
> all three verbs per unit and runs in CI's `types` shard — so a Status here that
> disagreed with the binary would be a red gate rather than a stale cell, which is
> the property the note above this table demands. **The Specified-outcome column
> is NOT inherited from the gate**: each was re-derived from S1 / S1-NS (a) /
> S1-CHAIN / S2 / S2-DECL against the fixture source. Rows 41, 42 and 45 are where
> that derivation and a fixture's own header prose part company; each says so in
> its Status cell.

| # | Cell (kind · receiver · topology · use) | Clause | Specified outcome | Fixture | run | build | check | Status |
|---|---|---|---|---|---|---|---|---|
| 33 | **importer** · interface NOT NAMEABLE — its module reaches the loaded graph **only transitively**, through a third module's **plain** `import` (which re-exports nothing) · receiver inside the standalone's domain | S1 (S1-SCOPE) | **not a shadow** → the imported standalone → `99` | `i12_importer_iface_not_nameable/` | 99 | 99 | accept | **OK** — the reachability cell #1375 recorded as owed, and the shape [#1353](https://github.com/MedakaLang/medaka/issues/1353) (S0, closed) was filed on. Under the graph-global reading the identical source prints **`7`** — an impl body from a module `main.mdk` has no import path to — at exit 0 on all three verbs. ⚠️ It **replaces a drained must-fail pin** (`1353-transitive-iface-shadow-no-visibility`, since deleted): a drained pin is removed, so without this row a fixed S0 would have no guard at all |
| 34 | **importer** · same topology as row 33 · **LIVE impl at the receiver's head tycon**, receiver **outside** the standalone's domain | S1 (S1-SCOPE) | **not a shadow** → the imported `Int -> Int` standalone applied to a `Box` → **located REJECT** `Type mismatch: Int vs Box` | `i13_importer_not_nameable_liveimpl/` | reject | reject | reject | **OK** — #1375's own "sharper repro". Under the graph-global reading the same source is ACCEPTED at exit 0 printing `300`. Row 33 pins a wrong **value**; this pins a wrong **denotation**, and the two fail for different reasons: here the answer is reachable *only* through a name the author could not have written |
| 35 | **importer** · the interface's home module **IS** imported — and the interface is still not nameable, because the import binds a different name (`import smod.{sf}`, and the bare-`import` spelling as its own row) | S1 (S1-SCOPE) + S1-NS (a) | **not a shadow** → the imported standalone → `99` (both spellings) | `i15_importer_iface_one_hop_unbound/` (`main.mdk` + `bare.mdk`) | 99 / 99 | 99 / 99 | accept | **OK** — the **ONE-HOP** form of row 33, one line shorter, and **not a duplicate of it**: a fix that admits a dependency's whole interface set on any import of it leaves row 33 green while this one still prints `7`. `bare.mdk` takes a different arm — a bare `import smod` is an **empty** member list, not a wildcard (AGENTS.md: a bare import binds NO names) — and is the lock that keeps a fix from special-casing the empty list, which would also break the **module-alias** admission row 41 depends on (#1277) |
| 36 | **importer** · interface reached **only by naming a SIBLING method** (`import ifc.{tag}`) · standalone's domain **covers** the live-impl head — the SILENT cell | S1-NS (a), per-**method** | `size` is admitted by **no** arm → not a shadow → the imported standalone → `42` | `i19_importer_sibling_method_silent/` | 42 | 42 | accept | **OK** — measurably per-method: writing `size x` on the strength of `import ifc.{tag}` is `Unbound variable: size`. Admitting the whole interface row because *one* member is named would make a **different** name dispatch-eligible on evidence that says nothing about it. Pre-ruling this printed `777`, the impl body; `777 → 42` is S1-SCOPE's acceptance narrowing reaching its **silent** half, which is the cost that clause charges itself |
| 37 | **definer** twin of row 36 — the module defines its own `size` and reaches the interface only by naming a sibling method | S1-NS (a) + S2 (definer arm) | not a shadow → the module's **own** top-level binding → `42` | `d23_definer_sibling_method_silent/` | 42 | 42 | accept | **OK** — paired with row 36 because **S2 states its rule per KIND**, so a fix repairing one arm leaves the other silent (the `d18`/`i6b`, `d22`/`i7` shape). ⚠️ **Baseline note, so this row is not over-read:** the merge base already answers `42` here — it guards a regression the S1-NS unit could have introduced, not one it inherited |
| 38 | **RETURN-POSITION** method (`zed : a` — the interface typaram appears **only** in the result) · interface admitted by **no** arm · DEFINER and IMPORTER graded separately | S1-NS (a) + S1-NS (b) | not a shadow → the module's own / the imported `zed` → `42` in both | `d24_definer_return_pos_not_nameable/`, `i21_importer_return_pos_not_nameable/` | 42 / 42 | 42 / 42 | accept | **OK** — the axis the corpus was wholly missing: **every** interface method in rows 3–32 mentions its typaram in an ARGUMENT. That one axis selects a different mark-pass input, which was concatenated **raw** while the arg-position inputs were filtered — making dispatch-eligibility a strict **superset** of shadow-hood, i.e. S1-NS (b)'s closure invariant violated, with the whole corpus green over it. Measured before the fix: `run` `777` vs **built binary** `42`, both exit 0 |
| 39 | **RETURN-POSITION** method · **interface IS nameable** (`import smod.{Zed, sf}`) · DEFINER — the discriminating control for row 38 | S2 (definer arm) + S7 | `zed` **is** a definer shadow → the standalone, unconditionally → `42` | `42` (`test/shadow_fixtures/d25_definer_return_pos_nameable/`) | `42` | `42` | accept, 0 diagnostics | ✅ **OK — [#1430](https://github.com/MedakaLang/medaka/issues/1430) FIXED.** It was three verbs, three answers (`check` accept, `run` **777**, `build` **E-PANIC** `unbound method: zed`), and the S0 half was `run`'s silently wrong value. **The defect was a TYPE/ROUTE split, not a classification miss:** `maybeStandaloneValueMono` had already pinned the occurrence's TYPE to the standalone, while `recordRLocalSite` pushed no route site at all — it matches on `methodDispatchIdx name`, and a return-position method has no dispatch argument, so that answered `None` and every arm declined. That is exactly the invariant `standaloneValuePinned`'s own header states ("⭐ THE ROUTE MUST FOLLOW THE ARM"), violated at the one cell the dispatch-index gate hides. The `build` half was a second, independent site: a nullary top-level binding is a value GLOBAL, so `emitMethod`'s `RLocal` arm emitting `call i64 @mdk_<sym>()` named a define that does not exist. **This is why row 38 must not be read as covering return position** — row 38 passes *because S1 declines to classify*, so it never reaches S2's inversion at all. The load-bearing axis is return-position-ness, **not** the nameability that rows 33–38 vary: give the method an argument mentioning the typaram and the inversion always fired correctly. Now gated in `test/shadow_fixtures/` as **D25**, the discriminating twin of D24 — until this fix the corpus's only two return-position cells (D24, I21) were both NOT-nameable, i.e. both green for the reason that they never reach S2 |
| 40 | **importer** · the METHOD arrives through a **re-export chain that names the method, not the interface** (`export import ifc.{size, Box}`) · no standalone of that name anywhere | S1-NS (a)(ii) + (b) | S1's **left** operand is empty → not a shadow → **ordinary dispatch** → `impl Sizeable Int` → `50` | `i20_importer_method_reexport_chain/` | 50 | 50 | accept | **OK** — graded on **`build`**, the only verb that could see it: an implementation whose re-export arm matches interface names only leaves `size` out of the dispatch-eligible set, the mark pass leaves a plain `EVar`, and emit falls into arg-tag dispatch — `check` exits 0 and `run` prints the right answer while `build` **E-PANICs**. S1-NS enumerates that asymmetry as non-conformant (item 4). The `impl Sizeable Int` is load-bearing: a **primitive** receiver carries no cell tag, which is what turns the missing mark into a panic |
| 41 | **importer** · interface reached **only through a MODULE ALIAS** (`import smod as S`) | S1-NS (a)(ii) | the alias arm admits `size` (*"a module alias … since `A.n` is a legal call"*) → `size` **is** a shadow → S2's importer arm, live `impl Sizeable String` → **dispatch** → `7` | `i18_importer_alias_not_nameable/` (`main.mdk` + `both.mdk`) | 7 / 7,7 | 7 / 7,7 | accept | **OK against the clause as written** — ⚠️ **and the fixture's own header says the opposite.** That header argues from the TYPE arm alone (an alias cannot put `Sizeable` in type position, so `impl Sizeable Blob` is rejected) and concludes the answer *"should"* be `99`. **S1-NS (a) is a UNION, and either arm suffices**; `i15_importer_iface_one_hop_unbound/bare.mdk`'s own note says the alias *"MUST admit the whole row"* and cites #1277 for it. The pinned values are conformant; **the disagreement is between two fixture comments and this clause, and it is a comment-truth defect, not a behaviour one** — see the ⚠️ under the tally |
| 42 | **importer** · method reached **only under a MEMBER ALIAS** (`import ifc.{size as sz}`), with a bare-`import` sibling as the discriminator | S1-NS (a)(ii) | the only callable spelling this import admits is **`sz`**; `size` is admitted by no arm → not a shadow → the imported standalone → `99` (both spellings) | `i22_importer_member_alias_not_nameable/` (`main.mdk` + `bare.mdk`) | **7** / 99 | **7** / 99 | accept | ❌ **KNOWN-BAD (main.mdk), self-draining — re-grade to `99` the day it is fixed.** `bare.mdk` is the proof the correct value is reachable rather than hypothetical: two spellings that admit the *same* amount of the interface (nothing writable) give different answers, and both cannot be right. ⚠️ **The obvious fix is INERT and this row says so** — `renameAliasedMethods` rewrites `{size as sz}` to `{size}` before `selectIfaceRows` ever runs, so re-keying that call on the local spelling cannot move this cell. A real fix spans both, and is a design question no ruling covers |
| 43 | **importer** · interface nameable **only through a re-export chain** (`export import ifc.{Sizeable}`) · receiver **outside** the standalone's domain — the LOUD half · graded against a hop-free control | S1-CHAIN ([#1380](https://github.com/MedakaLang/medaka/issues/1380)) | the chain arm admits `Sizeable` → shadow → S2's importer arm, live `impl Sizeable Box` → **dispatch** → `300`; the control **must agree** | `i14_importer_iface_via_reexport_chain/` (`main.mdk` + `direct.mdk`) | 300 / 300 | 300 / 300 | accept | **OK** — the corpus contained **no `export import` at all** before this cell (derive: `grep -rl 'export import' test/shadow_fixtures/`), which is exactly how a first cut could build the predicate out of a method-name index, answer *not nameable* for a chain that names **no method**, and reject this program while `direct.mdk` printed `300`. The **control is the real assertion**: re-routing one import through a re-exporter cannot change a program's meaning, so the two rows must agree under **either** reading of the clause |
| 44 | **importer** · same chain as row 43 · receiver **inside** the standalone's domain — the **SILENT** half · graded against a hop-free control | S1-CHAIN | shadow → dispatch → `7`; **not** the standalone's `99`; the control must agree | `i16_importer_iface_via_chain_silent/` (`main.mdk` + `direct.mdk`) | 7 / 7 | 7 / 7 | accept | **OK** — this is the cell S1-CHAIN's own 🕳️ paragraph recorded as **ungradeable by this corpus**, and it is now graded. Both readings **accept**; the answer is observable only as a value at exit 0 on every verb, so neither an ACCEPT/REJECT column nor cross-engine agreement can see it. A lost shadow here prints `99` silently — the `eq [1] [2]` erasure shape reaching the **importer** arm through a chain |
| 45 | **importer** · **TWO** unrelated interfaces declare the same bare method name at **different** dispatch argument positions (`mth : a -> Int -> Int` and `mth : Int -> b -> Int`) · **neither** admitted · graded against an import-order permutation | S2-DECL (d), the **none-admitted** arm | the admitted set is **empty** → S1 says `mth` is not a shadow → the imported standalone → `99`; the order-swapped row **must agree** | `i17_importer_two_ifaces_neither_nameable/` (`main.mdk` + `order-swapped.mdk`) | 99 / 99 | 99 / 99 | accept | **OK** — the standalone `fmodI.mth` is **load-bearing**: the bare-name dispatch-index table's only reader is gated on the standalone-values set, so without it this graph never reaches the defect. **Value DERIVED, not captured** — hand-derived from S2-DECL before any fix. ⚠️ **Two orderings is not a permutation differential**: three clauses have six orderings and this pins two. The other four live in `test/import_order_fixtures/1351-methoddispatchidx-import-order-collision/`. This row's original warning was: with neither interface nameable here, the bare-name table is never consulted, so this row's own convergence says nothing about #1351's (one-admitted) shape — do not treat one as evidence for the other, they are different admission cells. ✅ **UPDATE 2026-08-29**: #1351 has SEPARATELY closed on its own evidence, not by conflation with this row (`sprint/prelude-shadow-build-agreement` #2167, slice `S-importer-position-spine` @`d5d71833` — see the issue's closing comment for the mechanism and a dedicated adjudication confirming it is a real fix, not another manifestation shift). The general caution stands for any FUTURE row: a fix that converges one admission shape is not evidence for a differently-admitted one — verify each separately |

| 46 | **PRELUDE standalone** as the candidate left operand · interface declared in `M` · receiver at a head with **no impl** of that interface but **inside** the prelude standalone's domain — the LOUD, discriminating cell | S1-PRELUDE (a) | the prelude is **not** in S1's left operand → **not a shadow** → the bare name is the **interface method** → ordinary dispatch finds no impl → **located REJECT** | `x1_prelude_standalone_not_left_operand.mdk` | reject | reject | reject | **OK** — the cell #1375 item 2 left open and **the corpus had none**: every other unit puts the standalone in `M` or imports it explicitly, so this axis graded nowhere. The **rejected** reading (admit a prelude standalone as an *importer* shadow) ACCEPTS the same source and prints `False`, because S2's importer arm falls back to the standalone when no impl sits at the head — that difference is what makes this cell discriminating. ⚠️ Value **hand-derived from the ruling, not captured**: `eval` is a known-wrong oracle on this collision (see row 49) |
| 47 | row 46 with **ZERO impls** of the colliding interface | S1-PRELUDE (a) | same → **located REJECT** | `x2_prelude_standalone_zeroimpls.mdk` | reject | reject | reject | **OK** — the `d1b`/`d19` move applied to the prelude cell, and it closes a *different* escape hatch: an implementation that consulted the impl universe **before** deciding the name would answer row 46 correctly for the wrong reason. With no impl to consult, only the interface method having taken the name outright can produce this reject — which is (a)'s actual content (*"no S2 arm applies; the impl universe is never consulted to decide the name"*) |
| 48 | row 46 at **ARITY-DIFFERING** width — prelude `count`'s two arguments against an interface `count`'s one | S1-PRELUDE (a) + S8 | same → **located REJECT** (over-application **and** no impl at the function argument's head) | `x3_prelude_standalone_arity_differ.mdk` | reject | reject | reject | **OK** — rows 46/47 both collide with an arity-**matching** standalone, so a reader could conclude the rule is gated on the signatures lining up. It is not. Under the rejected reading this ACCEPTS and prints `3` |
| 49 | **PRELUDE standalone** collision where **BOTH denotations are well-typed at the SAME receiver** (an `impl` of the colliding interface at the receiver's head, so the interface method applies exactly where the prelude standalone also would) | S1-PRELUDE (a) + **S7** | (a) gives the **interface method**; `check`, `run` and the built binary must agree on it | `test/shadow_fixtures/x4_prelude_standalone_live_impl_receiver.mdk` (unconstrained), `x5_prelude_constrained_standalone_live_impl.mdk` (constrained) — added by the `prelude-shadow-agreement` sprint; [#1497](https://github.com/MedakaLang/medaka/issues/1497)'s must-fail pin is DRAINED (`test/must_fail_fixtures/1497-*` no longer exists) | **the PRELUDE standalone's answer** | **the INTERFACE METHOD's answer** | accept, **0 diagnostics** | ✅ **CONFORMANT, measured 2026-08-28 on this tree** (post `S-prelude-cell-agreement` `89268878` + `F1` `abf203ba`, sprint `prelude-shadow-agreement`). `check`/`run`/`build`+binary all agree on the **INTERFACE METHOD's** answer, matching (a) — both on the two gated fixtures (x4: `True`/`True`/`True`; x5: `7`/`7`/`7`, all `ACCEPT ACCEPT ACCEPT`, `diff_compiler_shadow_semantics.sh`) and on a further hand-run sample (`length`, `abs`, `compare`, `sum`, plus a cross-module importer variant of `abs`) — see the LOUD/SILENT/PRELUDE-INTERNAL bullets under S1-PRELUDE's Conformance for the individual re-measurements. **This sample is not a re-run of the review round's original 55-name census**, so this row does not claim conformance for every prelude name, only for what was re-measured. Issues [#1492](https://github.com/MedakaLang/medaka/issues/1492) and #1497 remain **OPEN** on the tracker (closing them is not this doc edit's call), but neither issue's own repro, nor this row's own fixtures, reproduce a run/build divergence on this tree any more; [#1493](https://github.com/MedakaLang/medaka/issues/1493) (the PRELUDE-INTERNAL sibling) is **CLOSED**. **No mechanism is asserted** for why the prior divergence closed (see the ⚠️ under S1-PRELUDE's Conformance: the partial-application account was already measured false, and no replacement account is offered here). 🚨 **STILL NOT CAPTURABLE as an engine-recorded golden** — even though the arms currently agree, per this document's own corpus rule (`WT-GOLDEN-ENSHRINES`) a captured golden records what an engine DID, and this cell's own history (a silent divergence existed once, unnoticed, until #1497 was filed) is the argument against ever letting one arm's output alone stand as this cell's ground truth. It is graded by `x4`/`x5`'s hand-derived `ALL_EXACT` run+build-agreement assertions instead, never a capture |

**Tally — DERIVE IT, do not read it.** The status distribution moves with every
row added, and the figure this line used to carry
(`26 OK · 0 BUG · 0 GAP · 0 UNVERIFIED · 3 UNTESTED-NO-FIXTURE`) was wrong on
**four** of its five counts **before** this section grew — measured against the
table as it stood at `adb789ca`, i.e. with none of rows 33–45 in it. It
under-counted `OK` by **eight** (34, not 26); it omitted row 9c's `KNOWN-BAD`
from every bucket, so that row was in no count at all; it claimed
`3 UNTESTED-NO-FIXTURE` for rows 21–23, which have had fixtures since
2026-07-16 (§4 carries the same stale claim, corrected there); and its `0 BUG`
is addressed on its own below. A tally is an encoded fact with no derivation
and no expiry, sitting one command away from the table it summarises:

```sh
awk -F'|' '/^\| *[0-9]/ { s=$10; gsub(/[^A-Za-z-]/," ",s); sub(/^ +/,"",s);
                          split(s,a," "); print a[1] }' \
    docs/spec/SHADOW-SEMANTICS.md | sort | uniq -c
```

⚠️ **Classify on the status cell's FIRST word, as that command does — not on
whether the cell contains a keyword.** Several cells *discuss* a `BUG` or a
`KNOWN-BAD` elsewhere in the same prose (row 45 points at a still-ledgered
import-order pin), so a substring count over the whole cell over-reports both.
That is the same failure this table's own history records one level up: a count
taken by the easiest available method rather than by the one that answers the
question.

At **2026-08-10** the command above reads: **45 OK · 1 BUG (row 39, #1430) ·
2 KNOWN-BAD (rows 9c and 42) · 1 UNREACHABLE · 2 baselines — 51 rows** —
recorded as a dated observation, not as a number this page maintains.

> ⚠️ **`0 BUG` IS NO LONGER TRUE, AND THAT IS THE POINT OF ROW 39.** The tally
> read `0 BUG` while [#1430](https://github.com/MedakaLang/medaka/issues/1430)
> was open — a definer shadow of a **return-position** method giving `check`
> accept, `run` `777` and `build` an E-PANIC, three verbs and three answers.
> It stayed invisible here because its fixture lives in
> `test/must_fail_fixtures/`, not in `test/shadow_fixtures/`, so the gate that
> enforces **this** table is green over it. **A cell with no row in this matrix
> is not a cell this matrix grades**, whatever its tally says.
>
> ⚠️ **UPDATE 2026-08-28 — #1430 is FIXED and row 39 now reads OK, so the tally
> above is stale in the OTHER direction; it is left as its dated observation.**
> The lesson does not change: the cell had no row in `test/shadow_fixtures/` for as long
> as it was broken, so the gate that enforces this table could not see it either
> way. It now has one — **D25**
> (`test/shadow_fixtures/d25_definer_return_pos_nameable/`), the discriminating
> twin of D24. Before it, the corpus's ONLY two return-position cells (D24, I21)
> were both NOT-nameable, i.e. both green because S1 declines to classify and S2
> is never reached. Re-run the command above rather than trusting either number.

> ⚠️ **Row 41 is a live disagreement between this clause set and two fixture
> headers, and it is recorded rather than harmonised.** `i18`'s header asserts
> the module-alias cell *"should"* answer `99`, reasoning from S1-NS (a)(i)
> alone; `i15`'s `bare.mdk` header asserts the alias *"MUST admit the whole
> row"*, reasoning from (a)(ii), and cites a closed S0 (#1277) that regressed
> when the alias arm was dropped. **(a) is a union of the two arms, so the
> second reading is the one the clause states** and the pinned `7` is
> conformant. Nothing here changes a value or a pin: the defect is a comment
> claiming a non-conformance the clause does not support, which is the shape
> this document's own §2 preamble was written about. **Owed:** correct `i18`'s
> header, or rule the alias arm out of (a)(ii) — one or the other, not neither.

> ### 🕳️ THIS MATRIX GRADED NOTHING ABOUT S1's SCOPE UNTIL 2026-08-08. Rows 33–45 are that gap being closed — read what they still do NOT cover.
>
> **Until rows 33–45 existed, no unit in `test/shadow_fixtures/` put the shadowed
> interface outside the occurrence module's nameable set** (§1.0), so **no row
> discriminated S1's scope from the graph-global reading of the same clause** —
> and a green `diff_compiler_shadow_semantics` was not evidence about the ruling.
> Derived, not assumed, over rows 3–32: every `d*` unit there is single-file, so
> nameable-in-`M` and graph-global coincide by construction;
> `i1`/`i6`/`i6b`/`i7`/`i8`/`i9`/`i10` declare the interface in `main.mdk`
> itself; `i3` and `d8` import it by name; `i4`/`i5` shadow prelude `Foldable`
> and `i11` prelude `Display`.
>
> **Measured, not inferred** (2026-08-06, `1443870c`, i.e. *before* the block
> above landed): the corpus as it then stood graded **byte-identically** whether
> S1's operands were scoped or graph-global — the same assertion count under
> each, with the two logs `diff`-identical. That measurement is the reason this
> note exists, and it is **not** superseded by rows 33–45; it is what those rows
> were written against. ⚠️ **Fixture UNITS and gate ASSERTIONS are different
> numbers** (assertions are units plus the coverage self-audit, and a
> multi-file unit contributes one row per graded `.mdk`), **and neither is a
> count to trust from this page.** Derive them: `ls test/shadow_fixtures/ | wc -l`
> and the `ok   coverage:` line the gate prints. (A figure of *17* has circulated
> for this corpus. It is wrong, and it is not a stale-but-once-true number — do
> not reintroduce it.)
>
> **What rows 33–45 now grade, and what they do not.**
>
> - ✅ **Reachability (#1353's axis, the ruling's own).** Rows 33–35 —
>   transitive-only, and the one-hop form where the interface's module *is*
>   imported under a member list that binds another name. [#1353](https://github.com/MedakaLang/medaka/issues/1353)
>   is **CLOSED**; its must-fail pin was drained and deleted, and row 33 is what
>   replaced it. The mechanism it was filed on, recorded because §3's own
>   S1-detect row is marked stale about it: the Module-path shadow test reads
>   `crossRun.value.universeIfaceMethodsRef`, grown per module by
>   `appendUniverseAccums`'s call to `allIfaceMethodNames` — which carries **no
>   `pub` filter** — accumulated **cumulatively in the loader's dependency-first
>   topological order**, the same shape `DICT-SEMANTICS.md` §8 I5 records for the
>   impl universe. The **feeder** is still unfiltered; what changed is that the
>   **result** is now intersected with the nameable set (§3).
> - ✅ **The namespace axis (S1-NS).** Rows 36–38 and 40–42 — sibling method,
>   return position, re-export by method name, module alias, member alias.
> - ✅ **The re-export chain (S1-CHAIN / #1380), including its SILENT half.**
>   Rows 43–44. S1-CHAIN's own 🕳️ paragraph recorded the silent half as
>   ungradeable by this corpus and enumerated why every importer unit then
>   present landed in the loud half; row 44 is the cell it said was missing.
> - ❌ **NOT graded: whether a PRELUDE standalone can be S1's LEFT operand.**
>   S1-SCOPE's "not ruled" item 2, still open. Every unit in this corpus has a
>   standalone that is local or explicitly imported, so nothing here exercises
>   it — the corpus is blind to that axis exactly as it was blind to this one.
>   ⚠️ Adjacent and **not** the same question, but the nearest live evidence
>   that the flat/prelude scoping boundary is load-bearing:
>   [#1191](https://github.com/MedakaLang/medaka/issues/1191) (OPEN), a user
>   binding colliding with a **prelude standalone** — no interface anywhere, so
>   S1 does not reach it — rejected on the zero-import single-file path against
>   the *prelude's* scheme. Pinned at
>   `test/must_fail_fixtures/1191-prelude-standalone-collision/`.
> - ❌ **NOT graded: export visibility (#1302's axis) — and it is not clear this
>   matrix is where it belongs.** [#1302](https://github.com/MedakaLang/medaka/issues/1302)'s
>   own filed repro does not exercise S1's shadow-hood conjunct at all (see the
>   ⚠️ under S1: its `mth` is an impl method, never a standalone `DFunDef`, so
>   `funDef-names ∩ iface-method-names` is vacuously false there **regardless of
>   how the interface operand is scoped**). A genuine S1-shaped export-visibility
>   row would need a *different* program — a real definer/importer shadow where
>   the interface lives in a module `M` imports **directly** but the interface's
>   declaration is not exported along that import — and whether such a shape
>   reproduces anything wrong today is **unverified**. It is also a distinct
>   question from #1302's actual mechanism (a wildcard import surfacing a private
>   interface's methods to the **impl-obligation** check). Not a chain case
>   either: the chain arm is **RULED IN SCOPE** (S1-CHAIN, #1380), and
>   S1-SCOPE's "not ruled" item 1 is narrowed to the sub-predicate. Owed to
>   whoever picks up #1302's actual mechanism.
>
> **The lesson stands even though the gap is closed, and it is the reason the ❌
> bullets above are written out rather than left implicit.** Row 32 graded green
> on a *broken* binary because every unit then used an annotated or literal
> receiver; rows 27–28 graded green over a real break because every importer unit
> then used a grounded receiver; rows 33–45 were absent while the clause they
> grade was being ruled. **Three times this corpus has been green over a cell
> nothing in it could express.** The remedy is never a bigger corpus — a corpus
> that cannot discriminate a ruling grades it exactly as well at 49 units as at
> 17, which is *not at all*. **Name the axis you are not varying.**
>
> ⚠️ **Two units in this corpus still have no row above**, and neither is a
> nameability cell: `i6b_importer_value_pos_arity_differ_unannot/` and
> `d18b_definer_value_pos_string_elem.mdk` are unannotated/element-type siblings
> of rows 21a and 9c. They are graded by the gate; they are simply not called out
> here. Derive the set rather than trusting this sentence — every unit the gate
> grades is in its own table, and its coverage self-audit fails if one is not.

> ### ⚠️ **A LOW `BUG` COUNT DOES NOT MEAN "NO VIOLATIONS". READ THE GAP AND UNVERIFIED COLUMNS.**
>
> *(This heading read `0 BUG` until 2026-08-10. The tally is no longer zero —
> row 39 / #1430 — but the lesson below was always about what the column
> **cannot** see, so it applies at any count.)*
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
| S1 detect (run/check, definer) | 🔴 **STALE — re-verified 2026-08-07, wrong on the Module path.** `buildDefinerShadows` is the FLAT-path function; on the MODULE (multi-module) path the reader is `definerShadowsFromSet`, keyed on `crossRun.value.universeIfaceMethodsRef` (grown by `appendUniverseAccums` → `allIfaceMethodNames`) — not the symbols or line numbers this cell names. Line numbers are additionally untrusted per this table's own preamble | this module's funDefs that name a method | **bare-name intersection, but NOT via `accData`/`publicDataDecls` — those are DEAD on the Module path** (`fullUniverse` binds `[]` there; an in-source comment calls the old accData concat "a dead per-module O(N) concat"). The real feeder, `allIfaceMethodNames`, has **no `pub` filter** (sees a private interface's methods too — the opposite of what "public decls" implies) and is accumulated **cumulatively in the loader's dependency-first topological order**, not filtered by import reachability — the same shape as `DICT-SEMANTICS.md` §8 I5's "PARTIAL — cumulative, not global" row for the impl universe. This is the mechanism behind #1375's reachability axis; see row-14 BUG. ⚠️ **The FEEDER is still unfiltered; the RESULT no longer is (S1-NS / #1353, 2026-08-08).** `checkBodyImpl` now wraps *both* `definerShadowsFromSet` and `standaloneShadowsFromSet` in `nameableIfaceShadows`, which intersects the answer with `nameableIfaceMethodSet` — the methods of the interfaces that module can NAME. So this cell describes the operand, not the answer |
| S1 detect (run/check, importer) | `typecheck.mdk:17020` `buildStandaloneShadowsGraph` | imported standalones shadowing a method | imported funDef names minus local names, methods scanned across `implDecls ++ prog` (the `cfc4fa5a` fix: LOCAL interfaces included) |
| S1 detect (build path) | `typecheck.mdk:11475` `computeMangledShadowMap` + `unitMangledShadows:11480`, set once at `elaborateModules:11932` (`mangledShadowMapRef`); consumed by `buildDefinerShadows:11460` and `buildStandaloneShadowsGraph:11487-11497` | recover shadows AFTER mangling renamed the standalone | **forward-constructs `mangledName mid m`** per (module, method) and checks it against actual funDefs — exact, not prefix-stripping; empty map on the un-mangled path (inert) |
| S1 mark | `typecheck.mdk:11942` `markRpNames` (∪ `buildStandaloneShadowsGraph`) → `prePassDictArg`/`prePassModulePairArg:11943-11944` rewrite occurrences to `EMethodAt` | occurrences get a route ref | graph-wide name set over USER modules (core excluded). ⚠️ **NO LONGER graph-wide on the Module path (S1-NS / #1353, 2026-08-08).** `markRpNames` is still what `core` is marked with, but each USER module goes through `prePassModulePairArg`, which filters four of its five inputs — `rpNames`, the graph shadow set (through `shadowBareName`), `argNames` and `shadowMap` — to `nameableIfaceMethodSet` for *that* module. `dictNames` is the one input left unfiltered, and is not an input to dispatch (it yields `EDictAt`) |
| (enabler of the S1 build split) | `compiler/backend/private_mangle.mdk`: `mangleUnits:117`, `buildUnitRenameMap:372`, `renameDecl` DFunDef `~578` + `renameScoped` EVar `~651` rename the standalone def + refs to `<mid>__N`; `renameIfaceMethod:626`/`renameImplMethod:636` leave the method **NAME bare** (header `:34-46`: dispatch is by bare name cross-module) | collision-free private symbols | **the asymmetry**: standalone side mangled, method side bare — which is exactly what defeated name-intersection detection (bug `0b4a7882`); driver order `compiler/entries/entry_support.mdk:133-134` (`runEmitWith`) and `:145-146` (`emitModulesWith`): mangle STRICTLY before mark |
| S2 type + record (definer) | app-head peel → `definerShadowArgHead` (definer disjunct gated `ifaceMethodName`, fires on `definerShadowNamesRef`; importer-on-emit disjunct gated `singleTyparamIfaceMethod`, fires on a mark-seeded `RLocal sym` — the cross-module emit signal) → `inferDefinerShadowApp` + `definerShadowHeadType`. The un-marked `check` path peels via `definerShadowVarHead` → `inferDefinerShadowVarApp`. **`definerReceiverDispatches` is the single decision point** | **[CHANGED — THE INVERSION]** a definer shadow types against the STANDALONE scheme, **always** (via the mangled sym on build — the scheme-selection SIGSEGV fix); `enforceStandaloneDomain` then imposes its declared domain, so a live-impl receiver is a located reject. The only dispatch arm left is S5's dict-bound receiver | ⚠️ **`definerShadowArgHead` fires for IMPORTER shadows too** — its `routeLocalSym /= ""` arm is the cross-module emit signal, so `inferDefinerShadowApp` serves BOTH kinds on the mangled path. "Did we reach this function" is therefore **NOT** the same question as "is this a definer shadow": `definerReceiverDispatches` must re-ask it via `isDefinerShadow` (`definerShadowNamesRef` never holds an imported standalone) or the inversion leaks onto importers and breaks `import map` |
| S2 type + record (importer) | `typecheck.mdk:4950` `shadowStandaloneHead` → `inferShadowApp:4979`; standalone schemes stashed in `shadowStandaloneSchemesRef` (`checkModuleFullImpl:11210`, concrete-head pick); impl existence query `ieImplExistsForHead` over the graph-global `bodyImplEnvRef` (ARCH B-2.1-g; its per-module prefix predecessor shadowKeyTableRef was deleted by B-2.1-d) | live-impl head ⇒ ordinary app (dispatch); else instantiate the IMPORTED standalone scheme + stamp `RLocal` | standalone scheme = the seedVars entry whose first arrow domain has a **concrete head tycon** (never the poly method scheme) |
| **S4 value-position pin** | check: `maybeStandaloneValueMono` (`typecheck.mdk`); build: `maybeStandaloneValueMonoEmit` via `inferMethodAt` — gated by **`emitValueShadowGate`** | a bare value-position shadow (`map size xs`, not an app head) denotes the STANDALONE: pin its TYPE to the standalone scheme (`Int -> Int`) so a HOF grounds the element concretely, instead of the permissive method scheme (`a -> i -> Int`, a function) whose `Display (List (Int -> Int))` stamps a **NULL element dict → SIGSEGV** (#410/#669 single-typaram; **#724 multi-typaram**) | **[#724] gated PER SHADOW KIND on BOTH paths** — DEFINER arm typaram-agnostic (`isDefinerShadow`, i.e. `contains name definerShadowNamesRef`), IMPORTER arm `singleTyparamIfaceMethod` (Fork 1). Before #724 the check path was already per-kind (definer typaram-agnostic) but the emit path used ONE blanket `singleTyparamIfaceMethod`, so a **multi-typaram definer value position** grounded on check yet DECLINED on emit → the #410 skew at multi-typaram width. ⚠️ the emit classifier is **`isDefinerShadow`, NOT `shadowStandaloneSchemesRef` membership** — that ref is `standaloneSchemeFor`'s scheme-SOURCE selector and an importer occurrence is not reliably in it at this pin, so keying on it mis-grounds the i10 multi-typaram importer app head to a garbage-pointer build. App heads never reach the pin as value positions: a definer app head is bracketed `shadowHeadCtxRef` True by `inferDefinerShadowApp`. Fixtures: `d22`/`d22b` (multi-typaram definer value position), `d22z` (app-head control) |
| S2 no-impl obligation skip | `typecheck.mdk:4670` `recordImplObligation`, skip arm `:4688` | a no-impl shadow receiver is a legitimate standalone fallback, not `No impl of …` | bare name ∈ `definerShadowNamesRef` ∪ `standaloneValuesRef` — skips the obligation for EVERY occurrence of the name, impl-having or not (this un-checks row 13: the domain mismatch is never re-imposed) |
| S2/S3/S5 route stamping | `recordRLocalSite` (gated on `standaloneValuesRef`, suppressed inside `inferDefinerShadowApp`); `resolveRLocalSites` / `resolveRLocalSite`: **`isDefinerShadow` ⇒ `RLocal sym` unconditionally**, else (importer) grounded head + `implExistsForHead` → leave route (dispatch) else `RLocal sym` (`stampRLocalOrFallback`); ungrounded → `RLocal` for definer shadows; build-path RKey via `pendingArgStamps` push → `resolveArgStamps` | **[CHANGED — THE INVERSION]** route by SHADOW KIND first, receiver second. `resolveArgStamps` runs BEFORE `resolveRLocalSites`, so the `RLocal` stamp wins | ⚠️ **`isDefinerShadow` carries the SAME gate as every typing entry point** (`ifaceMethodName` since #54; it was the typaram-count test `singleParamIfaceMethod`, whose mismatch with nothing else was S-3 / row 26). Routing here on a gate the typing entry points do not share routes a site whose TYPE came from the dispatch path — **route and type disagreeing is precisely the P0-20 bug class.** The two gates must stay identical |
| **S2-DECL** receiver argument + impl query | check/run: `methodDispatchIdx` → `recordRLocalSite` → `resolveRLocalSite` → `implExistsForHead`. build: `definerShadowArgHead`'s importer disjunct (`importerShadowOnEmitPath`) → `inferDefinerShadowApp`, which sets `suppressRLocalRecord` and peels the application's FIRST argument | which argument is the receiver, and whose impls answer the query | 🔴 **NON-CONFORMANT on BOTH arms, for DIFFERENT reasons — MEASURED 2026-08-09 ([#1351](https://github.com/MedakaLang/medaka/issues/1351)).** check/run keys the receiver position on the **bare method name** (first-match over a graph-global accumulator, so import-clause order decides) while the occurrence's TYPE comes from `methodIfaceParamsRef` — same key, **opposite** tie-break — so with two colliding declarations the two name different ones by construction (S2-DECL (b), (e)). build reads **no** dispatch-index table at all: the receiver is argument 0, positionally (S2-DECL (a)). `implExistsForHead` is keyed `(method name, head tycon)` with no interface, so it can answer about an impl of a declaration the module cannot name (S2-DECL (c)). ⚠️ **The two arms are independent**: re-deriving either dispatch-index table moves `run` and leaves the built binary where it was — an **S7** violation, not a partial fix |
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
  (2026-07-17). **Two KNOWN-BAD rows are open:** `d18` (row 9c, a #410 residual —
  `build` ships a binary that SEGFAULTs while `run` is correct) and
  `i22_importer_member_alias_not_nameable/main.mdk` (row 42, the member-alias
  cell, pinned to `7` where S1-NS (a)(ii) specifies `99`, with its own `bare.mdk`
  sibling as the discriminator). ⚠️ **A KNOWN-BAD row is not the only way a cell
  can be non-conformant and still green here** — row 39 ([#1430](https://github.com/MedakaLang/medaka/issues/1430),
  OPEN S0) is pinned in `test/must_fail_fixtures/`, **not** in
  `test/shadow_fixtures/`, so this gate is green over it and the coverage
  self-audit below cannot see it either: the audit checks that every fixture in
  *this* directory has a row, never that every cell in §2 has a fixture *here*.

CI: the `types` shard (`.github/workflows/ci.yml`); `diff_compiler_ci_shard_coverage`
enforces that it is in exactly one shard.

⚠️ **This paragraph read *"Still UNTESTED-NO-FIXTURE (rows 21–23): importer
value-position, importer N-way, and a return-position method shadow"* until
2026-08-10. All three got fixtures on 2026-07-16 while fixing #411** — rows 21a,
21b, 22, 23a and 23b in §2 name them — so the claim had been false for
three-and-a-half weeks, and §2's tally still carried its `3 UNTESTED-NO-FIXTURE`
bucket for the same rows. **There is no UNTESTED-NO-FIXTURE cell left in §2**;
derive the status distribution from the table itself rather than from a
sentence here (the command is under §2's tally).

The mechanical step it described still holds for any *new* cell: the gate picks
a fixture up automatically once a row is added to its own table, and its
coverage audit fails until one is.

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
   definer-shadow app path or its impl-existence query doesn't span
   the imported impl universe for a LOCAL standalone. (That query was then the
   per-module prefix table shadowKeyTableRef, deleted by ARCH B-2.1-d; it is now
   `ieImplExistsForHead` over the graph-global `bodyImplEnvRef`.)

Rows 12 and 13 are **silent build soundness holes** (check accepts, binary
prints garbage) — the same severity class as the original P0-18 build hole, and
strong candidates for the next fix batch, with rows 10/14 folded in as the
same "which stage owns S4/S6" decision.

> **✅ UPDATE (2026-07-10, `ef0874f3` — P0-19 batch 1):** rows **12 (d5b)** and **13
> (d9)** are FIXED — both now `check`/`run`/`build` REJECT with a located
> `Type mismatch` (`enforceStandaloneDomain` re-imposes the standalone's declared
> domain whenever a definer-shadow occurrence resolves to the standalone, on both
> the marked run/build path and a new un-marked `EVar` check path; gated by
> the impl-existence query (then shadowKeyTableRef, now `ieImplExistsForHead`) so
> live-impl receivers still dispatch). Regression fixtures
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
> (run+build print `3`,`4`, matching d2): the impl-existence table (then
> shadowKeyTableRef) seeded from the global
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
