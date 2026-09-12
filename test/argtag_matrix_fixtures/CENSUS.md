# The arg-tag decidability census

**Status:** LIVE. Graded by test/diff_compiler_argtag_matrix.sh, which cites it as the source of its pins.

Graded by [`test/diff_compiler_argtag_matrix.sh`](../diff_compiler_argtag_matrix.sh).
Serves [#2032](https://github.com/MedakaLang/medaka/issues/2032) (the
`T-LOCAL-CONSTRAINED-MONO` pin-narrowing question) and
[#2445](https://github.com/MedakaLang/medaka/issues/2445).

## What this census is

`T-LOCAL-CONSTRAINED-MONO` rejects a REGION of programs at check time: any local binding
whose body reaches a constrained method call and which is then used at two types
(`docs/KNOWN-GAPS.md`, "Known over-reject: a plain ground-type local also gets pinned").
Because the region is rejected, what the compiler *would* do with it is unobservable, and
#2032's question — *can the pin be narrowed?* — is a question entirely about that
unobservable region. The previous sprint answered from a hand-picked sample, which its
reviewer correctly called **"a lower bound, not closed."**

The test-only hatch `MEDAKA_ARGTAG_UNPIN=1` (`setLocalPinDisabled`,
`compiler/driver/medaka_cli.mdk` → `localPinPairs`, `compiler/types/typecheck.mdk`) drops
every pin channel so the region typechecks. This directory drives a **product of two
axes** through it and records, per cell, what the semantics *require* and what each engine
actually *does*.

**Every `expected.txt` here was written from the mechanism, never captured**
([WT-GOLDEN-ENSHRINES]). Several deliberately pin a WRONG ANSWER, because that wrong answer
IS the evidence. A cell that goes red must be **re-classified**, not re-blessed — see the
gate's header.

## The axes, and how far their product is actually sampled

A cell's outcome is decided at the one shared call site inside the pinned local, by
`emitArgDispatchChain` (`compiler/backend/llvm_emit.mdk:6393`), which tests
`emitTagMatch e tagReg (ctorsOfType e (groupTag g))` per group. That function has exactly
**two** inputs, so the matrix enumerates over exactly two axes:

**Axis B — the group set** (`groupImpls` / `distinctImplKeys`, `llvm_emit.mdk:7350`; groups
are keyed by `(method, canonical impl key)`). A single impl either **defines the method** or
**does not, and inherits the interface default**; there is no third way for one impl to
supply a method. But axis B is not a property of one impl — it is a property of the PAIR
being discriminated, and a pair of two-valued impls has **three** shapes:

| value | the pair |
|---|---|
| `B1_both_defined` | both impls define the method |
| `B2_one_default` | one defines it, the other inherits the interface default |
| `B3_both_inherit_default` | **neither** defines it; both inherit ONE interface default |

🚨 **This census originally enumerated B at two values and argued that made it exhausted.**
That argument was wrong, and wrong in the way that matters: it read the two-valuedness off a
single impl and then used it as the arity of a pairwise axis. `B3` is not a relabelling of
`B2` — it is the one shape in which *no* group in the method's group set carries a body of
its own, so every arm of the chain routes to the same inherited default and the receiver
identity has to survive *through* that default to reach the per-impl method it calls. That
is a distinct mechanism with a distinct, and silently wrong, native answer (see
`A1_distinct_user_heads__B3_both_inherit_default` below).

**Axis A — the per-group constructor-cell-tag set**, `ctorsOfType e (groupTag g)`. A head
type's ctor set is determined by its tycon, so for a *pair* of heads the only possible
relations between their tag sets are: both empty, one empty, equal, or disjoint. That is
four relations, and A enumerates all four —

| value | shape | tag-set relation |
|---|---|---|
| `A1_distinct_user_heads` | `Dog` / `Cat` | disjoint, both non-empty |
| `A2_same_head_diff_args` | `Box Int` / `Box String` | **equal** (one tycon, so one tag set) |
| `A3_both_primitive` | `Int` / `Bool` | **both empty** (a primitive receiver carries no cell tag) |
| `A4_mixed_primitive` | `Cat` / `Int` | **one empty** |
| `A5_open_head` | `Box a requires Speak a` / `Cat` | disjoint, reached through an OPEN head |

`A5` is not a fifth relation — it is `A1`'s relation spelled with a parametric,
`requires`-carrying head. It is enumerated anyway because a reader would otherwise
reasonably suspect that `requires`-carriage is a fifth case; it is not, because a `requires`
changes what the selected arm *does* (it needs an inner dict), never how the arm is
*selected*. Recording that explicitly is what closes the axis rather than leaving it
argued-by-omission.

**How much of `A × B` this corpus actually holds, stated plainly.** `A` has 5 values and
`B` has 3, so the full product is 15 cells. This corpus holds **11** of them: the complete
`A1…A5 × {B1, B2}` sub-product (10 cells), plus `A1 × B3`. The four remaining `B3` cells
(`A2 × B3` … `A5 × B3`) are **not enumerated**, and this census does not claim they are.

`A1 × B3` is the one that was added, and the choice is not arbitrary: `A1`'s heads are
disjoint and both non-empty, so it is the only `A` value where the discrimination *ought*
to succeed outright. A `B3`-only defect shows there uncontaminated by an A-axis collision
(`A2`), by a missing cell tag (`A3`, `A4`), or by a `requires`-body failure (`A5`) — every
one of which already fails for its own reason before `B` is consulted at all. So `A1 × B3`
is where a B3 mechanism is *visible*, and it is the cell that makes the coverage claim
above an honest one rather than a claim resting on an axis miscounted as two-valued.

**Falsification test for what is claimed.** Exhibit a program in the masked region whose
outcome differs from the cell with the same `(A, B)` coordinates. Since the outcome is a
function of the two inputs above and nothing else, such a program would prove
`emitArgDispatchChain` has a third input the matrix does not enumerate — and that is
exactly the finding this census would want. ⚠️ Note that the previous version of this
paragraph made that falsification test the whole warrant for a completeness claim, and it
did not catch `B3` — because a miscounted axis is not a third *input*, it is a missing
*value* of an enumerated one, and no amount of probing at `(A, B1)`/`(A, B2)` reaches it.
A reader auditing this corpus should re-derive each axis's arity from the mechanism before
trusting a product argument built on it.

## The headline result, re-measured: the region is NOT uniformly broken

**The previous headline was an artifact of the instrument, and this section corrects it.**
This census's first measurement (#2445) reported every masked cell wrong on the native
engine — `A1_distinct_user_heads__B1_both_defined`, two ordinary impls at two distinct user
tycons with no method-less impl anywhere, printed `woof|woof` silently at exit 0 — and
concluded that a `let`-local lowers to ONE lifted lambda with ONE shared route ref that
cannot serve two instantiations (the #1082 blocker). The regime argument under § "The
cells" asserted that the hatch reached the build path because `medaka build` runs the same
typechecker. It reaches the CLI's own typecheck gate, which is what that argument
measured; it did NOT reach the separate `medaka_emitter` process, whose elaboration is the
one the emitted IR is lowered from. That process never read `MEDAKA_ARGTAG_UNPIN`, so its
elaboration ran with the pin ARMED: `f` was narrowed to its first instantiation (`Dog`),
the `T-LOCAL-CONSTRAINED-MONO` error it recorded was discarded (the emit driver never read
`hadTypeErrors` — #2089), and `f Cat` was compiled against `Dog`'s impl. `woof|woof` was
the pin's own narrowing leaking through a discarded type error, not a route-ref collapse.
The emit driver now arms the hatch exactly as the CLI does (`argtagUnpinArmed`,
`compiler/entries/entry_support.mdk`), and the #2089 gate rejects a build whose emit-path
elaboration recorded that error under `MEDAKA_STRICT=1` — which is how the discrepancy
surfaced.

Re-measured with the hatch reaching the emitter, the picture is what the mechanism
predicts:

- **`A1` (disjoint, non-empty tag sets) is `decidable` on all three `B` values.** Two
  groups, two distinct tags, `emitArgDispatchChain` tests them and the right arm runs —
  including `B3`, where the receiver identity survives through the shared inherited default
  to the per-impl `name`. `woof|meow` and `<dog>|<cat>` on both engines.
- **`A5__B2` is `decidable`** for the same reason: once the parametric arm needs no inner
  dict, its selection is `A1`'s.
- **`A2` (equal tag sets) is `undecidable-by-construction` and now SAYS SO on the native
  engine too**: the binary builds and traps with `E-AMBIGUOUS-DISPATCH` on the first
  receiver, instead of the emitter panicking about a `fromInt` the program never mentions.
- **Both `A6` cells are now `decidable`.** Their top-level inferred `go` carries the
  complete `Wrap f` predicate as a dictionary parameter, and each ground call supplies
  the exact `Wrap (Pair Int)` or `Wrap (Pair String)` dictionary. The historical fixture
  names record the old route; neither call now reaches the arg-tag chain.
- **`A3`/`A4` (a receiver with no cell tag) stay `undecidable-by-construction`**; the build
  still aborts, now with the emitter naming the actual reason (`arg-tag dispatch on impl
  type that owns no constructors`) instead of the `fromInt` panic.
- **`A5__B1` stays a `bug`**: the `requires`-carrying arm's body still has no route to its
  inner dict; the native failure moved from `E-NONEXHAUSTIVE-MATCH` to a memory fault (exit
  139 — the shell's 128+SIGSEGV convention, not a code the binary chose), loud on both
  engines.

The control is unchanged. Where a call still reaches the arg-tag route, the only shapes it
cannot decide are the ones where the tag is strictly weaker than the type identity (`A2`)
or absent (`A3`/`A4`). The `A6` calls now carry exact predicate evidence and bypass that
route entirely; this is why their same-head types are distinguishable without weakening
the `A2` controls.

**Consequence for #2032's fix order.** The narrowing is NOT blocked on #1082 for the
disjoint-head shapes: `A1__B1`, `A1__B2`, `A1__B3` and `A5__B2` are correct on the native
engine as built. The shape #1046 names (`A1__B2`, one method-less impl) answers correctly
here. What remains is the `requires`-body failure (`A5__B1`, the #1082 shape proper) and
the `A2`/`A3`/`A4` undecidable classes, which any narrowing must keep pinned — or route
by a different mechanism — exactly as `docs/KNOWN-GAPS.md` says.

## Classification vocabulary

- **`decidable`** — both engines produce the semantically correct answer.
- **`undecidable-by-construction`** — the arg-tag route cannot decide this shape *even in
  principle*, because the constructor cell tag it tests is strictly weaker than the type
  identity the dispatch decision needs (or the receiver carries no cell tag at all, which
  `argDefaultEmittable`, `llvm_emit.mdk:6335`, already declines). No narrowing of the pin
  could ever make such a cell correct; only a different mechanism could.
- **`bug`** — the information available *is* sufficient (the control, or `medaka run`,
  produces the right answer from it) and the implementation gets it wrong anyway.

## The cells

Every cell's `check` is `0`: under the hatch, the whole region typechecks. That is the
hatch working, and it is why the region is observable at all.

**Which regime each column observes — measured, not assumed.** All four graded columns
(`check:`, `run:`, `build:`, `exec:`) are produced with `MEDAKA_ARGTAG_UNPIN=1` set, so all
four observe the **unpinned** regime. That is true of `build:` only because the emit
driver arms the hatch ITSELF (`argtagUnpinArmed`, `compiler/entries/entry_support.mdk`):
`medaka build` runs the CLI's typecheck gate in one process and the elaboration the IR is
lowered from in another (`medaka_emitter`), and an environment variable the CLI honours
says nothing about what the emitter did with it. This census's first measurement was
taken with the emitter NOT honouring it — see § headline result. The discriminating
measurement, on `A1__B1`, with the hatch dropped from the build alone:

```
$ ./medaka build test/argtag_matrix_fixtures/A1_distinct_user_heads__B1_both_defined/main.mdk -o /tmp/x
error: …main.mdk:15:6: local binding 'f' is used at two different types (Dog and Cat), but
it cannot be polymorphic: its body calls something that needs a 'Speak' instance, and only
top-level definitions can carry that constraint
$ echo $?
1
```

And with the hatch reaching the CLI but withheld from the emitter (the pre-correction
state), the same build exits 0 and the binary prints `woof|woof`: the emitter's own
elaboration recorded that diagnostic, discarded it, and compiled the narrowed local. A
`build:` line reading `0 | built …` alongside a correct `exec:` is therefore evidence the
hatch reached the emitter; a `0 | built …` alongside a wrong `exec:` is the signature of
it not having done so.

| cell | class | correct | `run` (eval) | native binary |
|---|---|---|---|---|
| `A1…__B1_both_defined` | decidable | `woof\|meow` | ✅ `woof\|meow` | ✅ `woof\|meow` |
| `A1…__B2_one_default` | decidable | `woof\|meow` | ✅ `woof\|meow` | ✅ `woof\|meow` |
| `A1…__B3_both_inherit_default` | decidable | `<dog>\|<cat>` | ✅ `<dog>\|<cat>` | ✅ `<dog>\|<cat>` |
| `A2…__B1_both_defined` | undecidable | `boxint\|boxstr` | E-AMBIGUOUS-DISPATCH, exit 1 | builds; E-AMBIGUOUS-DISPATCH at run, exit 1 |
| `A2…__B2_one_default` | undecidable | `boxint\|boxstr` | E-AMBIGUOUS-DISPATCH, exit 1 | builds; E-AMBIGUOUS-DISPATCH at run, exit 1 |
| `A3…__B1_both_defined` | undecidable | `int\|bool` | ✅ `int\|bool` | build aborts (no cell tag), exit 1 |
| `A3…__B2_one_default` | undecidable | `int\|bool` | ✅ `int\|bool` | build aborts (no cell tag), exit 1 |
| `A4…__B1_both_defined` | undecidable | `meow\|int` | ✅ `meow\|int` | build aborts (no cell tag), exit 1 |
| `A4…__B2_one_default` | undecidable | `meow\|int` | ✅ `meow\|int` | build aborts (no cell tag), exit 1 |
| `A5…__B1_both_defined` | bug | `[meow]\|meow` | E-PANIC, exit 1 | builds; memory fault, exit 139 |
| `A5…__B2_one_default` | decidable | `box\|meow` | ✅ `box\|meow` | ✅ `box\|meow` |
| `A6…__no_local` | decidable | `1\|2` | ✅ `1\|2` | ✅ `1\|2` |
| `A6…__one_default` | decidable | `9\|2` | ✅ `9\|2` | ✅ `9\|2` |
| `A7…__one_default` | decidable | `9\|2` | ✅ | ✅ |
| `CONTROL…__not_pinned` | decidable | `woof\|meow//woof\|meow` | ✅ | ✅ |

### A1_distinct_user_heads__B1_both_defined

**`decidable`.** Two impls, two distinct user tycons, both defining the method — disjoint
non-empty tag sets, two groups, everything `emitArgDispatchChain` needs — and it decides:
`woof|meow` on both engines.

⚠️ **This cell MOVED from `bug` to `decidable`, and the reason is the instrument, not the
route.** It was this census's headline: the native binary printed `woof|woof` at exit 0
while `medaka run` printed `woof|meow`, read as a one-route-ref collapse in the lifted
local. That measurement was taken with the hatch reaching the CLI's typecheck gate but not
the `medaka_emitter` process, whose elaboration pinned `f` to `Dog`, recorded the
`T-LOCAL-CONSTRAINED-MONO` error, had it discarded (#2089), and compiled `f Cat` against
`Dog`'s impl. See § headline result. Re-deriving `woof|woof` here would restore the
un-hatched emitter, not a finding about dispatch.

### A1_distinct_user_heads__B2_one_default

**`decidable`.** `A1__B1` with `impl Speak Dog where` left method-less so the interface
default supplies `speak`. This is #1046's named shape, and it answers `woof|meow` on both
engines: the default's group is selected by `Dog`'s tag exactly as a defining impl's would
be. Moved from `bug` with `A1__B1`, for the same reason — the pinned-emitter artifact
produced `woof|woof` here too, which is why the two shapes looked identical.

### A1_distinct_user_heads__B3_both_inherit_default

**`decidable`**, and the cell whose *absence* refuted this census's own completeness
argument (#2445 review round, S-3's finding). `A1`'s two disjoint user heads, with `speak`
left undefined on **both** impls so both inherit ONE interface default:

```
interface Speak a where
  name  : a -> String
  speak : a -> String
  speak v = "<" ++ name v ++ ">"

impl Speak Dog where
  name _ = "dog"
impl Speak Cat where
  name _ = "cat"
```

The default is receiver-derived — it dispatches `name v` on the same receiver — so the two
instances must print different strings even though they share one `speak` body. Correct is
`<dog>|<cat>`, and both engines produce it: the receiver identity survives through the
shared inherited default to the per-impl `name`.

**Why this cell still earns its place.** In `B2` exactly one group carries a body of its
own; in `B3` **no** group does — every arm of the chain routes into the same inherited
default, and the discriminating call is *inside* that default. Nothing in the `B1`/`B2`
pair exercises that, and the old two-valued count of axis B could not have found it. It
moved from `bug` (`<dog>|<dog>` at exit 0) with the rest of `A1` — see § headline result.

### A2_same_head_diff_args__B1_both_defined

**`undecidable-by-construction`**, and the cleanest instance of the mechanism §4 of the
S-1 packet names. `Box Int` and `Box String` are two impls with two distinct canonical
impl keys, so `groupImpls` yields TWO groups — but `ctorsOfType e (groupTag g)` is
`{Box}` for both, because a tycon determines its ctor set and there is one tycon here. Two
groups, one runtime test. The cell tag is strictly weaker than the type identity the
decision needs, so no amount of narrowing helps.

⚠️ **This cell's `run` line MOVED in #2445 S-3, and the class did not.** Eval used to
answer `boxint|boxint` **silently, at exit 0** — `filterByTag` kept both candidates
(they share the head tag) and `collectPartials` took the first one that applied. It now
refuses with `E-AMBIGUOUS-DISPATCH` at exit 1 (`checkArgTagDecidable`, `eval/eval.mdk`).
Re-deriving `boxint|boxint` here would be a regression, not a repair.

⚠️ **Its `build`/`exec` lines MOVED with the hatch reaching the emitter, and the class did
not.** The native side used to abort the whole build with the emitter's own `fromInt`
panic — a symptom of the pinned local's narrowed numeric literal, not of this cell (see §
headline result). It now BUILDS at exit 0 and traps with `E-AMBIGUOUS-DISPATCH` on the
first receiver. The correct answer is unreachable on this route either way; what changed
is that both engines now say so at the same phase. `A6__no_local` used to exercise the
same retimed refusal, but now bypasses the route with an exact predicate dictionary; its
section below explains why that does not change this local-binding cell.

### A2_same_head_diff_args__B2_one_default

**`undecidable-by-construction`.** `A2__B1` with the `Box Int` impl method-less. Identical
outcome on both engines (eval's S-3 refusal, the binary's retimed trap), which is the
point: at a head collision, axis B does not matter — the tag sets are equal whatever the
group set is, so the discrimination has already failed before the group set is consulted.
This cell is what makes "A2 is undecidable" a statement about the *head*, not about a
particular impl spelling.

### A3_both_primitive__B1_both_defined

**`undecidable-by-construction` on the arg-tag route.** `Int` and `Bool` are primitive
receivers and carry no constructor cell tag at all — `argDefaultEmittable`
(`llvm_emit.mdk:6335`) already declines such heads by design, so there is no tag for
`emitTagMatch` to test. `medaka build` aborts at exit 1, and since the hatch reaches the
emitter it aborts with the emitter naming that reason (`arg-tag dispatch on impl type that
owns no constructors (primitive receiver carries no cell tag)`) rather than the `fromInt`
panic the pinned local used to produce first.

⚠️ Note the engines part company here, and the reason matters for #2032: `medaka run`
answers `int|bool` **correctly**, because eval discriminates on the runtime *value* tag,
which does distinguish an `Int` from a `Bool`. So this shape is undecidable on the
emitter's ctor-cell-tag route specifically, not undecidable in principle. It is classified
`undecidable-by-construction` because the pin's narrowing question is a question about the
route that is built.

### A3_both_primitive__B2_one_default

**`undecidable-by-construction`.** `A3__B1` with the `Int` impl method-less. Same outcome
on both engines — as in `A2__B2`, axis B cannot rescue a discrimination that has no tag to
test in the first place.

### A4_mixed_primitive__B1_both_defined

**`undecidable-by-construction`.** One user head (`Cat`) with a tag, one primitive head
(`Int`) without. A chain can test the `Cat` arm but has nothing to test for the `Int` arm,
so the pair is not separable by the route. `medaka build` aborts at exit 1 with the same
no-cell-tag reason as `A3`; eval again gets it right by value tag. This is the "one empty"
relation, and it behaves like the "both empty" one rather than like the disjoint one —
worth recording, because a reader might expect the tagged half to survive.

### A4_mixed_primitive__B2_one_default

**`undecidable-by-construction`.** `A4__B1` with `impl Speak Cat` method-less. Unchanged, for
the `A2__B2` / `A3__B2` reason.

### A5_open_head__B1_both_defined

**`bug`.** `impl Speak (Box a) requires Speak a` and `impl Speak Cat` — disjoint heads, so
the discrimination is `A1`'s and it succeeds (its `B2` sibling proves that). What fails is
the `requires`-carrying arm's **body**: the inner `speak x` needs a dict for `a`, and the
local has no route to give it one. `medaka run` dies with
`E-PANIC: '++' requires Semigroup (List, String, or a type with append)`; the native binary
builds cleanly (exit 0) and dies with a memory fault (exit 139). Neither failure is about
tag discrimination; both are downstream of selection. Classified `bug` because the
selection information is sufficient.

⚠️ **The native failure MOVED with the hatch reaching the emitter** — from
`E-NONEXHAUSTIVE-MATCH` to `E-FATAL-SIGNAL`. Under the pinned emitter the local was
narrowed to its first instantiation and the parametric arm's missing inner dict surfaced
as a non-exhaustive match; with the local genuinely polymorphic the missing dict is read as
a word. Same defect, one phase later; this is the `#1082` shape proper. Loud on both
engines, so not a silent-wrongness cell.

### A5_open_head__B2_one_default

**`decidable`.** `A5__B1` with the parametric `impl Speak (Box a) requires Speak a` left
method-less, so the interface default supplies `speak` and the arm no longer needs an inner
dict. That removes `A5__B1`'s body failure and leaves selection alone, which is `A1`'s:
`box|meow` on both engines. Moved from `bug` (`box|box` at exit 0) with `A1` — the same
pinned-emitter artifact, see § headline result. The pair `A5__B1`/`A5__B2` is therefore
useful evidence on its own: it separates the `requires`-body failure from selection, and
shows the body failure is what remains once selection is made trivial.

### A6_same_head_chain_reached__no_local

**`decidable`.** The historical name records the route this source used before complete
inferred predicate slots landed. `go` has the principal scheme
`Wrap f => f a -> Int`; as a top-level binding it can abstract that predicate. Its slot
now retains the known argument vector `[f]`, so the two calls instantiate and pass two
different dictionaries: `Wrap (Pair Int)` and `Wrap (Pair String)`.

The emitted shape makes the new classification falsifiable. At base `42a672d04`, `go`
was `go(value)` and its body contained an arg-tag chain whose two `Pair` arms both called
`@mdk_dispatch_ambiguous`; eval and the native executable exited 1. On the repaired source,
`go` is `go(dict, value)`, its body calls `@mdk_disp_wsize_0_1(dict, value)`, and the two
call sites supply distinct canonical dictionary constants. The dispatcher matches those
keys to the exact `Pair Int` and `Pair String` rows. Both engines therefore print the
hand-derived `1|2` at exit 0.

This does not reclassify A2. Its constrained helper is local and, under the unpin hatch,
has no top-level predicate abstraction from which a complete dictionary can be passed.
It still reaches the arg-tag route, where one `Box` constructor tag cannot distinguish
`Box Int` from `Box String`. A6 is decidable because it no longer asks that route to make
the decision.

### A6_same_head_chain_reached__one_default

**`decidable`.** This is the inherited-default twin of `A6__no_local`. The `Pair Int`
instance contributes no explicit `wsize` body, but it still contributes the exact
`Wrap (Pair Int)` dictionary selected at the first call. The dictionary dispatcher sends
that key to the interface default, while the distinct `Wrap (Pair String)` key reaches the
explicit body returning `2`. Eval and native therefore print the hand-derived `9|2`.

At base `42a672d04`, both calls lacked the dictionary parameter and reached the raw/group
arg-tag guard, producing `E-AMBIGUOUS-DISPATCH`. The repaired `go(dict, value)` shape
removes that decision from the raw leg. `A2__B2` remains the control for a local occurrence
that still reaches a same-head arg-tag route and must stay loud.

### A7_distinct_heads_chain_reached__one_default

**`decidable`, and the historical negative control for `A6__one_default`'s old raw-leg
route.** It now follows the same repaired predicate path as A6: top-level `go` receives an
exact dictionary. The inheriting instance sits at `Solo` and the defining one at
`Pair Int`, so the two call sites pass distinct `Wrap Solo` and `Wrap (Pair Int)` evidence.
Correct remains `9|2` on both engines.

The cell no longer exercises the arg-tag raw leg, and this census does not claim it does.
It remains a useful control for the feature A6/B2 varies: one instance inherits the
interface default while the other defines the method, across two distinct heads. A
regression that collapsed complete `Wrap f` predicate slots or lost the inherited row
would move it. It is also the one `B2` cell in the corpus whose native default arm is
correct; the other B2 cells exercise separate mechanisms described above.

### CONTROL_toplevel_helper__not_pinned

**`decidable` — and deliberately OUTSIDE the masked region.** Same interface, same impls,
same head constructors, same use sites as `A1__B1`; the single difference is that the helper
is a top-level definition, which IS dict-abstracted, instead of a `let`-local. Correct on
both engines (`woof|meow//woof|meow`).

This cell exists for the reason `diff_compiler_must_fail.sh` requires a control on every
fixture: without it, `A1__B1`'s wrong answer would be consistent with "this interface, these
impls or these two tycons are broken", and the census's central claim would be an inference
rather than a measurement. **If this cell ever goes red, the environment broke, not the
region** — do not read it as progress on #2032.

## The emitter's `fromInt` panic, resolved

Six of the eleven masked cells (`A2`, `A3`, `A4`) used to fail `medaka build` at exit 1 with

```
error: emitter failed compiling main.mdk
runtime error [E-PANIC]: no impl of method 'fromInt' for type 'String'
```

naming a method none of these programs mention. It was recorded here as an S2-misleading
finding. It was the pinned emitter again: with the local narrowed to its first
instantiation, the emitter's elaboration left a numeric-literal route on the local's body
unresolved and the emitter panicked on the second receiver. With the hatch reaching the
emitter the panic is gone: `A2` builds and traps at run time with `E-AMBIGUOUS-DISPATCH`,
and `A3`/`A4` abort the build naming the actual reason — a primitive receiver carries no
cell tag.
