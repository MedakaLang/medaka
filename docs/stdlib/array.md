# array

array.mdk — operations on Array a
See STDLIB.md (Module 4) for the plan.

Design notes
────────────
Arrays are fixed-size, O(1) random access, and backed by mutable memory
under the hood.  Two design tensions shape this module:

1. Performance vs. functional feel.  The public API is a pure facade
where it can be (`map`, `filter`, `sort`, etc. return fresh arrays)
and explicitly mutates in place where that's the whole point
(`set`, `swap`, `sortInPlace`) — untracked, no effect in the signature.

2. Opaque builtin vs. typeclass member.  `Array a` cannot be pattern-
matched like `List a`, so the impls below dispatch through the
`array*` primitives declared in stdlib/runtime.mdk.  We implement
`Mappable`, `Foldable`, `Eq`, `Debug`, `Semigroup`, `Monoid` — and
deliberately skip `Applicative` / `Thenable`, because the natural
definitions would encode cartesian-style allocation that's a
performance trap on bulk data.

The kernel of OCaml-backed primitives lives in stdlib/runtime.mdk and is
the surface this module sits on top of.  Most operations here are one or
two lines of Medaka built on `arrayMakeWith` + `arrayGetUnsafe`, which
compile to a tight loop in the host runtime.

## `singleton`

```
singleton : a -> Array a
```

A one-element array.


*(doctest — run by `medaka test`)*

```medaka
> toList (singleton 5)
[5]
```

## `make`

```
make : Int -> a -> Array a
```

`make n x` — a fresh array of `n` copies of `x`.


*(doctest — run by `medaka test`)*

```medaka
> toList (make 3 0)
[0, 0, 0]
```

## `makeWith`

```
makeWith : Int -> (Int -> a) -> Array a
```

`makeWith n f` — a fresh array whose element `i` is `f i`.


*(doctest — run by `medaka test`)*

```medaka
> toList (makeWith 3 (i => i * 2))
[0, 2, 4]
> length (makeWith 0 (i => i))
0
```

## `replicate`

```
replicate : Int -> a -> Array a
```

Alias for `make`, included for symmetry with `List.replicate`.

## `fromList`

```
fromList : List a -> Array a
```

Build an array from a list, preserving order.

## `range`

```
range : Int -> Int -> Array Int
```

Half-open `[lo, hi)`.  Empty when `hi <= lo`.


*(doctest — run by `medaka test`)*

```medaka
> toList (range 0 4)
[0, 1, 2, 3]
```

## `copy`

```
copy : Array a -> Array a
```

Fresh copy with the same contents.  Useful before in-place mutation
when you want to preserve the original.

## `get`

```
get : Int -> Array a -> Option a
```

Bounds-checked indexing.  `arr[i]` (which panics on OOB) is the fast
path; `get` is the safe one.


*(doctest — run by `medaka test`)*

```medaka
> get 0 (fromList [1, 2, 3])
Some 1
> get 5 (fromList [1, 2, 3])
None
```

## `first`

```
first : Array a -> Option a
```

First element, or `None` when empty.


*(doctest — run by `medaka test`)*

```medaka
> first (fromList [1, 2, 3])
Some 1
```

## `last`

```
last : Array a -> Option a
```

Last element, or `None` when empty.


*(doctest — run by `medaka test`)*

```medaka
> last (fromList [1, 2, 3])
Some 3
```

## `reverse`

```
reverse : Array a -> Array a
```

Reverse the array into a fresh one.


*(doctest — run by `medaka test`)*

```medaka
> toList (reverse (fromList [1, 2, 3]))
[3, 2, 1]
```

## `sliceClamped`

```
sliceClamped : Int -> Int -> Array a -> Array a
```

`sliceClamped lo hi arr` — half-open `[lo, hi)`.  Clamps to the array bounds:
a request outside `[0, length arr]` is silently truncated, never panics.
Use `arr.[lo..hi]` (the `Slice` interface) if you want OOB to panic instead.


*(doctest — run by `medaka test`)*

```medaka
> toList (sliceClamped 1 3 (fromList [1, 2, 3, 4, 5]))
[2, 3]
```

## `take`

```
take : Int -> Array a -> Array a
```

First `n` elements (fewer if the array is shorter).


*(doctest — run by `medaka test`)*

```medaka
> toList (take 2 (fromList [1, 2, 3, 4]))
[1, 2]
```

## `drop`

```
drop : Int -> Array a -> Array a
```

All but the first `n` elements.


*(doctest — run by `medaka test`)*

```medaka
> toList (drop 2 (fromList [1, 2, 3, 4]))
[3, 4]
```

## `concat`

```
concat : Array (Array a) -> Array a
```

Flatten one level.  Two passes: sum the inner lengths, then bulk-copy
each inner array into the result with one `arrayBlit` per inner.
O(outer + total).


*(doctest — run by `medaka test`)*

```medaka
> toList (concat (fromList [fromList [1, 2], fromList [3]]))
[1, 2, 3]
```

## `zip`

```
zip : Array a -> Array b -> Array (a, b)
```

Pair up two arrays element-wise, truncating to the shorter length.

## `zipWith`

```
zipWith : (a -> b -> c) -> Array a -> Array b -> Array c
```

Combine two arrays element-wise with `f`, truncating to the shorter.


*(doctest — run by `medaka test`)*

```medaka
> toList (zipWith (x y => x + y) (fromList [1, 2]) (fromList [10, 20]))
[11, 22]
```

## `unzip`

```
unzip : Array (a, b) -> (Array a, Array b)
```

Split an array of pairs into two parallel arrays — the inverse of `zip`.


*(doctest — run by `medaka test`)*

```medaka
> let (xs, ys) = unzip (fromList [(1, 2), (3, 4)]) in (toList xs, toList ys)
([1, 3], [2, 4])
```

## `Filterable Array`

```
impl Filterable Array
```

`Filterable Array`.  Only `filterMap` is defined; `filter` comes from
the interface default.  `filterMap` filters via a list intermediate
(tail-recursive, builds reversed then `arrayFromList` after a final
reverse): one O(N) traversal + one O(M) list build + one O(M) array
copy, no mutation so the signature stays pure.

## `set`

```
set : Int -> a -> Array a -> Unit
```

Bounds-checked write.  Panics on OOB.

## `swap`

```
swap : Int -> Int -> Array a -> Unit
```

Exchange the elements at indices `i` and `j` in place.

## `fill`

```
fill : a -> Array a -> Unit
```

Overwrite every element with `x` in place.

## `blit`

```
blit : Array a -> Int -> Array a -> Int -> Int -> Unit
```

Bounds-checked bulk copy: copies `len` elements from `src` at offset
  `srcOff` into `dst` at offset `dstOff`.  Panics when any argument is
  negative or the copy would exceed either array's bounds.

## `sortInPlaceBy`

```
sortInPlaceBy : (a -> a -> Ordering) -> Array a -> Unit
```

Sort in place using the supplied comparison.

## `sortInPlace`

```
sortInPlace : Array a -> Unit
```

Sort in place by the `Ord` instance.

## `sortBy`

```
sortBy : (a -> a -> Ordering) -> Array a -> Array a
```

Sort into a fresh array using the supplied comparison (stable mergesort).


*(doctest — run by `medaka test`)*

```medaka
> toList (sortBy compare (fromList [3, 1, 4, 1, 5]))
[1, 1, 3, 4, 5]
> toList (sortBy (x y => compare y x) (fromList [3, 1, 2]))
[3, 2, 1]
```

## `sort`

```
sort : Array a -> Array a
```

Sort into a fresh array by the `Ord` instance.


*(doctest — run by `medaka test`)*

```medaka
> toList (sort (fromList [3, 1, 4, 1, 5]))
[1, 1, 3, 4, 5]
```

## `sortOn`

```
sortOn : (a -> b) -> Array a -> Array a
```

Sort into a fresh array by a key projection, computing the key once per
element (decorate–sort–undecorate) so an expensive `key` isn't recomputed in
every comparison — matching `List.sortOn`.


*(doctest — run by `medaka test`)*

```medaka
> toList (sortOn (x => 0 - x) (fromList [1, 3, 2]))
[3, 2, 1]
```

## `find`

```
find : (a -> Bool) -> Array a -> Option a
```

First element satisfying the predicate, or `None`.

## `findIndex`

```
findIndex : (a -> Bool) -> Array a -> Option Int
```

Index of the first element satisfying the predicate, or `None`.


*(doctest — run by `medaka test`)*

```medaka
> findIndex (x => x > 2) (fromList [1, 2, 3])
Some 2
```

## `foldWithIndex`

```
foldWithIndex : (a -> Int -> b -> a) -> a -> Array b -> a
```

Left-to-right fold, threading the running index alongside each element.


*(doctest — run by `medaka test`)*

```medaka
> foldWithIndex (acc i x => acc + i * x) 0 (fromList [10, 20, 30])
80
> foldWithIndex (acc i x => (i, x) :: acc) [] (fromList ([] : List Int))
[]
```

## `forEachWithIndex`

```
forEachWithIndex : (Int -> a -> Unit) -> Array a -> Unit
```

Visit every element in order, applying `f` to its index and itself for
the side effect. The bounds-safe replacement for hand-rolled index
recursion over `get`/`arrayGetUnsafe` in effectful loops (e.g. streaming
an array's bytes into a writer).


*(doctest — run by `medaka test`)*

```medaka
> let acc = Ref [] in let _ = forEachWithIndex (i x => acc := (i, x) :: !acc) (fromList [7, 8, 9]) in !acc
[(2, 9), (1, 8), (0, 7)]
```

## `mapWithIndex`

```
mapWithIndex : (Int -> a -> b) -> Array a -> Array b
```

Map every element together with its 0-based index — the missing member of
the index-callback family (`foldWithIndex`, `forEachWithIndex`), with the
same `(i x)` callback order `list.mapWithIndex` uses.


*(doctest — run by `medaka test`)*

```medaka
> toList (mapWithIndex (i x => i * x) (fromList [1, 2, 3]))
[0, 2, 6]
> toList (mapWithIndex (i x => i + x) (fromList ([] : List Int)))
[]
```

## `Mappable Array`

```
impl Mappable Array
```

## `Foldable Array`

```
impl Foldable Array
```

## `Semigroup (Array a)`

```
impl Semigroup (Array a)
```

## `Monoid (Array a)`

```
impl Monoid (Array a)
```

`Monoid.empty` for `Array` is the empty array.  `empty` is nullary, so it
dispatches on its annotated *result* type (Phase 103):


*(doctest — run by `medaka test`)*

```medaka
> length (empty : Array Int)
0
```

## `Debug (Array a)`

```
impl Debug (Array a) requires Debug a
```

Bracketed, comma-separated rendering matching the interpreter's printer
(`[|1, 2, 3|]`), so `debug` agrees with `println` on arrays.  Lives in
`core.mdk` (not `array.mdk`) so array literals render without an explicit
`import array`.


*(doctest — run by `medaka test`)*

```medaka
> debug [|1, 2, 3|] == "[|1, 2, 3|]"
True
```

## `Eq (Array a)`

```
impl Eq (Array a) requires Eq a
```

Lives in `core.mdk` (not `array.mdk`) alongside `Debug`/`Index` so
`deriving (Eq)` over a field of array type builds without an `import array`.

## `Ord (Array a)`

```
impl Ord (Array a) requires Ord a
```

Lexicographic, exactly like `Ord (List a)` — `Array` is `List`'s
random-access peer, so `compare` on two arrays agrees element-for-element
with `compare` on their `toList`s, and a prefix sorts before its extensions
(sheet row A-5).  Lives here rather than in `array.mdk` for the same reason
`Eq (Array a)` does: `deriving (Ord)` over a field of array type must build
without an `import array`.
| Lexicographic, exactly like `Ord (List a)` — `Array` is `List`'s
random-access peer, so `compare` on two arrays agrees element-for-element
with `compare` on their element lists, and a prefix sorts before its
extensions (sheet row A-5).  Lives here rather than in `array.mdk` for the
same reason `Eq (Array a)` does: `deriving (Ord)` over a field of array
type must build without an `import array`.

⚠️ The body delegates to `Ord (List a)` rather than walking the arrays
directly on purpose.  A hand-written walk needs an `Ord a`-constrained
top-level helper, and calling one of those from an `impl Ord …` body IN
THIS MODULE panics at run time with `unbound identifier: $dict_max_0` (the
same shape compiles and runs correctly in any other module, and `Eq`- and
`Hashable`-constrained helpers are fine from here).  Filed in the sprint
report; delegation sidesteps it and makes the "agrees with `Ord (List a)`"
law true by construction.

## `Display (Array a)`

```
impl Display (Array a) requires Display a
```

Renders `[|1, 2, 3|]`, matching `debug` but with unquoted elements (the
Display convention).  In `core.mdk` alongside `Debug (Array a)` so array
literals interpolate without an explicit `import array`.


*(doctest — run by `medaka test`)*

```medaka
> display [|1, 2, 3|] == "[|1, 2, 3|]"
True
```

## `Hashable (Array a)`

```
impl Hashable (Array a) requires Hashable a
```

The same `acc * 33 + hash x` fold `Hashable (List a)` uses, so an array
and the list of the same elements hash EQUALLY — the peer relationship
sheet row A-5 ratifies.  Agrees with `Eq (Array a)` by construction: equal
arrays have equal elements in equal order, so they fold to the same seed.

## `Index (Array a) Int a`

```
impl Index (Array a) Int a
```

`index arr i` reads `arr`'s element at `i` (`arr[i]` sugar dispatches
here).  O(1).  Raises the coded `indexError` (E-INDEX-OOB) when `i` is
out of range -- use `get` for a safe `Option`-returning read instead.

## `IndexMut (Array a) Int a`

```
impl IndexMut (Array a) Int a
```

`setIndex arr i v` writes `v` at `arr`'s index `i`, in place, and
returns `arr`.  O(1).  Raises the coded `indexError` (E-INDEX-OOB) when
`i` is out of range.

## `Slice (Array a)`

```
impl Slice (Array a)
```

`slice arr lo hi` copies `arr`'s elements over `[lo, hi)` into a fresh
`Array`.  O(hi - lo).  Raises the coded `sliceError` (E-SLICE-OOB) when the
range runs outside `arr` -- unlike stdlib `Array.sliceClamped`, which clamps.


*(doctest — run by `medaka test`)*

```medaka
> slice [|10, 20, 30, 40, 50|] 1 3
[|20, 30|]
```

