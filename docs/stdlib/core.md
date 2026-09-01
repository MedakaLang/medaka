# core

core.mdk — the foundation every other Medaka module rests on.

This file is automatically prepended to every program by the compiler
(see lib/prelude.ml), so everything declared here is in scope without
an `import`.  See STDLIB.md for the full plan and Module 1 checklist.

Layout:
1. Foundational data types (Ordering, Option, Result)
2. Interface hierarchy in dependency order:
Eq → Ord, Semigroup → Monoid, Debug, Num, Bounded,
Mappable → Applicative → Thenable, Foldable
Each interface is followed by its impls for built-in types.
3. Standalone helpers (Bool, Option, Result, Foldable, utility)
4. Arbitrary (property-testing generator interface)

Style notes:
* Strict evaluation: prefer tail-recursive helpers in `where` clauses
over right-leaning recursion when traversing potentially-large data.
* `default` on an impl is only required when more than one impl is
visible for the same head; we mark the `Result e` instances `default`
so a user can later add an `Err`-mapping variant.

## `Ordering`

```
data Ordering
  = Lt
  | Eq
  | Gt
```

Three-way comparison result, produced by `Ord.compare`.

## `Option`

```
data Option a
  = Some a
  | None
```

A value that may be absent.  Medaka's name for Haskell's `Maybe`.


*(doctest — run by `medaka test`)*

```medaka
> isSome (Some 1)
True
> isSome None
False
```

## `Result`

```
data Result e a
  = Ok a
  | Err e
```

A computation that either succeeded with `Ok a` or failed with `Err e`.
Errors are data; pattern-match to handle them.  See language-design.md.


*(doctest — run by `medaka test`)*

```medaka
> isOk (Ok 1)
True
> isOk (Err "boom")
False
```

## `Eq`

```
interface Eq a
  eq : a -> a -> Bool
```

Structural equality.  Reflexive, symmetric, transitive.
`==` on primitives is a builtin and does *not* dispatch through this
interface; the impls below exist so generic `Eq a => ...` code works.

## `neq`

```
neq : a -> a -> Bool
```

Negation of `eq`.  Standalone so impls cannot make it disagree with `eq`.

## `Eq Int`

```
impl Eq Int
```

## `Eq Float`

```
impl Eq Float
```

## `Eq Bool`

```
impl Eq Bool
```

## `Eq Char`

```
impl Eq Char
```

## `Eq Unit`

```
impl Eq Unit
```

## `Eq (Option a)`

```
impl Eq (Option a) requires Eq a
```

## `Eq (Result e a)`

```
impl Eq (Result e a) requires Eq e, Eq a
```

## `Eq (a, b)`

```
impl Eq (a, b) requires Eq a, Eq b
```

Structural equality for tuples (arities 2–5): equal iff every field is.

## `Eq (a, b, c)`

```
impl Eq (a, b, c) requires Eq a, Eq b, Eq c
```

## `Eq (a, b, c, d)`

```
impl Eq (a, b, c, d) requires Eq a, Eq b, Eq c, Eq d
```

## `Eq (a, b, c, d, e)`

```
impl Eq (a, b, c, d, e) requires Eq a, Eq b, Eq c, Eq d, Eq e
```

## `Semigroup`

```
interface Semigroup a
  append : a -> a -> a
```

Associative combine.  Backs the `++` operator and is the parent of
`Monoid`.  Implementations *must* satisfy
append a (append b c) == append (append a b) c.

## `Monoid`

```
interface Monoid a
  empty : a
```

A `Semigroup` with an identity element.  Laws:
append empty x == x       (left identity)
append x empty == x       (right identity)

## `Ord`

```
interface Ord a
  compare : a -> a -> Ordering
  lt : a -> a -> Bool
  gt : a -> a -> Bool
  lte : a -> a -> Bool
  gte : a -> a -> Bool
  min : a -> a -> a
  max : a -> a -> a
  lt : _
  gt : _
  lte : _
  gte : _
  min : _
  max : _
```

Total ordering.  `compare` is the primitive method; the comparison
helpers all have defaults expressed through it, but impls may override
any of them for performance or to encode special semantics (e.g. NaN).

## `clamp`

```
clamp : a -> a -> a -> a
```

`clamp lo hi x` constrains `x` into the inclusive interval `[lo, hi]`.
Precondition: `lo <= hi`; otherwise the result is `lo`.


*(doctest — run by `medaka test`)*

```medaka
> clamp 0 10 5
5
> clamp 0 10 (-3)
0
> clamp 0 10 99
10
```

## `isEven`

```
isEven : Int -> Bool
```

`isEven n` is `True` when `n` is divisible by 2 (negatives included).


*(doctest — run by `medaka test`)*

```medaka
> isEven 4
True
> isEven 7
False
```

## `isOdd`

```
isOdd : Int -> Bool
```

`isOdd n` is `True` when `n` is not divisible by 2.


*(doctest — run by `medaka test`)*

```medaka
> isOdd 3
True
> isOdd 8
False
```

## `Ord Int`

```
impl Ord Int
```

## `Ord Float`

```
impl Ord Float
```

`Ord Float` is IEEE-754 **totalOrder** (issue #360):

−NaN < −inf < … < −0.0 < +0.0 < … < +inf < +NaN

so `compare`, `min`/`max` and therefore `sort` are deterministic on NaN data
and never crash.  The previous `if a < b … else Eq` shape returned `Eq` for
`compare nan x` at EVERY `x`, which is not a total order at all: it broke
transitivity (`nan Eq 1.0` and `nan Eq 3.0`, yet `1.0 /= 3.0`), so a sorted
result was only an accident of the algorithm.

Deliberate divergence: `compare x y == Eq` coincides with `x == y` for every
non-NaN value — in particular `compare (−0.0) (+0.0) = Eq`, matching
`-0.0 == 0.0` (issue #758): the equal-branch normalises the zero sign away
rather than tie-breaking it.  NaN is the SOLE residual: `compare nan nan = Eq`
while `nan == nan = False`, because IEEE `==` is non-reflexive at NaN and no
total order can be — the trade Rust's `f64::total_cmp` and Java's
`Double.compare` make too.

⚠️  The four relational overrides below are LOAD-BEARING, do not delete them.
`< <= > >=` at Float are primitive IEEE predicates on every path, and all
four are False at a NaN operand (EMITTER-SEMANTICS N5, issue #305).  Ord's
interface DEFAULTS derive them from `compare`, so without these overrides the
Float dict would hand them totalOrder and silently make `nan < 1.0` True —
re-opening the S0 that #305 closed.  `min`/`max` keep their compare-derived
defaults on purpose: they are not IEEE predicates, and #360 asks for them to
be total.
(guards are not accepted in an impl method body — hence the `if` chain)

## `Ord Char`

```
impl Ord Char
```

## `Ord (a, b)`

```
impl Ord (a, b) requires Ord a, Ord b
```

Lexicographic ordering for tuples (arities 2–5): compare field by field,
left to right, stopping at the first that differs.

## `Ord (a, b, c)`

```
impl Ord (a, b, c) requires Ord a, Ord b, Ord c
```

## `Ord (a, b, c, d)`

```
impl Ord (a, b, c, d) requires Ord a, Ord b, Ord c, Ord d
```

## `Ord (a, b, c, d, e)`

```
impl Ord (a, b, c, d, e) requires Ord a, Ord b, Ord c, Ord d, Ord e
```

## `Ord (Option a)`

```
impl Ord (Option a) requires Ord a
```

`None` sorts before every `Some`; two `Some`s compare by their contents.

## `Ord (Result e a)`

```
impl Ord (Result e a) requires Ord e, Ord a
```

`Err` sorts before `Ok`; like constructors compare by their payloads.

## `Debug`

```
interface Debug a
  debug : a -> String
```

Human-readable string rendering.  Backs `medaka test` doctests, which
compare a result's `debug` against the expected text (GHCi/doctest parity).
`Debug Int`/`Float`/`Bool`/`Unit`/`List`/`Option`/`Result` and the tuple
impls live here; `Debug String`/`Debug Char` live in `string.mdk`.
Numeric/Bool `debug` matches the interpreter's `pp_value` (so it agrees with
`println`); `String`/`Char` render *quoted* (round-trippable, so `debug`
intentionally differs from `println` — cf. Haskell `debug` vs `putStr`).

## `Debug Int`

```
impl Debug Int
```

## `Debug Float`

```
impl Debug Float
```

## `Debug Bool`

```
impl Debug Bool
```

## `Debug Unit`

```
impl Debug Unit
```

## `Debug Ordering`

```
impl Debug Ordering
```

## `Eq Ordering`

```
impl Eq Ordering
```

Eq/Ord for Ordering are HAND-WRITTEN (not `deriving`): the `Eq` data
CONSTRUCTOR collides with the `Eq` class name, so `deriving (Eq)` is
ambiguous.  Without these, `o == Lt` check-accepts and `run`s but `build`
FAILS (no Ord/Eq Ordering binary).  Rank Lt < Eq < Gt.

## `Ord Ordering`

```
impl Ord Ordering
```

## `Debug Char`

```
impl Debug Char
```

## `Debug (Option a)`

```
impl Debug (Option a) requires Debug a
```

## `Debug (Result e a)`

```
impl Debug (Result e a) requires Debug e, Debug a
```

## `Debug (a, b)`

```
impl Debug (a, b) requires Debug a, Debug b
```

Tuple rendering (arities 2–5): `(a, b)`, matching the interpreter's
value printer.

## `Debug (a, b, c)`

```
impl Debug (a, b, c) requires Debug a, Debug b, Debug c
```

## `Debug (a, b, c, d)`

```
impl Debug (a, b, c, d) requires Debug a, Debug b, Debug c, Debug d
```

## `Debug (a, b, c, d, e)`

```
impl Debug (a, b, c, d, e) requires Debug a, Debug b, Debug c, Debug d, Debug e
```

## `Display`

```
interface Display a
  display : a -> String
```

Display rendering for string interpolation.  A `"\{e}"` hole desugars to
`display e`, so this is what `\{...}` calls.  Unlike `Debug`, `Display` does
*not* quote `String`/`Char` (interpolating a string splices its characters,
it doesn't debug a quoted literal) — this is the Debug-vs-Display split.  For
every other type `display` matches `debug`'s output, recursing with `display`
so nested strings stay unquoted too.  Lives in `core.mdk` (not `string.mdk`
like `Debug String`) because interpolation is core syntax: a bare `"\{name}"`
can't depend on an imported module.  `deriving (Display)` mirrors
`deriving (Debug)`.

## `Display Int`

```
impl Display Int
```

## `Display Float`

```
impl Display Float
```

## `Display Bool`

```
impl Display Bool
```

## `Display Unit`

```
impl Display Unit
```

## `Display Ordering`

```
impl Display Ordering
```

## `Display Char`

```
impl Display Char
```

## `Display (Option a)`

```
impl Display (Option a) requires Display a
```

## `Display (Result e a)`

```
impl Display (Result e a) requires Display e, Display a
```

## `Display (a, b)`

```
impl Display (a, b) requires Display a, Display b
```

## `Display (a, b, c)`

```
impl Display (a, b, c) requires Display a, Display b, Display c
```

## `Display (a, b, c, d)`

```
impl Display (a, b, c, d) requires Display a, Display b, Display c, Display d
```

## `Display (a, b, c, d, e)`

```
impl Display (a, b, c, d, e) requires Display a, Display b, Display c, Display d, Display e
```

## `Hashable`

```
interface Hashable a
  hash : a -> Int
```

Hash code for use in hash tables.  Equal values (per `Eq`) must produce
the same hash — the contractual invariant.  Hash values need not be unique.
Primitive impls delegate to per-type externs (`hashInt`/`hashString`/… —
specified deterministic hashers, byte-identical across the tree-walker and the
native backend); the derived impls and the compound impls below
(`Option`/`Result`/`List`/tuples) share one djb2-style fold: seed with the
constructor ordinal, then `acc = acc * 33 + hash field` left-to-right over
fields.  `deriving (Hashable)` generates exactly that fold for `data`,
`record`, and `newtype` types (#422).  The fold is NOT masked non-negative:
`Int` wraps, so a hash may be negative.  Only eq-agreement is contractual —
hash_map/hash_set mask at the point of use (#416).

## `Hashable Int`

```
impl Hashable Int
```

## `Hashable Float`

```
impl Hashable Float
```

## `Hashable Char`

```
impl Hashable Char
```

## `Hashable Bool`

```
impl Hashable Bool
```

## `Hashable Unit`

```
impl Hashable Unit
```

## `Hashable Ordering`

```
impl Hashable Ordering
```

Lt=0, Eq=1, Gt=2 — matches constructor declaration order.

## `Hashable (Option a)`

```
impl Hashable (Option a) requires Hashable a
```

None=1 (ordinal 1, no fields); Some x seeds at 0 then folds: 0*33+hash x.

## `Hashable (Result e a)`

```
impl Hashable (Result e a) requires Hashable e, Hashable a
```

Ok seeds at 0, Err at 1.

## `Hashable (a, b)`

```
impl Hashable (a, b) requires Hashable a, Hashable b
```

## `Hashable (a, b, c)`

```
impl Hashable (a, b, c) requires Hashable a, Hashable b, Hashable c
```

## `Hashable (a, b, c, d)`

```
impl Hashable (a, b, c, d) requires Hashable a, Hashable b, Hashable c, Hashable d
```

## `Hashable (a, b, c, d, e)`

```
impl Hashable (a, b, c, d, e) requires Hashable a, Hashable b, Hashable c, Hashable d, Hashable e
```

## `println`

```
println : a -> <IO> Unit
```

Human-facing output (Phase 111).  `println`/`print` render via `Display`
(unquoted, user-facing) rather than dumping internal `VCon` structure, so a
`Map` prints `Map { 1 => 10 }`, not its weight-balanced tree.  For
round-trippable Debug-rendering output (strings/chars quoted, constructor
names visible), import `io.mdk` and use `inspect` (`inspect x = putStrLn
(debug x)`).  These are ordinary Medaka functions over the string-only
`putStr`/`putStrLn` externs, which moves the `Display` constraint into
Medaka where dict-passing works (an extern can't receive a dictionary).

## `print`

```
print : a -> <IO> Unit
```

## `Num`

```
interface Num a
  add : a -> a -> a
  sub : a -> a -> a
  mul : a -> a -> a
  div : a -> a -> a
  negate : a -> a
  abs : a -> a
  signum : a -> a
  fromInt : Int -> a
```

Numeric arithmetic.  Backs `+`, `-`, `*`, `/` for user-defined numeric
types; the operators are hard-wired for `Int` and `Float` and only
dispatch through `add`/`sub`/... for other types.

`div` is truncating for `Int` and true division for `Float`, matching
the host operator.

## `Num Int`

```
impl Num Int
```

## `Num Float`

```
impl Num Float
```

## `Bounded`

```
interface Bounded a
  minBound : a
  maxBound : a
```

Types with a smallest and largest representable value.
Impls for `Int`, `Char` etc. land once the corresponding extern
constants are added; the interface itself is here so generic
bounded-type code can be written today.

## `Bounded Int`

```
impl Bounded Int
```

`Int` bounds are the platform's 63-bit native-integer limits.

*(doctest — run by `medaka test`)*

```medaka
> (minBound : Int) < (maxBound : Int)
True
```

## `Bounded Char`

```
impl Bounded Char
```

`Char` ranges over the Unicode scalar values, U+0000 to U+10FFFF.

*(doctest — run by `medaka test`)*

```medaka
> charCode (minBound : Char)
0
> charCode (maxBound : Char)
1114111
```

## `Mappable`

```
interface Mappable f
  map : (a -> <e> b) -> f a -> <e> f b
```

Structure-preserving map (a.k.a. Functor).  Laws:
map identity      == identity
map (g `compose` f) == map g `compose` map f

## `Mappable Option`

```
impl Mappable Option
```

## `Mappable (Result e)`

```
impl Mappable (Result e)
```

`default` so a user-defined alternative (e.g. one that maps over the
`Err` side) can coexist without forcing every call site to qualify.

## `replaceWith`

```
replaceWith : a b -> c -> a c
```

Replace every element of a wrapped value with a constant, keeping the
structure — Haskell's `$>`.  `replaceWith fa b == map (const b) fa`.


*(doctest — run by `medaka test`)*

```medaka
> replaceWith (Some 5) 9
Some 9
```

## `Applicative`

```
interface Applicative f
  pure : a -> f a
  ap : f (a -> b) -> f a -> f b
```

`Mappable` plus the ability to lift a plain value and apply a wrapped
function to a wrapped argument.  Laws (identity, homomorphism,
interchange, composition) follow Haskell's `Applicative`.

## `Applicative Option`

```
impl Applicative Option
```

## `Applicative (Result e)`

```
impl Applicative (Result e)
```

`default` (like `Mappable (Result e)`) so an error-accumulating
alternative — a `Validation`-style applicative — can coexist.

## `map2`

```
map2 : (a -> b -> c) -> d a -> d b -> d c
```

Lift a binary function over two applicative values — Haskell's `liftA2`.


*(doctest — run by `medaka test`)*

```medaka
> map2 (a b => a + b) (Some 3) (Some 4)
Some 7
> map2 (a b => a + b) (None : Option Int) (Some 4)
None
> map2 (a b => a + b) [1, 2] [10, 20]
[11, 21, 12, 22]
```

## `map3`

```
map3 : (a -> b -> c -> d) -> e a -> e b -> e c -> e d
```

Lift a ternary function over three applicative values — Haskell's `liftA3`.


*(doctest — run by `medaka test`)*

```medaka
> map3 (a b c => a + b + c) (Some 1) (Some 2) (Some 3)
Some 6
> map3 (a b c => a + b + c) [1] [10, 20] [100]
[111, 121]
```

## `Thenable`

```
interface Thenable m
  andThen : m a -> (a -> <e> m b) -> <e> m b
```

Sequencing of computations, threading the result.  Equivalent to
Haskell's `>>=` with arguments swapped to match the readable
"value first, then action" reading order.  Drives `do`-notation.

## `flatMap`

```
flatMap : (a -> b c) -> b a -> b c
```

`andThen` with arguments flipped — the Haskell/Scala `flatMap`.

## `flat`

```
flat : a (a b) -> a b
```

Collapse one layer of nesting.  Haskell calls this `join`.

## `when`

```
when : Bool -> a Unit -> a Unit
```

Run an action only when the condition holds.

## `unless`

```
unless : Bool -> a Unit -> a Unit
```

Run an action only when the condition is false.  Dual of `when`.

## `foldThen`

```
foldThen : (a -> b -> c a) -> a -> List b -> c a
```

Monadic left fold: thread an accumulator through an effectful step, in
order, over a list.  Haskell's `foldM`.


*(doctest — run by `medaka test`)*

```medaka
> foldThen (acc x => Some (acc + x)) 0 [1, 2, 3]
Some 6
```

## `repeatThen`

```
repeatThen : Int -> a b -> a (List b)
```

Run an action `n` times and collect the results in order.  `n <= 0`
yields `pure []`.  Haskell's `replicateM`.


*(doctest — run by `medaka test`)*

```medaka
> repeatThen 3 (Some 7)
Some [7, 7, 7]
```

## `filterThen`

```
filterThen : (a -> b Bool) -> List a -> b (List a)
```

Keep the elements for which an effectful predicate returns `True`, in
order.  Haskell's `filterM`.


*(doctest — run by `medaka test`)*

```medaka
> filterThen (x => Some (x > 1)) [1, 2, 3]
Some [2, 3]
```

## `forEach`

```
forEach : List a -> (a -> b Unit) -> b Unit
```

Run an effectful action for each element, in order, discarding the
per-element results.  Haskell's `traverse_`/`for_` specialised to `List`.


*(doctest — run by `medaka test`)*

```medaka
> forEach [1, 2, 3] (x => Some ())
Some ()
```

## `runEach`

```
runEach : List (a b) -> a Unit
```

Run each action in a list, in order, discarding the results.  Haskell's
`sequence_` specialised to `List`.


*(doctest — run by `medaka test`)*

```medaka
> runEach [Some 1, Some 2]
Some ()
```

## `Thenable Option`

```
impl Thenable Option
```

## `Thenable (Result e)`

```
impl Thenable (Result e)
```

`default` (like the rest of the `Result e` family) so a short-circuiting
alternative can coexist with the standard error-propagating sequence.

## `Alternative`

```
interface Alternative f
  noMatch : f a
  orElse : f a -> f a -> f a
```

Nondeterministic choice.  `noMatch` is the always-failing alternative
(identity for `orElse`); `orElse a b` tries `a` and, if it
"fails"/is-empty, falls back to `b` (left-biased).

Laws:
orElse noMatch x == x          (left identity)
orElse x noMatch == x          (right identity)
orElse (orElse x y) z == orElse x (orElse y z)  (associativity)


*(doctest — run by `medaka test`)*

```medaka
> length (orElse [1, 2] [3])
3
> isEmpty (orElse ([] : List Int) [1])
False
> isSome (orElse (Some 1) (Some 2))
True
> isSome (orElse None (Some 2))
True
> isSome (orElse None (None : Option Int))
False
```

## `Alternative Option`

```
impl Alternative Option
```

## `guard`

```
guard : Bool -> a Unit
```

`guard True` succeeds with `pure ()`; `guard False` is the failing
`noMatch`.  Used to prune an `Alternative` computation on a condition.


*(doctest — run by `medaka test`)*

```medaka
> (guard True : Option Unit)
Some ()
> (guard False : Option Unit)
None
```

## `Bimappable`

```
interface Bimappable p
  bimap : (a -> <e> c) -> (b -> <e> d) -> p a b -> <e> p c d
  mapFirst : (a -> <e> c) -> p a b -> <e> p c b
  mapFirst : _
  mapSecond : (b -> <e> d) -> p a b -> <e> p a d
  mapSecond : _
```

Map over BOTH type parameters of a two-parameter type constructor —
Haskell's `Bifunctor`, renamed to fit `Mappable`/`Thenable`.  `mapFirst`
touches the left/`Err` side, `mapSecond` the right/`Ok` side; both have
defaults in terms of `bimap`.


*(doctest — run by `medaka test`)*

```medaka
> bimap (n => n + 1) (n => n * 2) (Ok 5 : Result Int Int)
Ok 10
> bimap (n => n + 1) (n => n * 2) (Err 5 : Result Int Int)
Err 6
```

## `Bimappable Result`

```
impl Bimappable Result
```

`mapFirst` on `Result` generalizes the standalone `mapErr`.

## `Bimappable __tuple2__`

```
impl Bimappable __tuple2__
```

The bare 2-tuple constructor `(,)` as a `Bimappable`: `bimap` maps the two
fields independently.  `mapFirst`/`mapSecond` come from the interface
defaults, so they touch the left/right field respectively.


*(doctest — run by `medaka test`)*

```medaka
> bimap (x => x + 1) (y => y * 2) (3, 4)
(4, 8)
> mapFirst (x => x + 1) (3, 4)
(4, 4)
> mapSecond (y => y * 2) (3, 4)
(3, 8)
```

## `Foldable`

```
interface Foldable t
  fold : (b -> a -> <e> b) -> b -> t a -> <e> b
  foldRight : (a -> b -> <e> b) -> b -> t a -> <e> b
  foldMap : Monoid m => (a -> <e> m) -> t a -> <e> m
  toList : t a -> List a
  isEmpty : t a -> Bool
  length : t a -> Int
  foldMap : _
  length : _
  isEmpty : _
```

Collapse a container down to a summary value.

`fold` is a strict left fold; `foldRight` is the natural recursive form
and is the one you want for operations that need to preserve element
order (or that would otherwise allocate a reversed accumulator).

`length`, `isEmpty`, and `foldMap` come with defaults so impls only
need to define `fold`, `foldRight`, and `toList`; override the others
when the data structure admits a faster implementation (e.g. O(1)
`length` for arrays).


*(doctest — run by `medaka test`)*

```medaka
> isEmpty (None : Option Int)
True
> length (Some 5)
1
```

## `Filterable`

```
interface Filterable f
  filterMap : (a -> <e> Option b) -> f a -> <e> f b
  filter : (a -> <e> Bool) -> f a -> <e> f a
  filter : _
```

Containers that can drop elements (and transform-while-dropping).
Modeled on Haskell's `witherable` Filterable: `filterMap` is the
primitive, `filter` falls out as a derived default.  Kept separate
from `Mappable` because not every functor can shrink — a fixed-shape
container has no sensible `filterMap`.

## `FromEntries`

```
interface FromEntries c e
  fromEntries : List e -> c
```

Build a container `c` from a list of entries of type `e`.  Backs the
container-literal sugar: the compiler lowers `Map { k => v, … }` to
`fromEntries [(k, v), …]` and `Set { x, … }` to `fromEntries [x, …]`,
pinning the result type to the named container so this dispatches to that
container's impl.  `c` is the dispatch (result) type; `e` is its entry type
— for a map `(k, v)`, for a set the element.  Impls live with each container
(e.g. `impl FromEntries (Map k v) (k, v)` in map.mdk).

## `Index`

```
interface Index c k v
  index : c -> k -> v
```

Read access to a container `c` keyed by `k`, yielding a `v`.  `index c k`
looks up the value at key/index `k`; impls raise the coded `indexError`
abort (E-INDEX-OOB) on an out-of-range index or missing key.

## `IndexMut`

```
interface IndexMut c k v
  setIndex : c -> k -> v -> c
```

Write access to a container `c` keyed by `k`.  `setIndex c k v` writes
`v` at key/index `k`, returning the (possibly mutated in place) container.
Requires `Index c k v` (a container you can write into, you can also read
from).

## `Slice`

```
interface Slice c
  slice : c -> Int -> Int -> c
```

Read-only slicing of a container `c` by a half-open index range.  `slice c lo
hi` yields the sub-container over indices `[lo, hi)`.  The surface sugar
`c.[lo..hi]` / `c.[lo..=hi]` desugars to a call here (#670; the inclusive `..=`
form normalizes to `slice c lo (hi + 1)` in desugar), so the receiver is
constrained to a real container: `42.[0..1]` is a "no impl of Slice for Int"
type error rather than a wrong-container heap read.  Parallels `Index`.

## `Foldable Option`

```
impl Foldable Option
```

`Option` and `Result e` each foldable as a 0-or-1-element container.
`default` on the Result impl mirrors `Mappable (Result e)`: a user-defined
alternative (e.g. folding over the `Err` side) can coexist without
forcing every call site to qualify.

## `Foldable (Result e)`

```
impl Foldable (Result e)
```

## `Traversable`

```
interface Traversable t
  traverse : Thenable m => (a -> <e> m b) -> t a -> <e> m (t b)
  sequence : Thenable m => t (m a) -> m (t a)
  sequence : _
```

Containers that can be traversed left-to-right, running an effectful
function over each element and collecting the results inside the effect.
`Traversable` is `Mappable` + `Foldable` plus the ability to *commute* the
container with an applicative/monadic effect: `traverse` walks the structure,
`sequence` flips a container-of-effects into an effect-of-container.

For `Option`/`Result` the effect short-circuits on the first `None`/`Err`;
for any other `Thenable m` it threads `m` through the whole structure.


*(doctest — run by `medaka test`)*

```medaka
> traverse (x => if x > 0 then Some x else None) [1, 2, 3]
Some [1, 2, 3]
> traverse (x => if x > 0 then Some x else None) [1, -2, 3]
None
> traverse (x => if x > 0 then Some (x + 1) else None) (Some 5)
Some Some 6
> traverse (x => if x > 0 then Ok x else Err x) [1, 2, 3]
Ok [1, 2, 3]
> traverse (x => if x > 0 then Ok x else Err x) [1, -2, 3]
Err -2
> sequence [Some 1, Some 2, Some 3]
Some [1, 2, 3]
> sequence [Some 1, None, Some 3]
None
> sequence [Ok 1, Ok 2, Ok 3]
Ok [1, 2, 3]
> sequence [Ok 1, Err 99, Ok 3]
Err 99
```

## `Traversable Option`

```
impl Traversable Option
```

lint-disable-next-line rule-match-on-param

## `Traversable (Result e)`

```
impl Traversable (Result e)
```

`default` mirrors the `Foldable`/`Mappable (Result e)` impls so a
user-defined alternative can coexist without qualifying call sites.
lint-disable-next-line rule-match-on-param

## `any`

```
any : (a -> Bool) -> b a -> Bool
```

True when at least one element satisfies the predicate.


*(doctest — run by `medaka test`)*

```medaka
> any (x => x > 2) [1, 2, 3]
True
> any (x => x > 10) [1, 2, 3]
False
```

## `all`

```
all : (a -> Bool) -> b a -> Bool
```

True when every element satisfies the predicate.  Vacuously true on
the empty container.


*(doctest — run by `medaka test`)*

```medaka
> all (x => x > 0) [1, 2, 3]
True
> all (x => x > 0) []
True
```

## `find`

```
find : (a -> Bool) -> b a -> Option a
```

First element satisfying the predicate, or `None` if none do.
Latches the first hit via an as-pattern so subsequent elements don't
overwrite the answer.

## `count`

```
count : (a -> Bool) -> b a -> Int
```

Number of elements satisfying the predicate.

## `sum`

```
sum : a b -> b
```

Sum of a numeric foldable.  Identity is `0`; in practice this only
works for `Int` today because `(+)` is a builtin that doesn't yet
dispatch through `Num.add` for user-defined numeric types.

## `product`

```
product : a b -> b
```

Product of a numeric foldable.  Identity is `1`.  Same caveat as `sum`.

## `elem`

```
elem : a -> b a -> Bool
```

True when the value appears in the container (by `Eq`).

## `notElem`

```
notElem : a -> b a -> Bool
```

True when the value does *not* appear in the container.  `not . elem`.

## `maximum`

```
maximum : a b -> Option b
```

Largest element by `Ord`, or `None` when the container is empty.  Generic
over any `Foldable` — `List`, `Array`, `Option`, … all reuse this one body.


*(doctest — run by `medaka test`)*

```medaka
> maximum [3, 1, 2]
Some 3
> maximum ([] : List Int)
None
```

## `minimum`

```
minimum : a b -> Option b
```

Smallest element by `Ord`, or `None` when empty.  Generic, like `maximum`.


*(doctest — run by `medaka test`)*

```medaka
> minimum [3, 1, 2]
Some 1
```

## `otherwise`

```
otherwise : Bool
```

Alias for `True`, idiomatic in guard chains.

## `not`

```
not : Bool -> Bool
```

Logical negation.

## `and`

```
and : Bool -> Bool -> Bool
```

Strict logical AND.  The lazy short-circuiting form is the `&&`
operator, which is hard-wired in the evaluator.

## `or`

```
or : Bool -> Bool -> Bool
```

Strict logical OR.  See `and` for the lazy form.

## `xor`

```
xor : Bool -> Bool -> Bool
```

Exclusive OR.

## `isSome`

```
isSome : Option a -> Bool
```

True if the value is present.

## `isNone`

```
isNone : Option a -> Bool
```

True if the value is absent.

## `fromOption`

```
fromOption : a -> Option a -> a
```

Unwrap with a default for `None`.


*(doctest — run by `medaka test`)*

```medaka
> fromOption 0 (Some 42)
42
> fromOption 0 None
0
```

## `toResult`

```
toResult : a -> Option b -> Result a b
```

Turn an `Option` into a `Result`, supplying the error for `None`.

## `fromResult`

```
fromResult : Result a b -> Option b
```

Forget the error: `Ok x → Some x`, `Err _ → None`.
Named to match the "from-Result" intuition; this is the inverse of
`toResult` modulo the discarded error value.

## `isOk`

```
isOk : Result a b -> Bool
```

True if the result is `Ok`.

## `isErr`

```
isErr : Result a b -> Bool
```

True if the result is `Err`.

## `fromResultOr`

```
fromResultOr : a -> Result b a -> a
```

Unwrap with a default for `Err`.  Named distinctly from
`fromOption` so the two don't collide when both are in scope.

## `mapErr`

```
mapErr : (a -> b) -> Result a c -> Result b c
```

Apply a function to the `Err` side, leaving `Ok` alone.  The `Ok`
analogue is just `map` from `Mappable (Result e)`.

## `identity`

```
identity : a -> a
```

Return the argument unchanged.

## `fst`

```
fst : (a, b) -> a
```

First component of a pair.

*(doctest — run by `medaka test`)*

```medaka
> fst (1, 2)
1
```

## `snd`

```
snd : (a, b) -> b
```

Second component of a pair.

*(doctest — run by `medaka test`)*

```medaka
> snd ("a", True)
True
```

## `const`

```
const : a -> b -> a
```

Return the first argument; useful as a building block for ignoring
a callback's input (`map (const 0) xs == replicate (length xs) 0`).

## `flip`

```
flip : (a -> b -> c) -> b -> a -> c
```

Swap the first two arguments of a binary function.

## `on`

```
on : (a -> a -> b) -> (c -> a) -> c -> c -> b
```

Apply a binary function `f` to two arguments after running each through a
projection `g` — the classic `on`.  `sortBy (on compare fst)` compares
pairs by their first component.


*(doctest — run by `medaka test`)*

```medaka
> on compare fst (1, 9) (2, 8)
Lt
```

## `curry`

```
curry : ((a, b) -> c) -> a -> b -> c
```

Turn a function on a pair into a function of two arguments.  The inverse
of `uncurry`.  (Medaka tuples aren't auto-curried, so this is not free.)


*(doctest — run by `medaka test`)*

```medaka
> curry fst 1 2
1
```

## `uncurry`

```
uncurry : (a -> b -> c) -> (a, b) -> c
```

Turn a two-argument function into a function on a pair.  The inverse of
`curry`.


*(doctest — run by `medaka test`)*

```medaka
> uncurry (a b => a + b) (3, 4)
7
```

## `discard`

```
discard : a b -> a Unit
```

Run a wrapped computation for its structure/effect and discard the result,
replacing it with `Unit`.  Haskell calls this `void`.


*(doctest — run by `medaka test`)*

```medaka
> discard (Some 5)
Some ()
```

## `compose`

```
compose : (a -> b) -> (c -> a) -> c -> b
```

Right-to-left function composition: `(compose g f) x == g (f x)`.
Spelled `<<` as an operator.

## `pipe`

```
pipe : (a -> b) -> (b -> c) -> a -> c
```

Left-to-right function composition: `(pipe f g) x == g (f x)`.
Spelled `>>` as an operator.

## `apply`

```
apply : (a -> b) -> a -> b
```

Function application as a function.  Mainly useful for higher-order
code that wants to defer "actually call this" decisions.

## `Arbitrary`

```
interface Arbitrary a
  arbitrary : Unit -> <Rand> a
  shrink : a -> List a
  shrink : _
```

Sources of random values for property-based testing (`prop` decls).
`arbitrary` produces a value in the `<Rand>` effect; `shrink` returns
progressively smaller candidates used to reduce a failing example.

## `Arbitrary Int`

```
impl Arbitrary Int
```

## `Arbitrary Bool`

```
impl Arbitrary Bool
```

## `Arbitrary Float`

```
impl Arbitrary Float
```

## `Arbitrary Char`

```
impl Arbitrary Char
```

## `arbitraryString`

```
arbitraryString : Unit -> <Rand> String
```

Generate a random string of 0–10 printable ASCII chars.

## `arbitraryList`

```
arbitraryList : (Unit -> <Rand> a) -> Int -> <Rand> List a
```

Generate a list of up to `maxLen` elements using `gen`.

## `Rep`

```
data Rep
  = RCon String (List Rep)
  | RRecord String (List RField)
  | RInt Int
  | RFloat Float
  | RString String
  | RBool Bool
  | RChar Char
  | RUnit
```

A uniform, flat structural view of any value.  `deriving (Generic)`
synthesises `to_rep`, turning a value into this tagged tree; a library
author writes one function over `Rep` and gets their typeclass for any
deriving type (serialisation, hashing, pretty-printing, …).

`RCon` carries a constructor's name and its positional fields' reps;
`RRecord` carries a record type's name and its named fields.  The
remaining constructors are primitive leaves.

## `RField`

```
data RField
  = RField { fld_name : String, fld_rep : Rep }
```

A named field inside an `RRecord`.

## `Generic`

```
interface Generic a
  to_rep : a -> Rep
  from_rep : Rep -> a
  from_rep : _
```

Types with a structural representation.  `to_rep` is synthesised by
`deriving (Generic)`.  `from_rep` is return-type polymorphic, which the
runtime cannot dispatch on arguments alone, so it is a stub for now —
the signature is fixed so a later phase can fill in real bodies.

## `Generic Int`

```
impl Generic Int
```

## `Generic Float`

```
impl Generic Float
```

## `Generic Bool`

```
impl Generic Bool
```

## `Generic Char`

```
impl Generic Char
```

## `Generic Unit`

```
impl Generic Unit
```

