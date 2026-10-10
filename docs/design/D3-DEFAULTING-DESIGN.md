# Numeric defaulting at a multi-parameter goal — the D3 rule, determination, and the settle sequence

**Status:** design pass, 2026-10-03/04. Nothing in this document is implemented in
`main`. It settles the part of sprint `the-declared-variable-holds` (#3787, PR #3789)
that was cut: slices 3 (`S-multiparam-var-not-defaulted`) and 4
(`S-improve-in-method-body`). Every claim below marked *measured* was measured on a
prototype built from `c57d595ce`; the prototype's diff is
`/var/tmp/medaka-sprints/the-declared-variable-holds/reports/D3-prototype.patch`
(177 lines, `compiler/types/typecheck.mdk` only), the probes are under
`/var/tmp/medaka-sprints/the-declared-variable-holds/probes/d3/`, and the logs are in
`…/reports/{ds,probes,intree}-*.log`. A hand-derived expectation stands above every
captured value; where the two disagreed the hand-derived one is the one reported.
`checkUndeterminedArgs` and `checkUndeterminedObligation`, named below as they stood
at `c57d595ce`, were retired by #3897: the undetermined-goal verdict is now
`checkUndeterminedObligations` over the one candidate set `goalCandidates`, with no
per-argument loop and no sole-impl default.

The question this document answers in one sentence: **when a numeric literal's type
variable sits in a multi-parameter predicate, what settles it — the one instance that
fits, the caller, or `Int` — and in which order are those three asked.**

---

## 0. Recommendation

Replace three separate mechanisms — per-group improvement (§3), module-end head-tycon
grounding (gap #44), and group/body/quiescence numeric defaulting (§6.3) — with one
**settle sequence** run at every boundary and once more at quiescence:

1. **Improve** (§3, unchanged): a repeated head variable of the unique matching
   instance binds goal variables to each other.
2. **Determine**: a goal of arity ≥ 2 that exactly one instance head unifies with — the
   boundary's *unowned* variables held rigid, its *owned* variables free, and the
   candidate consistent with the boundary's other goals — is unified with a fresh
   instance of that head, minted at the boundary's level. A goal of arity ≥ 2 that **no**
   instance head unifies with, whose variables are all owned, is rejected at its site
   with `T-NO-IMPL`.
3. **Default**: a `Num`-constrained variable the boundary owns is grounded to `Int`
   unless a channel can still determine it. The channels are §6.3 D3's, with one made
   precise: an argument position of a member's type determines not only the variables
   in it but every variable of the member's **type** that the boundary's own goals
   connect to one of them. Variables outside the member's type default (they have no
   channel at all).
4. **Improve and determine again** over the goals defaulting changed (defaulting is a
   substitution like any other).
5. **Register ambiguity** on whatever is left, as today.

Three consequences, all measured on the prototype (§6):

- Every sprint probe passes on `check`, `run` and the built binary: `dbl b = get b +
  get b` prints `small`, `impl Report (Array a)` prints `3.75` then `7`, `a[0] == 1`
  at `Array Float` prints `True`, `pick [] [3, 7]` in an impl body builds and prints
  `[3, 7]`.
- The **Bytes/U8 face of #3437 passes by the same rule** (`input[pos] == 13` at
  `Bytes` prints `True`, at a group boundary and inside a `let`), and `input[pos] ==
  300` is refused with "integer literal 300 does not fit U8". No per-interface clause
  is involved.
- `test/diff_compiler_dict_semantics_test.mdk` moves **one** row of 298, the #1641 row,
  from a pinned check/run disagreement to `ACCEPT` on all three verbs; the scheme and
  span tables are unchanged; `check` over every stdlib module, every stdlib
  subdirectory module and `compiler/driver/medaka_cli.mdk` is byte-identical to base.

The alternative Val ruled on 2026-10-03 — Haskell's rule, *a variable in a
multi-parameter predicate is never a candidate* — was measured twice (alone, and with
determination added) and is **not recommended**; §9 gives the numbers. In short: alone
it moves 26 rows, 17 of them back into the `check`-accepts/`run`-rejects class the
sprint exists to close; with determination it still accepts `useIx 1` at `Ix a Bool =>`
printing `222`, and it rejects `println (debug ([|3, 4|][0]))`.

Section 11 lists the rulings this design needs before a sprint is dispatched; §12 is
the proposed sprint.

---

## 1. Where this starts

Sprint `the-declared-variable-holds` landed slices 1 and 2: a declared signature's
variables are rigid in every matcher, and an impl head's variables are the impl's
quantifiers (W3-inst). Slice 3 was attempted under the 2026-10-03 ruling (Haskell's
candidate rule) and refused by its own acceptance measurement: 26 rows of the dict
semantics table moved (`…/reports/S-multiparam-var-not-defaulted.md`, re-reproduced
here from `attempt2.patch`: 26 of 304, 4 scheme rows, 2 span rows, `ds-attempt2.log`).
Val's ruling #1 at the end of that sprint: *"Land D3; the Bytes face passes"*; ruling
#2: cut slices 3 and 4 and design first.

What the code does today, at the three places the question touches
(`compiler/types/typecheck.mdk`, line numbers at `c57d595ce`):

- **Improvement** (`improveByUniqueImpl` :37549, `improveGoal`, `commitImprovement`),
  called from `processSCC` only, before `finalizeNumBoundary`. It binds goal variables
  *to each other* (a repeated head variable); by §3's third bullet it never binds a
  variable to a constructor the instance has where the goal has a variable.
- **Module-end grounding** (`groundMultiParamObligations` :37470 → `groundOneObligation`
  → `uniqueImplTysFor` :37507). It does exactly what §3's bullet forbids — unifies the
  goal with the unique instance's head — but keyed on the **first** dispatch argument's
  head constructor only, skipping goals whose first argument is a variable, after
  `sigVarsStayFree`. The spec records it as "a separate step" (§3, last paragraph).
- **Defaulting** (`finalizeNumBoundary` :26055 with `unprotectedNumCandidates` :26161,
  `groundNumVarsWith`, `settleClosedBody` for test/prop bodies, and the
  method-body special case `bodyExtraNumObls`/`multiParamIds` :26220 for #3506). A
  candidate is a `Num`-constrained variable not protected by a declared signature and
  not reachable from an argument position of a member's type.
- **Undetermined-goal acceptance** (`checkUndeterminedObligations` :37299 →
  `checkUndeterminedArgs` :37312 → `checkUndeterminedObligation` :37343). It iterates
  **per argument**; the `| otherwise = ()` arm accepts an undetermined argument when
  the interface has exactly one impl at that position (OD3's sole-impl default).

The order today is: improve → default → (generalize) → … → module-end grounding →
undetermined-goal check. Defaulting runs before the one instance has had its say,
which is #3521's top-level face, #3437's `Array Float` face and #3549.

---

## 2. Method

Four trees from `c57d595ce` (`git archive`), each built with `make -C <tree> medaka`
and run with `MEDAKA_STRICT=1`:

| arm | content |
|---|---|
| **base** | `c57d595ce` unmodified |
| **attempt2** | `+ attempt2.patch` — Haskell's rule at every boundary (the sprint's refused slice 3) |
| **a3** | attempt2 `+` the prototype's determination step — Haskell's rule with the one instance asked first |
| **proto** | base `+ D3-prototype.patch` — the recommendation of §0 |

Every probe was run through `check`, `run`, and `build` plus executing the binary
([D-RUN-VS-BUILD]). The table `test/diff_compiler_dict_semantics_test.mdk` was run
whole on each arm (298 rows at base; attempt2 adds 6). The in-tree sweep is `check`
over `stdlib/*.mdk`, `stdlib/*/*.mdk` and `compiler/driver/medaka_cli.mdk` (45 units)
compared byte-for-byte between base and proto. The `Ix ?a Bool` root cause (§7) was
found with a fifth tree carrying `pushTypeError "D3-TRACE"` probes in
`checkUndeterminedObligation`, `routeUndeterminedTop`, `groundOneObligation` and
`improveGoal`, gated on the interface name so the compiler could still self-compile.

The prototype went through four rounds; §10 records the three defects the table found
in it and what they teach the implementation. The numbers in §6 and §9 are from the
final round (`ds-proto5.log`, `probes-proto5.log`, `intree-proto5.log`).

---

## 3. The rule (answers Q1)

This is written to replace §6.3 D1–D3's placement and candidate text and to be the one
paragraph `inst`'s "when" refers to. Vocabulary: a **boundary** is a point where a set
of bindings closes — a top-level group (§6.2 T1), a `where` component, a local `let`, an
`impl` or default method body, and quiescence (T4). A boundary **owns** a variable at
its own level (D4). A variable it does not own — a declared signature's variable, an
impl head's variable, an enclosing binder's variable, a variable in an argument
position of a member's type — is **unowned** and rigid for every step below.

> **Settle.** At every boundary, after its bodies are inferred and before it
> generalizes, over the goals it recorded, in this order:
>
> **S1 — Improve** (§3). Unchanged.
>
> **S2 — Determine.** For a goal `C τ₁ … τₙ`, `n ≥ 2`, not closed: let `U` be the
> instances of `C` whose heads unify with the goal, the goal's unowned variables held
> rigid and the instance's variables fresh, and let `U′ ⊆ U` be those whose commit
> leaves every other goal on a variable it binds satisfiable (**joint consistency**,
> §4.3). If `U′ = {I}`, unify the goal with a fresh instance of `I`'s head, the fresh
> variables minted **at the boundary's level**. If `U = ∅` and the goal has no unowned
> variable, reject at the goal's site with `T-NO-IMPL`. Otherwise commit nothing.
>
> **S3 — Default.** A variable is a candidate iff (i) some goal on it is `Num`, (ii)
> the boundary owns it, and (iii) **no channel of the boundary can determine it**. The
> channels are D3's — a declared `d̄_sig`, an impl's head and method dictionary — and
> the **argument channel**, which reaches every variable in an argument position of a
> member's type **and every variable of a member's type that the boundary's goals
> connect to one**, where two variables are connected when one goal mentions both. A
> variable in no member's type has no channel and is a candidate. A candidate is
> grounded to `Int` only if (iv) **joint consistency at defaulting** holds: every goal
> of arity ≥ 2 that mentions it, and that mentioned two or more variables when the
> boundary began defaulting, is still satisfiable after the substitution (an instance
> head unifies or a given covers it, the boundary's rigid set held), unless it was
> unsatisfiable before. A candidate (iv) withholds is left to S4, never tried at
> another default type, and a goal on it S4 leaves open with two or more candidates is
> `T-AMBIGUOUS-INSTANCE` (DICT §6.3 D3 clause 3; closed test and property bodies are
> not guarded).
>
> **S4 — Improve and determine again** over the goals S3 changed.
>
> **S5 — Register** every remaining undetermined goal: deferrable into the scheme
> (OD2) if it mentions an unowned variable; otherwise `T-AMBIGUOUS-INSTANCE` (OD3).
>
> **At quiescence** the same sequence runs once over every goal still open, with no
> variable unowned.

Three things this says that today's text does not:

- **Determination comes before defaulting.** `Get (Box Float) ?e` with the only
  instance `Get (Box a) a` fixes `?e = Float` in S2; a literal at `?e` then has nothing
  to default. Today the same program is accepted only because improvement (S1) happens
  to catch this particular shape (a repeated variable); `Index Bytes Int ?v` against
  `Index Bytes Int U8` has no repeated variable and nothing catches it, which is #3437's
  Bytes face.
- **The argument channel is closed under connection.** `dbl b = get b + get b` poses
  `Get b e` and `Num e` with `b` an argument and `e` the result. Today `e` is "not
  argument-reachable" and defaults to `Int`, after which `dbl (Box 1.5)` has no
  instance. Under S3, `e` is connected to `b` through `Get b e` and is in `dbl`'s type,
  so the caller's `b` determines it: `dbl : (Get b e, Num e) => b -> e` (measured).
  This is D3 clause 2's "a channel that outlives the boundary can determine it" read
  through §3: the caller supplies `b`, and improvement at the use site fixes `e`.
- **A variable outside the type still defaults.** `f x = ix x 0` with `Ix Int Int` and
  `Ix Int Char` poses `Ix a k`, `Num k`; `k` is connected to the argument `a` but is in
  no type of `f`. No caller can reach it, so it is a candidate: `f : Ix a Int => a ->
  Int`, `f 1` prints `9` (measured, same as base). Haskell would reject `f` as
  ambiguous. D3 rejects that reading explicitly ("no surviving channel"), and this
  design keeps D3.

No clause above names an interface, a type, or a stdlib module. The Bytes face passes
because `Index Bytes Int U8` is the only instance of `Index` whose head unifies with
`Index Bytes Int ?v` — not because `Bytes` or `U8` appears anywhere in the rule.

### 3.1 Why "connected and in the type", not "mentioned in a multi-parameter predicate"

The brief asked for an honest evaluation of a cheaper variant: *withhold a
multi-param-mentioned variable only when it is generalized into the scheme*. S3(iii)
is that variant made precise: "generalized into the scheme" is "in a member's type and
owned", and "connected to an argument" is what makes the caller able to fix it. The
difference between the two shows at a result variable connected to nothing the caller
supplies: `g u = get (mk ()) + 1` with `mk : Unit -> c` polymorphic poses `Get c e`,
`Num e`, `e` in the result. Under the cheaper variant `e` is withheld (it is in the
type), and `c` is then ambiguous; under S3 `e` defaults to `Int`, and `Get c Int` is
then ambiguous. Both reject; neither is reachable from an argument. The connection
clause is kept because it is the one D3 derives — result position is not a channel at
an inferred binding — and because it decides `f x = ix x 0` the way D3 does. The two
variants agree on every measured probe.

---

## 4. Determination (answers Q2 and Q6's consequence)

### 4.1 Is committing on the unique instance legitimate against §3's exclusion?

§3's third bullet: *"`U = {I}`, but `I`'s head does not match `π`, because `I` has a
type constructor where `π` has a variable. Committing there would be unification
against the instance head, not improvement: the only instance `impl Show (List Int)`
never fixes `Show (List t)` to `t = Int`."*

Two observations settle this.

First, **the implementation has committed exactly this way since gap #44**, at module
end, and the spec records it as a separate step rather than forbidding it. §3's
paragraph on `groundMultiParamObligations` is the exclusion bullet's own exception. So
the question is not whether to introduce head-constructor commitment but whether to
keep two versions of it with different keying — the module-end one keys on the first
dispatch argument's head constructor and skips variable-headed goals, which is why it
never fires on `Index Bytes Int ?v`'s *third* position without the first being
concrete, and why `s3-sig-constraint-unsatisfiable-rejects` was invisible to it.

Second, the exclusion's stated reason — *"would decide the overlap by the order the
variables happen to be solved in"* — applies to `|U| ≥ 2`, not to `|U| = 1`. With one
unifying instance over the whole `IE` (C4: assembled once, not growing), the commit is
a function of `(IE, π)` and of nothing else; no order of solving can produce a
different answer, because no other instance can ever match. What the bullet is really
guarding is the **1-ary** case, `Show (List t)`: committing `t = Int` there is
objectionable because `t` may be the caller's. That is an ownership question, and S2
states it as one: an unowned variable is rigid, so `Show (List t)` with `t` a
signature variable or an argument commits nothing (and `weird : b -> b` keeps its
`T-MISSING-CONSTRAINT`, measured). For an owned variable at the last boundary that can
determine it, the unique instance is the only type at which the program is well-typed,
and refusing it is a rejection with no witness.

**Proposed amendment to §3, third bullet** (replace):

> `U = {I}`, but `I`'s head has a type constructor where `π` has a variable that this
> boundary does not own — a signature's, an impl head's, an argument's, an enclosing
> binder's. Committing would decide a type the caller or the enclosing scope has the
> right to choose. For a variable the boundary owns, the commit is **determination**
> (§6.3 S2): the one instance whose head unifies with the goal is the one type the
> program can have at that position, and it is taken before numeric defaulting. A 1-ary
> goal is not determined; see §4.2 OD3.

**Proposed amendment to §3, last paragraph** (replace the "separate step" paragraph):

> The module-end head-tycon grounding (`groundMultiParamObligations`, gap #44) is the
> quiescence call of determination, keyed on the whole head rather than the first
> argument's constructor. It is retired as a separate step.

**Proposed amendment to §6.2 T4**, the sentence *"never committed to a default
instance"*: add *"— `default instance` meaning one of several; a goal of arity ≥ 2 with
exactly one unifying instance is determined, not defaulted (§6.3 S2)."*

### 4.2 Why arity ≥ 2 (and why that is not a carve-out)

The 1-ary case already has an answer in the code: OD3's *sole-impl default*
(`checkUndeterminedObligation`'s `| otherwise = ()`) **accepts** `Show ?t` with one
impl without binding `?t`. Whether that acceptance should become a commit is the
undetermined-goal sprint's question (#2028 family, T4 census). This design does not
answer it and does not touch it; the arity bound is the scope line between two
sprints, not a rule about interfaces. The next section is where that line costs
something.

### 4.3 Joint consistency (a ruling is needed; §11 R3)

`useIx : Ix a Bool => a -> Int`, `main = println (useIx 5)`, instances `Ix Int Char`
and `Ix Bool Bool` (`s-nary-truncated-goal-joint-rejects`). At `main`'s boundary the
goal is `Ix ?a Bool` with `Num ?a`. `U = {Ix Bool Bool}`: unique. Committing `?a :=
Bool` then fails `Num Bool` and the program is rejected with "Type mismatch: Int
literal vs Bool" (measured, prototype round 2) — a true rejection with a misleading
cause. The pinned answer is `T-NO-IMPL`, "No impl of Ix for Int Bool".

The prototype's S2 therefore filters `U` by the boundary's other goals on the bound
variable: a candidate that binds a `Num`-constrained variable to a type with no `Num`
instance is dropped (`U′`). With `U′ = ∅` nothing is committed; `?a` is then a
candidate, defaults to `Int`, and the closed goal `Ix Int Bool` is rejected by the
existing closed-goal check with the pinned message (measured).

Two consequences of the filter, one wanted and one for Val to weigh:

- `s-nary-truncated-goal-joint-rejects` and `s3-sig-constraint-unsatisfiable-rejects`
  reject with the pinned code and message (measured).
- **`d17_body_two_index`** — `impl Report (Array a) requires Num a, Debug a` with
  `report v = debug (v[0] + v[1])` and a second user instance `Index (Array a) Rng
  (Array a)` in scope — is **accepted** and prints `3.75` then `7`: `U = {Index (Array
  a) Int a, Index (Array a) Rng (Array a)}`, and the `Rng` instance binds the
  `Num`-constrained `?v` to `Array a`, which has no `Num` instance, so `U′` is a
  singleton. At base this program is accepted by `check` and fails on `run`
  (`E-AMBIGUOUS-DISPATCH`) and on `build` (`no impl of method 'index' for instance
  'Array'`) — §13 issue 2.

The filter makes instance *selection* depend on the sibling goals of the variable, which
Haskell's instance resolution never does. The property that makes it safe: the filter
only ever removes candidates, and a new instance can only enlarge `U` — so adding an
impl turns an accept into a loud ambiguity reject, never one value into another. The
general form, which the implementation should use instead of the prototype's list of
numeric heads: *a candidate is excluded when committing it closes some other goal on a
variable it binds to a vector with no unifying instance*. The alternative — no filter,
and report the post-commit failure as `T-NO-IMPL` on the original vector instead of a
mismatch — is also coherent and keeps selection sibling-blind; it leaves `d17` as it is
at base. The recommendation is the filter, because defaulting is already a
sibling-aware step (`Num` is the sibling it reads), and because the alternative's
diagnostic names the wrong fault.

### 4.4 Level discipline (hazard H1)

A fresh instance of `I`'s head must be minted **inside** the boundary's level.
`processSCC` calls `exitLevel` before its settle calls; a fresh variable minted there
sits at the outer level, and unification lowers the goal's variable to it, so the
variable is no longer generalizable. Measured (prototype round 1): `f x y = conv (Wrap
x) y` against `impl Conv (Wrap a) b requires Conv a b` printed `f : a -> b -> String`
— the residual `Conv c d` silently gone from the scheme — and the call-site reject of
`s4-gen-residual-mixed-vector-rejected` moved from 45:16 to 43:8. Wrapping the mint in
`enterLevel`/`exitLevel` restores `f : Conv c d => a -> b -> String` and the span
(measured, round 4). This is the same shape as D4's "a boundary with no level
discipline cannot host the ambiguity check", one step over: it cannot host
determination either. The acceptance rows are the two scheme lines
`s4-joint-residual-rdict-native` and `s4-gen-residual-mixed-no-requires-control` and
the span row for `s4-gen-residual-mixed-vector-rejected`, all already in the table.

Measured result of the implementation (S-determine): determination runs at the group
boundary only, before and after defaulting, with no quiescence call. A call at module
end is inert when its rigid set holds every published scheme's and impl head's
variables, and binds impl-head variables when it does not. `Conv c d` was the deleted
module-end grounding rebinding `f`'s quantified cells after generalization; without it
the scheme line prints the hand-derived `f : Conv a b => a -> b -> String`, and H1's
failure still prints `f : a -> b -> String`.

---

## 5. The Bytes/U8 face (answers Q3)

**Passes, by the general rule.** `isCr input pos = input[pos] == 13` with `isCr :
Bytes -> Int -> Bool`: the goal is `Index Bytes Int ?v` with `Num ?v`, `Eq ?v`. `U =
{Index Bytes Int U8}` (the only `Index` instance headed at `Bytes`), joint-consistent
(`U8` has `Num`), so S2 fixes `?v = U8`; the literal `13` is a `U8` literal and the
comparison is `U8 == U8`. Measured on all three verbs: `True` (`d03_bytes`), at a `let`
boundary too (`d08_let_bytes`), and `input[pos] == 300` is refused with "integer
literal 300 does not fit U8 (0..255)" on all three verbs (`d19_bytes_range`) — the
widening is bounded by the literal's range check, which runs on the determined type.
`Array U64` behaves the same (`d18_u64`, `False`, unchanged from base).

What this means for the sprint's "Out" entry (*"waits for a declared-determination
design — an associated type or fundep"*): no declaration is needed. The determination
is **by uniqueness**, not by a functional dependency the interface declares. The
difference matters once a second `Index Bytes Int _` instance exists: a fundep would
reject the second instance at declaration; uniqueness-determination would accept both
and turn `input[pos] == 13` into an ambiguity at the use site. That is the right
behaviour for an interface that declares no dependency, and `Index` declares none.
Whether `Index` *should* declare one is a separate language question this design does
not open.

**`docs/design/BYTES-DESIGN.md:307-309`** — the "Not settled here" bullet — is to be
rewritten when S1 (§12) lands:

> - **Settled by determination (`docs/design/D3-DEFAULTING-DESIGN.md`):** `b[i] == 13`
>   type-checks, because `Index Bytes Int U8` is the one instance that fits the goal
>   and it is taken before the literal defaults. `u8.toInt b[i] == 13` keeps working
>   and is no longer needed.

#3437 then closes fully; the sprint's re-scoping of it to the Bytes face is superseded.

---

## 6. Measured results

### 6.1 The sprint's probes and the design probes

`check` / `run` / built binary; a value is the printed output; "reject" lists the code
where it matters. Hand-derived expectation in the last column.

| probe | base | attempt2 (Haskell rule) | a3 (Haskell rule + determine) | proto (§0) | expected |
|---|---|---|---|---|---|
| `p3521top` unsigned `dbl b = get b + get b`, `classify (Box 1.5)` | reject ×3 (`No impl of Get for (Box Float) Int`) | `small` ×3 | `small` ×3 | `small` ×3 | `small` |
| `p3521body` `impl Report (Array a)`, `debug (v[0] + v[1])` | check 0, run panics, binary prints a heap word | check 0, run `3.75`, build fails | `3.75`/`7` ×3 | `3.75`/`7` ×3 | `3.75`, `7` |
| `p3437` `f : Array Float -> Bool; f a = a[0] == 1` | reject ×3 | `True` ×3 | `True` ×3 | `True` ×3 | `True` |
| `p3549` `q _ = pick [] [3, 7]` in an impl body | check 0, run `[3, 7]`, build fails | same as base | `[3, 7]` ×3 | `[3, 7]` ×3 | `[3, 7]` |
| `d03_bytes` `input[pos] == 13` at `Bytes` | reject ×3 | `True` ×3 | `True` ×3 | `True` ×3 | `True` |
| `d08_let_bytes` same, inside a `let` | reject ×3 | `True` ×3 | `True` ×3 | `True` ×3 | `True` |
| `d19_bytes_range` `input[pos] == 300` | reject (mismatch) | — | reject "does not fit U8" ×3 | reject "does not fit U8" ×3 | refuse, naming U8 |
| `d18_u64` `a[i] /= 0` at `Array U64` | `False` ×3 | `False` ×3 | `False` ×3 | `False` ×3 | `False` |
| `d06_two_unifying` `ix 5 'z'`, `Ix Int Char` and `Ix Float Char` | `1` ×3 | reject (ambiguous) | reject (ambiguous) | `1` ×3 | `1` (two unify; defaulting decides) |
| `d07_unique_float` `ix 5 'z'`, only `Ix Float Char` | reject (`No impl of Ix for Int Char`) | check 0, prints **`0`** (wrong) | `2` ×3 | `2` ×3 | `2` (§11 R4) |
| `d13_ix_x_0` `f x = ix x 0`, `Ix Int Int`=9, `Ix Int Char`=7 | `9` ×3 | check 0, run/build fail | check 0, run/build fail | `9` ×3 | `9` |
| `d12_orphan_get` `f b = (get b + 1) > 3`, `f (Box 2.5)` | reject at call ×3 | reject | reject | reject at call ×3 (`No impl of Get for (Box Float) Int`) | reject at the call |
| `d15_sumat_unsigned` `sumAt v i j = v[i] + v[j]` at `Array Float`, `Array Int` | reject ×3 | reject (ambiguous) | reject (ambiguous) | `3.75`/`7` ×3; `sumAt : (Index a b d, Index a c d, Num d) => a -> b -> c -> d` | `3.75`, `7` |
| `d16_mk_conv` `mk () = conv (Wrap 1)`, only `Conv (Wrap Int) Bool` | reject ×3 | reject | `True` ×3 | `True` ×3; `mk : Unit -> Bool` | `True` |
| `d17_body_two_index` impl body, second `Index (Array a) Rng (Array a)` | check 0, run `E-AMBIGUOUS-DISPATCH`, build fails | same | same | `3.75`/`7` ×3 | `3.75`, `7` under §4.3's filter; base behaviour without it |
| `d20_literal_array_index` `println (debug ([|3, 4|][0]))` | `3` ×3 | reject (ambiguous `Debug`) | check 0, run `3`, **build fails** | `3` ×3 | `3` |
| `d21_undet_nonliteral` `useIx (absent ())` at `Ix a Bool =>`, only `Ix Int Char` | **check 0** (ill-typed accepted) | — | — | check 0 (S2's reject half is **not** in the prototype) | reject, `T-NO-IMPL` at the call |
| `x1`/`x2` `f x y = conv (Wrap x) y` under a conditional instance | `f : Conv c d => a -> b -> String`, `w:int-bool`/`w:char-int` | — | — | identical to base | identical to base |

Rows of the existing table singled out:

| row | base | attempt2 | a3 | proto | pinned |
|---|---|---|---|---|---|
| `s3-sig-constraint-unsatisfiable-rejects` (`useIx 1` at `Ix a Bool =>`) | reject `T-NO-IMPL` | **accepted, prints 222** | **accepted, prints 222** | reject `T-NO-IMPL` | REJECT, `T-NO-IMPL` |
| `s-nary-truncated-goal-joint-rejects` | reject `T-NO-IMPL` | reject, wrong code | reject, wrong code | reject `T-NO-IMPL` at 30:16 | REJECT, `T-NO-IMPL` |
| `impl-head-repeated-var-body-default` (#1641) | ACCEPT/REJECT/REJECT (pinned disagreement) | same | `3.75`/`7` ×3 | `3.75`/`7` ×3 | moves to ACCEPT ×3, `total=3.75`, `total=7` |
| `impl-head-repeated-var-body-default-control` | `total=3.75`/`7` ×3 | same | **build fails** | same as base | ACCEPT ×3 |
| `s-multiparam-structured-inferred-rejected` (`h x = conv (Wrap x) 0`) | `boolInt/intInt` ×3 | check 0, run/build fail | check 0, run/build fail | same as base | ACCEPT ×3 |
| `s6-c1-rigid-goal-no-minimum` | reject `T-AMBIGUOUS-INSTANCE` | **check 0**, run fails | **check 0**, run fails | same as base | REJECT |
| `s6-c1-rigid-goal-unique-min-control` | `[3]` ×3 | check 0, run/build fail | check 0, run/build fail | same as base | ACCEPT ×3 |
| `impl-improvement-overlap-no-commit` (§3 floor) | ACCEPT/ACCEPT/REJECT, `W-INCOMPARABLE-IMPLS` | same | same | same | ACCEPT/ACCEPT/REJECT |

### 6.2 Whole-table and in-tree

| arm | `dict_semantics` verdict table | scheme lines | span rows | in-tree `check` sweep (45 units) |
|---|---|---|---|---|
| base | 0 / 298 | 0 / 17 | 0 / 11 | reference |
| attempt2 | **26** / 304 | 4 / 17 | 2 / 11 | not run (26 rows is disqualifying) |
| a3 | **14** / 304 | 2 / 17 | 3 / 11 | not run |
| proto | **1** / 298 — the #1641 row, the expected flip | 0 / 17 | 0 / 11 | **identical to base** (all 45 `rc=0 errors=0`) |

---

## 7. Root cause of the `Ix ?a Bool` acceptance (answers Q6)

Program: `useIx : Ix a Bool => a -> Int`, `main = println (useIx 1)`, only `impl Ix Int
Char`. Under attempt2 the literal's `?a` is withheld (it is mentioned by a
multi-parameter predicate), so the goal reaching the undetermined-goal check is `Ix ?a
Bool`, not `Ix Int Bool`.

Instrumented (`t-instr`, `D3-TRACE` at four sites): **no** grounding trace, **no**
improvement trace, **no** `routeUndeterminedTop` sole-impl trace fired. The only trace
was `undet-accept (sole-impl default)` — twice, once for the argument `a` and once for
`Bool`. `checkUndeterminedArgs` shatters the vector and asks
`checkUndeterminedObligation` **per argument**; each argument alone sees one impl of
`Ix` and the `| otherwise = ()` arm accepts it. The vector `Ix _ Bool`, which no
instance can ever satisfy, is never examined as a vector. At run time the literal's
`Int` fallback representation reaches the receiver-tag dispatch and `Ix Int Char`'s
body runs: `222`. The same mechanism yields `0` (a wrong value, not a crash) for
`d07_unique_float` under attempt2.

This is **reachable at base** with a non-literal receiver: `useIx (absent ())` with
`absent : Unit -> a` (`d21_undet_nonliteral`) is accepted by `check` at base — an
ill-typed program (`Ix ?a Bool` has no instance at any `?a`) — and only the deliberate
`panic` in `absent` stops it from running an unrelated impl. Attempt2 did not create
this defect; it made a literal reach it. It is §13 issue 1, S0.

S2's reject half is the fix: at the goal's vector, `U = ∅` with every variable owned
is `T-NO-IMPL`. `checkUndeterminedArgs`' per-argument loop is then redundant for
multi-argument goals and should be retired for them rather than kept beside the new
check.

---

## 8. Reporting (answers Q5)

Where a withheld-or-undetermined variable's goal is reported, by case, after S1–S5 at
the last boundary that owns every variable in it:

| state after S4 | code | site | message |
|---|---|---|---|
| `U = ∅`, every variable owned | `T-NO-IMPL` | the goal's recording site (`goalSiteLoc`), as `T-REQUIRES-DEPTH` does | `No impl of Ix for _ Bool: no instance of \`Ix\` has \`Bool\` in its second position, so no type for the first position can satisfy it.` A variable position renders as `_`, not as a letter — the letter reads as a name the program wrote. |
| `U′ = ∅`, `U ≠ ∅` (joint consistency emptied it) | nothing here | — | the variable defaults in S3 and the closed goal is checked as today (`No impl of Ix for Int Bool`) |
| `\|U′\| ≥ 2`, every variable owned, variable not a candidate | `T-AMBIGUOUS-INSTANCE`, message (1) | the goal's site | today's `ambiguousImplMsg`, with the goal vector rendered (`Ix _ Char`) and the two instances named, as message (2) already names its competitors |
| any unowned variable | deferred (OD2) | the use site | today's behaviour; the caller's instantiation decides |

Nothing above lets `check` accept what `run`/`build` reject: every state either commits
a type all three verbs then share, or rejects at `check`. The per-argument acceptance
is the only place today where `check` says yes to a vector no instance matches, and §7
retires it for `n ≥ 2`.

Codes: no new code. `T-NO-IMPL` gains a fourth reaching site in
`compiler/DIAGNOSTIC-CODES-DESIGN.md`'s table ("no impl, UNDETERMINED vector"), next
to the partially-ground row. `compiler/ERROR-QUALITY.md`'s register: state the fault
(no instance has `Bool` there), not the mechanism (nothing about defaulting or
determination), and no advice the reader cannot act on — "add a type annotation" is
wrong here, since no annotation makes `Ix _ Bool` satisfiable.

---

## 9. The three candidate rules, evaluated

| | **(a) today** — argument-reachable protection only | **(c) Haskell's rule** — a multi-param-mentioned variable is never a candidate | **(c) + determination** (a3) | **recommended** — D3's channels, argument channel closed under connection, after determination |
|---|---|---|---|---|
| sprint probes (4) on all three verbs | 0 of 4 | 2 of 4 (`p3521body`, `p3549` build fail) | 4 of 4 | 4 of 4 |
| Bytes face | reject | pass | pass | pass |
| table rows moved | 0 | 26 (13 check-accept/run-reject, 4 silenced rejects, 6 false rejects, 1 value diff, 2 build/code) | 14 | 1 (expected) |
| `useIx 1` at `Ix a Bool =>` | reject | **accepts, 222** | **accepts, 222** | reject |
| `[\|3, 4\|][0]` | 3 | **reject** | check 0, **build fails** | 3 |
| `ix 5 'z'`, only `Ix Float Char` | reject | **prints 0** | 2 | 2 |
| `f x = ix x 0` | 9 | check 0, run/build fail | check 0, run/build fail | 9 |
| self-compile, in-tree sweep | — | not reached | not reached | identical to base |

Rule (c) fails for a structural reason, not a tuning one: in Medaka the universal
indexing interface is 3-ary, so **every** indexed literal — `[|3, 4|][0]`, `xs[0] +
1`, `b[i] == 13` — mentions a multi-parameter predicate, and (c) withholds all of them.
Haskell lives with its rule because its `Num` literals almost never meet a
multi-parameter class in the prelude. The 13 check-accept/run-reject rows are the
withheld variable surviving to the per-argument acceptance of §7; the 6 false rejects
are the withheld variable surviving to the ambiguity check at `T4`. Adding
determination (a3) halves the damage and leaves the 222 and the `[|3, 4|][0]` build
failure — because determination cannot act where two instances unify (`d06`, `d20`'s
`Debug`), and (c) still forbids defaulting there.

The recommendation keeps D3 as written and adds one closure clause to one of its
channels. Its only table movement is the row the sprint contract predicted would move
(§4 F7 of the contract).

---

## 10. What the prototype's defects teach the implementation (hazards)

Each was found by the table or a probe, not by reading; each is an acceptance row for
§12.

- **H1 — level of minted instance variables** (§4.4). Rows: scheme lines
  `s4-joint-residual-rdict-native`, `s4-gen-residual-mixed-no-requires-control`; span
  `s4-gen-residual-mixed-vector-rejected` 45:16.
- **H2 — improvement's rigid set is the declared set, and nothing more.** Round 1 passed
  the connected variables to `improveByUniqueImpl` as if they were signature
  variables; `wrap y = pick [y] []` then could not bind `c` and generalized to `wrap : a
  -> b`, and `impl-improvement-unique-instance` failed to build. A connected variable is
  **owned**: improvement and determination bind it; only S3 leaves it alone. Row:
  `impl-improvement-unique-instance`.
- **H3 — the consistency test renders instance heads with fresh variables.** `fromAstType
  []` turns an unmapped instance variable into a rigid stand-in, and `Index (Array a)
  Int a` then read as binding the element to a non-numeric type; `a[0] == 1` at `Array
  Float` was rejected (round 3). Test against `freshRowHeads row`. Row: `p3437` /
  `impl-improvement-before-num-default`.
- **H4 — joint consistency by instance table, not by a list of heads.** The prototype's
  `numCandidateHeadOk` names the builtin numeric types; the implementation uses the
  instance table for the closed sibling goal (§4.3's general form). Row: a user
  `impl Num Money` indexed through `Index (Array Money) Int Money`.
- **H5 — a settled second pass is cheap and principled.** S4 measured no probe
  difference on the prototype; it is kept because S3 is a substitution and §3's "when"
  paragraph already runs improvement before defaulting for the same reason.
- **H6 — the method-body `Num` special case (#3506) is subsumed, and must be measured
  as such.** `bodyExtraNumObls`/`multiParamIds` protects a body variable a
  multi-parameter goal ties to the head; S2 determines those goals first and S3's
  channel reading covers the rest. Retire it only when the method-body rows
  (`impl-head-repeated-var-body-default`, `p3521body`, `p3549`, `d17`) pass without it.

---

## 11. Rulings needed before dispatch (one page for Val)

**R1 — the candidate rule.** Recommended: §3's S3 — D3's channels, argument channel
closed under connection, variables outside the type default. Alternative: the
2026-10-03 ruling (Haskell's rule), measured at 26 table rows alone and 14 with
determination, including `useIx 1` accepted printing 222 and `[|3, 4|][0]` rejected
(§9). The two differ on `f x = ix x 0` (`9` vs ambiguous) and on every indexed literal.
*Consequence of (c):* the sprint cannot land without re-pinning rows the spec derives.

**R2 — determination's legitimacy against §3's exclusion.** Recommended: narrow the
exclusion to unowned variables (§4.1's amendment), retire module-end grounding into
the quiescence call of the same function, amend T4's "default instance" sentence.
Alternative: keep the exclusion as written and keep gap #44's grounding as the
exception — then the Bytes face, `d07`, `d16` and `p3521body` stay rejected or wrong,
and the two mechanisms keep disagreeing on which goals they see.

**R3 — joint consistency (§4.3).** Recommended: filter candidates by the sibling goals
on the variables they bind; `d17` is then accepted (`3.75`, `7`). Alternative: no
filter; report a post-commit sibling failure as `T-NO-IMPL` on the original vector;
`d17` stays check-accept/run-reject at base and is filed (§13 issue 2). The filter's
safety property: a new instance can only turn an accept into a loud reject.

**R4 — the `d07` widening.** `ix 5 'z'` with only `impl Ix Float Char` prints `2`: the
literal becomes a `Float` because the one instance says so. This is new acceptance
(base rejects). It follows from R2 with no further rule; the question is whether Val
wants a literal's type decided by an instance at all. The Bytes face is the same
decision at `U8`, so R4 and the Bytes ruling stand or fall together.

**R5 — arity 1 stays with the undetermined-goal sprint** (§4.2). Recommended: yes.
Determination at arity ≥ 2 is the multi-parameter form of OD3's sole-impl default,
which already exists; whether arity 1 commits is #2028's family.

**R6 — the per-argument acceptance is an S0 and is fixed in this sprint, not filed
and deferred** (§7, §13 issue 1). It is reachable at base with `useIx (absent ())`.
Recommended: fix in S1, with `d21` as its acceptance row.

**R7 — `Index` declares no dependency** (§5). Recommended: none is added; a second
`Index Bytes Int _` instance would make `b[i] == 13` ambiguous at the use site, which
is correct for an interface that declares none. Declaring one is a separate language
question.

**R8 — #3437 closes fully** when S1 lands, and `BYTES-DESIGN.md:307-309` is rewritten
as in §5. The sprint's re-scoping of #3437 to the Bytes face is superseded.

---

## 12. Proposed sprint (contract outline)

Base: the merge of this document's PR. Tracking issue: new, under M-SOLVER if Val
reopens it; else none, as #3787 was. All slices extend `compiler/types/typecheck.mdk`
in place (#2586 sequences the split); no slice adds a file. Serial; none `parallel-ok`
(one file, one corpus, one snapshot).

| ID | Mission | Surface | Acceptance | Model | Depends |
|---|---|---|---|---|---|
| **S-determine** | S2 at the group boundary and at quiescence: `determineByUniqueInstance` with unowned variables rigid, fresh heads minted inside the level (H1), joint consistency by the instance table (H4), `U = ∅` with all variables owned → `T-NO-IMPL` at the goal site (§8). Retire `groundMultiParamObligations`/`uniqueImplTysFor` into the quiescence call. Retire `checkUndeterminedArgs`' per-argument loop for `n ≥ 2`. Spec: §3 third bullet, §3 last paragraph, §6.2 T4 sentence (§4.1); `DIAGNOSTIC-CODES-DESIGN.md` fourth `T-NO-IMPL` row; `BYTES-DESIGN.md:307-309` (§5). | `processSCC` settle region; `checkUndeterminedObligations`; the quiescence drain (`routeUndeterminedTop`'s caller); `improveGoal`'s helpers (`improvementPool`, `rowHeadUnifies`, `freshTvMap`). | New rows (all three verbs exact, hand-derived values in §6.1): `d03_bytes` `True`, `d08_let_bytes` `True`, `d19_bytes_range` REJECT "does not fit U8", `d07_unique_float` `2`, `d06_two_unifying` `1`, `d16_mk_conv` `True` with scheme `mk : Unit -> Bool`, `d20_literal_array_index` `3`, `d21_undet_nonliteral` REJECT `T-NO-IMPL` at the call, `x1`/`x2` scheme line `f : Conv c d => a -> b -> String` and values. Existing rows unchanged, in particular `s6-c1-*`, `impl-improvement-*`, `s3-sig-constraint-unsatisfiable-rejects`, `s-nary-truncated-goal-joint-rejects` (code and message). In-tree sweep identical to base. | opus: the level discipline (H1) and the ownership partition are the two places a plausible fix is wrong silently | — |
| **S-candidate-connected** | S3's channel reading at the group, `where` and `let` boundaries: the argument channel closed under connection over the boundary's goals, restricted to variables in a member's type; S4's second improve/determine pass. Spec: §6.3 D1 (settle order), D3 clause 2 (the channel text of §3 here). Drain the #1641 row to ACCEPT ×3. | `unprotectedNumCandidates`/`finalizeNumBoundary` callers for `NumBoundaryOwnedScc`, `…Group`, `…Member`; `connectedIds`. | New rows: `p3521top` `small`, `d15_sumat_unsigned` `3.75`/`7` with the scheme line `sumAt : (Index a b d, Index a c d, Num d) => a -> b -> c -> d`, `d13_ix_x_0` `9`, `d12_orphan_get` REJECT at the call. `impl-head-repeated-var-body-default` → ACCEPT ×3 `total=3.75`, `total=7`; its control unchanged. In-tree sweep identical. | sonnet, upgrade to opus on the first table movement outside the enumerated rows | S-determine |
| **S-method-body-settle** | S1–S5 at the impl/default method-body boundary with head and method variables rigid (slice 2's representation), before `checkMethodRigidityCore` and again after the body's defaulting. Replace §3's "Not yet applied inside a method body" paragraph. Measure whether `bodyExtraNumObls`/`multiParamIds` (#3506) is subsumed (H6) and retire it only on a green table. Closes #3521 (both faces), #3549, #3437. | `inferMethodBody` around `addedCallObls` and after `finalizeNumBoundary`. | New rows: `p3521body` `3.75`/`7`, `p3549` `[3, 7]` built, `d17_body_two_index` per R3. All #3506 rows unchanged. Self-compile green; in-tree sweep identical. | opus: the body boundary has two rigid sets and one survivor walk shared with W3-inst | S-determine, S-candidate-connected |

**Acceptance measurement, every slice (in-tree, run by the implementer and read by the
reviewer):**

```sh
MEDAKA_STRICT=1 ./medaka test test/diff_compiler_dict_semantics_test.mdk      # verdict, scheme, span tables; ~5 min
MEDAKA_STRICT=1 ./medaka test test/diff_compiler_run_check_agreement_test.mdk  # check/run agreement corpus
sh test/preflight.sh                                                           # derived gates + oracles
make medaka                                                                    # self-compile at the new rule
```
plus the in-tree sweep (`check` over `stdlib/*.mdk`, `stdlib/*/*.mdk`,
`compiler/driver/medaka_cli.mdk`; the base log is
`…/reports/intree-base.log`) — **byte-identical or stop**. New fixtures go in
`test/dict_fixtures/` with the hand-derived expectation in the header, enrolled as
`Row`s with `tableRows` bumped; `d21` is a REJECT row with `codes = [Present
"T-NO-IMPL"]` and a `SpanRow` at the call. Every slice also runs the engines with
`MEDAKA_REQUIRE_WASM=1` on its new fixtures.

**Stop conditions (report, do not work around):** a table row outside the slice's
enumerated movers changes verdict, value or code; the in-tree sweep differs from base;
`make medaka` fails at stage B; a scheme line in `test/snapshots/` or
`test/selfproc_goldens/legA/` moves other than by addition; any fix that needs the
interface's or the type's name.

**Rulings before dispatch:** R1, R2, R3 (§11). R4–R8 can be taken from the
recommendations without blocking.

---

## 13. Issues this pass filed (2026-10-04)

**1. #3808, S0 — `check` accepts a multi-argument goal no instance can satisfy, per argument.**
`checkUndeterminedArgs` (`compiler/types/typecheck.mdk:37312`) asks
`checkUndeterminedObligation` one argument at a time; the `| otherwise = ()` arm
accepts each argument that has exactly one impl at its position. The vector is never
checked. Repro (base `c57d595ce`): `interface Ix a b where ix : a -> b -> Int`, `impl Ix
Int Char`, `useIx : Ix a Bool => a -> Int`, `absent : Unit -> a; absent u = panic ""`,
`main = println (useIx (absent ()))` — `check` exit 0, scheme printed, on a program
whose goal `Ix _ Bool` has no instance at any first argument. With a literal receiver
it is masked by defaulting today; under any rule that withholds the literal's variable
it accepts `useIx 1` and prints `222` from `Ix Int Char`'s body. Fix: §8's `T-NO-IMPL`
on the vector (S-determine). Acceptance: `d21_undet_nonliteral` REJECT ×3.
Labels: `S0: silent wrongness`, `ws:typecheck`.

**2. #3809, S0 — two `Index` instances at one head: `check` accepts, `run` and `build` reject.**
`impl Index (Array a) Rng (Array a)` beside the prelude's `Index (Array a) Int a`, body
`report v = debug (v[0] + v[1])` under `impl Report (Array a) requires Num a, Debug a`
(`probes/d3/d17_body_two_index.mdk`). `check` exit 0; `run` `E-AMBIGUOUS-DISPATCH:
arg-tag dispatch on a receiver of type 'Array' is undecidable`; `build` `no impl of
method 'index' for instance 'Array'`. Under §4.3's filter the goal is determined and
the program prints `3.75`, `7`; without it the three verbs must at least agree
(`T-AMBIGUOUS-INSTANCE` at `check`). Labels: `S0: silent wrongness`, `ws:typecheck`;
closes with S-method-body-settle or with R3's alternative.

**3. #3810, S2 — a printed scheme carries a context variable its type does not mention.**
`sumAt : Num b => Array a -> Int -> Int -> a` is what `check` prints for
`impl-head-repeated-var-body-default-control`'s `sumAt`; `b` occurs in no type. The
scheme the binary uses is right (`total=3.75`, `total=7`); the rendering is not the
scheme. Same family as `h : a -> String` rendered for a binding whose context was
dropped (§4.4), which is why the scheme lines in `dict_semantics` are load-bearing: a
reader cannot tell a cosmetic orphan from a lost dictionary. Fix: render the
generalized scheme after improvement has re-linked the variable, or print the orphan
with its binding (`Num a`). Labels: `S2: misleading`, `ws:diagnostics`.

**4. #3811, S2 — a stdlib-located `T-NO-IMPL` is printed under the user's file name.** At base,
`d19_bytes_range` (8 lines) rejects with `…/d19_bytes_range.mdk:928:21: No impl of Index
for Bytes Int Int` beside the correct `8:15: Type mismatch: Int vs U8`. Line 928 is in
`stdlib/bytes.mdk`; the goal's location carries the stdlib position with the user
file's name. Observed on `check` and `build`; `run` prints only the mismatch. Not
caused by this design and not fixed by it; recorded because the S-determine rows will
pin locations on this shape. Labels: `S2: misleading`, `ws:diagnostics`.

---

## 14. Spec and document edits this design requires (checklist)

- `docs/spec/DICT-SEMANTICS.md` §3: third exclusion bullet (§4.1); the "When"
  paragraph (settle order S1–S5); the "Not yet applied inside a method body" paragraph
  (S-method-body-settle); the last paragraph on `groundMultiParamObligations`.
- §4.2 OD3: note that arity ≥ 2 determines rather than sole-impl-accepts.
- §6.2 T4: the "default instance" sentence.
- §6.3 D1: "last determination step" becomes "the third step of the settle sequence";
  D3 clause 2: the argument channel's closure clause; the #3506 paragraph goes when H6
  is measured.
- §11 rows for D1–D3, T3–T4.
- `compiler/DIAGNOSTIC-CODES-DESIGN.md`: fourth `T-NO-IMPL` row.
- `docs/design/BYTES-DESIGN.md:307-309` (§5).
- `test/MUST-FAIL-NOT-PINNABLE.txt` / `test/must_fail_fixtures/`: the `3437-*` pin
  drains with S-determine ([G-PIN-DRAIN]).
