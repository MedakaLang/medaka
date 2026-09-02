# core

The prelude: the types, interfaces, and functions every Medaka program
can use without an import.

This module defines `Option`, `Result`, and `Ordering`; the interface
hierarchy (`Eq`, `Ord`, `Semigroup`, `Monoid`, `Debug`, `Display`,
`Hashable`, `Num`, `Bounded`, `Mappable`, `Applicative`, `Thenable`,
`Alternative`, `Bimappable`, `Foldable`, `Filterable`, `Traversable`,
`Index`, `Slice`, `FromEntries`) with instances for the built-in types;
and the standalone helpers for booleans, options, results, and functions.
The container-specific operations live in their own modules (`list`,
`array`, `map`, and so on).

## Data types

### `Ordering`

```
data Ordering
  = Lt
  | Eq
  | Gt
```

The result of a three-way comparison, produced by `compare`.

Instances: `Debug`, `Eq`, `Ord`, `Display`, `Hashable`

### `Option`

```
data Option a
  = Some a
  | None
```

A value that may be absent.

```medaka
> isSome (Some 1)
True
> isSome None
False
```

Instances: `Eq`, [`Ord`](#ord-option-a), `Debug`, `Display`, `Hashable`, `Mappable`, `Applicative`, `Thenable`, `Alternative`, `Foldable`, `Traversable`, [`Arbitrary`](#arbitrary-option-a)

### `Result`

```
data Result e a
  = Ok a
  | Err e
```

A computation that either succeeded with `Ok a` or failed with `Err e`.

Errors are ordinary values. Pattern-match to handle them, or use the
`Thenable` instance and `do` notation to sequence steps that may fail.

```medaka
> isOk (Ok 1)
True
> isOk (Err "boom")
False
```

Instances: `Eq`, [`Ord`](#ord-result-e-a), `Debug`, `Display`, `Hashable`, `Mappable`, `Applicative`, `Thenable`, `Bimappable`, `Foldable`, `Traversable`

## Equality and ordering

### `Eq`

```
interface Eq a
  eq : a -> a -> Bool
```

Equality.

`eq` must be reflexive, symmetric, and transitive. The `==` operator on
the primitive types is built in and does not go through this interface;
the instances here are what let generic `Eq a =>` code work.

### `neq`

```
neq : Eq a => a -> a -> Bool
```

The negation of `eq`.

### `Semigroup`

```
interface Semigroup a
  append : a -> a -> a
```

Types with an associative combining operation.

`append` backs the `++` operator. It must be associative:
`append a (append b c)` equals `append (append a b) c`.

### `Monoid`

```
interface Monoid a
  empty : a
```

A `Semigroup` with an identity element.

`empty` must be a left and right identity for `append`:
`append empty x` and `append x empty` both equal `x`.

### `Ord`

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

Types with a total order.

`compare` is the only method an instance must define. The comparison
helpers `lt`, `gt`, `lte`, `gte`, `min`, and `max` default to definitions
in terms of `compare`, and an instance may override them.

### `clamp`

```
clamp : Ord a => a -> a -> a -> a
```

`x` limited to the inclusive range `[lo, hi]`.

Requires `lo <= hi`; otherwise the result is `lo`.

```medaka
> clamp 0 10 5
5
> clamp 0 10 99
10
```

## Rendering

### `Debug`

```
interface Debug a
  debug : a -> String
```

Types with a developer-facing text rendering.

`debug` renders a value as Medaka source: strings and characters are
quoted and escaped, constructors are shown by name, and lists, arrays,
and tuples use their literal syntax. `medaka test` compares a doctest's
result against its expected text with `debug`. `Display` is the
user-facing counterpart, which leaves strings unquoted.

### `Display`

```
interface Display a
  display : a -> String
```

Types with a user-facing text rendering.

`display` is what string interpolation calls: `"\{e}"` is `display e`.
It differs from `debug` in one way: strings and characters are spliced in
as they are, not quoted. For every other type it matches `debug`, and
nested strings stay unquoted. `deriving (Display)` works like
`deriving (Debug)`.

## Hashing

### `Hashable`

```
interface Hashable a
  hash : a -> Int
```

Types that can be used as hash-table keys.

Values that are equal by `Eq` must have equal hashes. Hashes need not be
unique, and may be negative. The compound instances (`Option`, `Result`,
`List`, `Array`, tuples) and `deriving (Hashable)` all use the same fold
over the fields, so an array hashes the same as the list of its
elements.

## Output

### `println`

```
println : Display a => a -> <IO> Unit
```

Writes a value to standard output, followed by a newline.

The value is rendered with `display`, so strings print without quotes
and a `Map` prints as `Map { 1 => 10 }`. For the `debug` rendering, use
`io.inspect`.

### `print`

```
print : Display a => a -> <IO> Unit
```

Writes a value to standard output with no trailing newline. See `println`.

## Numbers

### `Num`

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

Numeric types.

The arithmetic operators are built in for `Int` and `Float`; on any other
type, `+`, `-`, `*`, and `/` dispatch to `add`, `sub`, `mul`, and `div`.
`div` truncates for `Int` and is true division for `Float`.

### `isEven`

```
isEven : Int -> Bool
```

Whether `n` is divisible by two. Negative numbers included.

```medaka
> isEven 4
True
> isEven 7
False
```

### `isOdd`

```
isOdd : Int -> Bool
```

Whether `n` is not divisible by two.

```medaka
> isOdd 3
True
```

### `Bounded`

```
interface Bounded a
  minBound : a
  maxBound : a
```

Types with a smallest and a largest value.

## Mapping and sequencing

### `Mappable`

```
interface Mappable f
  map : (a -> <e> b) -> f a -> <e> f b
```

Containers whose elements can be transformed in place.

`map` must preserve the container's shape: `map identity` is the identity,
and `map (g << f)` equals `map g << map f`.

### `mapConst`

```
mapConst : Mappable f => b -> f a -> f b
```

The container with every element replaced by `b`.

Equivalent to `map (const b)`.

```medaka
> mapConst 9 (Some 5)
Some 9
```

### `Applicative`

```
interface Applicative f
  pure : a -> f a
  ap : f (a -> b) -> f a -> f b
```

Containers that can wrap a plain value and apply a wrapped function to a
wrapped argument.

`pure` wraps a value. `ap` applies a function inside one container to a
value inside another. The instances follow the usual applicative laws.

### `map2`

```
map2 : Applicative f => (a -> b -> c) -> f a -> f b -> f c
```

Combines two wrapped values with a two-argument function.

For `Option` and `Result`, the result is `None` or the first `Err` when
either input is. For lists, `f` is applied to every pair.

```medaka
> map2 (a b => a + b) (Some 3) (Some 4)
Some 7
> map2 (a b => a + b) [1, 2] [10, 20]
[11, 21, 12, 22]
```

### `map3`

```
map3 : Applicative f => (a -> b -> c -> d) -> f a -> f b -> f c -> f d
```

Combines three wrapped values with a three-argument function. See
`map2`.

```medaka
> map3 (a b c => a + b + c) (Some 1) (Some 2) (Some 3)
Some 6
```

### `Thenable`

```
interface Thenable m
  andThen : m a -> (a -> <e> m b) -> <e> m b
```

Containers whose computations can be sequenced, each step seeing the
result of the last.

`andThen m f` runs `m`, then passes its result to `f`. It is what `do`
notation desugars to. For `Option` and `Result`, a `None` or `Err` stops
the sequence.

### `flatMap`

```
flatMap : Thenable m => (a -> <e> m b) -> m a -> <e> m b
```

`andThen` with its arguments swapped.

### `flat`

```
flat : Thenable m => m (m a) -> m a
```

Removes one level of nesting: `Some (Some 1)` becomes `Some 1`.

### `when`

```
when : Thenable m => Bool -> m Unit -> m Unit
```

Runs an action only when the condition holds.

### `unless`

```
unless : Thenable m => Bool -> m Unit -> m Unit
```

Runs an action only when the condition does not hold.

### `foldThen`

```
foldThen : Thenable m => (b -> a -> <e> m b) -> b -> List a -> <e> m b
```

A left fold whose step is an action, run in order over the list.

```medaka
> foldThen (acc x => Some (acc + x)) 0 [1, 2, 3]
Some 6
```

### `repeatThen`

```
repeatThen : Thenable m => Int -> m a -> m (List a)
```

Runs an action `n` times and collects the results in order.

`pure []` when `n <= 0`.

```medaka
> repeatThen 3 (Some 7)
Some [7, 7, 7]
```

### `filterThen`

```
filterThen : Thenable m => (a -> <e> m Bool) -> List a -> <e> m (List a)
```

Keeps the elements for which an action returns `True`, in order.

```medaka
> filterThen (x => Some (x > 1)) [1, 2, 3]
Some [2, 3]
```

### `forEach`

```
forEach : Thenable m => (a -> <e> m Unit) -> List a -> <e> m Unit
```

Runs an action for each element in order, discarding the results.

```medaka
> forEach (x => Some ()) [1, 2, 3]
Some ()
```

### `runEach`

```
runEach : Thenable m => List (m a) -> m Unit
```

Runs each action in the list in order, discarding the results.

```medaka
> runEach [Some 1, Some 2]
Some ()
```

### `Alternative`

```
interface Alternative f
  noMatch : f a
  orElse : f a -> f a -> f a
```

Containers with a notion of failure and a fallback.

`noMatch` is the failing value: `None`, or the empty list. `orElse a b`
is `a` unless `a` failed, in which case it is `b`. For lists, `orElse` is
concatenation. `noMatch` is the identity for `orElse`, and `orElse` is
associative.

```medaka
> orElse None (Some 2)
Some 2
> orElse [1, 2] [3]
[1, 2, 3]
```

### `guard`

```
guard : Alternative f => Bool -> f Unit
```

Succeeds when the condition holds and fails otherwise.

`guard True` is `pure ()`; `guard False` is `noMatch`. Use it to stop an
`Alternative` computation on a condition.

```medaka
> (guard True : Option Unit)
Some ()
> (guard False : Option Unit)
None
```

### `Bimappable`

```
interface Bimappable p
  bimap : (a -> <e> c) -> (b -> <e> d) -> p a b -> <e> p c d
  mapFirst : (a -> <e> c) -> p a b -> <e> p c b
  mapFirst : _
  mapSecond : (b -> <e> d) -> p a b -> <e> p a d
  mapSecond : _
```

Two-parameter types whose parameters can be mapped independently.

`bimap f g` applies `f` to the first parameter and `g` to the second.
`mapFirst` and `mapSecond` map one side and default to `bimap` with
`identity` on the other. For `Result`, the first side is `Err` and the
second is `Ok`.

```medaka
> bimap (n => n + 1) (n => n * 2) (Ok 5 : Result Int Int)
Ok 10
> bimap (n => n + 1) (n => n * 2) (Err 5 : Result Int Int)
Err 6
```

## Containers

### `Foldable`

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

Containers whose elements can be reduced to a single value.

`fold` is a strict left fold. `foldRight` is the right fold, which
preserves element order in the result and is the one to use when the
step builds a structure. An instance defines `fold`, `foldRight`, and
`toList`; `foldMap`, `length`, and `isEmpty` have defaults, which an
instance may override where a faster version exists.

```medaka
> fold (acc x => acc + x) 0 [1, 2, 3]
6
> length (Some 5)
1
```

### `Filterable`

```
interface Filterable f
  filterMap : (a -> <e> Option b) -> f a -> <e> f b
  filter : (a -> <e> Bool) -> f a -> <e> f a
  filter : _
```

Containers whose elements can be dropped.

`filterMap` keeps the `Some` results of applying a function to each
element. `filter` keeps the elements satisfying a predicate, and defaults
to a definition in terms of `filterMap`. Not every `Mappable` container
is `Filterable`: a fixed-shape container cannot shrink.

### `FromEntries`

```
interface FromEntries c e
  fromEntries : List e -> c
```

Containers that can be built from a list of entries.

The container literals desugar to `fromEntries`: `Map { k => v }` is
`fromEntries [(k, v)]` and `Set { x }` is `fromEntries [x]`, with the
result type pinned to the named container. `c` is the container and `e`
its entry type: `(k, v)` for a map, the element for a set. Each container
module defines its own instance.

### `Index`

```
interface Index c k v
  index : c -> k -> v
```

Containers that can be read at a key.

`index c k` is the value at `k`; the `c[k]` syntax dispatches here. An
instance panics with an index error when `k` is out of range or absent.

### `IndexMut`

```
interface IndexMut c k v
  setIndex : c -> k -> v -> c
```

Containers that can be written at a key.

`setIndex c k v` writes `v` at `k` and returns the container, mutated in
place where the container is mutable.

### `Slice`

```
interface Slice c
  slice : c -> Int -> Int -> c
```

Containers that can be sliced by a half-open index range.

`slice c lo hi` is the sub-container over indices `[lo, hi)`. The
`c.[lo..hi]` and `c.[lo..=hi]` syntax dispatches here.

### `Traversable`

```
interface Traversable t
  traverse : Thenable m => (a -> <e> m b) -> t a -> <e> m (t b)
  sequence : Thenable m => t (m a) -> m (t a)
  sequence : _
```

Containers whose elements can be visited left to right with an action,
collecting the results inside the action's type.

`traverse f` applies `f` to each element and gathers the results.
`sequence` turns a container of actions into an action producing the
container. With `Option` or `Result` as the action, the first `None` or
`Err` is the result.

```medaka
> traverse (x => if x > 0 then Some x else None) [1, 2, 3]
Some [1, 2, 3]
> sequence [Ok 1, Err 99, Ok 3]
Err 99
```

## Folding

### `any`

```
any : Foldable t => (a -> <e> Bool) -> t a -> <e> Bool
```

Whether at least one element satisfies `f`.

```medaka
> any (x => x > 2) [1, 2, 3]
True
```

### `all`

```
all : Foldable t => (a -> <e> Bool) -> t a -> <e> Bool
```

Whether every element satisfies `f`.

`True` on an empty container.

```medaka
> all (x => x > 0) [1, 2, 3]
True
> all (x => x > 0) []
True
```

### `find`

```
find : Foldable t => (a -> <e> Bool) -> t a -> <e> Option a
```

The first element satisfying `f`, or `None`.

```medaka
> find (x => x > 1) [1, 2, 3]
Some 2
```

### `count`

```
count : Foldable t => (a -> <e> Bool) -> t a -> <e> Int
```

The number of elements satisfying `f`.

```medaka
> count isEven [1, 2, 3, 4]
2
```

### `sum`

```
sum : (Foldable t, Num a) => t a -> a
```

The sum of the elements. `0` for an empty container.

```medaka
> sum [1, 2, 3]
6
```

### `product`

```
product : (Foldable t, Num a) => t a -> a
```

The product of the elements. `1` for an empty container.

```medaka
> product [2, 3, 4]
24
```

### `elem`

```
elem : (Foldable t, Eq a) => a -> t a -> Bool
```

Whether the value occurs in the container.

```medaka
> elem 2 [1, 2, 3]
True
```

### `notElem`

```
notElem : (Foldable t, Eq a) => a -> t a -> Bool
```

Whether the value does not occur in the container.

### `maximum`

```
maximum : (Foldable t, Ord a) => t a -> Option a
```

The largest element, or `None` when the container is empty.

```medaka
> maximum [3, 1, 2]
Some 3
```

### `minimum`

```
minimum : (Foldable t, Ord a) => t a -> Option a
```

The smallest element, or `None` when the container is empty.

```medaka
> minimum [3, 1, 2]
Some 1
```

## Booleans

### `otherwise`

```
otherwise : Bool
```

`True`, for the final guard of a guard chain.

### `not`

```
not : Bool -> Bool
```

Logical negation.

### `and`

```
and : Bool -> Bool -> Bool
```

Logical and, with both arguments evaluated.

The `&&` operator evaluates its right operand only when the left is
`True`.

### `or`

```
or : Bool -> Bool -> Bool
```

Logical or, with both arguments evaluated.

The `||` operator evaluates its right operand only when the left is
`False`.

### `xor`

```
xor : Bool -> Bool -> Bool
```

Exclusive or.

## Options

### `isSome`

```
isSome : Option a -> Bool
```

Whether the value is `Some`.

### `isNone`

```
isNone : Option a -> Bool
```

Whether the value is `None`.

### `optionOr`

```
optionOr : a -> Option a -> a
```

The value inside a `Some`, or the default for `None`.

```medaka
> optionOr 0 (Some 42)
42
> optionOr 0 None
0
```

### `option`

```
option : b -> (a -> <e> b) -> Option a -> <e> b
```

Applies `f` to the value inside a `Some`, or returns the default for
`None`.

```medaka
> option 0 (x => x + 1) (Some 41)
42
> option 0 (x => x + 1) None
0
```

### `toResult`

```
toResult : e -> Option a -> Result e a
```

The option as a result, with `e` as the error for `None`.

```medaka
> toResult "missing" (Some 1)
Ok 1
> toResult "missing" None
Err "missing"
```

### `fromResult`

```
fromResult : Result e a -> Option a
```

The result as an option, discarding the error.

```medaka
> fromResult (Ok 1)
Some 1
> fromResult (Err "boom")
None
```

## Results

### `isOk`

```
isOk : Result e a -> Bool
```

Whether the result is `Ok`.

### `isErr`

```
isErr : Result e a -> Bool
```

Whether the result is `Err`.

### `resultOr`

```
resultOr : a -> Result e a -> a
```

The value inside an `Ok`, or the default for `Err`.

```medaka
> resultOr 0 (Ok 42)
42
> resultOr 0 (Err "boom")
0
```

### `result`

```
result : (e -> <eff> c) -> (a -> <eff> c) -> Result e a -> <eff> c
```

Applies `onErr` to the error of an `Err`, or `onOk` to the value of an
`Ok`.

```medaka
> result (e => 0) (x => x + 1) (Ok 41)
42
> result (e => e) (x => x + 1) (Err 7)
7
```

### `mapErr`

```
mapErr : (e -> f) -> Result e a -> Result f a
```

Applies `f` to the error of an `Err`, leaving an `Ok` unchanged.

`map` is the counterpart for the `Ok` side.

```medaka
> mapErr (e => "failed: " ++ e) (Err "boom")
Err "failed: boom"
```

## Functions

### `identity`

```
identity : a -> a
```

Its argument, unchanged.

### `fst`

```
fst : (a, b) -> a
```

The first component of a pair.

```medaka
> fst (1, 2)
1
```

### `snd`

```
snd : (a, b) -> b
```

The second component of a pair.

```medaka
> snd ("a", True)
True
```

### `const`

```
const : a -> b -> a
```

A function that ignores its argument and returns `x`.

```medaka
> map (const 0) [1, 2, 3]
[0, 0, 0]
```

### `flip`

```
flip : (a -> b -> <e> c) -> b -> a -> <e> c
```

`f` with its two arguments swapped.

```medaka
> flip (a b => a - b) 1 10
9
```

### `on`

```
on : (b -> b -> <e> c) -> (a -> b) -> a -> a -> <e> c
```

Applies `f` to the results of `g` on each argument.

`on compare fst` compares pairs by their first component.

```medaka
> on compare fst (1, 9) (2, 8)
Lt
```

### `curry`

```
curry : ((a, b) -> <e> c) -> a -> b -> <e> c
```

A function on a pair as a function of two arguments. The inverse of
`uncurry`.

```medaka
> curry fst 1 2
1
```

### `uncurry`

```
uncurry : (a -> b -> <e> c) -> (a, b) -> <e> c
```

A function of two arguments as a function on a pair. The inverse of
`curry`.

```medaka
> uncurry (a b => a + b) (3, 4)
7
```

### `discard`

```
discard : Mappable f => f a -> f Unit
```

The container with its contents replaced by `()`.

Use it to run a computation for its effect or structure alone.

```medaka
> discard (Some 5)
Some ()
```

### `compose`

```
compose : (b -> <e> c) -> (a -> <e> b) -> a -> <e> c
```

Right-to-left composition: `compose g f` applies `f`, then `g`. The
`<<` operator.

### `pipe`

```
pipe : (a -> <e> b) -> (b -> <e> c) -> a -> <e> c
```

Left-to-right composition: `pipe f g` applies `f`, then `g`. The `>>`
operator.

### `apply`

```
apply : (a -> <e> b) -> a -> <e> b
```

Function application as a function: `apply f x` is `f x`.

## Property testing

### `Arbitrary`

```
interface Arbitrary a
  arbitrary : Unit -> <Rand> a
  shrink : a -> List a
  shrink : _
```

Types that can generate random values for property tests.

`arbitrary` draws a value in the `<Rand>` effect. `shrink` lists smaller
candidates, tried in order to reduce a failing example; it defaults to
none.

### `arbitraryString`

```
arbitraryString : Unit -> <Rand> String
```

A random string of up to ten printable ASCII characters.

### `arbitraryList`

```
arbitraryList : (Unit -> <Rand> a) -> Int -> <Rand> List a
```

A random list of up to `maxLen` elements, each drawn with `gen`.

## Generic representation

### `Rep`

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

A uniform structural view of a value, produced by `deriving (Generic)`.

`RCon` is a constructor with its name and positional fields; `RRecord` is
a record with its name and named fields. The other constructors are the
primitive leaves. A function written over `Rep` works for every type
that derives `Generic`.

Instances: `Eq`, `Debug`

### `RField`

```
data RField
  = RField { fld_name : String, fld_rep : Rep }
```

A named field inside an `RRecord`.

Instances: `Eq`, `Debug`

### `Generic`

```
interface Generic a
  to_rep : a -> Rep
  from_rep : Rep -> a
  from_rep : _
```

Types with a structural representation.

`to_rep` is generated by `deriving (Generic)`. `from_rep` is not yet
implemented and panics when called.

## Instances

- `Int`: `Eq`, `Ord`, `Debug`, `Display`, `Hashable`, `Num`, [`Bounded`](#bounded-int), [`Arbitrary`](#arbitrary-int), `Generic`
- `Float`: `Eq`, [`Ord`](#ord-float), `Debug`, `Display`, `Hashable`, `Num`, `Arbitrary`, `Generic`
- `Bool`: `Eq`, `Debug`, `Display`, `Hashable`, `Arbitrary`, `Generic`
- `Char`: `Eq`, `Ord`, `Debug`, `Display`, `Hashable`, [`Bounded`](#bounded-char), `Arbitrary`, `Generic`
- `Unit`: `Eq`, `Debug`, `Display`, `Hashable`, `Generic`
- `(a, b)`: `Eq`, `Ord`, `Debug`, `Display`, `Hashable`
- `(a, b, c)`: `Eq`, `Ord`, `Debug`, `Display`, `Hashable`
- `(a, b, c, d)`: `Eq`, `Ord`, `Debug`, `Display`, `Hashable`
- `(a, b, c, d, e)`: `Eq`, `Ord`, `Debug`, `Display`, `Hashable`
- `__tuple2__`: [`Bimappable`](#bimappable-__tuple2__)

### `Ord Float`

```
impl Ord Float
```

Floats are totally ordered, NaN included:

```
-NaN < -inf < ... < -0.0 = +0.0 < ... < +inf < +NaN
```

`compare` agrees with `==` on every non-NaN value, so `-0.0` and `0.0`
compare `Eq`. Two NaNs of the same sign also compare `Eq`, even though
`nan == nan` is `False`. This makes `sort`, `min`, and `max` deterministic
on data that contains NaN.

`lt`, `gt`, `lte`, and `gte` are the IEEE comparisons, and are all `False`
when either operand is NaN.

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

The platform's 63-bit integer limits.

```medaka
> (minBound : Int) < (maxBound : Int)
True
```

### `Bounded Char`

```
impl Bounded Char
```

The Unicode scalar values, U+0000 to U+10FFFF.

```medaka
> charCode (maxBound : Char)
1114111
```

### `Bimappable __tuple2__`

```
impl Bimappable __tuple2__
```

Pairs map each field independently.

```medaka
> bimap (x => x + 1) (y => y * 2) (3, 4)
(4, 8)
> mapFirst (x => x + 1) (3, 4)
(4, 4)
```

### `Arbitrary Int`

```
impl Arbitrary Int
```

Draws from `-1000` to `1000`. Shrinks towards `0`.

### `Arbitrary (Option a)`

```
impl Arbitrary (Option a) requires Arbitrary a
```

Half the draws are `None`. A `Some` shrinks to `None`.

