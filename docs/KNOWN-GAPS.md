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
