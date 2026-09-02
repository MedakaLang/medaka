# list

Operations on `List a`.

A list is an immutable singly linked sequence. Every operation here returns
a new list and leaves its argument unchanged. Functions that could fail on
an empty list or an out-of-range index return an `Option` instead of
panicking.

The generic container operations (`map`, `filter`, `fold`, `length`, `elem`,
`sum`, `maximum`, `any`, `all`, and the rest of the `Foldable` and
`Traversable` interfaces) are defined in the prelude and work on lists
without an import. This module holds what is specific to lists.

## Re-exports

### `Filterable`

```
Filterable : re-export of core.Filterable
```

Re-exported from the prelude so that `list.filter` and `list.filterMap`
resolve when the module is imported qualified.

### `filter`

```
filter : (a -> Bool) -> b a -> b a
```

Re-exported from the prelude so that `list.filter` and `list.filterMap`
resolve when the module is imported qualified.

### `filterMap`

```
filterMap : (a -> Option b) -> c a -> c b
```

Re-exported from the prelude so that `list.filter` and `list.filterMap`
resolve when the module is imported qualified.

## Construction

### `singleton`

```
singleton : a -> List a
```

A list holding one element.

```medaka
> singleton 5
[5]
```

### `range`

```
range : Int -> Int -> List Int
```

The integers from `lo` up to, but not including, `hi`.

Empty when `lo >= hi`. `[lo..hi]` is the literal form.

```medaka
> range 2 5
[2, 3, 4]
```

### `rangeStep`

```
rangeStep : Int -> Int -> Int -> List Int
```

The integers from `lo` towards `hi` in steps of `step`, stopping before
`hi`.

A negative `step` counts down. Empty when `step` is `0` or points away
from `hi`.

```medaka
> rangeStep 0 10 3
[0, 3, 6, 9]
> rangeStep 5 0 (-2)
[5, 3, 1]
```

### `replicate`

```
replicate : Int -> a -> List a
```

A list of `n` copies of `x`.

Empty when `n <= 0`. Safe for large `n`: the call depth grows with
`log n`, not `n`.

```medaka
> replicate 3 0
[0, 0, 0]
```

### `iterate`

```
iterate : Int -> (a -> <e> a) -> a -> <e> List a
```

The first `n` results of applying `f` repeatedly, starting from `x`:
`[x, f x, f (f x), ...]`.

Empty when `n <= 0`.

```medaka
> iterate 4 (n => n * 2) 1
[1, 2, 4, 8]
```

### `unfold`

```
unfold : (b -> <e> Option (a, b)) -> b -> <e> List a
```

Builds a list from a seed.

`gen` is called with the current seed. It returns `Some (element, next)` to
emit `element` and continue from `next`, or `None` to stop.

```medaka
> unfold (n => if n > 5 then None else Some (n, n + 1)) 1
[1, 2, 3, 4, 5]
```

## Accessing elements

### `head`

```
head : List a -> Option a
```

The first element, or `None` when the list is empty.

```medaka
> head [1, 2, 3]
Some 1
> head ([] : List Int)
None
```

### `tail`

```
tail : List a -> Option (List a)
```

Everything after the first element, or `None` when the list is empty.

```medaka
> tail [1, 2, 3]
Some [2, 3]
> tail [1]
Some []
```

### `uncons`

```
uncons : List a -> Option (a, List a)
```

The first element and the rest, or `None` when the list is empty.

```medaka
> uncons [1, 2, 3]
Some (1, [2, 3])
```

### `last`

```
last : List a -> Option a
```

The last element, or `None` when the list is empty.

```medaka
> last [1, 2, 3]
Some 3
```

### `init`

```
init : List a -> Option (List a)
```

Everything except the last element, or `None` when the list is empty.

```medaka
> init [1, 2, 3]
Some [1, 2]
> init [1]
Some []
```

### `get`

```
get : Int -> List a -> Option a
```

The element at index `i`, counting from `0`, or `None` when `i` is out
of range.

Walks the list from the front, so the cost grows with `i`.

```medaka
> get 1 ["a", "b", "c"]
Some "b"
> get 5 ["a", "b", "c"]
None
```

## Transformation

### `reverse`

```
reverse : List a -> List a
```

The list in reverse order.

Safe on long lists.

```medaka
> reverse [1, 2, 3]
[3, 2, 1]
```

### `intersperse`

```
intersperse : a -> List a -> List a
```

The list with `sep` placed between each pair of adjacent elements.

```medaka
> intersperse 0 [1, 2, 3]
[1, 0, 2, 0, 3]
```

### `intercalate`

```
intercalate : List a -> List (List a) -> List a
```

The inner lists joined into one, with `sep` between each pair.

```medaka
> intercalate [0] [[1], [2, 3], [4]]
[1, 0, 2, 3, 0, 4]
```

### `transpose`

```
transpose : List (List a) -> List (List a)
```

The rows of a list of lists turned into columns.

Rows may have different lengths. A short row contributes nothing to the
columns beyond its end.

```medaka
> transpose [[1, 2, 3], [4, 5, 6]]
[[1, 4], [2, 5], [3, 6]]
> transpose [[1, 2], [3], [4, 5, 6]]
[[1, 3, 4], [2, 5], [6]]
```

### `subsequences`

```
subsequences : List a -> List (List a)
```

Every subsequence of the list: each subset of its elements, in their
original order.

A list of `n` elements has `2^n` subsequences.

```medaka
> subsequences [1, 2, 3]
[[], [1], [2], [1, 2], [3], [1, 3], [2, 3], [1, 2, 3]]
```

### `permutations`

```
permutations : List a -> List (List a)
```

Every ordering of the list's elements.

A list of `n` elements has `n!` permutations. They are produced in
lexicographic order of the original positions.

```medaka
> permutations [1, 2, 3]
[[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]]
```

## Folds and scans

### `scanLeft`

```
scanLeft : (b -> a -> <e> b) -> b -> List a -> <e> List b
```

Every intermediate value of a left fold, starting with the seed.

The result is one element longer than the input.

```medaka
> scanLeft (acc x => acc + x) 0 [1, 2, 3]
[0, 1, 3, 6]
```

### `scanRight`

```
scanRight : (a -> b -> <e> b) -> b -> List a -> <e> List b
```

Every intermediate value of a right fold, ending with the seed.

```medaka
> scanRight (x acc => x + acc) 0 [1, 2, 3]
[6, 5, 3, 0]
```

### `reduce`

```
reduce : (a -> a -> <e> a) -> List a -> <e> Option a
```

A left fold that uses the first element as the seed.

`None` when the list is empty. `fold` is the form that takes a seed.

```medaka
> reduce (x y => x + y) [1, 2, 3, 4]
Some 10
```

### `maximumBy`

```
maximumBy : (a -> a -> <e> Ordering) -> List a -> <e> Option a
```

The largest element according to `cmp`, or `None` when the list is
empty.

When several elements compare equal, the first one wins. `maximum` is the
form that uses the `Ord` instance.

```medaka
> maximumBy (x y => compare (x % 10) (y % 10)) [23, 47, 15]
Some 47
```

### `minimumBy`

```
minimumBy : (a -> a -> <e> Ordering) -> List a -> <e> Option a
```

The smallest element according to `cmp`, or `None` when the list is
empty.

When several elements compare equal, the first one wins. `minimum` is the
form that uses the `Ord` instance.

```medaka
> minimumBy (x y => compare (x % 10) (y % 10)) [23, 47, 15]
Some 23
```

## Search

### `findIndex`

```
findIndex : (a -> <e> Bool) -> List a -> <e> Option Int
```

The index of the first element satisfying `p`, or `None`.

```medaka
> findIndex (x => x > 2) [1, 2, 3, 4]
Some 2
```

### `findIndices`

```
findIndices : (a -> <e> Bool) -> List a -> <e> List Int
```

The indices of every element satisfying `p`.

```medaka
> findIndices (x => x > 2) [1, 3, 2, 4]
[1, 3]
```

### `elemIndex`

```
elemIndex : Eq a => a -> List a -> Option Int
```

The index of the first element equal to `x`, or `None`.

```medaka
> elemIndex 3 [1, 2, 3, 2]
Some 2
```

### `elemIndices`

```
elemIndices : Eq a => a -> List a -> List Int
```

The indices of every element equal to `x`.

```medaka
> elemIndices 2 [1, 2, 3, 2]
[1, 3]
```

### `lookup`

```
lookup : Eq k => k -> List (k, v) -> Option v
```

The value paired with `key` in an association list, or `None`.

The first matching pair wins. Each lookup scans the list, so for a large or
long-lived table use `map.Map` or `hash_map.HashMap`.

```medaka
> lookup 2 [(1, "a"), (2, "b")]
Some "b"
> lookup 9 [(1, "a"), (2, "b")]
None
```

### `findMap`

```
findMap : (a -> <e> Option b) -> List a -> <e> Option b
```

The first `Some` produced by applying `f` to the elements in order, or
`None`.

Stops at the first hit, so `f` is not applied to the remaining elements.

```medaka
> findMap (x => if x > 2 then Some (x * 10) else None) [1, 2, 3, 4]
Some 30
```

## Indexed

### `mapWithIndex`

```
mapWithIndex : (Int -> a -> <e> b) -> List a -> <e> List b
```

Like `map`, with `f` also receiving each element's index, counting
from `0`.

```medaka
> mapWithIndex (i x => i * x) [1, 2, 3]
[0, 2, 6]
```

### `indexed`

```
indexed : List a -> List (Int, a)
```

Each element paired with its index, counting from `0`.

```medaka
> indexed ["a", "b", "c"]
[(0, "a"), (1, "b"), (2, "c")]
```

### `mapAccumL`

```
mapAccumL : (s -> a -> <e> (s, b)) -> s -> List a -> <e> (s, List b)
```

A `map` that threads a state value from left to right.

`f` receives the state and an element, and returns the new state and the
mapped element. The result is the final state and the mapped list.

```medaka
> mapAccumL (s x => (s + x, s)) 0 [1, 2, 3]
(6, [0, 1, 3])
```

### `mapAccumR`

```
mapAccumR : (s -> a -> <e> (s, b)) -> s -> List a -> <e> (s, List b)
```

Like `mapAccumL`, but threads the state from right to left.

The mapped list keeps the input's order.

```medaka
> mapAccumR (s x => (s + x, s)) 0 [1, 2, 3]
(6, [5, 3, 0])
```

## Positional edits

### `insertAt`

```
insertAt : Int -> a -> List a -> List a
```

The list with `x` inserted at index `i`, shifting the following elements
right.

An index at or below `0` prepends; an index at or beyond the length
appends.

```medaka
> insertAt 1 9 [1, 2, 3]
[1, 9, 2, 3]
```

### `updateAt`

```
updateAt : Int -> a -> List a -> List a
```

The list with the element at index `i` replaced by `x`.

Unchanged when `i` is out of range.

```medaka
> updateAt 1 9 [1, 2, 3]
[1, 9, 3]
```

### `removeAt`

```
removeAt : Int -> List a -> List a
```

The list without the element at index `i`.

Unchanged when `i` is out of range.

```medaka
> removeAt 1 [1, 2, 3]
[1, 3]
```

## Sublists

### `take`

```
take : Int -> List a -> List a
```

The first `n` elements, or the whole list when it has fewer.

```medaka
> take 2 [1, 2, 3, 4]
[1, 2]
```

### `drop`

```
drop : Int -> List a -> List a
```

Everything after the first `n` elements.

```medaka
> drop 2 [1, 2, 3, 4]
[3, 4]
```

### `takeWhile`

```
takeWhile : (a -> <e> Bool) -> List a -> <e> List a
```

The longest prefix whose elements all satisfy `p`.

```medaka
> takeWhile (x => x < 3) [1, 2, 3, 1]
[1, 2]
```

### `dropWhile`

```
dropWhile : (a -> <e> Bool) -> List a -> <e> List a
```

The list without its longest prefix of elements satisfying `p`.

```medaka
> dropWhile (x => x < 3) [1, 2, 3, 1]
[3, 1]
```

### `span`

```
span : (a -> <e> Bool) -> List a -> <e> (List a, List a)
```

The longest prefix satisfying `p`, and the rest of the list.

Equivalent to `(takeWhile p xs, dropWhile p xs)` in one pass.

```medaka
> span (x => x < 3) [1, 2, 3, 1]
([1, 2], [3, 1])
```

### `break`

```
break : (a -> <e> Bool) -> List a -> <e> (List a, List a)
```

The prefix before the first element satisfying `p`, and the rest of the
list.

The same as `span` with the predicate negated.

```medaka
> break (x => x > 2) [1, 2, 3, 1]
([1, 2], [3, 1])
```

### `splitAt`

```
splitAt : Int -> List a -> (List a, List a)
```

The first `n` elements, and the rest of the list.

Equivalent to `(take n xs, drop n xs)` in one pass.

```medaka
> splitAt 2 [1, 2, 3, 4]
([1, 2], [3, 4])
```

### `sliceClamped`

```
sliceClamped : Int -> Int -> List a -> List a
```

The elements at indices `[lo, hi)`.

Indices are clamped to the list, so an out-of-range slice is shorter
rather than a panic. `xs.[lo..hi]` is the panicking form.

```medaka
> sliceClamped 1 3 [10, 20, 30, 40]
[20, 30]
```

### `chunks`

```
chunks : Int -> List a -> List (List a)
```

The list split into consecutive groups of `n` elements.

The last group holds whatever remains, so it may be shorter. Empty when
`n <= 0`.

```medaka
> chunks 2 [1, 2, 3, 4, 5]
[[1, 2], [3, 4], [5]]
```

### `dropWhileEnd`

```
dropWhileEnd : (a -> <e> Bool) -> List a -> <e> List a
```

The list without its longest suffix of elements satisfying `p`.

```medaka
> dropWhileEnd (x => x == 0) [1, 2, 0, 0]
[1, 2]
```

### `takeWhileEnd`

```
takeWhileEnd : (a -> <e> Bool) -> List a -> <e> List a
```

The longest suffix whose elements all satisfy `p`.

```medaka
> takeWhileEnd (x => x > 1) [1, 2, 3]
[2, 3]
```

### `split`

```
split : Eq a => List a -> List a -> List (List a)
```

The list split at every occurrence of the separator `sep`, with the
separators removed.

An empty separator yields the whole list as the only piece. This is the
list form of `string.split`; `splitAt` is the positional split.

```medaka
> split [0] [1, 0, 2, 0, 3]
[[1], [2], [3]]
> split [0] [0, 1]
[[], [1]]
```

## Sublist predicates

### `startsWith`

```
startsWith : Eq a => List a -> List a -> Bool
```

Whether the list begins with `prefix`.

Every list begins with the empty list. `elem` is the test for a single
element.

```medaka
> startsWith [1, 2] [1, 2, 3]
True
> startsWith [2, 3] [1, 2, 3]
False
```

### `endsWith`

```
endsWith : Eq a => List a -> List a -> Bool
```

Whether the list ends with `suffix`.

```medaka
> endsWith [2, 3] [1, 2, 3]
True
> endsWith [1, 2] [1, 2, 3]
False
```

### `containsSub`

```
containsSub : Eq a => List a -> List a -> Bool
```

Whether `sub` occurs as a contiguous run anywhere in the list.

The scan costs `O(n * m)`. For text, `string.contains` is faster.

```medaka
> containsSub [2, 3] [1, 2, 3, 4]
True
> containsSub [2, 4] [1, 2, 3, 4]
False
```

## Sorting

### `sortBy`

```
sortBy : (a -> a -> <e> Ordering) -> List a -> <e> List a
```

The list sorted by `cmp`.

The sort is stable: elements that compare equal keep their original
order. It costs `O(n log n)`.

```medaka
> sortBy (x y => compare y x) [3, 1, 2]
[3, 2, 1]
```

### `sort`

```
sort : Ord a => List a -> List a
```

The list sorted in ascending order.

The sort is stable.

```medaka
> sort [3, 1, 2, 1]
[1, 1, 2, 3]
```

### `sortOn`

```
sortOn : Ord b => (a -> <e> b) -> List a -> <e> List a
```

The list sorted in ascending order of `key`.

`key` is computed once per element, so it may be expensive. The sort is
stable.

```medaka
> sortOn (x => 0 - x) [1, 3, 2]
[3, 2, 1]
```

### `nubBy`

```
nubBy : (a -> a -> <e> Bool) -> List a -> <e> List a
```

The list with duplicates removed, where `same` decides which elements
are duplicates.

The first occurrence is kept. Costs `O(n^2)`.

```medaka
> nubBy (x y => x == y) [1, 2, 1, 3, 2]
[1, 2, 3]
```

### `nub`

```
nub : Eq a => List a -> List a
```

The list with duplicate elements removed.

The first occurrence is kept. Costs `O(n^2)`; for large lists, build a
`set.Set` or `hash_set.HashSet` instead.

```medaka
> nub [1, 2, 1, 3, 2, 1]
[1, 2, 3]
```

### `deleteBy`

```
deleteBy : (a -> a -> <e> Bool) -> a -> List a -> <e> List a
```

The list without the first element that `same` matches against `x`.

Unchanged when nothing matches.

```medaka
> deleteBy (x y => x == y) 2 [1, 2, 3, 2]
[1, 3, 2]
```

### `delete`

```
delete : Eq a => a -> List a -> List a
```

The list without the first occurrence of `x`.

Unchanged when `x` is absent. `filter (/= x)` removes every occurrence.

```medaka
> delete 2 [1, 2, 3, 2]
[1, 3, 2]
```

## Grouping

### `groupBy`

```
groupBy : (a -> a -> <e> Bool) -> List a -> <e> List (List a)
```

The list split into runs of adjacent elements that `same` considers
equivalent.

```medaka
> groupBy (x y => x == y) [1, 1, 2, 3, 3, 3]
[[1, 1], [2], [3, 3, 3]]
```

### `group`

```
group : Eq a => List a -> List (List a)
```

The list split into runs of adjacent equal elements.

```medaka
> group [1, 1, 2, 3, 3]
[[1, 1], [2], [3, 3]]
```

### `partition`

```
partition : (a -> <e> Bool) -> List a -> <e> (List a, List a)
```

The elements satisfying `p`, and the elements that do not.

Both parts keep the input's order.

```medaka
> partition (x => x > 2) [1, 2, 3, 4]
([3, 4], [1, 2])
```

### `somes`

```
somes : List (Option a) -> List a
```

The values inside the `Some`s, with the `None`s dropped.

```medaka
> somes [Some 1, None, Some 3]
[1, 3]
```

### `oks`

```
oks : List (Result e a) -> List a
```

The values inside the `Ok`s, with the `Err`s dropped.

```medaka
> oks [Ok 1, Err "boom", Ok 3]
[1, 3]
```

### `errs`

```
errs : List (Result e a) -> List e
```

The values inside the `Err`s, with the `Ok`s dropped.

```medaka
> errs [Ok 1, Err "boom", Ok 3]
["boom"]
```

### `partitionResults`

```
partitionResults : List (Result e a) -> (List e, List a)
```

The `Err` values and the `Ok` values, as two lists.

```medaka
> partitionResults [Ok 1, Err "boom", Ok 3]
(["boom"], [1, 3])
```

### `tally`

```
tally : Eq a => List a -> List (a, Int)
```

Each distinct element paired with the number of times it occurs.

Elements appear in the order they were first seen.

```medaka
> tally [1, 2, 1, 3, 1, 2]
[(1, 3), (2, 2), (3, 1)]
```

## Zipping

### `zip`

```
zip : List a -> List b -> List (a, b)
```

The elements of two lists paired up by position.

The result is as long as the shorter input. Extra elements of the longer
one are dropped.

```medaka
> zip [1, 2, 3] [10, 20]
[(1, 10), (2, 20)]
```

### `zip3`

```
zip3 : List a -> List b -> List c -> List (a, b, c)
```

The elements of three lists grouped into triples by position.

The result is as long as the shortest input.

```medaka
> zip3 [1, 2] [3, 4] [5, 6]
[(1, 3, 5), (2, 4, 6)]
```

### `zipWith`

```
zipWith : (a -> b -> <e> c) -> List a -> List b -> <e> List c
```

The elements of two lists combined by position with `f`.

The result is as long as the shorter input. `zip` is `zipWith` with a
pairing function.

```medaka
> zipWith (x y => x + y) [1, 2, 3] [10, 20, 30]
[11, 22, 33]
```

### `zip4`

```
zip4 : List a -> List b -> List c -> List d -> List (a, b, c, d)
```

The elements of four lists grouped into 4-tuples by position.

The result is as long as the shortest input.

```medaka
> zip4 [1, 2] [3, 4] [5, 6] [7, 8]
[(1, 3, 5, 7), (2, 4, 6, 8)]
```

### `zipWith3`

```
zipWith3 : (a -> b -> c -> <e> d) -> List a -> List b -> List c -> <e> List d
```

The elements of three lists combined by position with `f`.

The result is as long as the shortest input.

```medaka
> zipWith3 (x y z => x + y + z) [1, 2] [10, 20] [100, 200]
[111, 222]
```

### `unzip`

```
unzip : List (a, b) -> (List a, List b)
```

A list of pairs separated into a pair of lists. The inverse of `zip`.

```medaka
> unzip [(1, 2), (3, 4)]
([1, 3], [2, 4])
```

### `unzip3`

```
unzip3 : List (a, b, c) -> (List a, List b, List c)
```

A list of triples separated into three lists. The inverse of `zip3`.

```medaka
> unzip3 [(1, 2, 3), (4, 5, 6)]
([1, 4], [2, 5], [3, 6])
```

## Instances

- `List`: `Eq`, `Semigroup`, `Monoid`, [`Ord`](#ord-list-a), `Debug`, `Display`, `Hashable`, `Mappable`, `Applicative`, `Thenable`, `Alternative`, [`Index`](#index-list-a-int-a), [`Slice`](#slice-list-a), `Foldable`, `Traversable`, [`Filterable`](#filterable-list), `Arbitrary`

### `Ord (List a)`

```
impl Ord (List a) requires Ord a
```

Lexicographic ordering: compare element-wise, and a proper prefix sorts
before any list that extends it (`[1] < [1, 2]`, `[] < [0]`).

### `Index (List a) Int a`

```
impl Index (List a) Int a
```

`index xs i` is `xs`'s element at position `i`.  O(n) — a singly-linked
list has no random access, so this walks `i` cons cells; prefer `Array`/
`Vector` for index-heavy workloads.  Raises the coded `indexError`
(E-INDEX-OOB) when `i` is out of range.  No `IndexMut` impl: `List` is
immutable / has no in-place element write.

### `Slice (List a)`

```
impl Slice (List a)
```

`slice xs lo hi` is the sublist of `xs` over `[lo, hi)`.  O(hi) -- walks the
cons chain.  Out-of-range bounds are CLAMPED (never panics), matching the
interpreter's list-slice contract.

```medaka
> slice [10, 20, 30, 40] 1 3
[20, 30]
```

### `Filterable List`

```
impl Filterable List
```

`Filterable List`.  Lives in `core` (rather than `list.mdk`) so the
`filter` name is in scope for the rest of the stdlib; `list.mdk`
re-exports it for discoverability.

```medaka
> filter (x => x > 2) [1, 2, 3, 4]
[3, 4]
```

