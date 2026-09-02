# core

## `Ordering`

```
data Ordering
  = Lt
  | Eq
  | Gt
```

Instances: `Debug`, `Eq`, `Ord`, `Display`, `Hashable`

Three-way comparison result, produced by `Ord.compare`.

## `Option`

```
data Option a
  = Some a
  | None
```

Instances: `Eq`, [`Ord`](#ord-option-a), `Debug`, `Display`, `Hashable`, `Mappable`, `Applicative`, `Thenable`, `Alternative`, `Foldable`, `Traversable`, [`Arbitrary`](#arbitrary-option-a)

A value that may be absent.  Medaka's name for Haskell's `Maybe`.

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

Instances: `Eq`, [`Ord`](#ord-result-e-a), `Debug`, `Display`, `Hashable`, `Mappable`, `Applicative`, `Thenable`, `Bimappable`, `Foldable`, `Traversable`

A computation that either succeeded with `Ok a` or failed with `Err e`.
Errors are data; pattern-match to handle them.  See language-design.md.

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
neq : Eq a => a -> a -> Bool
```

Negation of `eq`.  Standalone so impls cannot make it disagree with `eq`.

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
clamp : Ord a => a -> a -> a -> a
```

`clamp lo hi x` constrains `x` into the inclusive interval `[lo, hi]`.
Precondition: `lo <= hi`; otherwise the result is `lo`.

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

```medaka
> isOdd 3
True
> isOdd 8
False
```

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

## `println`

```
println : Display a => a -> <IO> Unit
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
print : Display a => a -> <IO> Unit
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

## `Mappable`

```
interface Mappable f
  map : (a -> <e> b) -> f a -> <e> f b
```

Structure-preserving map (a.k.a. Functor).  Laws:
map identity      == identity
map (g `compose` f) == map g `compose` map f

## `mapConst`

```
mapConst : Mappable f => b -> f a -> f b
```

Replace every element of a wrapped value with a constant, keeping the
structure — Haskell's `<$`.  `mapConst b fa == map (const b) fa`.

Value-first/data-last, like every other prelude combinator: the argument
the name is about comes first, and the container comes last so partial
application composes (#2306 E-2 renamed and reordered this from
`replaceWith : f a -> b -> f b`).

```medaka
> mapConst 9 (Some 5)
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

## `map2`

```
map2 : Applicative f => (a -> b -> c) -> f a -> f b -> f c
```

Lift a binary function over two applicative values — Haskell's `liftA2`.

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
map3 : Applicative f => (a -> b -> c -> d) -> f a -> f b -> f c -> f d
```

Lift a ternary function over three applicative values — Haskell's `liftA3`.

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
flatMap : Thenable m => (a -> <e> m b) -> m a -> <e> m b
```

`andThen` with arguments flipped — the Haskell/Scala `flatMap`.

## `flat`

```
flat : Thenable m => m (m a) -> m a
```

Collapse one layer of nesting.  Haskell calls this `join`.

## `when`

```
when : Thenable m => Bool -> m Unit -> m Unit
```

Run an action only when the condition holds.

## `unless`

```
unless : Thenable m => Bool -> m Unit -> m Unit
```

Run an action only when the condition is false.  Dual of `when`.

## `foldThen`

```
foldThen : Thenable m => (b -> a -> <e> m b) -> b -> List a -> <e> m b
```

Monadic left fold: thread an accumulator through an effectful step, in
order, over a list.  Haskell's `foldM`.

```medaka
> foldThen (acc x => Some (acc + x)) 0 [1, 2, 3]
Some 6
```

## `repeatThen`

```
repeatThen : Thenable m => Int -> m a -> m (List a)
```

Run an action `n` times and collect the results in order.  `n <= 0`
yields `pure []`.  Haskell's `replicateM`.

```medaka
> repeatThen 3 (Some 7)
Some [7, 7, 7]
```

## `filterThen`

```
filterThen : Thenable m => (a -> <e> m Bool) -> List a -> <e> m (List a)
```

Keep the elements for which an effectful predicate returns `True`, in
order.  Haskell's `filterM`.

```medaka
> filterThen (x => Some (x > 1)) [1, 2, 3]
Some [2, 3]
```

## `forEach`

```
forEach : Thenable m => (a -> <e> m Unit) -> List a -> <e> m Unit
```

Run an effectful action for each element, in order, discarding the
per-element results.  Haskell's `traverse_`/`for_` specialised to `List`.

Fn-first/data-last, matching `find`/`count`/`any`/`all`/`filterThen`
(#2306 E-1 reordered this from `List a -> (a -> m Unit) -> m Unit`).  The
doctest below is also the PIN for that order: a reorder is silent wherever
both arguments still typecheck, but a lambda is not a `List`, so this line
fails to typecheck under the old signature.

```medaka
> forEach (x => Some ()) [1, 2, 3]
Some ()
```

## `runEach`

```
runEach : Thenable m => List (m a) -> m Unit
```

Run each action in a list, in order, discarding the results.  Haskell's
`sequence_` specialised to `List`.

```medaka
> runEach [Some 1, Some 2]
Some ()
```

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

## `guard`

```
guard : Alternative f => Bool -> f Unit
```

`guard True` succeeds with `pure ()`; `guard False` is the failing
`noMatch`.  Used to prune an `Alternative` computation on a condition.

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

```medaka
> bimap (n => n + 1) (n => n * 2) (Ok 5 : Result Int Int)
Ok 10
> bimap (n => n + 1) (n => n * 2) (Err 5 : Result Int Int)
Err 6
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

## `any`

```
any : Foldable t => (a -> <e> Bool) -> t a -> <e> Bool
```

True when at least one element satisfies the predicate.

```medaka
> any (x => x > 2) [1, 2, 3]
True
> any (x => x > 10) [1, 2, 3]
False
```

## `all`

```
all : Foldable t => (a -> <e> Bool) -> t a -> <e> Bool
```

True when every element satisfies the predicate.  Vacuously true on
the empty container.

```medaka
> all (x => x > 0) [1, 2, 3]
True
> all (x => x > 0) []
True
```

## `find`

```
find : Foldable t => (a -> <e> Bool) -> t a -> <e> Option a
```

First element satisfying the predicate, or `None` if none do.
Latches the first hit via an as-pattern so subsequent elements don't
overwrite the answer.

## `count`

```
count : Foldable t => (a -> <e> Bool) -> t a -> <e> Int
```

Number of elements satisfying the predicate.

## `sum`

```
sum : (Foldable t, Num a) => t a -> a
```

Sum of a numeric foldable.  Identity is `0`; in practice this only
works for `Int` today because `(+)` is a builtin that doesn't yet
dispatch through `Num.add` for user-defined numeric types.

## `product`

```
product : (Foldable t, Num a) => t a -> a
```

Product of a numeric foldable.  Identity is `1`.  Same caveat as `sum`.

## `elem`

```
elem : (Foldable t, Eq a) => a -> t a -> Bool
```

True when the value appears in the container (by `Eq`).

## `notElem`

```
notElem : (Foldable t, Eq a) => a -> t a -> Bool
```

True when the value does *not* appear in the container.  `not . elem`.

## `maximum`

```
maximum : (Foldable t, Ord a) => t a -> Option a
```

Largest element by `Ord`, or `None` when the container is empty.  Generic
over any `Foldable` — `List`, `Array`, `Option`, … all reuse this one body.

```medaka
> maximum [3, 1, 2]
Some 3
> maximum ([] : List Int)
None
```

## `minimum`

```
minimum : (Foldable t, Ord a) => t a -> Option a
```

Smallest element by `Ord`, or `None` when empty.  Generic, like `maximum`.

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

## `optionOr`

```
optionOr : a -> Option a -> a
```

Unwrap with a default for `None`.

```medaka
> optionOr 0 (Some 42)
42
> optionOr 0 None
0
```

## `option`

```
option : b -> (a -> <e> b) -> Option a -> <e> b
```

Eliminate an `Option` by supplying a default for `None` and a function
for `Some`.  Named for what it eliminates (Haskell calls it `maybe`).

Lived in a published one-entry `option` module until the
0.1.0 surface freeze moved it beside its own type (#2306 I-2).

```medaka
> option 0 (x => x + 1) (Some 41)
42
> option 0 (x => x + 1) None
0
```

## `toResult`

```
toResult : e -> Option a -> Result e a
```

Turn an `Option` into a `Result`, supplying the error for `None`.

## `fromResult`

```
fromResult : Result e a -> Option a
```

Forget the error: `Ok x → Some x`, `Err _ → None`.
Named to match the "from-Result" intuition; this is the inverse of
`toResult` modulo the discarded error value.

## `isOk`

```
isOk : Result e a -> Bool
```

True if the result is `Ok`.

## `isErr`

```
isErr : Result e a -> Bool
```

True if the result is `Err`.

## `resultOr`

```
resultOr : a -> Result e a -> a
```

Unwrap with a default for `Err`.  Named distinctly from
`optionOr` so the two don't collide when both are in scope.

## `result`

```
result : (e -> <eff> c) -> (a -> <eff> c) -> Result e a -> <eff> c
```

Eliminate a `Result` by supplying a handler for `Err` and a handler for
`Ok`.  Named for what it eliminates (Haskell calls it `either`).

Lived in a published one-entry `result` module until the
0.1.0 surface freeze moved it beside its own type (#2306 I-2).

```medaka
> result (e => 0) (x => x + 1) (Ok 41)
42
> result (e => e) (x => x + 1) (Err 7)
7
```

## `mapErr`

```
mapErr : (e -> f) -> Result e a -> Result f a
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

```medaka
> fst (1, 2)
1
```

## `snd`

```
snd : (a, b) -> b
```

Second component of a pair.

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
flip : (a -> b -> <e> c) -> b -> a -> <e> c
```

Swap the first two arguments of a binary function.

## `on`

```
on : (b -> b -> <e> c) -> (a -> b) -> a -> a -> <e> c
```

Apply a binary function `f` to two arguments after running each through a
projection `g` — the classic `on`.  `sortBy (on compare fst)` compares
pairs by their first component.

```medaka
> on compare fst (1, 9) (2, 8)
Lt
```

## `curry`

```
curry : ((a, b) -> <e> c) -> a -> b -> <e> c
```

Turn a function on a pair into a function of two arguments.  The inverse
of `uncurry`.  (Medaka tuples aren't auto-curried, so this is not free.)

```medaka
> curry fst 1 2
1
```

## `uncurry`

```
uncurry : (a -> b -> <e> c) -> (a, b) -> <e> c
```

Turn a two-argument function into a function on a pair.  The inverse of
`curry`.

```medaka
> uncurry (a b => a + b) (3, 4)
7
```

## `discard`

```
discard : Mappable f => f a -> f Unit
```

Run a wrapped computation for its structure/effect and discard the result,
replacing it with `Unit`.  Haskell calls this `void`.

```medaka
> discard (Some 5)
Some ()
```

## `compose`

```
compose : (b -> <e> c) -> (a -> <e> b) -> a -> <e> c
```

Right-to-left function composition: `(compose g f) x == g (f x)`.
Spelled `<<` as an operator.

## `pipe`

```
pipe : (a -> <e> b) -> (b -> <e> c) -> a -> <e> c
```

Left-to-right function composition: `(pipe f g) x == g (f x)`.
Spelled `>>` as an operator.

## `apply`

```
apply : (a -> <e> b) -> a -> <e> b
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

Instances: `Eq`, `Debug`

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

Instances: `Eq`, `Debug`

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

## Instances

- `Int`: `Eq`, `Ord`, `Debug`, `Display`, `Hashable`, `Num`, [`Bounded`](#bounded-int), `Arbitrary`, `Generic`
- `Float`: `Eq`, [`Ord`](#ord-float), `Debug`, `Display`, `Hashable`, `Num`, `Arbitrary`, `Generic`
- `Bool`: `Eq`, `Debug`, `Display`, `Hashable`, `Arbitrary`, `Generic`
- `Char`: `Eq`, `Ord`, `Debug`, `Display`, `Hashable`, [`Bounded`](#bounded-char), `Arbitrary`, `Generic`
- `Unit`: `Eq`, `Debug`, `Display`, `Hashable`, `Generic`
- `(a, b)`: `Eq`, `Ord`, `Debug`, `Display`, `Hashable`
- `(a, b, c)`: `Eq`, `Ord`, `Debug`, `Display`, `Hashable`
- `(a, b, c, d)`: `Eq`, `Ord`, `Debug`, `Display`, `Hashable`
- `(a, b, c, d, e)`: `Eq`, `Ord`, `Debug`, `Display`, `Hashable`
- `__tuple2__`: `Bimappable`

### `Ord Float`

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

### `Ord (Option a)`

```
impl Ord (Option a) requires Ord a
```

`None` sorts before every `Some`; two `Some`s compare by their contents.

### `Ord (Result e a)`

```
impl Ord (Result e a) requires Ord e, Ord a
```

`Err` sorts before `Ok`; like constructors compare by their payloads.

### `Bounded Int`

```
impl Bounded Int
```

`Int` bounds are the platform's 63-bit native-integer limits.

```medaka
> (minBound : Int) < (maxBound : Int)
True
```

### `Bounded Char`

```
impl Bounded Char
```

`Char` ranges over the Unicode scalar values, U+0000 to U+10FFFF.

```medaka
> charCode (minBound : Char)
0
> charCode (maxBound : Char)
1114111
```

### `Arbitrary (Option a)`

```
impl Arbitrary (Option a) requires Arbitrary a
```

Half the draws are `None`.  `shrink` collapses a `Some` to `None`, which
is the only strictly smaller `Option` there is.

