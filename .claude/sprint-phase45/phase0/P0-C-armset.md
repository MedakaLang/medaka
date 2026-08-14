# P0-C — Q7: the `_ => None` ARM SET

**Analyst:** packet P0-C (read-only). **Worktree:** `/root/medaka/.claude/worktrees/peppy-brewing-kitten`
**BASE pinned:** `aaa437167b633d6070adccd055c8c2a19e9bb8c6` (`git rev-parse HEAD` at task start).
Every `file:line` below was re-derived at that commit with `grep -nw` / `sed -n '<line>p'`, never
quoted from the sprint doc.

> ## 🚨 HEADLINE FINDING (up front, because it changes the answer)
>
> **The sprint doc's set of THREE is WRONG on both halves.**
>
> 1. On the **`Ty`** side the catch-all swallows **FIVE** constructors, not three:
>    `TyVar`, `TyFun`, `TyEffect`, `TyConstrained`, **`TyRow`**. `TyRow` is a real
>    `Ty` constructor (added by #997 for a bare row in a type-ARGUMENT slot,
>    `compiler/frontend/ast.mdk:574`) and it is named **nowhere** in the sprint doc,
>    in #1617, or in #1618. Discounting `TyVar` (deliberate, documented, load-bearing
>    for #1128/F-3b), the **defect set is FOUR: `TyFun`, `TyEffect`, `TyConstrained`, `TyRow`.**
> 2. On the **`Mono`** side there is **no `TyConstrained` analogue at all** — `Mono` has
>    six constructors and constraints are not one of them. The Mono catch-all swallows
>    `TVar`, `TFun`, `TEff`; the defect set there is **TWO: `TFun`, `TEff`.**
>
> So "three" is neither the Ty count nor the Mono count. It is a list assembled from
> two different types' constructor sets, and it is one member short on the `Ty` side.
> **This is Phase 3′'s "shipped a set one arm short" repeating.**

---

## A. The head-function family, enumerated

### A.0 How the set was derived (not inherited)

Started from the three names in the brief, then grepped for the *shape* rather than the
name, over the worktree only:

```sh
grep -rnE '^head[A-Za-z]* :|^[a-zA-Z_]*[Hh]ead[A-Za-z]* :' --include=*.mdk compiler/ stdlib/
grep -rn "headTycon" --include=*.mdk compiler/ stdlib/
```

That returns ~120 `*Head*` signatures. Filtering to *"maps a **type** (`Ty`/`Mono`) to a
head tycon / head tag"* — i.e. excluding pattern-matrix heads (`exhaust.headCtors`), CExpr /
CHead heads (`llvm_emit.conHeadInfo`, `wasm_emit.fstConHead`), expression spine heads
(`parser.spineHead`, `lint.appSpineHead`), and impl-declaration heads that take a `Decl`
(`implHeadGround`) — leaves the family below. Two extras that the brief does not name and
that DO match the shape are included and flagged.

### A.1 `eval.headTycon` — `Ty -> Option String`

**Definition:** `compiler/eval/eval.mdk:513`. Proof (`sed -n '513,519p'`):

```
headTycon : Ty -> Option String
headTycon (TyCon { tyConName = n }) = Some n
headTycon (TyApp a _) = headTycon a
headTycon (TyConstrained _ t) = headTycon t
headTycon (TyEffect _ _ t) = headTycon t
headTycon (TyTuple ts) = Some (tupleHeadTag (listLen ts))
headTycon _ = None
```

- **Arms matched:** `TyCon`, `TyApp` (spine recursion), `TyConstrained` (**strips**),
  `TyEffect` (**strips**), `TyTuple`.
- **Catch-all:** `headTycon _ = None` (`:519`).
- **Not exported.** No `export` keyword on `:513`; `grep -nw headTycon compiler/eval/eval.mdk`
  returns only `:513–519` (its own def/recursion) and `:1982`.
- **Call sites (whole tree, word-bounded):** exactly one non-recursive —
  `compiler/eval/eval.mdk:1982` (`headTyconHead (t::_) = headTycon t`).
- **Defined in:** `compiler/eval/eval.mdk`. **Imported by:** nobody (private).

### A.2 `eval.headTyconHead` — `List Ty -> Option String`

**Definition:** `compiler/eval/eval.mdk:1980`. Proof (`sed -n '1980,1982p'`):

```
export headTyconHead : List Ty -> Option String
headTyconHead [] = None
headTyconHead (t::_) = headTycon t
```

- **Arms:** `[]` → `None`; `(t::_)` → delegates to `headTycon`. It is a *list* projection —
  it adds a second `None` source ("empty head list") on top of `headTycon`'s catch-all, and
  both collapse into the same `noneHeadTag` at every consumer (see below).
- **Exported** (`:1980`). **Imported by** `compiler/ir/core_ir_lower.mdk:65` — proof:
  `sed -n '65p'` → `  headTyconHead,`.
- **Call sites** (`grep -rnw headTyconHead --include=*.mdk compiler/`, comment lines dropped):

| site | code |
|---|---|
| `compiler/eval/eval.mdk:309` | `declImplIfaceIdRow (DImpl {…}) = [(ifaceIdentity o ifaceName, fromOption noneHeadTag (headTyconHead typeArgs), implRouteKeyWord o ifaceName typeArgs None)]` |
| `compiler/eval/eval.mdk:378` | `implMethodReqCounts arities (DImpl { tys = typeArgs, methods, ... }) = match headTyconHead typeArgs` |
| `compiler/eval/eval.mdk:1974` | `  let tag = fromOption noneHeadTag (headTyconHead typeArgs)` |
| `compiler/ir/core_ir_lower.mdk:1306` | `ifaceImplHeadEntries (DImpl {…}) = [(ifaceIdentity o ifaceName, ifaceName, fromOption noneHeadTag (headTyconHead typeArgs), implRouteKeyWord o ifaceName typeArgs None)]` |
| `compiler/ir/core_ir_lower.mdk:1407` | `  let tag = fromOption noneHeadTag (headTyconHead typeArgs)` |

All five funnel `None` into `noneHeadTag` — i.e. **the swallowed shapes are not merely
"absent", they are actively COLLAPSED INTO ONE BUCKET** with each other and with the
empty-list case.

### A.3 `typecheck.headTyNode` — `Ty -> Ty` (the shared spine walk)

**Definition:** `compiler/types/typecheck.mdk:19433`. Proof (`sed -n '19433,19435p'`):

```
headTyNode : Ty -> Ty
headTyNode (TyApp a _) = headTyNode a
headTyNode t = t
```

Total, allocation-free. **It is `TyApp`-only** — it does *not* strip `TyEffect` /
`TyConstrained`, which is the precise mechanical reason A.4/A.5 below diverge from
`eval.headTycon`. Both `headTyconTy` and `headTyconNameTy` are written against it, so the
spine walk cannot drift between them; the **classification** of the returned node is what
differs, and that is where the arm set lives.

### A.4 `typecheck.headTyconTy` — `Ty -> Option HeadKey` (IMPL side of the dispatch key)

**Definition:** `compiler/types/typecheck.mdk:19452`. Proof (`sed -n '19452,19456p'`):

```
headTyconTy : Ty -> Option HeadKey
headTyconTy t = match headTyNode t
  TyCon { tyConName = n, tyConOrigin = o } => Some (headKeyOfCon o n)
  TyTuple ts => Some (headKeyOfCon OriginBuiltin (tupleHeadTagTc (listLen ts)))
  _ => None
```

- **Arms:** `TyCon`, `TyTuple`. **Catch-all:** `_ => None` (`:19456`).
- **Call sites** (`grep -nw headTyconTy … | grep -vE '^[0-9]+:[[:space:]]*--' | grep -vE '^[0-9]+:headTyconTy'`):
  - `:18413` — `KeyEntry (map implMethodNameTc methods) (headTyconTy headTy) headTy (implKeyTc iface tys) iface tys reqs 0`
  - `:19100` — `KeyEntry ms (headTyconTy headTy) headTy (implKeyTc ir.irName tys) ir.irName tys reqs (instRefSeq inst)`
  - `:22574` — `univReceiverTag (headTy::_) = headTyconTy headTy`
- **Defined in and used only from** `compiler/types/typecheck.mdk` (the tree-wide
  `grep -rn headTyconTy --include=*.mdk` hits outside that file are all comments in
  `compiler/types/registry.mdk`, `compiler/frontend/resolve.mdk:3818` and test fixtures — no
  call sites). **No module imports it.**

  ⚠️ **This contradicts nothing in the ruling but it does narrow it:** the ruling says the
  arm set "spans `typecheck.mdk` **and** `eval.mdk` … **and** `core_ir_lower.mdk`". True —
  but the cross-module edge is `headTyconHead` (A.2), *not* `headTyconTy`. `headTyconTy` is
  file-local.

### A.5 `typecheck.headTyconNameTy` — `Ty -> Option String` (bare-name residual)

**Definition:** `compiler/types/typecheck.mdk:19479`. Proof (`sed -n '19479,19483p'`):

```
headTyconNameTy : Ty -> Option String
headTyconNameTy t = match headTyNode t
  TyCon { tyConName = n } => Some n
  TyTuple ts => Some (tupleHeadTagTc (listLen ts))
  _ => None
```

- **Same two arms, same catch-all** (`:19483`). Deliberately duplicated rather than
  `map headKeyName (headTyconTy t)` — the doc-comment at `:19472–19478` gives the perf
  reason and explicitly states the invariant: *"these three arms … must classify the same
  head nodes"*.
- **Call sites:** `:18200`, `:20112`, `:23056` — all `match headTyconNameTy headTy`.
- File-local, not exported.

### A.6 `typecheck.headMonoNode` — `Mono -> Mono` (the Mono spine walk)

**Definition:** `compiler/types/typecheck.mdk:20814`. Proof (`sed -n '20814,20817p'`):

```
headMonoNode : Mono -> Mono
headMonoNode t = match normalize t
  TApp a _ => headMonoNode a
  other => other
```

`normalize`-at-every-level, `TApp`-only recursion. Same structural role as A.3.

### A.7 `typecheck.headTyconMono` — `Mono -> Option HeadKey` (GOAL side of the dispatch key)

**Definition:** `compiler/types/typecheck.mdk:20847`. Proof (`sed -n '20847,20849p'` + `'20862,20863p'`):

```
headTyconMono : Mono -> Option HeadKey
headTyconMono t = match headMonoNode t
  TCon n o => Some (headKeyOfCon o n)
  …
  TRigid n => Some (HkRigid n)
  _ => None
```

- **Arms:** `TCon`, `TRigid` (the latter flagged in-source as *"ANSWER-PRESERVING, NOT
  CORRECT"* — the residual §8 I6.1 violation). **Catch-all:** `_ => None` at `:20863`.
- **Call sites (13):** `:9919`, `:10118`, `:10136`, `:11655`, `:11953`, `:15522`, `:15828`,
  `:18609` (`goalHeadCon`), `:19961`, `:22587`, `:22598`, `:22828`, `:23219`.
- File-local, not exported.

### A.8 `typecheck.headTyconNameMono` — `Mono -> Option String` (bare-name residual)

**Definition:** `compiler/types/typecheck.mdk:20883`. Proof (`sed -n '20883,20887p'`):

```
headTyconNameMono : Mono -> Option String
headTyconNameMono t = match headMonoNode t
  TCon n _ => Some n
  TRigid n => Some n
  _ => None
```

- Same two arms, catch-all at `:20887`. Its own doc-comment (`:20878–20882`) already states
  the hazard verbatim: *"a new `Mono` head constructor is owed an arm in both (both fall
  through `_ => None`, which is exactly the wildcard hazard `AGENTS.md` names — audit them
  as a SET)."*
- **Call sites (18):** `:6974`, `:9813`, `:10973`, `:12066`, `:12662`, `:12719`, `:12822`,
  `:13251`, `:14155`, `:14357`, `:15670`, `:19616`, `:19854`, `:20353`, `:23030`, `:23322`,
  `:23523`, `:26011`.

### A.9 Two derived wrappers that inherit the arm set (named for completeness)

| wrapper | `file:line` | what it inherits |
|---|---|---|
| `goalHeadCon : List Mono -> Option HeadKey` | `compiler/types/typecheck.mdk:18608` (`:18609` = `goalHeadCon (g::_) = headTyconMono g`) | exactly `headTyconMono`'s arm set, plus a second `None` for the empty list |
| `univReceiverTag : List Ty -> Option HeadKey` | `compiler/types/typecheck.mdk:22574` (`univReceiverTag (headTy::_) = headTyconTy headTy`) | exactly `headTyconTy`'s arm set, plus a second `None` for the empty list |

These are the `Ty`/`Mono` structural twins of `eval.headTyconHead` (A.2). **A fix to the
arm set propagates through them for free; no separate bite is needed** — but they are the
reason a fix's blast radius is larger than three definitions.

### A.10 Out of family — checked and excluded (so the SET claim is auditable)

- `compiler/ir/core_ir_lower.mdk:1639 tyHeadName : Ty -> String` and
  `compiler/tools/lint.mdk:1229 tyHeadName : Ty -> Option String` — these DO match the shape
  ("`Ty` → head name"), but neither is on a dispatch-key path (`core_ir_lower`'s is a field-type
  renderer via `fieldTyHeadName :1634`; `lint`'s is a lint rule). **Flagged, not silently
  dropped.** They have their own catch-alls and their own (independent) arm sets; a Phase 4
  table does not read them. See REFUSALS for what I did *not* audit about them.
- `compiler/types/typecheck.mdk:23295 spineHeadMono : Mono -> Mono` — returns a node, not a
  key; it is a third spine walk alongside A.3/A.6, not a classifier.
- `compiler/types/typecheck.mdk:13075 headAnnotTy : Ty -> Mono` — a converter, not a head
  projection.

---

## B. 🎯 The SET of swallowed shapes — derived from the `data` declarations

### B.1 `Ty` — the full constructor set

`public export data Ty =` at **`compiler/frontend/ast.mdk:508`**. Constructors, derived by
`sed -n '508,600p' compiler/frontend/ast.mdk | grep -n '^  | '` (relative offsets converted
to absolute):

| # | constructor | abs line |
|---|---|---|
| 1 | `TyCon { tyConName, tyConLoc, tyConOrigin }` | `:555` (record opens `:555`, closes `:559`) |
| 2 | `TyVar String` | `:560` |
| 3 | `TyApp Ty Ty` | `:561` |
| 4 | `TyFun Ty Ty` | `:562` |
| 5 | `TyTuple (List Ty)` | `:563` |
| 6 | `TyEffect (List (String, Option String)) (Option String) Ty` | `:564` |
| 7 | `TyConstrained (List Constraint) Ty` | `:565` |
| 8 | **`TyRow (List (String, Option String)) (Option String) (Option Loc)`** | **`:574`** |

Proof for the one nobody names (`sed -n '574p' compiler/frontend/ast.mdk`):

```
  | TyRow (List (String, Option String)) (Option String) (Option Loc)
```

and its own doc-comment, `:566–573`, says what it is: *"A row/grade written BARE in a
type-ARGUMENT slot (#997), e.g. the `<Stdout>` of `Async <Stdout> Unit`. Distinct from
`TyEffect` … because a bare row-argument atom wraps nothing"*.

**`Ty` has EIGHT constructors.** The sprint doc, #1617 and #1618 all reason as if it had
seven.

### B.2 Subtraction, per `Ty`-side function

`headTyNode` (A.3) consumes `TyApp` and *only* `TyApp`, so the head node handed to each
classifier ranges over the other **seven** constructors.

| constructor | `eval.headTycon` | `typecheck.headTyconTy` | `typecheck.headTyconNameTy` |
|---|---|---|---|
| `TyCon` | `Some n` | `Some (headKeyOfCon o n)` | `Some n` |
| `TyTuple` | `Some __tupleN__` | `Some __tupleN__` (`OriginBuiltin`) | `Some __tupleN__` |
| `TyApp` | recurses | (consumed by `headTyNode`) | (consumed by `headTyNode`) |
| `TyVar` | **`None`** | **`None`** | **`None`** |
| `TyFun` | **`None`** | **`None`** | **`None`** |
| `TyEffect` | **strips → inner head** | **`None`** ⚠️ | **`None`** ⚠️ |
| `TyConstrained` | **strips → inner head** | **`None`** ⚠️ | **`None`** ⚠️ |
| **`TyRow`** | **`None`** 🚨 | **`None`** 🚨 | **`None`** 🚨 |

**Swallowed by `headTyconTy` / `headTyconNameTy`: FIVE** — `TyVar`, `TyFun`, `TyEffect`,
`TyConstrained`, `TyRow`.
**Swallowed by `eval.headTycon`: THREE** — `TyVar`, `TyFun`, `TyRow`.

Discounting `TyVar` (see B.4), the **defect set on the `Ty` side is FOUR**, and the
divergence set between the two engines' `Ty`-side projections is **TWO**
(`TyEffect`, `TyConstrained`) — which is #1618's shape exactly, but the *shared blind spot*
`TyRow` is invisible to any eval-vs-typecheck differential because **both sides answer
`None` for it.**

🚨 **`TyRow` is therefore strictly worse than the two the tracker knows about:** the
`diff_compiler_engines` 3-engine differential structurally cannot see it, because all engines
are equally blind. That is the "all three agreeing does not prove correctness" shape
`AGENTS.md` warns about, instantiated.

### B.3 `Mono` — the full constructor set, and its subtraction

`public export data Mono =` at **`compiler/types/typecheck.mdk:205`**. Constructors, derived
by `sed -n '205,400p' … | grep -n '^  | '`:

| # | constructor | abs line |
|---|---|---|
| 1 | `TVar (Ref Tyvar)` | `:206` |
| 2 | `TCon String TyConOrigin` | `:207` |
| 3 | `TRigid String` | `:297` |
| 4 | `TApp Mono Mono` | `:337` |
| 5 | `TFun Mono EffRow Mono` | `:338` |
| 6 | `TEff EffRow` | `:340` |

**`Mono` has SIX constructors. There is no `TConstrained`** — constraints live in
`Predicate`/`Require`, not in `Mono`. **There is no `TRow`** — `TEff EffRow` is the single
row-carrying node.

`headMonoNode` (A.6) `normalize`s and consumes `TApp`; a `TVar` that is `Link`ed is followed
by `normalize`, so a surviving `TVar` at the head is an **`Unbound`** metavariable.

| constructor | `headTyconMono` | `headTyconNameMono` |
|---|---|---|
| `TCon` | `Some (headKeyOfCon o n)` | `Some n` |
| `TRigid` | `Some (HkRigid n)` (flagged "not correct") | `Some n` |
| `TApp` | (consumed by `headMonoNode`) | (consumed) |
| `TVar` (unbound) | **`None`** | **`None`** |
| `TFun` | **`None`** ⚠️ | **`None`** ⚠️ |
| `TEff` | **`None`** ⚠️ | **`None`** ⚠️ |

**Swallowed: THREE** — `TVar`, `TFun`, `TEff`. Discounting `TVar` (an unsolved metavariable
genuinely has no head yet — `None` is the correct answer and every consumer's RNone/dict-path
fallback depends on it), the **Mono defect set is TWO: `TFun`, `TEff`.**

### B.4 Which `None`s are CORRECT and which are the defect

- **`TyVar` / `Mono.TVar` → `None` is CORRECT and load-bearing.** A fully-general
  `impl C a` head IS a bare `TyVar`; `compiler/types/typecheck.mdk:18395` records this
  deliberately (proof, `sed -n '18395p'`):
  `-- #1128 (F-3b): a fully-general 'impl C a' head is a bare TyVar, so 'headTyconTy'`.
  Do **not** give these an arm.
- **`Mono.TRigid` → `Some` is the OPPOSITE defect** — an arm that answers where it should
  not (in-source: *"A rigid variable has no head type constructor, so handing its parameter
  name out as a bucket key is the residual violation"*, `:20850–20857`). It is already tracked
  (§8 I6.1, #1110) and is **not** part of Q7's arm set, but any fix touching these functions
  must not accidentally "clean it up" — that is a separate semantics PR by explicit ruling.
- **The genuine Q7 defect set** is therefore:
  - `Ty` side: **`TyFun`, `TyEffect`, `TyConstrained`, `TyRow`** (four).
  - `Mono` side: **`TFun`, `TEff`** (two).
  - Cross-engine divergence: **`TyEffect`, `TyConstrained`** (eval strips, typecheck drops).

---

## C. Cross-check against the three issues

Read at BASE with `gh issue view 1617/1618 --json …`, and the tracker searched with
`gh issue list --search "TyConstrained" --state all` and `--search "TyRow" --state all`.

### C.1 #1617 — OPEN, `S0: silent wrongness` + `verified` + `ws:typecheck`

**Title:** *"a function-typed impl head falls into the noneHeadTag bucket — run answers by
declaration order in BOTH permutations at exit 0, build E-PANICs"*.

**Mechanism, one sentence:** two `TyFun` impl heads (`Int -> Int`, `Bool -> Bool`) both hit
`headTyconTy`'s `_ => None` arm, so `univReceiverTag` returns `None`, `headBucketKey None =
headlessBucketKey` files both under one bucket, and nothing downstream can discriminate them.

**Confirmed: it IS the arm set.** The issue body names the arm explicitly and states the
generalisation itself — *"the arm really means **anything that is not a `TyCon` and not a
`TyTuple`**"* and *"the arms want auditing as a SET"*. My independent subtraction (§B.2) agrees
with that characterisation exactly, and extends it by one member.

### C.2 #1618 — OPEN, `S1: loud breakage` + `verified` + `ws:typecheck`

**Title:** *"an effect-carrying impl head checks clean and runs correctly but CANNOT BE BUILT —
eval strips the effect to a concrete head, typecheck does not"*.

**Mechanism, one sentence:** `impl Sz (<Stdout> Int)` has a `TyEffect` head; `eval.headTycon`'s
`TyEffect _ _ t => headTycon t` arm (`compiler/eval/eval.mdk:517`) strips to `Int` while
`headTyconTy` answers `None`, so the two projections file the SAME impl under two different tags
and the emitter looks up `__none__` and finds nothing.

**Confirmed: it IS the arm set** — specifically the *disagreement* between two members of the
family, not a single arm. Note the fix direction is genuinely different from #1617's: #1617 needs
an arm ADDED; #1618 needs two functions RECONCILED. Both issue bodies say so and dedup against
each other on exactly that. That distinction is real and survives my audit.

### C.3 `TyConstrained` — 🚨 THE SPRINT DOC INVERTS WHAT BOTH BODIES SAY

**Tracker search:** `gh issue list --search "TyConstrained" --state all` returns
#1026, #1618, #1617, #604, #610, #1113, #1110. **No issue owns `TyConstrained` as a head-arm
defect** — so *"unfiled"* is correct.

**But *"named in both bodies as the third member of the SET"* is BACKWARDS.** Both bodies name it
as a candidate that was **measured NOT to be a defect**, and both use that measurement to BOUND
the class at two. Verbatim:

- #1617, "Dedup": *"A **third** candidate arm, `TyConstrained`, was **measured NOT to be a
  defect** — the source asymmetry exists, but stripping a constraint yields a still-headless type,
  so both sides agree. **The live set is two.**"*
- #1618, "Dedup": *"A **third** candidate arm, `TyConstrained`, was **measured NOT to be a
  defect**: eval strips it too, but stripping a constraint yields a still-headless type, so both
  sides agree and nothing breaks. **That measurement is what bounds this class at two.**"*

The sprint doc (`.claude/STAGE-B-PHASE45-SPRINT.md`, OUT list) reads this as
*"It is named in both #1617's and #1618's bodies as the third member of the SET; whoever fixes the
arm set fixes all three."* — **it kept the citation and dropped the polarity.** Both bodies say
the opposite of what the doc attributes to them.

**Consequence for the sprint:** the doc's "three" is right in COUNT only by coincidence, and wrong
in MEMBERSHIP. The real third member is **`TyRow`**, which nothing in the tracker or the sprint doc
mentions in this context (`gh issue list --search "TyRow" --state all` returns #1090, #1028, #1094
— all about row *kinding*, none about the head arm set).

**⚠️ A second-order caution on the `TyConstrained` measurement itself.** Its stated REASON —
*"stripping a constraint yields a still-headless type"* — is not general. `TyConstrained cs t` is
`(cs => t)`; if `t` is a `TyCon` spine, stripping yields a HEADED type, and the two sides would then
disagree exactly as they do for `TyEffect`. So the measurement's reason holds only for whatever
shape was actually probed. **I could not determine statically whether a `TyConstrained` head with a
concrete inner spine is reachable in impl-head position** (that is a parser/resolve question and I
am forbidden from building) — see REFUSALS. The verdict below does not depend on it.

### C.4 One more issue that shares the family but is NOT in this set

**#1180** (OPEN, S0) — the bare-`TyVar` case. Both bodies dedup against it and both are right to:
`TyVar → None` is the *documented intent* (`compiler/types/typecheck.mdk:18395`, §B.4). It is the
one `None` in the set that must not be repaired.


---

## D. 🎯 THE VERDICT — **PRECONDITION**, on the table's VALUE (not its key)

**One-line verdict: the arm set is a Phase 4 PRECONDITION. It must land BEFORE Phase 4's
admissibility table is computed-and-frozen, not alongside 4b.**

The trace, in five links. Every link is grep-proven above or below.

### D.1 Phase 4's table KEY does NOT contain a head — so the naive answer is "independent"

- `.claude/STAGE-B-PHASE45-SPRINT.md:61` — *"Per-(class, position) admissibility computed once
  post-K from global `IE`, frozen into the elaboration output **as data**, consumed and never
  re-derived"*.
- `:300` — *"Phase 4 must key the frozen table by INTERFACE IDENTITY (`module::Iface`), not by
  `(method, head)`."*
- `.claude/sprint-phase3/AD2-carrier-ruling.md:187` — *"`CAdmisTable`'s rows are keyed by
  *(class, position)*"*, and `:190`/`:205-206` hand Phase 4 the obligation to PROVE that key is
  scoped.

So the key is `(interface identity, argument position)`. **No head tycon appears in it.** Taken
alone this reads as "independent unit — ride with 4b." **That reading is wrong, and it is wrong
for the reason the brief anticipated: the key is not where the head enters.**

### D.2 The table's VALUE is DICT §5's predicate, which is a question ABOUT heads

`.claude/STAGE-B-PHASE45-SPRINT.md:312-313`, quoted (not paraphrased):

> Per (class, argument position), **every reachable constructor uniquely determines the
> min-specificity winner for every goal reaching the site, and the argument must be evaluated.**

*"Every reachable constructor uniquely determines the winner"* is, mechanically, *"do the
candidate impls at this (class, position) have DISTINGUISHABLE head tags?"* — which is precisely
what the head projection answers, and nothing else in the tree answers.

### D.3 `IE` — the input Phase 4 computes from — is INDEXED by `headTyconTy`

The table is computed *"post-K from global `IE`"*. `IE`'s own index is head-keyed, minted through
set-A functions:

| link | `file:line` | proof |
|---|---|---|
| impl-side head is `headTyconTy` | `compiler/types/typecheck.mdk:22574` | `univReceiverTag (headTy::_) = headTyconTy headTy` |
| `IE`'s head index files on it | `:4396-4397` | `ieHeadRows hd env = mregLookupK (headBucketKey hd) env.ieByHead` |
| the bucket key for `None` | `:18388` | `headBucketKey None = headlessBucketKey` |
| collision test reads it | `:19265` | `ieHeadCollidesByIface env iface hd = ieCountHeadByIface env iface hd > 1` |
| …and re-tests through it | `:19348` | `\| ir.irName == iface && headTabEq (univReceiverTag tys) goal =` |
| the universe bucket, goal side | `:22703-22706` | `univConcreteBucket … (Some hk) = mregLookupK (regKeyNTab [oblIfaceKey iface, dispHeadTab hk]) conc` / `univConcreteBucket _ _ None = []` |

**Every path from `IE` to a "do these impls discriminate?" answer goes through `headTyconTy`
(impl) or `headTyconMono` (goal).** There is no head-free route to the DICT §5 predicate in the
tree today.

### D.4 🚨 The decisive fact: the `None` bucket is DOCUMENTED as meaning something it does not mean

`compiler/types/typecheck.mdk:18391-18393` (`sed -n '18391,18393p'`):

```
-- The key of the bucket holding the fully-general (`impl C a`) entries.
headlessBucketKey : RegKey
headlessBucketKey = regKeyNTab []
```

So `impl Sz a` (`TyVar` — genuinely fully general), `impl Sz (Int -> Int)` (`TyFun`),
`impl Sz (Bool -> Bool)` (`TyFun`), `impl Sz (<Stdout> Int)` (`TyEffect`) and any `TyRow`-headed
impl **all land in the one bucket whose in-source name and comment assert they are fully
general.** Four of those five are not fully general at all; three of them are *mutually
distinguishable* types.

**This is not "the table is missing rows". It is "the input to the table asserts a FALSE
PROPERTY about four constructors, in the bucket's own documentation."** A `(class, position)`
admissibility verdict computed over that input is computed over a lie about which impls
overlap — and #1617 is the measured proof: `run` picks by declaration order in **both**
permutations at exit 0 because the two `TyFun` heads are, to `IE`, the same head.

### D.5 What "freezing" then does — and the honest scope of the harm

Be precise about what "frozen" means here, because it changes the argument's strength:

- **It is NOT frozen across releases.** *"Computed once post-K … consumed and never re-derived"*
  is a within-one-compilation freeze. A later arm-set fix would recompute the table correctly; it
  does not persist a wrong table into the binary format forever.
- **It IS frozen in three ways that matter, and the sprint doc already says the third one out
  loud** (`:302-304`): *"If Phase 4 freezes admissibility computed by the CURRENT selector, it
  freezes the order-dependence — and does so behind a table that then reads as authoritative."*
  1. **Epistemic freeze.** The verdict stops being derivable at the point of use. Today
     `ieHeadCollidesByIface` is called at the site and the head is visible in the same expression;
     after Phase 4 the answer is a `CAdmisTable` row and the head projection that produced it is
     several phases upstream. #1617/#1618-shaped defects become *attribution* problems.
  2. **Golden freeze.** Phase 4 takes its own **terminal close-out** with re-cut goldens —
     `.claude/STAGE-B-PHASE45-SPRINT.md:51-52`, *"structural and is not optional: Phase 4 takes
     its OWN terminal close-out — **goldens re-cut exactly once**, seed re-minted TWICE, fixpoint
     C3a+C3b"* (and `:62` lists it as *"Non-negotiable"*). Whatever the table says for a
     `TyFun`/`TyEffect`/`TyRow`
     head at that moment gets **captured into goldens** — and `AGENTS.md`'s standing warning
     applies verbatim: *"a captured golden records what the engine did, not what is correct … the
     gate then defends it forever, going red on the eventual fix."* The arm-set fix would then
     arrive as a **red gate**, and the next agent's cheapest move is to re-bless it.
  3. **Consumption freeze (4b/engines).** #1618's whole defect is that `eval.headTycon` and
     `headTyconTy` partition heads DIFFERENTLY. Phase 4b/5 makes the engines *consume* the table
     rather than re-derive (`:305-307`). Handing `eval` a table partitioned by `headTyconTy` while
     `eval.headTycon` still strips `TyEffect`/`TyConstrained` **promotes #1618 from a tag
     disagreement to a table-vs-engine disagreement** — strictly harder to see, and invisible to
     cross-engine differential because the table is single-sourced.

### D.6 Verdict, and the one branch that would change it

**PRECONDITION.** The arm set must land before Phase 4 computes and freezes the table, because:

1. Phase 4's table VALUE is a function of `IE`'s head partition (D.2–D.3);
2. that partition is wrong-by-construction for `TyFun`, `TyEffect`, `TyRow` (and possibly
   `TyConstrained`), and asserts a *false documented property* about them (D.4);
3. Phase 4's terminal close-out captures the result into goldens (D.5.2), converting the fix from
   "a fix" into "a red gate someone will re-bless".

**The ordering this implies:** arm set → Phase 4 (compute + freeze + close-out) → Phase 4b.
The ruling's placement (*"small, shared — so it rides with 4b, not with X-E"*) gets the SCOPE
right and the ORDER wrong: 4b is downstream of the freeze.

⚠️ **This does NOT mean the arm set must be fully repaired.** The precondition is discharged by
either of two things, and Phase 4 can pick:
- **(a) Fix the arms** — give `TyFun`/`TyRow` real builtin-origin head keys and reconcile
  `TyEffect`/`TyConstrained` across the two engines (bites in §E); or
- **(b) Make the table REFUSE to answer for a swallowed head.** `CAdmisAbsent` already exists as
  a distinct inhabitant (AD-2 §4). A row whose head projection is `None` for a reason *other than
  `TyVar`* is a head the table cannot honestly classify, and the fail-closed discipline RUN-B-013
  condition 1 protects says it must be representable as such. **This is much cheaper than (a) and
  it is the option I would recommend if Phase 4 is schedule-constrained** — but it requires the
  arm set to be *distinguishable at all*, i.e. it needs `headTyconTy` to tell "`TyVar`, correctly
  headless" apart from "`TyFun`/`TyEffect`/`TyRow`, headless because nobody wrote an arm". **Today
  it cannot: both are the same `None`.** So even option (b) needs a change inside `headTyconTy`.

**⇒ Under BOTH options, a change lands inside `headTyconTy` before the table is frozen. That is
what makes this a precondition rather than a scheduling preference.**

### D.7 The branch I could not close, stated as the brief permits

**A Phase 4 design choice not yet made would change the verdict:** if Phase 4 computes
admissibility **structurally from each impl's full `implTys` list** (comparing whole `Ty` values
pairwise for overlap) rather than by reading `IE`'s head buckets, then no set-A function is on the
path and the arm set becomes an independent unit that may ride with 4b.

- **What each branch implies:** head-bucket-derived ⇒ PRECONDITION (the analysis above).
  Structurally-derived ⇒ independent unit, **but** Phase 4 then owes a *new* overlap predicate over
  eight `Ty` constructors, which is a much larger unit than "read `ieHeadCollidesByIface`" and
  re-opens the same exhaustiveness hazard on a fresh function.
- **Which branch is live:** AD-2 §5.1 explicitly leaves the row type and key to Phase 4 and does
  not decide the computation. The sprint doc's `:61` says *"computed … from global `IE`"*, which
  points at the head-bucket branch. **I take `:61` as evidence for the first branch, and I flag
  that it is evidence, not a ruling.**

---

## E. Sizing — the arm-set fix as a bite list

**Enumerated by hand, because a `_ => None` catch-all is exhaustive and wrong: the exhaustiveness
checker reports every one of these six definitions as total.** No gate, no `medaka check`, and no
compiler diagnostic can produce this list; it comes from subtracting the `data` declarations
(§B.1, §B.3) from the arms (§A).

There is a ready-made fix precedent inside the target function itself — the `TyTuple` arm mints a
synthetic builtin-origin head key:
`TyTuple ts => Some (headKeyOfCon OriginBuiltin (tupleHeadTagTc (listLen ts)))`
(`compiler/types/typecheck.mdk:19455`). `HeadKey` has exactly two constructors — `HkDecl TabKey`
(`compiler/types/registry.mdk:995`) and `HkRigid String` (`:998`), declared at `:990` — and
`headKeyOfCon origin name = HkDecl (tabKeyOf NsType origin name)` (`:1009-1010`). So a `TyFun` or
`TyRow` head needs **no new `HeadKey` constructor**, only a synthetic tag mint alongside
`tupleHeadTagTc` (`compiler/types/typecheck.mdk:20892`) / `tupleHeadTag`
(`compiler/eval/eval.mdk:510-511`).

### Bite E-1 — give `TyFun` and `TyRow` a head tag (the ADD-AN-ARM half; drains #1617)

**Transformation:** add a `TyFun` arm and a `TyRow` arm to each `Ty`-side classifier, minting a
builtin-origin synthetic tag exactly as `TyTuple` does. **3 named sites:**

| # | site | current catch-all |
|---|---|---|
| 1 | `compiler/types/typecheck.mdk:19452` `headTyconTy` | `_ => None` at `:19456` |
| 2 | `compiler/types/typecheck.mdk:19479` `headTyconNameTy` | `_ => None` at `:19483` |
| 3 | `compiler/eval/eval.mdk:513` `headTycon` | `headTycon _ = None` at `:519` |

Plus **1 tag-mint site** beside each `tupleHeadTag*` (`typecheck.mdk:20892`, `eval.mdk:510`), and
those two must stay byte-identical — a stated invariant of the existing pair
(`typecheck.mdk:20889-20890`: *"byte-identical to eval.mdk's `tupleHeadTag`"*).

⚠️ **`TyFun` is binary, and currying means the head NODE does not carry the discrimination.**
`Int -> Int` and `Bool -> Bool` are both `TyFun _ _` — the same head node with different payloads
— which is #1617's repro exactly. **A bare `__fun__` tag puts them back in one bucket and does NOT
drain #1617.** So this bite is not sizeable as "one tag": **Phase 4 must decide what a function
head's tag IS.** Design question, outside an analyst's charter — flagged, not guessed (R-4).
(`TyRow` has no such problem: one tag suffices.)

- **could move:** the snapshot goldens for `types/typecheck` and `eval/eval`;
  `test/selfproc_goldens/legA/types.typecheck.golden` and `.../eval.eval.golden` — both modules are
  in `AGENTS.md`'s LEG A corpus, so this is graded by `diff_compiler_selfproc` in the **CI
  `backend` shard** and is phantom-skipped (hence green) in a fresh worktree by default; every
  `*.eval.golden` for a program with a function-typed or row impl head.
- **nearest miss:** an impl head that is a `TyApp` spine whose left end is a `TyFun` (an alias
  expanding to an arrow) — `headTyNode` hands `TyFun` to the new arm, but whether resolve has
  already expanded the alias is not derivable statically here.
- **engines:** all three. `eval.headTycon` feeds `headTyconHead`, which
  `compiler/ir/core_ir_lower.mdk:1306` and `:1407` read to build the LLVM/wasm impl-entry tags.
- **unchecked:** whether `TyRow` is reachable in impl-head position at all (R-2). If not, the
  `TyRow` arm is defensive rather than corrective — **still worth adding**, because the wildcard is
  exactly what made it unenumerable.

### Bite E-2 — reconcile `TyEffect` / `TyConstrained` across the two engines (drains #1618)

**Transformation:** make `eval.headTycon` and `typecheck.headTyconTy`/`headTyconNameTy` agree on
`TyEffect` and `TyConstrained`. **Same 3 sites as E-1**, plus the two existing strip arms at
`compiler/eval/eval.mdk:516` (`headTycon (TyConstrained _ t) = headTycon t`) and `:517`
(`headTycon (TyEffect _ _ t) = headTycon t`).

Two directions, **not equivalent** — a semantics choice, not a refactor:
- **strip on both** (typecheck adopts eval's behaviour): `impl Sz (<Stdout> Int)` and `impl Sz Int`
  become the same head, which is what coherence already assumes — `compiler/eval/eval.mdk:491-494`
  records the measured diagnostic *"Overlapping impls of Sz: Int and Int can match the same type"*,
  *"exit 1 on check AND run — note the diagnostic strips the row too"*;
- **`None` on both** (eval adopts typecheck's): an effect-carrying head becomes headless, landing
  in the bucket documented as fully-general (§D.4) — **strictly worse.**

⇒ **Strip-on-both is the only direction consistent with what coherence already does.** Stated as a
derivation from the in-source record, not as a ruling.

- **could move:** the same golden families as E-1, plus
  `test/must_fail_fixtures/1618-effect-carrying-impl-head-cannot-build/`, which flips green and
  **fails `diff_compiler_must_fail`** — the designed self-drain, not a break.
- **nearest miss:** a `TyConstrained` head whose inner type has a concrete head (`Ord a => Set a`).
  #1618's dedup asserts *"stripping a constraint yields a still-headless type"*, FALSE for that
  shape (§C.3). If reachable, this bite silently moves its bucket too.
- **engines:** all three; #1618's body records the cross-module form as byte-identical.
- **unchecked:** whether a `TyConstrained` impl head with a concrete inner spine parses (R-2).

### Bite E-3 — the `Mono` (goal-side) twins. **NOT OPTIONAL if E-1 lands.**

**Transformation:** add matching `TFun` and `TEff` arms to the two `Mono` classifiers, so the goal
side partitions heads the same way the impl side now does. **2 named sites:**

| # | site | current catch-all |
|---|---|---|
| 1 | `compiler/types/typecheck.mdk:20847` `headTyconMono` | `_ => None` at `:20863` |
| 2 | `compiler/types/typecheck.mdk:20883` `headTyconNameMono` | `_ => None` at `:20887` |

`univReceiverTag`/`headTyconTy` mints the impl-side bucket key and `headTyconMono` mints the
goal-side one; `univReceiverTag`'s own comment (`compiler/types/typecheck.mdk:22571-22572`) states
the invariant: *"the SAME tag `headTyconMono` computes for a dispatch mono, so an impl and the args
it matches land under the same key."*

🚨 **Fixing only the impl side files `impl Sz (Int -> Int)` under a function bucket while a goal of
type `Int -> Int` still looks in the HEADLESS bucket — the impl becomes UNREACHABLE.** That turns
#1617's wrong-answer-at-exit-0 into a no-impl failure on a program that previously "worked": a
partial fix manufacturing a new defect. This is precisely the *"audit the arms as a SET"* failure
this packet exists to prevent, and it is why E-1 and E-3 are **one landing, not two**.

- **could move:** as E-1, plus every `*.eval.golden` where dispatch reaches a function-typed value.
- **nearest miss:** `Mono.TVar` (unbound) must KEEP answering `None` (§B.4); `TRigid` must keep its
  existing wrong-but-ruled `Some` — a separate semantics PR by explicit in-source ruling
  (`compiler/types/typecheck.mdk:20850-20857`).
- **engines:** typecheck at the mint, all three at the consequence.
- **unchecked:** whether `TEff` can ever be a dispatch-goal head. Not derivable statically here.

### Bite E-4 — "no head at all" vs "head we refuse to classify" (the Phase-4-enabling MINIMUM)

If Phase 4 takes option (b) of §D.6, this is the whole bite: `headTyconTy` must distinguish
*"`TyVar`, correctly headless"* from *"`TyFun`/`TyEffect`/`TyRow`, headless because there is no
arm."* Today both are the one `None` at `:19456`, and `headBucketKey None = headlessBucketKey`
(`:18388`) files them together in the bucket whose own comment (`:18391`) asserts they are fully
general. **1 named site** plus its `Option HeadKey` consumers. **This is the smallest change that
discharges the §D precondition**, and it does not require answering R-4.

### E.5 🚨 NOTHING → SOMETHING: yes, in every bite — and the new path is untested by construction

**Answer: YES.** Every bite turns a `None` into a `Some`. And the consumers do not merely "handle
`None`" — three of them **drop the impl entirely**:

| consumer | `file:line` | the `None` arm |
|---|---|---|
| `implEntryFromTys` | `compiler/types/typecheck.mdk:18200-18204` | `None => []` — the impl produces **no `ImplEntry`** |
| `implHeadTagForIface` | `:20110-20115` | `None => []` |
| `implTysIfMatch` | `:23054-23059` | `None => []` |

Plus `univConcreteBucket _ _ None = []` (`:22706`) — a headless goal gets the **empty** bucket.

**So today a function-typed / effect-carrying / row impl head is not "bucketed oddly" — it is
INVISIBLE to three tables and looks up nothing.** After the fix it is present in all of them, on
code paths **no existing fixture has ever exercised**, because every existing fixture's coverage of
these shapes is the empty case. `AGENTS.md`'s rule applies verbatim: *"the new something is
untested by construction — every pre-existing test covered the empty case, so no existing fixture
can fail."*

**The tests that would catch it — built from the spec, not from the diff or from coverage:**

1. **A permutation differential over DICT §5's condition, on the newly-visible shapes.** Two impls
   of one interface at function-typed heads, in BOTH declaration orders, asserting the SAME
   hand-derived answer (`(5, 9)`). #1617's repro is already exactly this, pinned at
   `test/must_fail_fixtures/1617-fn-typed-impl-head-none-bucket/`; it self-drains and must be
   converted to a positive fixture **in the same PR**, not deleted. ⚠️ *Only a permutation
   differential sees this class* — `.claude/STAGE-B-PHASE45-SPRINT.md:306-307` records that all
   three engines agree on the same wrong, order-dependent answer, so `diff_compiler_engines` is
   structurally blind to it.
2. **A BYSTANDER fixture — the one no gate will suggest.** A program containing a function-typed or
   row impl head whose assertion is about code that *does not use it*. E-1/E-3 change the CONTENTS
   of a program-global bucket index (`ieByHead`), so the hazard is `AGENTS.md`'s program-global-table
   shape: the feature works and something unrelated breaks. Corpus precedent to copy:
   `test/eval_typed_fixtures/head_key_classes_bystander.mdk`, whose own header calls its unit
   *"ANSWER-PRESERVING"*.
3. **A negative control that must NOT move.** `impl C a` (bare `TyVar`) must stay in the headless
   bucket; #1180's pin (`test/must_fail_fixtures/1180-undetermined-top-headless-impl-commits/`) must
   **still reproduce** after the fix. If it drains, the fix over-reached into §B.4's deliberate
   `None` and broke #1128/F-3b's premise.
4. **A cross-engine tag-agreement fixture for E-2.** The same effect-headed impl through
   `check` / `run` / `build`, all three reaching the same impl. #1618 records the current asymmetry
   as `check=0 run=0 build=1`, so the grading channel is `build`'s exit code, not a value golden.
   ⚠️ `medaka build`'s exit code does not survive a pipe — redirect to a file and read `$?`.

**None of these four is derivable from the diff or from coverage.** (1) and (4) come from the issue
repros; (2) and (3) come from the spec and from the deliberate-`None` ruling.

---

## REFUSALS

Stated rather than guessed. I did not build, run, or invoke `./medaka` at any point, and I did not
read or grep `/root/medaka` (the stale main checkout) or any sibling worktree.

- **R-1 — Whether Phase 4 computes admissibility from `IE`'s head buckets or structurally from
  `implTys`.** The single hinge of §D, and a **Phase 4 design choice not yet made** (AD-2 §5 leaves
  the row type and the computation to Phase 4). §D.7 gives both branches and what each implies.
  `.claude/STAGE-B-PHASE45-SPRINT.md:61` (*"computed once post-K from global `IE`"*) is **evidence**
  for the head-bucket branch, not a ruling. My verdict is conditional on it and says so.
- **R-2 — Reachability of `TyRow`, and of a concrete-spined `TyConstrained`, in impl-head
  position.** Parser/resolve questions needing a probe this packet may not run. Affects only how
  much of E-1/E-2 is *corrective* vs *defensive*; it does **not** affect the §D verdict, because the
  `TyFun` member is measured-reachable (#1617, `verified`) and is sufficient alone.
- **R-3 — Whether #1617/#1618's "`TyConstrained` measured NOT a defect" measurement is sound.** I
  showed its stated REASON is not general (§C.3) but cannot re-run the measurement. **I am NOT
  claiming `TyConstrained` is a defect** — only that (a) the sprint doc inverts what both bodies say
  about it, and (b) the reason on record does not cover all shapes.
- **R-4 — What tag a `TyFun` head should carry.** Currying makes a single `__fun__` tag
  insufficient for #1617's own repro (§E-1). Design decision, out of charter.
- **R-5 — Sizing in time.** Bites and named sites only. The golden blast radius (LEG A + snapshots
  + `*.eval.golden`) is named but **not counted** — a count here would be an encoded fact with no
  derivation and no expiry.
- **R-6 — `core_ir_lower.tyHeadName` (`:1639`) and `lint.tyHeadName` (`:1229`).** Flagged in §A.10
  as shape-matching but off the dispatch path. I did **not** audit their arm sets. If a later reader
  wants *every* `Ty`→head function in the tree audited, those two are the remainder.
- **R-7 — I did not verify #1617's or #1618's repros first-hand.** I verified their *mechanism
  claims* against the source (both hold — §C.1, §C.2) and read their `verified` labels. The
  behaviour numbers in their bodies are relayed, not re-measured.

