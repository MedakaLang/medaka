# The arg-tag decidability census

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

## The axes, and why their product is complete

A cell's outcome is decided at the one shared call site inside the pinned local, by
`emitArgDispatchChain` (`compiler/backend/llvm_emit.mdk:6393`), which tests
`emitTagMatch e tagReg (ctorsOfType e (groupTag g))` per group. That function has exactly
**two** inputs, so the matrix enumerates over exactly two axes:

**Axis B — the group set** (`groupImpls` / `distinctImplKeys`, `llvm_emit.mdk:7350`; groups
are keyed by `(method, canonical impl key)`). An impl either **defines the method** (B1) or
**does not, and inherits the interface default** (B2). There is no third way for an impl to
supply a method, so B is exhausted at two values.

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

`A × B` is therefore the product, giving the **10 cells** below, plus **one control**
(`CONTROL_toplevel_helper__not_pinned`) that is deliberately *outside* the region.

**Falsification test for this claim.** Exhibit a program in the masked region whose
outcome differs from the cell with the same `(A, B)` coordinates. Since the outcome is a
function of the two inputs above and nothing else, such a program would prove
`emitArgDispatchChain` has a third input the matrix does not enumerate — and that is
exactly the finding this census would want.

## 🚨 The headline result: the region is uniformly broken, and NOT for the reason on record

`docs/KNOWN-GAPS.md` states that the narrowing is blocked specifically on
[#1046](https://github.com/MedakaLang/medaka/issues/1046) — the method-less-`impl` arg-tag
group collapse — and that fixing #1046 then unblocks the preserved
`enclosingRigidScopeInPlay` narrowing. **The matrix refutes the "specifically" and leaves
the conclusion standing for a broader reason.**

`A1_distinct_user_heads__B1_both_defined` has **no method-less impl at all** — two ordinary
impls at two distinct user tycons, the friendliest possible shape — and the native binary
still prints `woof|woof` instead of `woof|meow`, **silently, at exit 0**, while `medaka run`
prints the correct `woof|meow`. Zero of the ten masked cells produce the correct answer on
both engines. The `decidable` class is populated only by the control, which is not in the
region.

The discriminating measurement is the control. It holds the interface, the impls, the head
constructors and the use sites fixed and changes **one thing** — the helper is a top-level
definition rather than a `let`-local:

```
topF : Speak a => a -> String
topF v = speak v
main = println (speak Dog ++ "|" ++ speak Cat ++ "//" ++ topF Dog ++ "|" ++ topF Cat)
```
```
woof|meow//woof|meow      <- correct, on both engines
```

So the information needed to dispatch is present, and the group/tag machinery handles it
correctly. What fails is specific to the **local**: `dict_pass` prepends `$dict_…` params
to top-level defs and impl methods only, never to a `where`/`let` member, which lowers to
**one lifted lambda with one shared route ref** — as `pinLocalIfDictForwarded`'s own note in
`compiler/types/typecheck.mdk` already says. One route ref structurally cannot serve two
instantiations, so the first one wins.

**Consequence for #2032's fix order.** Fixing #1046 is *necessary but not sufficient*: it
would drain `A1…__B2_one_default` and leave `A1…__B1_both_defined` — a shape with no
method-less impl anywhere — silently wrong. The blocker is the one #1082
(dict-abstracting local bindings) names, and `docs/KNOWN-GAPS.md` already names #1082 as
the eventual fix for the *first* entry. The narrowing is blocked on **#1082**, not on
#1046. Until #1082 lands, no narrowing of `T-LOCAL-CONSTRAINED-MONO` is safe anywhere in
this region, which is a stronger and simpler answer than the one on record.

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

| cell | class | correct | `run` (eval) | native binary |
|---|---|---|---|---|
| `A1…__B1_both_defined` | bug | `woof\|meow` | ✅ `woof\|meow` | 🚨 `woof\|woof` **silent, exit 0** |
| `A1…__B2_one_default` | bug | `woof\|meow` | ✅ `woof\|meow` | 🚨 `woof\|woof` **silent, exit 0** |
| `A2…__B1_both_defined` | undecidable | `boxint\|boxstr` | E-AMBIGUOUS-DISPATCH, exit 1 | build aborts, exit 1 |
| `A2…__B2_one_default` | undecidable | `boxint\|boxstr` | E-AMBIGUOUS-DISPATCH, exit 1 | build aborts, exit 1 |
| `A3…__B1_both_defined` | undecidable | `int\|bool` | ✅ `int\|bool` | build aborts, exit 1 |
| `A3…__B2_one_default` | undecidable | `int\|bool` | ✅ `int\|bool` | build aborts, exit 1 |
| `A4…__B1_both_defined` | undecidable | `meow\|int` | ✅ `meow\|int` | build aborts, exit 1 |
| `A4…__B2_one_default` | undecidable | `meow\|int` | ✅ `meow\|int` | build aborts, exit 1 |
| `A5…__B1_both_defined` | bug | `[meow]\|meow` | E-PANIC, exit 1 | E-NONEXHAUSTIVE, exit 1 |
| `A5…__B2_one_default` | bug | `box\|meow` | ✅ `box\|meow` | 🚨 `box\|box` **silent, exit 0** |
| `A6…__no_local` | undecidable | `1\|2` | E-AMBIGUOUS-DISPATCH, exit 1 | builds; E-AMBIGUOUS-DISPATCH at run, exit 1 |
| `A6…__one_default` | undecidable | `9\|2` | E-AMBIGUOUS-DISPATCH, exit 1 | builds; E-AMBIGUOUS-DISPATCH at run, exit 1 |
| `A7…__one_default` | decidable | `9\|2` | ✅ | ✅ |
| `CONTROL…__not_pinned` | decidable | `woof\|meow//woof\|meow` | ✅ | ✅ |

### A1_distinct_user_heads__B1_both_defined

**`bug`.** Two impls, two distinct user tycons, both defining the method — disjoint
non-empty tag sets, two groups, everything `emitArgDispatchChain` needs. `medaka run` gets
it right, so the information is sufficient. The native binary answers `woof|woof` at exit 0.
This is the census's headline cell: it is the counterexample to "the narrowing is blocked
on #1046", because there is no method-less impl in it. See § headline result.

### A1_distinct_user_heads__B2_one_default

**`bug`.** `A1__B1` with `impl Speak Dog where` left method-less so the interface default
supplies `speak`. This is #1046's named shape. Identical symptom to `A1__B1` — `woof|woof`,
silent, exit 0 — which is precisely why #1046 cannot be the whole story: the shape with
and the shape without the method-less impl fail the same way. Fixing #1046 drains this
cell and leaves `A1__B1` standing.

### A2_same_head_diff_args__B1_both_defined

**`undecidable-by-construction`**, and the cleanest instance of the mechanism §4 of the
S-1 packet names. `Box Int` and `Box String` are two impls with two distinct canonical
impl keys, so `groupImpls` yields TWO groups — but `ctorsOfType e (groupTag g)` is
`{Box}` for both, because a tycon determines its ctor set and there is one tycon here. Two
groups, one runtime test, first arm wins. The cell tag is strictly weaker than the type
identity the decision needs, so no amount of narrowing helps.

⚠️ **This cell's `run` line MOVED in #2445 S-3, and the class did not.** Eval used to
answer `boxint|boxint` **silently, at exit 0** — `filterByTag` kept both candidates
(they share the head tag) and `collectPartials` took the first one that applied. It now
refuses with `E-AMBIGUOUS-DISPATCH` at exit 1 (`checkArgTagDecidable`, `eval/eval.mdk`).
The shape is still `undecidable-by-construction` — nothing here became decidable, and the
correct answer is still unreachable on this route. What changed is that the compiler now
SAYS SO instead of inventing an answer, so the pin records a refusal rather than a wrong
value. Re-deriving `boxint|boxint` here would be a regression, not a repair.

The native side does not even get that far — `medaka build` aborts at exit 1 with
`runtime error [E-PANIC]: no impl of method 'fromInt' for type 'String'`. That message is
the *emitter's own* panic, and it names `fromInt`, a method the user's program never
mentions; see the "loud but misleading" note below.

### A2_same_head_diff_args__B2_one_default

**`undecidable-by-construction`.** `A2__B1` with the `Box Int` impl method-less. Identical
outcome on both engines (including the S-3 `run` refusal noted above), which is the point: at a head collision, axis B does not matter —
the tag sets are equal whatever the group set is, so the discrimination has already failed
before the group set is consulted. This cell is what makes "A2 is undecidable" a statement
about the *head*, not about a particular impl spelling.

### A3_both_primitive__B1_both_defined

**`undecidable-by-construction` on the arg-tag route.** `Int` and `Bool` are primitive
receivers and carry no constructor cell tag at all — `argDefaultEmittable`
(`llvm_emit.mdk:6335`) already declines such heads by design, so there is no tag for
`emitTagMatch` to test. `medaka build` aborts at exit 1.

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
so the pair is not separable by the route. `medaka build` aborts at exit 1; eval again gets
it right by value tag. This is the "one empty" relation, and it behaves like the
"both empty" one rather than like the disjoint one — worth recording, because a reader might
expect the tagged half to survive.

### A4_mixed_primitive__B2_one_default

**`undecidable-by-construction`.** `A4__B1` with `impl Speak Cat` method-less. Unchanged, for
the `A2__B2` / `A3__B2` reason.

### A5_open_head__B1_both_defined

**`bug`.** `impl Speak (Box a) requires Speak a` and `impl Speak Cat` — disjoint heads, so
the discrimination is `A1`'s and should succeed. It does not, and it fails *differently* on
each engine: `medaka run` dies with
`E-PANIC: '++' requires Semigroup (List, String, or a type with append)`, while the native
binary builds cleanly (exit 0) and then dies with `E-NONEXHAUSTIVE-MATCH`. Neither failure
is about tag discrimination; both are about the `requires`-carrying arm's **body** — the
inner `speak x` needs a dict for `a`, and the pinned local has no route to give it one.
Classified `bug` because the selection information is sufficient (the heads are disjoint);
what breaks is downstream of selection.

Loud on both engines, so unlike `A1` this one is not a silent-wrongness cell.

### A5_open_head__B2_one_default

**`bug`.** `A5__B1` with the parametric `impl Speak (Box a) requires Speak a` left
method-less, so the interface default supplies `speak` and the arm no longer needs an inner
dict. That removes `A5__B1`'s downstream failure and re-exposes the *upstream* one: eval is
correct (`box|meow`), the native binary answers `box|box` **silently at exit 0** — the same
one-route-ref collapse as the `A1` row. The pair `A5__B1`/`A5__B2` is therefore useful
evidence on its own: it separates the `requires`-body failure from the local-route failure,
and shows the local-route failure is what remains once the body is made trivial.

### A6_same_head_chain_reached__no_local

**`undecidable-by-construction`** — and the cell the original ten did not contain: the
head collision reaching the NATIVE ARG-TAG CHAIN, with no `let`-local and therefore no
pin, no hatch, and no `#1082` monomorphisation anywhere in the story.

Every A2 cell routes its collision through a pinned local, and a pinned local is resolved
to ONE impl *before emit* — the marker stamps a single impl key on the lifted lambda's one
shared call site, so `emitArgDispatchChain` is never entered and the collision is
unobservable in IR. That was the S-3 spike's finding, and it is why the native halves of
`A2`/`A3`/`A4` all read "build aborts" rather than showing a chain. This cell removes the
local: `Wrap` is HIGHER-KINDED, so `go`'s constraint is not dict-abstracted and `wsize`
falls through to the arg-tag route with the receiver's runtime tag as its only evidence.

**Measured at base `919096b82`, before the S-3 guards** — the chain was built, and both
of its arms tested the SAME constant:

```
argyes10:  call @mdk_impl_…Wrap_7c__28_Pair_20_Int_29__7c__wsize   -- icmp eq %t6, 21474836480
argnext10: %t12 = icmp eq i64 %t6, 21474836480                     -- the identical tag
argyes13:  call @mdk_impl_…Wrap_7c__28_Pair_20_String_29__7c__wsize -- dead code
```

The binary printed `1` twice at exit 0 where the semantics say `1` then `2`; `medaka run`
printed `1` twice as well. That is the silent fold this corpus exists to name, observed on
the arg-tag chain itself rather than inferred from it.

Both engines now refuse loudly. The class stays `undecidable-by-construction`: the
runtime constructor tag is strictly weaker than the type identity the choice needs, and no
narrowing of `T-LOCAL-CONSTRAINED-MONO` can reach this cell at all — it is not in the
pinned region.

⚠️ **This cell's `build`/`exec` lines MOVED in #2445 F-1-v2, and the class did not.**
S-3 landed the native half as a `gapE` REFUSAL of the whole `medaka build` (exit 1, no
binary). That refusal could not be scoped, and F-1 measured why: a program that declares
these same colliding impls but never CONSTRUCTS a `Pair` receiver presents an IDENTICAL
static candidate set at `emitArgTagRoute` — a duplicate `Pair`-tagged arm in the chain
about to be emitted — yet is perfectly decidable and must build. The two differ only in
a whole-program receiver-reachability fact the emitter does not have, so any static test
that refuses this cell also refuses that correct program.

The loudness is therefore RETIMED rather than scoped: the chain is emitted as normal and
only the arms at a colliding head carry `@mdk_dispatch_ambiguous` instead of their impl
call. This cell now BUILDS at exit 0 and traps at exit 1 on the first `go (Pair 1 True)`,
before printing anything. That is the same verdict at a later phase — the cell is no more
decidable than it was — and it scopes the guard by ACTUAL receiver, exactly the way eval's
`checkArgTagDecidable` already did. Re-deriving a build-time refusal here would restore a
false positive on unreachable collisions; re-deriving `1|1` would restore the S0.

⚠️ **Honest limit.** `declHeadOfRouteWord` answers `""` when `ifaceImplHeadsRef` is
uninstalled, so a driver that never lowered through `lowerImpls` sees only the group heads
and still emits the silent chain. This cell pins the installed path, which is every path
`medaka build`/`run` take today; it is a floor, not a proof.

### A6_same_head_chain_reached__one_default

**`undecidable-by-construction`**, and the RAW LEG of the native guard — the one leg
nothing else in this corpus reaches on the chain path. `A6__no_local` with the `Pair Int`
impl left method-less, so the interface default supplies `wsize` for it.

The mechanism is worth stating because it is where a plausible fix fails OPEN. The
inheriting impl contributes no `CImplEntry`, so `implGroupsForMethod` yields exactly ONE
group here and a duplicate test over the group tags alone finds no collision at all — it
would emit a single-arm chain and silently answer `2|2`. The second `Pair` lives in `raw`
(the interface's declared route words minus what this method's entries cover), and `raw`'s
words are canonical KEYS at a collision, precisely because `declRouteKey` mints the bare
head only when the head IS unique. So `main::Wrap|(Pair Int)|` never string-compares equal
to the group's bare `Pair`, and a duplicate test over `map groupTag groups ++ raw` reports
"no collision" on exactly the shape the guard exists to catch. `declHeadOfRouteWord` maps
each raw word back to its head first, which is what keeps this cell loud.

Both engines refuse loudly on the first `go (Pair 1 True)`: eval at check-free run time
via `checkArgTagDecidable`, the binary via the retimed `@mdk_dispatch_ambiguous` arm. The
correct answer, `9|2`, needs the type identity behind the `Pair` tag and is unreachable on
this route whichever impl spelling is used — which is the same statement `A2__B2` makes
about axis B, made here on the chain rather than before it.

### A7_distinct_heads_chain_reached__one_default

**`decidable`, and the NEGATIVE CONTROL for `A6__one_default`.** Every ingredient of that
cell is present — a non-empty `raw` leg, an inheriting declared impl, the arg-tag chain
route, a higher-kinded interface, no `let`-local — with the collision removed: the
inheriting impl sits at `Solo` and the defining one at `Pair Int`, two distinct runtime
constructor tags.

It exists because the retimed guard's failure mode in the other direction is invisible
without it. A guard that trapped on the mere PRESENCE of a raw entry, or that compared
raw's route words against head tags by the wrong ruler and matched something, would fire
here and be wrong to — and it would look exactly like the correct behaviour on
`A6__one_default`. Correct on both engines (`9` then `2`).

**If this cell ever goes red the guard over-fires, not the region** — it is not evidence
about #2032. Note it is also the one `B2` cell in the corpus whose native default arm is
CORRECT; `A1__B2` and `A5__B2` answer with the defining impl's body at exit 0, which is
their own separate `bug` and not this cell's business.

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

## Loud, but misleading: the emitter's `fromInt` panic

Six of the ten cells (`A2`, `A3`, `A4`) fail `medaka build` at exit 1 with a message of the
form:

```
error: emitter failed compiling main.mdk
runtime error [E-PANIC]: no impl of method 'fromInt' for type 'String'
```

`fromInt` appears in none of these programs, and the type named (`String`, `Bool`, `Cat`) is
whichever receiver the emitter reached second. This is the *emitter process panicking*, not a
diagnostic: there is no located error, no diagnostic code, and nothing pointing at the
construct at fault. It is loud, which is the right direction, but it is an S2-misleading
message rather than a rejection. Recorded here as a finding rather than fixed — this slice's
mandate was to make the region observable, not to repair it.
