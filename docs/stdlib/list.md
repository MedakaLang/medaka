# list

list.mdk — operations on List a
See STDLIB.md for the full implementation plan.

## `Filterable`

```
Filterable : re-export of core.Filterable
```

Re-export the Filterable container ops so they're discoverable as
`list.filter` / `list.filterMap`.

## `filter`

```
filter : (a -> Bool) -> b a -> b a
```

Re-export the Filterable container ops so they're discoverable as
`list.filter` / `list.filterMap`.

## `filterMap`

```
filterMap : (a -> Option b) -> c a -> c b
```

Re-export the Filterable container ops so they're discoverable as
`list.filter` / `list.filterMap`.

## `singleton`

```
singleton : a -> List a
```

## `range`

```
range : Int -> Int -> List Int
```

The half-open integer interval `[lo, hi)` — `lo` up to but excluding `hi`.
Empty when `lo >= hi`.


*(doctest — run by `medaka test`)*

```medaka
> range 2 5
[2, 3, 4]
> range 5 5
[]
> range 5 2
[]
> range 0 1
[0]
```

## `rangeStep`

```
rangeStep : Int -> Int -> Int -> List Int
```

`rangeStep lo hi step` — arithmetic sequence from `lo`, stepping by `step`,
stopping before `hi`.  Empty when `step` points away from `hi` (or is `0`).


*(doctest — run by `medaka test`)*

```medaka
> rangeStep 0 10 3
[0, 3, 6, 9]
> rangeStep 5 0 (-2)
[5, 3, 1]
```

## `replicate`

```
replicate : Int -> a -> List a
```

A list of `n` copies of `x` (empty when `n <= 0`).

Built by doubling (`replicateDbl`) rather than one recursive call per
copy, so the interpreted call depth is `O(log n)` instead of `O(n)` —
the same shape `String.repeat` had before #1728.


*(doctest — run by `medaka test`)*

```medaka
> replicate 3 0
[0, 0, 0]
```

*(doctest — run by `medaka test`)*

```medaka
> replicate 0 0
[]
```

*(doctest — run by `medaka test`)*

```medaka
> take 3 (replicate 30000 1)
[1, 1, 1]
```

## `iterate`

```
iterate : Int -> (a -> a) -> a -> List a
```

`[x, f x, f (f x), …]` of length `n`.  Empty when `n <= 0`.


*(doctest — run by `medaka test`)*

```medaka
> iterate 4 (n => n * 2) 1
[1, 2, 4, 8]
> iterate 0 (n => n * 2) 1
[]
> iterate 1 (n => n * 2) 1
[1]
```

## `unfold`

```
unfold : (a -> Option (b, a)) -> a -> List b
```

Build a list from a seed: `gen` returns `Some (element, nextSeed)` to emit
an element and continue, or `None` to stop.


*(doctest — run by `medaka test`)*

```medaka
> unfold (n => if n > 5 then None else Some (n, n + 1)) 1
[1, 2, 3, 4, 5]
> unfold (n => if n > 0 then None else Some (n, n + 1)) 1
[]
> unfold (n => if n > 0 then None else Some (n, n + 1)) 0
[0]
```

## `reverse`

```
reverse : List a -> List a
```

The list in reverse order.  Tail-recursive accumulator — safe on long
lists where right-leaning recursion would overflow the stack.


*(doctest — run by `medaka test`)*

```medaka
> reverse [1, 2, 3]
[3, 2, 1]
```

## `intersperse`

```
intersperse : a -> List a -> List a
```

Insert `sep` between every pair of adjacent elements.


*(doctest — run by `medaka test`)*

```medaka
> intersperse 0 [1, 2, 3]
[1, 0, 2, 0, 3]
```

## `intercalate`

```
intercalate : List a -> List (List a) -> List a
```

Concatenate the inner lists with `sep` between them — `intersperse` then
flatten.


*(doctest — run by `medaka test`)*

```medaka
> intercalate [0] [[1], [2, 3], [4]]
[1, 0, 2, 3, 0, 4]
```

## `transpose`

```
transpose : List (List a) -> List (List a)
```

Turn rows into columns.  Ragged rows are allowed: shorter rows simply
contribute nothing to the later columns.


*(doctest — run by `medaka test`)*

```medaka
> transpose [[1, 2, 3], [4, 5, 6]]
[[1, 4], [2, 5], [3, 6]]
> transpose [[1, 2], [3], [4, 5, 6]]
[[1, 3, 4], [2, 5], [6]]
```

## `subsequences`

```
subsequences : List a -> List (List a)
```

Every subsequence (subset preserving order), `2^n` of them.


*(doctest — run by `medaka test`)*

```medaka
> subsequences [1, 2, 3]
[[], [1], [2], [1, 2], [3], [1, 3], [2, 3], [1, 2, 3]]
```

## `permutations`

```
permutations : List a -> List (List a)
```

Every ordering of the list, `n!` of them (lexicographic by original
position).


*(doctest — run by `medaka test`)*

```medaka
> permutations [1, 2, 3]
[[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]]
```

## `scanLeft`

```
scanLeft : (a -> b -> a) -> a -> List b -> List a
```

Like `fold`, but keeping every intermediate accumulator (so the result is
one longer than the input).


*(doctest — run by `medaka test`)*

```medaka
> scanLeft (acc x => acc + x) 0 [1, 2, 3]
[0, 1, 3, 6]
```

## `scanRight`

```
scanRight : (a -> b -> b) -> b -> List a -> List b
```

Right-associated `scanLeft`: every intermediate of a right fold.


*(doctest — run by `medaka test`)*

```medaka
> scanRight (x acc => x + acc) 0 [1, 2, 3]
[6, 5, 3, 0]
```

## `findIndex`

```
findIndex : (a -> Bool) -> List a -> Option Int
```

Index of the first element satisfying the predicate, or `None`.


*(doctest — run by `medaka test`)*

```medaka
> findIndex (x => x > 2) [1, 2, 3, 4]
Some 2
```

## `findIndices`

```
findIndices : (a -> Bool) -> List a -> List Int
```

Indices of every element satisfying the predicate.


*(doctest — run by `medaka test`)*

```medaka
> findIndices (x => x > 2) [1, 3, 2, 4]
[1, 3]
```

## `elemIndex`

```
elemIndex : a -> List a -> Option Int
```

Index of the first occurrence of `x` (by `Eq`), or `None`.


*(doctest — run by `medaka test`)*

```medaka
> elemIndex 3 [1, 2, 3, 2]
Some 2
```

## `elemIndices`

```
elemIndices : a -> List a -> List Int
```

Indices of every occurrence of `x` (by `Eq`).


*(doctest — run by `medaka test`)*

```medaka
> elemIndices 2 [1, 2, 3, 2]
[1, 3]
> elemIndices 9 [1, 2, 3]
[]
```

## `lookup`

```
lookup : a -> List (a, b) -> Option b
```

Look `key` up in an association list, returning the first match.
`O(n)` — for a large or long-lived table reach for `map.Map` (`O(log n)`)
or `hash_map.HashMap` instead.


*(doctest — run by `medaka test`)*

```medaka
> lookup 2 [(1, "a"), (2, "b")]
Some "b"
> lookup 9 [(1, "a"), (2, "b")]
None
```

## `findMap`

```
findMap : (a -> Option b) -> List a -> Option b
```

The first non-`None` result of `f` — `find` and `map` in a single pass,
without rebuilding the list.  Short-circuits on the first hit.


*(doctest — run by `medaka test`)*

```medaka
> findMap (x => if x > 2 then Some (x * 10) else None) [1, 2, 3, 4]
Some 30
> findMap (x => if x > 9 then Some x else None) [1, 2, 3]
None
```

## `reduce`

```
reduce : (a -> a -> a) -> List a -> Option a
```

Left-fold using the first element as the seed — `None` on an empty list.
Named `reduce` rather than `foldl1`: it needs no seed, so it reads as
"reduce the list to one value".


*(doctest — run by `medaka test`)*

```medaka
> reduce (x y => x + y) [1, 2, 3, 4]
Some 10
> reduce (x y => if x > y then x else y) [3, 1, 2]
Some 3
> reduce (x y => x + y) ([] : List Int)
None
```

## `maximumBy`

```
maximumBy : (a -> a -> Ordering) -> List a -> Option a
```

Largest element by a custom comparator, or `None` when empty.  Ties keep
the *first* of the equal elements.  `maximum` (core) is the `Ord` case.


*(doctest — run by `medaka test`)*

```medaka
> maximumBy (x y => compare (x % 10) (y % 10)) [23, 47, 15]
Some 47
> maximumBy compare ([] : List Int)
None
```

## `minimumBy`

```
minimumBy : (a -> a -> Ordering) -> List a -> Option a
```

Smallest element by a custom comparator, or `None` when empty.  Ties keep
the *first* of the equal elements.  `minimum` (core) is the `Ord` case.


*(doctest — run by `medaka test`)*

```medaka
> minimumBy (x y => compare (x % 10) (y % 10)) [23, 47, 15]
Some 23
> minimumBy compare ([] : List Int)
None
```

## `mapWithIndex`

```
mapWithIndex : (Int -> a -> b) -> List a -> List b
```

`map`, but `f` also receives each element's 0-based index.


*(doctest — run by `medaka test`)*

```medaka
> mapWithIndex (i x => i * x) [1, 2, 3]
[0, 2, 6]
> mapWithIndex (i x => i + x) [10, 20]
[10, 21]
```

## `indexed`

```
indexed : List a -> List (Int, a)
```

Pair every element with its 0-based index.


*(doctest — run by `medaka test`)*

```medaka
> indexed ["a", "b", "c"]
[(0, "a"), (1, "b"), (2, "c")]
```

## `mapAccumL`

```
mapAccumL : (a -> b -> (a, c)) -> a -> List b -> (a, List c)
```

Left-to-right `map` threading an accumulator: `f` sees the running state
and each element, and returns the new state plus the mapped element.
Returns the final state and the mapped list.


*(doctest — run by `medaka test`)*

```medaka
> mapAccumL (s x => (s + x, s)) 0 [1, 2, 3]
(6, [0, 1, 3])
```

## `mapAccumR`

```
mapAccumR : (a -> b -> (a, c)) -> a -> List b -> (a, List c)
```

Like `mapAccumL`, but threads the accumulator right-to-left.  The output
list stays in the input's order.


*(doctest — run by `medaka test`)*

```medaka
> mapAccumR (s x => (s + x, s)) 0 [1, 2, 3]
(6, [5, 3, 0])
```

## `insertAt`

```
insertAt : Int -> a -> List a -> List a
```

Insert `x` so that it lands at index `i`, shifting the rest right.
`i <= 0` prepends; `i >= length` appends.


*(doctest — run by `medaka test`)*

```medaka
> insertAt 1 9 [1, 2, 3]
[1, 9, 2, 3]
> insertAt 0 9 [1, 2]
[9, 1, 2]
> insertAt 7 9 [1, 2]
[1, 2, 9]
```

## `updateAt`

```
updateAt : Int -> a -> List a -> List a
```

Replace the element at index `i` with `x`.  Out-of-range leaves the list
unchanged.


*(doctest — run by `medaka test`)*

```medaka
> updateAt 1 9 [1, 2, 3]
[1, 9, 3]
> updateAt 7 9 [1, 2]
[1, 2]
```

## `removeAt`

```
removeAt : Int -> List a -> List a
```

Drop the element at index `i`.  Out-of-range leaves the list unchanged.


*(doctest — run by `medaka test`)*

```medaka
> removeAt 1 [1, 2, 3]
[1, 3]
> removeAt 7 [1, 2]
[1, 2]
```

## `take`

```
take : Int -> List a -> List a
```

First `n` elements (fewer if the list is shorter).


*(doctest — run by `medaka test`)*

```medaka
> take 2 [1, 2, 3, 4]
[1, 2]
```

## `drop`

```
drop : Int -> List a -> List a
```

Everything after the first `n` elements.


*(doctest — run by `medaka test`)*

```medaka
> drop 2 [1, 2, 3, 4]
[3, 4]
```

## `takeWhile`

```
takeWhile : (a -> Bool) -> List a -> List a
```

Longest prefix whose elements all satisfy the predicate.


*(doctest — run by `medaka test`)*

```medaka
> takeWhile (x => x < 3) [1, 2, 3, 1]
[1, 2]
> takeWhile (x => x < 9) [1, 2, 3]
[1, 2, 3]
> takeWhile (x => x < 0) [1, 2, 3]
[]
> takeWhile (x => x < 3) ([] : List Int)
[]
```

## `dropWhile`

```
dropWhile : (a -> Bool) -> List a -> List a
```

Drop the longest prefix whose elements satisfy the predicate.


*(doctest — run by `medaka test`)*

```medaka
> dropWhile (x => x < 3) [1, 2, 3, 1]
[3, 1]
> dropWhile (x => x < 9) [1, 2, 3]
[]
> dropWhile (x => x < 0) [1, 2, 3]
[1, 2, 3]
> dropWhile (x => x < 3) ([] : List Int)
[]
```

## `span`

```
span : (a -> Bool) -> List a -> (List a, List a)
```

`(takeWhile p xs, dropWhile p xs)`, in a single pass.


*(doctest — run by `medaka test`)*

```medaka
> span (x => x < 3) [1, 2, 3, 1]
([1, 2], [3, 1])
> span (x => x < 9) [1, 2, 3]
([1, 2, 3], [])
> span (x => x < 0) [1, 2, 3]
([], [1, 2, 3])
> span (x => x < 3) ([] : List Int)
([], [])
```

## `break`

```
break : (a -> Bool) -> List a -> (List a, List a)
```

`span` with the predicate negated: split at the first element that *does*
satisfy `p`.


*(doctest — run by `medaka test`)*

```medaka
> break (x => x > 2) [1, 2, 3, 1]
([1, 2], [3, 1])
> break (x => x > 9) [1, 2, 3]
([1, 2, 3], [])
> break (x => x > 0) [1, 2, 3]
([], [1, 2, 3])
> break (x => x > 2) ([] : List Int)
([], [])
```

## `splitAt`

```
splitAt : Int -> List a -> (List a, List a)
```

`(take n xs, drop n xs)`, in a single pass.


*(doctest — run by `medaka test`)*

```medaka
> splitAt 2 [1, 2, 3, 4]
([1, 2], [3, 4])
```

## `sliceClamped`

```
sliceClamped : Int -> Int -> List a -> List a
```

`sliceClamped lo hi xs` — the elements at indices `[lo, hi)`.  Clamps (never
panics); use `xs.[lo..hi]` (the `Slice` interface) for the panicking form.


*(doctest — run by `medaka test`)*

```medaka
> sliceClamped 1 3 [10, 20, 30, 40]
[20, 30]
```

## `chunks`

```
chunks : Int -> List a -> List (List a)
```

Split into consecutive groups of `n` (the last group may be shorter).
Empty when `n <= 0`.


*(doctest — run by `medaka test`)*

```medaka
> chunks 2 [1, 2, 3, 4, 5]
[[1, 2], [3, 4], [5]]
```

## `dropWhileEnd`

```
dropWhileEnd : (a -> Bool) -> List a -> List a
```

Drop the longest *suffix* whose elements all satisfy the predicate — the
mirror of `dropWhile`.  Trailing-whitespace trimming is the usual reason.


*(doctest — run by `medaka test`)*

```medaka
> dropWhileEnd (x => x == 0) [1, 2, 0, 0]
[1, 2]
> dropWhileEnd (x => x == 0) [0, 1, 0]
[0, 1]
> dropWhileEnd (x => x == 0) [0, 0]
[]
```

## `takeWhileEnd`

```
takeWhileEnd : (a -> Bool) -> List a -> List a
```

The longest *suffix* whose elements all satisfy the predicate — the mirror
of `takeWhile`.


*(doctest — run by `medaka test`)*

```medaka
> takeWhileEnd (x => x > 1) [1, 2, 3]
[2, 3]
> takeWhileEnd (x => x > 9) [1, 2, 3]
[]
> takeWhileEnd (x => x > 0) [1, 2]
[1, 2]
```

## `split`

```
split : List a -> List a -> List (List a)
```

Split on every occurrence of the separator *sublist*, dropping the
separators.  The list analogue of `string.split` — same needle-first
argument order, and an empty separator likewise yields `[xs]`.
(`splitAt` is the unrelated positional one, which takes an `Int`.)


*(doctest — run by `medaka test`)*

```medaka
> split [0] [1, 0, 2, 0, 3]
[[1], [2], [3]]
> split [0, 0] [1, 0, 0, 2]
[[1], [2]]
> split [9] [1, 2]
[[1, 2]]
> split [0] [0, 1]
[[], [1]]
```

## `startsWith`

```
startsWith : List a -> List a -> Bool
```

True when `prefix` is a leading sublist of `xs`.  Every list starts with
the empty list.


*(doctest — run by `medaka test`)*

```medaka
> startsWith [1, 2] [1, 2, 3]
True
> startsWith [2, 3] [1, 2, 3]
False
> startsWith ([] : List Int) [1]
True
```

## `endsWith`

```
endsWith : List a -> List a -> Bool
```

True when `suffix` is a trailing sublist of `xs`.


*(doctest — run by `medaka test`)*

```medaka
> endsWith [2, 3] [1, 2, 3]
True
> endsWith [1, 2] [1, 2, 3]
False
```

## `containsSub`

```
containsSub : List a -> List a -> Bool
```

True when `sub` occurs as a contiguous run anywhere in `xs`.  `O(n*m)`
naive scan — fine for short needles; for text prefer `string.contains`,
which is host-backed.


*(doctest — run by `medaka test`)*

```medaka
> containsSub [2, 3] [1, 2, 3, 4]
True
> containsSub [2, 4] [1, 2, 3, 4]
False
> containsSub ([] : List Int) [1]
True
```

## `sortBy`

```
sortBy : (a -> a -> Ordering) -> List a -> List a
```

Stable sort with a custom comparator (bottom-up is unnecessary; a plain
recursive merge sort is stable and `O(n log n)`).


*(doctest — run by `medaka test`)*

```medaka
> sortBy (x y => compare y x) [3, 1, 2]
[3, 2, 1]
```

## `sort`

```
sort : List a -> List a
```

Ascending stable sort by the `Ord` instance.


*(doctest — run by `medaka test`)*

```medaka
> sort [3, 1, 2, 1]
[1, 1, 2, 3]
```

## `sortOn`

```
sortOn : (a -> b) -> List a -> List a
```

Sort by a derived key, computing the key once per element via a
decorate–sort–undecorate pass (the key may be expensive, so this avoids
recomputing it inside every comparison).


*(doctest — run by `medaka test`)*

```medaka
> sortOn (x => 0 - x) [1, 3, 2]
[3, 2, 1]
```

## `nubBy`

```
nubBy : (a -> a -> Bool) -> List a -> List a
```

Drop duplicates by a custom equality, keeping the first occurrence.
`O(n²)` baseline.


*(doctest — run by `medaka test`)*

```medaka
> nubBy (x y => x == y) [1, 2, 1, 3, 2]
[1, 2, 3]
```

## `nub`

```
nub : List a -> List a
```

Drop duplicates by `Eq`, keeping the first occurrence.


*(doctest — run by `medaka test`)*

```medaka
> nub [1, 2, 1, 3, 2, 1]
[1, 2, 3]
```

## `deleteBy`

```
deleteBy : (a -> a -> Bool) -> a -> List a -> List a
```

Remove the *first* element matching a custom equality; unchanged when
nothing matches.


*(doctest — run by `medaka test`)*

```medaka
> deleteBy (x y => x == y) 2 [1, 2, 3, 2]
[1, 3, 2]
```

## `delete`

```
delete : a -> List a -> List a
```

Remove the *first* occurrence of `x` (by `Eq`); unchanged when absent.
Only the first — `filter (/= x) xs` removes every occurrence.


*(doctest — run by `medaka test`)*

```medaka
> delete 2 [1, 2, 3, 2]
[1, 3, 2]
> delete 9 [1, 2]
[1, 2]
```

## `groupBy`

```
groupBy : (a -> a -> Bool) -> List a -> List (List a)
```

Group maximal runs of adjacent elements that satisfy the equivalence.


*(doctest — run by `medaka test`)*

```medaka
> groupBy (x y => x == y) [1, 1, 2, 3, 3, 3]
[[1, 1], [2], [3, 3, 3]]
```

## `group`

```
group : List a -> List (List a)
```

Group maximal runs of adjacent equal elements (by `Eq`).


*(doctest — run by `medaka test`)*

```medaka
> group [1, 1, 2, 3, 3]
[[1, 1], [2], [3, 3]]
```

## `partition`

```
partition : (a -> Bool) -> List a -> (List a, List a)
```

`(filter p xs, filter (not . p) xs)`, in a single pass.


*(doctest — run by `medaka test`)*

```medaka
> partition (x => x > 2) [1, 2, 3, 4]
([3, 4], [1, 2])
```

## `somes`

```
somes : List (Option a) -> List a
```

Keep the `Some`s, drop the `None`s.


*(doctest — run by `medaka test`)*

```medaka
> somes [Some 1, None, Some 3]
[1, 3]
> somes ([] : List (Option Int))
[]
```

## `oks`

```
oks : List (Result a b) -> List b
```

Keep the `Ok` values, drop the `Err`s.


*(doctest — run by `medaka test`)*

```medaka
> oks [Ok 1, Err "boom", Ok 3]
[1, 3]
```

## `errs`

```
errs : List (Result a b) -> List a
```

Keep the `Err` values, drop the `Ok`s.


*(doctest — run by `medaka test`)*

```medaka
> errs [Ok 1, Err "boom", Ok 3]
["boom"]
```

## `partitionResults`

```
partitionResults : List (Result a b) -> (List a, List b)
```

Split into `(errs, oks)` in a single pass.


*(doctest — run by `medaka test`)*

```medaka
> partitionResults [Ok 1, Err "boom", Ok 3]
(["boom"], [1, 3])
```

## `tally`

```
tally : List a -> List (a, Int)
```

Count occurrences of each distinct element (by `Eq`), in first-seen order.


*(doctest — run by `medaka test`)*

```medaka
> tally [1, 2, 1, 3, 1, 2]
[(1, 3), (2, 2), (3, 1)]
```

## `head`

```
head : List a -> Option a
```

## `tail`

```
tail : List a -> Option (List a)
```

## `uncons`

```
uncons : List a -> Option (a, List a)
```

Split off the first element — `head` and `tail` in one match, which is
what you want when destructuring a list you cannot pattern-match on
directly.  `None` exactly when the list is empty.


*(doctest — run by `medaka test`)*

```medaka
> uncons [1, 2, 3]
Some (1, [2, 3])
> uncons [1]
Some (1, [])
> uncons ([] : List Int)
None
```

## `last`

```
last : List a -> Option a
```

## `init`

```
init : List a -> Option (List a)
```

## `get`

```
get : Int -> List a -> Option a
```

## `zip`

```
zip : List a -> List b -> List (a, b)
```

Pair up elements of two lists positionally.  The result is as long as
the *shorter* input; trailing elements of the longer one are dropped.


*(doctest — run by `medaka test`)*

```medaka
> zip [1, 2, 3] [10, 20]
[(1, 10), (2, 20)]
> zip [] [1, 2]
[]
```

## `zip3`

```
zip3 : List a -> List b -> List c -> List (a, b, c)
```

Like `zip`, but for three lists, producing triples.  Stops at the
shortest input.


*(doctest — run by `medaka test`)*

```medaka
> zip3 [1, 2] [3, 4] [5, 6]
[(1, 3, 5), (2, 4, 6)]
> zip3 [1, 2, 3] [4, 5] [6]
[(1, 4, 6)]
```

## `zipWith`

```
zipWith : (a -> b -> c) -> List a -> List b -> List c
```

Combine two lists element-wise with `f`, stopping at the shorter.
`zip` is the special case `zipWith (x y => (x, y))`.


*(doctest — run by `medaka test`)*

```medaka
> zipWith (x y => x + y) [1, 2, 3] [10, 20, 30]
[11, 22, 33]
> zipWith (x y => x * y) [1, 2, 3, 4] [10, 20]
[10, 40]
```

## `zip4`

```
zip4 : List a -> List b -> List c -> List d -> List (a, b, c, d)
```

Like `zip3`, but for four lists, producing 4-tuples.  Stops at the
shortest input.


*(doctest — run by `medaka test`)*

```medaka
> zip4 [1, 2] [3, 4] [5, 6] [7, 8]
[(1, 3, 5, 7), (2, 4, 6, 8)]
> zip4 [1, 2] [3] [5, 6] [7, 8]
[(1, 3, 5, 7)]
```

## `zipWith3`

```
zipWith3 : (a -> b -> c -> d) -> List a -> List b -> List c -> List d
```

Like `zipWith`, but for three lists.  `zip3` is the special case
`zipWith3 (x y z => (x, y, z))`.


*(doctest — run by `medaka test`)*

```medaka
> zipWith3 (x y z => x + y + z) [1, 2] [10, 20] [100, 200]
[111, 222]
> zipWith3 (x y z => x + y + z) [1, 2, 3] [10, 20] [100]
[111]
```

## `unzip`

```
unzip : List (a, b) -> (List a, List b)
```

Split a list of pairs into a pair of lists — the inverse of `zip`.


*(doctest — run by `medaka test`)*

```medaka
> unzip [(1, 2), (3, 4)]
([1, 3], [2, 4])
> unzip []
([], [])
```

## `unzip3`

```
unzip3 : List (a, b, c) -> (List a, List b, List c)
```

Split a list of triples into three lists — the inverse of `zip3`.


*(doctest — run by `medaka test`)*

```medaka
> unzip3 [(1, 2, 3), (4, 5, 6)]
([1, 4], [2, 5], [3, 6])
> unzip3 ([] : List (Int, Int, Int))
([], [], [])
```

## `Eq (List a)`

```
impl Eq (List a) requires Eq a
```

## `Semigroup (List a)`

```
impl Semigroup (List a)
```

## `Monoid (List a)`

```
impl Monoid (List a)
```

## `Ord (List a)`

```
impl Ord (List a) requires Ord a
```

Lexicographic ordering: compare element-wise, and a proper prefix sorts
before any list that extends it (`[1] < [1, 2]`, `[] < [0]`).

## `Debug (List a)`

```
impl Debug (List a) requires Debug a
```

## `Display (List a)`

```
impl Display (List a) requires Display a
```

## `Hashable (List a)`

```
impl Hashable (List a) requires Hashable a
```

## `Mappable List`

```
impl Mappable List
```

## `Applicative List`

```
impl Applicative List
```

## `Thenable List`

```
impl Thenable List
```

## `Alternative List`

```
impl Alternative List
```

## `Index (List a) Int a`

```
impl Index (List a) Int a
```

`index xs i` is `xs`'s element at position `i`.  O(n) — a singly-linked
list has no random access, so this walks `i` cons cells; prefer `Array`/
`MutArray` for index-heavy workloads.  Raises the coded `indexError`
(E-INDEX-OOB) when `i` is out of range.  No `IndexMut` impl: `List` is
immutable / has no in-place element write.

## `Slice (List a)`

```
impl Slice (List a)
```

`slice xs lo hi` is the sublist of `xs` over `[lo, hi)`.  O(hi) -- walks the
cons chain.  Out-of-range bounds are CLAMPED (never panics), matching the
interpreter's list-slice contract.


*(doctest — run by `medaka test`)*

```medaka
> slice [10, 20, 30, 40] 1 3
[20, 30]
```

## `Foldable List`

```
impl Foldable List
```

## `Traversable List`

```
impl Traversable List
```

Each `traverse` impl is a SINGLE clause with an inner `match`, not separate
per-constructor clauses: the multi-clause form of a generic `Thenable m =>`
method whose body has a return-position `pure` loops in eval (dict-passing ×
multi-clause desugar).  Do not split them back out.
lint-disable-next-line rule-match-on-param

## `Filterable List`

```
impl Filterable List
```

`Filterable List`.  Lives in `core` (rather than `list.mdk`) so the
`filter` name is in scope for the rest of the stdlib; `list.mdk`
re-exports it for discoverability.


*(doctest — run by `medaka test`)*

```medaka
> filter (x => x > 2) [1, 2, 3, 4]
[3, 4]
```

## `Arbitrary (List a)`

```
impl Arbitrary (List a) requires Arbitrary a
```

The instance form of `arbitraryList` (sheet row H-7).  `arbitraryList` stays
as the explicit-generator escape hatch — a generator that is not the type's
`Arbitrary` instance, or a longer list, still needs it.  This impl is what
lets a HAND-WRITTEN generator call `arbitrary` at `List a` and compose.
⚠️ It is NOT what makes `prop … (xs : List Int)` work: `medaka test`'s
runner generates from the declared TYPE, not from `Arbitrary` (see the
note above the laws below).  `maxLen` is 10, matching `arbitraryString`.

