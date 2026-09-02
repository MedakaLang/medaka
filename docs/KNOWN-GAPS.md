# Known gaps — accepted-vs-rejected boundary

**Status:** living, seeded. User-facing: for each entry, what construct is
rejected, why, and the workaround. This is not a design doc and not a bug
tracker — [`docs/spec/DICT-SEMANTICS.md`](spec/DICT-SEMANTICS.md) is the
normative semantics and the issue tracker is where a gap gets fixed; this
file is the short answer for someone who just hit the diagnostic.

⚠️ **This file's first entry is seed content, not a finished design.**
[#73](https://github.com/MedakaLang/medaka/issues/73) will eventually
regenerate this entry (and others like it) mechanically from the
`test/must_fail_fixtures/` pin corpus, so what's written here is a
hand-authored placeholder for that future generation, not a pre-emption of
it. The second entry below is different in kind: it is orchestrator-authored
from a fix round's own first-hand measurement (sprint
`dispatch-must-not-guess`, [#1986](https://github.com/MedakaLang/medaka/issues/1986)),
not corpus-derived, and documents a deliberate, reviewed trade-off rather
than seeding a future generator. The third entry is the same kind of
orchestrator-authored record, from sprint `depth-linearity`
([#2069](https://github.com/MedakaLang/medaka/issues/2069)).

## Nesting deeper than 20,000 is rejected, not crashed on

**Rejected as:** `E-NEST-TOO-DEEP` (see `nestTooDeepMsg`,
`compiler/frontend/parser.mdk`).

**What triggers it.** An expression, pattern, or type whose recursive-descent
parse nests more than 20,000 levels deep — parenthesized/bracketed
expressions, `if`/`let`/`match`/`do`, nested application, and (as of this
sprint) pattern nesting (`match` arms) and type nesting (`f : (((...))) ->
Int`) all share one module-level depth counter
(`nestDepthRef`/`maxNestDepth`) incremented and checked at each grammar's own
recursive re-entry point:

```
f : ((((((((( ... 20,001 levels deep ... )))))))))  -> Int
```

```
error: expression nesting too deep (limit 20000); split this expression into
named intermediate bindings
```

**Why.** The parser is a plain recursive-descent implementation; before this
cap existed, adversarially deep input in any of these three grammars
recursed past the native stack limit and crashed with an **unlocated**
`E-STACK-OVERFLOW` (`exit 134`, no diagnostic, no source location) — a
release-blocker (issue #77) because "never crash on any input" was
unmet. The cap trades an unreachable pathology (a program nobody could write
by hand, only generate) for a bounded, located, recoverable diagnostic. The
number 20,000 was chosen to sit comfortably below where the native stack
actually overflows on the reference box, with headroom; it is not derived
from any language-semantic limit and could move if the stack budget changes.

**Workaround.** Split the deeply nested expression into named intermediate
bindings — the diagnostic's own suggested fix; there is no legitimate
program that needs 20,000 levels of raw nesting, so this is expected to
never fire outside adversarial/generated input.

**What this does NOT cover.** A single related issue, #164, found and fixed
one super-linear (not crashing, but slow) parse-time cost inside the same
nesting family (`leftSectionOrExpr`'s full `ELoc`-stack unwind, O(depth²)
before the fix) but left a **second, independent** super-linear residual
(dominant at large N, ~5-6x doubling under wall-clock, memory/cache-bound
rather than instruction-bound) that is not yet isolated to a specific
combinator — see #164's own tracking comment for the measured ladder and
named candidate mechanism. The practical consequence: a *legitimate* program
at or near the 20,000 cap parses correctly but slowly (~22s at N=20000 on
the reference box) — the cap makes deep input **fail fast past the
boundary**, it does not yet make deep input **fast within** the boundary.

## A local forwarded to a constrained method at two rigid types

**Rejected as:** `T-LOCAL-CONSTRAINED-MONO`.

**What triggers it.** A `where`/`let`-bound local whose body calls a
constrained method is used at two different types that are the *type
variables of an enclosing signature* — the compiler cannot yet abstract a
local binding over a dictionary, so instead of silently monomorphising it
(and silently merging two distinct instances behind one call), it rejects
with a located diagnostic naming the binding, both collapsed types, and the
interface:

```
interface Sized a where
  sizeOf : a -> Int

useTwo : (Sized a, Sized b) => a -> b -> Int
useTwo x y = d x + d y where
  d v = sizeOf v
```

```
error: local binding 'd' is used at two different types (the signature's 'a'
and 'b'), but it cannot be polymorphic: its body calls something that needs a
'Sized' instance, and only top-level definitions can carry that constraint
```

**Why.** `dict_pass` prepends `$dict_…` parameters to top-level definitions
and impl methods only, never to a `where`/`let` member. A local used at two
rigid signature types would need its own dictionary parameter per use site to
route correctly; since locals cannot yet carry one, generalizing silently is
unsound (it merges the two instances behind whichever one wins first), so the
floor answer is to reject rather than guess.

**Workaround.** Hoist the local to a top-level binding — each call site then
gets its own instantiation instead of sharing one monomorphic slot:

```
d : Sized a => a -> Int
d v = sizeOf v

useTwo x y = d x + d y
```

**Eventual fix.** Dict-abstracting local bindings
([#1082](https://github.com/MedakaLang/medaka/issues/1082)) removes the need
for this rejection entirely — see
[`compiler/TYPECHECK-ARCH-BUG-FIT.md`](../compiler/TYPECHECK-ARCH-BUG-FIT.md)
family C for the mechanism and the falsifiable prediction for when that lands.

## Known over-reject: a plain ground-type local also gets pinned

**Status of this entry:** a deliberate, reviewed, documented trade-off — see
[#2032](https://github.com/MedakaLang/medaka/issues/2032) for the fix order
that would let this narrow.

**What triggers it.** The predicate above is broader than the first entry's
literal scope. It also rejects a local that forwards to a method call and is
then used at two plain **ground** types, with **no enclosing polymorphic
signature at all** — nothing here needs an abstract dictionary, and the local
already looks fully monomorphic:

```
let s = v => debug v
println (s 1)
println (s True)
```

with two `impl Debug` instances in scope (one for `Int`, one for `Bool`).
This rejects today with the same `T-LOCAL-CONSTRAINED-MONO`, even though
nothing here collapses a rigid signature variable — the local is pinned to
one method's dispatch decision the moment its body reaches a constrained
method call, regardless of whether an enclosing rigid scope is even present.

**Why this is shipping as a known gap rather than being narrowed — measured,
not argued.** Because the pin rejects the whole region, what the compiler
*would* do inside it is unobservable, so the narrowing question was
previously answered from a hand-picked sample. It has since been answered by
measurement. [`test/argtag_matrix_fixtures/CENSUS.md`](../test/argtag_matrix_fixtures/CENSUS.md)
drives the region through a test-only unpin hatch (`MEDAKA_ARGTAG_UNPIN=1`)
and grades every cell of the **product of the two axes that
`emitArgDispatchChain` actually reads** — the group set (an impl either
defines the method or inherits the interface default) and the per-group
constructor-cell-tag set (the four possible relations between two heads' tag
sets, plus the parametric `requires`-carrying spelling of one of them). That
product is **10 cells**, plus one control deliberately outside the region.

**Zero of the 10 masked cells are decidable.** Each is either a `bug` (the
information *is* sufficient — `medaka run` gets it right — and the native
binary is wrong anyway) or `undecidable-by-construction` (the constructor
cell tag the arg-tag route tests is strictly weaker than the type identity
the decision needs, so no *narrower predicate* over this route could ever
answer correctly; only a different mechanism could). The one `decidable` cell
is the control, `CONTROL_toplevel_helper__not_pinned`, which is outside the
pinned region by construction and therefore proves nothing about what a
narrowed pin could safely release.

**The blocker is #1082, not #1046.** This entry previously stated that the
narrowing was blocked *specifically* on
[#1046](https://github.com/MedakaLang/medaka/issues/1046) — the method-less
`impl` arg-tag group collapse — and that fixing #1046 would then unblock a
preserved `enclosingRigidScopeInPlay` narrowing. The census refutes the
"specifically". The cell `A1_distinct_user_heads__B1_both_defined` contains
**no method-less impl at all** — two ordinary impls at two distinct user
tycons, the friendliest shape the region admits — and the native binary still
prints `woof|woof` where the semantics say `woof|meow`, **silently, at exit
0**, while `medaka run` prints the correct answer. Fixing #1046 is therefore
*necessary but not sufficient*: it drains
`A1_distinct_user_heads__B2_one_default` and leaves `A1…__B1_both_defined`
standing. The discriminating measurement is the control, which holds the
interface, the impls, the heads and the use sites fixed and changes exactly
one thing — the helper is a top-level definition rather than a `let`-local —
and is correct on both engines. What fails is specific to the **local**:
`dict_pass` gives it no dictionary parameter, so it lowers to one lifted
lambda with one shared route ref, and one route ref structurally cannot serve
two instantiations.

The narrowing is therefore blocked on the same thing the first entry names as
its eventual fix: dict-abstracting local bindings
([#1082](https://github.com/MedakaLang/medaka/issues/1082)). Until that
lands, **no narrowing of `T-LOCAL-CONSTRAINED-MONO` is safe anywhere in this
region** — which is a stronger and simpler answer than the one this entry
previously carried, and it is why the preserved `enclosingRigidScopeInPlay`
predicate is not a design to resurrect on the grounds that no gate is red:
the whole region is invisible to the gate suite by construction, and five
green gates is exactly what that narrowing had when it was reverted.

**Workaround.** Same as the first entry — hoist the forwarding local to a
top-level binding — or, if hoisting is undesirable, split the one local into
two differently-named locals, one per use site.

## `<FFI>` is a reachability label, not a memory-safety guarantee

**What it is.** Calling a foreign function ends the compiler's memory-safety
guarantee for that program. `<FFI>` ([#2071](https://github.com/MedakaLang/medaka/issues/2071))
does **not** restore it. The label is a static, transitive statement of which
code paths reach a foreign call at all — and nothing more.

**Why this needs saying.** A foreign call can corrupt memory, crash, or
violate any invariant Medaka's own type system enforces, and nothing in the
effect system detects or prevents that — this is true even where `<FFI>`
correctly and transitively appears in every caller's row. Seeing `<FFI>` in a
signature tells you *which code can reach a foreign call*; it tells you
nothing about whether that call is safe to make.

**Workaround/caveat.** None — this is not a defect to work around, it is a
scope boundary to know about. Treat `<FFI>` purely as a reachability marker
when auditing a program, not as evidence the call has been checked for
memory safety. *(Migration note: this entry belongs on the public capability
release page once that page exists — [#2077](https://github.com/MedakaLang/medaka/issues/2077) —
it is written here first because that page does not exist yet.)*
