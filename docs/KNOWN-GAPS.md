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
than seeding a future generator.

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

**Why this is shipping as a known gap rather than being narrowed.** A
sharper predicate (`enclosingRigidScopeInPlay`, scoped only to the case an
enclosing `=>`-constrained group or method/impl body is actually live) was
implemented and measured: it correctly separates this shape from the first
entry's genuine G4 case, but it also releases the pin on
[#1046](https://github.com/MedakaLang/medaka/issues/1046)'s shape — an
**out-of-scope, still-open emitter defect** where a method-less `impl`
collapses two impls' arg-tag dispatch groups into one. Releasing the pin
there reintroduces a **silent wrong answer** with no diagnostic on any
engine, which is strictly worse than this over-reject. The narrowing is
therefore blocked on #1046 landing first, not on any remaining typechecker
work; see #2032 for the exact fix order (fix #1046's emitter defect, then
land the preserved narrowing). A regression fixture demonstrating the
over-reject (and the correct, narrower accept it should someday produce) was
measured during the fix round but was not committed to the tree this sprint —
also tracked as part of this same documented trade-off, to be landed
alongside the eventual narrowing.

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
